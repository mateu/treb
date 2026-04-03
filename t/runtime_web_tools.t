use strict;
use warnings;
use Test::More;

use lib 'lib';
use Bot::Runtime::WebTools qw(format_search_results);

my $no_results = format_search_results(undef, 'perl testing', {}, 3);
is($no_results, 'No useful web results found for: perl testing', 'reports no useful results when payload has no web entries');

my $formatted = format_search_results(
  undef,
  'perl bots',
  {
    web => {
      results => [
        {
          title       => 'Bot &amp; Tooling',
          url         => 'https://example.test/bot',
          description => 'A practical guide to IRC bot tooling and operations.',
        },
        {
          title       => 'Second result',
          url         => 'https://example.test/second',
          description => 'x' x 220,
        },
      ],
    },
  },
  2,
);

like($formatted, qr/^1\. Bot & Tooling - https:\/\/example\.test\/bot/m, 'formats first result line');
like($formatted, qr/^2\. Second result - https:\/\/example\.test\/second/m, 'formats second result line');
like($formatted, qr/\n\s{3}x{180}\.\.\./, 'truncates long descriptions to 180 chars plus ellipsis');

my $limit_clamped = format_search_results(
  undef,
  'perl bots',
  {
    web => {
      results => [
        { title => 'A', url => 'https://a.test', description => '' },
        { title => 'B', url => 'https://b.test', description => '' },
      ],
    },
  },
  1,
);

unlike($limit_clamped, qr/^2\./m, 'respects result limit');

done_testing;
