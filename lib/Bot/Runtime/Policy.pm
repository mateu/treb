package Bot::Runtime::Policy;

use strict;
use warnings;

use Exporter 'import';
use Bot::OutputCleanup qw(
  cleanup_log_preview
  cleanup_change_message
  cleanup_empty_message
);

our @EXPORT_OK = qw(
  mcp_tool_logging_enabled
  env_flag_enabled
  store_system_rows_enabled
  store_non_substantive_rows_enabled
  store_empty_response_rows_enabled
  cleanup_logging_enabled
  cleanup_log_preview_text
  log_cleanup_change
  log_cleanup_empty
);

sub mcp_tool_logging_enabled {
  return env_flag_enabled('MCP_TOOL_LOGGING', 1);
}

sub env_flag_enabled {
  my ($name, $default) = @_;
  my $raw = $ENV{$name};
  return $default if !defined $raw || $raw eq '';
  return 1 if $raw =~ /^(?:1|true|on|yes)$/i;
  return 0 if $raw =~ /^(?:0|false|off|no)$/i;
  return $default;
}

sub store_system_rows_enabled {
  return env_flag_enabled('STORE_SYSTEM_ROWS', 0);
}

sub store_non_substantive_rows_enabled {
  return env_flag_enabled('STORE_NON_SUBSTANTIVE_ROWS', 0);
}

sub store_empty_response_rows_enabled {
  return env_flag_enabled('STORE_EMPTY_RESPONSE_ROWS', 0);
}

sub cleanup_logging_enabled {
  return env_flag_enabled('CLEANUP_LOGGING', 0);
}

sub cleanup_log_preview_text {
  my ($text) = @_;
  return cleanup_log_preview($text);
}

sub log_cleanup_change {
  my (%args) = @_;
  my $self = $args{self} or die 'log_cleanup_change requires self';
  return unless cleanup_logging_enabled();
  my $msg = cleanup_change_message($args{label}, $args{before}, $args{after});
  return unless defined $msg;
  $self->info($msg);
}

sub log_cleanup_empty {
  my (%args) = @_;
  my $self = $args{self} or die 'log_cleanup_empty requires self';
  return unless cleanup_logging_enabled();
  $self->info(cleanup_empty_message($args{before}, $args{after}));
}

1;
