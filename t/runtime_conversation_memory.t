use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use JSON::PP qw(decode_json);
use lib 'lib';
use Bot::MemoryStore;
use Bot::Runtime::ConversationMemory qw(observe_public_message record_outgoing_line conversation_tool_specs);
use Bot::Runtime::Context qw(build_context_and_input);
use Bot::Runtime::PublicMessages qw(handle_standard_irc_public_event handle_ambient_irc_public_event);
{
  package ConversationIRC;
  sub nicks { return ('Alice','Bob') }
  sub is_channel_operator { 0 }
  package ConversationBot;
  sub new { my ($class,$memory,$profile)=@_; bless {memory=>$memory,profile=>$profile// 'burt',buffer=>[]},$class }
  sub memory { $_[0]{memory} }
  sub _profile { +{name=>$_[0]{profile}} }
  sub get_nickname { 'burt_bot' }
  sub get_channels { ['#ai','#other'] }
  sub _default_channel { '#ai' }
  sub _is_human_nick { $_[1] !~ /_bot$/ }
  sub _is_filtered_bot_nick { $_[1] =~ /_bot$/ }
  sub _bert_reply_lock { 0 }
  sub _bert_reply_turn_count { 0 }
  sub _last_activity { }
  sub _public_thread_open_until { 0 }
  sub _parse_public_addressee { return }
  sub _is_public_message_addressed_to_self { 0 }
  sub _persona_trait { 0 }
  sub info { }
  sub _buffer_message { my ($s,$chan,$nick,$msg,$extra)=@_; push @{$s->{buffer}},{channel=>$chan,nick=>$nick,msg=>$msg,%{$extra//{}}}; }
  sub irc { bless {},'ConversationIRC' }
  package ConversationTool;
  sub text_result { $_[1] }
}
my $dir=tempdir(CLEANUP=>1);
local $ENV{IRC_SERVER}='irc.test';
local $ENV{IRC_CASEMAPPING}='rfc1459';
local $ENV{ACTIVITY_FOLLOWUPS}; delete $ENV{ACTIVITY_FOLLOWUPS};
my $mem=Bot::MemoryStore->new(db_file=>"$dir/test.sqlite");
my $bot=ConversationBot->new($mem);
my $tool=bless {},'ConversationTool';
my %tools=map {$_->{name}=>$_} @{conversation_tool_specs($bot)};
is(scalar keys %tools,7,'Burt has journal, ledger, and watch tools');
sub call { my ($name,%a)=@_; $tools{$name}{code}->($tool,\%a) }
like(call('search_quotes',channel=>'#unknown'),qr/Error: Channel is not configured/,'unconfigured channels rejected');
like(call('search_quotes',network=>'another'),qr/Unknown argument/,'network scope cannot be overridden by model');
like(call('create_question',nick=>'Alice'),qr/Error: question/,'required fields validated at execution');
my $question=decode_json(call('create_question',nick=>'Alice',question=>'Still true?',claim=>'Always X',attribution=>'Burt hypothesis',falsifier=>'One not-X observation'));
observe_public_message(self=>$bot,nickstr=>'Alice!u@h',channels=>['#ai'],msg=>'not addressed to bot');
{
  no warnings 'redefine';
  local *Bot::Runtime::UtilityCommands::handle_public_utility_command=sub {0};
  handle_standard_irc_public_event(self=>$bot,nickstr=>'Alice!u@h',channels=>['#ai'],msg=>'not addressed to bot');
}
is(scalar @{$bot->{buffer}},0,'journal and ledger do not force a normal reply');
is(decode_json(call('search_quotes',text=>'not addressed'))->{results}[0]{message}{message},'not addressed to bot','unanswered public message captured');
my $ctx=build_context_and_input(self=>$bot,channel=>'#ai',messages=>[{nick=>'ALICE',msg=>'hello',source_kind=>'conversation'}]);
like($ctx->{context},qr/Still true/,'open questions automatically recalled for active speaker');
like($ctx->{context},qr/attributed hypotheses/,'recall warns hypotheses are not facts');
my $other=build_context_and_input(self=>$bot,channel=>'#other',messages=>[{nick=>'Alice',msg=>'hello'}]);
unlike($other->{context},qr/Still true/,'question recall isolated by channel');
$other=build_context_and_input(self=>$bot,channel=>'#ai',messages=>[{nick=>'Bob',msg=>'hello Alice'}]);
unlike($other->{context},qr/Still true/,'mere mention does not resurface open questions');
my $watch=decode_json(call('create_activity_watch',nick=>'Alice',reason=>'Revisit',question_id=>$question->{id}));
observe_public_message(self=>$bot,nickstr=>'Bob!u@h',channels=>['#ai'],msg=>'not Alice');
is(scalar @{$bot->{buffer}},0,'unrelated activity does not wake');
observe_public_message(self=>$bot,nickstr=>'Alice!u@h',channels=>['#other'],msg=>'wrong channel');
is(scalar @{$bot->{buffer}},0,'wrong channel does not wake');
observe_public_message(self=>$bot,nickstr=>'Alice!u@h',channels=>['#ai'],msg=>'back and speaking');
is(scalar @{$bot->{buffer}},1,'matching public message wakes despite ambient reply probability zero');
is($bot->{buffer}[0]{activity_wakes}[0]{event}{message},'back and speaking','exact trigger evidence bound to wake');
$ctx=build_context_and_input(self=>$bot,channel=>'#ai',messages=>$bot->{buffer});
like($ctx->{context},qr/update_activity_watch/,'wake prompts explicit disposition');
like($ctx->{context},qr/Still true/,'linked question included in wake context');
like(call('update_activity_watch',id=>$watch->{id},action=>'complete'),qr/completed/,'model can acknowledge handled wake');
my $before=$mem->_dbh->selectrow_array('SELECT COUNT(*) FROM public_messages');
record_outgoing_line(self=>$bot,channel=>'Alice',line=>'private');
observe_public_message(self=>$bot,nickstr=>'burt_bot!u@h',channels=>['#ai'],msg=>'self echo');
is($mem->_dbh->selectrow_array('SELECT COUNT(*) FROM public_messages'),$before,'PMs and self echoes excluded');
record_outgoing_line(self=>$bot,channel=>'#ai',line=>'actual sent line');
is(decode_json(call('search_quotes',text=>'actual sent'))->{results}[0]{message}{direction},'out','actual outgoing public line indexed');
my %treb=map {$_->{name}=>1} @{conversation_tool_specs(ConversationBot->new($mem,'treb'))};
ok(!$treb{create_activity_watch},'other profiles have proactive watches disabled by default');
{
  local $ENV{ACTIVITY_FOLLOWUPS}='1';
  my %enabled=map {$_->{name}=>1} @{conversation_tool_specs(ConversationBot->new($mem,'treb'))};
  ok($enabled{create_activity_watch},'explicit profile override enables watches');
}
{
  local $ENV{ACTIVITY_FOLLOWUPS}='0';
  my %disabled=map {$_->{name}=>1} @{conversation_tool_specs($bot)};
  ok(!$disabled{create_activity_watch},'explicit override disables Burt watches');
}
# Cap context independently of note ordering/probabilistic pinning.
$mem->create_question(channel=>'#ai',nick=>'Alice',question=>"Q$_",claim=>'claim',attribution=>'Alice',falsifier=>'counterexample') for 1..8;
$ctx=build_context_and_input(self=>$bot,channel=>'#ai',messages=>[{nick=>'Alice',msg=>'hello'}]);
my ($json)=$ctx->{context}=~/\n(\[\{.*\}\])\n/;
is(scalar @{decode_json($json)},3,'per-speaker ledger injection is bounded');
done_testing;
