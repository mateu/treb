use strict;
use warnings;
use Test::More;

use lib 'lib';
use Bot::Runtime::Presence qw(
  join_message
  part_message
  is_netsplit_reason
  quit_message
  netsplit_report_message
  private_message_message
  whois_text
);

is(
  join_message(nick => 'alice', host => 'user@example', join_greet_pct => 75),
  'alice (user@example) has joined the channel. join_greet_pct=75. Greet them if you like!',
  'join_message renders join text with greet percentage',
);

is(
  part_message(nick => 'alice', host => 'user@example', reason => 'Ping timeout'),
  'alice (user@example) has left the channel: Ping timeout',
  'part_message includes part reason when present',
);

is(
  part_message(nick => 'alice', host => 'user@example'),
  'alice (user@example) has left the channel',
  'part_message omits reason suffix when absent',
);

ok(
  is_netsplit_reason(reason => 'server1.network.org server2.network.org'),
  'is_netsplit_reason matches canonical netsplit format',
);
ok(
  !is_netsplit_reason(reason => 'Quit: gone'),
  'is_netsplit_reason rejects non-netsplit quit reasons',
);

is(
  quit_message(nick => 'alice', host => 'user@example', reason => 'Client exited'),
  'alice (user@example) has quit IRC: Client exited',
  'quit_message includes quit reason when present',
);

is(
  netsplit_report_message(split_reason => 'a.net b.net', nicks => [qw(alice bob)]),
  'NETSPLIT detected (a.net b.net) — 2 user(s) lost: alice, bob',
  'netsplit_report_message includes split reason and nick list',
);

is(
  private_message_message(nick => 'alice', host => 'user@example', msg => 'hello'),
  'PRIVATE MESSAGE from alice (user@example): hello — You can reply using send_private_message.',
  'private_message_message renders standard PM system message',
);

my $whois = whois_text(
  info => {
    nick     => 'alice',
    real     => 'Alice A',
    user     => 'alice',
    host     => 'example.net',
    server   => 'irc.example.net',
    channels => ['#ai', '#perl'],
    idle     => 42,
    signon   => 0,
    account  => 'alice_acc',
  },
  notes => "note one\nnote two",
);
like($whois, qr/^WHOIS alice:/m, 'whois_text includes nick header');
like($whois, qr/Real name: Alice A/, 'whois_text includes real name');
like($whois, qr/Host: alice\@example\.net/, 'whois_text includes host');
like($whois, qr/Channels: \#ai \#perl/, 'whois_text includes channels');
like($whois, qr/Idle: 42s/, 'whois_text includes idle');
like($whois, qr/Account: alice_acc/, 'whois_text includes account');
like($whois, qr/You have 2 saved note\(s\) about this user/, 'whois_text includes note count');

done_testing;
