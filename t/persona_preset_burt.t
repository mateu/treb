use strict;
use warnings;
use Test::More;

local $ENV{DB_FILE} = 't/persona_preset_burt.sqlite';
unlink $ENV{DB_FILE} if -f $ENV{DB_FILE};
local $ENV{IRC_NICKNAME} = 'Burt';

require './burt.pl';
my $bot = BurtBot->new();

# Test preset 0 (silent)
my ($ok0, $line0) = $bot->_apply_persona_preset(0);
ok($ok0, 'preset 0 applied');
is($bot->_persona_trait('join_greet_pct'), 0, 'silent: join_greet 0');
is($bot->_persona_trait('ambient_public_reply_pct'), 0, 'silent: ambient 0');
is($bot->_persona_trait('bot_reply_pct'), 0, 'silent: bot_reply 0');
is($bot->_persona_trait('bot_reply_max_turns'), 0, 'silent: turns 0');
is($bot->_persona_trait('public_thread_window_seconds'), 0, 'silent: window 0');

# Test preset 3 (mid-low: 30%)
my ($ok3, $line3) = $bot->_apply_persona_preset(3);
ok($ok3, 'preset 3 applied');
is($bot->_persona_trait('join_greet_pct'), 30, 'preset 3: join_greet 30');
is($bot->_persona_trait('ambient_public_reply_pct'), 30, 'preset 3: ambient 30');
is($bot->_persona_trait('bot_reply_pct'), 30, 'preset 3: bot_reply 30');
is($bot->_persona_trait('bot_reply_max_turns'), 3, 'preset 3: turns 3');
is($bot->_persona_trait('public_thread_window_seconds'), 27, 'preset 3: window 27');

# Test preset 5 (mid: 50%)
my ($ok5, $line5) = $bot->_apply_persona_preset(5);
ok($ok5, 'preset 5 applied');
is($bot->_persona_trait('join_greet_pct'), 50, 'preset 5: join_greet 50');
is($bot->_persona_trait('ambient_public_reply_pct'), 50, 'preset 5: ambient 50');
is($bot->_persona_trait('bot_reply_pct'), 50, 'preset 5: bot_reply 50');
is($bot->_persona_trait('bot_reply_max_turns'), 5, 'preset 5: turns 5');
is($bot->_persona_trait('public_thread_window_seconds'), 45, 'preset 5: window 45');

# Test preset 7 (high: 70%)
my ($ok7, $line7) = $bot->_apply_persona_preset(7);
ok($ok7, 'preset 7 applied');
is($bot->_persona_trait('join_greet_pct'), 70, 'preset 7: join_greet 70');
is($bot->_persona_trait('ambient_public_reply_pct'), 70, 'preset 7: ambient 70');
is($bot->_persona_trait('bot_reply_pct'), 70, 'preset 7: bot_reply 70');
is($bot->_persona_trait('bot_reply_max_turns'), 7, 'preset 7: turns 7');
is($bot->_persona_trait('public_thread_window_seconds'), 51, 'preset 7: window 51');

# Test preset 11 (max: 100%)
my ($ok11, $line11) = $bot->_apply_persona_preset(11);
ok($ok11, 'preset 11 applied');
is($bot->_persona_trait('join_greet_pct'), 100, 'preset 11: join_greet 100');
is($bot->_persona_trait('ambient_public_reply_pct'), 100, 'preset 11: ambient 100');
is($bot->_persona_trait('bot_reply_pct'), 100, 'preset 11: bot_reply 100');
is($bot->_persona_trait('bot_reply_max_turns'), 11, 'preset 11: turns 11');
is($bot->_persona_trait('public_thread_window_seconds'), 60, 'preset 11: window 60');
is($bot->_persona_trait('non_substantive_allow_pct'), 0, 'preset 11: non_substantive preserved at 0');

# Test confirmation messages
like($line0, qr/Applied persona preset 0:/, 'preset 0 confirmation');
like($line5, qr/Applied persona preset 5:/, 'preset 5 confirmation');
like($line11, qr/Applied persona preset 11:/, 'preset 11 confirmation');

# Test invalid input
my ($okX, $lineX) = $bot->_apply_persona_preset("abc");
ok(!$okX, 'invalid preset rejected');
like($lineX, qr/must be a non-negative integer/, 'invalid preset error message');

done_testing;