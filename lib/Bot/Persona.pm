package Bot::Persona;

use strict;
use warnings;

use Exporter 'import';
our @EXPORT_OK = qw(
  persona_trait_meta
  persona_trait_order
  clamp_persona_value
  load_persona_cache
  persona_text
  persona_summary_text
  persona_trait_text
  set_persona_trait
  apply_persona_preset
);

my %PERSONA_TRAIT_META = (
  join_greet_pct => {
    kind => 'pct',
    default => 0,
  },
  ambient_public_reply_pct => {
    kind => 'pct',
    default => 0,
  },
  public_thread_window_seconds => {
    kind => 'seconds',
    default => 45,
  },
  bot_reply_pct => {
    kind => 'pct',
    default => 50,
  },
  bot_reply_max_turns => {
    kind => 'turns',
    default => 1,
  },
  non_substantive_allow_pct => {
    kind => 'pct',
    default => 0,
  },
);

my @PERSONA_TRAIT_ORDER = qw(
  join_greet_pct
  ambient_public_reply_pct
  public_thread_window_seconds
  bot_reply_pct
  bot_reply_max_turns
  non_substantive_allow_pct
);

sub persona_trait_meta {
  return \%PERSONA_TRAIT_META;
}

sub persona_trait_order {
  return @PERSONA_TRAIT_ORDER;
}

sub _trait_meta {
  my ($args) = @_;
  return $args->{trait_meta} || \%PERSONA_TRAIT_META;
}

sub _trait_order {
  my ($args) = @_;
  return $args->{trait_order} || \@PERSONA_TRAIT_ORDER;
}

sub clamp_persona_value {
  my ($trait, $value, %args) = @_;
  return 0 unless defined $value;
  $value = int($value);
  $value = 0 if $value < 0;

  my $trait_meta = _trait_meta(\%args);
  my $meta = $trait_meta->{$trait} || {};
  if (($meta->{kind} || '') eq 'pct') {
    $value = 100 if $value > 100;
  }
  return $value;
}

sub _default_for_trait {
  my ($trait, %args) = @_;
  my $trait_meta = _trait_meta(\%args);
  return $trait_meta->{$trait}{default};
}

sub _env_name_for_trait {
  my ($trait, %args) = @_;
  my $trait_meta = _trait_meta(\%args);
  return $trait_meta->{$trait}{env} || uc($trait);
}

sub load_persona_cache {
  my (%args) = @_;
  my $memory = $args{memory} or die 'load_persona_cache requires memory';
  my $bot_name = $args{bot_name} or die 'load_persona_cache requires bot_name';
  my $trait_order = _trait_order(\%args);

  my $existing = $memory->get_persona_settings($bot_name);
  my %cache;

  for my $trait (@$trait_order) {
    my $value;
    if (exists $existing->{$trait}) {
      $value = $existing->{$trait};
    } else {
      my $env_name = _env_name_for_trait($trait, %args);
      if (exists $ENV{$env_name} && defined $ENV{$env_name} && $ENV{$env_name} =~ /^\d+$/) {
        $value = $ENV{$env_name};
      } else {
        $value = _default_for_trait($trait, %args);
      }
      $value = clamp_persona_value($trait, $value, %args);
      $memory->set_persona_setting($bot_name, $trait, $value);
    }
    $cache{$trait} = clamp_persona_value($trait, $value, %args);
  }

  return \%cache;
}

sub persona_text {
  my (%args) = @_;
  my $bot_name = $args{bot_name} || 'bot';
  my $cache = $args{cache} || {};
  my $full = $args{full} ? 1 : 0;
  my $trait_order = _trait_order(\%args);

  if ($full) {
    return join("\n",
      "Persona [$bot_name]:",
      map {
        my $value = defined $cache->{$_} ? $cache->{$_} : _default_for_trait($_, %args);
        $_ . ': ' . $value;
      } @$trait_order,
    );
  }

  my @pairs = map { sprintf('%s=%s', $_, defined $cache->{$_} ? $cache->{$_} : _default_for_trait($_, %args)) } @$trait_order;
  return "Persona [$bot_name] " . join(' ', @pairs);
}

sub persona_summary_text {
  my (%args) = @_;
  my $bot_name = $args{bot_name} || 'bot';
  my $cache = $args{cache} || {};
  my $trait_order = _trait_order(\%args);
  my %label = (
    join_greet_pct => 'join_greet',
    ambient_public_reply_pct => 'ambient',
    public_thread_window_seconds => 'thread_window',
    bot_reply_pct => 'bot_reply',
    bot_reply_max_turns => 'bot_turns',
    non_substantive_allow_pct => 'non_substantive',
  );
  return join(' ',
    "Persona [$bot_name]",
    map {
      my $value = defined $cache->{$_} ? $cache->{$_} : _default_for_trait($_, %args);
      ($label{$_} // $_) . '=' . $value;
    } @$trait_order,
  );
}

sub persona_trait_text {
  my (%args) = @_;
  my $trait = $args{trait};
  my $cache = $args{cache} || {};

  my $trait_meta = _trait_meta(\%args);
  my $trait_order = _trait_order(\%args);
  return 'Unknown persona trait. Valid: ' . join(', ', @$trait_order)
    unless defined $trait && exists $trait_meta->{$trait};

  my $value = defined $cache->{$trait} ? $cache->{$trait} : _default_for_trait($trait, %args);
  return "$trait=$value";
}

sub set_persona_trait {
  my (%args) = @_;
  my $memory = $args{memory} or die 'set_persona_trait requires memory';
  my $bot_name = $args{bot_name} or die 'set_persona_trait requires bot_name';
  my $cache = $args{cache} or die 'set_persona_trait requires cache';
  my $trait = $args{trait};
  my $value = $args{value};

  my $trait_meta = _trait_meta(\%args);
  my $trait_order = _trait_order(\%args);
  return (0, 'Unknown persona trait. Valid: ' . join(', ', @$trait_order))
    unless defined $trait && exists $trait_meta->{$trait};
  return (0, 'Value must be a non-negative integer.')
    unless defined $value && $value =~ /^\d+$/;

  my $clamped = clamp_persona_value($trait, $value, %args);
  $memory->set_persona_setting($bot_name, $trait, $clamped);
  $cache->{$trait} = $clamped;
  return (1, "$trait=$clamped");
}

sub apply_persona_preset {
  my (%args) = @_;
  my $memory = $args{memory} or die 'apply_persona_preset requires memory';
  my $bot_name = $args{bot_name} or die 'apply_persona_preset requires bot_name';
  my $cache = $args{cache} or die 'apply_persona_preset requires cache';
  my $value = $args{value};

  if (defined $value) {
    $value =~ s/[-\x7f]+/ /g;
    $value =~ s/^\s+|\s+$//g;
  }
  return (0, 'Preset value must be a non-negative integer.')
    unless defined $value && $value =~ /^\d+$/;

  my $trait_meta = _trait_meta(\%args);
  my $trait_order = _trait_order(\%args);
  my $n = int($value);
  my %next;

  if ($n == 0) {
    %next = map { $_ => 0 } @$trait_order;
  }
  elsif ($n <= 5) {
    my $pct = $n * 10;
    for my $trait (@$trait_order) {
      my $kind = $trait_meta->{$trait}{kind} || '';
      if ($kind eq 'pct') {
        if ($trait eq 'non_substantive_allow_pct') {
          $next{$trait} = defined $cache->{$trait} ? $cache->{$trait} : _default_for_trait($trait, %args);
        } else {
          $next{$trait} = $pct;
        }
      }
      elsif ($trait eq 'bot_reply_max_turns') {
        $next{$trait} = $n;
      }
      elsif ($trait eq 'public_thread_window_seconds') {
        $next{$trait} = $n * 9;
      }
      else {
        $next{$trait} = clamp_persona_value($trait, $n, %args);
      }
    }
  }
  elsif ($n <= 10) {
    my $pct = 50 + ($n - 5) * 10;
    for my $trait (@$trait_order) {
      my $kind = $trait_meta->{$trait}{kind} || '';
      if ($kind eq 'pct') {
        if ($trait eq 'non_substantive_allow_pct') {
          $next{$trait} = defined $cache->{$trait} ? $cache->{$trait} : _default_for_trait($trait, %args);
        } else {
          $next{$trait} = $pct;
        }
      }
      elsif ($trait eq 'bot_reply_max_turns') {
        $next{$trait} = $n;
      }
      elsif ($trait eq 'public_thread_window_seconds') {
        $next{$trait} = 45 + ($n - 5) * 3;
      }
      else {
        $next{$trait} = clamp_persona_value($trait, $n, %args);
      }
    }
  }
  else {
    for my $trait (@$trait_order) {
      my $kind = $trait_meta->{$trait}{kind} || '';
      if ($kind eq 'pct') {
        if ($trait eq 'non_substantive_allow_pct') {
          $next{$trait} = defined $cache->{$trait} ? $cache->{$trait} : _default_for_trait($trait, %args);
        } else {
          $next{$trait} = 100;
        }
      }
      elsif ($trait eq 'bot_reply_max_turns') {
        $next{$trait} = $n;
      }
      elsif ($trait eq 'public_thread_window_seconds') {
        $next{$trait} = 60;
      }
      else {
        $next{$trait} = clamp_persona_value($trait, $n, %args);
      }
    }
  }

  for my $trait (@$trait_order) {
    my $v = clamp_persona_value($trait, $next{$trait}, %args);
    $memory->set_persona_setting($bot_name, $trait, $v);
    $cache->{$trait} = $v;
  }

  return (1, 'Applied persona preset ' . $n . ': ' . persona_summary_text(bot_name => $bot_name, cache => $cache, %args));
}

1;
