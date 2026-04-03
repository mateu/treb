use strict;
use warnings;
use Test::More;

use lib 'lib';
use Bot::Runtime::PresenceEvents ();

{
  package POE::Kernel;

  our @DELAY_CALLS;

  sub delay {
    my ($class, $event, $seconds, @args) = @_;
    if (!defined $seconds) {
      ($event, $seconds, @args) = ($class, $event, @args);
    }
    push @DELAY_CALLS, [$event, $seconds, @args];
    return 1;
  }
}

{
  package Local::PresenceMemory;

  sub new { bless { recall_calls => [] }, shift }

  sub recall_notes {
    my ($self, @args) = @_;
    push @{$self->{recall_calls}}, [@args];
    return "note one\nnote two";
  }
}

{
  package Local::PresenceBot;

  sub new {
    my ($class) = @_;
    return bless {
      nickname       => 'treb',
      default_channel => '#bots',
      netsplit_quits => [],
      activity_ticks => 0,
      infos          => [],
      buffered       => [],
      persona_calls  => [],
      memory         => Local::PresenceMemory->new,
    }, $class;
  }

  sub get_nickname { $_[0]->{nickname} }
  sub _default_channel { $_[0]->{default_channel} }

  sub _netsplit_quits {
    my ($self, $value) = @_;
    $self->{netsplit_quits} = $value if @_ > 1;
    return $self->{netsplit_quits};
  }

  sub _last_activity {
    my ($self, $ts) = @_;
    $self->{activity_ticks}++ if defined $ts;
    return $self->{activity_ticks};
  }

  sub info {
    my ($self, $line) = @_;
    push @{$self->{infos}}, $line;
    return 1;
  }

  sub _buffer_message {
    my ($self, $channel, $speaker, $line) = @_;
    push @{$self->{buffered}}, [$channel, $speaker, $line];
    return 1;
  }

  sub _persona_trait {
    my ($self, $trait) = @_;
    push @{$self->{persona_calls}}, $trait;
    return 75 if $trait eq 'join_greet_pct';
    return 0;
  }

  sub memory { $_[0]->{memory} }
}

subtest 'join handler ignores self and buffers join message for others' => sub {
  my $bot = Local::PresenceBot->new;

  ok(
    !Bot::Runtime::PresenceEvents::handle_irc_join(
      self    => $bot,
      nickstr => 'treb!self@host',
      channel => '#bots',
    ),
    'self join is ignored',
  );

  ok(
    Bot::Runtime::PresenceEvents::handle_irc_join(
      self    => $bot,
      nickstr => 'alice!u@example.net',
      channel => '#bots',
    ),
    'non-self join is handled',
  );

  is_deeply($bot->{persona_calls}, ['join_greet_pct'], 'join handler asks for join_greet_pct trait');
  like($bot->{buffered}[0][2], qr/alice \(u\@example\.net\) has joined the channel/, 'join message buffered');
};

subtest 'part/quit handlers keep behavior and netsplit queueing' => sub {
  my $bot = Local::PresenceBot->new;
  local @POE::Kernel::DELAY_CALLS = ();

  ok(
    Bot::Runtime::PresenceEvents::handle_irc_part(
      self    => $bot,
      nickstr => 'alice!u@example.net',
      channel => '#bots',
      reason  => 'Ping timeout',
    ),
    'part event handled',
  );
  like($bot->{buffered}[0][2], qr/has left the channel: Ping timeout/, 'part reason is included');

  ok(
    Bot::Runtime::PresenceEvents::handle_irc_quit(
      self    => $bot,
      nickstr => 'bob!u@example.net',
      reason  => 'irc1.example.net irc2.example.net',
    ),
    'netsplit quit handled',
  );
  is_deeply($bot->{netsplit_quits}, ['bob'], 'netsplit nick queued for delayed report');
  is_deeply(
    \@POE::Kernel::DELAY_CALLS,
    [['_netsplit_report', 3, '#bots', 'irc1.example.net irc2.example.net']],
    'netsplit report delay scheduled',
  );

  ok(
    Bot::Runtime::PresenceEvents::handle_netsplit_report(
      self         => $bot,
      channel      => '#bots',
      split_reason => 'irc1.example.net irc2.example.net',
    ),
    'netsplit report emitted when queue has nicks',
  );
  is_deeply($bot->{netsplit_quits}, [], 'netsplit queue drained after report');
  like($bot->{buffered}[1][2], qr/NETSPLIT detected/, 'netsplit summary buffered');

  ok(
    Bot::Runtime::PresenceEvents::handle_irc_quit(
      self    => $bot,
      nickstr => 'carol!u@example.net',
      reason  => 'Client exited',
    ),
    'regular quit handled',
  );
  like($bot->{buffered}[2][2], qr/has quit IRC: Client exited/, 'regular quit message buffered');
};

subtest 'pm and whois handlers buffer runtime presence messages' => sub {
  my $bot = Local::PresenceBot->new;

  ok(
    Bot::Runtime::PresenceEvents::handle_irc_msg(
      self    => $bot,
      nickstr => 'dave!u@example.net',
      msg     => 'hello there',
    ),
    'private message handled',
  );
  like($bot->{buffered}[0][2], qr/^PRIVATE MESSAGE from dave/, 'pm system message buffered');

  ok(
    Bot::Runtime::PresenceEvents::handle_irc_whois(
      self => $bot,
      info => {
        nick     => 'dave',
        user     => 'dave',
        host     => 'example.net',
        channels => ['#bots'],
      },
    ),
    'whois handled',
  );
  is_deeply(
    $bot->{memory}{recall_calls},
    [['dave', '', 100]],
    'whois flow recalls notes with fixed note query shape',
  );
  like($bot->{buffered}[1][2], qr/^WHOIS dave:/, 'whois text buffered');
  like($bot->{infos}[1], qr/^WHOIS dave:/, 'whois text logged');
};

done_testing;
