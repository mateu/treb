use strict;
use warnings;
use Test::More;
use JSON::PP ();
use lib 'lib';
use Bot::Runtime::Workbench;
{
  package TerminalBot;
  sub _pending_raid { $_[0]{pending} }
  sub _send_to_channel { push @{$_[0]{sent}}, $_[2] }
  sub _bot_name_slug { 'burt' }
  sub get_nickname { 'burt_bot' }
  sub _is_human_nick { 1 }
}
local $ENV{BURT_WORKBENCH_SOCKET}='/test/socket';
local $ENV{IRC_SERVER}='irc.perl.org';
my $p={channel=>'#mateu-test',expires_at=>time+100,messages=>[
  {nick=>'mateu',source_kind=>'conversation',msg=>'burt_bot: write code and commit to repository'}]};
my $bot=bless {pending=>$p},'TerminalBot';
my @requests;
{
  no warnings 'redefine';
  local *Bot::Runtime::Workbench::broker_call=sub { push @requests,$_[0]; '{"jobs":[]}' };
  Bot::Runtime::Workbench::admit_task($bot);
  like($p->{coding_scope},qr/\A[a-f0-9]{64}\z/,'admission freezes trusted scope');
  is($requests[0]{phase},'started','admission persisted');
  is($requests[0]{channel},'#mateu-test','actual channel bound to status');
  $p->{expires_at}=time-1;
  $bot->{pending}=undef;
  my $notice=Bot::Runtime::Workbench::finish_task($bot,$p,'iteration_limit');
  like($notice,qr/No project bundle was saved.*not continuing/,'zero-job stop is honest');
  unlike($notice,qr/Saved bundles\/results/,'no blanket recovery promise');
  is($requests[-1]{scope},$p->{coding_scope},'terminal snapshot works after expiry and pending cleanup');
  is($requests[-1]{reason},'iteration_limit','operator gets trusted terminal reason');
}
for my $jobs (
  [{id=>'a'x32,state=>'failed'},{id=>'b'x32,state=>'uncertain'}],
  [{id=>'c'x32,state=>'running'}],
) {
  no warnings 'redefine';
  local *Bot::Runtime::Workbench::broker_call=sub { JSON::PP::encode_json({jobs=>$jobs}) };
  my $notice=Bot::Runtime::Workbench::finish_task($bot,$p,'runtime_error');
  for my $job (@$jobs) {
    like($notice,qr/\Q$job->{id} ($job->{state})\E/,'broker IDs and states retained even when tool reply was lost');
  }
}
for my $bad ('{"jobs":[{"id":"INJECTED","state":"failed"}]}','{"jobs":[],"error":"unavailable"}', '{}', '[]') {
  no warnings 'redefine';
  local *Bot::Runtime::Workbench::broker_call=sub {$bad};
  like(Bot::Runtime::Workbench::finish_task($bot,$p,'runtime_error'),qr/status unavailable/,'invalid/error status never promises no saved job');
}
{
  no warnings 'redefine';
  local *Bot::Runtime::Workbench::broker_call=sub {die "SECRET exception\n"};
  my $notice=Bot::Runtime::Workbench::finish_task($bot,$p,'deadline');
  like($notice,qr/status unavailable/,'transport failure is uncertain, not zero jobs');
  unlike($notice,qr/SECRET/,'exception text is not sent to IRC');
}
{
  my $called=0;
  no warnings 'redefine';
  local *Bot::Runtime::Workbench::broker_call=sub {$called++};
  is(Bot::Runtime::Workbench::finish_task($bot,{},'deadline'),'','ordinary chat has no coding status');
  is($called,0,'ordinary chat never contacts broker for status');
}
done_testing;
