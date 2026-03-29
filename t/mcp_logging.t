use strict;
use warnings;
use Test::More;

require './treb.pl';

my $obj = bless {}, 'BertBot';

{
    local $ENV{MCP_TOOL_LOGGING};
    ok($obj->_mcp_tool_logging_enabled, 'default is enabled');
}
{
    local $ENV{MCP_TOOL_LOGGING} = '1';
    ok($obj->_mcp_tool_logging_enabled, '1 enables logging');
}
{
    local $ENV{MCP_TOOL_LOGGING} = 'true';
    ok($obj->_mcp_tool_logging_enabled, 'true enables logging');
}
for my $v (qw(0 false off no)) {
    local $ENV{MCP_TOOL_LOGGING} = $v;
    ok(!$obj->_mcp_tool_logging_enabled, "$v disables logging");
}

done_testing;
