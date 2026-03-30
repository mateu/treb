use strict;
use warnings;
use Test::More;

sub check_source {
  my (%args) = @_;
  my $text = do { local (@ARGV, $/) = $args{file}; <> };

  like(
    $text,
    qr/\):\\s\+persona\\s\+set\\s\+/,
    "$args{name} still has addressed persona set handler",
  );

  like(
    $text,
    qr/return unless lc\(\$1\) eq lc\(\$self->get_nickname\);/,
    "$args{name} persona set checks addressed nick matches self",
  );

  unlike(
    $text,
    qr/\(\?::persona\\s\+set\\s\+\|persona:\\s\*set\\s\+\)/,
    "$args{name} no legacy bare persona set fallback remains",
  );
}

check_source(file => 'treb.pl', name => 'treb');
check_source(file => 'burt.pl', name => 'burt');

done_testing;
