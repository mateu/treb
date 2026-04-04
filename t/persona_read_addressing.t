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
  q|if ($msg =~ /^(?:([A-Za-z0-9_\-]+):\s+persona\s+full\s*)$/i) {|,
  'full persona read requires addressed form in utility runtime',
);
like_literal(
  $utility_commands,
  q|if ($msg =~ /^(?:([A-Za-z0-9_\-]+):\s+persona\s*)$/i) {|,
  'summary persona read requires addressed form in utility runtime',
);
unlike_literal(
  $utility_commands,
  q{(?::persona\s+full\s*|persona:\s*full},
  'no bare full persona read fallback remains',
);
unlike_literal(
  $utility_commands,
  q{(?::persona\s*|persona:\s*)$},
  'no bare summary persona read fallback remains',
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
