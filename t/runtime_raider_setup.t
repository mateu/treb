use strict;
use warnings;
use Test::More;

use lib 't/lib', 'lib';
use Bot::Runtime::RaiderSetup (qw(setup_raider));

{
    package IO::Async::Loop::POE;

    sub new { bless { added => [] }, shift }
    sub add {
        my ($self, $item) = @_;
        push @{ $self->{added} }, $item;
        return 1;
    }
    sub await {
        my ($self, $future) = @_;
        return 1;
    }
}

{
    package TestRuntimeFuture;

    sub new { bless {}, shift }
    sub get { return 1 }
}

{
    package Net::Async::MCP;

    sub new {
        my ($class, %args) = @_;
        return bless {
            server      => $args{server},
            initialized => 0,
        }, $class;
    }

    sub initialize {
        my ($self) = @_;
        $self->{initialized} = 1;
        return TestRuntimeFuture->new;
    }
}

{
    package Langertha::Engine::Groq;

    sub new {
        my ($class, %args) = @_;
        return bless { %args }, $class;
    }

    sub model { return $_[0]->{model} }
}

{
    package Langertha::Engine::Ollama;

    sub new {
        my ($class, %args) = @_;
        return bless { %args }, $class;
    }

    sub model { return $_[0]->{model} }
}

{
    package Langertha::Raider;

    sub new {
        my ($class, %args) = @_;
        return bless { %args }, $class;
    }
}

{
    package Bot::Mission;

    sub load_mission_for_script {
        my (%args) = @_;
        return { mission_args => \%args };
    }
}

{
    package TestRuntimeSetupBot;

    sub new {
        my ($class) = @_;
        return bless {
            mcp_server => { name => 'unit-tools' },
            nickname   => 'Bert',
            channels   => ['#ai', '#bots'],
            infos      => [],
        }, $class;
    }

    sub _build_mcp_server { return $_[0]->{mcp_server} }
    sub get_nickname { return $_[0]->{nickname} }
    sub get_channels { return @{ $_[0]->{channels} } }

    sub _mcp {
        my ($self, $value) = @_;
        $self->{mcp} = $value if @_ > 1;
        return $self->{mcp};
    }

    sub _raider {
        my ($self, $value) = @_;
        $self->{raider} = $value if @_ > 1;
        return $self->{raider};
    }

    sub info {
        my ($self, $line) = @_;
        push @{ $self->{infos} }, $line;
        return 1;
    }
}

subtest 'setup_raider wires mcp, mission, and raider with defaults' => sub {
    local %ENV = %ENV;
    delete @ENV{qw(ENGINE MODEL API_KEY OLLAMA_URL SYSTEM_PROMPT)};

    my @loaded;
    no warnings 'redefine';
    local *Bot::Runtime::RaiderSetup::use_module = sub {
        my ($class) = @_;
        push @loaded, $class;
        return 1;
    };

    my $bot = TestRuntimeSetupBot->new;
    my $raider = setup_raider(
        self        => $bot,
        owner       => 'Getty',
        max_line    => 400,
        script_file => '/tmp/treb.pl',
    );

    ok($bot->{mcp}, 'mcp object stored on bot');
    is($bot->{mcp}{server}{name}, 'unit-tools', 'mcp initialized with built server');
    ok($bot->{mcp}{initialized}, 'mcp initialize awaited');

    ok($raider, 'raider returned');
    is($raider->{max_context_tokens}, 8192, 'default max context tokens used');
    is($raider->{engine}{model}, 'llama-3.3-70b-versatile', 'default model applied');
    is_deeply($raider->{engine}{mcp_servers}, [$bot->{mcp}], 'engine receives mcp server list');

    my $mission = $raider->{mission}{mission_args};
    is($mission->{script_file}, '/tmp/treb.pl', 'mission uses provided script path');
    is($mission->{owner}, 'Getty', 'mission owner set');
    is($mission->{nick}, 'Bert', 'mission nick from bot');
    is($mission->{provider}, 'Groq', 'provider derived from engine class');
    is($mission->{channels}, '#ai, #bots', 'channels joined into mission payload');

    like($bot->{infos}[0], qr/^Raider ready: Langertha::Engine::Groq/, 'ready log line emitted');

    is_deeply(
        \@loaded,
        [
            'IO::Async::Loop::POE',
            'Net::Async::MCP',
            'Langertha::Engine::Groq',
            'Bot::Mission',
            'Langertha::Raider',
        ],
        'runtime classes loaded via use_module',
    );
};

subtest 'setup_raider respects Ollama-specific args and custom context' => sub {
    local %ENV = %ENV;
    $ENV{ENGINE} = 'Ollama';
    $ENV{MODEL} = 'kimi-k2.5:cloud';
    $ENV{API_KEY} = 'test-key';
    $ENV{OLLAMA_URL} = 'http://127.0.0.1:11434';
    $ENV{SYSTEM_PROMPT} = 'be concise';

    no warnings 'redefine';
    local *Bot::Runtime::RaiderSetup::use_module = sub { return 1 };

    my $bot = TestRuntimeSetupBot->new;
    my $raider = setup_raider(
        self               => $bot,
        owner              => 'mateu',
        max_line           => 320,
        max_context_tokens => 4096,
        script_file        => '/tmp/astrid.pl',
    );

    is($raider->{engine}{model}, 'kimi-k2.5:cloud', 'explicit model propagated');
    is($raider->{engine}{api_key}, 'test-key', 'api key propagated');
    is($raider->{engine}{url}, 'http://127.0.0.1:11434', 'ollama url propagated');
    is($raider->{max_context_tokens}, 4096, 'custom context token cap applied');

    my $mission = $raider->{mission}{mission_args};
    is($mission->{mission_extra}, 'be concise', 'system prompt appended to mission');
    is($mission->{provider}, 'Ollama', 'provider derived from Ollama engine class');
};

done_testing;
