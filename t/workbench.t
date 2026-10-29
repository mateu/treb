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
  {nick=>'mateu',source_kind=>'conversation',msg=>'burt_bot: inspect the python-csv reference, write a Perl fizzbuzz script and post a gist'}]}},'WorkbenchBot';
local $ENV{BURT_WORKBENCH_SOCKET}='/not/a/socket';
local $ENV{IRC_SERVER}='irc.perl.org';
my $scope=Bot::Runtime::Workbench::request_scope($bot,'edit_test');
is($scope,Bot::Runtime::Workbench::request_scope($bot,'publish_gist'),'run and publish bind to same runtime request');
like($scope,qr/^[a-f0-9]{64}$/,'scope is bounded digest');
my $tool=bless {},'WorkbenchTool';
my %defs=map {$_->{name}=>$_} @{Bot::Runtime::Workbench::tool_specs($bot)};
is(scalar keys %defs,14,'fourteen narrow tools including checkpoint recovery');
{
  no warnings 'redefine';
  local *Bot::Runtime::Workbench::broker_call=sub { '{"reference":"python-csv","text":"documentation","untrusted":true}' };
  my $before=scalar @{$bot->{sent}||[]};
  like($defs{read_coding_reference}{code}->($tool,{key=>'python-csv'}),qr/documentation/,'reference reaches broker under current request scope');
  is(scalar @{$bot->{sent}||[]},$before,'successful read is not reported as failed execution');
}
like($defs{publish_gist}{code}->($tool,{id=>'x',channel=>'#ai'}),qr/Invalid tool fields/,'model cannot choose scope/channel');
# Authoritative transition table: only a direct trusted envelope can mint its
# named capability; generic coding discussion is not an authority signal.
for my $case (
  ['read_status','burt_bot: inspect the python-csv reference'],
  ['edit_test','burt_bot: write and test this Perl program'],
  ['publish_gist','burt_bot: publish this as a gist'],
  ['publish_repo','burt_bot: push this project to the repository'],
) {
  my ($cap,$text)=@$case;
  my $saved=JSON::PP::decode_json(JSON::PP::encode_json($bot->{pending}));
  $bot->{pending}{messages}[0]{msg}=$text;
  ok(Bot::Runtime::Workbench::request_scope($bot,$cap),"$cap is granted only by its direct request");
  for my $other (grep { $_ ne $cap } qw(read_status edit_test publish_gist publish_repo)) {
    eval { Bot::Runtime::Workbench::request_scope($bot,$other) };
    ok($@,"$cap does not upgrade $other");
  }
  $bot->{pending}=$saved;
}
{
  my $saved=JSON::PP::decode_json(JSON::PP::encode_json($bot->{pending}));
  $bot->{pending}{messages}[0]{msg}='burt_bot: how was the coding session?';
  for my $cap (qw(read_status edit_test publish_gist publish_repo)) {
    eval { Bot::Runtime::Workbench::request_scope($bot,$cap) };
    ok($@,"coding-vocabulary-only text grants no $cap authority");
  }
  $bot->{pending}=$saved;
}
for my $name (qw(read_coding_reference run_code publish_gist read_repo_project publish_repo)) {
  like($defs{$name}{description},qr/Requires a current trusted human/,
    "$name describes its bounded human capability");
}
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
  eval {Bot::Runtime::Workbench::request_scope($bot,'publish_gist')};
  ok($@,"reject $case->[0]");
  $bot->{pending}=$copy;
}
$bot->{pending}{messages}[0]{msg}='burt_bot: write a script';
ok(Bot::Runtime::Workbench::request_scope($bot,'edit_test'),'run without publish permission');
eval {Bot::Runtime::Workbench::request_scope($bot,'publish_gist')};
like($@,qr/explicitly asking for a gist/,'publishing needs explicit current request');
$bot->{pending}{messages}[0]{msg}='burt_bot: write tests and publish to the repository';
is(Bot::Runtime::Workbench::request_scope($bot,'edit_test'),Bot::Runtime::Workbench::request_scope($bot,'publish_repo'),'repo run and publish share envelope');
my ($read_scope,$read_capability,$read_grant)=Bot::Runtime::Workbench::capability_grant($bot,'repo_read');
is($read_capability,'edit_test','edit authority can obtain its required repository snapshot');
is($read_scope,Bot::Runtime::Workbench::request_scope($bot,'edit_test'),'repository snapshot stays in the edit request scope');
eval {Bot::Runtime::Workbench::request_scope($bot,'publish_gist')};
like($@,qr/gist/,'repo permission does not authorize gist');
for my $text ('burt_bot: write tests and publish a gist', 'burt_bot: inspect the repo code', 'burt_bot: commit this code') {
  $bot->{pending}{messages}[0]{msg}=$text;
  eval {Bot::Runtime::Workbench::request_scope($bot,'publish_repo')};
  like($@,qr/explicitly asking to publish/,'repo publication needs both destination and action');
}
$bot->{pending}{messages}[0]{msg}='burt_bot: inspect the repository, update code and push to repo';
ok(Bot::Runtime::Workbench::request_scope($bot,'publish_repo'),'explicit push admitted');
like($defs{publish_repo}{code}->($tool,{id=>'x',branch=>'main'}),qr/Invalid tool fields/,'publication cannot substitute destination');
{
  local $ENV{IRC_SERVER}='elsewhere';
  eval {Bot::Runtime::Workbench::request_scope($bot,'edit_test')};
  like($@,qr/network/,'network cannot be overridden');
}
# Test-channel admission uses the same fresh human/publication gates.
{
  my $saved=JSON::PP::decode_json(JSON::PP::encode_json($bot->{pending}));
  my $ai_scope=Bot::Runtime::Workbench::request_scope($bot,'publish_repo');
  $bot->{pending}{channel}='#mateu-test';
  my $test_scope=Bot::Runtime::Workbench::request_scope($bot,'publish_repo');
  ok($test_scope,'test channel accepts explicit current human publication request');
  isnt($test_scope,$ai_scope,'request scope remains channel-bound');
  my $forwarded;
  no warnings 'redefine';
  local *Bot::Runtime::Workbench::broker_call=sub {$forwarded=$_[0]; return '{}'};
  $defs{read_repo_project}{code}->($tool,{branch=>'burt/dictionary',project=>'dictionary'});
  is($forwarded->{channel},'#mateu-test','broker receives actual runtime channel, not hardcoded #ai');
  $bot->{pending}{messages}[0]{msg}='burt_bot: write a script';
  eval {Bot::Runtime::Workbench::request_scope($bot,'publish_repo')};
  like($@,qr/explicitly asking to publish/,'test channel still requires explicit publication');
  $bot->{pending}{messages}[0]{source_kind}='reminder';
  eval {Bot::Runtime::Workbench::request_scope($bot,'edit_test')};
  ok($@,'test channel reminder cannot authorize coding');
  $bot->{pending}=$saved;
}
# Coding admission uses the same envelope gate; fixes a five-minute chat TTL
# without renewing job scope when the model repairs/retries.
$bot->{pending}{expires_at}=time+100;
Bot::Runtime::Workbench::admit_task($bot);
ok($bot->{pending}{coding_task},'current addressed coding envelope admitted');
cmp_ok($bot->{pending}{expires_at},'>=',time+1799,'separate thirty-minute coding lifetime');
my $task_expiry=$bot->{pending}{expires_at};
my $task_scope=Bot::Runtime::Workbench::request_scope($bot,'edit_test');
Bot::Runtime::Workbench::admit_task($bot);
is($bot->{pending}{expires_at},$task_expiry,'admission never renews deadline');
is(Bot::Runtime::Workbench::request_scope($bot,'edit_test'),$task_scope,'job scope stable');
is(scalar @{$bot->{sent}},1,'one start notice');
{
  no warnings 'redefine';
  local *Bot::Runtime::Workbench::broker_call=sub { '{"reference":"python-csv","text":"documentation","untrusted":true}' };
  my $before=scalar @{$bot->{sent}};
  $defs{read_coding_reference}{code}->($tool,{key=>'python-csv'});
  is(scalar @{$bot->{sent}},$before,'successful read stays quiet during coding task');
}
{
  no warnings 'redefine';
  local *Bot::Runtime::Workbench::broker_call=sub { '{"rejection_schema":1,"code":"invalid_request","disposition":"terminal"}' };
  $defs{read_coding_reference}{code}->($tool,{key=>'python-csv'});
}
is($bot->{pending}{coding_stop_reason},'Workbench request cannot be retried in this task',
 'terminal read rejection stops coding task');
delete $bot->{pending}{coding_stop_reason};
Bot::Runtime::Workbench::report_result($bot,'repo_run',JSON::PP::encode_json({
 id=>'a'x32,state=>'failed',result=>{exit_code=>1,output=>'INJECTED stdout'}}));
like($bot->{sent}[-1],qr/repo_run: failed.*exit 1/,'failed test notice includes stored job and exit');
unlike($bot->{sent}[-1],qr/INJECTED/,'generated output not reflected into channel');
Bot::Runtime::Workbench::report_result($bot,'repo_run',JSON::PP::encode_json({
 rejection_schema=>1,code=>'invalid_request',disposition=>'terminal'}));
is($bot->{pending}{coding_stop_reason},'Workbench request cannot be retried in this task',
 'terminal structured rejection stops coding task');
delete $bot->{pending}{coding_stop_reason};
Bot::Runtime::Workbench::report_result($bot,'repo_publish',JSON::PP::encode_json({
 id=>'a'x32,state=>'published',url=>'https://github.com/burt-agent/workspace/commit/'.('b'x40)}));
like($bot->{sent}[-1],qr{https://github.com/burt-agent/workspace/commit/},'actual broker commit URL reported');
Bot::Runtime::Workbench::report_result($bot,'repo_repair',JSON::PP::encode_json({
 id=>'c'x32,state=>'failed',attempts_remaining=>0,result=>{exit_code=>1}}));
like($bot->{sent}[-1],qr/0 sandbox attempts left/,'shared budget is visible');
is($bot->{pending}{coding_last_repo_job},'c'x32,'repair job survives model context compaction');
like($bot->{pending}{coding_stop_reason},qr/attempt budget exhausted/,'failed final attempt requests terminal stop');
my $project_failure=$bot->{pending}{coding_last_result};
Bot::Runtime::Workbench::report_result($bot,'repo_diagnose',JSON::PP::encode_json({
 id=>'d'x32,state=>'passed',attempts_remaining=>0,result=>{exit_code=>0}}));
is($bot->{pending}{coding_last_repo_job},'c'x32,'diagnostic does not replace project job');
is($bot->{pending}{coding_last_result},$project_failure,'passing diagnostic does not replace project failure');
like($defs{run_code}{code}->($tool,{files=>{'x.pl'=>'1;'},argv=>['/usr/bin/perl','x.pl'],title=>'probe'}),
 qr/Repository diagnostics must use diagnose_repo_job/,'repository diagnostics reuse the immutable bundle');
$bot->{pending}{expires_at}=time-1;
eval {Bot::Runtime::Workbench::request_scope($bot,'edit_test')};
ok($@,'extended deadline still expires');
for my $kind ('reminder','activity_followup','conversation') {
 my $pending={channel=>'#ai',expires_at=>time+100,messages=>[
  {nick=>'mateu',source_kind=>$kind,msg=>'burt_bot: hello'}]};
 $bot->{pending}=$pending;
 Bot::Runtime::Workbench::admit_task($bot);
 ok(!$pending->{coding_task},"noncoding $kind gets no longer lifetime");
}
$bot->{pending}={channel=>'#ai',expires_at=>time+100,messages=>[
  {nick=>'mateu',source_kind=>'conversation',msg=>'burt_bot: resume and test this coding project'}]};
Bot::Runtime::Workbench::admit_task($bot);
ok(!$bot->{pending}{coding_task},'explicit resume stays unbound for the resume tool');
# Proposal confirmations are a fresh trusted runtime envelope, not model/retrieval text.
$bot->{pending}={channel=>'#ai',expires_at=>time+100,messages=>[
  {nick=>'MaTeu[]',source_kind=>'conversation',queued_at=>time,msg=>'burt_bot: yes'}]};
my $confirmation=Bot::Runtime::Workbench::confirmation_envelope($bot);
is($confirmation->{action},'proposal_confirm','confirmation uses its narrow broker action');
is($confirmation->{requester},'mateu{}','confirmation requester uses IRC casemapping');
is($confirmation->{capability},'read_status','confirmation is scoped to a fresh bounded envelope');
ok($confirmation->{confirmed_at},'confirmation timestamp comes from the runtime message');
push @{$bot->{pending}{messages}},{nick=>'other',source_kind=>'conversation',msg=>'burt_bot: publish this gist'};
$confirmation=Bot::Runtime::Workbench::confirmation_envelope($bot);
ok(!exists($confirmation->{publish_grant}),'another requester cannot supply publication authority');
$bot->{pending}{messages}[0]{msg}='burt_bot: yes, publish this gist';
$confirmation=Bot::Runtime::Workbench::confirmation_envelope($bot);
is($confirmation->{publish_capability},'publish_gist','confirming requester supplies explicit gist authority');
$bot->{pending}{expires_at}=time-1;
eval { Bot::Runtime::Workbench::confirmation_envelope($bot) };
like($@,qr/No active #ai/,'expired envelope cannot mint confirmation grant');
$bot->{pending}{expires_at}=time+100;
$bot->{pending}{messages}[0]{msg}='burt_bot: yes';
pop @{$bot->{pending}{messages}};
$bot->{pending}{messages}[0]{source_kind}='activity_followup';
eval {Bot::Runtime::Workbench::confirmation_envelope($bot)};
like($@,qr/fresh explicit confirmation/,'retrieved/history text cannot confirm a proposal');
$bot->{pending}{messages}[0]{source_kind}='conversation';
$bot->{pending}{messages}[0]{msg}='yes';
eval {Bot::Runtime::Workbench::confirmation_envelope($bot)};
like($@,qr/fresh explicit confirmation/,'ambient yes cannot confirm a proposal');
$bot->{pending}{messages}[0]{msg}='burt_bot: yes';
push @{$bot->{pending}{messages}},{nick=>'other',source_kind=>'conversation',msg=>'burt_bot: yes'};
eval {Bot::Runtime::Workbench::confirmation_envelope($bot)};
like($@,qr/fresh explicit confirmation/,'ambiguous confirmation messages cannot authorize action');
# Tool callbacks inject requester/scope from the runtime envelope; model args contain neither.
$bot->{pending}={channel=>'#ai',expires_at=>time+100,messages=>[
  {nick=>'mateu',source_kind=>'conversation',msg=>'burt_bot: inspect the python-json reference'}]};
my $forwarded;
{
  no warnings 'redefine';
  local *Bot::Runtime::Workbench::broker_call=sub {$forwarded=$_[0]; return '{"proposal_id":"'.('a'x32).'","state":"proposed"}'};
  like($defs{propose_workbench_action}{code}->($tool,{action=>'reference',params=>{key=>'python-json'}}),
    qr/proposed/,'proposal tool returns broker proposal');
}
is($forwarded->{requester},'mateu','proposal requester is runtime-derived');
ok(!exists($forwarded->{params}{requester}),'model parameters cannot set requester identity');
$bot->{pending}={channel=>'#ai',expires_at=>time+100,messages=>[
  {nick=>'mateu',source_kind=>'conversation',queued_at=>time,msg=>'burt_bot: yes'}]};
{
  no warnings 'redefine';
  local *Bot::Runtime::Workbench::broker_call=sub {$forwarded=$_[0]; return '{"confirmed_action":"reference","reference":"python-json"}'};
  like($defs{confirm_workbench_proposal}{code}->($tool,{}),qr/python-json/,
    'confirmation tool forwards only the fresh runtime envelope');
}
is($forwarded->{requester},'mateu','confirmation requester is runtime-derived');
is_deeply([sort keys %$forwarded],[sort qw(action capability channel confirmed_at grant network requester scope)],
  'confirmation tool accepts no model-selected action or parameters');
# Recovery tools derive requester and fresh authorization from the current
# envelope; a checkpoint id is the only model-supplied selector.
$bot->{pending}={channel=>'#ai',expires_at=>time+100,messages=>[
  {nick=>'mateu',source_kind=>'conversation',msg=>'burt_bot: status this coding session'}]};
{
  no warnings 'redefine';
  local *Bot::Runtime::Workbench::broker_call=sub {$forwarded=$_[0]; return '{"checkpoint_id":"'.('a'x32).'","jobs":[],"attempts_remaining":4}'};
  like($defs{coding_checkpoint_status}{code}->($tool,{checkpoint_id=>'a'x32}),qr/checkpoint_id/,
    'checkpoint status is broker-derived');
}
is($forwarded->{requester},'mateu','checkpoint status requester is runtime-derived');
is_deeply([sort keys %$forwarded],[sort qw(action capability channel checkpoint_id grant network requester scope)],
  'status cannot supply channel, requester, scope, or grants');
$bot->{pending}={channel=>'#ai',expires_at=>time+100,messages=>[
  {nick=>'mateu',source_kind=>'conversation',msg=>'burt_bot: resume and test this coding project'}]};
{
  my $calls=0;
  my $resume_scope='';
  no warnings 'redefine';
  # The fresh runtime scope is opaque, so echo it from the request in the mock.
  local *Bot::Runtime::Workbench::broker_call=sub {
    $forwarded=$_[0];
    $resume_scope=$forwarded->{scope} if ++$calls==1;
    return $calls==1 ? JSON::PP::encode_json({resumed_scope=>$resume_scope,jobs=>[],attempts_remaining=>4})
      : JSON::PP::encode_json({checkpoint_id=>'c'x32,jobs=>[],attempts_remaining=>4});
  };
  like($defs{resume_coding_task}{code}->($tool,{checkpoint_id=>'a'x32}),qr/resumed_scope/,
    'resume accepts one exact checkpoint id');
}
is($forwarded->{action},'task_checkpoint','resume creates a new immutable lineage receipt');
is($forwarded->{scope},$bot->{pending}{coding_scope},'post-resume checkpoint retains the broker-bound scope');
is($bot->{pending}{coding_requester},'mateu','resume preserves broker-bound requester identity');
cmp_ok($bot->{pending}{expires_at},'>=',time+1799,'resume grants a fresh bounded coding lifetime');
$bot->{bot}='astrid';
is_deeply(Bot::Runtime::Workbench::tool_specs($bot),[],'other bots unchanged');
$bot->{bot}='burt';
local $ENV{BURT_WORKBENCH_SOCKET}='';
is_deeply(Bot::Runtime::Workbench::tool_specs($bot),[],'feature disabled by default');
done_testing;
