use strict;
use warnings;
use Test::More;

require './treb.pl';

{
    package TestSummaryBot;
    our @ISA = ('BertBot');
    sub new_minimal { bless {}, shift }
    sub _metacpan_get_json {
        my ($self, $url) = @_;
        return {
            documentation => 'Adam',
            distribution  => 'Adam',
            author        => 'OALDERS',
            description   => 'Fallback description',
            abstract      => 'A conversational bot framework and example bot.',
        } if $url =~ m{/v1/module/Adam$};
        return undef;
    }
    sub _metacpan_get_text {
        my ($self, $url) = @_;
        return <<'POD' if $url =~ m{/v1/pod/Adam\?content-type=text/x-pod$};
=pod

=head1 NAME

Adam - The patriarch of IRC Bots

=head1 DESCRIPTION

The Adam class implements an IRC bot based on POE::Component::IRC::State,
Moose, and MooseX::POE.

Adam is not meant to be used directly — see Moses for the declarative
sugar layer.

=head2 logger

Logger object details.

=cut
POD
        return undef;
    }
}

my $bot = TestSummaryBot->new_minimal;

subtest 'metacpan pod URL summary uses NAME plus bounded DESCRIPTION only' => sub {
    my $out = $bot->_summarize_url('https://metacpan.org/pod/Adam');
    like($out, qr/^Adam - The patriarch of IRC Bots\n/, 'starts with NAME section text on its own line');
    like($out, qr/The Adam class implements an IRC bot based on POE::Component::IRC::State/, 'includes DESCRIPTION body');
    like($out, qr/Adam is not meant to be used directly/, 'includes later DESCRIPTION paragraph');
    unlike($out, qr/logger|Logger object details/, 'does not include subsection content');
    like($out, qr{Docs: https://metacpan.org/pod/Adam}, 'includes docs URL');
};

done_testing;
