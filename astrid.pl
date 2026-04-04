#!/usr/bin/env perl
# ABSTRACT: Astrid IRC bot with shared Treb/Burt runtime, MCP tools, and conversation memory
#
# Environment:
#   ENGINE=Ollama              Engine class (override as needed)
#   MODEL=kimi-k2.5:cloud      Model name
#   API_KEY=...                Optional API key for engines that require one
#   OLLAMA_URL=http://127.0.0.1:11434  Local Ollama-compatible endpoint
#   IRC_SERVER=irc.perl.org    IRC server
#   IRC_PORT=6667              IRC server port (default: 6667)
#   IRC_NICKNAME=Astrid        Bot nickname
#   OWNER=mateu                Bot owner name for personality context
#   IRC_CHANNELS=#ai           Channels to join
#   DB_FILE=astrid.sqlite      SQLite database path
#   MAX_LINE_LENGTH=400        Max IRC line length
#   BUFFER_DELAY=1.5           Seconds to buffer messages before processing
#   LINE_DELAY=3               Delay between outgoing IRC lines
#   IDLE_PING=1800             Seconds of silence before idle ping
#   SYSTEM_PROMPT=...          Additional text appended to the system prompt

use strict;
use warnings;
use lib 'lib';

use Bot::MemoryStore;
use Bot::Runtime::Buffering qw(
  buffer_message
  split_priority_messages
  schedule_pending_buffers
);

use Bot::Runtime::Dispatch ();
use Bot::Runtime::OutputPipeline ();
use Bot::Runtime::MethodDelegates ();
use Bot::Runtime::PresenceEvents ();
use Bot::Runtime::UtilityCommands ();
use Bot::Runtime::WebTools ();
use Bot::Runtime::RaidFlow ();
use Bot::Runtime::EntrypointConfig qw(
  load_entrypoint_config
  build_persona_trait_config
  build_runtime_delegate_config
);
use Bot::Persona ();

my $CONFIG = load_entrypoint_config();
my $BOT_NICK = $CONFIG->{bot_nick};
my $BOT_IDENTITY_SLUG = $CONFIG->{bot_identity_slug};
my $OWNER = $CONFIG->{owner};

my $MAX_LINE = $CONFIG->{max_line};
my $BUFFER_DELAY = $CONFIG->{buffer_delay};
my $LINE_DELAY = $CONFIG->{line_delay};
my $IDLE_PING = $CONFIG->{idle_ping};

my ($PERSONA_TRAIT_META, $PERSONA_TRAIT_ORDER) = build_persona_trait_config(
  defaults => {
    ambient_public_reply_pct   => 0,
    public_thread_window_seconds => 0,
    bot_reply_pct              => 25,
    bot_reply_max_turns        => 1,
    non_substantive_allow_pct  => 0,
  },
);
my $ENTRYPOINT_RUNTIME_CONFIG = build_runtime_delegate_config(
  bot_name_slug   => $BOT_IDENTITY_SLUG,
  trait_meta      => $PERSONA_TRAIT_META,
  trait_order     => $PERSONA_TRAIT_ORDER,
  mcp_server_name => 'bert-tools',
  owner           => $OWNER,
  max_line        => $MAX_LINE,
  script_file     => __FILE__,
);

# --- The IRC Bot ---

package AstridBot;
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


sub _send_to_channel {
  my ($self, $channel, $text) = @_;
  return Bot::Runtime::Dispatch::send_to_channel(
    channel  => $channel,
    text     => $text,
    max_line => $MAX_LINE,
  );
}

event _send_line => sub {
  my ( $self, $channel, $line ) = @_[ OBJECT, ARG0, ARG1 ];
  $self->privmsg($channel => $line);
};

sub _default_filtered_bot_nicks {
  my ($self) = @_;
  return 'burt_bot';
}

sub _buffer_delay_seconds {
  my ($self) = @_;
  return $BUFFER_DELAY;
}

has _bert_reply_turn_count => (
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

sub _handles_bare_utility_commands { 0 }

event _process_buffer => sub {
  my ($self, $channel) = @_[OBJECT, ARG0];
  return Bot::Runtime::Buffering::process_buffer_event(
    self    => $self,
    channel => $channel,
  );
};

my @BRAINFREEZE = (
  '*brainfreeze*',
  '*buffering...*',
  '*hamster needs a breather*',
  '*neurons recharging*',
  '*getty forgot to pay the electricity bill again*',
  '*thinking intensifies... slowly*',
  '*basement WiFi acting up*',
);

sub _do_raid {
  my ($self) = @_;
  return Bot::Runtime::RaidFlow::do_raid(
    self => $self,
    max_line => $MAX_LINE,
    brainfreeze => \@BRAINFREEZE,
    silent_name => "Bert",
    allow_bert_non_substantive => 1,
    on_bert_reply_consumed => sub {
      my ($bot) = @_;
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

event _alarm_fired => sub {
  my ( $self, $channel, $reason ) = @_[ OBJECT, ARG0, ARG1 ];
  $self->info("Alarm fired: $reason");
  $self->_buffer_message($channel, 'system',
    "ALARM FIRED: $reason — You set this alarm earlier. Decide what to do now.");
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
  my ( $nick ) = split /!/, $nickstr;
  return if $nick eq $self->get_nickname;
  my $channel = ref $channels ? $channels->[0] : $channels;
  $self->info("$channel <$nick> $msg");
  $self->_last_activity(time());

  if ($self->_is_human_nick($nick) && $self->_bert_reply_turn_count) {
    $self->_bert_reply_turn_count(0);
    $self->info("Reset bert conversational turn count by human nick=$nick");
  }

  if (Bot::Runtime::UtilityCommands::handle_public_utility_command(
    self       => $self,
    channel    => $channel,
    msg        => $msg,
    style      => q{relaxed},
    notes_mode => q{utility_prefixed},
  )) {
    return;
  }

  my $speaker_is_filtered_bot = $self->_is_filtered_bot_nick($nick);

  my $bot_nick = $self->get_nickname;
  my $nick_re = quotemeta($bot_nick);
  my $direct_address = ($msg =~ /(?:^|\W)$nick_re(?:\W|$)/i) ? 1 : 0;

  if ($speaker_is_filtered_bot) {
    return unless $direct_address;
    my $bot_reply_max_turns = $self->_persona_trait('bot_reply_max_turns');
    if ($bot_reply_max_turns > 0 && $self->_bert_reply_turn_count >= $bot_reply_max_turns) {
      $self->info("Suppressing Bert conversational message: turn cap reached bot_reply_max_turns=$bot_reply_max_turns");
      return;
    }
    my $bot_reply_pct = $self->_persona_trait('bot_reply_pct');
    if ($bot_reply_pct < 100 && int(rand(100)) >= $bot_reply_pct) {
      $self->info("Suppressing Bert conversational message: probability gate bot_reply_pct=$bot_reply_pct");
      return;
    }
    $self->info('Allowing Bert conversational message (direct address, unlocked)');
    $self->_buffer_message($channel, $nick, $msg, { source_kind => 'bert_conversation' });
    return;
  }

  return unless $direct_address;

  my $warm_limit = 3;
  my $warm_window = 300;
  if (!$self->_human_warm_reply_expires_at || time() > $self->_human_warm_reply_expires_at) {
    $self->_human_warm_reply_count(0);
  }
  my $warm_human = ($self->_human_warm_reply_count < $warm_limit) ? 1 : 0;
  $self->_human_warm_reply_count($self->_human_warm_reply_count + 1);
  $self->_human_warm_reply_expires_at(time() + $warm_window);

  $self->_buffer_message($channel, $nick, $msg, { source_kind => 'conversation', warm_human => $warm_human });
};

event irc_join => sub {
  my ( $self, $nickstr, $channel ) = @_[ OBJECT, ARG0, ARG1 ];
  Bot::Runtime::PresenceEvents::handle_irc_join(
    self    => $self,
    nickstr => $nickstr,
    channel => $channel,
  );
};

event irc_part => sub {
  my ( $self, $nickstr, $channel, $reason ) = @_[ OBJECT, ARG0, ARG1, ARG2 ];
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

__PACKAGE__->run unless caller;
