use strict;
use warnings;
use Test::More;
use lib 'lib';
BEGIN {
  eval { require Moose; require Future::AsyncAwait; require Langertha::Plugin; 1 }
    or plan skip_all=>'Raider plugin dependencies unavailable';
}
use Bot::Runtime::RaiderPlugin::CodingTask;
my $host=bless {},'CodingHost';
my $pending={coding_task=>1,expires_at=>time+100,coding_attempts_remaining=>2,
  coding_last_repo_job=>'a'x32,coding_last_repo_state=>'failed'};
my $plugin=Bot::Runtime::RaiderPlugin::CodingTask->new(host=>$host,pending=>sub {$pending});
my $original={role=>'user',content=>'request'};
my $messages=$plugin->plugin_before_llm_call([$original],1)->get;
is(scalar @$messages,2,'one runtime reminder appended');
like($messages->[-1]{content},qr/Runtime coding budget: 13 sandbox runs total/,'production reminder advertises the thirteen-attempt budget');
like($messages->[-1]{content},qr/Remaining sandbox runs: 2/,'budget survives context loss');
{
  local $ENV{BURT_SANDBOX_ATTEMPTS}=5;
  my $trial_messages=$plugin->plugin_before_llm_call([$original],1)->get;
  like($trial_messages->[-1]{content},qr/Runtime coding budget: 5 sandbox runs total/,
    'frozen trial reminder advertises the five-attempt budget');
}
$plugin->reminder($messages->[-1]); # restore the production turn's replacement identity
like($messages->[-1]{content},qr/Latest repository job: a{32}/,'latest job remains inspectable');
$pending->{coding_attempts_remaining}=1;
$messages=$plugin->plugin_before_llm_call($messages,2)->get;
is(scalar @$messages,2,'reminder replaced, never accumulated');
is($messages->[0],$original,'tool/history message identities preserved for compaction');
like($messages->[-1]{content},qr/Remaining sandbox runs: 1/,'updated budget');
$pending->{coding_stop_reason}='sandbox attempt budget exhausted';
eval {$plugin->plugin_before_llm_call($messages,3)->get};
like($@,qr/sandbox attempt budget exhausted/,'terminal quota stops before another model call');
delete $pending->{coding_stop_reason};
$pending->{coding_attempts_remaining}=0;
eval {$plugin->plugin_before_llm_call($messages,4)->get};
like($@,qr/before a complete project passed/,'last diagnostic cannot consume final run and masquerade as project success');
delete $pending->{coding_stop_reason};
$pending->{coding_attempts_remaining}=1;
$pending->{expires_at}=time-1;
eval {$plugin->plugin_before_llm_call($messages,4)->get};
like($@,qr/coding deadline reached/,'fixed deadline stops before another model call');
$pending=undef;
$messages=$plugin->plugin_before_llm_call($messages,1)->get;
is_deeply($messages,[$original],'ordinary next turn has no stale coding instructions');
done_testing;
