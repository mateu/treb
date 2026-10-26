package Bot::Runtime::Limits;
use strict;
use warnings;
use Exporter 'import';
our @EXPORT_OK = qw(runtime_limit now);

sub now { time() }

sub runtime_limit {
  my ($name, $default) = @_;
  my $value = $ENV{"BOT_$name"};
  return $default unless defined $value && $value =~ /\A[1-9]\d*\z/;
  return 0 + $value;
}

1;
