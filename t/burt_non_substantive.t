use strict;
use warnings;
use Test::More;

local $ENV{DB_FILE} = 't/burt_non_substantive.sqlite';
unlink $ENV{DB_FILE} if -f $ENV{DB_FILE};
local $ENV{IRC_NICKNAME} = 'burt_bot';
local $ENV{BOT_IDENTITY_SLUG} = 'burt';

require './burt.pl';
my $bot = BurtBot->new();

ok($bot->_is_trivial_parenthetical('( ... )'), 'dot parenthetical is trivial');
ok($bot->_is_trivial_parenthetical('(…)'), 'unicode ellipsis parenthetical is trivial');
ok($bot->_is_trivial_parenthetical('(pause)'), 'pause parenthetical is trivial');
ok(!$bot->_is_trivial_parenthetical('(the chickens are in, by the way)'), 'real content parenthetical not trivial');
ok($bot->_is_non_substantive_output('( ... )'), 'trivial parenthetical is non-substantive');
ok($bot->_is_non_substantive_output('(Silent - Treb\'s greeting is bot-to-bot banter, no human involved.)'), 'silent policy narration is non-substantive');
ok($bot->_is_non_substantive_output('(Silent - continuing bot-to-bot banter without human involvement.)'), 'continued silent-policy narration is non-substantive');
ok($bot->_is_non_substantive_output('(Silence from the attic.)'), 'attic silence line is non-substantive');
ok($bot->_is_non_substantive_output('(The attic holds its peace.)'), 'attic peace line is non-substantive');
ok(!$bot->_is_non_substantive_output('mateu: the chickens are in ok.'), 'substantive line not non-substantive');

done_testing;
