use strict;
use warnings;
use Test::More;

use lib 'lib';
use Bot::Runtime::EntrypointConfig qw(build_persona_trait_config);

{
  local %ENV = %ENV;
  my ($meta, $order) = build_persona_trait_config();

  is_deeply(
    $order,
    [
      qw(
        join_greet_pct
        ambient_public_reply_pct
        public_thread_window_seconds
        bot_reply_pct
        bot_reply_max_turns
        non_substantive_allow_pct
      )
    ],
    'trait order matches shared runtime ordering',
  );

  is($meta->{ambient_public_reply_pct}{env}, 'PUBLIC_CHAT_ALLOW_PCT', 'ambient trait reads public chat env');
  is($meta->{ambient_public_reply_pct}{default}, 0, 'ambient default is 0');
  is($meta->{bot_reply_pct}{default}, 50, 'bot reply pct default is 50');
  is($meta->{bot_reply_max_turns}{default}, 1, 'bot reply max turns default is 1');
}

{
  local %ENV = %ENV;
  my ($meta) = build_persona_trait_config(
    defaults => {
      join_greet_pct              => 120,
      ambient_public_reply_pct    => -15,
      public_thread_window_seconds => -3.2,
      bot_reply_pct               => 42.9,
      bot_reply_max_turns         => 2.8,
      non_substantive_allow_pct   => 200,
    },
  );

  is($meta->{join_greet_pct}{default}, 100, 'join greet clamps to 100');
  is($meta->{ambient_public_reply_pct}{default}, 0, 'ambient clamps to 0');
  is($meta->{public_thread_window_seconds}{default}, 0, 'thread window clamps to non-negative int');
  is($meta->{bot_reply_pct}{default}, 42.9, 'bot reply pct preserves decimal');
  is($meta->{bot_reply_max_turns}{default}, 2, 'bot reply max turns coerces to int');
  is($meta->{non_substantive_allow_pct}{default}, 100, 'non-substantive clamps to 100');
}

done_testing;
