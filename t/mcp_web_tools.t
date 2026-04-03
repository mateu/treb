use strict;
use warnings;
use Test::More;

require './treb.pl';

{
    package TestMcpWebBot;
    our @ISA = ('BertBot');

    sub new { bless {}, shift }
    sub _mcp_tool_logging_enabled { 0 }

    sub _summarize_url {
        my ($self, $url) = @_;
        $self->{_last_summary_url} = $url;
        return "summary:$url";
    }

    sub _search_web {
        my ($self, $query, $limit) = @_;
        $self->{_last_search} = [$query, $limit];
        return "search:$query:$limit";
    }
}

{
    package TestMcpTool;
    sub new { bless {}, shift }
    sub text_result { return $_[1] }
}

my $bot = TestMcpWebBot->new;
my $server = $bot->_build_mcp_server;
ok($server, 'built mcp server');

my ($sum_tool) = grep { $_->{name} && $_->{name} eq 'summarize_url' } @{ $server->{tools} || [] };
ok($sum_tool, 'summarize_url tool registered');
like($sum_tool->{description} || '', qr/summarize/i, 'summarize_url description present');

my ($search_tool) = grep { $_->{name} && $_->{name} eq 'search_web' } @{ $server->{tools} || [] };
ok($search_tool, 'search_web tool registered');
like($search_tool->{description} || '', qr/defaults to 2/i, 'search_web description documents default limit');

subtest 'summarize_url delegates to _summarize_url' => sub {
    my $tool = TestMcpTool->new;
    my $out = $sum_tool->{code}->($tool, { url => '  https://example.com/post  ' });
    is($bot->{_last_summary_url}, 'https://example.com/post', 'URL is trimmed before delegation');
    is($out, 'summary:https://example.com/post', 'delegated summary returned');
};

subtest 'search_web delegates with MCP default limit=2' => sub {
    my $tool = TestMcpTool->new;
    my $out = $search_tool->{code}->($tool, { query => '  perl mcp  ' });
    is_deeply($bot->{_last_search}, ['perl mcp', 2], 'query trimmed and default limit set to 2');
    is($out, 'search:perl mcp:2', 'delegated search returned');
};

subtest 'search_web clamps limits to 1..5' => sub {
    my $tool = TestMcpTool->new;

    $search_tool->{code}->($tool, { query => 'x', limit => 0 });
    is_deeply($bot->{_last_search}, ['x', 1], 'lower bound enforced');

    $search_tool->{code}->($tool, { query => 'x', limit => 99 });
    is_deeply($bot->{_last_search}, ['x', 5], 'upper bound enforced');

    $search_tool->{code}->($tool, { query => 'x', limit => -1 });
    is_deeply($bot->{_last_search}, ['x', 1], 'negative limit clamped to 1');

    $search_tool->{code}->($tool, { query => 'x', limit => 'abc' });
    is_deeply($bot->{_last_search}, ['x', 2], 'non-numeric limit defaults to 2');
};

done_testing;
