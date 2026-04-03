package Bot::Runtime::PersonaTools;

use strict;
use warnings;

use Bot::Persona ();

sub _load_cache {
  my (%args) = @_;
  my $self        = $args{self} or die '_load_cache requires self';
  my $bot_name    = $args{bot_name} or die '_load_cache requires bot_name';
  my $trait_meta  = $args{trait_meta} or die '_load_cache requires trait_meta';
  my $trait_order = $args{trait_order} or die '_load_cache requires trait_order';

  my $cache = Bot::Persona::load_persona_cache(
    memory      => $self->memory,
    bot_name    => $bot_name,
    trait_meta  => $trait_meta,
    trait_order => $trait_order,
  );
  $self->_persona_cache($cache);
  return $cache;
}

sub default_persona_trait_value {
  my (%args) = @_;
  my $key = $args{key};
  my $cache = _load_cache(%args);
  return $cache->{$key};
}

sub load_persona_settings {
  my (%args) = @_;
  return _load_cache(%args);
}

sub persona_trait {
  my (%args) = @_;
  my $self = $args{self} or die 'persona_trait requires self';
  my $key  = $args{key};

  my $cache = $self->_persona_cache || {};
  return $cache->{$key} if exists $cache->{$key};
  $cache = _load_cache(%args);
  return $cache->{$key};
}

sub persona_stats_text {
  my (%args) = @_;
  my $self        = $args{self} or die 'persona_stats_text requires self';
  my $trait_order = $args{trait_order} or die 'persona_stats_text requires trait_order';

  my $cache = $self->_persona_cache || {};
  $cache = _load_cache(%args) unless %{$cache};
  return join('; ', map { $_ . '=' . $cache->{$_} } @{$trait_order});
}

sub persona_text {
  my (%args) = @_;
  my $self        = $args{self} or die 'persona_text requires self';
  my $bot_name    = $args{bot_name} or die 'persona_text requires bot_name';
  my $trait_meta  = $args{trait_meta} or die 'persona_text requires trait_meta';
  my $trait_order = $args{trait_order} or die 'persona_text requires trait_order';

  my $cache = $self->_persona_cache || {};
  $cache = _load_cache(%args) unless %{$cache};
  return Bot::Persona::persona_text(
    bot_name    => $bot_name,
    cache       => $cache,
    full        => 1,
    trait_meta  => $trait_meta,
    trait_order => $trait_order,
  );
}

sub persona_summary_text {
  my (%args) = @_;
  my $self        = $args{self} or die 'persona_summary_text requires self';
  my $bot_name    = $args{bot_name} or die 'persona_summary_text requires bot_name';
  my $trait_meta  = $args{trait_meta} or die 'persona_summary_text requires trait_meta';
  my $trait_order = $args{trait_order} or die 'persona_summary_text requires trait_order';

  my $cache = $self->_persona_cache || {};
  $cache = _load_cache(%args) unless %{$cache};
  return Bot::Persona::persona_summary_text(
    bot_name    => $bot_name,
    cache       => $cache,
    trait_meta  => $trait_meta,
    trait_order => $trait_order,
  );
}

sub persona_trait_text {
  my (%args) = @_;
  my $self        = $args{self} or die 'persona_trait_text requires self';
  my $trait       = $args{trait};
  my $trait_meta  = $args{trait_meta} or die 'persona_trait_text requires trait_meta';
  my $trait_order = $args{trait_order} or die 'persona_trait_text requires trait_order';

  my $cache = $self->_persona_cache || {};
  $cache = _load_cache(%args) unless %{$cache};
  return Bot::Persona::persona_trait_text(
    trait       => $trait,
    cache       => $cache,
    trait_meta  => $trait_meta,
    trait_order => $trait_order,
  );
}

sub set_persona_trait {
  my (%args) = @_;
  my $self        = $args{self} or die 'set_persona_trait requires self';
  my $bot_name    = $args{bot_name} or die 'set_persona_trait requires bot_name';
  my $trait       = $args{trait};
  my $value       = $args{value};
  my $trait_meta  = $args{trait_meta} or die 'set_persona_trait requires trait_meta';
  my $trait_order = $args{trait_order} or die 'set_persona_trait requires trait_order';

  my $cache = $self->_persona_cache || {};
  $cache = _load_cache(%args) unless %{$cache};
  my ($ok, $msg) = Bot::Persona::set_persona_trait(
    memory      => $self->memory,
    bot_name    => $bot_name,
    cache       => $cache,
    trait       => $trait,
    value       => $value,
    trait_meta  => $trait_meta,
    trait_order => $trait_order,
  );
  $self->_persona_cache($cache);
  return ($ok, $ok ? "Set $msg for $bot_name." : $msg);
}

sub apply_persona_preset {
  my (%args) = @_;
  my $self        = $args{self} or die 'apply_persona_preset requires self';
  my $bot_name    = $args{bot_name} or die 'apply_persona_preset requires bot_name';
  my $value       = $args{value};
  my $trait_meta  = $args{trait_meta} or die 'apply_persona_preset requires trait_meta';
  my $trait_order = $args{trait_order} or die 'apply_persona_preset requires trait_order';

  my $cache = $self->_persona_cache || {};
  $cache = _load_cache(%args) unless %{$cache};
  my ($ok, $msg) = Bot::Persona::apply_persona_preset(
    memory      => $self->memory,
    bot_name    => $bot_name,
    cache       => $cache,
    value       => $value,
    trait_meta  => $trait_meta,
    trait_order => $trait_order,
  );
  $self->_persona_cache($cache);
  return ($ok, $msg);
}

sub db_stats_text {
  my (%args) = @_;
  my $self = $args{self} or die 'db_stats_text requires self';

  my $dbh = $self->memory->_dbh;
  my ($conv_count) = $dbh->selectrow_array('SELECT COUNT(*) FROM conversations');
  my ($note_count) = $dbh->selectrow_array('SELECT COUNT(*) FROM notes');
  my ($channel_count) = $dbh->selectrow_array('SELECT COUNT(DISTINCT channel) FROM conversations');
  my ($latest) = $dbh->selectrow_array('SELECT MAX(created_at) FROM conversations');
  my ($system_rows) = $dbh->selectrow_array(q{SELECT COUNT(*) FROM conversations WHERE nick = 'system'});
  $conv_count ||= 0;
  $note_count ||= 0;
  $channel_count ||= 0;
  $system_rows ||= 0;
  $latest ||= 'n/a';

  my $persona_stats = persona_stats_text(%args);
  return sprintf(
    'DB: %s | conversations: %d | notes: %d | channels: %d | system rows: %d | latest: %s | persona={%s}',
    $self->memory->db_file,
    $conv_count,
    $note_count,
    $channel_count,
    $system_rows,
    $latest,
    $persona_stats,
  );
}

sub notes_text {
  my (%args) = @_;
  my $self = $args{self} or die 'notes_text requires self';
  my $nick = $args{nick};

  $nick //= '';
  $nick =~ s/^\s+|\s+$//g;
  return 'Usage: :notes <nick>' unless length $nick;

  my $notes = $self->memory->recall_notes($nick, '', 10);
  return $notes && $notes =~ /\S/ ? $notes : "No notes for $nick.";
}

1;
