use strict;
use warnings;
use Test::More;

local $ENV{DB_FILE} = 't/persona_set_treb.sqlite';
unlink $ENV{DB_FILE} if -f $ENV{DB_FILE};
local $ENV{IRC_NICKNAME} = 'treb_bot';
local $ENV{BOT_IDENTITY_SLUG} = 'treb';
require './treb.pl';

my $bot = BertBot->new();
$bot->_load_persona_settings;

my ($ok, $msg) = $bot->_set_persona_trait('bot_reply_max_turns', '2');
ok($ok, 'treb accepts valid trait update');
is($msg, 'Set bot_reply_max_turns=2 for treb.', 'treb confirmation message');
is($bot->_persona_trait('bot_reply_max_turns'), 2, 'treb cache updated immediately');
my $stored = $bot->memory->get_persona_settings('treb');
is($stored->{bot_reply_max_turns}, 2, 'treb setting persisted to db');

($ok, $msg) = $bot->_set_persona_trait('nope_trait', '2');
ok(!$ok, 'treb rejects unknown trait');
like($msg, qr/^Unknown persona trait\./, 'treb unknown trait message');

($ok, $msg) = $bot->_set_persona_trait('bot_reply_pct', 'nope');
ok(!$ok, 'treb rejects non-integer');
is($msg, 'Value must be a non-negative integer.', 'treb integer validation message');

($ok, $msg) = $bot->_set_persona_trait('bot_reply_pct', '999');
ok($ok, 'treb accepts oversized integer and clamps');
is($bot->_persona_trait('bot_reply_pct'), 100, 'treb pct clamped to 100');

done_testing;
