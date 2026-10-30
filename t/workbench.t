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
is(scalar keys %defs,15,'fifteen narrow tools including standalone checkpoint recovery');
like($defs{run_repo_project}{description},qr/THIRTEEN total sandbox attempts/,
  'production tools advertise the thirteen-attempt budget');
{
  local $ENV{BURT_SANDBOX_ATTEMPTS}=5;
  my %trial_defs=map {$_->{name}=>$_} @{Bot::Runtime::Workbench::tool_specs($bot)};
  like($trial_defs{run_code}{description},qr/At most FIVE sandbox runs TOTAL/,
    'frozen trials advertise the five-attempt budget');
  like($trial_defs{diagnose_repo_job}{description},qr/one of the FIVE shared executions/,
    'frozen diagnostics advertise the five-attempt budget');
}
{
  no warnings 'redefine';
  local *Bot::Runtime::Workbench::broker_call=sub { '{"reference":"python-csv","text":"documentation","untrusted":true}' };
  my $before=scalar @{$bot->{sent}||[]};
  like($defs{read_coding_reference}{code}->($tool,{key=>'python-csv'}),qr/documentation/,'reference reaches broker under current request scope');
  is(scalar @{$bot->{sent}||[]},$before,'successful read is not reported as failed execution');
}
like($defs{publish_gist}{code}->($tool,{id=>'x',channel=>'#ai'}),qr/Invalid tool fields/,'model cannot choose scope/channel');
# Authoritative transition table: only a direct trusted envelope can mint its
# named capability; natural task requests do not require magic coding verbs.
for my $case (
  ['read_status','burt_bot: inspect the python-csv reference'],
  ['read_status','burt_bot: inspect job '.('a'x32)],
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
    if ($cap eq 'edit_test' && $other eq 'read_status') {
      ok(!$@,'edit/test task includes its bounded repository read');
    } else {
      ok($@,"$cap does not upgrade $other");
    }
  }
  $bot->{pending}=$saved;
}
for my $case (
  ['reported dictionary continuation','burt_bot: you want to have another crack at the qtype/idtype/id query params for the dictionary code at https://github.com/burt-agent/workspace/tree/burt/dictionary',1],
  ['natural revisit','burt_bot: could you revisit the dictionary project and see what is missing?',1],
  ['indirect offline task','burt_bot: please help with this Perl program',1],
  ['bounded read','burt_bot: inspect the repository project',0],
  ['inspect push failures','burt_bot: inspect the code for push failures',0],
  ['explain commit remains non-public coding context','burt_bot: explain how to commit this code',1],
  ['comma bounded read','burt_bot, inspect the repository project',0],
  ['polite bounded read','burt_bot: please inspect the repository project',0],
  ['interrogative bounded read','burt_bot: could you inspect the repository?',0],
  ['compound bounded read','burt_bot: inspect the repository and read the python-csv reference',0],
  ['hyphenated bounded read','burt_bot: inspect the perl-test-more reference',0],
  ['checkpoint status read','burt_bot: status checkpoint '.('a'x32),0],
  ['offline task with no publication','burt_bot: repair this dictionary code; do not publish anything',1],
  ['offline task with negative constraint','burt_bot: update this inventory project (do not clamp negative balances)',1],
  ['post-processing task','burt_bot: fix the post-processing code',1],
  ['pre-commit task','burt_bot: implement a pre-commit script',1],
  ['status-reporting implementation','burt_bot: write a script to report the status of the project',1],
  ['subsequent sentence execution','burt_bot: inspect the repository. Run the tests.',1],
  ['declarative problem followed by task','burt_bot: this script is broken; fix the code and run the tests',1],
) {
  my ($name,$text,$edit)=@$case;
  my $saved=JSON::PP::decode_json(JSON::PP::encode_json($bot->{pending}));
  $bot->{pending}{messages}[0]{msg}=$text;
  ok(Bot::Runtime::Workbench::request_scope($bot,'read_status'),"$name grants bounded read/status");
  if ($edit) {
    ok(Bot::Runtime::Workbench::request_scope($bot,'edit_test'),"$name grants offline edit/test");
  } else {
    eval { Bot::Runtime::Workbench::request_scope($bot,'edit_test') };
    ok($@,"$name does not grant offline edit/test");
  }
  for my $publication (qw(publish_gist publish_repo)) {
    eval { Bot::Runtime::Workbench::request_scope($bot,$publication) };
    ok($@,"$name does not grant $publication");
  }
  $bot->{pending}=$saved;
}
{
  my $saved=JSON::PP::decode_json(JSON::PP::encode_json($bot->{pending}));
  $bot->{pending}{messages}[0]{msg}='burt_bot: read burt-agent/workspace project dictionary on branch burt/dictionary, run the tests, and push if they pass';
  ok(Bot::Runtime::Workbench::request_scope($bot,'read_status'),'natural read/test/push request grants bounded read');
  ok(Bot::Runtime::Workbench::request_scope($bot,'edit_test'),'natural read/test/push request grants offline test authority');
  ok(Bot::Runtime::Workbench::request_scope($bot,'publish_repo'),'natural read/test/push request grants explicit conditional publication');
  $bot->{pending}=$saved;
}
{
  my $saved=JSON::PP::decode_json(JSON::PP::encode_json($bot->{pending}));
  $bot->{pending}{messages}[0]{msg}='burt_bot: word, please proceed';
  ok(Bot::Runtime::Workbench::request_scope($bot,'edit_test'),'short addressed continuation grants offline task authority');
  eval { Bot::Runtime::Workbench::request_scope($bot,'publish_repo') };
  ok($@,'short continuation cannot grant publication');
  $bot->{pending}=$saved;
}
{
  my $saved=JSON::PP::decode_json(JSON::PP::encode_json($bot->{pending}));
  push @{$bot->{pending}{messages}}, {nick=>'mateu',source_kind=>'conversation',
    msg=>'burt_bot: do not push the dictionary work'};
  for my $cap (qw(read_status edit_test publish_gist publish_repo)) {
    eval { Bot::Runtime::Workbench::request_scope($bot,$cap) };
    ok($@,"latest cancellation revokes earlier buffered $cap authority");
  }
  $bot->{pending}=$saved;
}
{
  my $saved=JSON::PP::decode_json(JSON::PP::encode_json($bot->{pending}));
  $bot->{pending}{messages}[0]{msg}='burt_bot: write a script to push this project to the repository';
  ok(Bot::Runtime::Workbench::request_scope($bot,'edit_test'),'publication-tool implementation retains offline authority');
  ok(Bot::Runtime::Workbench::request_scope($bot,'publish_repo'),'publication-tool implementation separately grants repository publication');
  $bot->{pending}=$saved;
}
{
  my $saved=JSON::PP::decode_json(JSON::PP::encode_json($bot->{pending}));
  $bot->{pending}{messages}[0]{msg}='burt_bot, push this project to the repository';
  ok(Bot::Runtime::Workbench::request_scope($bot,'publish_repo'),'comma-addressed publication is explicitly admitted');
  for my $cap (qw(read_status edit_test)) {
    eval { Bot::Runtime::Workbench::request_scope($bot,$cap) };
    ok($@,"comma-addressed publication does not grant $cap");
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
for my $case (
  ['status-only','burt_bot: what is the status of the dictionary code?'],
  ['cancelled','burt_bot: do not revisit the dictionary code'],
  ['negated','burt_bot: please do not work on this repository project'],
  ['nonrequest','burt_bot: the dictionary code is in the repository'],
) {
  my ($name,$text)=@$case;
  my $saved=JSON::PP::decode_json(JSON::PP::encode_json($bot->{pending}));
  $bot->{pending}{messages}[0]{msg}=$text;
  for my $cap (qw(read_status edit_test publish_gist publish_repo)) {
    eval { Bot::Runtime::Workbench::request_scope($bot,$cap) };
    ok($@,"$name text grants no $cap authority");
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
for my $text ('burt_bot: write tests and publish a gist', 'burt_bot: inspect the repo code') {
  $bot->{pending}{messages}[0]{msg}=$text;
  eval {Bot::Runtime::Workbench::request_scope($bot,'publish_repo')};
  like($@,qr/explicitly asking to publish/,'repo publication needs both destination and action');
}
$bot->{pending}{messages}[0]{msg}='burt_bot: inspect the repository, update code and push to repo';
ok(Bot::Runtime::Workbench::request_scope($bot,'publish_repo'),'explicit push admitted');
$bot->{pending}{messages}[0]{msg}='burt_bot: please push your dictionary coding work';
ok(Bot::Runtime::Workbench::request_scope($bot,'publish_repo'),'ordinary addressed coding-work push is admitted');
for my $other (qw(read_status edit_test publish_gist)) {
  eval {Bot::Runtime::Workbench::request_scope($bot,$other)};
  ok($@,"ordinary direct push grants no $other authority");
}
{
  my $forwarded;
  no warnings 'redefine';
  local *Bot::Runtime::Workbench::broker_call=sub {$forwarded=$_[0]; return '{"id":"'.('d'x32).'","state":"passed"}'};
  $defs{publish_repo}{code}->($tool,{});
  is_deeply([sort keys %$forwarded],[sort qw(action capability channel grant network requester scope)],
    'direct publication producer forwards no model-selected id or destination');
  is($forwarded->{action},'repo_publish','direct publication producer uses repository action');
  is($forwarded->{capability},'publish_repo','direct publication producer carries bounded grant');
  is($forwarded->{requester},'mateu','direct publication producer derives requester from IRC envelope');
}
like($defs{publish_repo}{code}->($tool,{id=>'x',branch=>'main'}),qr/Invalid tool fields/,'publication cannot substitute destination');
$bot->{pending}{messages}[0]{msg}='burt_bot: inspect the repository, update code and push to repo';
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
Bot::Runtime::Workbench::report_result($bot,'run',JSON::PP::encode_json({
 id=>'e'x32,state=>'passed',attempts_remaining=>12,result=>{exit_code=>0}}));
is($bot->{pending}{coding_attempts_remaining},12,'expanded remaining budget reaches runtime status');
like($bot->{sent}[-1],qr/12 sandbox attempts left/,'expanded shared budget is reported');
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
  {nick=>'mateu',source_kind=>'conversation',msg=>'burt_bot: resume checkpoint and test this coding project'}]};
Bot::Runtime::Workbench::admit_task($bot);
ok(!$bot->{pending}{coding_task},'explicit checkpoint resume stays unbound for the resume tool');
$bot->{pending}={channel=>'#ai',expires_at=>time+100,messages=>[
  {nick=>'mateu',source_kind=>'conversation',msg=>'burt_bot: write and test a resume parsing script'}]};
Bot::Runtime::Workbench::admit_task($bot);
ok($bot->{pending}{coding_task},'incidental resume wording still admits a coding task');
delete $bot->{pending}{coding_task};
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
ok(!exists($confirmation->{publish_grant}),'confirmation never supplies standalone publication authority');
$bot->{pending}{messages}[0]{msg}='burt_bot: yes, publish this gist';
$confirmation=Bot::Runtime::Workbench::confirmation_envelope($bot);
ok(!exists($confirmation->{publish_capability}),'destination remains bound by the durable proposal');
ok($confirmation->{publication_confirmation},'an explicit publication verb retains publication intent');
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
$bot->{pending}{messages}[0]{msg}='please push';
$confirmation=Bot::Runtime::Workbench::confirmation_envelope($bot);
is($confirmation->{requester},'mateu{}','unaddressed natural approval remains runtime-derived');
$bot->{pending}{messages}=[
  {nick=>'burt_bot',source_kind=>'conversation',queued_at=>time-240,msg=>'Full project suite is green: 23 files, 1077 tests. Say the word and I’ll push it to burt/dictionary.'},
  {nick=>'mateu',source_kind=>'conversation',queued_at=>time,msg=>'please push'},
];
$confirmation=Bot::Runtime::Workbench::confirmation_envelope($bot);
like($confirmation->{scope},qr/^[a-f0-9]{64}$/,'unaddressed please push follows a bot offer without treating the offer as authority');
ok($confirmation->{publication_confirmation},'please push carries explicit publication intent');
$bot->{pending}{messages}[1]{source_kind}='activity_followup';
eval {Bot::Runtime::Workbench::confirmation_envelope($bot)};
like($@,qr/fresh explicit confirmation/,'retrieved text cannot mint approval');
$bot->{pending}{messages}=[{nick=>'mateu{}',source_kind=>'conversation',queued_at=>time,msg=>'burt_bot: yes'}];
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
  {nick=>'alice',source_kind=>'conversation',msg=>'burt_bot: write and test a Perl script'},
  {nick=>'bob',source_kind=>'conversation',msg=>'burt_bot: hello'}]};
Bot::Runtime::Workbench::admit_task($bot);
ok(!$bot->{pending}{coding_task},'ambiguous requesters do not admit a coding task');
{
  no warnings 'redefine';
  my $called=0;
  local *Bot::Runtime::Workbench::broker_call=sub {$called++; return '{}'};
  like($defs{run_code}{code}->($tool,{files=>{'main.pl'=>'print 1'},argv=>['/usr/bin/perl','/work/main.pl'],title=>'test'}),
    qr/Error: (?:No admitted coding task for run|Need a current trusted human request)/,'execution rejects an ambiguous unadmitted request');
  is($called,0,'unadmitted execution never reaches the broker');
}

$bot->{pending}={channel=>'#ai',expires_at=>time+100,messages=>[
  {nick=>'mateu',source_kind=>'conversation',queued_at=>time,msg=>'burt_bot: yes'}]};
{
  no warnings 'redefine';
  local *Bot::Runtime::Workbench::broker_call=sub {$forwarded=$_[0]; return '{"confirmed_action":"reference","reference":"python-json"}'};
  like($defs{confirm_workbench_proposal}{code}->($tool,{}),qr/python-json/,
    'confirmation tool forwards only the fresh runtime envelope');
}
is($forwarded->{requester},'mateu','confirmation requester is runtime-derived');
is_deeply([sort keys %$forwarded],[sort qw(action capability channel confirmed_at grant network publication_confirmation requester scope)],
  'confirmation tool accepts no model-selected action or parameters');
# Recovery tools derive requester and fresh authorization from the current
# envelope; a checkpoint id is the only model-supplied selector.
$bot->{pending}={channel=>'#ai',expires_at=>time+100,messages=>[
  {nick=>'mateu',source_kind=>'conversation',msg=>'burt_bot: inspect checkpoint '.('a'x32)}]};
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
my @resume_requests;
{
  my $resume_scope='';
  no warnings 'redefine';
  # The fresh runtime scope is opaque, so echo it from the request in the mock.
  local *Bot::Runtime::Workbench::broker_call=sub {
    $forwarded=$_[0]; push @resume_requests,$forwarded;
    $resume_scope=$forwarded->{scope} if $forwarded->{action} eq 'task_resume';
    return $forwarded->{action} eq 'task_resume' ? JSON::PP::encode_json({resumed_scope=>$resume_scope,jobs=>[],
      latest_execution_job=>{id=>'d'x32,state=>'passed'},
      latest_repository_job=>{id=>'d'x32,state=>'passed'},attempts_remaining=>4})
      : $forwarded->{action} eq 'task_checkpoint' ? JSON::PP::encode_json({checkpoint_id=>'c'x32,jobs=>[],attempts_remaining=>4})
      : JSON::PP::encode_json({budget=>{}});
  };
  like($defs{resume_coding_task}{code}->($tool,{checkpoint_id=>'a'x32}),qr/resumed_scope/,
    'resume accepts one exact checkpoint id');
}
my ($resume_checkpoint)=grep { $_->{action} eq 'task_checkpoint' } reverse @resume_requests;
is($resume_checkpoint->{scope},$bot->{pending}{coding_scope},'post-resume checkpoint retains the broker-bound scope');
is($resume_requests[-1]{action},'task_progress','resume also records the bounded progress notice');
is($bot->{pending}{coding_requester},'mateu','resume preserves broker-bound requester identity');
is($bot->{pending}{coding_last_execution_job},'d'x32,'resume restores the latest non-diagnostic execution job');
is($bot->{pending}{coding_last_execution_state},'passed','resume restores the latest non-diagnostic execution state');
is($bot->{pending}{coding_last_repo_job},'d'x32,'resume restores the latest complete repository job');
is($bot->{pending}{coding_last_repo_state},'passed','resume restores a completed repository job');
is($bot->{pending}{coding_receipts}{passed}{'d'x32},1,'resume restores the passed job receipt');
is(Bot::Runtime::Workbench::verified_final_report($bot,$bot->{pending},'Tests passed on the saved bundle.'),
  'Tests passed on the saved bundle.','resumed passed bundle permits truthful final report');
is($bot->{pending}{coding_attempts_remaining},4,'resume restores the broker-derived task budget');
cmp_ok($bot->{pending}{expires_at},'>=',time+1799,'resume grants a fresh bounded coding lifetime');
$bot->{pending}={channel=>'#ai',expires_at=>time-1,messages=>[
  {nick=>'mateu',source_kind=>'conversation',msg=>'burt_bot: resume and test this coding project'}]};
like($defs{resume_coding_task}{code}->($tool,{checkpoint_id=>'a'x32}),qr/Error: No active #ai or #mateu-test request/,
  'expired resume request cannot extend its deadline');
$bot->{pending}={channel=>'#ai',expires_at=>time+100,messages=>[
  {nick=>'mateu',source_kind=>'conversation',msg=>'burt_bot: resume checkpoint and test this coding project'}]};
my $resume_deadline=$bot->{pending}{expires_at};
{
  no warnings 'redefine';
  local *Bot::Runtime::Workbench::broker_call=sub { die "checkpoint rejected\n" };
  like($defs{resume_coding_task}{code}->($tool,{checkpoint_id=>'a'x32}),qr/Error: checkpoint rejected/,
    'failed resume reports rejection');
}
is($bot->{pending}{expires_at},$resume_deadline,'failed resume restores its original deadline');
$bot->{pending}={coding_task=>1,coding_last_result=>'No verified work result recorded.'};
like(Bot::Runtime::Workbench::verified_final_report($bot,$bot->{pending},'Tests passed and I pushed it.'),
  qr/report withheld/,'unreceipted test and publication claims are withheld');
$bot->{pending}{coding_last_repo_job}='a'x32;
$bot->{pending}{coding_last_repo_state}='passed';
$bot->{pending}{coding_last_execution_job}='a'x32;
$bot->{pending}{coding_last_execution_state}='passed';
$bot->{pending}{coding_last_publication_job}='a'x32;
$bot->{pending}{coding_receipts}={passed=>{'a'x32=>1},published=>{'a'x32=>''}};
is(Bot::Runtime::Workbench::verified_final_report($bot,$bot->{pending},'Tests passed and I pushed it.'),
  'Tests passed and I pushed it.','matching broker receipts permit factual final report');
is(Bot::Runtime::Workbench::verified_final_report($bot,$bot->{pending},'Tests passed; the changes have not been published.'),
  'Tests passed; the changes have not been published.','a truthful denial of publication is not suppressed');
$bot->{pending}{coding_receipts}{published}={};
like(Bot::Runtime::Workbench::verified_final_report($bot,$bot->{pending},'I pushed the changes. Tests passed.'),
  qr/report withheld/,'publication claims before test claims still require a receipt');
$bot->{pending}{coding_receipts}{published}{'a'x32}='';
$bot->{pending}={coding_task=>1,coding_last_execution_state=>'failed'};
is(Bot::Runtime::Workbench::verified_final_report($bot,$bot->{pending},'No tests passed; the suite failed because the fixture is missing.'),
  'No tests passed; the suite failed because the fixture is missing.','a truthful denial of test success is not suppressed');
$bot->{pending}{coding_last_repo_job}='a'x32;
$bot->{pending}{coding_last_repo_state}='passed';
$bot->{pending}{coding_last_execution_job}='a'x32;
$bot->{pending}{coding_last_execution_state}='passed';
$bot->{pending}{coding_last_publication_job}='a'x32;
$bot->{pending}{coding_receipts}={passed=>{'a'x32=>1},published=>{'a'x32=>''}};
$bot->{pending}{coding_last_repo_state}='failed';
$bot->{pending}{coding_last_execution_state}='failed';
like(Bot::Runtime::Workbench::verified_final_report($bot,$bot->{pending},'Tests passed.'),
  qr/report withheld/,'an earlier passed receipt cannot validate later failed work');
$bot->{pending}{coding_last_repo_state}='passed';
$bot->{pending}{coding_last_execution_state}='passed';
$bot->{pending}={coding_task=>1};
Bot::Runtime::Workbench::report_result($bot,'run','{"id":"'.('c'x32).'","state":"passed"}',1);
is(Bot::Runtime::Workbench::verified_final_report($bot,$bot->{pending},'Tests passed.'),
  'Tests passed.','matching standalone execution receipt permits factual final report');
$bot->{pending}{coding_receipts}{published}{'a'x32}='https://github.com/burt-agent/workspace/commit/'.('a'x40);
like(Bot::Runtime::Workbench::verified_final_report($bot,$bot->{pending},
  'I published https://github.com/burt-agent/workspace/commit/'.('b'x40)),
  qr/report withheld/,'a publication receipt cannot validate a different commit URL');
is(Bot::Runtime::Workbench::verified_final_report($bot,$bot->{pending},
  'No proposal was created because the broker is unavailable.'),
  'No proposal was created because the broker is unavailable.',
  'a truthful denial of proposal creation is not suppressed');
like(Bot::Runtime::Workbench::verified_final_report($bot,$bot->{pending},'The proposal is ready.'),
  qr/report withheld/,'unreceipted proposal claim is withheld');
$bot->{pending}{coding_receipts}{proposal}='b'x32;
is(Bot::Runtime::Workbench::verified_final_report($bot,$bot->{pending},'The proposal is ready.'),
  'The proposal is ready.','proposal receipt permits factual final report');
$bot->{bot}='astrid';
is_deeply(Bot::Runtime::Workbench::tool_specs($bot),[],'other bots unchanged');
$bot->{bot}='burt';
local $ENV{BURT_WORKBENCH_SOCKET}='';
is_deeply(Bot::Runtime::Workbench::tool_specs($bot),[],'feature disabled by default');
done_testing;
