package Bot::Runtime::Dispatch;

use strict;
use warnings;

use Exporter 'import';
use Encode qw(encode);
use Time::HiRes ();
our @EXPORT_OK = qw(
  parse_public_addressee
  is_public_message_addressed_to_self
  send_to_channel
  clear_send_queue
  pending_send_count
  is_stop_request
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

  if ($msg =~ /^\s*([A-Za-z0-9_\-]+)\s*[:,!]\s*(.+?)\s*$/s) {
    return ($1, $2);
  }

  if ($msg =~ /^\s*hey\s*,?\s*([A-Za-z0-9_\-]+)\s*[:,!?]?\s*(.+?)\s*$/si) {
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

# Lines not yet delivered, per IRC target: alarm ID plus the time it fires.
# One bot runs per process, so a module registry is the bot's registry.
# Entries past their fire time are pruned lazily; an alarm that already fired
# simply fails to remove.
my %PENDING_SENDS;

sub _send_queue_key { lc($_[0] // '') }

sub _prune_send_queue {
  my ($key) = @_;
  my $list = $PENDING_SENDS{$key} or return;
  my $now = Time::HiRes::time();
  @$list = grep { $_->[1] > $now } @$list;
  delete $PENDING_SENDS{$key} unless @$list;
}

sub pending_send_count {
  my (%args) = @_;
  my $key = _send_queue_key($args{channel});
  _prune_send_queue($key);
  return scalar @{ $PENDING_SENDS{$key} || [] };
}

# Cancel every line still scheduled for one target. Returns how many alarms
# were actually removed. Must run inside the bot's POE session, the session
# that scheduled them; POE only removes the current session's alarms.
sub clear_send_queue {
  my (%args) = @_;
  my $key = _send_queue_key($args{channel});
  my $list = delete $PENDING_SENDS{$key} or return 0;
  my $removed = 0;
  for my $entry (@$list) {
    my @gone = POE::Kernel->alarm_remove($entry->[0]);
    $removed++ if @gone;
  }
  return $removed;
}

# A short, addressed request to stop talking: "burt_bot: stop",
# "burt_bot: that's enough", "burt_bot: stop dumping". Anything longer is
# ordinary conversation and goes to the model.
my $STOP_BODY_RE = qr{
  \A
  (?: (?:ok(?:ay)?|please|pls|hey|whoa|woah) [,!.]* \s+ )*
  (?: (?:you \s+ can|can \s+ you|could \s+ you|just) \s+ )?
  (?: stop | halt | enough | that ['\x{2019}]? s \s+ enough | shut \s+ up | hush
    | (?:be \s+)? quiet | stfu | cancel )
  (?: \s+ (?:it|that|now|please|already|talking|dumping|spamming|flooding
            |pasting|posting|summari[sz]ing|transcribing) )*
  [\s.!,]*
  \z
}xi;

sub is_stop_request {
  my (%args) = @_;
  my $self = $args{self} or die 'is_stop_request requires self';
  my ($target, $body) = parse_public_addressee(self => $self, msg => $args{msg});
  return 0 unless defined $target && defined $body;
  my %aliases = _nickname_aliases($self);
  return 0 unless $aliases{lc $target};
  return $body =~ $STOP_BODY_RE ? 1 : 0;
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

  die 'invalid IRC target' if $channel =~ /[\s\x00:]/;
  # RFC 2812: 512 octets including PRIVMSG, target, separator and CRLF.
  my $wire_budget = 512 - length(encode('UTF-8', "PRIVMSG $channel :\r\n"));
  $max_line = $wire_budget if $max_line > $wire_budget;
  die 'IRC target leaves no payload space' if $max_line < 1;
  # Never allow raw CR/NUL to reach a protocol command.
  $text =~ s/[\r\x00]//g;
  my @chunks;
  for my $line (split(/\n/, $text)) {
    $line =~ s/^\s+|\s+$//g;
    while (length $line) {
      my ($count, $bytes) = (0, 0);
      for my $char (split //, $line) {
        my $size = length(encode('UTF-8', $char));
        last if $bytes + $size > $max_line;
        $bytes += $size;
        $count++;
      }
      die 'max_line too small for a UTF-8 character' unless $count;
      my $chunk = substr($line, 0, $count);
      if ($count < length($line) && $chunk =~ /^(.*\S)\s+\S*$/s) {
        $chunk = $1;
      }
      push @chunks, $chunk;
      substr($line, 0, length($chunk), '');
      $line =~ s/^\s+//;
    }
  }

  my $cumulative = 0;
  my $key = _send_queue_key($channel);
  _prune_send_queue($key);
  my $start = Time::HiRes::time();
  for my $i (0 .. $#chunks) {
    my $delay = length($chunks[$i]) / 30;
    $delay = 1.5 if $delay < 1.5;
    $delay += 5 if $i > 0 && $chunks[$i - 1] =~ /\.{3}\s*\*?\s*$/;
    $cumulative += $delay;
    # delay_set, not delay_add: only delay_set returns an alarm ID to cancel.
    my $id = POE::Kernel->delay_set($event_name => $cumulative, $channel, $chunks[$i]);
    push @{ $PENDING_SENDS{$key} }, [$id, $start + $cumulative] if defined $id;
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
