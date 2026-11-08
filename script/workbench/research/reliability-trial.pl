#!/usr/bin/env perl
# Operator-only. No IRC client, bot DB use, GitHub access, or hidden tests.
use strict;
use warnings;
use JSON::PP;
use Time::HiRes qw(time);
use MCP::Server;
use Bot::Runtime::Workbench;
use Bot::Runtime::RaiderSetup;
use ExperimentPlugin;
use URI;
use Digest::SHA qw(sha256_hex);
binmode STDOUT,':encoding(UTF-8)';
binmode STDERR,':encoding(UTF-8)';
$|=1;
{
  package ReliabilityBot;
  sub _bot_name_slug {'burt'}
  sub get_nickname {'burt_bot'}
  sub get_channels {'#ai'}
  sub _is_human_nick {$_[1] eq 'operator'}
  sub _pending_raid {$_[0]{pending}}
  sub _mcp {$_[0]{mcp}=$_[1] if @_>1;$_[0]{mcp}}
  sub _raider {$_[0]{raider}=$_[1] if @_>1;$_[0]{raider}}
  sub info {print STDERR "$_[1]\n"}
  sub _send_to_channel {print STDERR "OFFLINE_NOTICE: $_[2]\n"}
  sub _build_mcp_server {
    my ($self)=@_;
    my $server=MCP::Server->new(name=>'burt-reliability-no-publish',version=>'1');
    $server->tool(%$_) for grep {$_->{name} !~ /publish/} @{Bot::Runtime::Workbench::tool_specs($self)};
    return $server;
  }
}
open my $fh,'<:raw','/trial.json' or die $!;
my $config=decode_json(do {local $/;<$fh>});close $fh;
$ENV{MODEL}=$config->{model};
$ENV{FALLBACK_MODELS}='';
$ENV{BOT_CODING_TASK_TTL_SECONDS}=$config->{deadline_seconds};
$ENV{EXPERIMENT_DEADLINE}=$config->{deadline};
$ENV{BURT_SANDBOX_ATTEMPTS}=$config->{max_executions};
my $task=$config->{task};
my $request='burt_bot: '.$task->{prompt}."\nRead workspace repository branch $task->{branch}, project $task->{project}. Preserve existing project files and tests. Test the complete project. Do not publish anything.";
my $bot=bless {pending=>{channel=>'#ai',expires_at=>time+300,messages=>[
  {source_kind=>'conversation',nick=>'operator',msg=>$request}]}},'ReliabilityBot';
Bot::Runtime::Workbench::admit_task($bot);
# The host-owned fixed deadline starts before setup; never renew on admission.
$bot->{pending}{expires_at}=$config->{deadline};
my ($raider,$plugin,$result,$error);
my $compactions=0;
eval {
  $raider=Bot::Runtime::RaiderSetup::setup_raider(self=>$bot,owner=>'operator',max_line=>400,script_file=>'/app/burt.pl',max_context_tokens=>$config->{context_tokens},max_iterations=>$config->{max_iterations});
  die "effective iteration limit differs from frozen config\n" unless $raider->max_iterations==$config->{max_iterations};
  my $engine=$raider->engine;
  my $url=$engine->can('url') ? URI->new($engine->url) : undef;
  if ($url) {
    $url->userinfo(undef) if $url->can('userinfo');
    $url->query(undef);$url->fragment(undef);
  }
  my %dependency_hashes;
  for my $module (sort grep {m{^Langertha/}} keys %INC) {
    open my $dep,'<:raw',$INC{$module} or die $!;
    $dependency_hashes{$module}=sha256_hex(do {local $/;<$dep>});close $dep;
  }
  # Moose optional accessors can return an empty list. Force scalar context for
  # every method value so absent options stay JSON null, never shift hash pairs.
  $bot->{experiment_effective}={engine_class=>ref($engine),model=>scalar($engine->model),
    provider_url=>($url ? "$url" : undef),fallback_models=>[],
    max_iterations=>scalar($raider->max_iterations),context_tokens=>scalar($raider->max_context_tokens),
    context_compress_threshold=>scalar($raider->context_compress_threshold),
    provider_context_tokens=>($engine->can('has_context_size') && $engine->has_context_size ? scalar($engine->get_context_size) : undef),
    model_output_tokens=>($engine->can('get_response_size') ? scalar($engine->get_response_size) : undef),
    temperature=>($engine->can('has_temperature') && $engine->has_temperature ? scalar($engine->temperature) : undef),
    dependency_hashes=>\%dependency_hashes};
  open my $route,'>:raw','/state/effective-route.json' or die $!;
  print {$route} JSON::PP->new->canonical->utf8->encode($bot->{experiment_effective});close $route;
  if ($config->{expected_effective_route}) {
    my %common=%{$bot->{experiment_effective}};delete $common{context_tokens};
    my $json=JSON::PP->new->canonical;
    die "effective provider route or common budgets differ from frozen first trial\n"
      unless $json->encode(\%common) eq $json->encode($config->{expected_effective_route});
  }
  exit 0 if $config->{setup_only};
  $plugin=ExperimentPlugin->new(host=>$raider,state_dir=>'/state',notebook_enabled=>$config->{notebook},workflow_prompt=>$config->{workflow_prompt}//'');
  push @{$raider->plugin_instances},$plugin;
  # Observe unchanged library compaction; do not replace its algorithm.
  my $original=Langertha::Raider->can('_compact_conversation');
  {
    no warnings 'redefine';
    local *Langertha::Raider::_compact_conversation=sub {
      my ($self,$state)=@_;
      my $before=scalar @{$state->{conversation}};
      my $shed=$original->(@_);
      if ($shed) {
        $compactions++;
        $plugin->record('context_compaction',{estimated_tokens_shed=>$shed,messages_dropped=>$before-scalar(@{$state->{conversation}})});
      }
      return $shed;
    };
    $result=$raider->raid("Current #ai operator request: $request\nUse the coding tools. Return test results and any concrete unresolved blockers truthfully. No IRC messages or publication are possible in this offline experiment.");
  }
  1;
} or $error="$@";
my $metadata={pending=>$bot->{pending},error=>$error,result=>($result ? scalar($result->as_hash) : undef),
  terminal_response=>(defined($result) ? "$result" : ''),effective=>$bot->{experiment_effective},
  metrics=>($raider ? scalar($raider->metrics) : undef),model_calls=>($plugin ? scalar($plugin->calls) : 0),
  compactions=>$compactions,effective_context_tokens=>($raider ? scalar($raider->max_context_tokens) : undef),
  engine_model=>($raider ? scalar($raider->engine->model) : undef),
  engine_class=>($raider ? ref($raider->engine) : undef),langertha_version=>$Langertha::Raider::VERSION};
open my $out,'>:raw','/state/final.json' or die $!;
print {$out} JSON::PP->new->canonical->utf8->encode($metadata);close $out;
print defined($result) ? "$result\n" : '';
print STDERR $error if $error;
exit($error ? 1 : 0);
