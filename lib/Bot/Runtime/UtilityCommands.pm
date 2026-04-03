package Bot::Runtime::UtilityCommands;

use strict;
use warnings;

use Exporter 'import';

our @EXPORT_OK = qw(
  handle_public_utility_command
);

sub handle_public_utility_command {
  my (%args) = @_;

  my $self  = $args{self};
  my $msg   = $args{msg} // '';
  my $chan  = $args{channel};
  my $style = $args{style} // 'strict';
  my $notes_mode = $args{notes_mode} // 'direct_only';

  my $handled = $style eq 'relaxed'
    ? _handle_relaxed_style($self, $chan, $msg)
    : _handle_strict_style($self, $chan, $msg);
  return 1 if $handled;

  $handled = _handle_persona_commands($self, $chan, $msg, $notes_mode);
  return $handled ? 1 : 0;
}

sub _send_if_non_empty {
  my ($self, $channel, $text) = @_;
  return unless defined($text) && $text =~ /\S/;
  $self->_send_to_channel($channel, $text);
}

sub _handle_persona_commands {
  my ($self, $channel, $msg, $notes_mode) = @_;

  if ($msg =~ /^(?:([A-Za-z0-9_\-]+):\s+persona\s+full\s*)$/i) {
    return 0 unless lc($1) eq lc($self->get_nickname);
    my $line = $self->_persona_text;
    $self->_send_to_channel($channel, $line);
    return 1;
  }

  if ($msg =~ /^([A-Za-z0-9_\-]+):\s+persona\s+set\s+(\S+)\s+(?:=\s*)?(\S+)\s*$/i) {
    return 0 unless lc($1) eq lc($self->get_nickname);
    my ($ok, $line) = $self->_set_persona_trait($2, $3);
    $self->_send_to_channel($channel, $line);
    return 1;
  }

  if ($msg =~ /^([A-Za-z0-9_\-]+):\s+persona\s+get\s+(\S+)\s*$/i) {
    return 0 unless lc($1) eq lc($self->get_nickname);
    my $line = $self->_persona_trait_text($2);
    $self->_send_to_channel($channel, $line);
    return 1;
  }

  if ($msg =~ /^([A-Za-z0-9_\-]+):\s+persona\s+(\S+)\s*$/i) {
    my ($target_nick, $arg) = ($1, $2);
    return 0 unless lc($target_nick) eq lc($self->get_nickname);
    my $token = lc($arg);
    return 1 if $token eq 'full' || $token eq 'set' || $token eq 'get';
    if ($arg =~ /^\d+$/) {
      my ($ok, $line) = $self->_apply_persona_preset($arg);
      $self->_send_to_channel($channel, $line);
      return 1;
    }
    my $line = $self->_persona_trait_text($arg);
    $self->_send_to_channel($channel, $line);
    return 1;
  }

  if ($msg =~ /^(?:([A-Za-z0-9_\-]+):\s+persona\s*)$/i) {
    return 0 unless lc($1) eq lc($self->get_nickname);
    my $line = $self->_persona_summary_text;
    $self->_send_to_channel($channel, $line);
    return 1;
  }

  if ($notes_mode eq 'utility_prefixed') {
    if ($msg =~ /^(?:([A-Za-z0-9_\-]+):\s+)?(?:notes:\s*|:notes\s+)(\S+)\s*$/i) {
      return 0 unless $self->_utility_command_matches_me($1);
      my $nick = $2;
      my $line = $self->_notes_text($nick);
      _send_if_non_empty($self, $channel, $line);
      return 1;
    }
  } else {
    if ($msg =~ /^([A-Za-z0-9_\-]+):\s+notes\s+(\S+)\s*$/i) {
      return 0 unless lc($1) eq lc($self->get_nickname);
      my $nick = $2;
      my $line = $self->_notes_text($nick);
      _send_if_non_empty($self, $channel, $line);
      return 1;
    }
  }

  return 0;
}

sub _handle_strict_style {
  my ($self, $channel, $msg) = @_;

  if ($msg =~ /^(?:([A-Za-z0-9_\-]+):\s+sum\s+|sum:\s*|:sum\s+)(https?:\/\/\S+)/i) {
    return 0 unless $self->_utility_command_matches_me($1);
    my $url = $2;
    my $result = $self->_summarize_url($url);
    _send_if_non_empty($self, $channel, $result);
    return 1;
  }

  if ($msg =~ /^(?:([A-Za-z0-9_\-]+):\s+time\s*|:time\s*|time:\s*)$/i) {
    return 0 unless $self->_utility_command_matches_me($1);
    my $line = 'Current local time: ' . $self->_current_local_time_text . '.';
    $self->_send_to_channel($channel, $line);
    return 1;
  }

  if ($msg =~ /^(?:([A-Za-z0-9_\-]+):\s+dbstats\s*|:dbstats\s*|dbstats:\s*)$/i) {
    return 0 unless $self->_utility_command_matches_me($1);
    my $line = $self->_db_stats_text;
    $self->_send_to_channel($channel, $line);
    return 1;
  }

  if ($msg =~ /^(?:([A-Za-z0-9_\-]+):\s+time\s+in\s+|:time\s+in\s+|time:\s*)([A-Za-z_]+\/[A-Za-z0-9_+\-]+(?:\/[A-Za-z0-9_+\-]+)*)\s*$/i) {
    return 0 unless $self->_utility_command_matches_me($1);
    my $zone = $2;
    my $line = 'Current time in ' . $zone . ': ' . $self->_time_text_for_zone($zone) . '.';
    $self->_send_to_channel($channel, $line);
    return 1;
  }

  if ($msg =~ /^(?:([A-Za-z0-9_\-]+):\s+cpan\s+recent(?:\s+(\d+))?\s*|:cpan\s+recent(?:\s+(\d+))?\s*|cpan:\s*recent(?:\s+(\d+))?\s*)$/i) {
    return 0 unless $self->_utility_command_matches_me($1);
    my $count = defined $2 ? $2 : (defined $3 ? $3 : 3);
    my $result = $self->_cpan_lookup('recent', $count);
    _send_if_non_empty($self, $channel, $result);
    return 1;
  }

  if ($msg =~ /^(?:([A-Za-z0-9_\-]+):\s+cpan\s+(module|author|describe)\s+(.+)|:cpan\s+(module|author|describe)\s+(.+)|cpan:\s*(module|author|describe)\s+(.+))$/i) {
    return 0 unless $self->_utility_command_matches_me($1);
    my ($mode, $query) = defined $2 ? ($2, $3) : (defined $4 ? ($4, $5) : ($6, $7));
    my $result = $self->_cpan_lookup($mode, $query);
    _send_if_non_empty($self, $channel, $result);
    return 1;
  }

  if ($msg =~ /^(?:([A-Za-z0-9_\-]+):\s+cpan\s+(.+)|:cpan\s+(.+)|cpan:\s*(.+))$/i) {
    return 0 unless $self->_utility_command_matches_me($1);
    my $query = defined $2 ? $2 : (defined $3 ? $3 : $4);
    $query =~ s/^\s+|\s+$//g;
    my $result = $self->_cpan_lookup('module', $query);
    _send_if_non_empty($self, $channel, $result);
    return 1;
  }

  if ($msg =~ /^(?:([A-Za-z0-9_\-]+):\s+search\s+|:search\s+|search:\s+)(.+)/i) {
    return 0 unless $self->_utility_command_matches_me($1);
    my $arg = $2;
    my ($count, $query) = (3, $arg);
    if ($arg =~ /^\s*(\d+)\s+(.+)\s*$/) {
      $count = $1;
      $query = $2;
    }
    $count = 1 if $count < 1;
    $count = 5 if $count > 5;
    my $result = $self->_search_web($query, $count);
    _send_if_non_empty($self, $channel, $result);
    return 1;
  }

  return 0;
}

sub _handle_relaxed_style {
  my ($self, $channel, $msg) = @_;

  if ($msg =~ /^(?:([A-Za-z0-9_\-]+):\s+)?(?:sum:\s*|:sum\s+)(https?:\/\/\S+)/i) {
    return 0 unless $self->_utility_command_matches_me($1);
    my $url = $2;
    my $result = $self->_summarize_url($url);
    _send_if_non_empty($self, $channel, $result);
    return 1;
  }

  if ($msg =~ /^(?:([A-Za-z0-9_\-]+):\s+)?(?::time\s*|time:\s*)$/i) {
    return 0 unless $self->_utility_command_matches_me($1);
    my $line = 'Current local time: ' . $self->_current_local_time_text . '.';
    $self->_send_to_channel($channel, $line);
    return 1;
  }

  if ($msg =~ /^(?:([A-Za-z0-9_\-]+):\s+)?(?::dbstats\s*|dbstats:\s*)$/i) {
    return 0 unless $self->_utility_command_matches_me($1);
    my $line = $self->_db_stats_text;
    $self->_send_to_channel($channel, $line);
    return 1;
  }

  if ($msg =~ /^(?:([A-Za-z0-9_\-]+):\s+)?(?::time\s+in\s+|time:\s*)([A-Za-z_]+\/[A-Za-z0-9_+\-]+(?:\/[A-Za-z0-9_+\-]+)*)\s*$/i) {
    return 0 unless $self->_utility_command_matches_me($1);
    my $zone = $2;
    my $line = 'Current time in ' . $zone . ': ' . $self->_time_text_for_zone($zone) . '.';
    $self->_send_to_channel($channel, $line);
    return 1;
  }

  if ($msg =~ /^(?:([A-Za-z0-9_\-]+):\s+)?(?::cpan\s+recent(?:\s+(\d+))?\s*|cpan:\s*recent(?:\s+(\d+))?\s*)$/i) {
    return 0 unless $self->_utility_command_matches_me($1);
    my $count = defined $2 ? $2 : (defined $3 ? $3 : 3);
    my $result = $self->_cpan_lookup('recent', $count);
    _send_if_non_empty($self, $channel, $result);
    return 1;
  }

  if ($msg =~ /^(?:([A-Za-z0-9_\-]+):\s+)?(?::cpan\s+(module|author|describe)\s+(.+)|cpan:\s*(module|author|describe)\s+(.+))$/i) {
    return 0 unless $self->_utility_command_matches_me($1);
    my ($mode, $query) = defined $2 ? ($2, $3) : ($4, $5);
    my $result = $self->_cpan_lookup($mode, $query);
    _send_if_non_empty($self, $channel, $result);
    return 1;
  }

  if ($msg =~ /^(?:([A-Za-z0-9_\-]+):\s+)?(?::cpan\s+(.+)|cpan:\s*(.+))$/i) {
    return 0 unless $self->_utility_command_matches_me($1);
    my $query = defined $2 ? $2 : $3;
    $query =~ s/^\s+|\s+$//g;
    my $result = $self->_cpan_lookup('module', $query);
    _send_if_non_empty($self, $channel, $result);
    return 1;
  }

  if ($msg =~ /^(?:([A-Za-z0-9_\-]+):\s+)?(?::search\s+|search:\s+)(.+)/i) {
    return 0 unless $self->_utility_command_matches_me($1);
    my $arg = $2;
    my ($count, $query) = (3, $arg);
    if ($arg =~ /^\s*(\d+)\s+(.+)\s*$/) {
      $count = $1;
      $query = $2;
    }
    $count = 1 if $count < 1;
    $count = 5 if $count > 5;
    my $result = $self->_search_web($query, $count);
    _send_if_non_empty($self, $channel, $result);
    return 1;
  }

  return 0;
}

1;
