use strict;
use warnings;
use Test::More;

use lib 'lib';
use Bot::Runtime::Buffering qw(process_buffer_event);

{
  package Local::BufferFuture;

  sub new { bless {}, shift }
  sub get { return 1 }
}

{
  package Local::BufferBot;

  sub new {
    my ($class, %args) = @_;
    return bless {
      _buffer_timers  => {},
      _msg_buffer     => {},
      _processing     => 0,
      _pending_raid   => undef,
      logs            => [],
      errors          => [],
      raid_calls      => 0,
      setup_calls     => 0,
      scheduled_calls => 0,
      raider          => exists $args{raider} ? $args{raider} : { ready => 1 },
      setup_fail      => $args{setup_fail},
      setup_success   => exists $args{setup_success} ? $args{setup_success} : 1,
    }, $class;
  }

  sub _buffer_timers { return $_[0]->{_buffer_timers} }
  sub _msg_buffer { return $_[0]->{_msg_buffer} }

  sub _processing {
    my ($self, $value) = @_;
    $self->{_processing} = $value if @_ > 1;
    return $self->{_processing};
  }

  sub _pending_raid {
    my ($self, $value) = @_;
    $self->{_pending_raid} = $value if @_ > 1;
    return $self->{_pending_raid};
  }

  sub _raider {
    my ($self, $value) = @_;
    $self->{raider} = $value if @_ > 1;
    return $self->{raider};
  }

  sub _setup_raider {
    my ($self) = @_;
    $self->{setup_calls}++;
    die $self->{setup_fail} if defined $self->{setup_fail};
    if ($self->{setup_success}) {
      $self->{raider} ||= { ready => 1 };
    }
    return Local::BufferFuture->new;
  }

  sub _split_priority_messages {
    my ($self, $messages) = @_;
    return Bot::Runtime::Buffering::split_priority_messages(messages => $messages);
  }

  sub _do_raid {
    my ($self) = @_;
    $self->{raid_calls}++;
    return 1;
  }

  sub _schedule_pending_buffers {
    my ($self) = @_;
    $self->{scheduled_calls}++;
    return 1;
  }

  sub info {
    my ($self, $line) = @_;
    push @{$self->{logs}}, $line;
    return 1;
  }

  sub error {
    my ($self, $line) = @_;
    push @{$self->{errors}}, $line;
    return 1;
  }
}

my $bot = Local::BufferBot->new;

{
  no warnings 'redefine';
  local *Bot::Runtime::Context::build_context_and_input = sub {
    my (%args) = @_;
    my $count = scalar @{$args{messages} || []};
    return { input => "ctx:$args{channel}:$count" };
  };

  $bot->_buffer_timers->{'#ai'} = 'alarm-id';
  $bot->_msg_buffer->{'#ai'} = [
    { source_kind => 'conversation', nick => 'alice', msg => 'hi' },
    { source_kind => 'system', nick => 'system', msg => 'debug' },
  ];

  process_buffer_event(self => $bot, channel => '#ai');
}

ok(!exists $bot->_buffer_timers->{'#ai'}, 'timer removed for processed channel');
is(scalar @{$bot->_msg_buffer->{'#ai'} || []}, 1, 'deferred non-conversation message re-buffered');
is($bot->_processing, 1, 'processing flag set before raid dispatch');
is($bot->{raid_calls}, 1, 'raid execution triggered');

my $pending = $bot->_pending_raid;
ok($pending, 'pending raid payload stored');
is($pending->{channel}, '#ai', 'pending raid includes channel');
is(scalar @{$pending->{messages}}, 1, 'pending raid keeps only active conversation lane');
like($pending->{input}, qr/^ctx:#ai:1$/, 'pending raid input comes from context builder');

ok(
  scalar grep { $_ eq 'Deferring lower-priority buffered messages while human conversation lane is active' } @{$bot->{logs} || []},
  'deferral log emitted',
);
ok(
  scalar grep { /^Processing buffer for #ai:/ } @{$bot->{logs} || []},
  'processing log emitted',
);

my $setup_ok = Local::BufferBot->new(raider => undef);
{
  no warnings 'redefine';
  local *Bot::Runtime::Context::build_context_and_input = sub {
    my (%args) = @_;
    my $count = scalar @{$args{messages} || []};
    return { input => "ctx:$args{channel}:$count" };
  };

  $setup_ok->_msg_buffer->{'#setup'} = [
    { source_kind => 'conversation', nick => 'alice', msg => 'hello' },
  ];

  process_buffer_event(self => $setup_ok, channel => '#setup');
}

is($setup_ok->{setup_calls}, 1, 'missing raider attempts setup before raid dispatch');
is($setup_ok->{raid_calls}, 1, 'setup success continues to raid dispatch');
ok($setup_ok->_raider, 'setup success stores raider instance');
like(join("\n", @{$setup_ok->{logs}}), qr/Raider unavailable while processing buffer; attempting setup/, 'setup attempt logged');

my $setup_fail = Local::BufferBot->new(raider => undef, setup_fail => 'boom');
$setup_fail->_msg_buffer->{'#defer'} = [
  { source_kind => 'conversation', nick => 'alice', msg => 'hello' },
];
process_buffer_event(self => $setup_fail, channel => '#defer');

is($setup_fail->{setup_calls}, 1, 'setup failure path still attempts setup once');
is($setup_fail->{raid_calls}, 0, 'setup failure defers instead of calling raid');
is(scalar @{$setup_fail->_msg_buffer->{'#defer'} || []}, 1, 'active message is re-buffered when raider unavailable');
is($setup_fail->{scheduled_calls}, 1, 'setup failure schedules pending buffers for retry');
is($setup_fail->_pending_raid, undef, 'setup failure does not set pending raid payload');
is($setup_fail->_processing, 0, 'setup failure does not flip processing flag');
like(join("\n", @{$setup_fail->{logs}}), qr/Raider unavailable; deferring buffered messages/, 'deferral log emitted for missing raider');
like(join("\n", @{$setup_fail->{errors}}), qr/Raider setup retry failed in buffering: boom/, 'setup retry error logged');

my $busy = Local::BufferBot->new;
$busy->_buffer_timers->{'#busy'} = 'alarm-busy';
$busy->_msg_buffer->{'#busy'} = [ { source_kind => 'conversation', msg => 'still queued' } ];
$busy->_processing(1);
process_buffer_event(self => $busy, channel => '#busy');

ok(!exists $busy->_buffer_timers->{'#busy'}, 'busy path still clears timer');
is(scalar @{$busy->_msg_buffer->{'#busy'} || []}, 1, 'busy path leaves buffered messages untouched');
is($busy->{raid_calls}, 0, 'busy path skips raid');

my $empty = Local::BufferBot->new;
$empty->_buffer_timers->{'#empty'} = 'alarm-empty';
process_buffer_event(self => $empty, channel => '#empty');

ok(!exists $empty->_buffer_timers->{'#empty'}, 'empty path clears timer');
is($empty->{raid_calls}, 0, 'empty path performs no raid');

my $err;
eval { process_buffer_event(channel => '#missing-self') };
$err = $@;
like($err, qr/requires self/, 'process_buffer_event validates self argument');

eval { process_buffer_event(self => $bot) };
$err = $@;
like($err, qr/requires channel/, 'process_buffer_event validates channel argument');

done_testing;
