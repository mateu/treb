use strict;
use warnings;
use Test::More;

use lib 'lib';
use Bot::Runtime::OutputPipeline qw(clean_ai_output);

{
  package TestBot;

  sub new {
    my ($class) = @_;
    return bless { logs => [] }, $class;
  }

  sub _log_cleanup_change {
    my ($self, $label, $before, $after) = @_;
    push @{$self->{logs}}, [$label, $before, $after];
    return;
  }

  sub _clean_text_for_irc {
    my ($self, $text) = @_;
    $text =~ s/[ ]{2,}/ /g;
    $text =~ s/^\s+|\s+$//g;
    return "IRC:$text";
  }

  sub log_labels {
    my ($self) = @_;
    return map { $_->[0] } @{$self->{logs}};
  }
}

my $bot = TestBot->new;
my $cleaned = clean_ai_output(
  self => $bot,
  text => '<think>hidden</think>  <@mateu>  hello  ' . "\n" . 'save_note foo' . "\n",
);

is($cleaned, 'IRC:mateu: hello', 'strips reasoning/tool lines and normalizes via bot hook');
is_deeply(
  [ $bot->log_labels ],
  [ 'strip_reasoning', 'strip_markup', 'normalize_text' ],
  'logs cleanup phases with default labels',
);

my $retry_bot = TestBot->new;
my $retry_cleaned = clean_ai_output(
  self => $retry_bot,
  text => '<thinking>internal</thinking> <nick> retry',
  log_prefix => 'warm_retry_',
);

is($retry_cleaned, 'IRC:nick: retry', 'supports warm retry cleanup payload');
is_deeply(
  [ $retry_bot->log_labels ],
  [ 'warm_retry_strip_reasoning', 'warm_retry_strip_markup', 'warm_retry_normalize_text' ],
  'applies configured log label prefix',
);

my $silence_bot = TestBot->new;
my $silence_cleaned = clean_ai_output(
  self => $silence_bot,
  text => 'status: Remaining quiet.',
);

is($silence_cleaned, 'IRC:', 'collapses status-prefixed silence intent before send');

my $substantive_bot = TestBot->new;
my $substantive_cleaned = clean_ai_output(
  self => $substantive_bot,
  text => 'No output file was generated because the command failed.',
);

is(
  $substantive_cleaned,
  'IRC:No output file was generated because the command failed.',
  'does not collapse substantive no-output diagnostic text',
);

done_testing;
