use strict;
use warnings;
use Test::More;

use lib 'lib';
use Bot::Runtime::Dispatch qw(
  parse_public_addressee
  is_public_message_addressed_to_self
  send_to_channel
  is_filtered_bot_nick
  default_channel
  utility_command_matches_me
);

{
  package Local::DispatchBot;

  sub new {
    my ($class, %args) = @_;
    return bless {
      nickname => $args{nickname} || 'Bert',
      channels => $args{channels},
    }, $class;
  }

  sub get_nickname { $_[0]->{nickname} }
  sub get_channels { $_[0]->{channels} }
}

my ($target, $body) = parse_public_addressee(msg => 'bert: hello there');
is($target, 'bert', 'parse_public_addressee captures nick with colon syntax');
is($body, 'hello there', 'parse_public_addressee captures body with colon syntax');

($target, $body) = parse_public_addressee(msg => 'Astrid what time is it in Denver?', self => Local::DispatchBot->new(nickname => 'Astrid_bot'));
is($target, 'Astrid', 'parse_public_addressee captures plain leading-name syntax for bot aliases');
is($body, 'what time is it in Denver?', 'parse_public_addressee captures body after plain leading name');

($target, $body) = parse_public_addressee(msg => 'hey burt, you awake?');
is($target, 'burt', 'parse_public_addressee captures hey syntax target');
is($body, 'you awake?', 'parse_public_addressee captures hey syntax body');

($target, $body) = parse_public_addressee(msg => 'Astrid! Kitchen duty today?');
is($target, 'Astrid', 'parse_public_addressee captures bang-address syntax');
is($body, 'Kitchen duty today?', 'parse_public_addressee captures bang-address body');

($target, $body) = parse_public_addressee(msg => 'Hey Astrid! Kitchen duty today?');
is($target, 'Astrid', 'parse_public_addressee captures hey+bang syntax');
is($body, 'Kitchen duty today?', 'parse_public_addressee captures hey+bang body');

($target, $body) = parse_public_addressee(msg => 'just chatting');
ok(!defined $target && !defined $body, 'parse_public_addressee returns undef pair when not addressed');

my $bot = Local::DispatchBot->new(nickname => 'Bert_bot');
ok(is_public_message_addressed_to_self(self => $bot, msg => 'bert_bot: status?'), 'is_public_message_addressed_to_self matches visible nick case-insensitively');
ok(is_public_message_addressed_to_self(self => $bot, msg => 'Bert status?'), 'is_public_message_addressed_to_self matches short plain-name addressing');
ok(is_public_message_addressed_to_self(self => $bot, msg => 'Hey Bert! status?'), 'is_public_message_addressed_to_self matches hey+bang short-name addressing');
ok(!is_public_message_addressed_to_self(self => $bot, msg => 'astrid: status?'), 'is_public_message_addressed_to_self rejects other nicks');

local $ENV{BOT_FILTER_NICKS};
ok(is_filtered_bot_nick(nick => 'burt_bot', default_filter_nicks => 'burt_bot'), 'default bot filter list applies when env is unset');
ok(!is_filtered_bot_nick(nick => 'mateu', default_filter_nicks => 'burt_bot'), 'unknown nick is not filtered');

local $ENV{BOT_FILTER_NICKS} = 'a_bot, b_bot';
ok(is_filtered_bot_nick(nick => 'B_BOT', default_filter_nicks => ''), 'env filter list matches case-insensitively');
ok(!is_filtered_bot_nick(nick => 'burt_bot', default_filter_nicks => 'burt_bot'), 'env filter list overrides default list');

is(default_channel(self => Local::DispatchBot->new(channels => ['#ai', '#perl'])), '#ai', 'default_channel returns first configured channel');
is(default_channel(self => Local::DispatchBot->new(channels => '#solo')), '#solo', 'default_channel returns scalar channel unchanged');

ok(utility_command_matches_me(self => $bot, target => 'bert', allow_bare => 0), 'utility command target matches short nickname alias');
ok(utility_command_matches_me(self => $bot, target => 'bert_bot', allow_bare => 0), 'utility command target matches visible nickname');
ok(!utility_command_matches_me(self => $bot, target => 'astrid', allow_bare => 1), 'utility command target must match nickname when provided');
ok(utility_command_matches_me(self => $bot, allow_bare => 1), 'utility command allows bare usage when configured');
ok(!utility_command_matches_me(self => $bot, allow_bare => 0), 'utility command rejects bare usage when disabled');

my @scheduled;
{
  no warnings 'redefine';
  local *POE::Kernel::delay_add = sub {
    my ($class, @args) = @_;
    push @scheduled, \@args;
    return scalar @scheduled;
  };

  my $elapsed = send_to_channel(
    channel           => '#ai',
    text              => "first line...\nsecond line",
    max_line          => 50,
    return_cumulative => 1,
  );

  is(scalar @scheduled, 2, 'send_to_channel schedules one event per non-empty line');
  is($scheduled[0][0], '_send_line', 'send_to_channel uses default event name');
  is($scheduled[0][2], '#ai', 'send_to_channel passes channel');
  is($scheduled[0][3], 'first line...', 'send_to_channel preserves first line text');
  is($scheduled[1][3], 'second line', 'send_to_channel preserves second line text');
  ok($scheduled[1][1] > $scheduled[0][1], 'send_to_channel accumulates delay over chunks');
  ok($elapsed >= $scheduled[1][1], 'send_to_channel returns cumulative delay when requested');
}

@scheduled = ();
{
  no warnings 'redefine';
  local *POE::Kernel::delay_add = sub {
    my ($class, @args) = @_;
    push @scheduled, \@args;
    return scalar @scheduled;
  };

  send_to_channel(
    channel    => '#ai',
    text       => 'abcdefghij klmnopqrst',
    max_line   => 10,
    event_name => '_custom_send',
  );

  ok(scalar(@scheduled) >= 2, 'send_to_channel splits long lines with max_line');
  is($scheduled[0][0], '_custom_send', 'send_to_channel respects custom event name');
}

# Validate max_line guards against infinite-loop-inducing values
for my $bad_max_line (0, -1, 'abc') {
  eval {
    send_to_channel(
      channel  => '#test',
      text     => 'hello',
      max_line => $bad_max_line,
    );
  };
  like($@, qr/positive integer/, "send_to_channel dies on invalid max_line: '$bad_max_line'");
}

done_testing;
