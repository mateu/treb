use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use lib 'lib';
use Bot::Runtime::WebTools qw(summarize_url);

{ package Local::PageBot; sub new { bless {}, shift } sub _summarize_special_url { undef } }
my $bot = Local::PageBot->new;
my $cap = Bot::Runtime::WebTools::_max_download_bytes();

# A stand-in curl on PATH: writes FAKE_CURL_BYTES of 'a' then the -w write-out.
my $dir = tempdir(CLEANUP => 1);
open my $fh, '>', "$dir/curl" or die $!;
print {$fh} <<'SH';
#!/usr/bin/env perl
my ($w) = map { $ARGV[$_ + 1] } grep { $ARGV[$_] eq '-w' } 0 .. $#ARGV;
$| = 1;
my $left = $ENV{FAKE_CURL_BYTES};
while ($left > 0) { my $n = $left > 65536 ? 65536 : $left; print 'a' x $n; $left -= $n; }
$w =~ s/%\{content_type\}/text\/plain/;
print $w;
SH
close $fh;
chmod 0755, "$dir/curl";
local $ENV{PATH} = "$dir:$ENV{PATH}";

subtest 'body under the cap is complete and keeps its Content-Type' => sub {
  local $ENV{FAKE_CURL_BYTES} = 5000;
  my ($body, $type, $cut) = Bot::Runtime::WebTools::_fetch_url('https://example.test/small');
  is(length $body, 5000, 'whole body returned');
  is($type, 'text/plain', 'write-out Content-Type parsed');
  ok(!$cut, 'not flagged as truncated');
};

subtest 'body over the cap is cut at the cap, not rejected' => sub {
  local $ENV{FAKE_CURL_BYTES} = $cap * 3;
  my ($body, $type, $cut) = Bot::Runtime::WebTools::_fetch_url('https://example.test/big');
  ok(defined $body, 'oversized body still yields text');
  is(length $body, $cap, 'body cut exactly at the cap');
  ok($cut, 'flagged as truncated');
  unlike($body, qr/__BOT_URL_CONTENT_TYPE__/, 'write-out marker never leaks into body');
};

subtest 'summarize_url marks a cut download on every chunk and at the end' => sub {
  no warnings 'redefine';
  local *Bot::Runtime::WebTools::_fetch_url = sub { ('x' x 20000, '', 1) };
  my $first = summarize_url($bot, 'https://example.test/big.txt');
  like($first, qr/DOWNLOAD CUT: only the first \d+ KiB/, 'first chunk says the download was cut');
  like($first, qr/TRUNCATED:.*offset=12000/, 'still offers the next offset');
  my $last = summarize_url($bot, 'https://example.test/big.txt', 12000);
  like($last, qr/End of fetched text\. The rest of the page was never downloaded/, 'last chunk does not claim completeness');
  unlike($last, qr/Complete extracted page text/, 'never reports a cut page as complete');
};

done_testing;
