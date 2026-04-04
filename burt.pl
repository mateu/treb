#!/usr/bin/env perl
# ABSTRACT: AI agent IRC bot with Langertha::Raider, MCP tools, and conversation memory
#
# Environment:
#   ENGINE=Groq                 Engine class (default: Groq)
#   MODEL=llama-3.3-70b-versatile  Model name
#   API_KEY=gsk_...             API key (or LANGERTHA_<ENGINE>_API_KEY)
#   IRC_SERVER=irc.perl.org     IRC server (default: irc.perl.org)
#   IRC_PORT=6667               IRC server port (default: 6667)
#   IRC_NICKNAME=Bert           Bot nickname (default: random from a fun list)
#   OWNER=Getty                 Bot owner name for personality (default: $USER)
#   IRC_CHANNELS=#ai            Channels to join
#   DB_FILE=ai-bot.db           SQLite database path
#   MAX_LINE_LENGTH=400         Max IRC line length (default: 400)
#   BUFFER_DELAY=1.5            Seconds to buffer messages before processing (default: 1.5)
#   LINE_DELAY=1.5              Delay between outgoing IRC lines (default: 1.5)
#   IDLE_PING=1800              Seconds of silence before idle ping (default: 1800)
#   SYSTEM_PROMPT=...           Additional text appended to the system prompt

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
use Bot::Runtime::RaiderSetup ();
use Bot::Runtime::EntrypointConfig qw(build_persona_trait_config);
use Bot::Persona ();

my @BOT_NAMES = qw(
  Botsworth Clanky Sparky Fizz Gizmo Pixel Blip Rusty Ziggy Turbo
  Sprocket Widget Noodle Bleep Chomp Dingle Wobble Clunk Zippy Quirk
);
my $BOT_NICK = $ENV{IRC_NICKNAME} || $BOT_NAMES[rand @BOT_NAMES] . int(rand(999));
my $BOT_IDENTITY_SLUG = lc($ENV{BOT_IDENTITY_SLUG} || $BOT_NICK || 'bot');
my $OWNER = $ENV{OWNER} || $ENV{USER} || 'unknown';

my $MAX_LINE = $ENV{MAX_LINE_LENGTH} || 400;
my $BUFFER_DELAY = $ENV{BUFFER_DELAY} || 1.5;
my $LINE_DELAY = $ENV{LINE_DELAY} || 3;
my $IDLE_PING = $ENV{IDLE_PING} || 1800;
my ($PERSONA_TRAIT_META, $PERSONA_TRAIT_ORDER) = build_persona_trait_config(
  defaults => {
    ambient_public_reply_pct     => 50,
    public_thread_window_seconds => 45,
    bot_reply_pct                => 25,
    bot_reply_max_turns          => 1,
    non_substantive_allow_pct    => 0,
  },
);

# --- The IRC Bot ---

package BurtBot;
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

sub _bot_name_slug {
  my ($self) = @_;
  return $BOT_IDENTITY_SLUG;
}

sub _persona_runtime_args {
  my ($self) = @_;
  return (
    self        => $self,
    bot_name    => $self->_bot_name_slug,
    trait_meta  => $PERSONA_TRAIT_META,
    trait_order => $PERSONA_TRAIT_ORDER,
  );
}

sub _mcp_server_name {
  my ($self) = @_;
  return 'burt-tools';
}

async sub _setup_raider {
  my ($self) = @_;
  Bot::Runtime::RaiderSetup::setup_raider(
    self        => $self,
    owner       => $OWNER,
    max_line    => $MAX_LINE,
    script_file => __FILE__,
  );
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
  return 1 unless defined $text;

  my $t = $text;
  $t =~ s/^\s+|\s+$//g;
  return 1 unless length $t;
  return 1 if $self->_is_trivial_parenthetical($t);

  # Burt is intentionally more conversational/atmospheric than Treb.
  # Preserve a few of the older permissive guardrails here so shared
  # cleanup extraction does not over-suppress substantive Burt replies.
  return 0 if $t =~ m{https?://};
  return 0 if $t =~ /[:;]/;
  return 0 if length($t) > 180;

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

sub _send_to_channel {
  my ($self, $channel, $text) = @_;
  return Bot::Runtime::Dispatch::send_to_channel(
    channel           => $channel,
    text              => $text,
    max_line          => $MAX_LINE,
    return_cumulative => 1,
  );
}

event _send_line => sub {
  my ( $self, $channel, $line ) = @_[ OBJECT, ARG0, ARG1 ];
  $self->privmsg($channel => $line);
};

sub _default_filtered_bot_nicks {
  my ($self) = @_;
  return '';
}

sub _buffer_delay_seconds {
  my ($self) = @_;
  return $BUFFER_DELAY;
}

has _bert_reply_lock => (
  is => 'rw', traits => ['NoGetopt'],
  default => sub { 0 },
);

has _public_thread_open_until => (
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
    silent_name => "Burt",
    allow_bert_non_substantive => 0,
    post_cleanup_guard => sub {
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
    },
    on_bert_reply_consumed => sub {
      my ($bot) = @_;
      $bot->_bert_reply_lock(1);
      $bot->info('Burt conversational reply consumed; lock set');
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

  if ($self->_is_human_nick($nick) && $self->_bert_reply_lock) {
    $self->_bert_reply_lock(0);
    $self->info("Reset burt conversational lock by human nick=$nick");
  }

  if (Bot::Runtime::UtilityCommands::handle_public_utility_command(
    self       => $self,
    channel    => $channel,
    msg        => $msg,
    style      => q{relaxed},
    notes_mode => q{direct_only},
  )) {
    return;
  }

  my $speaker_is_filtered_bot = $self->_is_filtered_bot_nick($nick);

  my $bot_nick = $self->get_nickname;
  my $nick_re = quotemeta($bot_nick);
  my $direct_address = ($msg =~ /(?:^|\W)$nick_re(?:\W|$)/i) ? 1 : 0;
  my $thread_open = ($self->_public_thread_open_until && time() <= $self->_public_thread_open_until) ? 1 : 0;
  my $addressed_other_human_turn = 0;
  if ($self->_is_human_nick($nick) && !$direct_address) {
    if ($msg =~ /^\s*([A-Za-z0-9_\-]+)\s*[:,]/) {
      my $target = $1;
      $addressed_other_human_turn = 1 if lc($target) ne lc($bot_nick);
    }
  }

  if ($speaker_is_filtered_bot) {
    return unless $direct_address;
    if ($self->_bert_reply_lock) {
      $self->info('Suppressing Burt conversational message: lock set');
      return;
    }
    my $bot_reply_pct = $self->_persona_trait('bot_reply_pct');
    if ($bot_reply_pct < 100 && int(rand(100)) >= $bot_reply_pct) {
      $self->info("Suppressing Burt conversational message: probability gate bot_reply_pct=$bot_reply_pct");
      return;
    }
    $self->info('Allowing Burt conversational message (direct address, unlocked)');
    my $public_thread_window_seconds = $self->_persona_trait('public_thread_window_seconds');
    if ($public_thread_window_seconds > 0) {
      $self->_public_thread_open_until(time() + $public_thread_window_seconds);
      $self->info("Opened public thread window for ${public_thread_window_seconds}s (filtered bot lane)");
    }
    $self->_buffer_message($channel, $nick, $msg, { source_kind => 'bert_conversation' });
    return;
  }

  if ($direct_address) {
    my $public_thread_window_seconds = $self->_persona_trait('public_thread_window_seconds');
    if ($public_thread_window_seconds > 0) {
      $self->_public_thread_open_until(time() + $public_thread_window_seconds);
      $self->info("Opened public thread window for ${public_thread_window_seconds}s (direct address)");
    }
    $self->_buffer_message($channel, $nick, $msg, {
      source_kind => 'conversation',
      warm_human  => 1,
    });
    return;
  }

  if ($addressed_other_human_turn) {
    $self->info('Suppressing public conversational message: human addressed someone else');
    return;
  }

  if ($thread_open) {
    $self->info('Allowing public conversational message due to open thread window');
    $self->_buffer_message($channel, $nick, $msg, { source_kind => 'conversation' });
    return;
  }

  my $ambient_public_reply_pct = $self->_persona_trait('ambient_public_reply_pct');
  if ($ambient_public_reply_pct < 100 && int(rand(100)) >= $ambient_public_reply_pct) {
    $self->info("Suppressing public conversational message: probability gate ambient_public_reply_pct=$ambient_public_reply_pct");
    return;
  }

  $self->info('Allowing public conversational message via ambient probability gate');
  $self->_buffer_message($channel, $nick, $msg, { source_kind => 'conversation' });
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
