package Bot::Runtime::Buffering;

use strict;
use warnings;

use Exporter 'import';
use Bot::Runtime::Context ();
use Bot::Runtime::Reminders ();
use Bot::Runtime::Limits qw(runtime_limit now);
our @EXPORT_OK = qw(
  buffer_message
  split_priority_messages
  process_buffer_event
  schedule_pending_buffers
);

# Expire old context before admitting or dispatching messages. Journal evidence
# lives separately; dropping work here never deletes the conversation journal.
sub _prune_buffers {
  my ($self) = @_;
  my $cutoff = now() - runtime_limit('REPLY_TTL_SECONDS', 300);
  for my $ch (keys %{$self->_msg_buffer}) {
    my $queue = $self->_msg_buffer->{$ch};
    my $before = @$queue;
    @$queue = grep { ($_->{queued_at} // now()) > $cutoff } @$queue;
    $self->info("Expired buffered messages for $ch: " . ($before - @$queue)) if $before > @$queue;
    next if @$queue;
    delete $self->_msg_buffer->{$ch};
    if (my $id = delete $self->_buffer_timers->{$ch}) {
      POE::Kernel->alarm_remove($id);
    }
  }
}

sub buffer_message {
  my (%args) = @_;
  my $self    = $args{self}    or die 'buffer_message requires self';
  my $channel = $args{channel} or die 'buffer_message requires channel';
  my $nick    = $args{nick};
  my $msg     = $args{msg};
  my $extra   = $args{extra} || {};
  my $delay   = $args{delay};
  die 'buffer_message requires delay' unless defined $delay;

  _prune_buffers($self);
  my $total = 0;
  $total += @$_ for values %{$self->_msg_buffer};
  if ($total >= runtime_limit('QUEUE_MAX_TOTAL', 500)
      || @{$self->_msg_buffer->{$channel} || []} >= runtime_limit('QUEUE_MAX_CHANNEL', 100)
      || length($msg // '') > runtime_limit('QUEUE_MAX_MESSAGE_CHARS', 16384)) {
    $self->info("Buffer capacity exceeded for $channel; ignoring new work (journal retained)");
    return;
  }
  push @{$self->_msg_buffer->{$channel} ||= []}, {
    %{$extra},
    channel => $channel,
    nick    => $nick,
    msg     => $msg,
    queued_at => now(),
  };

  if (my $id = delete $self->_buffer_timers->{$channel}) {
    POE::Kernel->alarm_remove($id);
  }

  my $id = POE::Kernel->alarm_set(_process_buffer => ($self->_msg_buffer->{$channel}[0]{queued_at} + $delay), $channel);
  $self->_buffer_timers->{$channel} = $id;
}

sub split_priority_messages {
  my (%args) = @_;
  my $messages = $args{messages} || [];

  my @messages = @{$messages};
  my @conversation = grep { (($_->{source_kind} // '') eq 'conversation') } @messages;
  return (\@messages, []) unless @conversation;

  my @deferred = grep { (($_->{source_kind} // '') ne 'conversation') } @messages;
  return (\@conversation, \@deferred);
}

sub process_buffer_event {
  my (%args) = @_;
  my $self    = $args{self} or die 'process_buffer_event requires self';
  my $channel = $args{channel} or die 'process_buffer_event requires channel';

  delete $self->_buffer_timers->{$channel};

  _prune_buffers($self);
  return if $self->_processing;
  my @incoming_messages = @{$self->_msg_buffer->{$channel} || []};
  return unless @incoming_messages;

  $self->_msg_buffer->{$channel} = [];
  my ($active_messages, $deferred_messages) = $self->_split_priority_messages(\@incoming_messages);
  my @messages = @{$active_messages || []};
  my @deferred = @{$deferred_messages || []};
  if (@deferred) {
    $self->info('Deferring lower-priority buffered messages while human conversation lane is active');
    push @{$self->_msg_buffer->{$channel} ||= []}, @deferred;
  }
  return unless @messages;

  my $raider = $self->can('_raider') ? $self->_raider : undef;
  if (!$raider && $self->can('_setup_raider')) {
    $self->info('Raider unavailable while processing buffer; attempting setup');
    my $setup_ok = eval {
      my $setup = $self->_setup_raider;
      $setup->get if defined $setup && ref($setup) && $setup->can('get');
      1;
    };
    if (!$setup_ok && $self->can('error')) {
      my $err = "$@";
      $err =~ s/\s+$//;
      $self->error("Raider setup retry failed in buffering: $err");
    }
    $raider = $self->can('_raider') ? $self->_raider : undef;
  }

  unless ($raider) {
    $self->info('Raider unavailable; deferring buffered messages');
    _prune_buffers($self);
    my $total = 0;
    $total += @$_ for values %{$self->_msg_buffer};
    my $queue = $self->_msg_buffer->{$channel} ||= [];
    my $room = runtime_limit('QUEUE_MAX_CHANNEL', 100) - @$queue;
    my $global_room = runtime_limit('QUEUE_MAX_TOTAL', 500) - $total;
    $room = $global_room if $global_room < $room;
    $room = 0 if $room < 0;
    $self->info("Requeue capacity exceeded for $channel; dropping excess work") if @messages > $room;
    splice @messages, $room if @messages > $room;
    unshift @$queue, @messages;
    $self->_schedule_pending_buffers if $self->can('_schedule_pending_buffers');
    return;
  }

  # A cancelled/expired reminder may still have a volatile queued wake. Filter it
  # before context/model work. A lease recovers queue loss after restart or TTL.
  @messages = grep {
    !defined($_->{reminder_id}) || $self->memory->consume_reminder(
      bot=>Bot::Runtime::Reminders::bot_identity($self),channel=>$channel,id=>$_->{reminder_id})
  } @messages;
  unless (@messages) {
    $self->_schedule_pending_buffers;
    return;
  }

  $self->_processing(1);

  my $ctx = Bot::Runtime::Context::build_context_and_input(
    self     => $self,
    channel  => $channel,
    messages => \@messages,
  );
  my $input = $ctx->{input};

  $self->info("Processing buffer for $channel:\n$input");

  my $oldest = now();
  for my $m (@messages) {
    $oldest = $m->{queued_at} if defined $m->{queued_at} && $m->{queued_at} < $oldest;
  }
  $self->_pending_raid({ input => $input, channel => $channel, messages => \@messages,
    expires_at => $oldest + runtime_limit('REPLY_TTL_SECONDS', 300) });
  $self->_do_raid;
}

sub schedule_pending_buffers {
  my (%args) = @_;
  my $self  = $args{self} or die 'schedule_pending_buffers requires self';
  my $delay = $args{delay};
  die 'schedule_pending_buffers requires delay' unless defined $delay;

  _prune_buffers($self);
  for my $ch (keys %{$self->_msg_buffer}) {
    next unless @{$self->_msg_buffer->{$ch} || []};
    next if $self->_buffer_timers->{$ch};
    my $id = POE::Kernel->alarm_set(_process_buffer => time() + $delay, $ch);
    $self->_buffer_timers->{$ch} = $id;
  }
}

1;
