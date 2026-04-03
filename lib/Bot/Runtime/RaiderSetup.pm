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

  my $mcp_server = $self->_build_mcp_server;
  my $loop_class = 'IO::Async::Loop::POE';
  use_module($loop_class);
  my $loop = $loop_class->new;

  my $mcp_class = 'Net::Async::MCP';
  use_module($mcp_class);
  my $mcp = $mcp_class->new(server => $mcp_server);
  $loop->add($mcp);
  my $initialize = $mcp->initialize;
  if (defined $initialize && ref($initialize) && $initialize->can('get')) {
    $initialize->get;
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
  my $raider = $raider_class->new(
    engine             => $engine,
    max_context_tokens => $max_context_tokens,
    mission            => $mission,
  );

  $self->_raider($raider);
  $self->info("Raider ready: $engine_class / " . ($engine->model));
  return $raider;
}

1;
