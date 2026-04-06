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
use utf8;
use Encode qw();
binmode(STDOUT, ":utf8");
binmode(STDERR, ":utf8");
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
use Bot::Runtime::PublicMessages ();
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
    bot_reply_pct              => 50,
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

package BertBot;
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


sub _send_to_channel_max_line { $MAX_LINE }

event _send_line => sub {
  my ( $self, $channel, $line ) = @_[ OBJECT, ARG0, ARG1 ];
  $self->privmsg($channel => Encode::encode_utf8($line));
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

sub _handles_bare_utility_commands { 1 }

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
    silent_name => "treb_bot",
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
  return Bot::Runtime::PublicMessages::handle_standard_irc_public_event(
    self       => $self,
    nickstr    => $nickstr,
    channels   => $channels,
    msg        => $msg,
    utility_style      => q{strict},
    utility_notes_mode => q{direct_only},
    bot_direct_mode    => q{mention},
    human_direct_mode  => q{addressed_to_self},
  );
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
