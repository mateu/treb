use strict;
use warnings;
use Test::More;

sub check_source {
  my (%args) = @_;
  my $text = do { local (@ARGV, $/) = $args{file}; <> };

  like(
    $text,
    qr/\^\(\?:\(\[A-Za-z0-9_\\-\]\+\):\\s\+persona\\s\+set\\s\+\(\\S\+\)\\s\+\(\\S\+\)/s,
    "$args{name} supports addressed persona set syntax",
  );

  like(
    $text,
    qr/return unless lc\(\$1\) eq lc\(\$self->get_nickname\)/,
    "$args{name} persona set checks addressed nick matches self",
  );

  like(
    $text,
    qr/else \{\n\s+return;\n\s+\}/s,
    "$args{name} rejects unaddressed persona set writes",
  );
}

check_source(file => 'treb.pl', name => 'treb');
check_source(file => 'burt.pl', name => 'burt');

done_testing;
