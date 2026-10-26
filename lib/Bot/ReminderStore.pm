package Bot::ReminderStore;
use strict;
use warnings;
use Moose::Role;
use Bot::IRCIdentity qw(irc_scope);
requires '_dbh';

sub initialize_reminder_schema {
  my ($self,$dbh)=@_;
  $dbh->do(q{CREATE TABLE IF NOT EXISTS reminders (
    id INTEGER PRIMARY KEY, bot TEXT NOT NULL, network TEXT NOT NULL,
    channel TEXT NOT NULL, reason TEXT NOT NULL, created_at INTEGER NOT NULL,
    due_at INTEGER NOT NULL, state TEXT NOT NULL DEFAULT 'armed',
    lease_until INTEGER, fired_at INTEGER)});
  $dbh->do(q{CREATE INDEX IF NOT EXISTS reminders_scope ON reminders(bot,network,channel,state,due_at,id)});
}
sub _reminder_scope {
  my (%a)=@_;
  my ($network,$channel)=irc_scope(%a);
  my $bot=$a{bot}//'';
  die "Bot identity required\n" unless !ref($bot) && length($bot) && length($bot)<=100;
  return ($bot,$network,$channel);
}
sub _reminder_id {
  my ($id)=@_;
  die "Invalid reminder ID\n" unless defined($id) && !ref($id) && $id =~ /\A[1-9]\d*\z/ && $id<=9_000_000_000_000_000;
  return $id;
}
sub _expire_reminders {
  my ($self,$now,@scope)=@_;
  $self->_dbh->do(q{UPDATE reminders SET state='expired',lease_until=NULL
    WHERE bot=? AND network=? AND channel=? AND state IN ('armed','queued') AND due_at<?},
    undef,@scope,$now-3600);
}
sub create_reminder {
  my ($self,%a)=@_;
  my @scope=_reminder_scope(%a);
  my $reason=$a{reason};
  die "Reason is required (maximum 1000 characters)\n"
    unless defined($reason) && !ref($reason) && $reason =~ /\S/ && length($reason)<=1000;
  my $delay=$a{delay_seconds};
  die "Delay must be 10-2592000 seconds\n" unless defined($delay) && !ref($delay) && $delay =~ /\A\d+\z/ && $delay>=10 && $delay<=2592000;
  my $now=time();
  $self->_expire_reminders($now,@scope);
  # One statement keeps the per-scope admission bound atomic across connections.
  my $changed=$self->_dbh->do(q{INSERT INTO reminders(bot,network,channel,reason,created_at,due_at)
    SELECT ?,?,?,?,?,? WHERE (SELECT COUNT(*) FROM reminders WHERE bot=? AND network=? AND channel=?
    AND state IN ('armed','queued'))<20},undef,@scope,$reason,$now,$now+$delay,@scope);
  die "Maximum 20 active reminders per channel\n" unless $changed && $changed>0;
  return {id=>$self->_dbh->sqlite_last_insert_rowid,state=>'armed',due_at=>$now+$delay,channel=>$scope[2]};
}
sub list_reminders {
  my ($self,%a)=@_;
  my @scope=_reminder_scope(%a);
  $self->_expire_reminders(time(),@scope);
  my $limit=$a{limit}//20;
  die "Limit must be 1-20\n" unless !ref($limit) && $limit =~ /\A\d+\z/ && $limit>=1 && $limit<=20;
  my @where=('bot=?','network=?','channel=?'); my @bind=@scope;
  if (defined $a{cursor}) { push @where,'id<?'; push @bind,_reminder_id($a{cursor}); }
  return $self->_dbh->selectall_arrayref('SELECT * FROM reminders WHERE '.join(' AND ',@where).' ORDER BY id DESC LIMIT ?',
    {Slice=>{}},@bind,$limit);
}
sub cancel_reminder {
  my ($self,%a)=@_;
  my @scope=_reminder_scope(%a);
  my $id=_reminder_id($a{id});
  $self->_expire_reminders(time(),@scope);
  my $changed=$self->_dbh->do(q{UPDATE reminders SET state='cancelled',lease_until=NULL WHERE id=? AND bot=? AND network=? AND channel=?
    AND state IN ('armed','queued')},undef,$id,@scope);
  die "Active reminder not found in this scope\n" unless $changed && $changed>0;
  return {id=>$id,state=>'cancelled'};
}
sub claim_due_reminders {
  my ($self,%a)=@_;
  my @scope=_reminder_scope(%a);
  my $now=time();
  $self->_expire_reminders($now,@scope);
  my $rows=$self->_dbh->selectall_arrayref(q{SELECT * FROM reminders WHERE bot=? AND network=? AND channel=? AND due_at<=?
    AND (state='armed' OR (state='queued' AND lease_until<=?)) ORDER BY due_at,id LIMIT 3}, {Slice=>{}},@scope,$now,$now);
  my @claimed;
  for my $r (@$rows) {
    my $changed=$self->_dbh->do(q{UPDATE reminders SET state='queued',lease_until=? WHERE id=?
      AND (state='armed' OR (state='queued' AND lease_until<=?))},undef,$now+600,$r->{id},$now);
    push @claimed,$r if $changed && $changed>0;
  }
  return \@claimed;
}
sub release_reminder {
  my ($self,%a)=@_;
  my @scope=_reminder_scope(%a);
  return $self->_dbh->do(q{UPDATE reminders SET state='armed',lease_until=NULL WHERE id=? AND bot=? AND network=? AND channel=? AND state='queued'},
    undef,_reminder_id($a{id}),@scope);
}
sub consume_reminder {
  my ($self,%a)=@_;
  my @scope=_reminder_scope(%a);
  my $now=time();
  $self->_expire_reminders($now,@scope);
  my $changed=$self->_dbh->do(q{UPDATE reminders SET state='fired',fired_at=?,lease_until=NULL WHERE id=? AND bot=? AND network=? AND channel=? AND state='queued'},
    undef,$now,_reminder_id($a{id}),@scope);
  return $changed && $changed>0 ? 1 : 0;
}
1;
