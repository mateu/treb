use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);

local $ENV{DB_FILE} = tempdir(CLEANUP => 1) . '/persona_get_burt.sqlite';
local $ENV{IRC_NICKNAME} = 'burt_bot';
local $ENV{BOT_IDENTITY_SLUG} = 'burt';
local $ENV{JOIN_GREET_PCT} = 23;

require './burt.pl';
my $bot = Bot::HouseBot->new();
$bot->_load_persona_settings;

is($bot->_persona_trait_text('join_greet_pct'), 'join_greet_pct=23', 'burt explicit trait read');
like($bot->_persona_trait_text('nope'), qr/^Unknown persona trait\./, 'burt unknown trait read');

done_testing;
