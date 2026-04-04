use strict;
use warnings;
use Test::More;

sub slurp {
  my ($file) = @_;
  return do { local (@ARGV, $/) = $file; <> };
}

sub like_literal {
  my ($text, $literal, $name) = @_;
  like($text, qr/\Q$literal\E/, $name);
}

sub unlike_literal {
  my ($text, $literal, $name) = @_;
  unlike($text, qr/\Q$literal\E/, $name);
}

my $utility_commands = slurp('lib/Bot/Runtime/UtilityCommands.pm');

like_literal(
  $utility_commands,
  q|if ($msg =~ /^([A-Za-z0-9_\-]+):\s+persona\s+set\s+(\S+)\s+(?:=\s*)?(\S+)\s*$/i) {|,
  'persona set requires addressed form in utility runtime',
);
like_literal(
  $utility_commands,
  q{return 0 unless lc($1) eq lc($self->get_nickname);},
  'persona set checks addressed nick matches bot nickname',
);
unlike_literal(
  $utility_commands,
  q{(?::persona\s+set\s+|persona:\s*set\s+)},
  'no legacy bare persona set fallback remains',
);

for my $script (qw(treb.pl burt.pl)) {
  my $entrypoint = slurp($script);
  like_literal(
    $entrypoint,
    q{Bot::Runtime::UtilityCommands::handle_public_utility_command(},
    "$script delegates utility parsing to runtime module",
  );
}

done_testing;
