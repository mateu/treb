package MCP::Server;

use strict;
use warnings;

sub new {
  my ($class, %args) = @_;
  return bless {
    name    => $args{name},
    version => $args{version},
    tools   => [],
  }, $class;
}

sub tool {
  my ($self, %args) = @_;
  push @{ $self->{tools} }, \%args;
  return;
}

1;
