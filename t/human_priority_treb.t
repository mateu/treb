use strict;
use warnings;
use Test::More;

BEGIN { require './treb.pl'; }

my $bot = BertBot->new();

my @mixed = (
  { nick => 'Alice', msg => 'Treb, help', source_kind => 'conversation' },
  { nick => 'system', msg => 'Burt joined' },
  { nick => 'Burt', msg => 'Treb, question', source_kind => 'bert_conversation' },
  { nick => 'Alice', msg => 'Treb, more context', source_kind => 'conversation' },
);

my ($active, $deferred) = $bot->_split_priority_messages(\@mixed);

is(scalar(@$active), 2, 'conversation lane kept active when present');
is(scalar(@$deferred), 2, 'non-conversation messages deferred when conversation present');
ok(!grep((($_->{source_kind}//'') eq 'bert_conversation') || $_->{nick} eq 'system', @$active), 'active batch excludes bot/system chatter');
ok(grep((($_->{source_kind}//'') eq 'bert_conversation'), @$deferred), 'bert conversation deferred');
ok(grep(($_->{nick}//'') eq 'system', @$deferred), 'system message deferred');

my @no_human = (
  { nick => 'system', msg => 'Burt joined' },
  { nick => 'Burt', msg => 'Treb, question', source_kind => 'bert_conversation' },
);

($active, $deferred) = $bot->_split_priority_messages(\@no_human);

is(scalar(@$active), 2, 'batch unchanged when no human conversation lane present');
is(scalar(@$deferred), 0, 'nothing deferred when no human conversation lane present');

my @only_human = (
  { nick => 'Alice', msg => 'Treb, first', source_kind => 'conversation' },
  { nick => 'Alice', msg => 'Treb, second', source_kind => 'conversation' },
);

($active, $deferred) = $bot->_split_priority_messages(\@only_human);

is(scalar(@$active), 2, 'multiple human conversation messages stay together');
is(scalar(@$deferred), 0, 'no deferral when all messages are priority lane');

done_testing;
