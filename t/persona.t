use strict;
use warnings;
use Test::More;
use DBI;

my $db = 't/persona.sqlite';
unlink $db if -f $db;

local $ENV{DB_FILE} = $db;
local $ENV{IRC_NICKNAME} = 'Treb';
local $ENV{JOIN_GREET_PCT} = 88;
local $ENV{PUBLIC_CHAT_ALLOW_PCT} = 12;
local $ENV{PUBLIC_THREAD_WINDOW_SECONDS} = 7;
local $ENV{BERT_REPLY_ALLOW_PCT} = 66;
local $ENV{BERT_REPLY_MAX_TURNS} = 3;
local $ENV{NON_SUBSTANTIVE_ALLOW_PCT} = 9;

require './treb.pl';
my $bot = BertBot->new();
$bot->_load_persona_settings;

is($bot->_persona_trait('join_greet_pct'), 88, 'join_greet_pct loaded');
is($bot->_persona_trait('ambient_public_reply_pct'), 12, 'ambient_public_reply_pct loaded');
is($bot->_persona_trait('public_thread_window_seconds'), 7, 'thread window loaded');
is($bot->_persona_trait('bot_reply_pct'), 66, 'bot_reply_pct loaded');
is($bot->_persona_trait('bot_reply_max_turns'), 3, 'bot_reply_max_turns loaded');
is($bot->_persona_trait('non_substantive_allow_pct'), 9, 'non_substantive_allow_pct loaded');
like($bot->_db_stats_text, qr/persona=\{.*join_greet_pct=88.*bot_reply_max_turns=3/s, 'dbstats includes persona');
like($bot->_persona_text, qr/Persona \[treb\]:/, 'persona header');

my $dbh = DBI->connect("dbi:SQLite:dbname=$db", '', '', { RaiseError => 1, sqlite_unicode => 1 });
my ($count) = $dbh->selectrow_array('SELECT COUNT(*) FROM persona_settings WHERE bot_name = ?', undef, 'treb');
ok($count >= 6, 'persona rows persisted');

done_testing;
