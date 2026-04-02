use strict;
use warnings;
use Test::More;

local $ENV{DB_FILE} = 't/persona_output_treb.sqlite';
unlink $ENV{DB_FILE} if -f $ENV{DB_FILE};
local $ENV{IRC_NICKNAME} = 'treb_bot';
local $ENV{BOT_IDENTITY_SLUG} = 'treb';
local $ENV{JOIN_GREET_PCT} = 11;
local $ENV{PUBLIC_CHAT_ALLOW_PCT} = 22;
local $ENV{PUBLIC_THREAD_WINDOW_SECONDS} = 33;
local $ENV{BOT_REPLY_PCT} = 44;
local $ENV{BOT_REPLY_MAX_TURNS} = 5;
local $ENV{NON_SUBSTANTIVE_ALLOW_PCT} = 6;

require './treb.pl';
my $bot = BertBot->new();
$bot->_load_persona_settings;

my $summary = $bot->_persona_summary_text;
my $full = $bot->_persona_text;

like($summary, qr/^Persona \[treb\] /, 'treb summary header');
unlike($summary, qr/\n/, 'treb summary is one line');
like($summary, qr/join_greet=11/, 'treb summary join_greet');
like($summary, qr/ambient=22/, 'treb summary ambient');
like($summary, qr/thread_window=33/, 'treb summary thread_window');
like($summary, qr/bot_reply=44/, 'treb summary bot_reply');
like($summary, qr/bot_turns=5/, 'treb summary bot_turns');
like($summary, qr/non_substantive=6/, 'treb summary non_substantive');
like($full, qr/^Persona \[treb\]:/m, 'treb full header');
like($full, qr/join_greet_pct: 11/, 'treb full canonical names');
like($full, qr/non_substantive_allow_pct: 6/, 'treb full non_substantive label');

done_testing;
