use strict;
use warnings;
use Test::More;

use lib 'lib';
use Bot::Runtime::WebTools qw(format_search_results format_extractive_url_summary);

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

subtest 'format_extractive_url_summary returns page text without raider' => sub {
  my $out = format_extractive_url_summary(
    title   => 'Gist Title',
    excerpt => "First paragraph with enough characters to be kept as a chunk.\n\nSecond paragraph also long enough for extraction here.\n\nshort\n",
    url     => 'https://gist.github.com/mateu/example',
  );
  like($out, qr/^Extracted page text for https:\/\/gist\.github\.com\/mateu\/example/m, 'labels source URL');
  like($out, qr/Gist Title/, 'includes title');
  like($out, qr/First paragraph with enough characters/, 'includes long chunk');
  unlike($out, qr/^short$/m, 'skips short fragments');
};

{
  package Local::NoRaidBot;
  sub new { bless { raid_calls => 0 }, shift }
  sub _raider { return $_[0] }
  sub raid {
    my ($self) = @_;
    $self->{raid_calls}++;
    die 'nested raid must not be called from summarize_url';
  }
  sub _summarize_special_url { return undef }
}

subtest 'summarize_url never nests into raider->raid' => sub {
  my $bot = Local::NoRaidBot->new;
  # Force fetch failure path still must not touch raid.
  local $ENV{PATH} = '/usr/bin:/bin';
  my $out = Bot::Runtime::WebTools::summarize_url($bot, 'https://example.invalid/no-such-host-treb-test');
  is($bot->{raid_calls}, 0, 'raid was not invoked');
  like($out, qr/URL fetch failed|URL did not yield|Extracted page text|Please provide/i, 'returns tool-safe result');
};

done_testing;
