use strict;
use warnings;
use Test::More;

use lib 'lib';
use Bot::Runtime::MethodDelegates qw(install_shared_delegates);

{
    package TestDelegateBot;

    sub new { bless {}, shift }
}

my @installed = install_shared_delegates('TestDelegateBot');
ok(@installed >= 10, 'delegates installed');
ok(TestDelegateBot->can('_time_text_for_zone'), 'time delegate installed');
ok(TestDelegateBot->can('_cpan_lookup'), 'cpan delegate installed');

my $bot = TestDelegateBot->new;

{
    no warnings 'redefine';
    local *Bot::Commands::Time::time_text_for_zone = sub {
        my ($zone) = @_;
        return "zone:$zone";
    };
    local *Bot::Commands::Time::current_local_time_text = sub {
        return 'now';
    };
    local *Bot::OutputCleanup::repair_mojibake_text = sub {
        my ($text) = @_;
        return "repair:$text";
    };
    local *Bot::OutputCleanup::clean_text_for_irc = sub {
        my ($text) = @_;
        return "clean:$text";
    };
    local *Bot::OutputCleanup::is_non_substantive_output = sub {
        my ($text) = @_;
        return $text eq 'meh' ? 1 : 0;
    };
    local *Bot::Commands::CPAN::_cpan_lookup = sub {
        my ($self, $mode, $name) = @_;
        return join(':', 'cpan', ref($self), $mode, $name);
    };
    local *Bot::Runtime::WebTools::search_web = sub {
        my ($self, $query, $limit) = @_;
        return join(':', 'web', ref($self), $query, $limit);
    };

    is($bot->_time_text_for_zone('Europe/London'), 'zone:Europe/London', 'time delegate strips invocant');
    is($bot->_current_local_time_text, 'now', 'current_local_time delegate strips invocant');
    is($bot->_repair_mojibake_text('caf?'), 'repair:caf?', 'repair delegate strips invocant');
    is($bot->_clean_text_for_irc('line'), 'clean:line', 'clean delegate strips invocant');
    ok($bot->_is_non_substantive_output('meh'), 'non substantive delegate strips invocant');
    is(
        $bot->_cpan_lookup('module', 'Moo'),
        'cpan:TestDelegateBot:module:Moo',
        'cpan delegate forwards invocant and args',
    );
    is(
        $bot->_search_web('perl', 2),
        'web:TestDelegateBot:perl:2',
        'web delegate forwards invocant and args',
    );
}

{
    package TestDelegateBurtBot;

    sub _is_non_substantive_output { return 'custom' }
}

install_shared_delegates('TestDelegateBurtBot');
is(
    TestDelegateBurtBot->_is_non_substantive_output('meh'),
    'custom',
    'existing methods are not overwritten by shared delegates',
);

done_testing;
