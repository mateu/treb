package Bot::Runtime::RaiderPlugin::TerminalSilence;

use strict;
use warnings;

use Moose;
use Future::AsyncAwait;

extends 'Langertha::Plugin';

has terminal_silence_requested => (
  is      => 'rw',
  isa     => 'Bool',
  default => 0,
);

async sub plugin_before_raid {
  my ($self, $messages) = @_;
  $self->terminal_silence_requested(0);
  return $messages;
}

async sub plugin_before_tool_call {
  my ($self, $name, $input) = @_;
  if (defined $name && $name eq 'stay_silent') {
    $self->terminal_silence_requested(1);
    # A text MCP result alone starts another model turn. Raider's supported
    # cancellation API ends this raid at its next safe point instead.
    $self->host->cancel;
  }
  return ($name, $input);
}

__PACKAGE__->meta->make_immutable;

1;
