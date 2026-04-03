use strict;
use warnings;
use Test::More;

use lib 'lib';
use Bot::OutputCleanup qw(cleanup_change_message cleanup_empty_message cleanup_log_preview);
use Bot::Runtime::Policy qw(
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

{
    package TestPolicyBot;

    sub new { bless { info => [] }, shift }
    sub info {
        my ($self, $msg) = @_;
        push @{ $self->{info} }, $msg;
        return 1;
    }
}

{
    local $ENV{MCP_TOOL_LOGGING};
    ok(mcp_tool_logging_enabled(), 'MCP tool logging enabled by default');
}

for my $value (qw(0 false off no)) {
    local $ENV{MCP_TOOL_LOGGING} = $value;
    ok(!mcp_tool_logging_enabled(), "MCP tool logging disabled by $value");
}

{
    local $ENV{MCP_TOOL_LOGGING} = 'true';
    ok(mcp_tool_logging_enabled(), 'MCP tool logging enabled by true');
}

{
    local $ENV{STORE_SYSTEM_ROWS};
    is(env_flag_enabled('STORE_SYSTEM_ROWS', 0), 0, 'env flag falls back to default value');
}
{
    local $ENV{STORE_SYSTEM_ROWS} = 'yes';
    is(env_flag_enabled('STORE_SYSTEM_ROWS', 0), 1, 'env flag parses true values');
}
{
    local $ENV{STORE_SYSTEM_ROWS} = 'no';
    is(env_flag_enabled('STORE_SYSTEM_ROWS', 1), 0, 'env flag parses false values');
}
{
    local $ENV{STORE_SYSTEM_ROWS} = 'weird';
    is(env_flag_enabled('STORE_SYSTEM_ROWS', 1), 1, 'env flag keeps default for unknown values');
}

{
    local $ENV{STORE_SYSTEM_ROWS};
    ok(!store_system_rows_enabled(), 'store_system_rows defaults to false');
}
{
    local $ENV{STORE_NON_SUBSTANTIVE_ROWS} = '1';
    ok(store_non_substantive_rows_enabled(), 'store_non_substantive_rows can be enabled');
}
{
    local $ENV{STORE_EMPTY_RESPONSE_ROWS} = 'true';
    ok(store_empty_response_rows_enabled(), 'store_empty_response_rows can be enabled');
}

{
    local $ENV{CLEANUP_LOGGING};
    ok(!cleanup_logging_enabled(), 'cleanup logging defaults to false');
}
{
    local $ENV{CLEANUP_LOGGING} = 'on';
    ok(cleanup_logging_enabled(), 'cleanup logging can be enabled');
}

{
    my $text = "line 1\nline 2\nline 3";
    is(cleanup_log_preview_text($text), cleanup_log_preview($text), 'preview formatting delegated to output cleanup');
}

{
    local $ENV{CLEANUP_LOGGING} = '0';
    my $bot = TestPolicyBot->new;
    log_cleanup_change(
        self   => $bot,
        label  => 'normalize_text',
        before => 'before',
        after  => 'after',
    );
    is_deeply($bot->{info}, [], 'log_cleanup_change does not emit when disabled');
}

{
    local $ENV{CLEANUP_LOGGING} = '1';
    my $bot = TestPolicyBot->new;
    log_cleanup_change(
        self   => $bot,
        label  => 'normalize_text',
        before => 'before',
        after  => 'after',
    );
    is_deeply(
        $bot->{info},
        [cleanup_change_message('normalize_text', 'before', 'after')],
        'log_cleanup_change emits cleanup change message',
    );
}

{
    local $ENV{CLEANUP_LOGGING} = '1';
    my $bot = TestPolicyBot->new;
    log_cleanup_empty(
        self   => $bot,
        before => '  answer  ',
        after  => '',
    );
    is_deeply(
        $bot->{info},
        [cleanup_empty_message('  answer  ', '')],
        'log_cleanup_empty emits cleanup empty message',
    );
}

done_testing;
