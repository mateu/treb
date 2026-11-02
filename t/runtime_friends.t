use strict;
use warnings;
use Test::More;
use File::Temp qw(tempfile);
use JSON::PP ();
use lib 'lib';
use Bot::Runtime::Friends ();
use Bot::Runtime::PresenceEvents ();
{
  package FriendBot;
  sub new { bless {events=>[]}, shift }
  sub info {}
  sub _bot_name_slug { 'burt' }
  sub get_nickname { 'burt_bot' }
  sub get_channels { '#test' }
  sub _default_channel { '#test' }
  sub _last_activity {}
  sub _persona_trait { 0 }
  sub _buffer_message { my $s=shift; push @{$s->{events}}, [@_] }
  sub _netsplit_quits { $_[0]{quits} ||= [] }
}
{ package POE::Kernel; sub delay { 1 } }
my ($fh,$path)=tempfile();
sub config { my ($data)=@_; open my $out,'>',$path or die $!; print $out $data; close $out; }
my @logs;
my $load=sub { Bot::Runtime::Friends::load(path=>$path,log=>sub {push @logs,$_[0]}) };
config('{"friends":[{"nick":"MaTeU","about":"Pal"},{"nick":"oalders"}]}');
is(scalar keys %{$load->()},2,'valid config');
ok($load->()->{mateu},'folded nick');
ok(!$load->()->{oalders_},'suffix not an alias');
local $ENV{BURT_FRIENDS_FILE}=$path;
local $ENV{BOT_FRIEND_JOIN_COOLDOWN_SECONDS}=21600;
local $ENV{BURT_GITHUB_WRITERS}='only_operator';
my $bot=FriendBot->new;
my $ctx=Bot::Runtime::Friends::context($bot,[{nick=>'MaTeU',msg=>'hello'}]);
like($ctx,qr/Pal/,'speaker gets profile');
unlike($ctx,qr/"nick":"oalders"/,'irrelevant profile absent');
like(Bot::Runtime::Friends::context($bot,[{nick=>'stranger',msg=>'hey mateu!'}]),qr/Pal/,'mentioned friend');
is(Bot::Runtime::Friends::context($bot,[{nick=>'oalders_',msg=>'hi'}]),'','no alias context');
is($ENV{BURT_GITHUB_WRITERS},'only_operator','writers unchanged');
ok(Bot::Runtime::Friends::greet($bot,'mateu','#test',100),'forced first greeting');
ok(!Bot::Runtime::Friends::greet($bot,'MATEU','#TEST',101),'folded cooldown');
ok(Bot::Runtime::Friends::greet($bot,'mateu','#other',101),'channel independent');
ok(Bot::Runtime::Friends::greet($bot,'mateu','#test',21700),'cooldown expires');
my $joins=FriendBot->new;
for my $nick ('mateu','mateu','stranger') {
 Bot::Runtime::PresenceEvents::handle_irc_join(self=>$joins,nickstr=>"$nick!anyhost",channel=>'#test');
}
like($joins->{events}[0][2],qr/join_greet_pct=100.*greet them warmly/s,'friend forced');
like($joins->{events}[1][2],qr/join_greet_pct=0/,'rejoin ordinary');
like($joins->{events}[2][2],qr/join_greet_pct=0/,'stranger ordinary');
my $split=FriendBot->new;
Bot::Runtime::PresenceEvents::handle_irc_quit(self=>$split,nickstr=>'mateu!host',reason=>'a.example b.example');
Bot::Runtime::PresenceEvents::handle_irc_join(self=>$split,nickstr=>'mateu!otherhost',channel=>'#test');
like($split->{events}[0][2],qr/join_greet_pct=0/,'netsplit rejoin suppressed without prior greeting');
for my $bad ('{', '{"friends":{}}', JSON::PP->new->encode({friends=>[map {{nick=>"friend$_"}} 1..21]}), JSON::PP->new->encode({friends=>[{nick=>'mateu',about=>'x'x501}]}), 'x'x65537) {
 config($bad); is_deeply($load->(),{},'invalid config fails closed');
}
unlink $path;
is_deeply($load->(),{},'missing file off');
my $empty=FriendBot->new;
is(Bot::Runtime::Friends::context($empty,[{nick=>'mateu',msg=>'hi'}]),'','runtime continues without file');
ok(@logs,'failure logged');
done_testing;
