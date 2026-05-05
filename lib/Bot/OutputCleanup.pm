package Bot::OutputCleanup;

use strict;
use warnings;

use Exporter 'import';
use HTML::Entities ();
use Encode ();

our @EXPORT_OK = qw(
  repair_mojibake_text
  clean_text_for_irc
  normalize_silence_intent_text
  is_silence_intent_output
  is_non_substantive_output
  cleanup_log_preview
  cleanup_change_message
  cleanup_empty_message
);

sub repair_mojibake_text {
  my ($text) = @_;
  return $text unless defined $text && length $text;
  return $text unless $text =~ /(?:â.|Â.|â€”|â€“|â€¦|Ã.|\x{fffd})/;

  my $fixed = eval {
    my $bytes = Encode::encode('latin1', $text, Encode::FB_CROAK);
    Encode::decode('UTF-8', $bytes, Encode::FB_CROAK);
  };
  return defined $fixed ? $fixed : $text;
}

sub clean_text_for_irc {
  my ($text) = @_;
  return '' unless defined $text;

  $text = HTML::Entities::decode_entities($text);
  $text = repair_mojibake_text($text);

  $text =~ s/\r//g;
  $text =~ s/\x{00A0}/ /g;
  $text =~ s/[\x{2018}\x{2019}]/'/g;
  $text =~ s/[\x{201C}\x{201D}]/"/g;
  $text =~ s/[\x{2013}\x{2014}]/ - /g;
  $text =~ s/\x{2026}/.../g;
  $text =~ s/[\x{00B7}\x{2022}]/ - /g;
  $text =~ s/\n[ ]+/\n/g;
  $text =~ s/[ \t]+/ /g;
  $text =~ s/ *\n */\n/g;
  $text =~ s/\n{3,}/\n\n/g;
  $text =~ s/^\s+|\s+$//g;

  return $text;
}

sub normalize_silence_intent_text {
  my ($text) = @_;
  return '' unless defined $text;

  $text =~ s/^\s+|\s+$//g;
  return '' unless length $text;

  my $prev = '';
  my $i = 0;
  while ($text ne $prev && $i++ < 4) {
    $prev = $text;
    $text =~ s/^\s*<(?:success|output|response)\b[^>]*>\s*(.*?)\s*<\/(?:success|output|response)>\s*$/$1/is;
    $text =~ s/^\s*(?:success|result|status)\s*:\s*//i;
    $text =~ s/^\s+|\s+$//g;
  }

  return $text;
}

sub is_silence_intent_output {
  my ($text) = @_;
  return 0 unless defined $text;

  my $normalized = normalize_silence_intent_text($text);
  return 0 unless length $normalized;
  return 0 if length($normalized) > 200;

  my $lc = lc $normalized;
  $lc =~ s/\s+/ /g;

  return 0 if $lc =~ /https?:\/\//;
  return 0 if $lc =~ /\b(?:because|since|when|while|after|before|if|but|however|except|unless|for example)\b/;

  return 1 if $lc =~ /^\(?\s*no output\s*\)?[.!?… ]*$/;
  return 1 if $lc =~ /^\(?\s*(?:no|empty) response(?: needed)?(?:\s*[-:]\s*(?:staying silent\.?|silent))?\s*\)?[.!?… ]*$/;
  return 1 if $lc =~ /^(?:no response needed|nothing to add|nothing further|no comment)(?:\b.*)?[.!?… ]*$/;
  return 1 if $lc =~ /^(?:i(?: am|'m)?\s+)?(?:stay(?:ing)?|remain(?:ing)?|keep(?:ing)?|choose|chose)\s+(?:silent|quiet|to stay silent|to remain silent|not to respond)(?:\b.*)?[.!?… ]*$/;
  return 1 if $lc =~ /^(?:bot|assistant|i)\s+(?:chose|choose|chooses|is choosing)\s+(?:silence|to stay silent|not to respond)(?:\b.*)?[.!?… ]*$/;
  return 1 if $lc =~ /^(?:just\s+)?(?:observing|listening|waiting|lurking|standing by)(?:\b.*)?[.!?… ]*$/;

  if (
    $lc =~ /\b(?:silent|silence|quiet|no output|no response|no reply|not to respond|nothing to add|nothing further|no comment|staying silent|remaining quiet|sits this out)\b/
    && $lc !~ /\b(?:error|failed|fix|bug|issue|todo|next|run|command|path|file|test|result|output:)\b/
    && $lc !~ /[0-9]{2,}/
  ) {
    return 1;
  }

  return 0;
}

sub is_non_substantive_output {
  my ($text) = @_;
  return 1 unless defined $text;

  my $orig = $text;
  $text =~ s/^\s+|\s+$//g;
  return 1 unless length $text;

  my $lc = lc $text;
  $lc =~ s/\s+/ /g;

  return 1 if $lc =~ /^(?:ok|okay|kk|noted|understood|got it|roger|sure|fine|yep|yeah|...|\.)$/;
  return 1 if $lc =~ /^\((?:[^()]|\([^)]*\)){0,120}\)$/ && $lc !~ /[a-z0-9].*[a-z0-9].*[a-z0-9]/;
  return 1 if $lc =~ /^(?:\*.*\*|_.*_)$/ && length($lc) < 80;
  return 1 if $lc =~ /^\(?\s*silent\s*[-:]/;
  return 1 if $lc =~ /^end_turn:\s*$/;
  return 1 if $lc =~ /^system \(untrusted\): no response needed\.$/;
  return 1 if $lc =~ /^system \(untrusted\): \[you were silent\. no response was needed\.\]$/;
  return 1 if $lc =~ /^system \(untrusted\):/;
  return 1 if $lc =~ /^system:\s*(?:stop further tool use until new messages arrive\.|you see messages from burt_bot in \#mateu-test\. do not reply to this system message\.|you will now receive messages\. stay quiet unless directly addressed\.)$/;
  return 1 if $lc =~ m{^<success>\s*bot chose silence\.\s*</success>$};
  return 1 if $lc =~ /^success:\s*bot chose silence\.?$/;
  return 1 if is_silence_intent_output($text);
  return 1 if $lc =~ /^\[no response needed\s*-\s*i chose silence\]$/;
  return 1 if $lc =~ /doesn't require a response from me/ && $lc =~ /lurking quietly|banter unprompted|housemate/;
  return 1 if $lc =~ /^i'?ll stay quiet(?:\b| here\.)/;
  return 1 if $lc =~ /not my moment to jump in/;
  return 1 if $lc =~ /^\(i respected her choice\.\)$/;
  return 1 if $lc =~ /^\(still respecting it\)$/;
  return 1 if $lc =~ /^\*system\* .*staying silent/;
  return 1 if $lc =~ /^\*system\* .*still just observing/;
  return 1 if $lc =~ /\b(?:bot-to-bot banter|no human involved|continuing .* without human involvement|staying quiet|remain(?:ing)? quiet|stays quiet|stays silent|without comment|notes the pattern|not speaking)\b/ && length($lc) < 240;
  return 1 if $lc =~ /^(?:silently|quietly|softly|calmly|gently|watchfully|wordlessly|still|silent|quiet)\b/ && length($lc) < 120;
  return 1 if $lc =~ /\b(?:watch(?:ing)?|listen(?:ing)?|lurking|observ(?:e|ing)|waiting|standing by)\b/ && length($lc) < 120 && $lc !~ /https?:\/\//;
  return 1 if $lc =~ /^(?:i(?: am|'m)? )?(?:stay(?:ing)?|remain(?:ing)?|keep(?:ing)?)\s+(?:silent|quiet)(?:\b.*)?[.!?… ]*$/ && length($lc) < 120;
  return 1 if $lc =~ /^(?:just )?(?:observing|listening|waiting|lurking|standing by)(?:\b.*)?[.!?… ]*$/ && length($lc) < 120;
  return 1 if $lc =~ /^\(?(?:quietly|silently|softly|watchfully)\s+(?:listen(?:s|ing)?|observe(?:s|ing)?|lurk(?:s|ing)?|wait(?:s|ing)?)\b.*\)?[.!?… ]*$/ && length($lc) < 160;
  return 1 if $lc =~ /^(?:no response needed|nothing to add|nothing further|no comment)(?:\b.*)?[.!?… ]*$/ && length($lc) < 120;
  return 1 if $lc =~ /\b(?:rafters|tuning|humming|ambient|background)\b/ && length($lc) < 120;
  return 1 if $lc =~ /\battic\b/ && $lc =~ /\b(?:silence|silent|quiet|peace|stillness|holds? its peace)\b/ && length($lc) < 160;
  return 1 if $lc =~ /^(?:\(?\s*)?(?:silence from the attic|the attic holds its peace)(?:\s*\)?)?[.!… ]*$/;
  return 1 if $lc =~ /^\(?\s*(?:pause|silence|quiet|stillness|listening)\s*\)?[.!… ]*$/;
  return 1 if $orig !~ /[A-Za-z0-9]/;

  return 0;
}

sub cleanup_log_preview {
  my ($text) = @_;
  return '' unless defined $text;
  $text =~ s/[\r\n\t]+/ /g;
  $text =~ s/\s{2,}/ /g;
  $text =~ s/^\s+|\s+$//g;
  $text = substr($text, 0, 120) . '...' if length($text) > 120;
  return $text;
}

sub cleanup_change_message {
  my ($label, $before, $after) = @_;
  $before = '' unless defined $before;
  $after  = '' unless defined $after;
  return undef if $before eq $after;
  my $before_preview = cleanup_log_preview($before);
  my $after_preview  = cleanup_log_preview($after);
  return sprintf(
    'Cleanup[%s] len=%d -> %d | before="%s" | after="%s"',
    $label,
    length($before),
    length($after),
    $before_preview,
    $after_preview,
  );
}

sub cleanup_empty_message {
  my ($before, $after) = @_;
  $before = '' unless defined $before;
  $after  = '' unless defined $after;
  my $before_preview = cleanup_log_preview($before);
  my $after_preview  = cleanup_log_preview($after);
  return sprintf(
    'Cleanup collapsed to empty len=%d -> %d | before="%s" | after="%s"',
    length($before),
    length($after),
    $before_preview,
    $after_preview,
  );
}

1;
