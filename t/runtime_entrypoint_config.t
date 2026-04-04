use strict;
use warnings;
use Test::More;

use lib 'lib';
use Bot::Runtime::EntrypointConfig qw(
  default_bot_names
  load_entrypoint_config
  persona_trait_order
  persona_trait_meta
);

my @names = default_bot_names();
ok(@names >= 10, 'default bot names list is populated');
ok(grep { $_ eq 'Botsworth' } @names, 'default bot names include expected seed name');

{
  local $ENV{IRC_NICKNAME} = 'TeStBot';
  local $ENV{BOT_IDENTITY_SLUG} = 'MiXeD-Slug';
  local $ENV{OWNER} = '';
  local $ENV{USER} = 'sysuser';
  local $ENV{MAX_LINE_LENGTH} = 480;
  local $ENV{BUFFER_DELAY} = '2.5';
  local $ENV{LINE_DELAY} = 4;
  local $ENV{IDLE_PING} = 900;

  my $cfg = load_entrypoint_config();
  is($cfg->{bot_nick}, 'TeStBot', 'load_entrypoint_config prefers IRC_NICKNAME');
  is($cfg->{bot_identity_slug}, 'mixed-slug', 'identity slug is normalized to lowercase');
  is($cfg->{owner}, 'sysuser', 'owner falls back to USER when OWNER is empty');
  is($cfg->{max_line}, 480, 'max_line reads env override');
  is($cfg->{buffer_delay}, '2.5', 'buffer delay reads numeric env override');
  is($cfg->{line_delay}, 4, 'line delay reads env override');
  is($cfg->{idle_ping}, 900, 'idle ping reads env override');
}

{
  local $ENV{IRC_NICKNAME} = '';
  local $ENV{BOT_IDENTITY_SLUG} = '';
  local $ENV{OWNER} = '';
  local $ENV{USER} = '';
  local $ENV{MAX_LINE_LENGTH} = '';
  local $ENV{BUFFER_DELAY} = '';
  local $ENV{LINE_DELAY} = '';
  local $ENV{IDLE_PING} = '';

  my $cfg = load_entrypoint_config(default_nick => 'FallbackNick');
  is($cfg->{bot_nick}, 'FallbackNick', 'default_nick used when IRC_NICKNAME unset');
  is($cfg->{bot_identity_slug}, 'fallbacknick', 'identity slug derives from fallback nick');
  is($cfg->{owner}, 'unknown', 'owner defaults to unknown with no OWNER/USER');
  is($cfg->{max_line}, 400, 'max_line defaults to 400');
  is($cfg->{buffer_delay}, '1.5', 'buffer delay defaults to 1.5');
  is($cfg->{line_delay}, 3, 'line delay defaults to 3');
  is($cfg->{idle_ping}, 1800, 'idle ping defaults to 1800');
}

{
  local $ENV{BUFFER_DELAY} = 'bogus';
  local $ENV{MAX_LINE_LENGTH} = 0;
  my $cfg = load_entrypoint_config();
  is($cfg->{buffer_delay}, 1.5, 'non-numeric BUFFER_DELAY falls back to default');
  is($cfg->{max_line}, 1, 'MAX_LINE_LENGTH is clamped to minimum of 1');
}

{
  local $ENV{MAX_LINE_LENGTH} = -25;
  my $cfg = load_entrypoint_config();
  is($cfg->{max_line}, 1, 'negative MAX_LINE_LENGTH is clamped to minimum of 1');
}

my @order = persona_trait_order();
is_deeply(
  \@order,
  [qw(join_greet_pct ambient_public_reply_pct public_thread_window_seconds bot_reply_pct bot_reply_max_turns non_substantive_allow_pct)],
  'persona trait order remains stable',
);

my $base_meta = persona_trait_meta();
is($base_meta->{join_greet_pct}{default}, 100, 'base join_greet default preserved');
is($base_meta->{ambient_public_reply_pct}{default}, 0, 'base ambient default preserved');
is($base_meta->{bot_reply_pct}{default}, 50, 'base bot_reply default preserved');
is($base_meta->{bot_reply_max_turns}{default}, 1, 'base bot_reply_max_turns default preserved');
is($base_meta->{public_thread_window_seconds}{env}, 'PUBLIC_THREAD_WINDOW_SECONDS', 'thread-window env mapping preserved');

my $burt_meta = persona_trait_meta(defaults => {
  ambient_public_reply_pct => 50,
  public_thread_window_seconds => 45,
  bot_reply_pct => 25,
});
is($burt_meta->{ambient_public_reply_pct}{default}, 50, 'override supports ambient public reply default');
is($burt_meta->{public_thread_window_seconds}{default}, 45, 'override supports thread-window default');
is($burt_meta->{bot_reply_pct}{default}, 25, 'override supports bot-reply default');
is($burt_meta->{bot_reply_max_turns}{default}, 1, 'unspecified defaults remain unchanged');

my $normalized_meta = persona_trait_meta(defaults => {
  join_greet_pct               => 120,
  ambient_public_reply_pct     => -15,
  public_thread_window_seconds => -3.2,
  bot_reply_pct                => 42.9,
  bot_reply_max_turns          => 2.8,
  non_substantive_allow_pct    => 200,
});
is($normalized_meta->{join_greet_pct}{default}, 100, 'join greet clamps to 100');
is($normalized_meta->{ambient_public_reply_pct}{default}, 0, 'ambient clamps to 0');
is($normalized_meta->{public_thread_window_seconds}{default}, 0, 'thread window clamps to non-negative int');
is($normalized_meta->{bot_reply_pct}{default}, 42, 'bot reply pct coerces to int');
is($normalized_meta->{bot_reply_max_turns}{default}, 2, 'bot reply max turns coerces to int');
is($normalized_meta->{non_substantive_allow_pct}{default}, 100, 'non-substantive clamps to 100');

done_testing;
