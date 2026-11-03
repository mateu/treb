use strict;
use warnings;
use Test::More;
use lib 'lib';
use Bot::Runtime::Workbench;

{
  package WorkbenchBot;
  sub _bot_name_slug { $_[0]{bot}//'burt' }
  sub _is_human_nick { $_[1] ne 'system' && $_[1] ne 'other_bot' }
  sub _pending_raid { $_[0]{pending} }
  sub _send_to_channel { push @{$_[0]{sent}}, $_[2] }
  package WorkbenchTool;
  sub text_result { $_[1] }
}

sub pending {
  return {
    channel => '#ai',
    expires_at => time + 100,
    messages => [{nick => 'mateu', source_kind => 'conversation', msg => 'please work on this'}],
  };
}

my $bot = bless {pending => pending()}, 'WorkbenchBot';
my $tool = bless {}, 'WorkbenchTool';
local $ENV{BURT_WORKBENCH_SOCKET} = '/not/a/socket';
local $ENV{IRC_SERVER} = 'irc.perl.org';
my %defs = map { $_->{name} => $_ } @{Bot::Runtime::Workbench::tool_specs($bot)};

is(scalar keys %defs, 16, 'thin proxy exposes the supported tool set');
ok(!exists $defs{create_repo_pull_request} && !exists $defs{inspect_repo_pull_request}
   && !exists $defs{merge_repo_pull_request},
  'legacy fixed-repository pull-request tools are absent');
ok(!exists $defs{propose_workbench_action} && !exists $defs{confirm_workbench_proposal},
  'obsolete proposal and confirmation tools are absent');
for my $name (keys %defs) {
  unlike($defs{$name}{description}, qr/(?:capability|grant|proposal|confirmation)/i,
    "$name description is a thin contract, not an authorization protocol");
}
like($defs{run_repo_project}{description}, qr/THIRTEEN total sandbox attempts/,
  'production sandbox budget remains documented');
{
  local $ENV{BURT_SANDBOX_ATTEMPTS} = 5;
  my %trial = map { $_->{name} => $_ } @{Bot::Runtime::Workbench::tool_specs($bot)};
  like($trial{run_code}{description}, qr/At most FIVE sandbox runs TOTAL/,
    'trial budget remains documented');
}

my $scope = Bot::Runtime::Workbench::request_scope($bot);
like($scope, qr/^[a-f0-9]{64}$/, 'active envelope yields an opaque scope');
is(Bot::Runtime::Workbench::trusted_requester($bot), 'mateu',
  'requester derives from the active human envelope');
$bot->{pending}{messages}[0]{msg} = 'unaddressed work is allowed';
like(Bot::Runtime::Workbench::request_scope($bot), qr/^[a-f0-9]{64}$/,
  'unaddressed human conversation remains an active envelope');
$bot->{pending}{messages}[0]{nick} = 'other';
isnt(Bot::Runtime::Workbench::request_scope($bot), $scope,
  'request scope binds the human message identity');
$bot->{pending}{messages}[0]{nick} = 'mateu';

for my $case (
  ['private channel', sub { $_[0]{channel} = 'mateu' }],
  ['wrong public channel', sub { $_[0]{channel} = '#other' }],
  ['expired envelope', sub { $_[0]{expires_at} = time - 1 }],
  ['reminder', sub { $_[0]{messages}[0]{source_kind} = 'reminder' }],
  ['history follow-up', sub { $_[0]{messages}[0]{source_kind} = 'activity_followup' }],
  ['bot message', sub { $_[0]{messages}[0]{nick} = 'other_bot' }],
) {
  my $p = pending();
  $case->[1]->($p);
  $bot->{pending} = $p;
  eval { Bot::Runtime::Workbench::request_scope($bot) };
  ok($@, "$case->[0] cannot supply an active trusted envelope");
}
$bot->{pending} = pending();
{
  local $ENV{IRC_SERVER} = 'irc.example.net';
  eval { Bot::Runtime::Workbench::request_scope($bot) };
  ok($@, 'another IRC network cannot supply Workbench provenance');
}
{
  local $ENV{BURT_WORKBENCH_SOCKET} = '';
  my $disabled = bless {bot => 'burt', pending => pending()}, 'WorkbenchBot';
  Bot::Runtime::Workbench::admit_task($disabled);
  ok(!$disabled->{pending}{coding_task}, 'disabled Workbench does not admit a task');
}
{
  my $other_bot = bless {bot => 'bert', pending => pending()}, 'WorkbenchBot';
  Bot::Runtime::Workbench::admit_task($other_bot);
  ok(!$other_bot->{pending}{coding_task}, 'non-Burt runtime does not admit a task');
}
$bot->{pending}{messages}[0]{msg} = 'Burt, resume the checkpoint abc';
ok(Bot::Runtime::Workbench::resume_requested($bot), 'natural resume-the-checkpoint form defers task admission');
$bot->{pending}{messages}[0]{msg} = 'write a resume parser';
Bot::Runtime::Workbench::admit_task($bot);
ok($bot->{pending}{coding_task}, 'ordinary work mentioning resume is not diverted to recovery');
$bot->{pending} = pending();
{
  no warnings 'redefine';
  my @called;
  local *Bot::Runtime::Workbench::broker_call = sub {
    my ($request) = @_; push @called, $request;
    return JSON::PP::encode_json({jobs => []}) if $request->{action} eq 'task_status';
    return JSON::PP::encode_json({checkpoint_id => 'a'x32, jobs => [], attempts_remaining => 13})
      if $request->{action} eq 'task_checkpoint';
    return JSON::PP::encode_json({}) if $request->{action} eq 'task_progress';
    return JSON::PP::encode_json({id => 'b'x32, state => 'passed', attempts_remaining => 12,
      result => {exit_code => 0}});
  };
  like($defs{run_code}{code}->($tool, {
    files => {'main.pl' => '1;'}, argv => ['/usr/bin/perl', '/work/main.pl'], title => 'probe',
  }), qr/"state":"passed"/, 'first Workbench invocation admits and dispatches execution');
  ok($bot->{pending}{coding_task}, 'first Workbench invocation marks the task admitted');
  is(scalar(grep { $_->{action} eq 'task_status' && $_->{phase} eq 'started' } @called), 1,
    'first invocation reports exactly one task start');
  my @scopes = map { $_->{scope} } grep { exists $_->{scope} } @called;
  is_deeply([grep { $_ ne $scopes[0] } @scopes], [], 'lifecycle and run calls share the admitted scope');
}

my @requests;
{
  no warnings 'redefine';
  local *Bot::Runtime::Workbench::broker_call = sub {
    my ($request) = @_;
    push @requests, $request;
    return JSON::PP::encode_json({reference => 'python-csv', text => 'documentation', untrusted => JSON::PP::true})
      if $request->{action} eq 'reference';
    return JSON::PP::encode_json({checkpoint_id => 'c'x32, jobs => [], attempts_remaining => 4})
      if $request->{action} eq 'task_checkpoint';
    return JSON::PP::encode_json({jobs => []})
      if $request->{action} eq 'task_status';
    return JSON::PP::encode_json({})
      if $request->{action} eq 'task_progress';
    return JSON::PP::encode_json({id => 'a'x32, state => 'passed', attempts_remaining => 12,
      result => {exit_code => 0}});
  };
  like($defs{read_coding_reference}{code}->($tool, {key => 'python-csv'}),
    qr/documentation/, 'reference dispatch succeeds through broker');
}
my $reference = $requests[-1];
is_deeply([sort keys %$reference], [sort qw(action channel key network requester scope)],
  'structured reference dispatch derives provenance only from runtime state');
is($reference->{requester}, 'mateu', 'dispatch derives requester');
is($reference->{channel}, '#ai', 'dispatch derives channel');
is($reference->{network}, 'irc.perl.org', 'dispatch fixes network');
like($reference->{scope}, qr/^[a-f0-9]{64}$/, 'dispatch derives scope');
ok(!exists($reference->{capability}) && !exists($reference->{grant}),
  'dispatch carries no capability or grant');
like($defs{read_coding_reference}{code}->($tool, {key => 'python-csv', requester => 'mallory'}),
  qr/Invalid tool fields/, 'model cannot select requester provenance');

$bot->{pending} = pending();
$bot->{pending}{channel} = '#mateu-test';
{
  no warnings 'redefine';
  local *Bot::Runtime::Workbench::broker_call = sub {
    my ($request) = @_; push @requests, $request; return '{}';
  };
  $defs{read_repo_project}{code}->($tool, {branch => 'burt/dictionary', project => 'dictionary'});
}
is($requests[-1]{channel}, '#mateu-test', 'test channel is runtime-derived, never hardcoded');
ok(!exists $defs{publish_repo}, 'legacy repository publication tool is removed');

$bot->{pending} = pending();
my @lifecycle;
{
  no warnings 'redefine';
  local *Bot::Runtime::Workbench::broker_call = sub {
    my ($request) = @_; push @lifecycle, $request;
    return JSON::PP::encode_json({jobs => []}) if $request->{action} eq 'task_status';
    return JSON::PP::encode_json({checkpoint_id => 'c'x32, jobs => [], attempts_remaining => 4})
      if $request->{action} eq 'task_checkpoint';
    return JSON::PP::encode_json({}) if $request->{action} eq 'task_progress';
    return JSON::PP::encode_json({id => 'd'x32, state => 'passed', attempts_remaining => 12,
      result => {exit_code => 0}});
  };
  Bot::Runtime::Workbench::admit_task($bot);
}
ok($bot->{pending}{coding_task}, 'active human conversation admits a lifecycle task');
is($bot->{pending}{coding_requester}, 'mateu', 'task freezes derived requester');
like($bot->{pending}{coding_scope}, qr/^[a-f0-9]{64}$/, 'task freezes derived scope');
ok(grep($_->{action} eq 'task_status', @lifecycle), 'admission reports lifecycle status');
ok(grep($_->{action} eq 'task_checkpoint', @lifecycle), 'admission records a checkpoint');
ok(grep($_->{action} eq 'task_progress', @lifecycle), 'admission reports a progress receipt');

my $task_scope = $bot->{pending}{coding_scope};
my $task_expiry = $bot->{pending}{expires_at};
Bot::Runtime::Workbench::admit_task($bot);
is($bot->{pending}{coding_scope}, $task_scope, 'admission does not replace frozen scope');
is($bot->{pending}{expires_at}, $task_expiry, 'admission does not renew the deadline');

my @run_requests;
{
  no warnings 'redefine';
  local *Bot::Runtime::Workbench::broker_call = sub {
    my ($request) = @_; push @run_requests, $request;
    return JSON::PP::encode_json({}) if $request->{action} eq 'task_progress';
    return JSON::PP::encode_json({id => 'e'x32, state => 'passed', attempts_remaining => 12,
      result => {exit_code => 0}});
  };
  like($defs{run_code}{code}->($tool, {
    files => {'main.pl' => 'print qq(ok\n);'}, argv => ['/usr/bin/perl', '/work/main.pl'], title => 'probe',
  }), qr/"state":"passed"/, 'admitted task dispatches execution');
}
my ($run) = grep { $_->{action} eq 'run' } @run_requests;
is_deeply([sort grep { $_ ne 'files' && $_ ne 'argv' && $_ ne 'title' } keys %$run],
  [sort qw(action channel network requester scope)], 'run adds only derived provenance');
ok(!exists($run->{capability}) && !exists($run->{grant}), 'run has no authorization payload');
is($bot->{pending}{coding_attempts_remaining}, 12, 'broker attempt receipt reaches runtime state');

Bot::Runtime::Workbench::report_result($bot, 'publish',
  JSON::PP::encode_json({id => 'b'x32, state => 'uncertain'}));
like($bot->{sent}[-1], qr/success unconfirmed.*do not retry/,
  'uncertain publication directs reconciliation instead of retry');
delete $bot->{pending}{coding_stop_reason};
Bot::Runtime::Workbench::report_result($bot, 'repo_publish', JSON::PP::encode_json({
  error => 'request rejected by Workbench policy', rejection_schema => 1,
  code => 'invalid_request', disposition => 'retryable',
}));
like($bot->{sent}[-1], qr/repo_publish: error; invalid_request/,
  'no-candidate publication preflight reports its safe rejection');
unlike($bot->{sent}[-1], qr/success unconfirmed|operator reconciliation|do not retry/,
  'safe publication preflight is not misreported as an uncertain write');
ok(!$bot->{pending}{coding_stop_reason},
  'safe publication preflight does not terminally stop the task');
Bot::Runtime::Workbench::report_result($bot, 'repo_run',
  JSON::PP::encode_json({id => 'f'x32, state => 'failed', attempts_remaining => 0,
    result => {exit_code => 1, output => 'INJECTED'}}));
like($bot->{sent}[-1], qr/exit 1/, 'task result reports broker exit code');
unlike($bot->{sent}[-1], qr/INJECTED/, 'untrusted output is not echoed to channel');
like($bot->{pending}{coding_stop_reason}, qr/attempt budget exhausted/,
  'final failed attempt stops task');

$bot->{pending} = pending();
$bot->{pending}{messages}[0]{msg} = 'resume checkpoint';
my @resume;
my $resume_state='passed';
{
  no warnings 'redefine';
  local *Bot::Runtime::Workbench::broker_call = sub {
    my ($request) = @_; push @resume, $request;
    return JSON::PP::encode_json({jobs => []}) if $request->{action} eq 'checkpoint_status';
    return JSON::PP::encode_json({
      resumed_scope => $request->{scope}, jobs => [], attempts_remaining => 4,
      latest_execution_job => {id => 'd'x32, state => $resume_state},
      latest_repository_job => {id => 'd'x32, state => 'published'},
      latest_publication_job => {id => 'd'x32,
        url => 'https://github.com/burt-agent/workspace/commit/'.('e'x40)},
    }) if $request->{action} eq 'task_resume';
    return JSON::PP::encode_json({checkpoint_id => 'c'x32, jobs => [], attempts_remaining => 4})
      if $request->{action} eq 'task_checkpoint';
    return JSON::PP::encode_json({});
  };
  like($defs{coding_checkpoint_status}{code}->($tool, {checkpoint_id => 'a'x32}),
    qr/jobs/, 'checkpoint status remains available for an explicit resume envelope');
  ok(!$bot->{pending}{coding_task}, 'checkpoint status does not accidentally admit an explicit resume request');
  like($defs{resume_coding_task}{code}->($tool, {checkpoint_id => 'a'x32}),
    qr/resumed_scope/, 'resume restores a checkpoint using a fresh envelope');
  $resume_state='failed';
  $bot->{pending}=pending();
  $bot->{pending}{messages}[0]{msg}='resume checkpoint';
  $defs{resume_coding_task}{code}->($tool, {checkpoint_id=>'a'x32});
  like(Bot::Runtime::Workbench::verified_final_report($bot,$bot->{pending},'job '.('d'x32)),
    qr/^job d{32}
\[verified: tests failed - job d{8}/,
    'failed resumed execution remains backed and renders failed status');
  $resume_state='passed';
  $bot->{pending}=pending();
  $bot->{pending}{messages}[0]{msg}='resume checkpoint';
  $defs{resume_coding_task}{code}->($tool, {checkpoint_id=>'a'x32});

}
is($bot->{pending}{coding_requester}, 'mateu', 'resume keeps runtime-derived requester');
is($bot->{pending}{coding_receipts}{passed}{'d'x32}, 1, 'resume restores execution receipt');
is($bot->{pending}{coding_receipts}{published}{'d'x32},
  'https://github.com/burt-agent/workspace/commit/'.('e'x40),
  'resume restores publication receipt');
like(Bot::Runtime::Workbench::verified_final_report($bot, $bot->{pending},
  'Tests passed and the saved bundle was published.'),
  qr/^Tests passed and the saved bundle was published\.\n\[verified:/, 'restored receipts support truthful report');

$bot->{pending} = {coding_task => 1, coding_last_result => 'No verified work result recorded.'};
like(Bot::Runtime::Workbench::verified_final_report($bot, $bot->{pending}, 'Tests passed and I pushed it.'),
  qr/^Tests passed and I pushed it\.\n\[verified:/, 'prose verbs are not receipt claims');

{
  $bot->{pending}=pending();
  no warnings 'redefine';
  my $runs=0;
  my $raw=JSON::PP::encode_json({rejection_schema=>1,code=>'invalid_request',
    disposition=>'terminal',retryable=>JSON::PP::false,
    reason=>'operator verification policy required for this project',
    required_action=>'The branch is not approved for test runs; the operator needs to add it to the verification policy.'});
  local *Bot::Runtime::Workbench::broker_call=sub {
    return '{}' unless $_[0]{action} eq 'repo_run';
    $runs++; return $raw;
  };
  my $args={snapshot_id=>'a'x32,changes=>{},delete=>[],argv=>['/usr/bin/perl','test.pl'],title=>'test'};
  $defs{run_repo_project}{code}->($tool,$args);
  $defs{run_repo_project}{code}->($tool,{%$args});
  is($runs,1,'identical policy rejection short-circuits before broker dispatch');
  my $report=Bot::Runtime::Workbench::verified_final_report($bot,$bot->{pending},
    'Both repo read and test failed twice.');
  like($report,qr/repo_run blocked: operator verification policy required/,'report preserves actual action and reason');
  like($report,qr/operator needs to add it/,'report includes concrete remedy');
  like($report,qr/Both repo read and test failed twice/,'policy status does not replace model prose');
  like(Bot::Runtime::Workbench::finish_task($bot,$bot->{pending},'runtime_error'),
    qr/operator verification policy required/,'stop path also preserves policy reason');
  $bot->{pending}=pending();
  $raw=JSON::PP::encode_json({rejection_schema=>1,code=>'transport_unavailable',
    disposition=>'retryable',message=>'broker unavailable; operator inspection required'});
  $runs=0;
  $defs{run_repo_project}{code}->($tool,$args);
  $defs{run_repo_project}{code}->($tool,$args);
  is($runs,2,'transient errors retain retry dispatch behavior');

}

{
  my $p={coding_task=>1};
  $bot->{pending}=$p;
  Bot::Runtime::Workbench::report_result($bot,'repo_run',JSON::PP::encode_json({id=>'8'x32,state=>'passed',result=>{output=>"Files=23, Tests=1209\nResult: PASS"}}));
  for my $text ('Nothing published - main already has it', 'No need to publish; already committed on main', 'already pushed to main', 'clean run - Result: PASS, 23 files, 1209 tests', 'v0.08 10.7k line 123') {
    like(Bot::Runtime::Workbench::verified_final_report($bot,$p,$text),qr/^\Q$text\E\n\[verified:/,'prose preserved with status');
  }
  for my $case (['commit abc1234','commit abc1234'],['24 files, 1209 tests','24 files/1209 tests'],['job '.('9'x32),'job '.('9'x32)],['https://github.com/burt-agent/workspace/commit/'.('a'x40),'URL']) {
    my $v=Bot::Runtime::Workbench::verified_final_report($bot,$p,$case->[0]);
    like($v,qr/report withheld:.*\Q$case->[1]\E/,'names unbacked artifact');
    like($v,qr/\[verified: tests passed - job 88888888, 23 files\/1209 tests; publication: none this task\]/,'status survives withholding');
  }
  for my $text ('I edited 3 files', 'added 2 tests', 'mateu/treb PR #88 fixed the policy',
      'pull request #88', 'https://github.com/mateu/treb/pull/88',
      'https://github.com/other/repo/commit/'.('b'x40),
      'https://gist.github.com/other/'.('b'x32),
      '23 files/1209 tests', '23 files and 1209 tests') {
    like(Bot::Runtime::Workbench::verified_final_report($bot,$p,$text),
      qr/^\Q$text\E
\[verified:/,'ordinary prose or backed paired counts preserved');
  }
  Bot::Runtime::Workbench::report_result($bot,'repo_read',JSON::PP::encode_json({
    base_sha=>'be22ae6d'.('c'x32),tree_sha=>'abcdef12'.('d'x32),
    files=>{'untrusted'=>'commit deadbee'}}),1);
  for my $sha ('be22ae6d','abcdef12') {
    like(Bot::Runtime::Workbench::verified_final_report($bot,$p,"commit $sha"),
      qr/^commit $sha
\[verified:/,'snapshot SHA prefix is backed');
  }
  like(Bot::Runtime::Workbench::verified_final_report($bot,$p,'commit deadbee'),
    qr/report withheld: commit deadbee/,'snapshot file contents cannot back SHA');
  like(Bot::Runtime::Workbench::verified_final_report($bot,{coding_task=>1},'done'),qr/tests: no runs recorded/,'no run status');
  Bot::Runtime::Workbench::report_result($bot,'repo_run',JSON::PP::encode_json({id=>'7'x32,state=>'failed'}));
  like(Bot::Runtime::Workbench::verified_final_report($bot,$p,'done'),qr/tests failed - job 77777777/,'failed status');
  my $url='https://gist.github.com/burt-agent/'.('a'x32);
  Bot::Runtime::Workbench::report_result($bot,'publish',JSON::PP::encode_json({id=>'7'x32,state=>'published',url=>$url}));
  like(Bot::Runtime::Workbench::verified_final_report($bot,$p,$url),qr/^\Q$url\E\n\[verified:.*publication: \Q$url\E/,'gist ID is not mistaken for a job and publication is rendered');
  for my $action (qw(repo_inspect job_inspect)) {
    Bot::Runtime::Workbench::report_result($bot,$action,JSON::PP::encode_json({
      id=>'6'x32,state=>'published',execution_state=>'passed',
      result=>{output=>"Files=42, Tests=1500
"}}),1);
    like(Bot::Runtime::Workbench::verified_final_report($bot,$p,'42 files, 1500 tests'),
      qr/^42 files, 1500 tests
/,'inspection restores saved count evidence');
    is($p->{coding_last_execution_job},'7'x32,'inspection does not change latest execution');
  }
  like(Bot::Runtime::Workbench::verified_final_report($bot,$p,'job 88888888'),qr/^job 88888888\n/,'unique explicit job prefix backed');
  like(Bot::Runtime::Workbench::verified_final_report($bot,$p,'Files=23, Tests=1209'),qr/^Files=23, Tests=1209\n/,'paired harness counts backed');
  like(Bot::Runtime::Workbench::verified_final_report($bot,$p,'burt-agent/workspace#99'),qr/report withheld: PR burt-agent\/workspace#99/,'unbacked PR named');
  Bot::Runtime::Workbench::report_result($bot,'publish',JSON::PP::encode_json({state=>'uncertain'}));
  like(Bot::Runtime::Workbench::verified_final_report($bot,$p,'done'),qr/uncertain write/,'uncertain publication rendered');
  Bot::Runtime::Workbench::github_receipt($bot,$p,'github_api',{outcome_uncertain=>1,method=>'POST',path=>'/repos/o/r/issues'});
  Bot::Runtime::Workbench::report_result($bot,'publish',JSON::PP::encode_json({id=>'7'x32,state=>'published',url=>$url}));
  like(Bot::Runtime::Workbench::verified_final_report($bot,$p,'done'),qr/uncertain write/,
    'successful bundle publication does not reconcile unrelated account write');


}

$bot->{bot} = 'astrid';
is_deeply(Bot::Runtime::Workbench::tool_specs($bot), [], 'other bots remain unchanged');
$bot->{bot} = 'burt';
local $ENV{BURT_WORKBENCH_SOCKET} = '';
is_deeply(Bot::Runtime::Workbench::tool_specs($bot), [], 'feature remains disabled without socket');
done_testing;
