use strict;
use warnings;
use utf8;
use Test::More;
use File::Temp qw(tempdir);
use JSON::PP qw(decode_json);
use lib 'lib';
use Bot::MemoryStore;
use Bot::IRCIdentity qw(irc_fold);

my $dir=tempdir(CLEANUP=>1);
local $ENV{IRC_SERVER}='irc.test';
local $ENV{IRC_CASEMAPPING}='rfc1459';
my $db="$dir/events.sqlite";
my $mem=Bot::MemoryStore->new(db_file=>$db);
sub fails (&$) {my ($code,$pattern)=@_; eval {$code->()}; like($@,$pattern,'invalid input rejected');}
sub record {my (%a)=@_; $mem->record_public_message(channel=>'#ai',nick=>'Alice',message=>'hello',%a)}
sub search { $mem->search_quotes(channel=>'#ai',@_) }

is(irc_fold('A[\\^'),'a{|~','RFC1459 casemapping');
is(irc_fold('A[\\^','strict-rfc1459'),'a{|^','strict mapping preserves caret');
is(irc_fold('A[\\^','ascii'),'a[\\^','ASCII mapping');
my $one=record(message=>'  Literal 100% _ café ☃  ');
my $blank=record(message=>'   ');
is(search(text=>'   ')->{results}[0]{message}{message},'   ','whitespace-only IRC messages remain verbatim');
my $two=record(nick=>'Bob',message=>'neighbor');
my $three=record(nick=>'ALICE',message=>'second');
record(channel=>'#else',nick=>'Alice',message=>'secret elsewhere');
record(network=>'else.test',message=>'other network');
my $out=record(nick=>'burt_bot',message=>'actual outgoing line',direction=>'out');
my $result=search(nick=>'alice',text=>'100% _',neighbors=>2);
is(scalar @{$result->{results}},1,'literal substring, not SQL wildcards');
is($result->{results}[0]{message}{message},'  Literal 100% _ café ☃  ','exact text and Unicode retained');
is($result->{results}[0]{message}{id},$one,'stable provenance ID');
is_deeply([map {$_->{id}} @{$result->{results}[0]{neighbors}}],[$blank,$two],'neighbors stay in scope');
like($result->{results}[0]{message}{utc},qr/^\d{4}-\d\d-\d\dT.*Z$/,'UTC timestamp');
is(scalar @{search(text=>"' OR 1=1 --")->{results}},0,'SQL stays data');
is(scalar @{search(nick=>'Alice')->{results}},3,'network and channel isolated');
is(search(text=>'outgoing')->{results}[0]{message}{direction},'out','sent lines searchable');
my $page=search(nick=>'Alice',limit=>1);
is($page->{next_cursor},$one,'continuation cursor provided');
is(search(nick=>'Alice',limit=>1,cursor=>$page->{next_cursor})->{results}[0]{message}{id},$blank,'next page is stable');
$mem->_dbh->do('UPDATE public_messages SET received_at=0 WHERE id=?',undef,$one);
is(scalar @{search(from=>'1970-01-01T00:00:00Z',to=>'1970-01-01T00:00:00Z')->{results}},1,'date boundaries inclusive');
# UTC parsing must not depend on the process timezone.
{
  local $ENV{TZ}='America/Denver'; POSIX::tzset();
  is(scalar @{search(to=>'1970-01-01T00:00:00Z')->{results}},1,'UTC dates unaffected by local timezone');
}
POSIX::tzset();
fails {search(from=>'2026-02-30T00:00:00Z')} qr/Invalid UTC date/;
fails {search(from=>'today')} qr/Dates must be UTC/;
fails {search(from=>'2026-10-01T00:00:00Z',to=>'2025-10-01T00:00:00Z')} qr/from must not follow/;
fails {search(limit=>21)} qr/Invalid limit/;
fails {search(channel=>'Alice')} qr/public channel/;
like(search()->{notice},qr/offline gaps/,'incomplete coverage explicitly disclosed');

my %q=(channel=>'#ai',nick=>'Alice',question=>'Does X hold?',claim=>'X always holds',attribution=>'Burt hypothesis',falsifier=>'An observed counterexample',source_ids=>[$one]);
my $question=$mem->create_question(%q);
is($question->{status},'open','new question open');
is_deeply($question->{source_ids},[$one],'evidence persisted');
is($mem->list_questions(channel=>'#AI',nick=>'ALICE')->[0]{attribution},'Burt hypothesis','attribution retained across casemapped recall');
fails {$mem->create_question(%q,source_ids=>[$three+1])} qr/Source message/;
fails {$mem->create_question(%q,falsifier=>'')} qr/falsifier is required/;
fails {$mem->update_question(channel=>'#else',id=>$question->{id},status=>'resolved',resolution=>'counterexample')} qr/Question not found/;
fails {$mem->update_question(channel=>'#ai',id=>$question->{id},status=>'resolved',resolution=>'')} qr/resolution is required/;
$mem->update_question(channel=>'#ai',id=>$question->{id},status=>'resolved',resolution=>'Counterexample observed');
is_deeply($mem->list_questions(channel=>'#ai'),[],'resolved excluded from open recall');
is($mem->list_questions(channel=>'#ai',status=>'all')->[0]{resolution},'Counterexample observed','closed history queryable');
$mem->update_question(channel=>'#ai',id=>$question->{id},status=>'open',resolution=>'New uncertainty');

my $watch=$mem->create_activity_watch(channel=>'#ai',nick=>'ALICE',reason=>'revisit X',question_id=>$question->{id},cooldown_seconds=>60);
fails {$mem->create_activity_watch(channel=>'#ai',nick=>'Bob',reason=>'wrong',question_id=>$question->{id})} qr/same nick/;
is_deeply($mem->activity_wakes(channel=>'#ai',event_id=>$three),[],'old event cannot trigger new watch');
my $unrelated=record(nick=>'Bob');
is_deeply($mem->activity_wakes(channel=>'#ai',event_id=>$unrelated),[],'unrelated activity cannot trigger');
my $event=record(nick=>'Alice',message=>'back now');
my $wakes=$mem->activity_wakes(channel=>'#ai',event_id=>$event);
is(scalar @$wakes,1,'matching activity wakes');
is($wakes->[0]{event}{message},'back now','wake bound to exact event');
is($wakes->[0]{question}{id},$question->{id},'linked question included');
is_deeply($mem->activity_wakes(channel=>'#ai',event_id=>$event),[],'duplicate event cannot wake twice');
is_deeply($mem->activity_wakes(channel=>'#ai',event_id=>record()),[],'cooldown prevents per-line wake storm');
# A new store represents a restarted process. Pending work is durable, not just a POE timer.
$mem=Bot::MemoryStore->new(db_file=>$db);
is($mem->list_activity_watches(channel=>'#ai')->[0]{state},'pending','pending state survives restart');
$mem->_dbh->do('UPDATE activity_watches SET last_wake=last_wake-61');
my $retry=$mem->activity_wakes(channel=>'#ai',event_id=>record(message=>'still here'));
is(scalar @$retry,1,'restart retries pending wake on later activity');
$mem->update_activity_watch(channel=>'#ai',id=>$watch->{id},action=>'defer');
is($mem->list_activity_watches(channel=>'#ai')->[0]{state},'armed','deferral rearms watch');
is_deeply($mem->activity_wakes(channel=>'#ai',event_id=>record()),[],'deferral retains cooldown');
$mem->_dbh->do('UPDATE activity_watches SET last_wake=last_wake-61');
$mem->activity_wakes(channel=>'#ai',event_id=>record());
$mem->update_activity_watch(channel=>'#ai',id=>$watch->{id},action=>'complete');
is_deeply($mem->activity_wakes(channel=>'#ai',event_id=>record()),[],'completed one-shot never repeats');
fails {$mem->update_activity_watch(channel=>'#ai',id=>$watch->{id},action=>'defer')} qr/no longer active/;
my $expired=$mem->create_activity_watch(channel=>'#ai',nick=>'Alice',reason=>'expire');
$mem->_dbh->do('UPDATE activity_watches SET expires_at=0 WHERE id=?',undef,$expired->{id});
is_deeply($mem->activity_wakes(channel=>'#ai',event_id=>record()),[],'expired watch cannot wake');
is($mem->list_activity_watches(channel=>'#ai')->[0]{state},'expired','expiry recorded');
my $cancelled=$mem->create_activity_watch(channel=>'#ai',nick=>'Alice',reason=>'cancel');
$mem->update_activity_watch(channel=>'#ai',id=>$cancelled->{id},action=>'cancel');
is_deeply($mem->activity_wakes(channel=>'#ai',event_id=>record()),[],'cancelled watch cannot wake');
my $linked=$mem->create_activity_watch(channel=>'#ai',nick=>'Alice',reason=>'linked',question_id=>$question->{id});
$mem->update_question(channel=>'#ai',id=>$question->{id},status=>'withdrawn',resolution=>'Premise withdrawn');
is($mem->list_activity_watches(channel=>'#ai')->[0]{state},'cancelled','closing question cancels linked watch');
fails {$mem->create_activity_watch(channel=>'#ai',nick=>'Alice',reason=>'closed',question_id=>$question->{id})} qr/open question/;

$mem->save_note('Alice','legacy note');
like($mem->recall_notes('Alice',''),qr/legacy note/,'legacy notes unaffected');
$mem->store_conversation(nick=>'Alice',message=>'legacy exchange',response=>'yes',channel=>'#ai');
like($mem->recall('legacy'),qr/legacy exchange/,'legacy exchanges unaffected');
my $qpage=$mem->create_question(%q);
is($mem->list_questions(channel=>'#ai',status=>'all',limit=>1)->[0]{id},$qpage->{id},'newest question first');
is($mem->list_questions(channel=>'#ai',status=>'all',cursor=>$qpage->{id})->[0]{id},$question->{id},'closed question reachable by pagination');
my $wpage=$mem->list_activity_watches(channel=>'#ai',limit=>1);
is($mem->list_activity_watches(channel=>'#ai',cursor=>$wpage->[0]{id},limit=>1)->[0]{id},$cancelled->{id},'watch pagination reaches older records');

my $legacy="$dir/legacy.sqlite";
my $dbh=DBI->connect("dbi:SQLite:dbname=$legacy",'','',{RaiseError=>1});
$dbh->do('CREATE TABLE conversations (id INTEGER PRIMARY KEY,nick TEXT,message TEXT,response TEXT,channel TEXT,created_at DATETIME DEFAULT CURRENT_TIMESTAMP)');
$dbh->do("INSERT INTO conversations(nick,message,response,channel) VALUES('OldNick','original message','original reply','#ai')");
$dbh->disconnect;
my $upgraded=Bot::MemoryStore->new(db_file=>$legacy);
like($upgraded->recall('original'),qr/original message/,'additive schema upgrade preserves pre-existing conversations');
is_deeply($upgraded->search_quotes(channel=>'#ai')->{results},[],'legacy exchanges never misrepresented as verbatim events');
done_testing;
