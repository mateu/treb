package Bot::Runtime::RaidFlow;

use strict;
use warnings;

use Exporter 'import';
use POE::Kernel ();
use Bot::Runtime::OutputPipeline 'clean_ai_output';

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

  my $raider = $self->_raider;
  if (!$raider && $self->can('_setup_raider')) {
    $self->info('Raider missing; attempting runtime setup');
    my $setup_ok = eval {
      my $setup = $self->_setup_raider;
      $setup->get if defined $setup && ref($setup) && $setup->can('get');
      1;
    };
    if (!$setup_ok) {
      my $err = "$@";
      $err =~ s/\s+$//;
      $self->error("Raider setup retry failed: $err");
    }
    $raider = $self->_raider;
  }

  unless ($raider) {
    $self->error('Raider unavailable: no active raider instance');
    $self->_send_to_channel(
      $channel || $self->_default_channel,
      'My brain is still booting. Try again in a moment.',
    );
    $self->_pending_raid(undef);
    $self->_processing(0);
    $self->_schedule_pending_buffers;
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

  my $answer = eval {
    my $result = $raider->raid($input);
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
    my $err = "$@";
    $err =~ s/\s+$//;
    $self->error("Raider error: $err");

    if ($has_warm_human_conversation && $err =~ /tool loop exceeded/i) {
      my $fallback = 'I dug through the available tool results but could not find a reliable match for that request before the tool loop gave up. I would not trust a specific castle/architect answer from this pass.';
      $self->_send_to_channel(
        $channel || $self->_default_channel,
        $fallback,
      );
      $self->_processing(0);
      $self->_schedule_pending_buffers;
      return;
    }

    $self->_send_to_channel(
      $self->_default_channel,
      'My brain is fried. Someone forgot to feed the gerbils that power my CPU.',
    );
    $self->_processing(0);
    $self->_schedule_pending_buffers;
    return;
  }

  eval {
    my $engine = $raider->active_engine;
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
  $answer = clean_ai_output(self => $self, text => $answer);

  if ($answer !~ /\S/ && $has_warm_human_conversation) {
    $self->info('Retrying empty output for warm human conversation lane');
    my $retry = eval {
      my $prompt = $input . "\n\nA human directly addressed you and your previous output was empty. Answer that human directly and promptly now. This overrides your default quietness. Be brief, useful, and natural. Answer the actual question first. Use any tool results you already have. Do not use stage directions, faux silence, ambient observation, withdrawn asides, roleplay garnish, or any text about staying quiet. Output plain IRC-ready text only.";
      my $result = $raider->raid($prompt);
      "$result";
    };
    if (!$@ && defined $retry) {
      my $retry_raw = $retry;
      $retry = clean_ai_output(self => $self, text => $retry, log_prefix => 'empty_retry_');
      if ($retry =~ /\S/) {
        $answer = $retry;
        $raw_answer = $retry_raw;
      }
    }
  }

  if ($answer !~ /\S/) {
    $self->_log_cleanup_empty($raw_answer, $answer);
    $self->info('Answer empty after cleanup; staying silent');
    $self->_schedule_pending_buffers;
    return;
  }

  if ($post_cleanup_guard && $post_cleanup_guard->($self, $channel, $answer)) {
    return;
  }

  if ($self->_is_non_substantive_output($answer)) {
    if ($has_warm_human_conversation) {
      $self->info('Retrying non-substantive output for warm human conversation lane');
      my $retry = eval {
        my $prompt = $input . "\n\nA human directly addressed you. Answer that human directly and promptly now. This overrides your default quietness. Be brief, useful, and natural. Answer the actual question first. Do not use stage directions, faux silence, ambient observation, withdrawn asides, roleplay garnish, or any text about staying quiet. If silence would be appropriate, output nothing instead of narrating silence.";
        my $result = $raider->raid($prompt);
        "$result";
      };
      if (!$@ && defined $retry) {
        my $retry_raw = $retry;
        $retry = clean_ai_output(self => $self, text => $retry, log_prefix => 'warm_retry_');
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
      my $retry = $raider->raid(
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
