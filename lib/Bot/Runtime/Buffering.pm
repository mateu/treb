package Bot::Runtime::Buffering;

use strict;
use warnings;

use Exporter 'import';
our @EXPORT_OK = qw(
  buffer_message
  split_priority_messages
  schedule_pending_buffers
);

sub buffer_message {
  my (%args) = @_;
  my $self    = $args{self}    or die 'buffer_message requires self';
  my $channel = $args{channel} or die 'buffer_message requires channel';
  my $nick    = $args{nick};
  my $msg     = $args{msg};
  my $extra   = $args{extra} || {};
  my $delay   = $args{delay};
  die 'buffer_message requires delay' unless defined $delay;

  push @{$self->_msg_buffer->{$channel} ||= []}, {
    channel => $channel,
    nick    => $nick,
    msg     => $msg,
    %{$extra},
  };

  if (my $id = delete $self->_buffer_timers->{$channel}) {
    POE::Kernel->alarm_remove($id);
  }

  my $id = POE::Kernel->alarm_set(_process_buffer => time() + $delay, $channel);
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

sub schedule_pending_buffers {
  my (%args) = @_;
  my $self  = $args{self} or die 'schedule_pending_buffers requires self';
  my $delay = $args{delay};
  die 'schedule_pending_buffers requires delay' unless defined $delay;

  for my $ch (keys %{$self->_msg_buffer}) {
    next unless @{$self->_msg_buffer->{$ch} || []};
    next if $self->_buffer_timers->{$ch};
    my $id = POE::Kernel->alarm_set(_process_buffer => time() + $delay, $ch);
    $self->_buffer_timers->{$ch} = $id;
  }
}

1;
