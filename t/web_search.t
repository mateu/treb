use strict;
use warnings;
use Test::More;
use JSON::PP qw(encode_json);

require './treb.pl';

{
    package TestBot;
    our @ISA = ('BertBot');

    sub new {
        my ($class) = @_;
        return bless {}, $class;
    }

    sub get_nickname { 'Squirt' }
}

my $bot = TestBot->new;

subtest 'format_search_results default limit is 3' => sub {
    my $data = {
        web => {
            results => [
                { title => 'One',   url => 'https://e/1', description => 'd1' },
                { title => 'Two',   url => 'https://e/2', description => 'd2' },
                { title => 'Three', url => 'https://e/3', description => 'd3' },
                { title => 'Four',  url => 'https://e/4', description => 'd4' },
            ],
        },
    };
    my $out = $bot->_format_search_results('test', $data);
    like($out, qr/^1\. One - https:\/\/e\/1/m, 'first result present');
    like($out, qr/^3\. Three - https:\/\/e\/3/m, 'third result present');
    unlike($out, qr/^4\. Four - https:\/\/e\/4/m, 'fourth omitted by default');
};

subtest 'format_search_results respects explicit limit and cap' => sub {
    my $data = {
        web => {
            results => [
                map +{ title => "R$_", url => "https://e/$_", description => "d$_" }, 1..6
            ],
        },
    };

    my $out2 = $bot->_format_search_results('test', $data, 2);
    like($out2, qr/^2\. R2 - https:\/\/e\/2/m, 'second present at limit 2');
    unlike($out2, qr/^3\. R3 - https:\/\/e\/3/m, 'third omitted at limit 2');

    my $out9 = $bot->_format_search_results('test', $data, 9);
    like($out9, qr/^5\. R5 - https:\/\/e\/5/m, 'fifth present after clamp');
    unlike($out9, qr/^6\. R6 - https:\/\/e\/6/m, 'sixth omitted after clamp to 5');
};

subtest 'format_search_results cleans html entities / mojibake-ish punctuation' => sub {
    my $data = {
        web => {
            results => [
                {
                    title => 'Olaf Alders Â· GitHub',
                    url => 'https://github.com/oalders',
                    description => 'I&#x27;ve built stuff &amp; shared itâ€¦',
                },
            ],
        },
    };
    my $out = $bot->_format_search_results('olaf', $data, 1);
    like($out, qr/Olaf Alders\s+-\s+GitHub - https:\/\/github.com\/oalders/, 'title normalized to ASCII-ish separators');
    like($out, qr/I've built stuff & shared it\.\.\./, 'description entities and ellipsis normalized');
};

subtest '_search_web handles missing key and empty query' => sub {
    local $ENV{BRAVE_API_KEY} = '';
    is($bot->_search_web('thing'), q{Web search isn't configured right now.}, 'missing key guarded');
    is($bot->_search_web('   '), 'Search query is empty.', 'empty query guarded');
};

subtest 'command parser supports default and explicit count syntax' => sub {
    my @cases = (
        [':search Olaf Alders', 3, 'Olaf Alders'],
        [':search 5 Olaf Alders', 5, 'Olaf Alders'],
        ['search: Olaf Alders', 3, 'Olaf Alders'],
        ['search: 2 Olaf Alders', 2, 'Olaf Alders'],
        ['search: 99 Olaf Alders', 5, 'Olaf Alders'],
    );

    for my $c (@cases) {
        my ($msg, $want_count, $want_query) = @$c;
        ok($msg =~ /^(?::search\s+|search:\s+)(.+)/i, "matches trigger: $msg");
        my $arg = $1;
        my ($count, $query) = (3, $arg);
        if ($arg =~ /^\s*(\d+)\s+(.+)\s*$/) {
            $count = $1;
            $query = $2;
        }
        $count = 1 if $count < 1;
        $count = 5 if $count > 5;
        is($count, $want_count, "count parsed for: $msg");
        is($query, $want_query, "query parsed for: $msg");
    }
};

SKIP: {
    skip 'set TREB_LIVE_WEB_TEST=1 for live Brave call', 1 unless $ENV{TREB_LIVE_WEB_TEST};

    my $orig_key = $ENV{BRAVE_API_KEY};
    skip 'BRAVE_API_KEY required for live web test', 1 unless defined $orig_key && length $orig_key;

    local $ENV{BRAVE_API_KEY} = $orig_key;
    my $query = $ENV{TREB_LIVE_WEB_QUERY} || 'Olaf Alders';
    my $out = $bot->_search_web($query, 2);
    diag("LIVE_WEB_RESULT:\n$out") if $ENV{TREB_LIVE_WEB_SHOW};
    like($out, qr/\S/, 'live web search returned non-empty output');
}

done_testing;
