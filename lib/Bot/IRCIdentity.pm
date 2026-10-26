package Bot::IRCIdentity;
use strict;
use warnings;
use Exporter 'import';
our @EXPORT_OK = qw(irc_fold irc_scope);

sub irc_fold {
  my ($value, $mapping) = @_;
  $value //= '';
  $mapping //= $ENV{IRC_CASEMAPPING} // 'rfc1459';
  die "Unsupported IRC casemapping\n" unless $mapping =~ /\A(?:ascii|strict-rfc1459|rfc1459)\z/;
  $value =~ tr/A-Z/a-z/;
  $value =~ tr/[]\\/{}|/ unless $mapping eq 'ascii';
  $value =~ tr/^/~/ if $mapping eq 'rfc1459';
  return $value;
}

sub irc_scope {
  my (%args) = @_;
  my $network = lc($args{network} // $ENV{IRC_SERVER} // 'irc.perl.org');
  my $channel = $args{channel} // '';
  die "Network and public channel required\n"
    unless length($network) && length($network) <= 255 && $network !~ /[\s\x00]/
      && $channel =~ /\A[#&][^\s,\x00]{1,199}\z/;
  return ($network, irc_fold($channel));
}
1;
