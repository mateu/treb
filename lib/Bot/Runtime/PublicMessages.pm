package Bot::Runtime::PublicMessages;

use strict;
use warnings;

use Exporter 'import';
our @EXPORT_OK = qw(handle_standard_irc_public_event handle_ambient_irc_public_event);

use Bot::Runtime::UtilityCommands ();

sub _resolve_direct_address {
  my (%args) = @_;
  my $mode = $args{mode} // 'mention';
  my $mention = $args{mention} ? 1 : 0;
  my $addressed_to_self = $args{addressed_to_self} ? 1 : 0;
  return $mention if $mode eq 'mention';
  return $addressed_to_self if $mode eq 'addressed_to_self';
  die "_resolve_direct_address requires mode to be 'mention' or 'addressed_to_self' (got '$mode')";
}

sub handle_standard_irc_public_event {
  my (%args) = @_;

  my $self = $args{self} or die 'handle_standard_irc_public_event requires self';
  my $nickstr = $args{nickstr} // '';
  my $channels = $args{channels};
  my $msg = defined $args{msg} ? $args{msg} : '';

  my $utility_style = $args{utility_style} // 'strict';
  my $utility_notes_mode = $args{utility_notes_mode} // 'direct_only';
  my $bot_direct_mode = $args{bot_direct_mode} // 'mention';
  my $human_direct_mode = $args{human_direct_mode} // 'addressed_to_self';
  my $warm_limit  = $args{warm_limit};
  my $warm_window = $args{warm_window};
  if (defined $warm_limit) {
    die "handle_standard_irc_public_event requires warm_limit to be a positive integer (got: $warm_limit)"
      unless $warm_limit =~ /\A[1-9]\d*\z/;
    $warm_limit = int($warm_limit);
  } else {
    $warm_limit = 3;
  }
  if (defined $warm_window) {
    die "handle_standard_irc_public_event requires warm_window to be a positive integer (got: $warm_window)"
      unless $warm_window =~ /\A[1-9]\d*\z/;
    $warm_window = int($warm_window);
  } else {
    $warm_window = 300;
  }

  my ($nick) = split /!/, $nickstr;
  return 0 if defined($nick) && $nick eq $self->get_nickname;

  my $channel = ref $channels ? $channels->[0] : $channels;
  $self->info("$channel <$nick> $msg");
  $self->_last_activity(time());

  if ($self->_is_human_nick($nick) && $self->_bert_reply_turn_count) {
    $self->_bert_reply_turn_count(0);
    $self->info("Reset bert conversational turn count by human nick=$nick");
  }

  if (Bot::Runtime::UtilityCommands::handle_public_utility_command(
    self       => $self,
    channel    => $channel,
    msg        => $msg,
    style      => $utility_style,
    notes_mode => $utility_notes_mode,
  )) {
    return 1;
  }

  my $speaker_is_filtered_bot = $self->_is_filtered_bot_nick($nick);
  my $bot_nick = $self->get_nickname;
  my $nick_re = quotemeta($bot_nick);
  my $direct_mention = ($msg =~ /(?:^|\W)$nick_re(?:\W|$)/i) ? 1 : 0;
  my $direct_addressee = $self->_is_public_message_addressed_to_self($msg) ? 1 : 0;

  my $bot_direct_address = _resolve_direct_address(
    mode => $bot_direct_mode,
    mention => ($direct_mention || $direct_addressee) ? 1 : 0,
    addressed_to_self => $direct_addressee,
  );
  my $human_direct_address = _resolve_direct_address(
    mode => $human_direct_mode,
    mention => $direct_mention,
    addressed_to_self => $direct_addressee,
  );

  if ($speaker_is_filtered_bot) {
    return 0 unless $bot_direct_address;

    my $bot_reply_max_turns = $self->_persona_trait('bot_reply_max_turns');
    if ($bot_reply_max_turns > 0 && $self->_bert_reply_turn_count >= $bot_reply_max_turns) {
      $self->info("Suppressing Bert conversational message: turn cap reached bot_reply_max_turns=$bot_reply_max_turns");
      return 1;
    }

    my $bot_reply_pct = $self->_persona_trait('bot_reply_pct');
    if ($bot_reply_pct < 100 && int(rand(100)) >= $bot_reply_pct) {
      $self->info("Suppressing Bert conversational message: probability gate bot_reply_pct=$bot_reply_pct");
      return 1;
    }

    $self->info('Allowing Bert conversational message (direct address, unlocked)');
    $self->_buffer_message($channel, $nick, $msg, { source_kind => 'bert_conversation' });
    return 1;
  }

  return 0 unless $human_direct_address;

  if (!$self->_human_warm_reply_expires_at || time() > $self->_human_warm_reply_expires_at) {
    $self->_human_warm_reply_count(0);
  }

  my $warm_human = ($self->_human_warm_reply_count < $warm_limit) ? 1 : 0;
  $self->_human_warm_reply_count($self->_human_warm_reply_count + 1);
  $self->_human_warm_reply_expires_at(time() + $warm_window);

  $self->_buffer_message($channel, $nick, $msg, {
    source_kind => 'conversation',
    warm_human  => $warm_human,
  });
  return 1;
}

# Burt's conversational lane: ambient replies gated by ambient_public_reply_pct,
# an open-thread window after direct address, and a one-reply lock (rather than
# a turn counter) for filtered-bot conversation that any human message resets.
sub handle_ambient_irc_public_event {
  my (%args) = @_;

  my $self = $args{self} or die 'handle_ambient_irc_public_event requires self';
  my $nickstr = $args{nickstr} // '';
  my $channels = $args{channels};
  my $msg = defined $args{msg} ? $args{msg} : '';
  my $utility_style = $args{utility_style} // 'relaxed';
  my $utility_notes_mode = $args{utility_notes_mode} // 'direct_only';

  my ($nick) = split /!/, $nickstr;
  return 0 if defined($nick) && $nick eq $self->get_nickname;
  my $channel = ref $channels ? $channels->[0] : $channels;
  $self->info("$channel <$nick> $msg");
  $self->_last_activity(time());

  if ($self->_is_human_nick($nick) && $self->_bert_reply_lock) {
    $self->_bert_reply_lock(0);
    $self->info("Reset burt conversational lock by human nick=$nick");
  }

  if (Bot::Runtime::UtilityCommands::handle_public_utility_command(
    self       => $self,
    channel    => $channel,
    msg        => $msg,
    style      => $utility_style,
    notes_mode => $utility_notes_mode,
  )) {
    return 1;
  }

  my $speaker_is_filtered_bot = $self->_is_filtered_bot_nick($nick);

  my $bot_nick = $self->get_nickname;
  my $nick_re = quotemeta($bot_nick);
  my $direct_mention = ($msg =~ /(?:^|\W)$nick_re(?:\W|$)/i) ? 1 : 0;
  my $direct_addressee = $self->_is_public_message_addressed_to_self($msg) ? 1 : 0;
  my $direct_address = ($direct_mention || $direct_addressee) ? 1 : 0;
  my $thread_open = ($self->_public_thread_open_until && time() <= $self->_public_thread_open_until) ? 1 : 0;
  my $addressed_other_human_turn = 0;
  if ($self->_is_human_nick($nick) && !$direct_address) {
    my ($target) = $self->_parse_public_addressee($msg);
    $addressed_other_human_turn = 1 if defined($target) && lc($target) ne lc($bot_nick) && lc($target) ne 'hey';
  }

  my $open_thread_window = sub {
    my ($why) = @_;
    my $public_thread_window_seconds = $self->_persona_trait('public_thread_window_seconds');
    return unless $public_thread_window_seconds > 0;
    $self->_public_thread_open_until(time() + $public_thread_window_seconds);
    $self->info("Opened public thread window for ${public_thread_window_seconds}s ($why)");
  };

  if ($speaker_is_filtered_bot) {
    return 0 unless $direct_address;
    if ($self->_bert_reply_lock) {
      $self->info('Suppressing Burt conversational message: lock set');
      return 1;
    }
    my $bot_reply_pct = $self->_persona_trait('bot_reply_pct');
    if ($bot_reply_pct < 100 && int(rand(100)) >= $bot_reply_pct) {
      $self->info("Suppressing Burt conversational message: probability gate bot_reply_pct=$bot_reply_pct");
      return 1;
    }
    $self->info('Allowing Burt conversational message (direct address, unlocked)');
    $open_thread_window->('filtered bot lane');
    $self->_buffer_message($channel, $nick, $msg, { source_kind => 'bert_conversation' });
    return 1;
  }

  if ($direct_address) {
    $open_thread_window->('direct address');
    $self->_buffer_message($channel, $nick, $msg, {
      source_kind => 'conversation',
      warm_human  => 1,
    });
    return 1;
  }

  if ($addressed_other_human_turn) {
    $self->info('Suppressing public conversational message: human addressed someone else');
    return 1;
  }

  if ($thread_open) {
    $self->info('Allowing public conversational message due to open thread window');
    $self->_buffer_message($channel, $nick, $msg, { source_kind => 'conversation' });
    return 1;
  }

  my $ambient_public_reply_pct = $self->_persona_trait('ambient_public_reply_pct');
  if ($ambient_public_reply_pct < 100 && int(rand(100)) >= $ambient_public_reply_pct) {
    $self->info("Suppressing public conversational message: probability gate ambient_public_reply_pct=$ambient_public_reply_pct");
    return 1;
  }

  $self->info('Allowing public conversational message via ambient probability gate');
  $self->_buffer_message($channel, $nick, $msg, { source_kind => 'conversation' });
  return 1;
}

1;
