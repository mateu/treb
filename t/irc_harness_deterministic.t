use strict;
use warnings;
use IO::Socket::INET;
use Test::More;

my $should_run = ($ENV{RUN_IRC_HARNESS_DETERMINISTIC} // '') ne '' || ($ENV{CI} // '') ne '';

if (!$should_run) {
    plan skip_all => 'set RUN_IRC_HARNESS_DETERMINISTIC=1 to run deterministic IRC harness integration test';
}

my $port_guard = IO::Socket::INET->new(
    LocalAddr => '127.0.0.1',
    LocalPort => 6667,
    Proto     => 'tcp',
    Listen    => 1,
    ReuseAddr => 0,
);

if (!$port_guard) {
    plan skip_all => 'deterministic harness needs 127.0.0.1:6667, but it is already in use';
}
close $port_guard;

my $cmd = 'script/run-local-irc-harness.sh --mode deterministic';
my $output = `$cmd 2>&1`;
my $rc = $? >> 8;

my ($run_dir) = $output =~ /"run_dir"\s*:\s*"([^"]+)"/;
diag("harness run_dir: $run_dir") if $run_dir;

if ($rc != 0) {
    diag("harness command failed: $cmd (exit $rc)");
    diag($output);

    if ($run_dir && -d $run_dir) {
        for my $name (qw(behavior_report.txt evaluation.txt transcript.log burt.log treb.log conversation.log summary.json)) {
            my $path = "$run_dir/$name";
            next unless -e $path;
            my $tail = `tail -n 120 "$path" 2>&1`;
            diag("==== tail $path ====");
            diag($tail);
        }
    }
}

is($rc, 0, 'deterministic IRC harness exits cleanly');

done_testing;
