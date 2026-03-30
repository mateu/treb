use strict;
use warnings;
use Test::More;

local $ENV{DB_FILE} = 't/persona_set_burt.sqlite';
unlink $ENV{DB_FILE} if -f $ENV{DB_FILE};
local $ENV{IRC_NICKNAME} = 'Burt';
require './burt.pl';

my $bot = BurtBot->new();
$bot->_load_persona_settings;

my ($ok, $msg) = $bot->_set_persona_trait('ambient_public_reply_pct', '17');
ok($ok, 'burt accepts valid trait update');
is($msg, 'Set ambient_public_reply_pct=17 for burt.', 'burt confirmation message');
is($bot->_persona_trait('ambient_public_reply_pct'), 17, 'burt cache updated immediately');
my $stored = $bot->memory->get_persona_settings('burt');
is($stored->{ambient_public_reply_pct}, 17, 'burt setting persisted to db');

($ok, $msg) = $bot->_set_persona_trait('bot_reply_max_turns', '999');
ok($ok, 'burt accepts large integer');
is($bot->_persona_trait('bot_reply_max_turns'), 999, 'burt integer trait is not pct-clamped');

done_testing;
