use strict;
use warnings;
use Test::More;

use lib 'lib';
use Bot::Runtime::ConnectionEvents ();

{
  package Local::ConnectionBot;

  sub new { bless { warnings => [] }, shift }

  sub warning {
    my ($self, $msg) = @_;
    push @{$self->{warnings}}, $msg;
    return;
  }
}

my $bot = Local::ConnectionBot->new;

ok(
  Bot::Runtime::ConnectionEvents::handle_irc_error(
    self    => $bot,
    message => 'Trying to reconnect too fast.',
  ),
  'handles server ERROR',
);
ok(
  Bot::Runtime::ConnectionEvents::handle_irc_disconnected(self => $bot, server => 'irc.perl.org'),
  'handles disconnect',
);
ok(
  Bot::Runtime::ConnectionEvents::handle_irc_socketerr(self => $bot, error => 'Connection refused'),
  'handles socket error',
);
Bot::Runtime::ConnectionEvents::handle_irc_disconnected(self => $bot);

is_deeply(
  $bot->{warnings},
  [
    'server ERROR: Trying to reconnect too fast.',
    'disconnected from irc.perl.org',
    'socket error: Connection refused',
    'disconnected from server',
  ],
  'logs connection failures at warning level',
);

done_testing;
