use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use JSON::PP qw(decode_json);
use lib 'lib';
use Bot::MemoryStore;
use Bot::Runtime::Reminders;
{
  package ReminderBot;
  sub new { bless {memory=>$_[1],channels=>{},buffer=>[],processing=>0},$_[0] }
  sub memory { $_[0]{memory} }
  sub _bot_name_slug { 'burt' }
  sub _default_channel { '#first' }
  sub get_channels { ['#first','#second'] }
  sub _pending_raid { +{channel=>'#second'} }
  sub _reminder_channels { $_[0]{channels} }
  sub _processing { $_[0]{processing} }
  sub info { }
  sub _buffer_message { my ($s,@args)=@_; return if $s->{reject}; push @{$s->{buffer}},\@args; return 1 }
  package ReminderTool;
  sub text_result { $_[1] }
}
local $ENV{IRC_SERVER}='irc.test';
my $dir=tempdir(CLEANUP=>1);
my $path="$dir/reminders.sqlite";
my $store=Bot::MemoryStore->new(db_file=>$path);
my $bot=ReminderBot->new($store);
my $tool=bless {},'ReminderTool';
my %tools=map {$_->{name}=>$_} @{Bot::Runtime::Reminders::tool_specs($bot)};
sub call { my ($name,%args)=@_; $tools{$name}{code}->($tool,\%args) }
sub scope { (bot=>'burt',channel=>'#second') }
my $r=decode_json(call('set_alarm',reason=>' tea ',delay_seconds=>2));
ok($r->{id},'set returns stable reminder ID');
is($r->{channel},'#second','uses originating channel, not default');
cmp_ok(abs($r->{due_at}-time()-10),'<=',1,'minimum delay normalized');
my $list=decode_json(call('list_alarms'));
is($list->[0]{reason},'tea','trimmed reason persisted');
is(decode_json(call('set_alarm',reason=>'default',delay_seconds=>'oops'))->{state},'armed','legacy invalid delay uses default');
my $long=decode_json(call('set_alarm',reason=>'long',delay_seconds=>99999999));
cmp_ok(abs($long->{due_at}-time()-2592000),'<=',1,'delay capped at 30 days');
like(call('set_alarm',reason=>' ',delay_seconds=>30),qr/Error: Reason/,'empty reason rejected');
like(call('set_alarm',reason=>'x'x1001,delay_seconds=>30),qr/Error: Reason/,'oversized reason rejected');
like(call('set_alarm',reason=>'bad',channel=>'nick'),qr/Error: Channel/,'PM scope rejected');
like(call('list_alarms',network=>'other'),qr/Error: Unknown/,'model cannot override network');
like(call('cancel_alarm',id=>$r->{id},channel=>'#first'),qr/not found/,'cannot cancel across channels');
is_deeply($store->list_reminders(bot=>'astrid',channel=>'#second'),[],'bot identities isolated');
is_deeply($store->list_reminders(scope(),network=>'other'),[],'networks isolated');
is_deeply(decode_json(call('list_alarms',limit=>1,cursor=>$long->{id}))->[0]{id},$long->{id}-1,'pagination returns previous ID');
$store->_dbh->do('UPDATE reminders SET due_at=? WHERE id=?',undef,time()-20,$r->{id});
# Separate connection proves persistence and simulates a fresh process.
my $reopened=Bot::MemoryStore->new(db_file=>$path);
is($reopened->list_reminders(scope())->[-1]{id},$r->{id},'stable ID survives reopen');
my $claimed=$reopened->claim_due_reminders(scope());
is(scalar @$claimed,1,'restart recovers overdue reminder');
is($claimed->[0]{id},$r->{id},'correct recovered ID');
is_deeply($store->claim_due_reminders(scope()),[],'second connection cannot duplicate active claim');
$store->_dbh->do('UPDATE reminders SET lease_until=? WHERE id=?',undef,time()-1,$r->{id});
is(scalar @{$store->claim_due_reminders(scope())},1,'crashed queue claim recovers after lease expiry');
is(decode_json(call('cancel_alarm',id=>$r->{id}))->{state},'cancelled','queued reminder can be cancelled');
ok(!$store->consume_reminder(scope(),id=>$r->{id}),'cancelled volatile wake suppressed before model');
$store->_dbh->do('UPDATE reminders SET due_at=? WHERE id=?',undef,time()-3601,$long->{id});
is($store->list_reminders(scope())->[0]{state},'expired','older than one hour overdue expires');
is_deeply($store->claim_due_reminders(scope()),[],'expired/cancelled never wake');
my $due=$store->create_reminder(scope(),reason=>'wake',delay_seconds=>10);
$store->_dbh->do('UPDATE reminders SET due_at=? WHERE id=?',undef,time()-1,$due->{id});
my @timers;
{
  no warnings 'redefine';
  local *POE::Kernel::delay=sub { shift; push @timers,[@_] };
  Bot::Runtime::Reminders::poll($bot);
  is(scalar @{$bot->{buffer}},0,'not joined: no wake');
  $bot->{channels}{'#second'}=1;
  $bot->{reject}=1;
  Bot::Runtime::Reminders::poll($bot);
  is($store->list_reminders(scope())->[0]{state},'armed','queue rejection releases persisted claim');
  $bot->{reject}=0; $bot->{processing}=1;
  Bot::Runtime::Reminders::poll($bot);
  is(scalar @{$bot->{buffer}},0,'busy runtime does not claim wake');
  $bot->{processing}=0;
  Bot::Runtime::Reminders::poll($bot);
  is(scalar @{$bot->{buffer}},1,'joined channel accepts wake');
  is($bot->{buffer}[0][0],'#second','wake preserves channel');
  is($bot->{buffer}[0][3]{reminder_id},$due->{id},'buffer includes durable ID');
  Bot::Runtime::Reminders::poll($bot);
  is(scalar @{$bot->{buffer}},1,'subsequent poll does not duplicate wake');
  ok($store->consume_reminder(scope(),id=>$due->{id}),'wake admitted to evaluation');
  ok(!$reopened->consume_reminder(scope(),id=>$due->{id}),'cannot consume twice across connections');
  like(call('cancel_alarm',id=>$due->{id}),qr/not found/,'cannot cancel evaluation already admitted');
}
is_deeply($timers[-1],['_reminder_tick',10],'single named timer rescheduled');
for (1..20) { $store->create_reminder(bot=>'limit',channel=>'#second',reason=>'bounded',delay_seconds=>10) }
ok(!eval {$store->create_reminder(bot=>'limit',channel=>'#second',reason=>'overflow',delay_seconds=>10);1},'active count bounded');
like($@,qr/Maximum 20/,'capacity rejection explicit');
$store->save_note('Alice','existing note');
like($store->recall_notes('Alice','existing'),qr/existing note/,'existing memory tables preserved');
is($store->_dbh->selectrow_array('PRAGMA integrity_check'),'ok','SQLite integrity intact');
done_testing;
