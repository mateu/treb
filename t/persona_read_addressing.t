use strict;
use warnings;
use Test::More;

use lib 'lib';
use Bot::Runtime::UtilityCommands qw(handle_public_utility_command);

{
  package Local::PersonaReadBot;

  sub new {
    my ($class, %args) = @_;
    return bless {
      nickname => $args{nickname} // 'Treb',
      sent     => [],
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

  sub _persona_text         { 'persona:full' }
  sub _persona_summary_text { 'persona:summary' }

  sub _summarize_url          { '' }
  sub _current_local_time_text { '' }
  sub _db_stats_text          { '' }
  sub _time_text_for_zone     { '' }
  sub _cpan_lookup            { '' }
  sub _search_web             { '' }
  sub _set_persona_trait      { (1, '') }
  sub _apply_persona_preset   { (1, '') }
  sub _persona_trait_text     { '' }
  sub _notes_text             { '' }
}

# addressed persona full is handled
{
  my $bot = Local::PersonaReadBot->new(nickname => 'Treb');
  ok(
    handle_public_utility_command(
      self       => $bot,
      channel    => '#test',
      msg        => 'treb: persona full',
      style      => 'strict',
      notes_mode => 'direct_only',
    ),
    'addressed persona full is handled',
  );
  is($bot->{sent}[-1], 'persona:full', 'addressed persona full sends full persona text');
}

# persona full rejects mismatched nick
{
  my $bot = Local::PersonaReadBot->new(nickname => 'Treb');
  ok(
    !handle_public_utility_command(
      self       => $bot,
      channel    => '#test',
      msg        => 'othernick: persona full',
      style      => 'strict',
      notes_mode => 'direct_only',
    ),
    'mismatched-nick persona full is rejected',
  );
}

# bare persona full forms are not handled
for my $msg (':persona full', 'persona: full') {
  my $bot = Local::PersonaReadBot->new(nickname => 'Treb');
  ok(
    !handle_public_utility_command(
      self       => $bot,
      channel    => '#test',
      msg        => $msg,
      style      => 'strict',
      notes_mode => 'direct_only',
    ),
    "bare persona full form '$msg' is not handled",
  );
}

# addressed persona summary is handled
{
  my $bot = Local::PersonaReadBot->new(nickname => 'Treb');
  ok(
    handle_public_utility_command(
      self       => $bot,
      channel    => '#test',
      msg        => 'treb: persona',
      style      => 'strict',
      notes_mode => 'direct_only',
    ),
    'addressed persona summary is handled',
  );
  is($bot->{sent}[-1], 'persona:summary', 'addressed persona summary sends summary text');
}

# persona summary rejects mismatched nick
{
  my $bot = Local::PersonaReadBot->new(nickname => 'Treb');
  ok(
    !handle_public_utility_command(
      self       => $bot,
      channel    => '#test',
      msg        => 'othernick: persona',
      style      => 'strict',
      notes_mode => 'direct_only',
    ),
    'mismatched-nick persona summary is rejected',
  );
}

# bare persona summary forms are not handled
for my $msg (':persona', 'persona:') {
  my $bot = Local::PersonaReadBot->new(nickname => 'Treb');
  ok(
    !handle_public_utility_command(
      self       => $bot,
      channel    => '#test',
      msg        => $msg,
      style      => 'strict',
      notes_mode => 'direct_only',
    ),
    "bare persona summary form '$msg' is not handled",
  );
}

# treb.pl and burt.pl delegate utility parsing to runtime
sub slurp { my ($f) = @_; do { local (@ARGV, $/) = $f; <> } }
for my $script (qw(treb.pl burt.pl)) {
  my $src = slurp($script);
  like(
    $src,
    qr/Bot::Runtime::UtilityCommands::handle_public_utility_command\s*\(/,
    "$script delegates utility parsing to runtime module",
  );
}

done_testing;
