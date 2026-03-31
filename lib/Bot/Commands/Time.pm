package Bot::Commands::Time;

use strict;
use warnings;

use Exporter 'import';
use POSIX ();
our @EXPORT_OK = qw(time_text_for_zone current_local_time_text);

sub time_text_for_zone {
  my ($zone) = @_;
  $zone ||= 'America/Denver';
  local $ENV{TZ} = $zone;
  my @lt = localtime(time());
  my @days = qw(Sunday Monday Tuesday Wednesday Thursday Friday Saturday);
  my @months = qw(January February March April May June July August September October November December);
  my $wday = $days[$lt[6]];
  my $month = $months[$lt[4]];
  my $mday = $lt[3];
  my $year = $lt[5] + 1900;
  my $hour24 = $lt[2];
  my $min = $lt[1];
  my $ampm = $hour24 >= 12 ? 'PM' : 'AM';
  my $hour12 = $hour24 % 12;
  $hour12 = 12 if $hour12 == 0;
  my $tz = POSIX::strftime('%Z', localtime(time())) || $zone;
  return sprintf('%s, %s %d, %d, %d:%02d %s %s (%s)',
    $wday, $month, $mday, $year, $hour12, $min, $ampm, $tz, $zone);
}

sub current_local_time_text {
  return time_text_for_zone('America/Denver');
}

1;
