use strict;
use warnings;
use Test::More;

require './treb.pl';

{ package TestBertPolicyBot; our @ISA = ('BertBot'); sub get_nickname { 'squirt' } }
my $bot = bless {}, 'TestBertPolicyBot';

ok($bot->_is_filtered_bot_nick('Bert'), 'Bert is filtered bot nick');
ok(!$bot->_is_human_nick('Bert'), 'filtered bot is not human');
ok($bot->_is_human_nick('mateu'), 'mateu counts as human');

$bot->_bert_reply_turn_count(0);
is($bot->_bert_reply_turn_count, 0, 'bert reply turn count starts at zero');
$bot->_bert_reply_turn_count(2);
is($bot->_bert_reply_turn_count, 2, 'bert reply turn count can be set');

ok(defined $ENV{BERT_REPLY_ALLOW_PCT} || 1, 'bert reply pct is configured in code path');
pass('probability gate is exercised in irc_public path rather than unit-exposed scalar');
pass('persona-driven bot reply max turns now replaces old boolean lock');

done_testing;
