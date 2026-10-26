package Bot::HouseBot;
# ABSTRACT: AI agent IRC bot with Langertha::Raider, MCP tools, and conversation memory
#
# One runtime for the whole household. Each bot's entry script (treb.pl,
# burt.pl, astrid.pl, critic.pl) sets $Bot::HouseBot::PROFILE and
# $Bot::HouseBot::SCRIPT_FILE in a BEGIN block before loading this module;
# per-bot differences live in Bot::Profiles. BOT_PROFILE in the environment
# is the fallback when no entry script set one.
#
# Environment:
#   ENGINE=Groq                 Engine class (default: Groq)
#   MODEL=llama-3.3-70b-versatile  Model name
#   API_KEY=gsk_...             API key (or LANGERTHA_<ENGINE>_API_KEY)
#   OLLAMA_URL=http://127.0.0.1:11434  Local Ollama-compatible endpoint
#   IRC_SERVER=irc.perl.org     IRC server (default: irc.perl.org)
#   IRC_PORT=6667               IRC server port (default: 6667)
#   IRC_NICKNAME=treb_bot       Bot nickname (default: profile default or random from a fun list)
#   BOT_IDENTITY_SLUG=treb      Persona/memory identity (default: profile default or nickname)
#   OWNER=mateu                 Bot owner name for personality (default: $USER)
#   IRC_CHANNELS=#ai            Channels to join
#   DB_FILE=ai-bot.db           SQLite database path
#   MAX_LINE_LENGTH=400         Max IRC line length (default: 400)
#   BUFFER_DELAY=1.5            Seconds to buffer messages before processing (default: 1.5)
#   LINE_DELAY=3                Delay between outgoing IRC lines (default: 3)
#   IDLE_PING=1800              Seconds of silence before idle ping (default: 1800)
#   SYSTEM_PROMPT=...           Additional text appended to the system prompt

use strict;
use warnings;
use utf8;

BEGIN {
  binmode(STDOUT, ':encoding(UTF-8)');
  binmode(STDERR, ':encoding(UTF-8)');
  STDOUT->autoflush(1);
  STDERR->autoflush(1);
}

use Bot::MemoryStore;
use Bot::OutputCleanup ();
use Bot::Profiles qw(profile_for);
use Bot::Runtime::Buffering qw(
  buffer_message
  split_priority_messages
  schedule_pending_buffers
);

use Bot::Runtime::Dispatch ();
use Bot::Runtime::OutputPipeline ();
use Bot::Runtime::MethodDelegates ();
use Bot::Runtime::PresenceEvents ();
use Bot::Runtime::ConnectionEvents ();
use Bot::Runtime::PublicMessages ();
use Bot::Runtime::ConversationMemory ();
use Bot::Runtime::Reminders ();
use Bot::IRCIdentity qw(irc_fold);
use Bot::Runtime::WebTools ();
use Bot::Runtime::RaidFlow ();
use Bot::Runtime::EntrypointConfig qw(
  load_entrypoint_config
  build_persona_trait_config
  build_runtime_delegate_config
);
use Bot::Persona ();

our $PROFILE;
our $SCRIPT_FILE;

my $PROFILE_NAME = $PROFILE // $ENV{BOT_PROFILE}
  // die 'Bot::HouseBot needs a profile: load it via a bot entry script or set BOT_PROFILE';
my $P = profile_for($PROFILE_NAME);
$SCRIPT_FILE //= do {
  (my $dir = __FILE__) =~ s{/?lib/Bot/HouseBot\.pm\z}{};
  ($dir eq '' ? '.' : $dir) . "/$P->{name}.pl";
};

my $CONFIG = load_entrypoint_config(
  default_nick          => $P->{default_nick},
  default_identity_slug => $P->{default_identity_slug},
);
my $BOT_NICK = $CONFIG->{bot_nick};
my $BOT_IDENTITY_SLUG = $CONFIG->{bot_identity_slug};
my $OWNER = $CONFIG->{owner};

my $MAX_LINE = $CONFIG->{max_line};
my $BUFFER_DELAY = $CONFIG->{buffer_delay};
my $LINE_DELAY = $CONFIG->{line_delay};
my $IDLE_PING = $CONFIG->{idle_ping};

my ($PERSONA_TRAIT_META, $PERSONA_TRAIT_ORDER) = build_persona_trait_config(
  defaults => $P->{trait_defaults},
);
my $ENTRYPOINT_RUNTIME_CONFIG = build_runtime_delegate_config(
  bot_name_slug   => $BOT_IDENTITY_SLUG,
  trait_meta      => $PERSONA_TRAIT_META,
  trait_order     => $PERSONA_TRAIT_ORDER,
  mcp_server_name => $P->{mcp_server_name},
  owner           => $OWNER,
  max_line        => $MAX_LINE,
  script_file     => $SCRIPT_FILE,
);

# --- The IRC Bot ---

use Moses;
use namespace::autoclean;
use HTML::Entities ();
use Encode ();
use Future::AsyncAwait;
use Bot::Commands::CPAN ();

Bot::Runtime::MethodDelegates::install_shared_delegates(__PACKAGE__);

server ( $ENV{IRC_SERVER} || 'irc.perl.org' );
port ( $ENV{IRC_PORT} || 6667 );
nickname ( $BOT_NICK );
channels ( $ENV{IRC_CHANNELS} ? split(/,/, $ENV{IRC_CHANNELS}) : '#ai' );

has memory => (
  is => 'ro', lazy => 1, traits => ['NoGetopt'],
  default => sub { Bot::MemoryStore->new },
);

has _mcp => ( is => 'rw', traits => ['NoGetopt'] );
has _raider => ( is => 'rw', traits => ['NoGetopt'] );
has _msg_buffer => (
  is => 'rw', traits => ['NoGetopt'],
  default => sub { {} },  # { channel => [messages] }
);
has _buffer_timers => (
  is => 'rw', traits => ['NoGetopt'],
  default => sub { {} },  # { channel => alarm_id }
);
has _processing => (
  is => 'rw', traits => ['NoGetopt'],
  default => 0,
);
has _pending_raid => (
  is => 'rw', traits => ['NoGetopt'],
  default => sub { undef },
);
has _rate_limit_wait => (
  is => 'rw', traits => ['NoGetopt'],
  default => 0,
);

sub _profile { $P }

sub _entrypoint_runtime_config {
  my ($self) = @_;
  return $ENTRYPOINT_RUNTIME_CONFIG;
}

has _last_activity => (
  is => 'rw', traits => ['NoGetopt'],
  default => sub { time() },
);

# Netsplit detection: collect server-split quits within a short window
has _netsplit_quits => (
  is => 'rw', traits => ['NoGetopt'],
  default => sub { [] },
);

before 'START' => sub {
  my ($self) = @_;
  $self->_setup_raider->get;
  POE::Kernel->delay( _idle_check => $IDLE_PING );
};

sub _send_to_channel_max_line { $MAX_LINE }
sub _send_to_channel_return_cumulative { $P->{return_cumulative_send} ? 1 : 0 }

# POE writes Perl's internal string representation to the socket, so a
# decoded string must be encoded explicitly or Latin-1-range characters go
# out as single bytes.
event _send_line => sub {
  my ( $self, $channel, $line ) = @_[ OBJECT, ARG0, ARG1 ];
  $self->privmsg($channel => Encode::encode_utf8($line));
  eval { Bot::Runtime::ConversationMemory::record_outgoing_line(self=>$self,channel=>$channel,line=>$line); 1 }
    or $self->info("Public-message journal failed: $@");
};

sub _default_filtered_bot_nicks { $P->{default_filtered_bot_nicks} }

sub _buffer_delay_seconds {
  my ($self) = @_;
  return $BUFFER_DELAY;
}

# Standard lane: filtered-bot replies are capped by a turn counter.
has _bert_reply_turn_count => (
  is => 'rw', traits => ['NoGetopt'],
  default => sub { 0 },
);

# Ambient lane (Burt): one filtered-bot reply until a human speaks.
has _bert_reply_lock => (
  is => 'rw', traits => ['NoGetopt'],
  default => sub { 0 },
);

has _public_thread_open_until => (
  is => 'rw', traits => ['NoGetopt'],
  default => sub { 0 },
);

has _human_warm_reply_count => (
  is => 'rw', traits => ['NoGetopt'],
  default => sub { 0 },
);

has _human_warm_reply_expires_at => (
  is => 'rw', traits => ['NoGetopt'],
  default => sub { 0 },
);

has _persona_cache => (
  is => 'rw', traits => ['NoGetopt'],
  default => sub { {} },
);

sub _handles_bare_utility_commands { $P->{bare_utility_commands} ? 1 : 0 }

sub _is_trivial_parenthetical {
  my ($self, $text) = @_;
  return 0 unless defined $text;
  my $t = $text;
  $t =~ s/^\s+|\s+$//g;
  return 0 unless length $t;
  return 1 if $t =~ /^\(\s*(?:\.{1,}|…+|\.\s*\.\s*\.|…\s*…\s*…|uh+|um+|er+|hmm+|hm+|\.\.\.\s*)\s*\)$/i;
  return 1 if $t =~ /^\(\s*(?:pause|beat|silence|quiet|thinking|muttering|listening|watching|observing)\s*\)$/i;
  return 0;
}

sub _is_non_substantive_output {
  my ($self, $text) = @_;
  return 1 if $P->{parenthetical_guards} && $self->_is_trivial_parenthetical($text);
  return Bot::OutputCleanup::is_non_substantive_output($text);
}

sub _is_repeated_parenthetical_output {
  my ($self, $channel, $text) = @_;
  return 0 unless defined $channel && length $channel;
  return 0 unless defined $text;

  my $t = $text;
  $t =~ s/^\s+|\s+$//g;
  return 0 unless length $t;
  return 0 unless $t =~ /^\(.*\)$/s;

  my $rows = eval {
    $self->memory->_dbh->selectall_arrayref(
      q{SELECT response FROM conversations
         WHERE channel = ? AND response IS NOT NULL AND response != ''
         ORDER BY id DESC LIMIT 3},
      { Slice => {} }, $channel,
    );
  };
  return 0 if $@ || ref($rows) ne 'ARRAY' || !@$rows;

  my $last = $rows->[0]{response};
  return 0 unless defined $last;
  $last =~ s/^\s+|\s+$//g;
  return 0 unless length $last;
  return 0 unless $last =~ /^\(.*\)$/s;

  return lc($last) eq lc($t) ? 1 : 0;
}

event _process_buffer => sub {
  my ($self, $channel) = @_[OBJECT, ARG0];
  return Bot::Runtime::Buffering::process_buffer_event(
    self    => $self,
    channel => $channel,
  );
};

sub _do_raid {
  my ($self) = @_;
  my $ambient = $P->{public_messages} eq 'ambient';
  return Bot::Runtime::RaidFlow::do_raid(
    self => $self,
    max_line => $MAX_LINE,
    brainfreeze => $P->{brainfreeze},
    silent_name => $BOT_NICK,
    allow_bert_non_substantive => $P->{allow_bert_non_substantive},
    ($P->{parenthetical_guards} ? (post_cleanup_guard => sub {
      my ($bot, $channel, $answer) = @_;
      if ($bot->_is_trivial_parenthetical($answer)) {
        $bot->info("Suppressing trivial parenthetical output");
        $bot->_schedule_pending_buffers;
        return 1;
      }
      if ($bot->_is_repeated_parenthetical_output($channel, $answer)) {
        $bot->info("Suppressing repeated parenthetical output");
        $bot->_schedule_pending_buffers;
        return 1;
      }
      return 0;
    }) : ()),
    on_bert_reply_consumed => sub {
      my ($bot) = @_;
      if ($ambient) {
        $bot->_bert_reply_lock(1);
        $bot->info('Burt conversational reply consumed; lock set');
        return;
      }
      my $next = $bot->_bert_reply_turn_count + 1;
      $bot->_bert_reply_turn_count($next);
      $bot->info("Bert conversational reply consumed; turn count=$next");
    },
  );
}

event _retry_raid => sub {
  my ($self) = $_[OBJECT];
  $self->info("Retrying raid...");
  $self->_do_raid;
};

has _reminder_channels => (is => 'rw', traits => ['NoGetopt'], default => sub { {} });

event _reminder_tick => sub {
  Bot::Runtime::Reminders::poll($_[OBJECT]);
};

event _idle_check => sub {
  my ($self) = $_[OBJECT];
  my $idle_secs = time() - $self->_last_activity;
  if ($idle_secs >= $IDLE_PING && !$self->_processing) {
    my $idle_mins = int($idle_secs / 60);
    $self->info("Idle ping after ${idle_mins}m");
    # Ping first channel only (idle is a global concept)
    my $channel = $self->_default_channel;
    $self->_buffer_message($channel, 'system',
      "No activity for $idle_mins minutes. You can say something if you want, or stay_silent.");
  }
  POE::Kernel->delay( _idle_check => $IDLE_PING );
};

event irc_public => sub {
  my ( $self, $nickstr, $channels, $msg ) = @_[ OBJECT, ARG0, ARG1, ARG2 ];
  eval { Bot::Runtime::ConversationMemory::observe_public_message(
    self=>$self,nickstr=>$nickstr,channels=>$channels,msg=>$msg); 1 }
    or $self->info("Public-message observation failed: $@");
  if ($P->{public_messages} eq 'ambient') {
    return Bot::Runtime::PublicMessages::handle_ambient_irc_public_event(
      self               => $self,
      nickstr            => $nickstr,
      channels           => $channels,
      msg                => $msg,
      utility_style      => $P->{utility_style},
      utility_notes_mode => $P->{utility_notes_mode},
    );
  }
  return Bot::Runtime::PublicMessages::handle_standard_irc_public_event(
    self       => $self,
    nickstr    => $nickstr,
    channels   => $channels,
    msg        => $msg,
    utility_style      => $P->{utility_style},
    utility_notes_mode => $P->{utility_notes_mode},
    bot_direct_mode    => q{mention},
    human_direct_mode  => q{addressed_to_self},
  );
};

event irc_join => sub {
  my ( $self, $nickstr, $channel ) = @_[ OBJECT, ARG0, ARG1 ];
  my ($nick) = split /!/, $nickstr;
  if (irc_fold($nick) eq irc_fold($self->get_nickname)) {
    $self->_reminder_channels->{irc_fold($channel)} = 1;
    Bot::Runtime::Reminders::poll($self);
  }
  Bot::Runtime::PresenceEvents::handle_irc_join(
    self    => $self,
    nickstr => $nickstr,
    channel => $channel,
  );
};

event irc_kick => sub {
  my ($self, $channel, $kicked) = @_[OBJECT, ARG1, ARG2];
  delete $self->_reminder_channels->{irc_fold($channel)}
    if irc_fold($kicked) eq irc_fold($self->get_nickname);
};

event irc_part => sub {
  my ( $self, $nickstr, $channel, $reason ) = @_[ OBJECT, ARG0, ARG1, ARG2 ];
  my ($nick) = split /!/, $nickstr;
  delete $self->_reminder_channels->{irc_fold($channel)}
    if irc_fold($nick) eq irc_fold($self->get_nickname);
  Bot::Runtime::PresenceEvents::handle_irc_part(
    self    => $self,
    nickstr => $nickstr,
    channel => $channel,
    reason  => $reason,
  );
};

event irc_quit => sub {
  my ( $self, $nickstr, $reason ) = @_[ OBJECT, ARG0, ARG1 ];
  Bot::Runtime::PresenceEvents::handle_irc_quit(
    self    => $self,
    nickstr => $nickstr,
    reason  => $reason,
  );
};

event _netsplit_report => sub {
  my ( $self, $channel, $split_reason ) = @_[ OBJECT, ARG0, ARG1 ];
  Bot::Runtime::PresenceEvents::handle_netsplit_report(
    self         => $self,
    channel      => $channel,
    split_reason => $split_reason,
  );
};

event irc_msg => sub {
  my ( $self, $nickstr, $recipients, $msg ) = @_[ OBJECT, ARG0, ARG1, ARG2 ];
  Bot::Runtime::PresenceEvents::handle_irc_msg(
    self    => $self,
    nickstr => $nickstr,
    msg     => $msg,
  );
};

event irc_whois => sub {
  my ( $self, $info ) = @_[ OBJECT, ARG0 ];
  Bot::Runtime::PresenceEvents::handle_irc_whois(
    self => $self,
    info => $info,
  );
};

event irc_error => sub {
  my ( $self, $message ) = @_[ OBJECT, ARG0 ];
  Bot::Runtime::ConnectionEvents::handle_irc_error(
    self    => $self,
    message => $message,
  );
};

event irc_disconnected => sub {
  my ( $self, $server ) = @_[ OBJECT, ARG0 ];
  $self->_reminder_channels({});
  Bot::Runtime::ConnectionEvents::handle_irc_disconnected(
    self   => $self,
    server => $server,
  );
};

event irc_socketerr => sub {
  my ( $self, $error ) = @_[ OBJECT, ARG0 ];
  Bot::Runtime::ConnectionEvents::handle_irc_socketerr(
    self  => $self,
    error => $error,
  );
};

1;
