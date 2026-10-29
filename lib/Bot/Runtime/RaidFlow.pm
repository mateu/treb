package Bot::Runtime::RaidFlow;

use strict;
use warnings;

use Exporter 'import';
use POE::Kernel ();
use Bot::Runtime::Workbench ();
use Bot::Runtime::Limits qw(runtime_limit now);
use Bot::Runtime::OutputPipeline 'clean_ai_output';

our @EXPORT_OK = qw(do_raid);

sub _terminal_silence_cancelled {
  my ($raider, $result) = @_;
  return 0 unless ref($result) && $result->can('is_cancelled') && $result->is_cancelled;
  return 0 unless $raider && $raider->can('plugin_instances');
  for my $plugin (@{ $raider->plugin_instances || [] }) {
    return 1 if $plugin->can('terminal_silence_requested') && $plugin->terminal_silence_requested;
  }
  return 0;
}

sub _transient_engine_error {
  my ($err) = @_;
  return 0 if $err =~ /tool loop exceeded/i;
  return $err =~ /\b50[0-4]\b|overload|temporarily|unavailable|timed? ?out/i ? 1 : 0;
}

# Primary engine first on every raid; fallbacks only for transient failures within this raid.
sub _raid_with_fallback {
  my ($self, $raider, $input) = @_;
  my $can_switch = $raider->can('switch_engine') && $raider->can('engine_catalog');
  $raider->reset_engine if $can_switch && defined $raider->active_engine_name;
  my @fallbacks = $can_switch ? sort keys %{ $raider->engine_catalog } : ();

  my $result = eval { $raider->raid($input) };
  my $err = $@;
  while ($err && @fallbacks && _transient_engine_error("$err")) {
    my $name = shift @fallbacks;
    (my $short = "$err") =~ s/\s+/ /g;
    $self->info("Engine failed (" . substr($short, 0, 160) . "); switching to $name");
    $raider->switch_engine($name);
    $result = eval { $raider->raid($input) };
    $err = $@;
  }
  die $err if $err;
  return $result;
}

sub _expire_raid {
  my ($self, $reason, $pending) = @_;
  $self->info("Abandoning pending raid: $reason");
  $pending //= $self->_pending_raid;
  Bot::Runtime::Workbench::task_notice($self,$pending,
    'Coding task stopped: ' . $reason . '. ' . ($pending->{coding_last_result}//'No test result recorded.') .
    ' ' . Bot::Runtime::Workbench::finish_task($self,$pending,'deadline'), 1);
  POE::Kernel->delay('_retry_raid'); # cancel the old retry before admitting new work
  $self->_pending_raid(undef);
  $self->_rate_limit_wait(0);
  $self->_processing(0);
  $self->_schedule_pending_buffers;
}

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
  $pending->{started_at} //= now();
  $pending->{expires_at} //= $pending->{started_at} + runtime_limit('REPLY_TTL_SECONDS', 300);
  $pending->{retry_deadline} //= $pending->{started_at} + runtime_limit('RETRY_DEADLINE_SECONDS', 180);
  if (now() >= $pending->{expires_at}
      || (($pending->{retry_count} // 0) && now() >= $pending->{retry_deadline})) {
    _expire_raid($self, 'reply/retry deadline reached');
    return;
  }

  Bot::Runtime::Workbench::admit_task($self);

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
    Bot::Runtime::Workbench::task_notice($self,$pending,'Coding task stopped: runtime unavailable. ' .
      Bot::Runtime::Workbench::finish_task($self,$pending,'runtime_error'), 1);
    $self->_send_to_channel(
      $channel || $self->_default_channel,
      'My brain is still booting. Try again in a moment.',
    );
    $self->_pending_raid(undef);
    $self->_rate_limit_wait(0);
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

  # Nested raid (e.g. a tool calling raid again) deadlocks POE/IO::Async.
  if ($self->can('_raid_in_progress') && $self->_raid_in_progress) {
    $self->error('Refusing nested raid; tool path attempted re-entrant raider call');
    Bot::Runtime::Workbench::task_notice($self,$pending,'Coding task stopped: nested runtime call. ' .
      Bot::Runtime::Workbench::finish_task($self,$pending,'runtime_error'), 1);
    $self->_send_to_channel(
      $channel || $self->_default_channel,
      'My brain hiccuped on a nested thought. Try that again.',
    );
    $self->_pending_raid(undef);
    $self->_rate_limit_wait(0);
    $self->_processing(0);
    $self->_schedule_pending_buffers;
    return;
  }

  if ($self->can('_raid_in_progress')) {
    $self->_raid_in_progress(1);
  }

  my $answer = eval {
    my $result = _raid_with_fallback($self, $raider, $input);
    _terminal_silence_cancelled($raider, $result) ? '__SILENT__' : "$result";
  };
  my $raid_error = $@;
  if ($self->can('_raid_in_progress')) {
    $self->_raid_in_progress(0);
  }

  if (now() >= $pending->{expires_at}) {
    _expire_raid($self, 'reply expired during generation');
    return;
  }

  if ($raid_error && $raid_error =~ /429|rate.limit/i) {
    if (($pending->{retry_count} // 0) >= runtime_limit('RETRY_MAX_ATTEMPTS', 2)) {
      _expire_raid($self, 'rate-limit retry budget exhausted');
      return;
    }
    my $total_wait = $self->_rate_limit_wait;
    my $err_channel = $channel || $self->_default_channel;
    if ($total_wait == 0 && @{$brainfreeze}) {
      my $msg = $brainfreeze->[rand @{$brainfreeze}];
      $self->_send_to_channel($err_channel, $msg);
    }
    my $wait = $total_wait < 70 ? (70 - $total_wait) : 60;
    if (now() + $wait >= $pending->{retry_deadline}
        || now() + $wait >= $pending->{expires_at}) {
      _expire_raid($self, 'next retry would exceed deadline');
      return;
    }
    $pending->{retry_count}++;
    $self->_rate_limit_wait($total_wait + $wait);
    $self->info('Rate limited, total wait: ' . $self->_rate_limit_wait . "s, next retry in ${wait}s");
    POE::Kernel->delay(_retry_raid => $wait);
    return;
  }

  $self->_rate_limit_wait(0);
  $self->_pending_raid(undef);

  if ($raid_error) {
    my $err = "$raid_error";
    $err =~ s/\s+$//;
    $self->error("Raider error: $err");

    my $fallback = $pending->{coding_task}
      ? 'Coding task stopped: ' . ($pending->{coding_stop_reason}//($err =~ /tool loop exceeded/i ? 'tool iteration budget exhausted' : 'runtime error')) . '. ' . ($pending->{coding_last_result}//'No test result recorded.') . ' ' . Bot::Runtime::Workbench::finish_task($self,$pending,
          $pending->{coding_stop_reason} ? 'execution_limit' : $err =~ /tool loop exceeded/i ? 'iteration_limit' : 'runtime_error')
      : $err =~ /tool loop exceeded/i
      ? 'I hit the tool-call limit before I could finish that request. Please try again with a narrower question.'
      : 'My brain is fried. Someone forgot to feed the gerbils that power my CPU.';
    $self->_send_to_channel(
      $channel || $self->_default_channel,
      $fallback,
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

  if ($answer =~ /__SILENT__/) {
    Bot::Runtime::Workbench::task_notice($self,$pending,'Coding task ended without a final report. ' . Bot::Runtime::Workbench::finish_task($self,$pending,'no_report'), 1);
    $self->info("${silent_name} chose to stay silent");
    $self->_processing(0);
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
    Bot::Runtime::Workbench::task_notice($self,$pending,'Coding task ended without a final report. ' . Bot::Runtime::Workbench::finish_task($self,$pending,'no_report'), 1);
    $self->info('Answer empty after cleanup; staying silent');
    $self->_processing(0);
    $self->_schedule_pending_buffers;
    return;
  }

  if ($post_cleanup_guard && $post_cleanup_guard->($self, $channel, $answer)) {
    Bot::Runtime::Workbench::task_notice($self,$pending,'Coding task report suppressed. ' .
      Bot::Runtime::Workbench::finish_task($self,$pending,'no_report'), 1);
    $self->_processing(0);
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
      Bot::Runtime::Workbench::task_notice($self,$pending,'Coding task ended without a usable final report. ' . Bot::Runtime::Workbench::finish_task($self,$pending,'no_report'), 1);
      $self->info('Suppressing non-substantive output');
      $self->_processing(0);
      $self->_schedule_pending_buffers;
      return;
    }
  }

  # Dispatch::send_to_channel already wraps long lines locally. Do not ask the
  # model to rewrite "your last response": history compression can replace that
  # response with an internal state summary, which would then be sent to IRC.

  if (now() >= $pending->{expires_at}) {
    _expire_raid($self, 'reply expired during output cleanup/retry', $pending);
    return;
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

  Bot::Runtime::Workbench::finish_task($self,$pending,'final_report');
  $self->_send_to_channel($channel, $answer);

  if ($has_bert_conversation && $on_bert_reply_consumed) {
    $on_bert_reply_consumed->($self);
  }

  $self->_processing(0);
  $self->_schedule_pending_buffers;
}

1;
