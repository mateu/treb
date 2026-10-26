use strict;
use warnings;
use Test::More;

my $should_run = ($ENV{RUN_IRC_HARNESS_DETERMINISTIC} // '') ne '' || ($ENV{CI} // '') ne '';

if (!$should_run) {
    plan skip_all => 'set RUN_IRC_HARNESS_DETERMINISTIC=1 to run deterministic IRC harness integration test';
}

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

# Exercise the real IRC event wiring, not just the observer helper in isolation.
if ($rc == 0 && $run_dir) {
    require DBI;
    for my $bot (qw(burt treb)) {
        my $db="$run_dir/$bot-harness.sqlite";
        ok(-f $db, "$bot harness database exists");
        my $dbh=DBI->connect("dbi:SQLite:dbname=$db",'','',{RaiseError=>1});
        cmp_ok($dbh->selectrow_array("SELECT COUNT(*) FROM public_messages WHERE nick='Alice' AND direction='in'"),'>',0,
            "$bot captures human channel messages in real event path");
        cmp_ok($dbh->selectrow_array("SELECT COUNT(*) FROM public_messages WHERE direction='out'"),'>',0,
            "$bot captures outgoing dispatches");
        is($dbh->selectrow_array("SELECT COUNT(*) FROM public_messages WHERE message='time:' AND nick='Alice'"),1,
            "$bot journals exact utility command before command handler consumes it");
        $dbh->disconnect;
    }
}

done_testing;
