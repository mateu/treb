package Bot::Runtime::EntrypointConfig;

use strict;
use warnings;

use Exporter 'import';

our @EXPORT_OK = qw(build_persona_trait_config);

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

sub build_persona_trait_config {
  my (%args) = @_;
  my $defaults = $args{defaults} || {};

  my $trait_meta = {
    join_greet_pct => {
      kind    => 'pct',
      env     => 'JOIN_GREET_PCT',
      default => _normalize_pct($defaults->{join_greet_pct} // 100),
    },
    ambient_public_reply_pct => {
      kind    => 'pct',
      env     => 'PUBLIC_CHAT_ALLOW_PCT',
      default => _normalize_pct($defaults->{ambient_public_reply_pct} // 0),
    },
    public_thread_window_seconds => {
      kind    => 'int',
      env     => 'PUBLIC_THREAD_WINDOW_SECONDS',
      default => _normalize_non_negative_int($defaults->{public_thread_window_seconds} // 0),
    },
    bot_reply_pct => {
      kind    => 'pct',
      env     => 'BOT_REPLY_PCT',
      default => _normalize_pct($defaults->{bot_reply_pct} // 50),
    },
    bot_reply_max_turns => {
      kind    => 'int',
      env     => 'BOT_REPLY_MAX_TURNS',
      default => _normalize_non_negative_int($defaults->{bot_reply_max_turns} // 1),
    },
    non_substantive_allow_pct => {
      kind    => 'pct',
      env     => 'NON_SUBSTANTIVE_ALLOW_PCT',
      default => _normalize_pct($defaults->{non_substantive_allow_pct} // 0),
    },
  };

  my $trait_order = [
    qw(
      join_greet_pct
      ambient_public_reply_pct
      public_thread_window_seconds
      bot_reply_pct
      bot_reply_max_turns
      non_substantive_allow_pct
    )
  ];

  return ($trait_meta, $trait_order);
}

1;
