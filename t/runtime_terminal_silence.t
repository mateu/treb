use strict;
use warnings;
use Test::More;
use Future;
use IO::Async::Loop;
use MCP::Server;
use Net::Async::MCP;
use Langertha::Raider;

use lib 'lib';
use Bot::Runtime::RaiderPlugin::TerminalSilence;
use Bot::Runtime::RaiderPlugin::ToolTrace;

{
  package TerminalSilence::Response;
  sub new { bless {}, shift }
  sub is_success { 1 }
  sub status_line { '200 OK' }
  sub content { '' }
}

{
  package TerminalSilence::Engine;
  sub new {
    my ($class, %args) = @_;
    return bless { loop => $args{loop}, mcp_servers => $args{mcp_servers} || [], repeat_silence => $args{repeat_silence} || 0, turns => 0, requests => 0 }, $class;
  }
  sub async_loop { $_[0]{loop} }
  sub mcp_servers { $_[0]{mcp_servers} }
  sub chat_model { 'terminal-silence-test' }
  sub format_tools { $_[1] }
  sub build_tool_chat_request { return { request => 1 } }
  sub async_request_f {
    my ($self) = @_;
    $self->{requests}++;
    return $self->{loop}->new_future->done(TerminalSilence::Response->new);
  }
  sub parse_response {
    my ($self) = @_;
    return { tool_calls => [{ name => 'stay_silent', input => { reason => 'ambient join' } }] }
      if $self->{repeat_silence} || $self->{turns}++ == 0;
    return { text => 'this must not be reached' };
  }
  sub response_tool_calls { $_[1]{tool_calls} // [] }
  sub response_text_content { $_[1]{text} // '' }
  sub extract_tool_call { return ($_[1]{name}, $_[1]{input}) }
  sub think_tag_filter { 0 }
  sub format_tool_results { return map { { role => 'tool', content => 'result' } } @{ $_[2] } }
}

my $loop = IO::Async::Loop->new;
my $calls = 0;
my $server = MCP::Server->new(name => 'terminal-silence-test', version => '1.0');
$server->tool(
  name => 'stay_silent',
  input_schema => { type => 'object', properties => { reason => { type => 'string' } } },
  code => sub {
    $calls++;
    my ($tool, $args) = @_;
    return $tool->text_result('__SILENT__');
  },
);
my $mcp = Net::Async::MCP->new(server => $server);
$loop->add($mcp);
$loop->await($mcp->initialize);

my @pre_fix_trace;
my $pre_fix_engine = TerminalSilence::Engine->new(loop => $loop, mcp_servers => [$mcp], repeat_silence => 1);
my $pre_fix_raider = Langertha::Raider->new(
  engine => $pre_fix_engine,
  max_iterations => 2,
  no_session_embeddings => 1,
  plugins => [
    '+Bot::Runtime::RaiderPlugin::ToolTrace', { logger => sub { push @pre_fix_trace, $_[0] } },
  ],
);
my $pre_fix_ok = eval { $pre_fix_raider->raid('<system> a bot joined the channel'); 1 };
ok(!$pre_fix_ok, 'a text-only stay_silent result does not end Raider');
like($@, qr/Raider tool loop exceeded 2 iterations/, 'unfixed loop reaches Raider iteration cap');
is($pre_fix_engine->{requests}, 2, 'unfixed loop starts another model turn after each silent result');
is($calls, 2, 'unfixed loop invokes real MCP stay_silent once per iteration');
like(join("\n", @pre_fix_trace), qr/event=model_tool_call name=stay_silent args=\{reason:scalar\}/, 'trace captures the repeated model call with only argument metadata');
like(join("\n", @pre_fix_trace), qr/event=tool_result name=stay_silent status=succeeded result_chars=10/, 'trace captures the text-only silent result that failed to terminate the loop');

my @trace;
my $engine = TerminalSilence::Engine->new(loop => $loop, mcp_servers => [$mcp]);
my $raider = Langertha::Raider->new(
  engine => $engine,
  max_iterations => 13,
  no_session_embeddings => 1,
  plugins => [
    '+Bot::Runtime::RaiderPlugin::TerminalSilence',
    '+Bot::Runtime::RaiderPlugin::ToolTrace', { logger => sub { push @trace, $_[0] } },
  ],
);

my $result = $raider->raid('<system> a bot joined the channel');
ok($result->is_cancelled, 'stay_silent ends the active Raider raid via supported cancellation');
is($calls, 3, 'the fixed real MCP stay_silent tool runs once');
is($engine->{requests}, 1, 'no second model turn can begin after terminal silence');
like(join("\n", @trace), qr/event=model_tool_call name=stay_silent args=\{reason:scalar\}/, 'trace records model tool call with only argument metadata');
like(join("\n", @trace), qr/event=tool_result name=stay_silent status=(?:succeeded|cancelled)/, 'trace records terminal tool result without content');

$loop->remove($mcp);
done_testing;
