#!/usr/bin/env perl
# Operator-only acceptance: re-run an explicitly provided untrusted saved
# bundle inside the real offline runner, then let the production model repair
# it. No IRC client, live bot DB writes, or publication tools.
use strict;
use warnings;
use JSON::PP;
use MCP::Server;
use Bot::Runtime::Workbench;
use Bot::Runtime::RaiderSetup;
binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';
select STDERR; $|=1; select STDOUT; $|=1;
{
  package RepairSmoke;
  sub _bot_name_slug {'burt'}
  sub get_nickname {'burt_bot'}
  sub get_channels {'#ai'}
  sub _is_human_nick {$_[1] eq 'operator'}
  sub _pending_raid {$_[0]{pending}}
  sub _mcp {$_[0]{mcp}=$_[1] if @_>1;$_[0]{mcp}}
  sub _raider {$_[0]{raider}=$_[1] if @_>1;$_[0]{raider}}
  sub info {print STDERR "$_[1]\n"}
  sub _send_to_channel {print STDERR "NOTICE: $_[2]\n"}
  sub _build_mcp_server {
    my ($self)=@_;
    my $s=MCP::Server->new(name=>'burt-repair-smoke',version=>'1');
    $s->tool(%$_) for grep {$_->{name} !~ /publish/} @{Bot::Runtime::Workbench::tool_specs($self)};
    return $s;
  }
}
open my $fh,'<:raw','/repair-fixture.json' or die $!;
my $fixture=decode_json(do {local $/;<$fh>});
close $fh;
my $request='burt_bot: test and repair the saved dictionary project. Preserve existing files and tests; fix the actual defects. Do not publish anything.';
my $bot=bless {pending=>{channel=>'#ai',expires_at=>time+300,messages=>[
  {source_kind=>'conversation',nick=>'operator',msg=>$request}]}},'RepairSmoke';
Bot::Runtime::Workbench::admit_task($bot);
my $scope=Bot::Runtime::Workbench::request_scope($bot,0);
my %envelope=(scope=>$scope,channel=>'#ai',network=>'irc.perl.org');
my $snapshot=decode_json(Bot::Runtime::Workbench::broker_call({%envelope,action=>'repo_read',
  branch=>'burt/dictionary',project=>'dictionary'}));
die encode_json($snapshot) unless $snapshot->{base_sha};
my $seed=Bot::Runtime::Workbench::broker_call({%envelope,action=>'repo_run',
  branch=>'burt/dictionary',project=>'dictionary',base_sha=>$snapshot->{base_sha},
  files=>$fixture->{files},argv=>['/usr/bin/perl','-Ilib','t/dictionary.t'],title=>'Replay original failed dictionary bundle'});
my $job=decode_json($seed);
die 'original failure was not reproduced: '.$seed unless ($job->{state}//'') eq 'failed';
Bot::Runtime::Workbench::report_result($bot,'repo_run',$seed);
my $raider=Bot::Runtime::RaiderSetup::setup_raider(self=>$bot,owner=>'operator',max_line=>400,script_file=>'/app/burt.pl');
my $result=$raider->raid("Current #ai operator request: $request\nThe original failure is reproduced in repository job $job->{id}. Inspect that job for ALL saved source and test output, then repair the affected files only using repair_repo_project. Keep existing regression assertions (correct genuinely malformed fixture bytes if needed); do not delete tests, suppress failures, or change the complete-suite argv. No publication tools are available. Stop only after the complete project passes or a concrete blocker.\n");
print "$result\n";
print 'FINAL_METADATA: '.encode_json($bot->_pending_raid)."\n";
die 'acceptance failed: no passed repository repair' unless ($bot->_pending_raid->{coding_last_repo_state}//'') eq 'passed';
my $final=decode_json(Bot::Runtime::Workbench::broker_call({%envelope,action=>'repo_inspect',
  id=>$bot->_pending_raid->{coding_last_repo_job}}));
die 'acceptance changed the complete-project test argv' unless
  encode_json($final->{result}{argv}) eq encode_json(['/usr/bin/perl','-Ilib','t/dictionary.t']);
die 'acceptance dropped original project files' if grep {!exists $final->{files}{$_}} keys %{$fixture->{files}};
