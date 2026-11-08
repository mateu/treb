use strict;
use warnings;
use Test::More;
use JSON::PP ();
use lib 'lib';
use Bot::Runtime::Workbench;

{
  package PublicationBot;
  sub _pending_raid { $_[0]{pending} }
  sub _send_to_channel { push @{$_[0]{sent}}, $_[2] }
  sub _bot_name_slug { 'burt' }
  sub get_nickname { 'burt_bot' }
  sub _is_human_nick { 1 }
  package PublicationTool;
  sub text_result { $_[1] }
}

my $bot=bless {pending=>{coding_task=>1,channel=>'#ai',expires_at=>time+100,
  messages=>[{nick=>'mateu',source_kind=>'conversation',
    msg=>'burt_bot: write code and publish a gist and commit to the repository'}]}},'PublicationBot';
my $warning=qr/success unconfirmed; the public write may already have succeeded; operator reconciliation required before retrying; do not retry/;

for my $action (qw(publish)) {
  for my $response (
    {error=>'submission failed or response lost; operator reconciliation required; do not retry; INJECTED'},
    {error=>'broker unavailable; operator inspection required'},
    {id=>'a'x32,state=>'uncertain'},
    {id=>'a'x32,state=>'publishing'},
    {state=>'published',error=>'INJECTED contradictory envelope'},
    [],
  ) {
    Bot::Runtime::Workbench::report_result($bot,$action,JSON::PP::encode_json($response));
    like($bot->{sent}[-1],$warning,"$action warns on unconfirmed publication");
    unlike($bot->{sent}[-1],qr/INJECTED/,"$action does not echo arbitrary error text");
    is($bot->{pending}{coding_last_result},$bot->{sent}[-1],
      "$action retains publication warning for terminal failure reporting");
  }
  Bot::Runtime::Workbench::report_result($bot,$action,'not JSON');
  like($bot->{sent}[-1],$warning,"$action malformed response is unconfirmed");
  my $url=$action eq 'publish' ? 'https://gist.github.com/burt-agent/abcdef'
    : 'https://github.com/burt-agent/workspace/commit/'.('b'x40);
  Bot::Runtime::Workbench::report_result($bot,$action,JSON::PP::encode_json({
    id=>'a'x32,state=>'published',url=>$url}));
  like($bot->{sent}[-1],qr/\Q$url\E/,"$action confirmed publication keeps actual URL");
  unlike($bot->{sent}[-1],$warning,"$action confirmed publication has no uncertainty warning");
}

# Exercise the real tool callbacks, including transport exceptions after dispatch.
local $ENV{BURT_WORKBENCH_SOCKET}='/test/socket';
local $ENV{IRC_SERVER}='irc.perl.org';
my %tools=map {$_->{name}=>$_} @{Bot::Runtime::Workbench::tool_specs($bot)};
my $tool=bless {},'PublicationTool';
ok(!exists $tools{publish_repo}, 'legacy repository publication callback is absent');
for my $name (qw(publish_gist)) {
  no warnings qw(redefine once);
  local *Bot::Runtime::Workbench::broker_call=sub {
    die "Workbench read failed\n";
  };
  $bot->{pending}{messages}=[{nick=>'mateu',source_kind=>'conversation',
    msg=>$name eq 'publish_gist' ? 'burt_bot: publish a gist' : 'burt_bot: please push your dictionary coding work'}];
  my $args=$name eq 'publish_gist' ? {id=>'a'x32} : {};
  my $result=$tools{$name}{code}->($tool,$args);
  like($result,qr/Error: Workbench read failed/,"$name retains transport failure for model");
  like($bot->{sent}[-1],$warning,"$name transport failure warns channel without model help");
  is($bot->{pending}{coding_last_result},$bot->{sent}[-1],"$name saves transport warning");
}

Bot::Runtime::Workbench::report_result($bot,'repo_run',JSON::PP::encode_json({error=>'INJECTED'}));
unlike($bot->{sent}[-1],$warning,'test errors are not misreported as public writes');
unlike($bot->{sent}[-1],qr/INJECTED/,'test error text is not echoed');

# D4: report_result appends the labeled-kill text after the exit code, and
# nothing extra for an ordinary exited result.
for my $case (
  [time_limit=>'stopped by the 20 s sandbox time limit'],
  [memory_limit=>'stopped by the 256 MiB sandbox memory limit'],
  [output_limit=>'stopped by the 64 KiB sandbox output limit'],
) {
  my ($reason,$text)=@$case;
  Bot::Runtime::Workbench::report_result($bot,'run',JSON::PP::encode_json({
    id=>'a'x32,state=>'failed',result=>{exit_code=>1,reason=>$reason}}));
  like($bot->{sent}[-1],qr/\Qexit 1; $text\E/,"run notice names the $reason limit");
}
Bot::Runtime::Workbench::report_result($bot,'run',JSON::PP::encode_json({
  id=>'a'x32,state=>'failed',result=>{exit_code=>1,reason=>'exited'}}));
unlike($bot->{sent}[-1],qr/sandbox (?:time|memory|output) limit/,
  'an ordinary exited failure gets no limit text');

# D5: the four tool descriptions carry the shared limit-reason sentence.
my $limit_sentence=qr/result\.reason time_limit\/memory_limit\/output_limit means the sandbox stopped the job at that limit, not that the code failed its tests; do not rewrite code to fix it; tell the requester which limit was hit\./;
for my $name (qw(run_code run_repo_project repair_repo_project diagnose_repo_job)) {
  like($tools{$name}{description},$limit_sentence,"$name describes sandbox limit reasons");
}

done_testing;
