use strict;
use warnings;
use Test::More;

require './treb.pl';

my $bot = bless {}, 'BertBot';
my $server = $bot->_build_mcp_server;
ok($server, 'built mcp server');

my ($tool) = grep { $_->{name} && $_->{name} eq 'cpan_module' } @{ $server->{tools} || [] };
ok($tool, 'cpan_module tool registered');
like($tool->{description} || '', qr/CPAN module metadata/i, 'tool has expected description');

done_testing;
