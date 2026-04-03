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

my @alarm_events;
{
    no warnings 'redefine';
    local *POE::Kernel::delay_add = sub {
        my ($class, @args) = @_;
        push @alarm_events, \@args;
        return scalar @alarm_events;
    };

    is(
        $tools{set_alarm}{code}->($tool, { reason => 'poke me', delay_seconds => 2 }),
        'Alarm set for 10s: poke me',
        'set_alarm clamps minimum delay'
    );
    is(
        $tools{set_alarm}{code}->($tool, { reason => 'someday', delay_seconds => 99999 }),
        'Alarm set for 3600s: someday',
        'set_alarm clamps maximum delay'
    );
    is(
        $tools{set_alarm}{code}->($tool, { reason => 'default', delay_seconds => 'bogus' }),
        'Alarm set for 10s: default',
        'set_alarm falls back to default on non-numeric delay'
    );
    is(
        $tools{set_alarm}{code}->($tool, { reason => '   ', delay_seconds => 60 }),
        'Reason is required.',
        'set_alarm requires non-empty reason'
    );
}
is_deeply($alarm_events[0], ['_alarm_fired', 10, '#test', 'poke me'], 'set_alarm schedules POE alarm with normalized delay');
is_deeply($alarm_events[1], ['_alarm_fired', 3600, '#test', 'someday'], 'set_alarm schedules clamped high delay');
is_deeply($alarm_events[2], ['_alarm_fired', 10, '#test', 'default'], 'set_alarm schedules default delay on invalid numeric input');

is($tools{cpan_module}{code}->($tool, { name => '  Moo  ' }), 'cpan:module:Moo', 'cpan_module delegates trimmed name');
is_deeply($bot->{cpan}[0], ['module', 'Moo'], 'cpan lookup called with mode and module');
is($tools{cpan_module}{code}->($tool, { name => '   ' }), 'Module name is required.', 'cpan_module rejects empty names');

is($tools{summarize_url}{code}->($tool, { url => '  https://example.com  ' }), 'summary:https://example.com', 'summarize_url delegates trimmed URL');
is_deeply($bot->{urls}, ['https://example.com'], 'summary delegate captured URL');
is($tools{summarize_url}{code}->($tool, { url => '   ' }), 'URL is empty.', 'summarize_url rejects empty URL');

$tools{search_web}{code}->($tool, { query => '  perl  ' });
is_deeply($bot->{web}[0], ['perl', 2], 'search_web uses default MCP limit 2');
$tools{search_web}{code}->($tool, { query => 'perl', limit => 77 });
is_deeply($bot->{web}[1], ['perl', 5], 'search_web clamps limit high bound');
$tools{search_web}{code}->($tool, { query => 'perl', limit => 0 });
is_deeply($bot->{web}[2], ['perl', 1], 'search_web clamps limit low bound');
$tools{search_web}{code}->($tool, { query => 'perl', limit => 'bogus' });
is_deeply($bot->{web}[3], ['perl', 2], 'search_web defaults to 2 on non-numeric limit');
is($tools{search_web}{code}->($tool, { query => '   ' }), 'Search query is empty.', 'search_web rejects empty query');

like($tools{current_time}{code}->($tool, {}), qr/^Current local time:/, 'current_time returns formatted line');
like($tools{time_in}{code}->($tool, { zone => '  Europe/London  ' }), qr/Europe\/London/, 'time_in trims zone');
is($tools{time_in}{code}->($tool, { zone => '   ' }), 'Timezone is required.', 'time_in rejects empty zone');

is($tools{recall_history}{code}->($tool, { query => 'deploy' }), 'history:deploy', 'recall_history delegates to memory');
is($tools{recall_history}{code}->($tool, { query => '   ' }), 'History query is required.', 'recall_history rejects empty query');
is($tools{save_note}{code}->($tool, { nick => '  alice  ', content => '  likes perl  ' }), 'Note saved about alice.', 'save_note trims nick and content');
is($tools{save_note}{code}->($tool, { nick => '  ', content => 'likes perl' }), 'Nick is required.', 'save_note requires nick');
is($tools{save_note}{code}->($tool, { nick => 'alice', content => '   ' }), 'Note content is required.', 'save_note requires content');
like($tools{recall_notes}{code}->($tool, { nick => 'alice' }), qr/likes perl/, 'recall_notes returns note content');
is($tools{update_note}{code}->($tool, { id => 7, content => 'updated' }), 'Note #7 updated.', 'update_note success path');
is($tools{update_note}{code}->($tool, { id => 0, content => 'updated' }), 'Note id must be a positive integer.', 'update_note validates id');
is($tools{update_note}{code}->($tool, { id => 7, content => '   ' }), 'Note content is required.', 'update_note validates content');
is($tools{delete_note}{code}->($tool, { id => 8 }), 'Note #8 deleted.', 'delete_note success path');
is($tools{delete_note}{code}->($tool, { id => 'bogus' }), 'Note id must be a positive integer.', 'delete_note validates id');

is($tools{send_private_message}{code}->($tool, { nick => '  alice  ', message => '  hello  ', reason => '  requested by bob  ' }), 'Private message sent to alice.', 'send_private_message trims fields');
is(scalar @{ $bot->{pms} }, 2, 'send_private_message sends message and reason');
is_deeply($bot->{pms}[0], ['alice', 'hello'], 'primary PM sent');
is_deeply($bot->{pms}[1], ['alice', '(reason: requested by bob)'], 'reason PM sent to trimmed nick');
is($tools{send_private_message}{code}->($tool, { nick => ' ', message => 'hello' }), 'Nick is required.', 'send_private_message requires nick');
is($tools{send_private_message}{code}->($tool, { nick => 'alice', message => '   ' }), 'Message is required.', 'send_private_message requires message');

like($tools{whois}{code}->($tool, { nick => '  alice  ' }), qr/WHOIS request sent/, 'whois trims nick and acknowledges request');
is_deeply($bot->{irc}{events}[0], ['whois', 'alice'], 'whois delegated to IRC client');
is($tools{whois}{code}->($tool, { nick => '   ' }), 'Nick is required.', 'whois requires nick');

done_testing;
