package Bot::Runtime::MethodDelegates;
use strict;
use warnings;

use Exporter 'import';
our @EXPORT_OK = qw(install_shared_delegates);

use Bot::Commands::CPAN ();
use Bot::Commands::Time ();
use Bot::OutputCleanup ();
use Bot::Runtime::WebTools ();

sub install_shared_delegates {
  my ($target_package) = @_;
  die "install_shared_delegates requires a target package" unless $target_package;

  my %delegates = (
    _time_text_for_zone => sub {
      my ($self, $zone) = @_;
      return Bot::Commands::Time::time_text_for_zone($zone);
    },
    _current_local_time_text => sub {
      my ($self) = @_;
      return Bot::Commands::Time::current_local_time_text();
    },
    _repair_mojibake_text => sub {
      my ($self, $text) = @_;
      return Bot::OutputCleanup::repair_mojibake_text($text);
    },
    _clean_text_for_irc => sub {
      my ($self, $text) = @_;
      return Bot::OutputCleanup::clean_text_for_irc($text);
    },
    _is_non_substantive_output => sub {
      my ($self, $text) = @_;
      return Bot::OutputCleanup::is_non_substantive_output($text);
    },
    _metacpan_get_json => sub { Bot::Commands::CPAN::_metacpan_get_json(@_) },
    _metacpan_get_text => sub { Bot::Commands::CPAN::_metacpan_get_text(@_) },
    _extract_pod_section => sub { Bot::Commands::CPAN::_extract_pod_section(@_) },
    _format_cpan_module_result => sub { Bot::Commands::CPAN::_format_cpan_module_result(@_) },
    _format_cpan_describe_result => sub { Bot::Commands::CPAN::_format_cpan_describe_result(@_) },
    _format_cpan_author_result => sub { Bot::Commands::CPAN::_format_cpan_author_result(@_) },
    _format_cpan_recent_results => sub { Bot::Commands::CPAN::_format_cpan_recent_results(@_) },
    _cpan_lookup => sub { Bot::Commands::CPAN::_cpan_lookup(@_) },
    _summarize_special_url => sub { Bot::Commands::CPAN::_summarize_special_url(@_) },
    _summarize_metacpan_pod => sub { Bot::Commands::CPAN::_summarize_metacpan_pod(@_) },
    _format_search_results => sub { Bot::Runtime::WebTools::format_search_results(@_) },
    _summarize_url => sub { Bot::Runtime::WebTools::summarize_url(@_) },
    _search_web => sub { Bot::Runtime::WebTools::search_web(@_) },
  );

  my @installed;

  no strict 'refs';
  for my $name (keys %delegates) {
    next if defined &{"${target_package}::${name}"};
    *{"${target_package}::${name}"} = $delegates{$name};
    push @installed, $name;
  }

  return sort @installed;
}

1;
