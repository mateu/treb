use strict;
use warnings;
use Test::More;
use JSON::PP ();
use lib 'lib';
use Bot::Runtime::Workbench;

{
  package GitHubBot;
  sub _bot_name_slug { $_[0]{bot}//'burt' }
  sub _is_human_nick { $_[1] ne 'other_bot' }
  sub _pending_raid { $_[0]{pending} }
  sub _send_to_channel { push @{$_[0]{sent}}, $_[2] }
  package GitHubTool;
  sub text_result { $_[1] }
}

sub pending {
  return {channel=>'#ai', expires_at=>time+100,
    messages=>[{nick=>'MaTeU', source_kind=>'conversation', msg=>'burt_bot: open an issue for this'}]};
}

my @github=qw(github_whoami github_api github_read github_commit_files);
my $tool=bless {}, 'GitHubTool';
local $ENV{IRC_SERVER}='irc.perl.org';

{
  local $ENV{BURT_WORKBENCH_SOCKET}='';
  my $bot=bless {pending=>pending()}, 'GitHubBot';
  is_deeply(Bot::Runtime::Workbench::tool_specs($bot), [], 'no GitHub tools without the broker socket');
}
local $ENV{BURT_WORKBENCH_SOCKET}='/test/socket';
{
  my $other=bless {bot=>'treb', pending=>pending()}, 'GitHubBot';
  is_deeply(Bot::Runtime::Workbench::tool_specs($other), [], 'no GitHub tools for another bot profile');
}

my $bot=bless {pending=>pending()}, 'GitHubBot';
my %defs=map { $_->{name}=>$_ } @{Bot::Runtime::Workbench::tool_specs($bot)};
ok($defs{$_}, "$_ is exposed for Burt with the socket enabled") for @github;
ok(!exists $defs{$_}{input_schema}{properties}{requester}, "$_ schema has no requester field") for @github;
ok(!exists $defs{publish_repo}, 'publish_repo is not exposed');
is($defs{github_commit_files}{input_schema}{properties}{from_job}{type}, 'string', 'tested job is an optional commit source');
is_deeply([sort @{$defs{github_commit_files}{input_schema}{required}}], [qw(branch message repo)], 'commit requires destination/message but chooses files or from_job');
is_deeply([sort @{$defs{github_api}{input_schema}{required}}], [qw(method path)], 'github_api requires method and path');
is_deeply([sort @{$defs{github_commit_files}{input_schema}{required}}], [qw(branch message repo)], 'commit schema permits either source');
ok(exists $defs{github_commit_files}{input_schema}{properties}{from_job}, 'commit schema exposes tested job source');
ok(!exists $defs{publish_repo}, 'legacy repository publish tool is absent');
like($defs{github_api}{description}, qr/api\.github\.com/, 'github_api documents the fixed host');
like($defs{github_whoami}{description}, qr/never assume an account name/i, 'whoami discourages hard-coded identity');
for my $name (keys %defs) {
  unlike($defs{$name}{description}, qr/burt-agent\b(?!\/workspace)/, "$name does not hard-code the account")
    if $name =~ /\Agithub_/;
}

my @calls;
my %reply;
sub broker {
  my ($request)=@_;
  push @calls, $request;
  return JSON::PP::encode_json({jobs=>[]}) if $request->{action} eq 'task_status';
  return JSON::PP::encode_json({checkpoint_id=>'c'x32, jobs=>[], attempts_remaining=>13})
    if $request->{action} eq 'task_checkpoint';
  return JSON::PP::encode_json({}) if $request->{action} eq 'task_progress';
  return $reply{$request->{action}} // JSON::PP::encode_json({ok=>JSON::PP::true, status=>200, write=>JSON::PP::false});
}

{
  no warnings 'redefine';
  local *Bot::Runtime::Workbench::broker_call=\&broker;
  local $ENV{BURT_GITHUB_WRITERS}=' mateu ,someone';
  $reply{github_whoami}=JSON::PP::encode_json({login=>'acct', scopes=>['repo']});
  my $raw=$defs{github_whoami}{code}->($tool, {});
  like($raw, qr/"login":"acct"/, 'first GitHub tool call dispatches to the broker');
  ok($bot->{pending}{coding_task}, 'first GitHub tool call lazily admits the task');
  is(scalar(grep { $_->{action} eq 'task_status' && $_->{phase} eq 'started' } @calls), 1,
    'lazy admission reports exactly one task start');
  my ($who)=grep { $_->{action} eq 'github_whoami' } @calls;
  is($who->{requester}, 'mateu', 'broker receives the envelope requester, folded');
  is_deeply([map { $who->{$_} } qw(channel network)], ['#ai', 'irc.perl.org'], 'broker receives envelope channel/network');
  my @scopes=map { $_->{scope} } @calls;
  is_deeply([grep { $_ ne $scopes[0] } @scopes], [], 'lifecycle and GitHub calls share the admitted scope');
  ok(!(grep { /github_whoami started/ } @{$bot->{sent}//[]}), 'GitHub reads do not spend progress notices');

  @calls=();
  like($defs{github_api}{code}->($tool, {method=>'GET', path=>'/user', requester=>'other'}), qr/Error: Invalid tool fields/,
    'model cannot supply a requester');
  like($defs{github_api}{code}->($tool, {method=>'GET', path=>'/user', scope=>'f'x64}), qr/Error: Invalid tool fields/,
    'model cannot supply a scope');
  is(scalar(grep { $_->{action} =~ /\Agithub_/ } @calls), 0, 'rejected arguments never reach the broker');

  $defs{github_api}{code}->($tool, {method=>'POST', path=>'/repos/o/r/issues', body=>{title=>'t'}});
  my ($write)=grep { $_->{action} eq 'github_api' } @calls;
  is($write->{requester}, 'mateu', 'write requester comes from the envelope');
  is_deeply($write->{body}, {title=>'t'}, 'body is forwarded unchanged');
}

{
  no warnings 'redefine';
  local *Bot::Runtime::Workbench::broker_call=\&broker;
  local $ENV{BURT_GITHUB_WRITERS}='someone-else';
  @calls=();
  like($defs{github_api}{code}->($tool, {method=>'post', path=>'/repos/o/r/issues', body=>{}}),
    qr/Error: GitHub writes require an allowlisted trusted requester/, 'non-writer write fails fast');
  like($defs{github_commit_files}{code}->($tool, {repo=>'o/r', branch=>'b', files=>{a=>'b'}, message=>'m'}),
    qr/Error: GitHub writes require/, 'non-writer commit fails fast');
  is(scalar(grep { $_->{action} =~ /\Agithub_/ } @calls), 0, 'denied writes never reach the broker');
  unlike($defs{github_api}{code}->($tool, {method=>'GET', path=>'/repos/o/r'}), qr/Error/, 'non-writer reads work');
  unlike($defs{github_api}{code}->($tool, {method=>'POST', path=>'/graphql', body=>{query=>'{viewer{login}}'}}),
    qr/Error/, 'GraphQL queries are left to broker classification');
  local $ENV{BURT_GITHUB_WRITERS}='';
  like($defs{github_api}{code}->($tool, {method=>'DELETE', path=>'/repos/o/r/issues/comments/1'}),
    qr/Error: GitHub writes require/, 'empty allowlist means no writes');
}

{
  no warnings 'redefine';
  local *Bot::Runtime::Workbench::broker_call=\&broker;
  local $ENV{BURT_GITHUB_WRITERS}='MATEU';
  my $sha='e'x40;
  my $url="https://github.com/o/r/commit/$sha";
  $reply{github_commit_files}=JSON::PP::encode_json({ok=>JSON::PP::true, write=>JSON::PP::true,
    commit_sha=>$sha, commit_url=>$url});
  $defs{github_commit_files}{code}->($tool, {repo=>'o/r', branch=>'topic', files=>{a=>'b'}, message=>'m'});
  $defs{github_commit_files}{code}->($tool, {repo=>'o/r', branch=>'topic', from_job=>'a'x32, message=>'tested'});
  is($calls[-1]{from_job}, 'a'x32, 'runtime forwards explicit tested job');
  ok(!exists $calls[-1]{files}, 'tested source never adds caller files');
  my $pending=$bot->{pending};
  like(Bot::Runtime::Workbench::verified_final_report($bot, $pending, "I committed the change: $url"),
    qr/^I committed the change: \Q$url\E\n\[verified:/, 'commit claims backed by a GitHub receipt are allowed');
  like(Bot::Runtime::Workbench::verified_final_report($bot, $pending,
    'I committed it: https://github.com/o/r/commit/'.('f'x40)), qr/report withheld/,
    'a commit URL without a receipt is withheld');

  my $fresh=bless {pending=>pending()}, 'GitHubBot';
  my %fresh_defs=map { $_->{name}=>$_ } @{Bot::Runtime::Workbench::tool_specs($fresh)};
  $reply{github_api}=JSON::PP::encode_json({ok=>JSON::PP::false, write=>JSON::PP::true, outcome_uncertain=>JSON::PP::true,
    method=>'POST', path=>'/repos/o/r/issues', request_id=>undef, instruction=>'verify'});
  $fresh_defs{github_api}{code}->($tool, {method=>'POST', path=>'/repos/o/r/issues', body=>{}});
  like($fresh->{sent}[-1], qr{github_api: GitHub write outcome uncertain \(POST /repos/o/r/issues\); verify},
    'uncertain writes notify the channel');
  ok(!$fresh->{pending}{coding_stop_reason}, 'uncertain GitHub writes do not stop the task');
  like(Bot::Runtime::Workbench::verified_final_report($fresh, $fresh->{pending}, 'I pushed the fix.'),
    qr/publication: none this task; uncertain write/, 'uncertain write status is authoritative');
  delete $reply{github_api};
}

done_testing;
