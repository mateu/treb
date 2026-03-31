use strict;
use warnings;
use Test::More;

require './treb.pl';

{
    package TestMetaBot;
    our @ISA = ('BertBot');
    sub new_minimal { bless {}, shift }
    sub _metacpan_get_text {
        my ($self, $url) = @_;
        return <<'POD' if $url =~ m{/v1/pod/Bracket\?content-type=text/x-pod$};
=pod

=head1 NAME

Bracket - College Basketball Tournament Bracket Web Application

=head1 DESCRIPTION

College Basketball Tournament Bracket Web application using the Catalyst framework.
Deploy an instance of this bracket software to run your own bracket system.
It requires a data store such as MySQL, PostgreSQL or SQLite.

Simple admin interface to build the perfect bracket as the tournament unfolds.

=head2 logger

Not part of DESCRIPTION.

=cut
POD
        return undef;
    }
}

my $bot = TestMetaBot->new_minimal;

subtest 'extract_pod_section stops at next =headN' => sub {
    my $pod = <<'POD';
=pod

=head1 DESCRIPTION

Alpha line.

Beta line.

=head2 logger

Should not appear.
POD
    my $desc = $bot->_extract_pod_section($pod, 'DESCRIPTION');
    like($desc, qr/Alpha line\./, 'first paragraph kept');
    like($desc, qr/Beta line\./, 'second paragraph kept');
    unlike($desc, qr/logger|Should not appear/, 'stopped before subsection');
};

subtest 'describe formatter returns DESCRIPTION section text directly' => sub {
    my $out = $bot->_format_cpan_describe_result('Bracket', {
        documentation => 'Bracket',
        distribution  => 'Bracket',
        author        => 'MATEU',
        description   => 'Fallback description',
        abstract      => 'College Basketball Tournament Bracket Web Application',
    });
    like($out, qr/^College Basketball Tournament Bracket Web application using the Catalyst framework\./, 'description starts from DESCRIPTION');
    like($out, qr/Deploy an instance of this bracket software/, 'keeps description body');
    unlike($out, qr/logger|Not part of DESCRIPTION/, 'does not include subsection content');
    unlike($out, qr/is a CPAN module by/, 'no synthetic wrapper prose');
};

subtest 'mojibake cleanup for module output' => sub {
    my $bot = bless {}, 'BertBot';
    my $line = $bot->_format_cpan_module_result('MCP::Server', {
        documentation => 'MCP::Server',
        distribution  => 'MCP',
        author        => 'SRI',
        abstract      => 'An implementation â€” part of the MCP distribution',
    });
    unlike($line, qr/implementation\s+â/, 'broken implementation mojibake removed');
    like($line, qr/MCP::Server\s+-\s+An implementation/, 'line still shaped as compact module summary');
    done_testing;
};

done_testing;
