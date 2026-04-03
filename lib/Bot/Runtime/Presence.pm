package Bot::Runtime::Presence;

use strict;
use warnings;

use Exporter 'import';
our @EXPORT_OK = qw(
  join_message
  part_message
  is_netsplit_reason
  quit_message
  netsplit_report_message
  private_message_message
  whois_text
);

sub join_message {
  my (%args) = @_;
  my $nick = $args{nick} // '';
  my $host = $args{host} // '';
  my $join_greet_pct = defined $args{join_greet_pct} ? $args{join_greet_pct} : 100;

  return "$nick ($host) has joined the channel. join_greet_pct=$join_greet_pct. Greet them if you like!";
}

sub part_message {
  my (%args) = @_;
  my $nick = $args{nick} // '';
  my $host = $args{host} // '';
  my $reason = $args{reason};

  my $msg = "$nick ($host) has left the channel";
  $msg .= ": $reason" if defined $reason && length $reason;
  return $msg;
}

sub is_netsplit_reason {
  my (%args) = @_;
  my $reason = $args{reason};
  return 0 unless defined $reason && length $reason;
  return $reason =~ /^\S+\.\S+ \S+\.\S+$/ ? 1 : 0;
}

sub quit_message {
  my (%args) = @_;
  my $nick = $args{nick} // '';
  my $host = $args{host} // '';
  my $reason = $args{reason};

  my $msg = "$nick ($host) has quit IRC";
  $msg .= ": $reason" if defined $reason && length $reason;
  return $msg;
}

sub netsplit_report_message {
  my (%args) = @_;
  my $split_reason = $args{split_reason} // '';
  my $nicks = $args{nicks} || [];
  my $nick_list = join(', ', @{$nicks});

  return "NETSPLIT detected ($split_reason) — "
    . scalar(@{$nicks}) . " user(s) lost: $nick_list";
}

sub private_message_message {
  my (%args) = @_;
  my $nick = $args{nick} // '';
  my $host = $args{host} // '';
  my $msg = $args{msg} // '';

  return "PRIVATE MESSAGE from $nick ($host): $msg — You can reply using send_private_message.";
}

sub whois_text {
  my (%args) = @_;
  my $info = $args{info} || {};
  my $notes = $args{notes};

  my @parts;
  push @parts, "WHOIS $info->{nick}:";
  push @parts, "  Real name: $info->{real}" if $info->{real};
  push @parts, "  Host: $info->{user}\@$info->{host}" if $info->{user};
  push @parts, "  Server: $info->{server}" if $info->{server};
  push @parts, "  Channels: " . join(' ', @{$info->{channels}}) if $info->{channels};
  push @parts, "  Idle: $info->{idle}s" if defined $info->{idle};
  push @parts, "  Signed on: " . localtime($info->{signon}) if $info->{signon};
  push @parts, "  Account: $info->{account}" if $info->{account};

  if (defined $notes && $notes =~ /\S/) {
    my $count = scalar(split /\n/, $notes);
    push @parts, "  You have $count saved note(s) about this user. Use recall_notes to review them.";
  }

  return join("\n", @parts);
}

1;
