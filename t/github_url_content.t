use strict;
use warnings;
use Test::More;
use JSON::PP ();
use lib 'lib';
use Bot::Runtime::WebTools qw(summarize_url format_extractive_url_summary);

{ package Local::PageBot; sub new { bless {}, shift } sub _summarize_special_url { undef } }
my $bot = Local::PageBot->new;
my $article = "---\ntitle: Pass filenames\n---\n\nOpening paragraph " . ('intro ' x 60)
  . "\n\n## Example\n```perl\nmy \$input = <STDIN>;\nsystem('perl', 'child.pl', 'night mix.wav');\n```\n"
  . "\n" . join("\n\n", map { "Paragraph $_: " . ('explanation ' x 10) } 1..12)
  . "\n\nFINAL VERDICT: inspect what the child receives.\n";

subtest 'raw markdown and diff preserve entire article, code and tail' => sub {
  my @seen;
  no warnings 'redefine';
  local *Bot::Runtime::WebTools::_fetch_url = sub { push @seen, $_[0]; return $article };
  for my $url ('https://raw.githubusercontent.com/user/repo/sha/article.md',
               'https://github.com/user/repo/pull/559.diff',
               'https://patch-diff.githubusercontent.com/raw/user/repo/pull/559.patch',
               'https://github.com/user/repo/blob/sha/article.md') {
    my $out = summarize_url($bot, $url);
    like($out, qr/Complete extracted page text/, 'small article delivered completely');
    like($out, qr/\Q$article\E/s, 'full body delivered without paragraph clipping');
    like($out, qr/<STDIN>/, 'Perl angle-bracket code survives');
    like($out, qr/FINAL VERDICT/, 'later sections survive');
  }
  is($seen[-1], 'https://github.com/user/repo/raw/sha/article.md', 'blob page resolves to raw rather than navigation');
};

subtest 'PR reads API patches, not navigation HTML' => sub {
  my @seen;
  no warnings 'redefine';
  local *Bot::Runtime::WebTools::_fetch_url = sub {
    my ($url) = @_; push @seen, $url;
    return JSON::PP::encode_json({ title => 'Article PR', body => 'Review this article',
      head => {sha => 'fixed-head'}, changed_files => 1 }) if $url =~ m{/pulls/559$};
    return JSON::PP::encode_json([{ filename => 'article.md', status => 'added',
      raw_url => 'https://raw.githubusercontent.com/user/repo/fixed-head/article.md', patch => $article }])
      if $url =~ m{/pulls/559/files\?per_page=100$};
    die "Unexpected URL $url";
  };
  my $out = summarize_url($bot, 'https://github.com/user/repo/pull/559/files');
  like($out, qr/Head commit: fixed-head/, 'pins returned metadata to PR head');
  like($out, qr/FINAL VERDICT/, 'includes patch tail');
  like($out, qr/<STDIN>/, 'does not HTML-strip patches');
  is(scalar @seen, 2, 'fetches metadata and changed files');
};

subtest 'large pages have explicit retrievable continuation' => sub {
  my $large = ('a' x 12000) . "\nEND OF ARTICLE";
  my $first = format_extractive_url_summary(url => 'https://example.test', excerpt => $large);
  like($first, qr/TRUNCATED:.*offset=12000/, 'provides exact next offset');
  unlike($first, qr/END OF ARTICLE/, 'bounded first result');
  my $last = format_extractive_url_summary(url => 'https://example.test', excerpt => $large, offset => 12000);
  like($last, qr/END OF ARTICLE/, 'continuation reaches tail');
  like($last, qr/End of extracted page text/, 'marks completion');
  like(summarize_url($bot, 'https://example.test', -1), qr/Offset must/, 'rejects invalid offset');
};

subtest 'GitHub omissions and retrieval failures are honest' => sub {
  no warnings 'redefine';
  local *Bot::Runtime::WebTools::_fetch_url = sub {
    return JSON::PP::encode_json({title => 'Big PR', head => {sha => 'head'}, changed_files => 101})
      if $_[0] =~ m{/pulls/559$};
    return JSON::PP::encode_json([{filename => 'binary', raw_url => 'https://example.test/raw'}]);
  };
  my $out = summarize_url($bot, 'https://github.com/user/repo/pull/559');
  like($out, qr/INCOMPLETE:/, 'discloses omitted changed files');
  like($out, qr/Patch unavailable/, 'does not pretend missing patch was read');
  local *Bot::Runtime::WebTools::_fetch_url = sub { undef };
  like(summarize_url($bot, 'https://github.com/user/repo/pull/559'), qr/could not be verified/, 'API failure is not a navigation summary');
};

subtest 'HTML extraction keeps useful text but not scripts' => sub {
  no warnings 'redefine';
  local *Bot::Runtime::WebTools::_fetch_url = sub {
    '<html><head><title>A &amp; B</title><script>secret script</script></head><body><p>'
      . ('Useful article text &lt;STDIN&gt; ' x 8) . '</p></body></html>';
  };
  my $out = summarize_url($bot, 'https://example.test/article');
  like($out, qr/A & B/, 'decodes HTML entities');
  like($out, qr/<STDIN>/, 'retains encoded code snippets');
  unlike($out, qr/secret script|<html>/, 'strips HTML and scripts');
};

subtest 'partial failed HTTP transfer is never accepted' => sub {
  require File::Temp;
  my $dir = File::Temp::tempdir(CLEANUP => 1);
  open my $fh, '>', "$dir/curl" or die $!;
  print {$fh} "#!/bin/sh\nprintf 'partial body that must not be treated as a complete article'\nexit 22\n";
  close $fh;
  chmod 0755, "$dir/curl";
  local $ENV{PATH} = $dir;
  is(summarize_url($bot, 'https://example.test/article'), 'URL fetch failed right now.', 'nonzero curl exit rejects partial data');
};

done_testing;
