use strict;
use warnings;
use Test::More;

require './treb.pl';

local $ENV{DB_FILE} = ':memory:';
my $obj = bless {}, 'BertBot';
my $memory = $obj->memory;
my $dbh = $memory->_dbh;

$dbh->do(q{INSERT INTO conversations (nick, message, response, channel) VALUES (?,?,?,?)}, undef, 'mateu', 'hello', 'hi', '#test');
$dbh->do(q{INSERT INTO conversations (nick, message, response, channel) VALUES (?,?,?,?)}, undef, 'system', 'idle', 'silent', '#test');
$dbh->do(q{INSERT INTO notes (nick, content) VALUES (?, ?)}, undef, 'mateu', 'likes practical tooling');

my $line = $obj->_db_stats_text;
like($line, qr/DB: :memory:/, 'includes db path');
like($line, qr/conversations: 2/, 'counts conversations');
like($line, qr/notes: 1/, 'counts notes');
like($line, qr/channels: 1/, 'counts channels');
like($line, qr/system rows: 1/, 'counts system rows');
like($line, qr/latest:/, 'includes latest timestamp field');

done_testing;
