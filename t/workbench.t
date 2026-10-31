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

is(scalar keys %defs, 13, 'thin proxy exposes the supported tool set');
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
  my $called = 0;
  local *Bot::Runtime::Workbench::broker_call = sub { $called++; return '{}'; };
  like($defs{run_code}{code}->($tool, {
    files => {'main.pl' => '1;'}, argv => ['/usr/bin/perl', '/work/main.pl'], title => 'probe',
  }), qr/No admitted coding task for run/, 'execution requires task lifecycle admission');
  is($called, 0, 'unadmitted execution does not reach the broker');
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
like($defs{publish_repo}{code}->($tool, {id => 'x'}), qr/Invalid tool fields/,
  'repository publication takes no model-selected job or destination');

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

Bot::Runtime::Workbench::report_result($bot, 'repo_publish',
  JSON::PP::encode_json({id => 'b'x32, state => 'uncertain'}));
like($bot->{sent}[-1], qr/success unconfirmed.*do not retry/,
  'uncertain publication directs reconciliation instead of retry');
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
{
  no warnings 'redefine';
  local *Bot::Runtime::Workbench::broker_call = sub {
    my ($request) = @_; push @resume, $request;
    return JSON::PP::encode_json({
      resumed_scope => $request->{scope}, jobs => [], attempts_remaining => 4,
      latest_execution_job => {id => 'd'x32, state => 'passed'},
      latest_repository_job => {id => 'd'x32, state => 'published'},
      latest_publication_job => {id => 'd'x32,
        url => 'https://github.com/burt-agent/workspace/commit/'.('e'x40)},
    }) if $request->{action} eq 'task_resume';
    return JSON::PP::encode_json({checkpoint_id => 'c'x32, jobs => [], attempts_remaining => 4})
      if $request->{action} eq 'task_checkpoint';
    return JSON::PP::encode_json({});
  };
  like($defs{resume_coding_task}{code}->($tool, {checkpoint_id => 'a'x32}),
    qr/resumed_scope/, 'resume restores a checkpoint using a fresh envelope');
}
is($bot->{pending}{coding_requester}, 'mateu', 'resume keeps runtime-derived requester');
is($bot->{pending}{coding_receipts}{passed}{'d'x32}, 1, 'resume restores execution receipt');
is($bot->{pending}{coding_receipts}{published}{'d'x32},
  'https://github.com/burt-agent/workspace/commit/'.('e'x40),
  'resume restores publication receipt');
is(Bot::Runtime::Workbench::verified_final_report($bot, $bot->{pending},
  'Tests passed and the saved bundle was published.'),
  'Tests passed and the saved bundle was published.', 'restored receipts support truthful report');

$bot->{pending} = {coding_task => 1, coding_last_result => 'No verified work result recorded.'};
like(Bot::Runtime::Workbench::verified_final_report($bot, $bot->{pending}, 'Tests passed and I pushed it.'),
  qr/report withheld/, 'unreceipted claims remain withheld');

$bot->{bot} = 'astrid';
is_deeply(Bot::Runtime::Workbench::tool_specs($bot), [], 'other bots remain unchanged');
$bot->{bot} = 'burt';
local $ENV{BURT_WORKBENCH_SOCKET} = '';
is_deeply(Bot::Runtime::Workbench::tool_specs($bot), [], 'feature remains disabled without socket');
done_testing;
