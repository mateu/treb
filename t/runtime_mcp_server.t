use strict;
use warnings;
use Test::More;

use lib 't/lib', 'lib';
use Bot::Runtime::MCPServer qw(build_mcp_server);

{
    package TestRuntimeMemory;

    sub new { bless { notes => {} }, shift }
    sub recall { my ($self, $q) = @_; return "history:$q" }
    sub save_note {
        my ($self, $nick, $content) = @_;
        push @{ $self->{notes}{$nick} ||= [] }, $content;
        return 1;
    }
    sub recall_notes {
        my ($self, $nick, $query) = @_;
        my @rows;
        if (defined $nick && length $nick) {
            @rows = @{ $self->{notes}{$nick} || [] };
        }
        else {
            @rows = map { @$_ } values %{ $self->{notes} };
        }
        if (defined $query && length $query) {
            @rows = grep { index($_, $query) >= 0 } @rows;
        }
        return @rows ? join(' | ', @rows) : '';
    }
    sub update_note { return $_[1] == 7 ? 1 : 0 }
    sub delete_note { return $_[1] == 8 ? 1 : 0 }
}

{
    package TestRuntimeIRC;

    sub new { bless { events => [] }, shift }
    sub yield {
        my ($self, @args) = @_;
        push @{ $self->{events} }, \@args;
        return 1;
    }
}

{
    package TestRuntimeTool;

    sub new { bless {}, shift }
    sub text_result { return $_[1] }
}

{
    package TestRuntimeBot;

    sub new {
        my ($class) = @_;
        my $self = bless {
            memory  => TestRuntimeMemory->new,
            irc     => TestRuntimeIRC->new,
            infos   => [],
            pms     => [],
            cpan    => [],
            urls    => [],
            web     => [],
        }, $class;
        return $self;
    }

    sub _default_channel { return '#test' }
    sub _mcp_tool_logging_enabled { return 1 }
    sub _cpan_lookup {
        my ($self, $mode, $name) = @_;
        push @{ $self->{cpan} }, [$mode, $name];
        return "cpan:$mode:$name";
    }
    sub _summarize_url {
        my ($self, $url) = @_;
        push @{ $self->{urls} }, $url;
        return "summary:$url";
    }
    sub _search_web {
        my ($self, $query, $limit) = @_;
        push @{ $self->{web} }, [$query, $limit];
        return "search:$query:$limit";
    }
    sub _current_local_time_text { return '2026-04-03 09:10 MDT' }
    sub _time_text_for_zone {
        my ($self, $zone) = @_;
        return "zone:$zone";
    }
    sub memory { return $_[0]->{memory} }
    sub irc { return $_[0]->{irc} }
    sub info {
        my ($self, $line) = @_;
        push @{ $self->{infos} }, $line;
        return 1;
    }
    sub privmsg {
        my ($self, $nick, $msg) = @_;
        push @{ $self->{pms} }, [$nick, $msg];
        return 1;
    }
}

my $bot = TestRuntimeBot->new;
my $tool = TestRuntimeTool->new;
my $server = build_mcp_server(self => $bot, server_name => 'unit-tools');
ok($server, 'server built');
is($server->{name}, 'unit-tools', 'server name set from argument');

my %tools = map { ($_->{name} => $_) } @{ $server->{tools} || [] };
for my $name (qw(
    stay_silent set_alarm cpan_module summarize_url search_web current_time time_in
    recall_history save_note recall_notes update_note delete_note send_private_message whois
)) {
    ok($tools{$name}, "$name tool registered");
}

is($tools{stay_silent}{code}->($tool, { reason => 'n/a' }), '__SILENT__', 'stay_silent emits sentinel');

is($tools{cpan_module}{code}->($tool, { name => '  Moo  ' }), 'cpan:module:Moo', 'cpan_module delegates trimmed name');
is_deeply($bot->{cpan}[0], ['module', 'Moo'], 'cpan lookup called with mode and module');

is($tools{summarize_url}{code}->($tool, { url => '  https://example.com  ' }), 'summary:https://example.com', 'summarize_url delegates trimmed URL');
is_deeply($bot->{urls}, ['https://example.com'], 'summary delegate captured URL');

$tools{search_web}{code}->($tool, { query => '  perl  ' });
is_deeply($bot->{web}[0], ['perl', 2], 'search_web uses default MCP limit 2');
$tools{search_web}{code}->($tool, { query => 'perl', limit => 77 });
is_deeply($bot->{web}[1], ['perl', 5], 'search_web clamps limit high bound');
$tools{search_web}{code}->($tool, { query => 'perl', limit => 0 });
is_deeply($bot->{web}[2], ['perl', 1], 'search_web clamps limit low bound');

like($tools{current_time}{code}->($tool, {}), qr/^Current local time:/, 'current_time returns formatted line');
like($tools{time_in}{code}->($tool, { zone => 'Europe/London' }), qr/Europe\/London/, 'time_in includes zone');

is($tools{recall_history}{code}->($tool, { query => 'deploy' }), 'history:deploy', 'recall_history delegates to memory');
is($tools{save_note}{code}->($tool, { nick => 'alice', content => 'likes perl' }), 'Note saved about alice.', 'save_note acknowledges write');
like($tools{recall_notes}{code}->($tool, { nick => 'alice' }), qr/likes perl/, 'recall_notes returns note content');
is($tools{update_note}{code}->($tool, { id => 7, content => 'updated' }), 'Note #7 updated.', 'update_note success path');
is($tools{delete_note}{code}->($tool, { id => 8 }), 'Note #8 deleted.', 'delete_note success path');

is($tools{send_private_message}{code}->($tool, { nick => 'alice', message => 'hello', reason => 'requested by bob' }), 'Private message sent to alice.', 'send_private_message acknowledges send');
is(scalar @{ $bot->{pms} }, 2, 'send_private_message sends message and reason');
is_deeply($bot->{pms}[0], ['alice', 'hello'], 'primary PM sent');

like($tools{whois}{code}->($tool, { nick => 'alice' }), qr/WHOIS request sent/, 'whois acknowledges request');
is_deeply($bot->{irc}{events}[0], ['whois', 'alice'], 'whois delegated to IRC client');

done_testing;
