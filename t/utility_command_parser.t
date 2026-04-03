use strict;
use warnings;

use Test::More;
use lib 'lib';
use Bot::Runtime::UtilityCommands qw(parse_utility_command);

sub parse_ok {
  my ($profile, $msg, $type, $label) = @_;
  my $cmd = parse_utility_command(profile => $profile, msg => $msg);
  ok($cmd, $label // "$profile parses $msg");
  is($cmd->{type}, $type, "type=$type for $msg") if $cmd;
  return $cmd;
}

sub parse_none {
  my ($profile, $msg, $label) = @_;
  my $cmd = parse_utility_command(profile => $profile, msg => $msg);
  ok(!defined($cmd), $label // "$profile does not parse $msg");
}

my $treb_sum = parse_ok('treb', ':sum https://example.com', 'sum', 'treb parses :sum');
is($treb_sum->{url}, 'https://example.com', 'treb sum captures url');

my $treb_target_sum = parse_ok('treb', 'treb: sum https://example.com', 'sum', 'treb parses addressed sum');
is($treb_target_sum->{target}, 'treb', 'treb sum captures target');

parse_none('treb', 'treb: :sum https://example.com', 'treb does not accept double-prefix sum syntax');

my $burt_sum = parse_ok('burt', 'burt: :sum https://example.com', 'sum', 'burt accepts optional target + :sum');
is($burt_sum->{target}, 'burt', 'burt sum target parsed');

my $astrid_notes = parse_ok('astrid', ':notes alice', 'notes', 'astrid parses bare notes command');
is($astrid_notes->{nick}, 'alice', 'astrid notes captures nick');
parse_none('burt', ':notes alice', 'burt does not parse bare :notes');

my $time_in = parse_ok('burt', ':time in Europe/Paris', 'time_in', 'time-in command parsed');
is($time_in->{zone}, 'Europe/Paris', 'time-in captures zone');

my $cpan_recent = parse_ok('treb', 'cpan: recent 5', 'cpan_recent', 'cpan recent parsed');
is($cpan_recent->{count}, 5, 'cpan recent count captured');

my $cpan_lookup = parse_ok('astrid', ':cpan describe Mojo::DOM', 'cpan_lookup', 'cpan describe parsed');
is(lc $cpan_lookup->{mode}, 'describe', 'cpan mode captured');
is($cpan_lookup->{query}, 'Mojo::DOM', 'cpan query captured');

my $search = parse_ok('burt', 'search: 2 Olaf Alders', 'search', 'search count prefix parsed');
is($search->{count}, 2, 'search count captured');
is($search->{query}, 'Olaf Alders', 'search query captured');

my $persona = parse_ok('treb', 'treb: persona set bot_reply_pct 33', 'persona_set', 'persona set parsed');
is($persona->{key}, 'bot_reply_pct', 'persona key captured');
is($persona->{value}, '33', 'persona value captured');

done_testing;
