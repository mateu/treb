use strict;
use warnings;
use Test::More;

use lib 'lib';
use Bot::Persona qw(persona_trait_meta persona_trait_order);
use Bot::Runtime::PersonaTools ();

{
  package Local::DBH;

  sub new {
    my ($class, %args) = @_;
    return bless { memory => $args{memory} }, $class;
  }

  sub selectrow_array {
    my ($self, $sql) = @_;
    my $memory = $self->{memory};

    if ($sql eq 'SELECT COUNT(*) FROM conversations') {
      return scalar @{$memory->{conversations}};
    }
    if ($sql eq 'SELECT COUNT(*) FROM notes') {
      return scalar @{$memory->{notes}};
    }
    if ($sql eq 'SELECT COUNT(DISTINCT channel) FROM conversations') {
      my %channels;
      $channels{$_->{channel}} = 1 for grep { defined $_->{channel} } @{$memory->{conversations}};
      return scalar keys %channels;
    }
    if ($sql eq 'SELECT MAX(created_at) FROM conversations') {
      my @timestamps = map { $_->{created_at} } grep { defined $_->{created_at} } @{$memory->{conversations}};
      return undef unless @timestamps;

      my $max = $timestamps[0];
      for my $timestamp (@timestamps[1 .. $#timestamps]) {
        $max = $timestamp if $timestamp gt $max;
      }
      return $max;
    }
    if ($sql eq q{SELECT COUNT(*) FROM conversations WHERE nick = 'system'}) {
      my $count = scalar grep { ($_->{nick} // '') eq 'system' } @{$memory->{conversations}};
      return $count;
    }

    die "Unexpected SQL in Local::DBH: $sql";
  }
}

{
  package Local::Memory;

  sub new {
    my ($class, %args) = @_;
    my $self = bless {
      db_file      => $args{db_file} || ':memory:',
      conversations => [],
      notes         => [],
      persona       => {},
      _note_id      => 0,
    }, $class;
    $self->{_dbh} = Local::DBH->new(memory => $self);
    return $self;
  }

  sub _dbh { $_[0]->{_dbh} }
  sub db_file { $_[0]->{db_file} }

  sub get_persona_settings {
    my ($self, $bot_name) = @_;
    return { %{$self->{persona}{$bot_name} || {}} };
  }

  sub set_persona_setting {
    my ($self, $bot_name, $trait_key, $trait_value) = @_;
    $self->{persona}{$bot_name}{$trait_key} = "$trait_value";
  }

  sub add_conversation {
    my ($self, %row) = @_;
    push @{$self->{conversations}}, {
      nick       => $row{nick},
      message    => $row{message},
      response   => $row{response},
      channel    => $row{channel},
      created_at => $row{created_at} || '2026-04-03 12:00:00',
    };
  }

  sub add_note {
    my ($self, $nick, $content) = @_;
    $self->{_note_id}++;
    push @{$self->{notes}}, {
      id      => $self->{_note_id},
      nick    => $nick,
      content => $content,
    };
  }

  sub recall_notes {
    my ($self, $nick, $query, $limit) = @_;
    $query //= '';
    $limit //= 10;

    my @rows = grep {
      ($_->{nick} // '') eq $nick && ($_->{content} // '') =~ /\Q$query\E/
    } @{$self->{notes}};
    @rows = reverse @rows;
    splice @rows, $limit if @rows > $limit;

    return join("\n", map { "#$_->{id} [$_->{nick}] $_->{content}" } @rows);
  }
}

{
  package Local::PersonaTestBot;

  sub new {
    my ($class, %args) = @_;
    return bless {
      memory         => $args{memory},
      _persona_cache => {},
    }, $class;
  }

  sub memory { $_[0]->{memory} }

  sub _persona_cache {
    my ($self, $value) = @_;
    $self->{_persona_cache} = $value if @_ > 1;
    return $self->{_persona_cache};
  }
}

local $ENV{JOIN_GREET_PCT} = 77;
local $ENV{PUBLIC_CHAT_ALLOW_PCT} = 33;
local $ENV{PUBLIC_THREAD_WINDOW_SECONDS} = 12;
local $ENV{BOT_REPLY_PCT} = 44;
local $ENV{BOT_REPLY_MAX_TURNS} = 5;
local $ENV{NON_SUBSTANTIVE_ALLOW_PCT} = 6;

my %meta = %{ Bot::Persona::persona_trait_meta() };
my @order = Bot::Persona::persona_trait_order();

my $memory = Local::Memory->new(db_file => ':memory:');
my $bot = Local::PersonaTestBot->new(memory => $memory);
my %args = (
  self        => $bot,
  bot_name    => 'treb',
  trait_meta  => \%meta,
  trait_order => \@order,
);

my $cache = Bot::Runtime::PersonaTools::load_persona_settings(%args);
is($cache->{join_greet_pct}, 77, 'load_persona_settings reads env values');
is($bot->_persona_cache->{bot_reply_pct}, 44, 'cache stored on bot');

my $default = Bot::Runtime::PersonaTools::default_persona_trait_value(%args, key => 'non_substantive_allow_pct');
is($default, 6, 'default_persona_trait_value reads cache-backed value');

is(Bot::Runtime::PersonaTools::persona_trait(%args, key => 'public_thread_window_seconds'), 12, 'persona_trait reads cached values');
like(Bot::Runtime::PersonaTools::persona_stats_text(%args), qr/join_greet_pct=77/, 'persona_stats_text renders ordered key/value list');
like(Bot::Runtime::PersonaTools::persona_text(%args), qr/^Persona \[treb\]:/m, 'persona_text renders full view');
like(Bot::Runtime::PersonaTools::persona_summary_text(%args), qr/^Persona \[treb\] join_greet=/m, 'persona_summary_text renders compact summary view');
is(Bot::Runtime::PersonaTools::persona_trait_text(%args, trait => 'bot_reply_pct'), 'bot_reply_pct=44', 'persona_trait_text reads one trait');

my ($ok_set, $set_msg) = Bot::Runtime::PersonaTools::set_persona_trait(%args, trait => 'bot_reply_pct', value => 101);
ok($ok_set, 'set_persona_trait succeeds for valid trait');
is($bot->_persona_cache->{bot_reply_pct}, 100, 'set_persona_trait clamps pct values');
like($set_msg, qr/^Set bot_reply_pct=100 for treb\./, 'set_persona_trait includes bot name in message');

my ($ok_preset, $preset_msg) = Bot::Runtime::PersonaTools::apply_persona_preset(%args, value => 3);
ok($ok_preset, 'apply_persona_preset accepts valid preset');
like($preset_msg, qr/^Applied persona preset 3:/, 'apply_persona_preset returns summary text');
is($bot->_persona_cache->{bot_reply_max_turns}, 3, 'apply_persona_preset updates cache');

$memory->add_conversation(nick => 'mateu', message => 'hey', response => 'yo', channel => '#ai', created_at => '2026-04-03 12:00:00');
$memory->add_conversation(nick => 'system', message => 'noop', response => 'noop', channel => '#ai', created_at => '2026-04-03 12:01:00');
$memory->add_note('mateu', 'keeps things practical');

my $stats = Bot::Runtime::PersonaTools::db_stats_text(%args);
like($stats, qr/conversations: 2/, 'db_stats_text counts conversation rows');
like($stats, qr/system rows: 1/, 'db_stats_text includes system rows');
like($stats, qr/persona=\{.*bot_reply_max_turns=3/s, 'db_stats_text includes persona stats');

is(Bot::Runtime::PersonaTools::notes_text(self => $bot, nick => 'mateu'), '#1 [mateu] keeps things practical', 'notes_text returns stored notes');
is(Bot::Runtime::PersonaTools::notes_text(self => $bot, nick => 'nobody'), 'No notes for nobody.', 'notes_text handles missing notes');
is(Bot::Runtime::PersonaTools::notes_text(self => $bot, nick => '   '), 'Usage: :notes <nick>', 'notes_text validates nick');

done_testing;
