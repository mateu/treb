package Bot::Runtime::MethodDelegates;
use strict;
use warnings;

use Exporter 'import';
our @EXPORT_OK = qw(install_shared_delegates);

use Bot::Commands::CPAN ();
use Bot::Persona ();
use Bot::Commands::Time ();
use Bot::OutputCleanup ();
use Bot::Runtime::Buffering ();
use Bot::Runtime::Dispatch ();
use Bot::Runtime::MCPServer ();
use Bot::Runtime::PersonaTools ();
use Bot::Runtime::Policy ();
use Bot::Runtime::RaiderSetup ();
use Bot::Runtime::WebTools ();

{
  package Bot::Runtime::MethodDelegates::ImmediateFuture;

  sub new {
    my ($class, $value) = @_;
    return bless { value => $value }, $class;
  }

  sub get {
    my ($self) = @_;
    return $self->{value};
  }
}

sub install_shared_delegates {
  my ($target_package) = @_;
  die "install_shared_delegates requires a target package" unless $target_package;

  my @_required_config_keys = qw(
    bot_name_slug mcp_server_name owner max_line script_file
  );

  my $runtime_config_for = sub {
    my ($self) = @_;
    die ref($self) . ' must define _entrypoint_runtime_config'
      unless $self->can('_entrypoint_runtime_config');
    my $config = $self->_entrypoint_runtime_config;
    die ref($self) . ' _entrypoint_runtime_config must return a hashref'
      unless ref($config) eq 'HASH';
    for my $key (@_required_config_keys) {
      die ref($self) . " _entrypoint_runtime_config missing required key: $key"
        unless exists $config->{$key} && defined $config->{$key};
    }
    die ref($self) . ' _entrypoint_runtime_config script_file must not be empty'
      unless length($config->{script_file} // '');
    return $config;
  };

  my %delegates = (
    _bot_name_slug => sub {
      my ($self) = @_;
      my $config = $runtime_config_for->($self);
      return $config->{bot_name_slug};
    },
    _persona_runtime_args => sub {
      my ($self) = @_;
      my $config = $runtime_config_for->($self);
      return (
        self        => $self,
        bot_name    => $config->{bot_name_slug},
        trait_meta  => $config->{trait_meta},
        trait_order => $config->{trait_order},
      );
    },
    _mcp_server_name => sub {
      my ($self) = @_;
      my $config = $runtime_config_for->($self);
      return $config->{mcp_server_name};
    },
    _setup_raider => sub {
      my ($self) = @_;
      my $config = $runtime_config_for->($self);
      my %args = (
        self        => $self,
        owner       => $config->{owner},
        max_line    => $config->{max_line},
        script_file => $config->{script_file},
      );
      if (defined $config->{max_context_tokens}) {
        $args{max_context_tokens} = $config->{max_context_tokens};
      }
      my $raider = Bot::Runtime::RaiderSetup::setup_raider(%args);
      return Bot::Runtime::MethodDelegates::ImmediateFuture->new($raider);
    },
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
    _default_channel => sub {
      my ($self) = @_;
      return Bot::Runtime::Dispatch::default_channel(self => $self);
    },
    _parse_public_addressee => sub {
      my ($self, $msg) = @_;
      return Bot::Runtime::Dispatch::parse_public_addressee(msg => $msg);
    },
    _is_public_message_addressed_to_self => sub {
      my ($self, $msg) = @_;
      return Bot::Runtime::Dispatch::is_public_message_addressed_to_self(
        self => $self,
        msg  => $msg,
      );
    },
    _is_filtered_bot_nick => sub {
      my ($self, $nick) = @_;
      return Bot::Runtime::Dispatch::is_filtered_bot_nick(
        nick                 => $nick,
        default_filter_nicks => $self->_default_filtered_bot_nicks,
      );
    },
    _is_human_nick => sub {
      my ($self, $nick) = @_;
      return 0 unless defined $nick && length $nick;
      return 0 if $nick eq $self->get_nickname;
      return $self->_is_filtered_bot_nick($nick) ? 0 : 1;
    },
    _utility_command_matches_me => sub {
      my ($self, $target) = @_;
      return Bot::Runtime::Dispatch::utility_command_matches_me(
        self       => $self,
        target     => $target,
        allow_bare => $self->_handles_bare_utility_commands,
      );
    },
    _send_to_channel_max_line => sub {
      return $ENV{MAX_LINE_LENGTH} || 400;
    },
    _send_to_channel_return_cumulative => sub {
      return 0;
    },
    _send_to_channel => sub {
      my ($self, $channel, $text) = @_;
      return Bot::Runtime::Dispatch::send_to_channel(
        channel           => $channel,
        text              => $text,
        max_line          => $self->_send_to_channel_max_line,
        return_cumulative => $self->_send_to_channel_return_cumulative,
      );
    },
    _buffer_message => sub {
      my ($self, $channel, $nick, $msg, $extra) = @_;
      return Bot::Runtime::Buffering::buffer_message(
        self    => $self,
        channel => $channel,
        nick    => $nick,
        msg     => $msg,
        extra   => $extra,
        delay   => $self->_buffer_delay_seconds,
      );
    },
    _split_priority_messages => sub {
      my ($self, $messages) = @_;
      return Bot::Runtime::Buffering::split_priority_messages(messages => $messages);
    },
    _schedule_pending_buffers => sub {
      my ($self) = @_;
      return Bot::Runtime::Buffering::schedule_pending_buffers(
        self  => $self,
        delay => $self->_buffer_delay_seconds,
      );
    },
    _clamp_persona_value => sub {
      my ($self, $key, $value) = @_;
      my %runtime_args = $self->_persona_runtime_args;
      return Bot::Persona::clamp_persona_value(
        $key,
        $value,
        trait_meta  => $runtime_args{trait_meta},
        trait_order => $runtime_args{trait_order},
      );
    },
    _default_persona_trait_value => sub {
      my ($self, $key) = @_;
      return Bot::Runtime::PersonaTools::default_persona_trait_value($self->_persona_runtime_args, key => $key);
    },
    _load_persona_settings => sub {
      my ($self) = @_;
      return Bot::Runtime::PersonaTools::load_persona_settings($self->_persona_runtime_args);
    },
    _persona_trait => sub {
      my ($self, $key) = @_;
      return Bot::Runtime::PersonaTools::persona_trait($self->_persona_runtime_args, key => $key);
    },
    _persona_stats_text => sub {
      my ($self) = @_;
      return Bot::Runtime::PersonaTools::persona_stats_text($self->_persona_runtime_args);
    },
    _persona_text => sub {
      my ($self) = @_;
      return Bot::Runtime::PersonaTools::persona_text($self->_persona_runtime_args);
    },
    _persona_summary_text => sub {
      my ($self) = @_;
      return Bot::Runtime::PersonaTools::persona_summary_text($self->_persona_runtime_args);
    },
    _persona_trait_text => sub {
      my ($self, $trait) = @_;
      return Bot::Runtime::PersonaTools::persona_trait_text($self->_persona_runtime_args, trait => $trait);
    },
    _set_persona_trait => sub {
      my ($self, $trait, $value) = @_;
      return Bot::Runtime::PersonaTools::set_persona_trait($self->_persona_runtime_args, trait => $trait, value => $value);
    },
    _apply_persona_preset => sub {
      my ($self, $value) = @_;
      return Bot::Runtime::PersonaTools::apply_persona_preset($self->_persona_runtime_args, value => $value);
    },
    _db_stats_text => sub {
      my ($self) = @_;
      return Bot::Runtime::PersonaTools::db_stats_text($self->_persona_runtime_args);
    },
    _notes_text => sub {
      my ($self, $nick) = @_;
      return Bot::Runtime::PersonaTools::notes_text(self => $self, nick => $nick);
    },
    _mcp_tool_logging_enabled => sub {
      return Bot::Runtime::Policy::mcp_tool_logging_enabled();
    },
    _env_flag_enabled => sub {
      my ($self, $name, $default) = @_;
      return Bot::Runtime::Policy::env_flag_enabled($name, $default);
    },
    _store_system_rows_enabled => sub {
      return Bot::Runtime::Policy::store_system_rows_enabled();
    },
    _store_non_substantive_rows_enabled => sub {
      return Bot::Runtime::Policy::store_non_substantive_rows_enabled();
    },
    _store_empty_response_rows_enabled => sub {
      return Bot::Runtime::Policy::store_empty_response_rows_enabled();
    },
    _cleanup_logging_enabled => sub {
      return Bot::Runtime::Policy::cleanup_logging_enabled();
    },
    _cleanup_log_preview => sub {
      my ($self, $text) = @_;
      return Bot::Runtime::Policy::cleanup_log_preview_text($text);
    },
    _log_cleanup_change => sub {
      my ($self, $label, $before, $after) = @_;
      return Bot::Runtime::Policy::log_cleanup_change(
        self   => $self,
        label  => $label,
        before => $before,
        after  => $after,
      );
    },
    _log_cleanup_empty => sub {
      my ($self, $before, $after) = @_;
      return Bot::Runtime::Policy::log_cleanup_empty(
        self   => $self,
        before => $before,
        after  => $after,
      );
    },
    _build_mcp_server => sub {
      my ($self) = @_;
      return Bot::Runtime::MCPServer::build_mcp_server(
        self        => $self,
        server_name => $self->_mcp_server_name,
      );
    },
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
