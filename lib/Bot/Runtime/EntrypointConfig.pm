package Bot::Runtime::EntrypointConfig;

use strict;
use warnings;

use Exporter 'import';
use Scalar::Util qw(looks_like_number);

our @EXPORT_OK = qw(
  default_bot_names
  load_entrypoint_config
  persona_trait_order
  persona_trait_meta
  build_persona_trait_config
  build_runtime_delegate_config
);

my @DEFAULT_BOT_NAMES = qw(
  Botsworth Clanky Sparky Fizz Gizmo Pixel Blip Rusty Ziggy Turbo
  Sprocket Widget Noodle Bleep Chomp Dingle Wobble Clunk Zippy Quirk
);

my @PERSONA_TRAIT_ORDER = qw(
  join_greet_pct
  ambient_public_reply_pct
  public_thread_window_seconds
  bot_reply_pct
  bot_reply_max_turns
  non_substantive_allow_pct
);

sub default_bot_names {
  return @DEFAULT_BOT_NAMES;
}

sub persona_trait_order {
  return @PERSONA_TRAIT_ORDER;
}

sub _env_string {
  my ($name, $default) = @_;
  my $value = $ENV{$name};
  return $default unless defined $value && $value ne '';
  return $value;
}

sub _env_number {
  my (%args) = @_;
  my $name    = $args{name}    // die '_env_number requires name';
  my $default = $args{default};
  my $raw = $ENV{$name};
  my $value = $default;

  if (defined $raw && $raw ne '' && looks_like_number($raw)) {
    $value = 0 + $raw;
  }

  if (defined $args{min} && $value < $args{min}) {
    $value = $args{min};
  }
  if (defined $args{max} && $value > $args{max}) {
    $value = $args{max};
  }

  return $value;
}

sub _normalize_pct {
  my ($value) = @_;
  $value = 0 + ($value // 0);
  $value = 0 if $value < 0;
  $value = 100 if $value > 100;
  return int($value);
}

sub _normalize_non_negative_int {
  my ($value) = @_;
  $value = 0 + ($value // 0);
  $value = 0 if $value < 0;
  return int($value);
}

sub load_entrypoint_config {
  my (%args) = @_;
  my $default_nick = $args{default_nick};

  my @names = default_bot_names();
  my $bot_nick = _env_string('IRC_NICKNAME', $default_nick || $names[rand @names] . int(rand(999)));

  return {
    bot_nick           => $bot_nick,
    bot_identity_slug  => lc(_env_string('BOT_IDENTITY_SLUG', $bot_nick || 'bot')),
    owner              => _env_string('OWNER', _env_string('USER', 'unknown')),
    max_line           => _env_number(name => 'MAX_LINE_LENGTH', default => 400, min => 1),
    buffer_delay       => _env_number(name => 'BUFFER_DELAY', default => 1.5),
    line_delay         => _env_number(name => 'LINE_DELAY', default => 3),
    idle_ping          => _env_number(name => 'IDLE_PING', default => 1800),
  };
}

sub persona_trait_meta {
  my (%args) = @_;
  my $defaults = $args{defaults} || {};

  return {
    join_greet_pct => {
      kind    => 'pct',
      env     => 'JOIN_GREET_PCT',
      default => _normalize_pct(
        exists $defaults->{join_greet_pct} ? $defaults->{join_greet_pct} : 100
      ),
    },
    ambient_public_reply_pct => {
      kind    => 'pct',
      env     => 'PUBLIC_CHAT_ALLOW_PCT',
      default => _normalize_pct(
        exists $defaults->{ambient_public_reply_pct} ? $defaults->{ambient_public_reply_pct} : 0
      ),
    },
    public_thread_window_seconds => {
      kind    => 'int',
      env     => 'PUBLIC_THREAD_WINDOW_SECONDS',
      default => _normalize_non_negative_int(
        exists $defaults->{public_thread_window_seconds} ? $defaults->{public_thread_window_seconds} : 0
      ),
    },
    bot_reply_pct => {
      kind    => 'pct',
      env     => 'BOT_REPLY_PCT',
      default => _normalize_pct(
        exists $defaults->{bot_reply_pct} ? $defaults->{bot_reply_pct} : 50
      ),
    },
    bot_reply_max_turns => {
      kind    => 'int',
      env     => 'BOT_REPLY_MAX_TURNS',
      default => _normalize_non_negative_int(
        exists $defaults->{bot_reply_max_turns} ? $defaults->{bot_reply_max_turns} : 1
      ),
    },
    non_substantive_allow_pct => {
      kind    => 'pct',
      env     => 'NON_SUBSTANTIVE_ALLOW_PCT',
      default => _normalize_pct(
        exists $defaults->{non_substantive_allow_pct} ? $defaults->{non_substantive_allow_pct} : 0
      ),
    },
  };
}

sub build_persona_trait_config {
  my (%args) = @_;
  my $trait_meta = persona_trait_meta(defaults => $args{defaults});
  my $trait_order = [ persona_trait_order() ];
  return ($trait_meta, $trait_order);
}

sub build_runtime_delegate_config {
  my (%args) = @_;

  my $bot_name_slug = defined $args{bot_name_slug} ? $args{bot_name_slug} : 'bot';
  my $trait_meta = $args{trait_meta} || {};
  my $trait_order = $args{trait_order} || [];
  my $max_line = $args{max_line};
  my $script_file = $args{script_file};
  die 'build_runtime_delegate_config requires max_line' unless defined $max_line;
  die 'build_runtime_delegate_config requires script_file' unless defined $script_file && length $script_file;

  my %config = (
    bot_name_slug    => $bot_name_slug,
    trait_meta       => $trait_meta,
    trait_order      => $trait_order,
    mcp_server_name  => $args{mcp_server_name} || ($bot_name_slug . '-tools'),
    owner            => defined $args{owner} ? $args{owner} : 'unknown',
    max_line         => $max_line,
    script_file      => $script_file,
  );

  if (defined $args{max_context_tokens}) {
    $config{max_context_tokens} = $args{max_context_tokens};
  }

  return \%config;
}

1;
