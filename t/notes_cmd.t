use strict;
use warnings;
use Test::More;

require './treb.pl';

local $ENV{DB_FILE} = ':memory:';
my $obj = bless {}, 'BertBot';
my $dbh = $obj->memory->_dbh;
$dbh->do(q{INSERT INTO notes (nick, content) VALUES (?, ?)}, undef, 'mateu', 'likes practical tooling');
$dbh->do(q{INSERT INTO notes (nick, content) VALUES (?, ?)}, undef, 'mateu', 'prefers concise replies');

my $line = $obj->_notes_text('mateu');
like($line, qr/\[mateu\] likes practical tooling/, 'includes first note');
like($line, qr/\[mateu\] prefers concise replies/, 'includes second note');

my $none = $obj->_notes_text('nobody');
is($none, 'No notes for nobody.', 'empty nick returns friendly miss');

my $usage = $obj->_notes_text('   ');
is($usage, 'Usage: :notes <nick>', 'blank nick returns usage');

done_testing;
