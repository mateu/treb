package Bot::Runtime::PresenceEvents;

use strict;
use warnings;

use Bot::Runtime::Presence ();

sub handle_irc_join {
  my (%args) = @_;
  my $self = $args{self} or die 'handle_irc_join requires self';
  my $nickstr = $args{nickstr};
  my $channel = $args{channel};

  my ( $nick, $host ) = split /!/, ($nickstr // ''), 2;
  return 0 if $nick eq $self->get_nickname;
  $self->info("$channel $nick ($host) joined");
  $self->_last_activity(time());
  $self->_buffer_message(
    $channel,
    'system',
    Bot::Runtime::Presence::join_message(
      nick           => $nick,
      host           => $host,
      join_greet_pct => $self->_persona_trait('join_greet_pct'),
    ),
  );

  return 1;
}

sub handle_irc_part {
  my (%args) = @_;
  my $self = $args{self} or die 'handle_irc_part requires self';
  my $nickstr = $args{nickstr};
  my $channel = $args{channel};
  my $reason = $args{reason};

  my ( $nick, $host ) = split /!/, ($nickstr // ''), 2;
  return 0 if $nick eq $self->get_nickname;
  $self->info("$channel $nick ($host) parted" . ($reason ? ": $reason" : ''));
  $self->_last_activity(time());
  my $msg = Bot::Runtime::Presence::part_message(
    nick   => $nick,
    host   => $host,
    reason => $reason,
  );
  $self->_buffer_message($channel, 'system', $msg);

  return 1;
}

sub handle_irc_quit {
  my (%args) = @_;
  my $self = $args{self} or die 'handle_irc_quit requires self';
  my $nickstr = $args{nickstr};
  my $reason = $args{reason};

  my ( $nick, $host ) = split /!/, ($nickstr // ''), 2;
  return 0 if $nick eq $self->get_nickname;
  $self->info("$nick ($host) quit" . ($reason ? ": $reason" : ''));
  $self->_last_activity(time());
  my $channel = $self->_default_channel;

  if (Bot::Runtime::Presence::is_netsplit_reason(reason => $reason)) {
    push @{$self->_netsplit_quits}, $nick;
    # Delay reporting to aggregate short bursts from split storms.
    POE::Kernel->delay( _netsplit_report => 3, $channel, $reason );
    return 1;
  }

  my $msg = Bot::Runtime::Presence::quit_message(
    nick   => $nick,
    host   => $host,
    reason => $reason,
  );
  $self->_buffer_message($channel, 'system', $msg);

  return 1;
}

sub handle_netsplit_report {
  my (%args) = @_;
  my $self = $args{self} or die 'handle_netsplit_report requires self';
  my $channel = $args{channel};
  my $split_reason = $args{split_reason};

  my @nicks = @{$self->_netsplit_quits};
  return 0 unless @nicks;
  $self->_netsplit_quits([]);
  $self->_buffer_message(
    $channel,
    'system',
    Bot::Runtime::Presence::netsplit_report_message(
      split_reason => $split_reason,
      nicks        => \@nicks,
    ),
  );

  return 1;
}

sub handle_irc_msg {
  my (%args) = @_;
  my $self = $args{self} or die 'handle_irc_msg requires self';
  my $nickstr = $args{nickstr};
  my $msg = $args{msg};

  my ( $nick, $host ) = split /!/, ($nickstr // ''), 2;
  return 0 if $nick eq $self->get_nickname;
  $self->info("PM <$nick> ($host) $msg");
  $self->_last_activity(time());
  my $channel = $self->_default_channel;
  $self->_buffer_message(
    $channel,
    'system',
    Bot::Runtime::Presence::private_message_message(
      nick => $nick,
      host => $host,
      msg  => $msg,
    ),
  );

  return 1;
}

sub handle_irc_whois {
  my (%args) = @_;
  my $self = $args{self} or die 'handle_irc_whois requires self';
  my $info = $args{info} || {};

  my $notes = $self->memory->recall_notes($info->{nick}, '', 100);
  my $result = Bot::Runtime::Presence::whois_text(
    info  => $info,
    notes => $notes,
  );
  $self->info($result);
  my $channel = $self->_default_channel;
  $self->_buffer_message($channel, 'system', $result);

  return 1;
}

1;
