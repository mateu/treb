use strict;
use warnings;
use Test::More;

sub check_source {
  my (%args) = @_;
  my $text = do { local (@ARGV, $/) = $args{file}; <> };
  like($text, qr/\(\?:\(\[A-Za-z0-9_\\-\]\+\):\\s\+persona\\s\+full\\s\*\)\$/s, "$args{name} full persona read requires addressed form");
  like($text, qr/\(\?:\(\[A-Za-z0-9_\\-\]\+\):\\s\+persona\\s\*\)\$/s, "$args{name} summary persona read requires addressed form");
  unlike($text, qr/\^\(\?::persona\\s\+full\\s\*\|persona:\\s\*full/s, "$args{name} no bare full persona read");
  unlike($text, qr/\^\(\?::persona\\s\*\|persona:\\s\*\)\$/s, "$args{name} no bare persona read");
}

check_source(file => 'treb.pl', name => 'treb');
check_source(file => 'burt.pl', name => 'burt');

done_testing;
