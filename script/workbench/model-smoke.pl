#!/usr/bin/env perl
# Explicit operator-only integration check: calls the model and creates one
# public test gist. No IRC client/session, messages, or live database access.
use strict;
use warnings;
binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';
use MCP::Server;
use Bot::Runtime::Workbench;
use Bot::Runtime::RaiderSetup;
{
  package WorkbenchSmoke;
  sub new { my ($class,$mode)=@_; bless {pending=>{channel=>'#ai',expires_at=>time+300,messages=>[
    {source_kind=>'conversation',nick=>'operator',msg=>($mode eq 'repo-start' ? 'burt_bot: write a tiny Perl arithmetic module with an add function; test positive, zero and negative inputs. Read branch burt/tool-smoke project repository-smoke first, then test the complete project and publish it to the workspace repository. Include README.md describing this as an integration smoke project, not the dictionary client.' : $mode eq 'repo-continue' ? 'burt_bot: read existing branch burt/tool-smoke project repository-smoke in the workspace repo. Keep the existing addition function and tests, add a subtract function with meaningful assertions, test the complete project, and publish the update to the same repository branch. Preserve all existing files.' : 'burt_bot: write a Perl FizzBuzz function, test 1, 3, 5 and 15, and post the source and tests as a public gist.')}]}},$class }
  sub _bot_name_slug { 'burt' }
  sub get_nickname { 'burt_bot' }
  sub get_channels { '#ai' }
  sub _is_human_nick { $_[1] eq 'operator' }
  sub _pending_raid { $_[0]{pending} }
  sub _mcp { $_[0]{mcp}=$_[1] if @_>1; $_[0]{mcp} }
  sub _raider { $_[0]{raider}=$_[1] if @_>1; $_[0]{raider} }
  sub info { print STDERR "$_[1]\n" }
  sub _build_mcp_server {
    my ($self)=@_;
    my $server=MCP::Server->new(name=>'burt-workbench-smoke',version=>'1');
    $server->tool(%$_) for @{Bot::Runtime::Workbench::tool_specs($self)};
    return $server;
  }
}
my $mode=shift(@ARGV)//'gist';
my $bot=WorkbenchSmoke->new($mode);
my $raider=Bot::Runtime::RaiderSetup::setup_raider(self=>$bot,owner=>'operator',max_line=>400,script_file=>'/app/burt.pl');
my $result=$raider->raid("Current #ai human message: ".$bot->_pending_raid->{messages}[0]{msg}.
  "\nThis is an explicit operator integration check, not ambient conversation. Use the coding tools now, include meaningful assertions, and return the real publication URL and test result. Do not send any IRC messages.");
print "$result\n";
