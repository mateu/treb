use strict;
use warnings;
use Test::More;

require './treb.pl';

my $bot = bless {}, 'BertBot';

{
    local $ENV{STORE_SYSTEM_ROWS} = undef;
    ok(!$bot->_store_system_rows_enabled, 'system rows disabled by default');
}

{
    local $ENV{STORE_SYSTEM_ROWS} = '1';
    ok($bot->_store_system_rows_enabled, 'system rows can be enabled');
}

{
    local $ENV{STORE_NON_SUBSTANTIVE_ROWS} = undef;
    ok(!$bot->_store_non_substantive_rows_enabled, 'non-substantive rows disabled by default');
}

{
    local $ENV{STORE_NON_SUBSTANTIVE_ROWS} = 'yes';
    ok($bot->_store_non_substantive_rows_enabled, 'non-substantive rows can be enabled');
}

{
    local $ENV{STORE_EMPTY_RESPONSE_ROWS} = undef;
    ok(!$bot->_store_empty_response_rows_enabled, 'empty-response rows disabled by default');
}

{
    local $ENV{STORE_EMPTY_RESPONSE_ROWS} = 'true';
    ok($bot->_store_empty_response_rows_enabled, 'empty-response rows can be enabled');
}

ok($bot->_is_non_substantive_output('(quietly observes the tuning)'), 'known fluff still classifies non-substantive');
ok(!$bot->_is_non_substantive_output('Current local time: Sunday, March 29, 2026, 10:00 AM MDT (America/Denver).'), 'useful content not classified non-substantive');

done_testing;
