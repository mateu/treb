package Bot::Runtime::RaidFlow;

use strict;
use warnings;

use Exporter 'import';

our @EXPORT_OK = qw(do_raid);

sub do_raid {
  my (%args) = @_;

  my $self = $args{self} or die 'do_raid requires self';
  my $max_line = $args{max_line} // 400;
  my $silent_name = $args{silent_name} // 'Bot';
  my $brainfreeze = $args{brainfreeze} || [];
  my $allow_bert_non_substantive = $args{allow_bert_non_substantive} ? 1 : 0;
  my $post_cleanup_guard = $args{post_cleanup_guard};
  my $on_bert_reply_consumed = $args{on_bert_reply_consumed};

  my $pending = $self->_pending_raid;
  return unless $pending;

  my $input    = $pending->{input};
  my $channel  = $pending->{channel};
  my $messages = $pending->{messages};

  my $answer = eval {
    my $result = $self->_raider->raid($input);
    "$result";
  };

  if ($@ && $@ =~ /429|rate.limit/i) {
    my $total_wait = $self->_rate_limit_wait;
    my $err_channel = $self->_default_channel;
    if ($total_wait == 0 && @{$brainfreeze}) {
      my $msg = $brainfreeze->[rand @{$brainfreeze}];
      $self->_send_to_channel($err_channel, $msg);
    }
    my $wait = $total_wait < 70 ? (70 - $total_wait) : 60;
    $self->_rate_limit_wait($total_wait + $wait);
    $self->info('Rate limited, total wait: ' . $self->_rate_limit_wait . "s, next retry in ${wait}s");
    if ($total_wait > 0 && int($total_wait / 180) != int($self->_rate_limit_wait / 180) && @{$brainfreeze}) {
      my $msg = $brainfreeze->[rand @{$brainfreeze}];
      $self->_send_to_channel($err_channel, $msg);
    }
    POE::Kernel->delay(_retry_raid => $wait);
    return;
  }

  $self->_rate_limit_wait(0);
  $self->_pending_raid(undef);

  if ($@) {
    $self->error("Raider error: $@");
    $self->_send_to_channel(
      $self->_default_channel,
      'My brain is fried. Someone forgot to feed the gerbils that power my CPU.',
    );
    $self->_processing(0);
    $self->_schedule_pending_buffers;
    return;
  }

  eval {
    my $engine = $self->_raider->active_engine;
    if ($engine->has_rate_limit) {
      my $rl = $engine->rate_limit;
      $self->info(
        sprintf 'Rate limit: %s requests remaining, %s tokens remaining',
          $rl->requests_remaining // '?', $rl->tokens_remaining // '?'
      );
    }
  };

  $self->_processing(0);

  if ($answer =~ /__SILENT__/) {
    $self->info("${silent_name} chose to stay silent");
    $self->_schedule_pending_buffers;
    return;
  }

  my $raw_answer = $answer;
  my $answer_before_strip = $answer;
  $answer =~ s/<think\b[^>]*>.*?<\/think>\s*//gsi;
  $answer =~ s/<thinking\b[^>]*>.*?<\/thinking>\s*//gsi;
  $answer =~ s/^\s*(?:Thought|Reasoning|Chain[ -]?of[ -]?Thought|Internal Reasoning)\s*:\s*.*?(?=^\S|\z)//gims;
  $self->_log_cleanup_change('strip_reasoning', $answer_before_strip, $answer);

  my $answer_before_markup = $answer;
  $answer =~ s/^<\s*\@?\s*(\w+)\s*>:?\s*/$1: /mg;
  $answer =~ s/<\s*\@?\s*(\w+)\s*>/$1/g;
  $answer =~ s/<\/?\w+>//g;
  $answer =~ s/^\*?\s*(save_note|recall_notes|update_note|delete_note|recall_history|stay_silent|set_alarm|whois|send_private_message)\b[^\n]*\n?//mg;
  $answer =~ s/^\s+//;
  $answer =~ s/\s+$//;
  $self->_log_cleanup_change('strip_markup', $answer_before_markup, $answer);

  my $answer_before_normalize = $answer;
  $answer = $self->_clean_text_for_irc($answer) if defined $answer;
  $self->_log_cleanup_change('normalize_text', $answer_before_normalize, $answer);

  if ($answer !~ /\S/) {
    $self->_log_cleanup_empty($raw_answer, $answer);
    $self->info('Answer empty after cleanup; staying silent');
    $self->_schedule_pending_buffers;
    return;
  }

  if ($post_cleanup_guard && $post_cleanup_guard->($self, $channel, $answer)) {
    return;
  }

  my $has_bert_conversation = 0;
  my $has_warm_human_conversation = 0;
  for my $m (@{$messages}) {
    if (($m->{source_kind} // '') eq 'bert_conversation' && $m->{nick} && $self->_is_filtered_bot_nick($m->{nick})) {
      $has_bert_conversation = 1;
    }
    if (($m->{source_kind} // '') eq 'conversation' && ($m->{warm_human} // 0)) {
      $has_warm_human_conversation = 1;
    }
  }

  if ($self->_is_non_substantive_output($answer)) {
    if ($has_warm_human_conversation) {
      $self->info('Retrying non-substantive output for warm human conversation lane');
      my $retry = eval {
        my $prompt = $input . "\n\nA human directly addressed you. Answer that human directly and promptly now. This overrides your default quietness. Be brief, useful, and natural. Answer the actual question first. Do not use stage directions, faux silence, ambient observation, withdrawn asides, roleplay garnish, or any text about staying quiet. If silence would be appropriate, output nothing instead of narrating silence.";
        my $result = $self->_raider->raid($prompt);
        "$result";
      };
      if (!$@ && defined $retry) {
        my $retry_raw = $retry;
        my $retry_before_strip = $retry;
        $retry =~ s/<think\b[^>]*>.*?<\/think>\s*//gsi;
        $retry =~ s/<thinking\b[^>]*>.*?<\/thinking>\s*//gsi;
        $retry =~ s/^\s*(?:Thought|Reasoning|Chain[ -]?of[ -]?Thought|Internal Reasoning)\s*:\s*.*?(?=^\S|\z)//gims;
        $self->_log_cleanup_change('warm_retry_strip_reasoning', $retry_before_strip, $retry);
        my $retry_before_markup = $retry;
        $retry =~ s/^<\s*\@?\s*(\w+)\s*>:?\s*/$1: /mg;
        $retry =~ s/<\s*\@?\s*(\w+)\s*>/$1/g;
        $retry =~ s/<\/?\w+>//g;
        $retry =~ s/^\*?\s*(save_note|recall_notes|update_note|delete_note|recall_history|stay_silent|set_alarm|whois|send_private_message)\b[^\n]*\n?//mg;
        $retry =~ s/^\s+//;
        $retry =~ s/\s+$//;
        $self->_log_cleanup_change('warm_retry_strip_markup', $retry_before_markup, $retry);
        my $retry_before_normalize = $retry;
        $retry = $self->_clean_text_for_irc($retry) if defined $retry;
        $self->_log_cleanup_change('warm_retry_normalize_text', $retry_before_normalize, $retry);
        if ($retry =~ /\S/ && !$self->_is_non_substantive_output($retry)) {
          $answer = $retry;
          $raw_answer = $retry_raw;
        }
      }
    }
  }

  if ($self->_is_non_substantive_output($answer)) {
    my $non_substantive_allow_pct = $self->_persona_trait('non_substantive_allow_pct');
    if ($allow_bert_non_substantive && $has_bert_conversation) {
      $self->info('Allowing borderline non-substantive output for bert_conversation lane');
    } elsif ($non_substantive_allow_pct > 0 && int(rand(100)) < $non_substantive_allow_pct) {
      $self->info("Allowing non-substantive output due to non_substantive_allow_pct=$non_substantive_allow_pct");
    } else {
      $self->info('Suppressing non-substantive output');
      $self->_schedule_pending_buffers;
      return;
    }
  }

  my @lines = grep { length } map { s/^\s+//r =~ s/\s+$//r } split(/\n/, $answer);
  my $too_long = grep { length($_) > $max_line } @lines;
  if ($too_long) {
    $self->info('Response too long, asking to shorten');
    $answer = eval {
      my $retry = $self->_raider->raid(
        "Your last response had lines over $max_line characters. "
        . "Rewrite it shorter. Every line must be under $max_line chars."
      );
      "$retry";
    } || $answer;
  }

  my $answer_is_empty_artifact = ($answer =~ /^\(Empty response:/s) ? 1 : 0;
  my $answer_is_non_substantive = $self->_is_non_substantive_output($answer) ? 1 : 0;
  my $store_system_rows = $self->_store_system_rows_enabled;
  my $store_non_substantive_rows = $self->_store_non_substantive_rows_enabled;
  my $store_empty_response_rows = $self->_store_empty_response_rows_enabled;

  for my $m (@{$messages}) {
    if ($m->{nick} eq 'system' && !$store_system_rows) {
      $self->info('Skipping storage for system row');
      next;
    }
    if ($answer_is_empty_artifact && !$store_empty_response_rows) {
      $self->info('Skipping storage for empty-response artifact');
      next;
    }
    if ($answer_is_non_substantive && !$store_non_substantive_rows) {
      $self->info('Skipping storage for non-substantive response');
      next;
    }
    $self->memory->store_conversation(
      nick => $m->{nick}, message => $m->{msg},
      response => $answer, channel => $m->{channel},
    );
  }

  $self->_send_to_channel($channel, $answer);

  if ($has_bert_conversation && $on_bert_reply_consumed) {
    $on_bert_reply_consumed->($self);
  }

  $self->_schedule_pending_buffers;
}

1;
