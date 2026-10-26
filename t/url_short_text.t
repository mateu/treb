use strict;
use warnings;
use Test::More;
use lib 'lib';
use Bot::Runtime::WebTools qw(summarize_url);

{ package Local::PageBot; sub new { bless {}, shift } sub _summarize_special_url { undef } }
my $bot = Local::PageBot->new;
my $message = "Das Pferd frisst keinen Gurkensalat!\n";

subtest 'short .txt file is delivered whole' => sub {
  no warnings 'redefine';
  local *Bot::Runtime::WebTools::_fetch_url = sub { ($message, 'text/plain') };
  my $out = summarize_url($bot, 'https://lo.keep-cool.org/message.txt');
  like($out, qr/Complete extracted page text/, 'not rejected for being short');
  like($out, qr/Das Pferd frisst keinen Gurkensalat!/, 'full text present');
  unlike($out, qr/SHORT PAGE/, 'raw text is not flagged as a placeholder');
};

subtest 'short text/plain without extension is raw by Content-Type' => sub {
  no warnings 'redefine';
  local *Bot::Runtime::WebTools::_fetch_url = sub { ("ok <b>not html</b>\n", 'text/plain; charset=utf-8') };
  my $out = summarize_url($bot, 'https://example.test/message');
  like($out, qr/ok <b>not html<\/b>/, 'angle brackets survive in declared plain text');
  unlike($out, qr/SHORT PAGE/, 'no placeholder warning');
};

subtest 'short HTML is returned with a placeholder warning' => sub {
  no warnings 'redefine';
  local *Bot::Runtime::WebTools::_fetch_url = sub {
    ('<!doctype html><html><head><title>App</title><script>boot()</script></head>'
      . '<body><noscript>You need to enable JavaScript to run this app.</noscript><div id="root"></div></body></html>',
     'text/html; charset=utf-8');
  };
  my $out = summarize_url($bot, 'https://example.test/app');
  like($out, qr/enable JavaScript/, 'stripped text still delivered');
  like($out, qr/SHORT PAGE: only \d+ characters/, 'flags likely placeholder');
  unlike($out, qr/boot\(\)/, 'script removed');
};

subtest 'HTML with no readable text still fails' => sub {
  no warnings 'redefine';
  local *Bot::Runtime::WebTools::_fetch_url = sub {
    ('<html><body><script>boot()</script><div id="root"></div></body></html>', 'text/html');
  };
  like(summarize_url($bot, 'https://example.test/empty'), qr/did not yield any readable text/, 'empty after stripping is rejected');
};

subtest 'scalar-only fetch fixtures still work' => sub {
  no warnings 'redefine';
  local *Bot::Runtime::WebTools::_fetch_url = sub { 'tiny' };
  like(summarize_url($bot, 'https://example.test/x'), qr/--- BEGIN PAGE TEXT ---\ntiny\n/, 'short body without type is delivered');
};

done_testing;
