package Bot::Runtime::UtilityCommands;

use strict;
use warnings;

use Exporter 'import';
our @EXPORT_OK = qw(parse_utility_command);

sub parse_utility_command {
  my (%args) = @_;
  my $msg = $args{msg};
  return undef unless defined $msg;

  my $profile = lc($args{profile} // 'treb');
  if ($profile eq 'treb') {
    return _parse_treb($msg);
  }
  if ($profile eq 'burt') {
    return _parse_optional_target($msg, notes_optional_target => 0);
  }
  if ($profile eq 'astrid') {
    return _parse_optional_target($msg, notes_optional_target => 1);
  }

  die "Unknown utility command parser profile: $profile";
}

sub _parse_treb {
  my ($msg) = @_;

  if ($msg =~ /^(?:([A-Za-z0-9_\-]+):\s+sum\s+|sum:\s*|:sum\s+)(https?:\/\/\S+)/i) {
    return { type => 'sum', target => $1, url => $2 };
  }

  if ($msg =~ /^(?:([A-Za-z0-9_\-]+):\s+time\s*|:time\s*|time:\s*)$/i) {
    return { type => 'time', target => $1 };
  }

  if ($msg =~ /^(?:([A-Za-z0-9_\-]+):\s+dbstats\s*|:dbstats\s*|dbstats:\s*)$/i) {
    return { type => 'dbstats', target => $1 };
  }

  if ($msg =~ /^(?:([A-Za-z0-9_\-]+):\s+persona\s+full\s*)$/i) {
    return { type => 'persona_full', target => $1 };
  }

  if ($msg =~ /^([A-Za-z0-9_\-]+):\s+persona\s+set\s+(\S+)\s+(?:=\s*)?(\S+)\s*$/i) {
    return { type => 'persona_set', target => $1, key => $2, value => $3 };
  }

  if ($msg =~ /^([A-Za-z0-9_\-]+):\s+persona\s+get\s+(\S+)\s*$/i) {
    return { type => 'persona_get', target => $1, key => $2 };
  }

  if ($msg =~ /^([A-Za-z0-9_\-]+):\s+persona\s+(\S+)\s*$/i) {
    return { type => 'persona_arg', target => $1, arg => $2 };
  }

  if ($msg =~ /^(?:([A-Za-z0-9_\-]+):\s+persona\s*)$/i) {
    return { type => 'persona_summary', target => $1 };
  }

  if ($msg =~ /^([A-Za-z0-9_\-]+):\s+notes\s+(\S+)\s*$/i) {
    return { type => 'notes', target => $1, nick => $2 };
  }

  if ($msg =~ /^(?:([A-Za-z0-9_\-]+):\s+time\s+in\s+|:time\s+in\s+|time:\s*)([A-Za-z_]+\/[A-Za-z0-9_+\-]+(?:\/[A-Za-z0-9_+\-]+)*)\s*$/i) {
    return { type => 'time_in', target => $1, zone => $2 };
  }

  if ($msg =~ /^(?:([A-Za-z0-9_\-]+):\s+cpan\s+recent(?:\s+(\d+))?\s*|:cpan\s+recent(?:\s+(\d+))?\s*|cpan:\s*recent(?:\s+(\d+))?\s*)$/i) {
    my $count = defined $2 ? $2 : (defined $3 ? $3 : (defined $4 ? $4 : 3));
    return { type => 'cpan_recent', target => $1, count => $count };
  }

  if ($msg =~ /^(?:([A-Za-z0-9_\-]+):\s+cpan\s+(module|author|describe)\s+(.+)|:cpan\s+(module|author|describe)\s+(.+)|cpan:\s*(module|author|describe)\s+(.+))$/i) {
    my ($mode, $query) = defined $2 ? ($2, $3) : (defined $4 ? ($4, $5) : ($6, $7));
    return { type => 'cpan_lookup', target => $1, mode => $mode, query => $query };
  }

  if ($msg =~ /^(?:([A-Za-z0-9_\-]+):\s+cpan\s+(.+)|:cpan\s+(.+)|cpan:\s*(.+))$/i) {
    my $query = defined $2 ? $2 : (defined $3 ? $3 : $4);
    $query =~ s/^\s+|\s+$//g;
    return { type => 'cpan_lookup', target => $1, mode => 'module', query => $query };
  }

  if ($msg =~ /^(?:([A-Za-z0-9_\-]+):\s+search\s+|:search\s+|search:\s+)(.+)/i) {
    my $arg = $2;
    my ($count, $query) = (3, $arg);
    if ($arg =~ /^\s*(\d+)\s+(.+)\s*$/) {
      $count = $1;
      $query = $2;
    }
    return { type => 'search', target => $1, count => $count, query => $query };
  }

  return undef;
}

sub _parse_optional_target {
  my ($msg, %opts) = @_;

  if ($msg =~ /^(?:([A-Za-z0-9_\-]+):\s+)?(?:sum:\s*|:sum\s+)(https?:\/\/\S+)/i) {
    return { type => 'sum', target => $1, url => $2 };
  }

  if ($msg =~ /^(?:([A-Za-z0-9_\-]+):\s+)?(?::time\s*|time:\s*)$/i) {
    return { type => 'time', target => $1 };
  }

  if ($msg =~ /^(?:([A-Za-z0-9_\-]+):\s+)?(?::dbstats\s*|dbstats:\s*)$/i) {
    return { type => 'dbstats', target => $1 };
  }

  if ($msg =~ /^(?:([A-Za-z0-9_\-]+):\s+persona\s+full\s*)$/i) {
    return { type => 'persona_full', target => $1 };
  }

  if ($msg =~ /^([A-Za-z0-9_\-]+):\s+persona\s+set\s+(\S+)\s+(?:=\s*)?(\S+)\s*$/i) {
    return { type => 'persona_set', target => $1, key => $2, value => $3 };
  }

  if ($msg =~ /^([A-Za-z0-9_\-]+):\s+persona\s+get\s+(\S+)\s*$/i) {
    return { type => 'persona_get', target => $1, key => $2 };
  }

  if ($msg =~ /^([A-Za-z0-9_\-]+):\s+persona\s+(\S+)\s*$/i) {
    return { type => 'persona_arg', target => $1, arg => $2 };
  }

  if ($msg =~ /^(?:([A-Za-z0-9_\-]+):\s+persona\s*)$/i) {
    return { type => 'persona_summary', target => $1 };
  }

  if ($opts{notes_optional_target}) {
    if ($msg =~ /^(?:([A-Za-z0-9_\-]+):\s+)?(?:notes:\s*|:notes\s+)(\S+)\s*$/i) {
      return { type => 'notes', target => $1, nick => $2 };
    }
  } else {
    if ($msg =~ /^([A-Za-z0-9_\-]+):\s+notes\s+(\S+)\s*$/i) {
      return { type => 'notes', target => $1, nick => $2 };
    }
  }

  if ($msg =~ /^(?:([A-Za-z0-9_\-]+):\s+)?(?::time\s+in\s+|time:\s*)([A-Za-z_]+\/[A-Za-z0-9_+\-]+(?:\/[A-Za-z0-9_+\-]+)*)\s*$/i) {
    return { type => 'time_in', target => $1, zone => $2 };
  }

  if ($msg =~ /^(?:([A-Za-z0-9_\-]+):\s+)?(?::cpan\s+recent(?:\s+(\d+))?\s*|cpan:\s*recent(?:\s+(\d+))?\s*)$/i) {
    my $count = defined $2 ? $2 : (defined $3 ? $3 : 3);
    return { type => 'cpan_recent', target => $1, count => $count };
  }

  if ($msg =~ /^(?:([A-Za-z0-9_\-]+):\s+)?(?::cpan\s+(module|author|describe)\s+(.+)|cpan:\s*(module|author|describe)\s+(.+))$/i) {
    my ($mode, $query) = defined $2 ? ($2, $3) : ($4, $5);
    return { type => 'cpan_lookup', target => $1, mode => $mode, query => $query };
  }

  if ($msg =~ /^(?:([A-Za-z0-9_\-]+):\s+)?(?::cpan\s+(.+)|cpan:\s*(.+))$/i) {
    my $query = defined $2 ? $2 : $3;
    $query =~ s/^\s+|\s+$//g;
    return { type => 'cpan_lookup', target => $1, mode => 'module', query => $query };
  }

  if ($msg =~ /^(?:([A-Za-z0-9_\-]+):\s+)?(?::search\s+|search:\s+)(.+)/i) {
    my $arg = $2;
    my ($count, $query) = (3, $arg);
    if ($arg =~ /^\s*(\d+)\s+(.+)\s*$/) {
      $count = $1;
      $query = $2;
    }
    return { type => 'search', target => $1, count => $count, query => $query };
  }

  return undef;
}

1;
