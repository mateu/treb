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
is(scalar keys %defs,2,'two narrow tools');
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
{
  local $ENV{IRC_SERVER}='elsewhere';
  eval {Bot::Runtime::Workbench::request_scope($bot,0)};
  like($@,qr/network/,'network cannot be overridden');
}
$bot->{bot}='astrid';
is_deeply(Bot::Runtime::Workbench::tool_specs($bot),[],'other bots unchanged');
$bot->{bot}='burt';
local $ENV{BURT_WORKBENCH_SOCKET}='';
is_deeply(Bot::Runtime::Workbench::tool_specs($bot),[],'feature disabled by default');
done_testing;
