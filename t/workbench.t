use strict;
use warnings;
use Test::More;
use lib 'lib';
use Bot::Runtime::Workbench;
{
  package WorkbenchBot;
  sub _bot_name_slug { $_[0]{bot}//'burt' }
  sub get_nickname { 'burt_bot' }
  sub _is_human_nick { $_[1] ne 'system' && $_[1] ne 'other_bot' }
  sub _pending_raid { $_[0]{pending} }
  sub _send_to_channel { push @{$_[0]{sent}},$_[2] }
  package WorkbenchTool;
  sub text_result { $_[1] }
}
my $bot=bless {pending=>{channel=>'#ai',expires_at=>time+100,messages=>[
  {nick=>'mateu',source_kind=>'conversation',msg=>'burt_bot: write a Perl fizzbuzz script and post a gist'}]}},'WorkbenchBot';
local $ENV{BURT_WORKBENCH_SOCKET}='/not/a/socket';
local $ENV{IRC_SERVER}='irc.perl.org';
my $scope=Bot::Runtime::Workbench::request_scope($bot,0);
is($scope,Bot::Runtime::Workbench::request_scope($bot,1),'run and publish bind to same runtime request');
like($scope,qr/^[a-f0-9]{64}$/,'scope is bounded digest');
my $tool=bless {},'WorkbenchTool';
my %defs=map {$_->{name}=>$_} @{Bot::Runtime::Workbench::tool_specs($bot)};
is(scalar keys %defs,7,'seven narrow tools');
like($defs{publish_gist}{code}->($tool,{id=>'x',channel=>'#ai'}),qr/Invalid tool fields/,'model cannot choose scope/channel');
for my $case (
  ['private channel',sub {$_[0]{pending}{channel}='mateu'}],
  ['different channel',sub {$_[0]{pending}{channel}='#other'}],
  ['expired request',sub {$_[0]{pending}{expires_at}=time-1}],
  ['reminder wake',sub {$_[0]{pending}{messages}[0]{source_kind}='reminder'}],
  ['bot request',sub {$_[0]{pending}{messages}[0]{nick}='other_bot'}],
  ['ambient conversation',sub {$_[0]{pending}{messages}[0]{msg}='write a script and gist'}],
  ['history evidence',sub {$_[0]{pending}{messages}[0]{source_kind}='activity_followup'}],
) {
  my $copy=JSON::PP::decode_json(JSON::PP::encode_json($bot->{pending}));
  $case->[1]->($bot);
  eval {Bot::Runtime::Workbench::request_scope($bot,1)};
  ok($@,"reject $case->[0]");
  $bot->{pending}=$copy;
}
$bot->{pending}{messages}[0]{msg}='burt_bot: write a script';
ok(Bot::Runtime::Workbench::request_scope($bot,0),'run without publish permission');
eval {Bot::Runtime::Workbench::request_scope($bot,1)};
like($@,qr/explicitly asking for a gist/,'publishing needs explicit current request');
$bot->{pending}{messages}[0]{msg}='burt_bot: write tests and publish to the repository';
is(Bot::Runtime::Workbench::request_scope($bot,0),Bot::Runtime::Workbench::request_scope($bot,'repo'),'repo run and publish share envelope');
eval {Bot::Runtime::Workbench::request_scope($bot,1)};
like($@,qr/gist/,'repo permission does not authorize gist');
for my $text ('burt_bot: write tests and publish a gist', 'burt_bot: inspect the repo code', 'burt_bot: commit this code') {
  $bot->{pending}{messages}[0]{msg}=$text;
  eval {Bot::Runtime::Workbench::request_scope($bot,'repo')};
  like($@,qr/explicitly asking to publish/,'repo publication needs both destination and action');
}
$bot->{pending}{messages}[0]{msg}='burt_bot: update code and push to repo';
ok(Bot::Runtime::Workbench::request_scope($bot,'repo'),'explicit push admitted');
like($defs{publish_repo}{code}->($tool,{id=>'x',branch=>'main'}),qr/Invalid tool fields/,'publication cannot substitute destination');
{
  local $ENV{IRC_SERVER}='elsewhere';
  eval {Bot::Runtime::Workbench::request_scope($bot,0)};
  like($@,qr/network/,'network cannot be overridden');
}
# Coding admission uses the same envelope gate; fixes a five-minute chat TTL
# without renewing job scope when the model repairs/retries.
$bot->{pending}{expires_at}=time+100;
Bot::Runtime::Workbench::admit_task($bot);
ok($bot->{pending}{coding_task},'current addressed coding envelope admitted');
cmp_ok($bot->{pending}{expires_at},'>=',time+1799,'separate thirty-minute coding lifetime');
my $task_expiry=$bot->{pending}{expires_at};
my $task_scope=Bot::Runtime::Workbench::request_scope($bot,0);
Bot::Runtime::Workbench::admit_task($bot);
is($bot->{pending}{expires_at},$task_expiry,'admission never renews deadline');
is(Bot::Runtime::Workbench::request_scope($bot,0),$task_scope,'job scope stable');
is(scalar @{$bot->{sent}},1,'one start notice');
Bot::Runtime::Workbench::report_result($bot,'repo_run',JSON::PP::encode_json({
 id=>'a'x32,state=>'failed',result=>{exit_code=>1,output=>'INJECTED stdout'}}));
like($bot->{sent}[-1],qr/repo_run: failed.*exit 1/,'failed test notice includes stored job and exit');
unlike($bot->{sent}[-1],qr/INJECTED/,'generated output not reflected into channel');
Bot::Runtime::Workbench::report_result($bot,'repo_publish',JSON::PP::encode_json({
 id=>'a'x32,state=>'published',url=>'https://github.com/burt-agent/workspace/commit/'.('b'x40)}));
like($bot->{sent}[-1],qr{https://github.com/burt-agent/workspace/commit/},'actual broker commit URL reported');
Bot::Runtime::Workbench::report_result($bot,'repo_repair',JSON::PP::encode_json({
 id=>'c'x32,state=>'failed',attempts_remaining=>0,result=>{exit_code=>1}}));
like($bot->{sent}[-1],qr/0 sandbox attempts left/,'shared budget is visible');
is($bot->{pending}{coding_last_repo_job},'c'x32,'repair job survives model context compaction');
like($bot->{pending}{coding_stop_reason},qr/attempt budget exhausted/,'failed final attempt requests terminal stop');
$bot->{pending}{expires_at}=time-1;
eval {Bot::Runtime::Workbench::request_scope($bot,0)};
ok($@,'extended deadline still expires');
for my $kind ('reminder','activity_followup','conversation') {
 my $pending={channel=>'#ai',expires_at=>time+100,messages=>[
  {nick=>'mateu',source_kind=>$kind,msg=>'burt_bot: hello'}]};
 $bot->{pending}=$pending;
 Bot::Runtime::Workbench::admit_task($bot);
 ok(!$pending->{coding_task},"noncoding $kind gets no longer lifetime");
}
$bot->{bot}='astrid';
is_deeply(Bot::Runtime::Workbench::tool_specs($bot),[],'other bots unchanged');
$bot->{bot}='burt';
local $ENV{BURT_WORKBENCH_SOCKET}='';
is_deeply(Bot::Runtime::Workbench::tool_specs($bot),[],'feature disabled by default');
done_testing;
