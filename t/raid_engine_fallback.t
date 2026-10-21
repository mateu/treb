use strict;
use warnings;
use Test::More;

use lib 'lib';
BEGIN { $INC{'POE/Kernel.pm'} = 1 }
{ package POE::Kernel; sub delay { 1 } }
use Bot::Runtime::RaidFlow ();

{
  package Local::Log;
  sub new { bless { lines => [] }, shift }
  sub info { push @{$_[0]{lines}}, $_[1] }
}

{
  package Local::Raider;
  sub new {
    my ($c, %a) = @_;
    bless { script => $a{script}, catalog => $a{catalog} || {}, active => undef, calls => [] }, $c;
  }
  sub engine_catalog { $_[0]{catalog} }
  sub active_engine_name { $_[0]{active} }
  sub switch_engine { $_[0]{active} = $_[1] }
  sub reset_engine { $_[0]{active} = undef }
  sub raid {
    my $self = shift;
    my $step = shift @{$self->{script}};
    push @{$self->{calls}}, $self->{active} // 'default';
    die $step->{die} if $step->{die};
    return $step->{ok};
  }
}

my $log = Local::Log->new;
my $f = \&Bot::Runtime::RaidFlow::_raid_with_fallback;
my $cat = { fallback1 => {}, fallback2 => {} };

my $r = Local::Raider->new(script => [{ die => "503 Service Unavailable overloaded" }, { ok => 'hi' }], catalog => $cat);
is $f->($log, $r, 'x'), 'hi', 'falls back on 503';
is_deeply $r->{calls}, ['default', 'fallback1'], 'switched to first fallback';

$r = Local::Raider->new(script => [{ die => "503 overloaded" }, { die => "502 bad gateway" }, { ok => 'ok2' }], catalog => $cat);
is $f->($log, $r, 'x'), 'ok2', 'walks the chain';
is_deeply $r->{calls}, ['default', 'fallback1', 'fallback2'];

$r = Local::Raider->new(script => [{ die => "503 overloaded" }, { die => "503 overloaded" }, { die => "503 overloaded" }], catalog => $cat);
eval { $f->($log, $r, 'x') };
like $@, qr/503/, 'raises after chain exhausted';

$r = Local::Raider->new(script => [{ die => "Raider tool loop exceeded 13 iterations" }], catalog => $cat);
eval { $f->($log, $r, 'x') };
like $@, qr/tool loop/, 'tool loop error is not retried';
is_deeply $r->{calls}, ['default'];

$r = Local::Raider->new(script => [{ ok => 'a' }, { ok => 'b' }], catalog => $cat);
$r->{active} = 'fallback1';
$f->($log, $r, 'x');
is_deeply $r->{calls}, ['default'], 'primary is retried at the start of each raid';

done_testing;
