package Bot::Runtime::OutputPipeline;

use strict;
use warnings;

use Exporter 'import';

our @EXPORT_OK = qw(clean_ai_output);

sub clean_ai_output {
  my (%args) = @_;
  my $self = $args{self};
  my $text = $args{text};
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
  $text =~ s/^\s+//;
  $text =~ s/\s+$//;
  $self->_log_cleanup_change($prefix . 'strip_markup', $before_markup, $text);

  my $before_normalize = $text;
  $text = $self->_clean_text_for_irc($text) if defined $text;
  $self->_log_cleanup_change($prefix . 'normalize_text', $before_normalize, $text);

  return $text;
}

1;
