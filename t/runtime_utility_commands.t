use strict;
use warnings;
use Test::More;

use lib 'lib';
use Bot::Runtime::UtilityCommands qw(handle_public_utility_command);

{
  package Local::UtilityBot;

  sub new {
    my ($class, %args) = @_;
    return bless {
      nickname        => $args{nickname} // 'Treb',
      allow_bare      => $args{allow_bare} ? 1 : 0,
      sent            => [],
      summarize_calls => [],
      cpan_calls      => [],
      search_calls    => [],
      time_zones      => [],
      notes_calls     => [],
      persona_set     => [],
      preset_calls    => [],
      persona_get     => [],
    }, $class;
  }

  sub get_nickname { $_[0]->{nickname} }

  sub _utility_command_matches_me {
    my ($self, $target) = @_;
    if (defined $target && length $target) {
      return lc($target) eq lc($self->get_nickname) ? 1 : 0;
    }
    return $self->{allow_bare} ? 1 : 0;
  }

  sub _send_to_channel {
    my ($self, $channel, $text) = @_;
    push @{$self->{sent}}, [$channel, $text];
  }

  sub _summarize_url {
    my ($self, $url) = @_;
    push @{$self->{summarize_calls}}, $url;
    return "sum:$url";
  }

  sub _current_local_time_text { '12:34' }

  sub _db_stats_text { 'db:ok' }

  sub _time_text_for_zone {
    my ($self, $zone) = @_;
    push @{$self->{time_zones}}, $zone;
    return "zone:$zone";
  }

  sub _cpan_lookup {
    my ($self, $mode, $query) = @_;
    push @{$self->{cpan_calls}}, [$mode, $query];
    return "cpan:$mode:$query";
  }

  sub _search_web {
    my ($self, $query, $count) = @_;
    push @{$self->{search_calls}}, [$query, $count];
    return "search:$count:$query";
  }

  sub _persona_text { 'persona:full' }
  sub _persona_summary_text { 'persona:summary' }

  sub _set_persona_trait {
    my ($self, $trait, $value) = @_;
    push @{$self->{persona_set}}, [$trait, $value];
    return (1, "set:$trait=$value");
  }

  sub _apply_persona_preset {
    my ($self, $preset) = @_;
    push @{$self->{preset_calls}}, $preset;
    return (1, "preset:$preset");
  }

  sub _persona_trait_text {
    my ($self, $trait) = @_;
    push @{$self->{persona_get}}, $trait;
    return "trait:$trait";
  }

  sub _notes_text {
    my ($self, $nick) = @_;
    push @{$self->{notes_calls}}, $nick;
    return "notes:$nick";
  }
}

{
  my $bot = Local::UtilityBot->new(nickname => 'Treb', allow_bare => 0);
  ok(
    handle_public_utility_command(
      self       => $bot,
      channel    => '#ai',
      msg        => 'treb: sum https://example.test',
      style      => 'strict',
      notes_mode => 'direct_only',
    ),
    'strict handler accepts targeted sum command'
  );
  is_deeply($bot->{summarize_calls}, ['https://example.test'], 'strict targeted sum passes URL');
}

{
  my $bot = Local::UtilityBot->new(nickname => 'Treb', allow_bare => 1);
  ok(
    handle_public_utility_command(
      self       => $bot,
      channel    => '#ai',
      msg        => 'sum: https://example.test',
      style      => 'strict',
      notes_mode => 'direct_only',
    ),
    'strict handler allows bare sum when bot permits bare utility commands'
  );
}

{
  my $bot = Local::UtilityBot->new(nickname => 'Treb', allow_bare => 0);
  ok(
    !handle_public_utility_command(
      self       => $bot,
      channel    => '#ai',
      msg        => 'sum: https://example.test',
      style      => 'strict',
      notes_mode => 'direct_only',
    ),
    'strict handler rejects bare sum when bot disallows bare utility commands'
  );
}

{
  my $bot = Local::UtilityBot->new(nickname => 'Burt', allow_bare => 1);
  ok(
    handle_public_utility_command(
      self       => $bot,
      channel    => '#ai',
      msg        => ':sum https://example.test',
      style      => 'relaxed',
      notes_mode => 'direct_only',
    ),
    'relaxed handler accepts :sum shorthand'
  );
}

{
  my $bot = Local::UtilityBot->new(nickname => 'Burt', allow_bare => 1);
  ok(
    !handle_public_utility_command(
      self       => $bot,
      channel    => '#ai',
      msg        => 'astrid: sum https://example.test',
      style      => 'relaxed',
      notes_mode => 'direct_only',
    ),
    'targeted command must match bot nickname'
  );
}

{
  my $bot = Local::UtilityBot->new(nickname => 'Treb', allow_bare => 0);
  ok(
    handle_public_utility_command(
      self       => $bot,
      channel    => '#ai',
      msg        => 'treb: persona set bot_reply_pct 42',
      style      => 'strict',
      notes_mode => 'direct_only',
    ),
    'persona set command is handled'
  );
  is_deeply($bot->{persona_set}, [['bot_reply_pct', 42]], 'persona set command forwards trait and value');
}

{
  my $bot = Local::UtilityBot->new(nickname => 'Treb', allow_bare => 0);
  ok(
    handle_public_utility_command(
      self       => $bot,
      channel    => '#ai',
      msg        => 'treb: persona 3',
      style      => 'strict',
      notes_mode => 'direct_only',
    ),
    'persona numeric shorthand maps to preset command'
  );
  is_deeply($bot->{preset_calls}, [3], 'persona preset receives numeric argument');
}

{
  my $bot = Local::UtilityBot->new(nickname => 'Treb', allow_bare => 1);
  ok(
    handle_public_utility_command(
      self       => $bot,
      channel    => '#ai',
      msg        => 'treb: notes mateu',
      style      => 'strict',
      notes_mode => 'direct_only',
    ),
    'direct notes mode accepts explicit nick-targeted command'
  );
  ok(
    !handle_public_utility_command(
      self       => $bot,
      channel    => '#ai',
      msg        => 'notes: mateu',
      style      => 'strict',
      notes_mode => 'direct_only',
    ),
    'direct notes mode rejects notes: shorthand'
  );
}

{
  my $bot = Local::UtilityBot->new(nickname => 'Astrid', allow_bare => 1);
  ok(
    handle_public_utility_command(
      self       => $bot,
      channel    => '#ai',
      msg        => 'notes: mateu',
      style      => 'relaxed',
      notes_mode => 'utility_prefixed',
    ),
    'utility-prefixed notes mode accepts notes: shorthand'
  );
  is_deeply($bot->{notes_calls}, ['mateu'], 'utility-prefixed notes forwards nick');
}

{
  my $bot = Local::UtilityBot->new(nickname => 'Treb', allow_bare => 1);
  ok(
    handle_public_utility_command(
      self       => $bot,
      channel    => '#ai',
      msg        => ':cpan recent 4',
      style      => 'strict',
      notes_mode => 'direct_only',
    ),
    'strict style parses :cpan recent count'
  );
  is_deeply($bot->{cpan_calls}, [['recent', 4]], 'cpan recent count is forwarded');
}

{
  my $bot = Local::UtilityBot->new(nickname => 'Burt', allow_bare => 1);
  ok(
    handle_public_utility_command(
      self       => $bot,
      channel    => '#ai',
      msg        => ':cpan author RJBS',
      style      => 'relaxed',
      notes_mode => 'direct_only',
    ),
    'relaxed style parses :cpan mode query command'
  );
  is_deeply($bot->{cpan_calls}, [['author', 'RJBS']], 'cpan mode and query are forwarded');
}

{
  my $bot = Local::UtilityBot->new(nickname => 'Burt', allow_bare => 1);
  ok(
    handle_public_utility_command(
      self       => $bot,
      channel    => '#ai',
      msg        => 'search: 9 perl bots',
      style      => 'relaxed',
      notes_mode => 'direct_only',
    ),
    'search command is handled'
  );
  is_deeply($bot->{search_calls}, [['perl bots', 5]], 'search result count is clamped to max');
}

{
  my $bot = Local::UtilityBot->new(nickname => 'Burt', allow_bare => 1);
  ok(
    handle_public_utility_command(
      self       => $bot,
      channel    => '#ai',
      msg        => 'search: 0 perl bots',
      style      => 'relaxed',
      notes_mode => 'direct_only',
    ),
    'search command with low count is handled'
  );
  is_deeply($bot->{search_calls}, [['perl bots', 1]], 'search result count is clamped to minimum');
}

{
  my $bot = Local::UtilityBot->new(nickname => 'Treb', allow_bare => 1);
  ok(
    !handle_public_utility_command(
      self       => $bot,
      channel    => '#ai',
      msg        => 'just chatting',
      style      => 'strict',
      notes_mode => 'direct_only',
    ),
    'non-command input is ignored'
  );
}

done_testing;
