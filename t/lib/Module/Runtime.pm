package Module::Runtime;

use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(use_module);

sub use_module {
    my ($module) = @_;
    return $module;
}

1;
