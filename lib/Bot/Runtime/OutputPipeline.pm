package Bot::Runtime::OutputPipeline;

use strict;
use warnings;

use Exporter 'import';

our @EXPORT_OK = qw(clean_ai_output);

sub clean_ai_output {
  my (%args) = @_;
  my $self = $args{self} or die 'clean_ai_output requires self';
  my $text = $args{text} // '';
  my $prefix = $args{log_prefix} // '';

  my $before_strip = $text;
  $text =~ s/<think\b[^>]*>.*?<\/think>\s*//gsi;
  $text =~ s/<thinking\b[^>]*>.*?<\/thinking>\s*//gsi;
  $text =~ s/^\s*(?:Thought|Reasoning|Chain[ -]?of[ -]?Thought|Internal Reasoning)\s*:\s*.*?(?=^\S|\z)//gims;
  $self->_log_cleanup_change($prefix . 'strip_reasoning', $before_strip, $text);

  my $before_markup = $text;
  $text =~ s/^<\s*\@?\s*(\w+)\s*>:?\s*/$1: /mg;
  $text =~ s/<\s*\@?\s*(\w+)\s*>/$1/g;
  $text =~ s/<\/?\w+>//g;
  $text =~ s/^\*?\s*(save_note|recall_notes|update_note|delete_note|recall_history|stay_silent|set_alarm|whois|send_private_message)\b[^\n]*\n?//mg;
  $text =~ s/^\s*end_turn:\s*\n?//img;
  $text =~ s/^\s*System\s*\(untrusted\)\s*:\s*[^\n]*\n?//img;
  $text =~ s/^\s*system\s*:\s*(?:Stop further tool use until new messages arrive\.|You see messages from burt_bot in \#mateu-test\. Do not reply to this system message\.|You will now receive messages\. Stay quiet unless directly addressed\.)\s*\n?//img;
  $text =~ s/^\s*I stayed silent\b[^\n]*\n?//img;
  $text =~ s/^\s*I am staying silent\b[^\n]*\n?//img;
  $text =~ s/^\s*\(No response\s*-\s*staying silent\)\s*\n?//img;
  $text =~ s/^\s*\[No response needed\s*-\s*I chose silence\]\s*\n?//img;
  $text =~ s/^\s*[^\n]*doesn't require a response from me\.[^\n]*\n?//img;
  $text =~ s/^\s*[^\n]*we don't banter unprompted\.[^\n]*\n?//img;
  $text =~ s/^\s*[^\n]*I'll continue lurking quietly\.?\s*\n?//img;
  $text =~ s/^\s+//;
  $text =~ s/\s+$//;
  $self->_log_cleanup_change($prefix . 'strip_markup', $before_markup, $text);

  my $before_normalize = $text;
  $text = $self->_clean_text_for_irc($text) if defined $text;
  $self->_log_cleanup_change($prefix . 'normalize_text', $before_normalize, $text);

  return $text;
}

1;
