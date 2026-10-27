use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use IO::Socket::UNIX;
use Socket qw(SOCK_STREAM);
use JSON::PP ();
use lib 'lib';
use Bot::Runtime::Workbench;

my $dir=tempdir(CLEANUP=>1);
local $ENV{BURT_WORKBENCH_SOCKET}="$dir/broker.sock";
my $server=IO::Socket::UNIX->new(Type=>SOCK_STREAM,Local=>$ENV{BURT_WORKBENCH_SOCKET},Listen=>1)
  or die $!;
my $pid=fork(); die $! unless defined $pid;
if (!$pid) {
  local $SIG{ALRM}=sub {exit 2}; alarm 10;
  my $peer=$server->accept() or exit 3;
  binmode $peer;
  my $raw=<$peer>;
  print {$peer} $raw or exit 4;
  close $peer;
  exit 0;
}
close $server;
my $files={'data.txt'=>"\x01" x 131072};
my $raw=Bot::Runtime::Workbench::broker_call({files=>$files});
is_deeply(JSON::PP::decode_json($raw)->{files},$files,
  'Perl IPC sends and receives a complete 128 KiB worst-case escaped bundle');
waitpid($pid,0);
is($?,0,'bounded peer completed');
eval {Bot::Runtime::Workbench::broker_call({files=>{'data.txt'=>'x' x 2097152}})};
like($@,qr/Request too large/,'wire envelope still bounded independently of source');
done_testing;
