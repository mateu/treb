use strict;
use warnings;
use Test::More;

local $ENV{DB_FILE} = 't/persona_preset_treb.sqlite';
unlink $ENV{DB_FILE} if -f $ENV{DB_FILE};
local $ENV{IRC_NICKNAME} = 'Treb';

require './treb.pl';
my $bot = BertBot->new();
$bot->_load_persona_settings;

my ($ok0, $line0) = $bot->_apply_persona_preset(0);
ok($ok0, 'preset 0 applied');
is($bot->_persona_trait('join_greet_pct'), 0, 'join_greet zeroed');
is($bot->_persona_trait('ambient_public_reply_pct'), 0, 'ambient zeroed');
is($bot->_persona_trait('public_thread_window_seconds'), 0, 'window zeroed');
is($bot->_persona_trait('bot_reply_max_turns'), 0, 'turns zeroed');
like($line0, qr/Applied persona preset 0:/, 'preset 0 confirmation');

my ($ok11, $line11) = $bot->_apply_persona_preset(11);
ok($ok11, 'preset 11 applied');
is($bot->_persona_trait('join_greet_pct'), 100, 'join_greet maxed');
is($bot->_persona_trait('ambient_public_reply_pct'), 100, 'ambient maxed');
is($bot->_persona_trait('bot_reply_pct'), 100, 'bot_reply maxed');
is($bot->_persona_trait('non_substantive_allow_pct'), 0, 'non_substantive preserved at conservative default');
is($bot->_persona_trait('bot_reply_max_turns'), 11, 'turns set from preset');
is($bot->_persona_trait('public_thread_window_seconds'), 60, 'window fixed to 60');
like($line11, qr/Applied persona preset 11:/, 'preset 11 confirmation');
my ($ok3, $line3) = $bot->_apply_persona_preset("3\x0f");
ok($ok3, 'control-char wrapped preset still applies');
is($bot->_persona_trait('bot_reply_max_turns'), 3, 'turns set from normalized preset');
like($line3, qr/Applied persona preset 3:/, 'normalized preset confirmation');

done_testing;
