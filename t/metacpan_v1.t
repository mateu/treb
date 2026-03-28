use strict;
use warnings;
use Test::More;

require './treb.pl';

{
    package TestMetaBot;
    our @ISA = ('BertBot');
    sub new_minimal { bless {}, shift }
}

my $bot = TestMetaBot->new_minimal;

subtest 'module formatter' => sub {
    my $out = $bot->_format_cpan_module_result('Moo', {
        documentation => 'Moo',
        distribution  => 'Moo',
        author        => 'HAARG',
        abstract      => 'Minimalist object orientation for Perl',
    });
    like($out, qr/^Moo - Minimalist object orientation for Perl/, 'module summary present');
    like($out, qr/Dist: Moo\./, 'distribution included');
    like($out, qr/Author: HAARG\./, 'author included');
    like($out, qr{https://metacpan.org/pod/Moo}, 'doc URL included');
};

subtest 'author formatter' => sub {
    my $out = $bot->_format_cpan_author_result('OALDERS', {
        pauseid => 'OALDERS',
        name    => 'Olaf Alders',
    });
    is($out, 'OALDERS - Olaf Alders - https://metacpan.org/author/OALDERS', 'author output exact');
};

subtest 'recent formatter dedups exact distributions, respects limit, and includes version when present' => sub {
    my $out = $bot->_format_cpan_recent_results({
        hits => {
            hits => [
                { _source => { distribution => 'Mojolicious', author => 'SRI', version => '9.42', date => '2026-03-10T00:00:00' } },
                { _source => { distribution => 'Mojolicious', author => 'SRI', version => '9.41', date => '2026-03-09T00:00:00' } },
                { _source => { distribution => 'Mojo-Pg',     author => 'SRI', date => '2026-03-08T00:00:00' } },
                { _source => { distribution => 'OpenAPI-Modern', author => 'ETHER', version => '0.001', date => '2026-03-07T00:00:00' } },
            ],
        },
    }, 3);
    like($out, qr/^MetaCPAN recent:\n1\. /, 'recent prefix and numbered first line');
    like($out, qr/\n2\. /, 'second line numbered');
    like($out, qr/\n3\. /, 'third line numbered');
    like($out, qr/Mojolicious 9\.42 \(SRI, 2026-03-10T00:00:00\)/, 'version included when present');
    like($out, qr/Mojo-Pg \(SRI, 2026-03-08T00:00:00\)/, 'missing version omitted cleanly');
    unlike($out, qr/2026-03-09T00:00:00/, 'dropped duplicate distribution');
};

subtest 'usage guard' => sub {
    is($bot->_cpan_lookup('', ''), 'Usage: :cpan module <name> | :cpan author <query> | :cpan recent [count]', 'usage guard exact');
};

subtest 'command regex examples' => sub {
    like(':cpan module Moo', qr/^:cpan\s+(module|author)\s+(.+)/i, 'module command matches');
    like(':cpan author OALDERS', qr/^:cpan\s+(module|author)\s+(.+)/i, 'author command matches');
    like(':cpan recent', qr/^:cpan\s+recent(?:\s+(\d+))?\s*$/i, 'recent default matches');
    like(':cpan recent 5', qr/^:cpan\s+recent(?:\s+(\d+))?\s*$/i, 'recent count form matches');
    unlike('cpan recent', qr/^:cpan\s+recent(?:\s+(\d+))?\s*$/i, 'no ambient trigger');
};

done_testing;
