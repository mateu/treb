use strict;
use warnings;
use Test::More;

use lib 'lib';
use Bot::Runtime::MethodDelegates qw(install_shared_delegates);

{
  package TestDelegateBot;

  sub new { bless {}, shift }
  sub get_nickname { 'testbot' }
  sub _default_filtered_bot_nicks { 'rude_bot' }
  sub _buffer_delay_seconds { 17 }
  sub _handles_bare_utility_commands { 1 }
  sub _persona_runtime_args {
    my ($self) = @_;
    return (
      self        => $self,
      bot_name    => 'testbot',
      trait_meta  => { kindness => 1 },
      trait_order => ['kindness'],
    );
  }
  sub _mcp_server_name { 'delegate-tools' }
}

my @installed = install_shared_delegates('TestDelegateBot');
ok(@installed >= 10, 'delegates installed');
ok(TestDelegateBot->can('_time_text_for_zone'), 'time delegate installed');
ok(TestDelegateBot->can('_cpan_lookup'), 'cpan delegate installed');

my $bot = TestDelegateBot->new;

{
  no warnings 'redefine';
  local *Bot::Commands::Time::time_text_for_zone = sub {
    my ($zone) = @_;
    return "zone:$zone";
  };
  local *Bot::Commands::Time::current_local_time_text = sub {
    return 'now';
  };
  local *Bot::OutputCleanup::repair_mojibake_text = sub {
    my ($text) = @_;
    return "repair:$text";
  };
  local *Bot::OutputCleanup::clean_text_for_irc = sub {
    my ($text) = @_;
    return "clean:$text";
  };
  local *Bot::OutputCleanup::is_non_substantive_output = sub {
    my ($text) = @_;
    return $text eq 'meh' ? 1 : 0;
  };
  local *Bot::Commands::CPAN::_cpan_lookup = sub {
    my ($self, $mode, $name) = @_;
    return join(':', 'cpan', ref($self), $mode, $name);
  };
  local *Bot::Runtime::WebTools::search_web = sub {
    my ($self, $query, $limit) = @_;
    return join(':', 'web', ref($self), $query, $limit);
  };
  local *Bot::Runtime::Dispatch::default_channel = sub {
    my (%args) = @_;
    return join(':', 'default-channel', ref($args{self}));
  };
  local *Bot::Runtime::Dispatch::is_filtered_bot_nick = sub {
    my (%args) = @_;
    return ($args{nick} eq 'rude_bot' && $args{default_filter_nicks} eq 'rude_bot') ? 1 : 0;
  };
  local *Bot::Runtime::Dispatch::utility_command_matches_me = sub {
    my (%args) = @_;
    return join(':', 'utility', ref($args{self}), $args{target}, $args{allow_bare});
  };
  local *Bot::Runtime::Buffering::buffer_message = sub {
    my (%args) = @_;
    return join(':', 'buffer', ref($args{self}), $args{channel}, $args{nick}, $args{msg}, ($args{delay} // 'undef'));
  };
  local *Bot::Runtime::Buffering::split_priority_messages = sub {
    my (%args) = @_;
    return [reverse @{ $args{messages} || [] }];
  };
  local *Bot::Runtime::Buffering::schedule_pending_buffers = sub {
    my (%args) = @_;
    return join(':', 'schedule', ref($args{self}), ($args{delay} // 'undef'));
  };
  local *Bot::Persona::clamp_persona_value = sub {
    my ($key, $value, %args) = @_;
    return join(':', 'clamp', $key, $value, ref($args{trait_meta}), ref($args{trait_order}));
  };
  local *Bot::Runtime::PersonaTools::default_persona_trait_value = sub {
    my (%args) = @_;
    return join(':', 'default', $args{key}, $args{bot_name});
  };
  local *Bot::Runtime::PersonaTools::persona_text = sub {
    my (%args) = @_;
    return join(':', 'persona', $args{bot_name}, ref($args{self}));
  };
  local *Bot::Runtime::PersonaTools::notes_text = sub {
    my (%args) = @_;
    return join(':', 'notes', $args{nick}, ref($args{self}));
  };
  local *Bot::Runtime::Policy::mcp_tool_logging_enabled = sub { 1 };
  local *Bot::Runtime::Policy::env_flag_enabled = sub {
    my ($name, $default) = @_;
    return join(':', 'env', $name, $default);
  };
  local *Bot::Runtime::Policy::cleanup_log_preview_text = sub {
    my ($text) = @_;
    return "preview:$text";
  };
  local *Bot::Runtime::MCPServer::build_mcp_server = sub {
    my (%args) = @_;
    return join(':', 'mcp', $args{server_name}, ref($args{self}));
  };

  is($bot->_time_text_for_zone('Europe/London'), 'zone:Europe/London', 'time delegate strips invocant');
  is($bot->_current_local_time_text, 'now', 'current_local_time delegate strips invocant');
  is($bot->_repair_mojibake_text('caf?'), 'repair:caf?', 'repair delegate strips invocant');
  is($bot->_clean_text_for_irc('line'), 'clean:line', 'clean delegate strips invocant');
  ok($bot->_is_non_substantive_output('meh'), 'non substantive delegate strips invocant');
  is(
    $bot->_cpan_lookup('module', 'Moo'),
    'cpan:TestDelegateBot:module:Moo',
    'cpan delegate forwards invocant and args',
  );
  is(
    $bot->_search_web('perl', 2),
    'web:TestDelegateBot:perl:2',
    'web delegate forwards invocant and args',
  );
  is(
    $bot->_default_channel(),
    'default-channel:TestDelegateBot',
    'default channel delegate forwards invocant in named args',
  );
  ok(
    $bot->_is_filtered_bot_nick('rude_bot'),
    'filtered nick delegate uses bot-specific default filter hook',
  );
  ok(
    !$bot->_is_human_nick('rude_bot'),
    'human nick delegate excludes filtered bot nicks',
  );
  ok(
    !$bot->_is_human_nick('testbot'),
    'human nick delegate excludes self nick',
  );
  is(
    $bot->_utility_command_matches_me('treb'),
    'utility:TestDelegateBot:treb:1',
    'utility command delegate forwards allow_bare policy hook',
  );
  is(
    $bot->_buffer_message('#chan', 'alice', 'hello'),
    'buffer:TestDelegateBot:#chan:alice:hello:17',
    'buffer delegate forwards payload and bot delay hook',
  );
  is_deeply(
    $bot->_split_priority_messages([qw(one two)]),
    [qw(two one)],
    'split-priority delegate forwards list payload',
  );
  is(
    $bot->_schedule_pending_buffers(),
    'schedule:TestDelegateBot:17',
    'schedule delegate forwards bot delay hook',
  );
  is(
    $bot->_clamp_persona_value('kindness', 120),
    'clamp:kindness:120:HASH:ARRAY',
    'persona clamp delegate forwards runtime trait metadata',
  );
  is(
    $bot->_default_persona_trait_value('kindness'),
    'default:kindness:testbot',
    'persona default delegate forwards runtime args',
  );
  is(
    $bot->_persona_text(),
    'persona:testbot:TestDelegateBot',
    'persona text delegate forwards runtime args',
  );
  is(
    $bot->_notes_text('alice'),
    'notes:alice:TestDelegateBot',
    'notes delegate forwards nick and invocant',
  );
  ok($bot->_mcp_tool_logging_enabled, 'policy delegate forwards zero-arg call');
  is(
    $bot->_env_flag_enabled('FLAG', 0),
    'env:FLAG:0',
    'policy delegate strips invocant',
  );
  is(
    $bot->_cleanup_log_preview('line'),
    'preview:line',
    'cleanup preview delegate strips invocant',
  );
  is(
    $bot->_build_mcp_server(),
    'mcp:delegate-tools:TestDelegateBot',
    'mcp builder delegate uses bot server-name hook',
  );
}

{
  package TestDelegateBurtBot;

  sub _is_non_substantive_output { return 'custom' }
  sub _build_mcp_server { return 'custom-mcp' }
}

install_shared_delegates('TestDelegateBurtBot');
is(
  TestDelegateBurtBot->_is_non_substantive_output('meh'),
  'custom',
  'existing methods are not overwritten by shared delegates',
);
is(
  TestDelegateBurtBot->_build_mcp_server(),
  'custom-mcp',
  'existing mcp builder method is not overwritten by shared delegates',
);

done_testing;
