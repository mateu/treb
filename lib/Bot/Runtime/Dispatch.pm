package Bot::Runtime::Dispatch;

use strict;
use warnings;

use Exporter 'import';
our @EXPORT_OK = qw(
  parse_public_addressee
  is_public_message_addressed_to_self
  send_to_channel
  is_filtered_bot_nick
  default_channel
  utility_command_matches_me
);

sub _nickname_aliases {
  my ($self) = @_;
  my $nick = $self->get_nickname // '';
  my %aliases;
  for my $name ($nick, ($ENV{BOT_IDENTITY_SLUG} // '')) {
    next unless defined $name && length $name;
    $aliases{lc $name} = 1;
    (my $short = $name) =~ s/(?:_bot|_agent)\z//i;
    $aliases{lc $short} = 1 if length $short;
  }
  return %aliases;
}

sub parse_public_addressee {
  my (%args) = @_;
  my $msg = $args{msg};
  my $self = $args{self};
  return (undef, undef) unless defined $msg;

  if ($msg =~ /^\s*([A-Za-z0-9_\-]+)\s*[:,]\s*(.+?)\s*$/s) {
    return ($1, $2);
  }

  if ($msg =~ /^\s*hey\s+([A-Za-z0-9_\-]+)\s*[:,]?\s*(.+?)\s*$/si) {
    return ($1, $2);
  }

  if ($self && $msg =~ /^\s*([A-Za-z0-9_\-]+)\s+(.+?)\s*$/s) {
    my ($target, $body) = ($1, $2);
    my %aliases = _nickname_aliases($self);
    return ($target, $body) if $aliases{lc $target};
  }

  return (undef, undef);
}

sub is_public_message_addressed_to_self {
  my (%args) = @_;
  my $self = $args{self} or die 'is_public_message_addressed_to_self requires self';
  my $msg = $args{msg};

  my ($target, $body) = parse_public_addressee(self => $self, msg => $msg);
  return 0 unless defined $target && defined $body && $body =~ /\S/;
  my %aliases = _nickname_aliases($self);
  return $aliases{lc $target} ? 1 : 0;
}

sub send_to_channel {
  my (%args) = @_;
  my $channel = $args{channel} or die 'send_to_channel requires channel';
  my $text = defined $args{text} ? $args{text} : '';
  my $max_line = $args{max_line};
  die 'send_to_channel requires max_line' unless defined $max_line;
  die 'send_to_channel requires max_line to be a positive integer'
    unless $max_line =~ /\A[1-9]\d*\z/;
  $max_line = int($max_line);
  my $event_name = $args{event_name} || '_send_line';
  my $return_cumulative = $args{return_cumulative} ? 1 : 0;

  my @chunks;
  for my $line (split(/\n/, $text)) {
    $line =~ s/^\s+//;
    $line =~ s/\s+$//;
    next unless length $line;
    while (length($line) > $max_line) {
      my $chunk = substr($line, 0, $max_line);
      if ($chunk =~ /^(.{1,$max_line})\s/) {
        $chunk = $1;
      }
      push @chunks, $chunk;
      $line = substr($line, length($chunk));
      $line =~ s/^\s+//;
    }
    push @chunks, $line if length $line;
  }

  my $cumulative = 0;
  for my $i (0 .. $#chunks) {
    my $delay = length($chunks[$i]) / 30;
    $delay = 1.5 if $delay < 1.5;
    $delay += 5 if $i > 0 && $chunks[$i - 1] =~ /\.{3}\s*\*?\s*$/;
    $cumulative += $delay;
    POE::Kernel->delay_add($event_name => $cumulative, $channel, $chunks[$i]);
  }

  return $return_cumulative ? $cumulative : undef;
}

sub is_filtered_bot_nick {
  my (%args) = @_;
  my $nick = $args{nick};
  return unless defined $nick;

  my $default_filter_nicks = defined $args{default_filter_nicks} ? $args{default_filter_nicks} : 'burt_bot';
  my $raw = $ENV{BOT_FILTER_NICKS} // $default_filter_nicks;
  my %blocked = map { lc($_) => 1 }
                grep { length }
                map  { s/^\s+|\s+$//gr }
                split /,/, $raw;

  return $blocked{lc $nick};
}

sub default_channel {
  my (%args) = @_;
  my $self = $args{self} or die 'default_channel requires self';
  my $channels = $self->get_channels;
  return ref $channels ? $channels->[0] : $channels;
}

sub utility_command_matches_me {
  my (%args) = @_;
  my $self = $args{self} or die 'utility_command_matches_me requires self';
  my $target = $args{target};
  my $allow_bare = $args{allow_bare} ? 1 : 0;

  return $allow_bare unless defined $target && length $target;
  my %aliases = _nickname_aliases($self);
  return $aliases{lc $target} ? 1 : 0;
}

1;
