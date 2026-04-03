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
use Bot::Mission qw(load_mission_for_script);
use Bot::Commands::Time qw(time_text_for_zone current_local_time_text);
use Bot::OutputCleanup qw(
  repair_mojibake_text
  clean_text_for_irc
  is_non_substantive_output
);
use Bot::Runtime::Buffering qw(
  buffer_message
  split_priority_messages
  schedule_pending_buffers
);

use Bot::Runtime::Dispatch ();
use Bot::Runtime::MCPServer ();
use Bot::Runtime::PersonaTools ();
use Bot::Runtime::OutputPipeline ();
use Bot::Runtime::Presence ();
use Bot::Runtime::WebTools ();
use Bot::Runtime::Policy ();
use Bot::Runtime::RaidFlow ();
use Bot::Persona qw(
  persona_trait_meta
  persona_trait_order
  clamp_persona_value
  load_persona_cache
  persona_text
  persona_summary_text
  persona_trait_text
  set_persona_trait
  apply_persona_preset
);

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
my $NON_SUBSTANTIVE_ALLOW_PCT = exists $ENV{NON_SUBSTANTIVE_ALLOW_PCT} ? 0 + $ENV{NON_SUBSTANTIVE_ALLOW_PCT} : 0;
$NON_SUBSTANTIVE_ALLOW_PCT = 0 if $NON_SUBSTANTIVE_ALLOW_PCT < 0;
$NON_SUBSTANTIVE_ALLOW_PCT = 100 if $NON_SUBSTANTIVE_ALLOW_PCT > 100;
my $BOT_REPLY_PCT = exists $ENV{BOT_REPLY_PCT} ? 0 + $ENV{BOT_REPLY_PCT} : 25;
$BOT_REPLY_PCT = 0 if $BOT_REPLY_PCT < 0;
$BOT_REPLY_PCT = 100 if $BOT_REPLY_PCT > 100;
my $BOT_REPLY_MAX_TURNS = exists $ENV{BOT_REPLY_MAX_TURNS} ? 0 + $ENV{BOT_REPLY_MAX_TURNS} : 1;
$BOT_REPLY_MAX_TURNS = 0 if $BOT_REPLY_MAX_TURNS < 0;

my %PERSONA_TRAIT_META = (
  join_greet_pct => { kind => 'pct', env => 'JOIN_GREET_PCT', default => 100 },
  ambient_public_reply_pct => { kind => 'pct', env => 'PUBLIC_CHAT_ALLOW_PCT', default => 0 },
  public_thread_window_seconds => { kind => 'int', env => 'PUBLIC_THREAD_WINDOW_SECONDS', default => 0 },
  bot_reply_pct => { kind => 'pct', env => 'BOT_REPLY_PCT', default => 50 },
  bot_reply_max_turns => { kind => 'int', env => 'BOT_REPLY_MAX_TURNS', default => 1 },
  non_substantive_allow_pct => { kind => 'pct', env => 'NON_SUBSTANTIVE_ALLOW_PCT', default => 0 },
);
my @PERSONA_TRAIT_ORDER = qw(join_greet_pct ambient_public_reply_pct public_thread_window_seconds bot_reply_pct bot_reply_max_turns non_substantive_allow_pct);

# --- The IRC Bot ---

package AstridBot;
use Moses;
use namespace::autoclean;
use HTML::Entities ();
use Encode ();
use IO::Async::Loop::POE;
use Future::AsyncAwait;
use Net::Async::MCP;
use Module::Runtime qw( use_module );
use Langertha::Raider;
use Bot::Commands::CPAN ();

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

sub _time_text_for_zone {
  my ($self, $zone) = @_;
  return Bot::Commands::Time::time_text_for_zone($zone);
}

sub _current_local_time_text {
  my ($self) = @_;
  return Bot::Commands::Time::current_local_time_text();
}

sub _clamp_persona_value {
  my ($self, $key, $value) = @_;
  return Bot::Persona::clamp_persona_value($key, $value, trait_meta => \%PERSONA_TRAIT_META, trait_order => \@PERSONA_TRAIT_ORDER);
}

sub _bot_name_slug {
  my ($self) = @_;
  return $BOT_IDENTITY_SLUG;
}

sub _default_persona_trait_value {
  my ($self, $key) = @_;
  return Bot::Runtime::PersonaTools::default_persona_trait_value($self->_persona_runtime_args, key => $key);
}

sub _persona_runtime_args {
  my ($self) = @_;
  return (
    self        => $self,
    bot_name    => $self->_bot_name_slug,
    trait_meta  => \%PERSONA_TRAIT_META,
    trait_order => \@PERSONA_TRAIT_ORDER,
  );
}

sub _load_persona_settings {
  my ($self) = @_;
  return Bot::Runtime::PersonaTools::load_persona_settings($self->_persona_runtime_args);
}

sub _persona_trait {
  my ($self, $key) = @_;
  return Bot::Runtime::PersonaTools::persona_trait($self->_persona_runtime_args, key => $key);
}

sub _persona_stats_text {
  my ($self) = @_;
  return Bot::Runtime::PersonaTools::persona_stats_text($self->_persona_runtime_args);
}

sub _persona_text {
  my ($self) = @_;
  return Bot::Runtime::PersonaTools::persona_text($self->_persona_runtime_args);
}

sub _persona_summary_text {
  my ($self) = @_;
  return Bot::Runtime::PersonaTools::persona_summary_text($self->_persona_runtime_args);
}

sub _persona_trait_text {
  my ($self, $trait) = @_;
  return Bot::Runtime::PersonaTools::persona_trait_text($self->_persona_runtime_args, trait => $trait);
}

sub _set_persona_trait {
  my ($self, $trait, $value) = @_;
  return Bot::Runtime::PersonaTools::set_persona_trait($self->_persona_runtime_args, trait => $trait, value => $value);
}

sub _apply_persona_preset {
  my ($self, $value) = @_;
  return Bot::Runtime::PersonaTools::apply_persona_preset($self->_persona_runtime_args, value => $value);
}

sub _mcp_tool_logging_enabled {
  return Bot::Runtime::Policy::mcp_tool_logging_enabled();
}

sub _env_flag_enabled {
  my ($self, $name, $default) = @_;
  return Bot::Runtime::Policy::env_flag_enabled($name, $default);
}

sub _store_system_rows_enabled {
  return Bot::Runtime::Policy::store_system_rows_enabled();
}

sub _store_non_substantive_rows_enabled {
  return Bot::Runtime::Policy::store_non_substantive_rows_enabled();
}

sub _store_empty_response_rows_enabled {
  return Bot::Runtime::Policy::store_empty_response_rows_enabled();
}

sub _cleanup_logging_enabled {
  return Bot::Runtime::Policy::cleanup_logging_enabled();
}

sub _cleanup_log_preview {
  my ($self, $text) = @_;
  return Bot::Runtime::Policy::cleanup_log_preview_text($text);
}

sub _log_cleanup_change {
  my ($self, $label, $before, $after) = @_;
  return Bot::Runtime::Policy::log_cleanup_change(
    self   => $self,
    label  => $label,
    before => $before,
    after  => $after,
  );
}

sub _log_cleanup_empty {
  my ($self, $before, $after) = @_;
  return Bot::Runtime::Policy::log_cleanup_empty(
    self   => $self,
    before => $before,
    after  => $after,
  );
}

sub _db_stats_text {
  my ($self) = @_;
  return Bot::Runtime::PersonaTools::db_stats_text($self->_persona_runtime_args);
}

sub _notes_text {
  my ($self, $nick) = @_;
  return Bot::Runtime::PersonaTools::notes_text(self => $self, nick => $nick);
}
sub _build_mcp_server {
  my ($self) = @_;
  return Bot::Runtime::MCPServer::build_mcp_server(self => $self, server_name => 'bert-tools');
}

async sub _setup_raider {
  my ($self) = @_;

  my $mcp_server = $self->_build_mcp_server;
  my $loop = IO::Async::Loop::POE->new;
  my $mcp = Net::Async::MCP->new(server => $mcp_server);
  $loop->add($mcp);
  await $mcp->initialize;
  $self->_mcp($mcp);

  my $engine_class = 'Langertha::Engine::' . ($ENV{ENGINE} || 'Groq');
  use_module($engine_class);

  my %engine_args = ( mcp_servers => [$mcp] );
  $engine_args{model} = $ENV{MODEL} || 'llama-3.3-70b-versatile';
  $engine_args{api_key} = $ENV{API_KEY} if $ENV{API_KEY};
  if (($ENV{ENGINE} || 'Groq') eq 'Ollama' && $ENV{OLLAMA_URL}) {
    $engine_args{url} = $ENV{OLLAMA_URL};
  }

  my $engine = $engine_class->new(%engine_args);

  my $nick = $self->get_nickname;
  my $model = $engine->model;
  my $provider = ref($engine) =~ s/.*:://r;
  my $chan_list = join(', ', $self->get_channels);
  my $mission = Bot::Mission::load_mission_for_script(
    script_file   => __FILE__,
    nick          => $nick,
    owner         => $OWNER,
    model         => $model,
    provider      => $provider,
    channels      => $chan_list,
    max_line      => $MAX_LINE,
    mission_extra => $ENV{SYSTEM_PROMPT},
  );

  my $raider = Langertha::Raider->new(
    engine             => $engine,
    max_context_tokens => 8192,
    mission            => $mission,
  );

  $self->_raider($raider);
  $self->info("Raider ready: $engine_class / " . ($engine->model));
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


sub _repair_mojibake_text {
  my ($self, $text) = @_;
  return Bot::OutputCleanup::repair_mojibake_text($text);
}

sub _clean_text_for_irc {
  my ($self, $text) = @_;
  return Bot::OutputCleanup::clean_text_for_irc($text);
}

sub _metacpan_get_json { Bot::Commands::CPAN::_metacpan_get_json(@_) }
sub _metacpan_get_text { Bot::Commands::CPAN::_metacpan_get_text(@_) }
sub _extract_pod_section { Bot::Commands::CPAN::_extract_pod_section(@_) }
sub _format_cpan_module_result { Bot::Commands::CPAN::_format_cpan_module_result(@_) }
sub _format_cpan_describe_result { Bot::Commands::CPAN::_format_cpan_describe_result(@_) }
sub _format_cpan_author_result { Bot::Commands::CPAN::_format_cpan_author_result(@_) }
sub _format_cpan_recent_results { Bot::Commands::CPAN::_format_cpan_recent_results(@_) }
sub _cpan_lookup { Bot::Commands::CPAN::_cpan_lookup(@_) }
sub _summarize_special_url { Bot::Commands::CPAN::_summarize_special_url(@_) }
sub _summarize_metacpan_pod { Bot::Commands::CPAN::_summarize_metacpan_pod(@_) }

sub _format_search_results { Bot::Runtime::WebTools::format_search_results(@_) }
sub _summarize_url { Bot::Runtime::WebTools::summarize_url(@_) }
sub _search_web { Bot::Runtime::WebTools::search_web(@_) }

sub _is_non_substantive_output {
  my ($self, $text) = @_;
  return Bot::OutputCleanup::is_non_substantive_output($text);
}

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

sub _is_filtered_bot_nick {
  my ($self, $nick) = @_;
  return Bot::Runtime::Dispatch::is_filtered_bot_nick(
    nick => $nick,
    default_filter_nicks => 'burt_bot',
  );
}

sub _default_channel {
  my ($self) = @_;
  return Bot::Runtime::Dispatch::default_channel(self => $self);
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

sub _is_human_nick {
  my ($self, $nick) = @_;
  return 0 unless defined $nick && length $nick;
  return 0 if $nick eq $self->get_nickname;
  return $self->_is_filtered_bot_nick($nick) ? 0 : 1;
}

sub _handles_bare_utility_commands { 0 }

sub _utility_command_matches_me {
  my ($self, $target) = @_;
  return Bot::Runtime::Dispatch::utility_command_matches_me(
    self       => $self,
    target     => $target,
    allow_bare => $self->_handles_bare_utility_commands,
  );
}

sub _buffer_message {
  my ($self, $channel, $nick, $msg, $extra) = @_;
  return Bot::Runtime::Buffering::buffer_message(
    self    => $self,
    channel => $channel,
    nick    => $nick,
    msg     => $msg,
    extra   => $extra,
    delay   => $BUFFER_DELAY,
  );
}

sub _split_priority_messages {
  my ($self, $messages) = @_;
  return Bot::Runtime::Buffering::split_priority_messages(messages => $messages);
}

event _process_buffer => sub {
  my ($self, $channel) = @_[OBJECT, ARG0];
  return Bot::Runtime::Buffering::process_buffer_event(
    self    => $self,
    channel => $channel,
  );
};

sub _schedule_pending_buffers {
  my ($self) = @_;
  return Bot::Runtime::Buffering::schedule_pending_buffers(
    self  => $self,
    delay => $BUFFER_DELAY,
  );
}

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

  if ($msg =~ /^(?:([A-Za-z0-9_\-]+):\s+)?(?:sum:\s*|:sum\s+)(https?:\/\/\S+)/i) {
    return unless $self->_utility_command_matches_me($1);
    my $url = $2;
    my $result = $self->_summarize_url($url);
    $self->_send_to_channel($channel, $result) if defined($result) && $result =~ /\S/;
    return;
  }

  if ($msg =~ /^(?:([A-Za-z0-9_\-]+):\s+)?(?::time\s*|time:\s*)$/i) {
    return unless $self->_utility_command_matches_me($1);
    my $line = 'Current local time: ' . $self->_current_local_time_text . '.';
    $self->_send_to_channel($channel, $line);
    return;
  }
  if ($msg =~ /^(?:([A-Za-z0-9_\-]+):\s+)?(?::dbstats\s*|dbstats:\s*)$/i) {
    return unless $self->_utility_command_matches_me($1);
    my $line = $self->_db_stats_text;
    $self->_send_to_channel($channel, $line);
    return;
  }

  if ($msg =~ /^(?:([A-Za-z0-9_\-]+):\s+persona\s+full\s*)$/i) {
    return unless lc($1) eq lc($self->get_nickname);
    my $line = $self->_persona_text;
    $self->_send_to_channel($channel, $line);
    return;
  }

  if ($msg =~ /^([A-Za-z0-9_\-]+):\s+persona\s+set\s+(\S+)\s+(?:=\s*)?(\S+)\s*$/i) {
    return unless lc($1) eq lc($self->get_nickname);
    my ($ok, $line) = $self->_set_persona_trait($2, $3);
    $self->_send_to_channel($channel, $line);
    return;
  }

  if ($msg =~ /^([A-Za-z0-9_\-]+):\s+persona\s+get\s+(\S+)\s*$/i) {
    return unless lc($1) eq lc($self->get_nickname);
    my $line = $self->_persona_trait_text($2);
    $self->_send_to_channel($channel, $line);
    return;
  }

  if ($msg =~ /^([A-Za-z0-9_\-]+):\s+persona\s+(\S+)\s*$/i) {
    my ($target_nick, $arg) = ($1, $2);
    return unless lc($target_nick) eq lc($self->get_nickname);
    my $token = lc($arg);
    return if $token eq 'full' || $token eq 'set' || $token eq 'get';
    if ($arg =~ /^\d+$/) {
      my ($ok, $line) = $self->_apply_persona_preset($arg);
      $self->_send_to_channel($channel, $line);
      return;
    }
    my $line = $self->_persona_trait_text($arg);
    $self->_send_to_channel($channel, $line);
    return;
  }

  if ($msg =~ /^(?:([A-Za-z0-9_\-]+):\s+persona\s*)$/i) {
    return unless lc($1) eq lc($self->get_nickname);
    my $line = $self->_persona_summary_text;
    $self->_send_to_channel($channel, $line);
    return;
  }

  if ($msg =~ /^(?:([A-Za-z0-9_\-]+):\s+)?(?:notes:\s*|:notes\s+)(\S+)\s*$/i) {
    return unless $self->_utility_command_matches_me($1);
    my $nick = $2;
    my $line = $self->_notes_text($nick);
    $self->_send_to_channel($channel, $line) if defined($line) && $line =~ /\S/;
    return;
  }


  if ($msg =~ /^(?:([A-Za-z0-9_\-]+):\s+)?(?::time\s+in\s+|time:\s*)([A-Za-z_]+\/[A-Za-z0-9_+\-]+(?:\/[A-Za-z0-9_+\-]+)*)\s*$/i) {
    return unless $self->_utility_command_matches_me($1);
    my $zone = $2;
    my $line = 'Current time in ' . $zone . ': ' . $self->_time_text_for_zone($zone) . '.';
    $self->_send_to_channel($channel, $line);
    return;
  }

  if ($msg =~ /^(?:([A-Za-z0-9_\-]+):\s+)?(?::cpan\s+recent(?:\s+(\d+))?\s*|cpan:\s*recent(?:\s+(\d+))?\s*)$/i) {
    return unless $self->_utility_command_matches_me($1);
    my $count = defined $2 ? $2 : (defined $3 ? $3 : 3);
    my $result = $self->_cpan_lookup('recent', $count);
    $self->_send_to_channel($channel, $result) if defined($result) && $result =~ /\S/;
    return;
  }

  if ($msg =~ /^(?:([A-Za-z0-9_\-]+):\s+)?(?::cpan\s+(module|author|describe)\s+(.+)|cpan:\s*(module|author|describe)\s+(.+))$/i) {
    return unless $self->_utility_command_matches_me($1);
    my ($mode, $query) = defined $2 ? ($2, $3) : ($4, $5);
    my $result = $self->_cpan_lookup($mode, $query);
    $self->_send_to_channel($channel, $result) if defined($result) && $result =~ /\S/;
    return;
  }

  if ($msg =~ /^(?:([A-Za-z0-9_\-]+):\s+)?(?::cpan\s+(.+)|cpan:\s*(.+))$/i) {
    return unless $self->_utility_command_matches_me($1);
    my $query = defined $2 ? $2 : $3;
    $query =~ s/^\s+|\s+$//g;
    my $result = $self->_cpan_lookup('module', $query);
    $self->_send_to_channel($channel, $result) if defined($result) && $result =~ /\S/;
    return;
  }

  if ($msg =~ /^(?:([A-Za-z0-9_\-]+):\s+)?(?::search\s+|search:\s+)(.+)/i) {
    return unless $self->_utility_command_matches_me($1);
    my $arg = $2;
    my ($count, $query) = (3, $arg);
    if ($arg =~ /^\s*(\d+)\s+(.+)\s*$/) {
      $count = $1;
      $query = $2;
    }
    $count = 1 if $count < 1;
    $count = 5 if $count > 5;
    my $result = $self->_search_web($query, $count);
    $self->_send_to_channel($channel, $result) if defined($result) && $result =~ /\S/;
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
  my ( $nick, $host ) = split /!/, $nickstr, 2;
  return if $nick eq $self->get_nickname;
  $self->info("$channel $nick ($host) joined");
  $self->_last_activity(time());
  $self->_buffer_message(
    $channel,
    'system',
    Bot::Runtime::Presence::join_message(
      nick           => $nick,
      host           => $host,
      join_greet_pct => $self->_persona_trait('join_greet_pct'),
    ),
  );
};

event irc_part => sub {
  my ( $self, $nickstr, $channel, $reason ) = @_[ OBJECT, ARG0, ARG1, ARG2 ];
  my ( $nick, $host ) = split /!/, $nickstr, 2;
  return if $nick eq $self->get_nickname;
  $self->info("$channel $nick ($host) parted" . ($reason ? ": $reason" : ''));
  $self->_last_activity(time());
  my $msg = Bot::Runtime::Presence::part_message(
    nick   => $nick,
    host   => $host,
    reason => $reason,
  );
  $self->_buffer_message($channel, 'system', $msg);
};

event irc_quit => sub {
  my ( $self, $nickstr, $reason ) = @_[ OBJECT, ARG0, ARG1 ];
  my ( $nick, $host ) = split /!/, $nickstr, 2;
  return if $nick eq $self->get_nickname;
  $self->info("$nick ($host) quit" . ($reason ? ": $reason" : ''));
  $self->_last_activity(time());
  my $channel = $self->_default_channel;

  if (Bot::Runtime::Presence::is_netsplit_reason(reason => $reason)) {
    push @{$self->_netsplit_quits}, $nick;
    # Delay reporting — collect all netsplit quits in a short window
    POE::Kernel->delay( _netsplit_report => 3, $channel, $reason );
    return;
  }

  my $msg = Bot::Runtime::Presence::quit_message(
    nick   => $nick,
    host   => $host,
    reason => $reason,
  );
  $self->_buffer_message($channel, 'system', $msg);
};

event _netsplit_report => sub {
  my ( $self, $channel, $split_reason ) = @_[ OBJECT, ARG0, ARG1 ];
  my @nicks = @{$self->_netsplit_quits};
  return unless @nicks;
  $self->_netsplit_quits([]);
  $self->_buffer_message(
    $channel,
    'system',
    Bot::Runtime::Presence::netsplit_report_message(
      split_reason => $split_reason,
      nicks        => \@nicks,
    ),
  );
};

event irc_msg => sub {
  my ( $self, $nickstr, $recipients, $msg ) = @_[ OBJECT, ARG0, ARG1, ARG2 ];
  my ( $nick, $host ) = split /!/, $nickstr, 2;
  return if $nick eq $self->get_nickname;
  $self->info("PM <$nick> ($host) $msg");
  $self->_last_activity(time());
  my $channel = $self->_default_channel;
  $self->_buffer_message(
    $channel,
    'system',
    Bot::Runtime::Presence::private_message_message(
      nick => $nick,
      host => $host,
      msg  => $msg,
    ),
  );
};

event irc_whois => sub {
  my ( $self, $info ) = @_[ OBJECT, ARG0 ];
  my $notes = $self->memory->recall_notes($info->{nick}, '', 100);
  my $result = Bot::Runtime::Presence::whois_text(
    info  => $info,
    notes => $notes,
  );
  $self->info($result);
  my $channel = $self->_default_channel;
  $self->_buffer_message($channel, 'system', $result);
};

__PACKAGE__->run unless caller;
