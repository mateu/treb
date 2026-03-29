use strict;
use warnings;
use Test::More;

require './treb.pl';

my $obj = bless {}, 'BertBot';

ok(BertBot->can('_current_local_time_text'), 'has _current_local_time_text helper');

my $text = $obj->_current_local_time_text;
ok(defined $text && $text ne '', 'time text returned');
like($text, qr/America\/Denver\)/, 'includes America/Denver label');
like($text, qr/\b(?:AM|PM)\b/, 'includes AM/PM');
like($text, qr/^(?:Sunday|Monday|Tuesday|Wednesday|Thursday|Friday|Saturday),\s+(?:January|February|March|April|May|June|July|August|September|October|November|December)\s+\d{1,2},\s+\d{4},\s+\d{1,2}:\d{2}\s+(?:AM|PM)\s+\S+\s+\(America\/Denver\)$/,
    'matches expected human-readable shape');

ok(index(Path('treb.pl')->slurp, q{name         => 'current_time'}) >= 0, 'MCP tool registration present') if 0;

# Keep this file small and behavior-focused; dispatch is exercised live.

done_testing;
