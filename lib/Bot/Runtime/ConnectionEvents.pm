package Bot::Runtime::ConnectionEvents;

use strict;
use warnings;

# Adam only logs these at debug level via DEFAULT, which hides server
# refusals such as hybrid's "Trying to reconnect too fast." throttle.

sub handle_irc_error {
  my (%args) = @_;
  my $self = $args{self} or die 'handle_irc_error requires self';
  my $message = defined $args{message} ? $args{message} : '';

  $self->warning("server ERROR: $message");
  return 1;
}

sub handle_irc_disconnected {
  my (%args) = @_;
  my $self = $args{self} or die 'handle_irc_disconnected requires self';
  my $server = defined $args{server} ? $args{server} : 'server';

  $self->warning("disconnected from $server");
  return 1;
}

sub handle_irc_socketerr {
  my (%args) = @_;
  my $self = $args{self} or die 'handle_irc_socketerr requires self';
  my $error = defined $args{error} ? $args{error} : 'unknown error';

  $self->warning("socket error: $error");
  return 1;
}

1;
