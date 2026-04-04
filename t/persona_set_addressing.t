use strict;
use warnings;
use Test::More;

use lib 'lib';
use Bot::Runtime::UtilityCommands qw(handle_public_utility_command);

{
  package Local::PersonaSetBot;

  sub new {
    my ($class, %args) = @_;
    return bless {
      nickname    => $args{nickname} // 'Treb',
      sent        => [],
      persona_set => [],
    }, $class;
  }

  sub get_nickname { $_[0]->{nickname} }

  sub _utility_command_matches_me {
    my ($self, $target) = @_;
    return 0 unless defined $target && length $target;
    return lc($target) eq lc($self->get_nickname) ? 1 : 0;
  }

  sub _send_to_channel {
    my ($self, $chan, $text) = @_;
    push @{$self->{sent}}, $text;
  }

  sub _set_persona_trait {
    my ($self, $trait, $value) = @_;
    push @{$self->{persona_set}}, [$trait, $value];
    return (1, "set:$trait=$value");
  }

  sub _summarize_url          { '' }
  sub _current_local_time_text { '' }
  sub _db_stats_text          { '' }
  sub _time_text_for_zone     { '' }
  sub _cpan_lookup            { '' }
  sub _search_web             { '' }
  sub _persona_text           { '' }
  sub _persona_summary_text   { '' }
  sub _persona_trait_text     { '' }
  sub _apply_persona_preset   { (1, '') }
  sub _notes_text             { '' }
}

# addressed persona set is handled and sets trait
{
  my $bot = Local::PersonaSetBot->new(nickname => 'Treb');
  ok(
    handle_public_utility_command(
      self       => $bot,
      channel    => '#test',
      msg        => 'treb: persona set bot_reply_pct 42',
      style      => 'strict',
      notes_mode => 'direct_only',
    ),
    'addressed persona set is handled',
  );
  is_deeply($bot->{persona_set}, [['bot_reply_pct', '42']], 'addressed persona set forwards trait and value');
}

# mismatched nick is rejected
{
  my $bot = Local::PersonaSetBot->new(nickname => 'Treb');
  ok(
    !handle_public_utility_command(
      self       => $bot,
      channel    => '#test',
      msg        => 'othernick: persona set bot_reply_pct 42',
      style      => 'strict',
      notes_mode => 'direct_only',
    ),
    'mismatched-nick persona set is rejected',
  );
  is_deeply($bot->{persona_set}, [], 'mismatched-nick persona set does not set trait');
}

# bare persona set forms are not handled
for my $msg ('persona: set bot_reply_pct 42', ':persona set bot_reply_pct 42') {
  my $bot = Local::PersonaSetBot->new(nickname => 'Treb');
  ok(
    !handle_public_utility_command(
      self       => $bot,
      channel    => '#test',
      msg        => $msg,
      style      => 'strict',
      notes_mode => 'direct_only',
    ),
    "bare persona set form '$msg' is not handled",
  );
}

# treb.pl delegates public-message flow; burt.pl still delegates utility parsing directly
sub slurp { my ($f) = @_; do { local (@ARGV, $/) = $f; <> } }
like(
  slurp('treb.pl'),
  qr/Bot::Runtime::PublicMessages::handle_standard_irc_public_event\s*\(/,
  'treb.pl delegates public message handling to runtime module',
);
like(
  slurp('burt.pl'),
  qr/Bot::Runtime::UtilityCommands::handle_public_utility_command\s*\(/,
  'burt.pl delegates utility parsing to runtime module',
);

done_testing;
