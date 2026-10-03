use strict;
use warnings;
use Test::More;

use lib 'lib';

# Stub POE::Kernel so the rate-limit retry path can be exercised without
# requiring the full POE distribution.
BEGIN { $INC{'POE/Kernel.pm'} = 1 }
{ package POE::Kernel; our @delayed; sub delay { push @POE::Kernel::delayed, [ @_[1..$#_] ]; 1 } }

use Bot::Runtime::RaidFlow qw(do_raid);

{
  package Local::RaidFlowMemory;

  sub new { bless { rows => [] }, shift }

  sub store_conversation {
    my ($self, %row) = @_;
    push @{$self->{rows}}, { %row };
    return 1;
  }
}

{
  package Local::RaidFlowEngine;

  sub new { bless { has_rate_limit => 0 }, shift }
  sub has_rate_limit { return $_[0]->{has_rate_limit} }
}

{
  package Local::RaidFlowFuture;

  sub new { bless {}, shift }
  sub get { return 1 }
}

{
  package Local::RaidFlowRaider;

  sub new {
    my ($class, %args) = @_;
    return bless {
      replies => $args{replies} || [],
      engine  => Local::RaidFlowEngine->new,
      plugins => $args{plugins} || [],
    }, $class;
  }

  sub raid {
    my ($self, $prompt) = @_;
    my $next = shift @{$self->{replies}};
    die "No queued raid response for prompt: $prompt" unless defined $next;
    die $next->{die} if ref($next) eq 'HASH' && exists $next->{die};
    return $next;
  }

  sub active_engine { return $_[0]->{engine} }
  sub plugin_instances { return $_[0]->{plugins} }
}

{
  package Local::RaidFlowBot;

  sub new {
    my ($class, %args) = @_;
    my $raider = exists $args{raider}
      ? $args{raider}
      : Local::RaidFlowRaider->new(replies => $args{replies} || []);
    return bless {
      _pending_raid                 => $args{pending},
      _rate_limit_wait              => 0,
      _processing                   => 1,
      _persona                      => { non_substantive_allow_pct => 0 },
      _store_system_rows_enabled    => 1,
      _store_non_substantive_rows_enabled => 1,
      _store_empty_response_rows_enabled   => 1,
      _bert_reply_turn_count        => 0,
      _bert_reply_lock              => 0,
      sent                          => [],
      info                          => [],
      errors                        => [],
      scheduled                     => 0,
      cleanup_log                   => [],
      memory                        => Local::RaidFlowMemory->new,
      raider                        => $raider,
      setup_calls                   => 0,
      setup_fail                    => $args{setup_fail},
      setup_replies                 => $args{setup_replies} || [],
    }, $class;
  }

  sub _pending_raid {
    my ($self, $value) = @_;
    $self->{_pending_raid} = $value if @_ > 1;
    return $self->{_pending_raid};
  }

  sub _rate_limit_wait {
    my ($self, $value) = @_;
    $self->{_rate_limit_wait} = $value if @_ > 1;
    return $self->{_rate_limit_wait};
  }

  sub _processing {
    my ($self, $value) = @_;
    $self->{_processing} = $value if @_ > 1;
    return $self->{_processing};
  }

  sub _raid_in_progress {
    my ($self, $value) = @_;
    $self->{_raid_in_progress} = $value if @_ > 1;
    return $self->{_raid_in_progress} ? 1 : 0;
  }

  sub _raider {
    my ($self, $value) = @_;
    $self->{raider} = $value if @_ > 1;
    return $self->{raider};
  }

  sub _setup_raider {
    my ($self) = @_;
    $self->{setup_calls}++;
    die $self->{setup_fail} if defined $self->{setup_fail};
    if (!$self->{raider}) {
      $self->{raider} = Local::RaidFlowRaider->new(replies => $self->{setup_replies});
    }
    return Local::RaidFlowFuture->new;
  }

  sub _default_channel { return '#ai' }

  sub _send_to_channel {
    my ($self, $channel, $msg) = @_;
    push @{$self->{sent}}, { channel => $channel, msg => $msg };
    return 1;
  }

  sub _schedule_pending_buffers {
    my ($self) = @_;
    $self->{scheduled}++;
    return 1;
  }

  sub info {
    my ($self, $msg) = @_;
    push @{$self->{info}}, $msg;
    return 1;
  }

  sub error {
    my ($self, $msg) = @_;
    push @{$self->{errors}}, $msg;
    return 1;
  }

  sub _clean_text_for_irc { return $_[1] }

  sub _log_cleanup_change {
    my ($self, $label, $before, $after) = @_;
    push @{$self->{cleanup_log}}, [$label, $before, $after];
    return 1;
  }

  sub _log_cleanup_empty {
    my ($self, $before, $after) = @_;
    push @{$self->{cleanup_log}}, ['empty', $before, $after];
    return 1;
  }

  sub _is_non_substantive_output {
    my ($self, $text) = @_;
    return 0 unless defined $text;
    return $text =~ /^\s*(?:\.\.\.|\(.*?\))\s*$/ ? 1 : 0;
  }

  sub _is_filtered_bot_nick {
    my ($self, $nick) = @_;
    return (($nick // '') eq 'burt_bot') ? 1 : 0;
  }

  sub _persona_trait {
    my ($self, $key) = @_;
    return $self->{_persona}{$key};
  }

  sub _store_system_rows_enabled { return $_[0]->{_store_system_rows_enabled} }
  sub _store_non_substantive_rows_enabled { return $_[0]->{_store_non_substantive_rows_enabled} }
  sub _store_empty_response_rows_enabled { return $_[0]->{_store_empty_response_rows_enabled} }

  sub memory { return $_[0]->{memory} }

  sub _bert_reply_turn_count {
    my ($self, $value) = @_;
    $self->{_bert_reply_turn_count} = $value if @_ > 1;
    return $self->{_bert_reply_turn_count};
  }

  sub _bert_reply_lock {
    my ($self, $value) = @_;
    $self->{_bert_reply_lock} = $value if @_ > 1;
    return $self->{_bert_reply_lock};
  }
}

{
  package Local::TerminalSilenceResult;
  use overload '""' => sub { 'Cancelled' }, fallback => 1;
  sub new { bless {}, shift }
  sub is_cancelled { 1 }
}

{
  package Local::TerminalSilencePlugin;
  sub new { bless {}, shift }
  sub terminal_silence_requested { 1 }
}

{
  my $raider = Local::RaidFlowRaider->new(
    replies => [Local::TerminalSilenceResult->new],
    plugins => [Local::TerminalSilencePlugin->new],
  );
  my $bot = Local::RaidFlowBot->new(
    pending => {
      input => '<system> a bot joined',
      channel => '#mateu-test',
      messages => [
        { nick => 'system', channel => '#mateu-test', msg => 'joined', source_kind => 'system' },
      ],
    },
    raider => $raider,
  );

  do_raid(self => $bot, max_line => 400, silent_name => 'Treb');

  is(scalar @{$bot->{sent}}, 0, 'terminal stay_silent cancellation emits no IRC fallback');
  is($bot->_pending_raid, undef, 'terminal stay_silent clears pending raid');
  is($bot->_processing, 0, 'terminal stay_silent resets processing');
  is($bot->{scheduled}, 1, 'terminal stay_silent schedules the next pending buffer');
  like(join("\n", @{$bot->{info}}), qr/Treb chose to stay silent/, 'terminal stay_silent is logged as silence');
}

{
  my $bot = Local::RaidFlowBot->new(
    pending => {
      input => 'prompt',
      channel => '#ai',
      messages => [
        { nick => 'burt_bot', channel => '#ai', msg => 'ping', source_kind => 'bert_conversation' },
      ],
    },
    replies => ['hello'],
  );

  my $consumed = 0;
  do_raid(
    self => $bot,
    max_line => 400,
    brainfreeze => ['*brainfreeze*'],
    silent_name => 'Bert',
    allow_bert_non_substantive => 1,
    on_bert_reply_consumed => sub { $consumed++ },
  );

  is($bot->{sent}[0]{msg}, 'hello', 'sends cleaned answer');
  is($consumed, 1, 'bert consumption callback triggered');
  is($bot->{scheduled}, 1, 'pending buffers scheduled after send');
  is($bot->_pending_raid, undef, 'pending raid cleared after completion');
  is($bot->{memory}{rows}[0]{response}, 'hello', 'conversation row stored');
}

{
  my $bot = Local::RaidFlowBot->new(
    pending => {
      input => 'prompt',
      channel => '#ai',
      messages => [
        { nick => 'mateu', channel => '#ai', msg => 'question', source_kind => 'conversation', warm_human => 1 },
      ],
    },
    replies => ['...', 'actual answer'],
  );

  do_raid(
    self => $bot,
    max_line => 400,
    brainfreeze => ['*brainfreeze*'],
    silent_name => 'Burt',
    allow_bert_non_substantive => 0,
  );

  is($bot->{sent}[0]{msg}, 'actual answer', 'warm-human non-substantive reply retries and sends substantive output');
}

{
  my $bot = Local::RaidFlowBot->new(
    pending => {
      input => 'treb_bot: Find some theaters in Marseille.',
      channel => '#ai',
      messages => [
        { nick => 'mateu', channel => '#ai', msg => 'treb_bot: Find some theaters in Marseille.', source_kind => 'conversation', warm_human => 1 },
      ],
    },
    replies => ['', 'mateu: I found Théâtre du Gymnase, Théâtre Toursky, and Théâtre de l\'Odéon in Marseille.'],
  );

  do_raid(
    self => $bot,
    max_line => 400,
    brainfreeze => ['*brainfreeze*'],
    silent_name => 'treb_bot',
    allow_bert_non_substantive => 0,
  );

  is(
    $bot->{sent}[0]{msg},
    'mateu: I found Théâtre du Gymnase, Théâtre Toursky, and Théâtre de l\'Odéon in Marseille.',
    'warm-human empty reply retries and sends substantive output',
  );
  like(
    join("\n", @{$bot->{info}}),
    qr/Retrying empty output for warm human conversation lane/,
    'empty warm-human retry is logged',
  );
}

{
  my $bot = Local::RaidFlowBot->new(
    pending => {
      input => 'prompt',
      channel => '#ai',
      messages => [
        { nick => 'mateu', channel => '#ai', msg => 'question', source_kind => 'conversation' },
      ],
    },
    replies => ['(shrug)'],
  );

  my $guard_calls = 0;
  do_raid(
    self => $bot,
    max_line => 400,
    brainfreeze => ['*brainfreeze*'],
    post_cleanup_guard => sub {
      my ($self, $channel, $answer) = @_;
      $guard_calls++;
      $self->_schedule_pending_buffers;
      return 1;
    },
  );

  is($guard_calls, 1, 'post-cleanup guard invoked once');
  is(scalar @{$bot->{sent}}, 0, 'guarded flow does not send message');
  is($bot->{scheduled}, 1, 'guard is responsible for scheduling pending buffers');
}

{
  my $bot = Local::RaidFlowBot->new(
    pending => {
      input => 'prompt',
      channel => '#ai',
      messages => [
        { nick => 'burt_bot', channel => '#ai', msg => 'ping', source_kind => 'bert_conversation' },
      ],
    },
    replies => ['...'],
  );

  do_raid(
    self => $bot,
    max_line => 400,
    brainfreeze => ['*brainfreeze*'],
    allow_bert_non_substantive => 1,
  );

  is($bot->{sent}[0]{msg}, '...', 'bert lane allows borderline non-substantive output');
  like(join("\n", @{$bot->{info}}), qr/Allowing borderline non-substantive output/, 'bert lane allowance logged');
}

{
  my $bot = Local::RaidFlowBot->new(
    pending => {
      input => 'prompt',
      channel => '#ai',
      messages => [
        { nick => 'mateu', channel => '#ai', msg => 'question', source_kind => 'conversation' },
      ],
    },
    raider => undef,
    setup_replies => ['hello after setup'],
  );

  do_raid(
    self => $bot,
    max_line => 400,
    brainfreeze => ['*brainfreeze*'],
  );

  is($bot->{setup_calls}, 1, 'missing raider triggers setup retry');
  is($bot->{sent}[0]{msg}, 'hello after setup', 'setup retry provides usable raider response');
  is($bot->_pending_raid, undef, 'pending raid cleared after setup retry success');
}

{
  my $bot = Local::RaidFlowBot->new(
    pending => {
      input => 'prompt',
      channel => '#ai',
      messages => [
        { nick => 'mateu', channel => '#ai', msg => 'question', source_kind => 'conversation' },
      ],
    },
    raider => undef,
    setup_fail => 'boom',
  );

  do_raid(
    self => $bot,
    max_line => 400,
    brainfreeze => ['*brainfreeze*'],
  );

  is($bot->{setup_calls}, 1, 'setup retry attempted when missing raider has no instance');
  is($bot->{sent}[0]{msg}, 'My brain is still booting. Try again in a moment.', 'fallback reply sent when raider remains unavailable');
  is($bot->_pending_raid, undef, 'pending raid cleared when raider is unavailable');
  is($bot->_processing, 0, 'processing flag reset when raider is unavailable');
  is($bot->{scheduled}, 1, 'pending buffers scheduled after missing raider fallback');
  like(join("\n", @{$bot->{errors}}), qr/Raider setup retry failed: boom/, 'setup retry failure is logged');
}

{
  my $bot = Local::RaidFlowBot->new(
    pending => {
      input => 'treb_bot: Tell me about a castle in Marseille and who the architect was.',
      channel => '#mateu-test',
      messages => [
        { nick => 'mateu', channel => '#mateu-test', msg => 'treb_bot: Tell me about a castle in Marseille and who the architect was.', source_kind => 'conversation', warm_human => 1 },
      ],
    },
    replies => [{ die => 'Raider tool loop exceeded 13 iterations' }],
  );

  do_raid(
    self        => $bot,
    max_line    => 400,
    brainfreeze => ['*brainfreeze*'],
  );

  like(
    $bot->{sent}[0]{msg},
    qr/hit the tool-call limit/i,
    'tool-loop failure gets a truthful bounded fallback',
  );
  is($bot->{sent}[0]{channel}, '#mateu-test', 'tool-loop fallback stays in the triggering channel');
  unlike($bot->{sent}[0]{msg}, qr/castle|architect/i, 'tool-loop fallback does not invent request-specific facts');
  like(
    join("\n", @{$bot->{errors}}),
    qr/Raider error: Raider tool loop exceeded 13 iterations/,
    'tool-loop failure is still logged',
  );
}

{
  @POE::Kernel::delayed = ();

  my $bot = Local::RaidFlowBot->new(
    pending => {
      input    => 'prompt',
      channel  => '#mateu-test',
      messages => [
        { nick => 'mateu', channel => '#mateu-test', msg => 'hello', source_kind => 'conversation' },
      ],
    },
    replies => [{ die => '429 Too Many Requests: rate limit exceeded' }],
  );

  do_raid(
    self        => $bot,
    max_line    => 400,
    brainfreeze => ['*brainfreeze*'],
  );

  isnt($bot->_pending_raid, undef, '429: pending raid is retained');
  ok($bot->_rate_limit_wait > 0, '429: rate_limit_wait is increased');
  is($bot->{sent}[0]{msg}, '*brainfreeze*', '429: brainfreeze message sent on first rate-limit hit');
  is($bot->{sent}[0]{channel}, '#mateu-test', '429: notice stays in the triggering channel');
  is(scalar @POE::Kernel::delayed, 1, '429: exactly one retry delay is scheduled');
  is($POE::Kernel::delayed[0][0], '_retry_raid', '429: scheduled event is _retry_raid');
}

{
  my $bot = Local::RaidFlowBot->new(
    pending => {
      input    => 'nested',
      channel  => '#ai',
      messages => [
        { nick => 'mateu', channel => '#ai', msg => 'hello', source_kind => 'conversation', warm_human => 1 },
      ],
    },
    replies => ['should-not-run'],
  );
  $bot->_raid_in_progress(1);

  do_raid(
    self        => $bot,
    max_line    => 400,
    brainfreeze => ['*brainfreeze*'],
  );

  like($bot->{sent}[0]{msg}, qr/nested thought/i, 'nested raid is refused with a recovery message');
  like(join("\n", @{$bot->{errors}}), qr/Refusing nested raid/, 'nested raid refusal is logged');
  is($bot->_pending_raid, undef, 'pending raid cleared on nested refusal');
  is($bot->_processing, 0, 'processing reset on nested refusal');
  is($bot->{scheduled}, 1, 'buffers rescheduled after nested refusal');
}

done_testing;
