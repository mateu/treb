package Bot::Runtime::RaiderPlugin::ToolTrace;

use strict;
use warnings;

use Moose;
use Future::AsyncAwait;

extends 'Langertha::Plugin';

has logger => (
  is       => 'ro',
  isa      => 'CodeRef',
  required => 1,
);

sub _arg_meta {
  my ($input) = @_;
  return 'args=none' unless defined $input;
  return 'args=nonhash' unless ref($input) eq 'HASH';
  my @keys = sort keys %{$input};
  my @types = map {
    my $value = $input->{$_};
    my $kind = !defined $value ? 'undef' : ref($value) || 'scalar';
    "$_:$kind";
  } @keys;
  return 'args={' . join(',', @types) . '}';
}

sub _result_meta {
  my ($result) = @_;
  return 'status=succeeded result=scalar' unless ref($result) eq 'HASH';
  my $status = $result->{cancelled} ? 'cancelled' : $result->{isError} ? 'failed' : 'succeeded';
  my $chars = 0;
  if (ref($result->{content}) eq 'ARRAY') {
    $chars += length($_->{text} // '') for grep { ref($_) eq 'HASH' } @{$result->{content}};
  }
  return "status=$status result_chars=$chars";
}

async sub plugin_after_llm_response {
  my ($self, $data, $iteration) = @_;
  my $engine = $self->host->active_engine;
  my $calls = eval { $engine->response_tool_calls($data) } || [];
  for my $call (@{$calls}) {
    my ($name, $input) = eval { $engine->extract_tool_call($call) };
    $name = '?' unless defined $name && length $name;
    $self->logger->("Raider trace iteration=$iteration event=model_tool_call name=$name " . _arg_meta($input));
  }
  return $data;
}

async sub plugin_before_tool_call {
  my ($self, $name, $input) = @_;
  $name = '?' unless defined $name && length $name;
  $self->logger->("Raider trace event=tool_dispatch name=$name " . _arg_meta($input));
  return ($name, $input);
}

async sub plugin_after_tool_call {
  my ($self, $name, $input, $result) = @_;
  $name = '?' unless defined $name && length $name;
  $self->logger->("Raider trace event=tool_result name=$name " . _result_meta($result));
  return $result;
}

__PACKAGE__->meta->make_immutable;

1;
