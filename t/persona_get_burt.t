use strict;
use warnings;
use Test::More;

local $ENV{DB_FILE} = 't/persona_get_burt.sqlite';
unlink $ENV{DB_FILE} if -f $ENV{DB_FILE};
local $ENV{IRC_NICKNAME} = 'Burt';
local $ENV{JOIN_GREET_PCT} = 23;

require './burt.pl';
my $bot = BurtBot->new();
$bot->_load_persona_settings;

is($bot->_persona_trait_text('join_greet_pct'), 'join_greet_pct=23', 'burt explicit trait read');
like($bot->_persona_trait_text('nope'), qr/^Unknown persona trait\./, 'burt unknown trait read');

done_testing;
