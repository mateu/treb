package Bot::Runtime::RaiderSetup;

use strict;
use warnings;

use Exporter 'import';
use Module::Runtime qw(use_module);

our @EXPORT_OK = qw(setup_raider);

sub setup_raider {
  my (%args) = @_;
  my $self = $args{self} or die 'setup_raider requires self';
  my $owner = $args{owner} // 'unknown';
  my $max_line = $args{max_line};
  die 'setup_raider requires max_line' unless defined $max_line;
  my $script_file = $args{script_file} or die 'setup_raider requires script_file';
  my $max_context_tokens = defined $args{max_context_tokens} ? $args{max_context_tokens} : 8192;
  # Operator opt-in for the Burt rollout. Other bots and explicit caller budgets
  # retain their existing settings. This is a compactor budget, not an API cap.
  if (!defined $args{max_context_tokens} && $self->can('_bot_name_slug')
      && $self->_bot_name_slug eq 'burt' && exists $ENV{BURT_CONTEXT_TOKENS}) {
    my $budget = $ENV{BURT_CONTEXT_TOKENS};
    die 'BURT_CONTEXT_TOKENS must be an integer from 8192 to 65536'
      unless $budget =~ /\A[0-9]+\z/ && $budget >= 8192 && $budget <= 65536;
    $max_context_tokens = 0 + $budget;
  }

  my $max_iterations = 13;
  $max_iterations = 26 if $self->can('_bot_name_slug') && $self->_bot_name_slug eq 'burt';

  my $mcp_server = $self->_build_mcp_server;
  my $loop_class = 'IO::Async::Loop::POE';
  use_module($loop_class);
  my $loop = $loop_class->new;

  my $mcp_class = 'Net::Async::MCP';
  use_module($mcp_class);
  my $mcp = $mcp_class->new(server => $mcp_server);
  $loop->add($mcp);
  my $initialize = $mcp->initialize;
  if (defined $initialize && ref($initialize)) {
    $loop->await($initialize);
  }
  $self->_mcp($mcp);

  my $engine_class = 'Langertha::Engine::' . ($ENV{ENGINE} || 'Groq');
  use_module($engine_class);

  my %engine_args = ( mcp_servers => [$mcp] );
  $engine_args{model} = $ENV{MODEL} || 'llama-3.3-70b-versatile';
  $engine_args{api_key} = $ENV{API_KEY} if $ENV{API_KEY};
  if (($ENV{ENGINE} || 'Groq') eq 'Ollama' && $ENV{OLLAMA_URL}) {
    $engine_args{url} = $ENV{OLLAMA_URL};
  }

  my $engine = $engine_class->new(%engine_args);

  my $nick = $self->get_nickname;
  my $model = $engine->model;
  my $provider = ref($engine) =~ s/.*:://r;
  my $chan_list = join(', ', $self->get_channels);
  use_module('Bot::Mission');
  my $mission = Bot::Mission::load_mission_for_script(
    script_file   => $script_file,
    nick          => $nick,
    owner         => $owner,
    model         => $model,
    provider      => $provider,
    channels      => $chan_list,
    max_line      => $max_line,
    mission_extra => $ENV{SYSTEM_PROMPT},
  );

  my $raider_class = 'Langertha::Raider';
  use_module($raider_class);
  my @plugins = ('+Bot::Runtime::RaiderPlugin::TerminalSilence',
    '+Bot::Runtime::RaiderPlugin::CodingTask', { pending => sub { $self->_pending_raid } });
  if ($ENV{RAIDER_TOOL_TRACE}) {
    push @plugins, '+Bot::Runtime::RaiderPlugin::ToolTrace', {
      logger => sub { $self->info($_[0]) },
    };
  }

  my $raider = $raider_class->new(
    engine             => $engine,
    max_context_tokens => $max_context_tokens,
    mission            => $mission,
    max_iterations     => $max_iterations,
    plugins            => \@plugins,
  );

  my $n = 0;
  for my $fallback_model (grep { length } map { s/^\s+|\s+$//gr } split /,/, $ENV{FALLBACK_MODELS} // '') {
    next if $fallback_model eq $engine_args{model};
    my $fallback_engine = $engine_class->new(%engine_args, model => $fallback_model);
    $raider->add_engine('fallback' . ++$n, engine => $fallback_engine, description => $fallback_model);
  }

  $self->_raider($raider);
  $self->info("Raider ready: $engine_class / " . ($engine->model));
  $self->info("Raider compactor budget: $max_context_tokens tokens; max iterations: $max_iterations");
  return $raider;
}

1;
