use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);

use lib 'lib';
use Bot::MemoryStore;

my $dir = tempdir(CLEANUP => 1);
my $mem = Bot::MemoryStore->new(db_file => "$dir/pin.sqlite");

$mem->save_note('phschafft', 'PINNED: dictionary tool does not exist yet');
$mem->save_note('phschafft', "ordinary note $_") for 1 .. 6;

my @lines = split /\n/, $mem->recall_notes('phschafft', '', 3);
is scalar(@lines), 3, 'limit respected';
like $lines[0], qr/PINNED: dictionary/, 'pinned note is first even though oldest';
like $lines[1], qr/ordinary note 6/, 'then newest first';

my $lead = 0;
$lead++ for grep { (split /\n/, $mem->recall_notes('phschafft', '', 3, 50))[0] =~ /PINNED:/ } 1 .. 400;
cmp_ok $lead, '>', 120, 'pin_pct 50: pinned leads often';
cmp_ok $lead, '<', 280, 'pin_pct 50: but not always';

my @none = split /\n/, $mem->recall_notes('phschafft', '', 3, 0);
unlike $none[0], qr/PINNED:/, 'pin_pct 0: pinned ranks by recency';
is scalar(@none), 3, 'limit still respected';

done_testing;
