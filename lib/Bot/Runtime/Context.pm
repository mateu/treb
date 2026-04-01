package Bot::Runtime::Context;

use strict;
use warnings;

use Exporter 'import';
our @EXPORT_OK = qw(build_context_and_input);

sub build_context_and_input {
  my (%args) = @_;
  my $self     = $args{self}     or die 'build_context_and_input requires self';
  my $channel  = $args{channel}  or die 'build_context_and_input requires channel';
  my $messages = $args{messages} || [];

  my %seen_nicks;
  for my $m (@{$messages}) {
    next if (($m->{nick} // '') eq 'system');
    $seen_nicks{$m->{nick}} = 1 if defined $m->{nick} && length $m->{nick};
  }

  for my $m (grep { (($_->{nick} // '') eq 'system') } @{$messages}) {
    if (($m->{msg} // '') =~ /^(\S+)\s+\(/) {
      $seen_nicks{$1} = 1;
    }
    if (($m->{msg} // '') =~ /PRIVATE MESSAGE from (\S+)/) {
      $seen_nicks{$1} = 1;
    }
  }

  my @channel_nicks = eval { $self->irc->nicks($channel) } || ();
  if (@channel_nicks) {
    my %chan_nicks = map { lc($_) => $_ } @channel_nicks;
    for my $m (@{$messages}) {
      for my $word (split /\W+/, ($m->{msg} // '')) {
        if (my $real = $chan_nicks{lc $word}) {
          $seen_nicks{$real} = 1;
        }
      }
    }
  }

  my $context = '';
  for my $nick (sort keys %seen_nicks) {
    my $notes = $self->memory->recall_notes($nick, '', 5);
    if ($notes) {
      $context .= "[Your notes about $nick: $notes]\n";
    }
  }

  my $rendered = join("\n", map {
    my $prefix = $_->{nick};
    if (($prefix // '') ne 'system' && $self->irc->is_channel_operator($channel, $prefix)) {
      $prefix = '@' . $prefix;
    }
    '<' . $prefix . '> ' . ($_->{msg} // '');
  } @{$messages});

  my $input = '';
  $input .= $context if $context;
  $input .= $rendered;

  return {
    seen_nicks => [sort keys %seen_nicks],
    context    => $context,
    rendered   => $rendered,
    input      => $input,
  };
}

1;
