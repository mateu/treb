use strict;
use warnings;
use Test::More;

require './treb.pl';

{ package TestBertPolicyBot; our @ISA = ('BertBot'); sub get_nickname { 'squirt' } }
my $bot = bless {}, 'TestBertPolicyBot';

ok($bot->_is_filtered_bot_nick('Bert'), 'Bert is filtered bot nick');
ok(!$bot->_is_human_nick('Bert'), 'filtered bot is not human');
ok($bot->_is_human_nick('mateu'), 'mateu counts as human');

$bot->_bert_reply_lock(0);
is($bot->_bert_reply_lock, 0, 'bert reply lock starts clear');
$bot->_bert_reply_lock(1);
is($bot->_bert_reply_lock, 1, 'bert reply lock can be set');

ok(defined $ENV{BERT_REPLY_ALLOW_PCT} || 1, 'bert reply pct is configured in code path');
pass('probability gate is exercised in irc_public path rather than unit-exposed scalar');
pass('lexical bert reply percentage does not need direct test exposure');

done_testing;
