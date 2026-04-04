use strict;
use warnings;
use Test::More;

use lib 'lib';
use Bot::Runtime::PublicMessages qw(handle_standard_irc_public_event);
use Bot::Runtime::Dispatch ();

{
  package Local::PublicBot;

  sub new {
    my ($class, %args) = @_;
    return bless {
      nickname                      => $args{nickname} || 'treb_bot',
      filtered                      => $args{filtered} || {},
      traits                        => $args{traits} || {},
      _bert_reply_turn_count        => 0,
      _human_warm_reply_count       => 0,
      _human_warm_reply_expires_at  => 0,
      _last_activity                => 0,
      logs                          => [],
      buffered                      => [],
    }, $class;
  }

  sub get_nickname { return $_[0]->{nickname} }

  sub info {
    my ($self, $line) = @_;
    push @{$self->{logs}}, $line;
    return 1;
  }

  sub _last_activity {
    my ($self, $value) = @_;
    $self->{_last_activity} = $value if @_ > 1;
    return $self->{_last_activity};
  }

  sub _is_human_nick {
    my ($self, $nick) = @_;
    return 0 unless defined $nick && length $nick;
    return 0 if lc($nick) eq lc($self->get_nickname);
    return $self->_is_filtered_bot_nick($nick) ? 0 : 1;
  }

  sub _is_filtered_bot_nick {
    my ($self, $nick) = @_;
    return $self->{filtered}{lc($nick || '')} ? 1 : 0;
  }

  sub _persona_trait {
    my ($self, $key) = @_;
    return $self->{traits}{$key} // 0;
  }

  sub _bert_reply_turn_count {
    my ($self, $value) = @_;
    $self->{_bert_reply_turn_count} = $value if @_ > 1;
    return $self->{_bert_reply_turn_count};
  }

  sub _human_warm_reply_count {
    my ($self, $value) = @_;
    $self->{_human_warm_reply_count} = $value if @_ > 1;
    return $self->{_human_warm_reply_count};
  }

  sub _human_warm_reply_expires_at {
    my ($self, $value) = @_;
    $self->{_human_warm_reply_expires_at} = $value if @_ > 1;
    return $self->{_human_warm_reply_expires_at};
  }

  sub _is_public_message_addressed_to_self {
    my ($self, $msg) = @_;
    return Bot::Runtime::Dispatch::is_public_message_addressed_to_self(
      self => $self,
      msg  => $msg,
    );
  }

  sub _buffer_message {
    my ($self, $channel, $nick, $msg, $extra) = @_;
    push @{$self->{buffered}}, {
      channel => $channel,
      nick    => $nick,
      msg     => $msg,
      extra   => $extra,
    };
    return 1;
  }
}

{
  my $bot = Local::PublicBot->new(nickname => 'treb_bot');
  my @calls;
  no warnings 'redefine';
  local *Bot::Runtime::UtilityCommands::handle_public_utility_command = sub {
    my (%args) = @_;
    push @calls, \%args;
    return 1;
  };

  my $handled = handle_standard_irc_public_event(
    self               => $bot,
    nickstr            => 'alice!u@h',
    channels           => ['#ai'],
    msg                => 'sum: https://example.test',
    utility_style      => 'strict',
    utility_notes_mode => 'direct_only',
  );

  is($handled, 1, 'utility short-circuit returns handled');
  is(scalar @calls, 1, 'utility handler invoked once');
  is($calls[0]{style}, 'strict', 'utility style forwarded');
  is($calls[0]{notes_mode}, 'direct_only', 'utility notes mode forwarded');
  is(scalar @{$bot->{buffered}}, 0, 'no buffering when utility command handles message');
}

{
  my $bot = Local::PublicBot->new(
    nickname => 'treb_bot',
    filtered => { burt_bot => 1 },
    traits   => { bot_reply_max_turns => 1, bot_reply_pct => 100 },
  );

  no warnings 'redefine';
  local *Bot::Runtime::UtilityCommands::handle_public_utility_command = sub { return 0 };

  handle_standard_irc_public_event(
    self               => $bot,
    nickstr            => 'burt_bot!u@h',
    channels           => ['#ai'],
    msg                => 'hey treb_bot what do you think',
    utility_style      => 'strict',
    utility_notes_mode => 'direct_only',
    bot_direct_mode    => 'mention',
    human_direct_mode  => 'addressed_to_self',
  );

  is(scalar @{$bot->{buffered}}, 1, 'filtered bot message buffered when mention-mode direct');
  is($bot->{buffered}[0]{extra}{source_kind}, 'bert_conversation', 'filtered bot lane source kind set');
}

{
  my $bot = Local::PublicBot->new(
    nickname => 'treb_bot',
    filtered => { burt_bot => 1 },
    traits   => { bot_reply_max_turns => 1, bot_reply_pct => 100 },
  );
  $bot->_bert_reply_turn_count(1);

  no warnings 'redefine';
  local *Bot::Runtime::UtilityCommands::handle_public_utility_command = sub { return 0 };

  handle_standard_irc_public_event(
    self               => $bot,
    nickstr            => 'burt_bot!u@h',
    channels           => ['#ai'],
    msg                => 'treb_bot: still there?',
    utility_style      => 'strict',
    utility_notes_mode => 'direct_only',
    bot_direct_mode    => 'mention',
    human_direct_mode  => 'addressed_to_self',
  );

  is(scalar @{$bot->{buffered}}, 0, 'filtered bot message suppressed when turn cap reached');
}

{
  my $bot = Local::PublicBot->new(
    nickname => 'treb_bot',
    traits   => { bot_reply_max_turns => 1, bot_reply_pct => 100 },
  );
  $bot->_bert_reply_turn_count(2);

  no warnings 'redefine';
  local *Bot::Runtime::UtilityCommands::handle_public_utility_command = sub { return 0 };

  for (1..4) {
    handle_standard_irc_public_event(
      self               => $bot,
      nickstr            => 'alice!u@h',
      channels           => ['#ai'],
      msg                => 'treb_bot: hello',
      utility_style      => 'strict',
      utility_notes_mode => 'direct_only',
      bot_direct_mode    => 'mention',
      human_direct_mode  => 'addressed_to_self',
      warm_limit         => 3,
      warm_window        => 300,
    );
  }

  is($bot->_bert_reply_turn_count, 0, 'human speaker resets bert conversational turn count');
  is(scalar @{$bot->{buffered}}, 4, 'direct-addressed human messages are buffered');
  is($bot->{buffered}[0]{extra}{warm_human}, 1, 'warm flag set for first message');
  is($bot->{buffered}[2]{extra}{warm_human}, 1, 'warm flag set through warm limit');
  is($bot->{buffered}[3]{extra}{warm_human}, 0, 'warm flag disabled after warm limit');
}

{
  my $bot = Local::PublicBot->new(
    nickname => 'astrid_bot',
    filtered => { treb_bot => 1 },
    traits   => { bot_reply_max_turns => 1, bot_reply_pct => 100 },
  );

  no warnings 'redefine';
  local *Bot::Runtime::UtilityCommands::handle_public_utility_command = sub { return 0 };

  handle_standard_irc_public_event(
    self               => $bot,
    nickstr            => 'alice!u@h',
    channels           => ['#ai'],
    msg                => 'hey astrid_bot can you help?',
    utility_style      => 'relaxed',
    utility_notes_mode => 'utility_prefixed',
    bot_direct_mode    => 'mention',
    human_direct_mode  => 'mention',
  );

  is(scalar @{$bot->{buffered}}, 1, 'mention-mode human direct path buffers astrid public message');
  is($bot->{buffered}[0]{extra}{source_kind}, 'conversation', 'human lane source kind set');
  is($bot->{buffered}[0]{extra}{warm_human}, 1, 'human lane marks warm_human');
}

done_testing;
