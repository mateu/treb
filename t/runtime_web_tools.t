use strict;
use warnings;

use Test::More;

use lib 'lib';
use Bot::Runtime::WebTools qw(
  format_search_results
  summarize_url
  search_web
);

subtest 'format_search_results keeps legacy defaults and clamps' => sub {
  my $data = {
    web => {
      results => [
        map +{ title => "R$_", url => "https://e/$_", description => "d$_" }, 1 .. 6
      ],
    },
  };

  my $out_default = format_search_results('test', $data);
  like($out_default, qr/^3\. R3 - https:\/\/e\/3/m, 'default includes third result');
  unlike($out_default, qr/^4\. R4 - https:\/\/e\/4/m, 'default omits fourth result');

  my $out_clamped = format_search_results('test', $data, 999);
  like($out_clamped, qr/^5\. R5 - https:\/\/e\/5/m, 'upper bound clamps to five');
  unlike($out_clamped, qr/^6\. R6 - https:\/\/e\/6/m, 'sixth result omitted after clamp');
};

subtest 'format_search_results normalizes entities and punctuation' => sub {
  my $data = {
    web => {
      results => [
        {
          title => 'Olaf Alders Â· GitHub',
          url => 'https://github.com/oalders',
          description => 'I&#x27;ve built stuff &amp; shared itâ€¦',
        },
      ],
    },
  };

  my $out = format_search_results('olaf', $data, 1);
  like($out, qr/Olaf Alders\s+-\s+GitHub - https:\/\/github.com\/oalders/, 'separator normalized');
  like($out, qr/I've built stuff & shared it\.\.\./, 'entities normalized');
};

subtest 'search_web validates input before network call' => sub {
  is(search_web(query => '   ', api_key => 'x'), 'Search query is empty.', 'empty query guarded');
  is(search_web(query => 'thing', api_key => ''), q{Web search isn't configured right now.}, 'missing key guarded');
};

subtest 'summarize_url validates input and supports special-url callback' => sub {
  is(summarize_url(url => ''), 'URL is empty.', 'empty URL guarded');
  is(summarize_url(url => 'ftp://example.com'), 'Please provide an http:// or https:// URL.', 'scheme guarded');

  my $raid_called = 0;
  my $out = summarize_url(
    url => 'https://metacpan.org/pod/Adam',
    summarize_special_url_cb => sub { return "special summary for $_[0]"; },
    raid_cb => sub { $raid_called = 1; return 'should not be used'; },
  );

  is($out, 'special summary for https://metacpan.org/pod/Adam', 'special callback short-circuits');
  is($raid_called, 0, 'raid callback not called when special summary is available');
};

done_testing;
