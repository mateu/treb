package Bot::MemoryStore;

use strict;
use warnings;

use Moose;
use DBI;

has db_file => ( is => 'ro', default => sub { $ENV{DB_FILE} || 'ai-bot.db' } );
has _dbh => ( is => 'ro', lazy => 1, builder => '_build_dbh' );

sub _build_dbh {
  my ($self) = @_;
  my $dbh = DBI->connect('dbi:SQLite:dbname=' . $self->db_file, '', '', {
    RaiseError => 1, sqlite_unicode => 1,
  });
  $dbh->do('CREATE TABLE IF NOT EXISTS conversations (
    id INTEGER PRIMARY KEY, nick TEXT, message TEXT, response TEXT,
    channel TEXT, created_at DATETIME DEFAULT CURRENT_TIMESTAMP
  )');
  $dbh->do('CREATE TABLE IF NOT EXISTS notes (
    id INTEGER PRIMARY KEY, nick TEXT, content TEXT,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
  )');
  $dbh->do('CREATE TABLE IF NOT EXISTS persona_settings (
    id INTEGER PRIMARY KEY,
    bot_name TEXT NOT NULL,
    trait_key TEXT NOT NULL,
    trait_value TEXT NOT NULL,
    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(bot_name, trait_key)
  )');
  return $dbh;
}

sub store_conversation {
  my ($self, %a) = @_;
  $self->_dbh->do(
    'INSERT INTO conversations (nick, message, response, channel) VALUES (?,?,?,?)',
    undef, @a{qw(nick message response channel)},
  );
}

sub recall {
  my ($self, $query, $limit) = @_;
  $limit //= 5;
  my $rows = $self->_dbh->selectall_arrayref(
    'SELECT nick, message, response FROM conversations WHERE message LIKE ? OR response LIKE ? ORDER BY id DESC LIMIT ?',
    { Slice => {} }, "%$query%", "%$query%", $limit,
  );
  return join("\n---\n", map { "<$_->{nick}> $_->{message}\n$_->{response}" } @$rows);
}

sub save_note {
  my ($self, $nick, $content) = @_;
  $self->_dbh->do('INSERT INTO notes (nick, content) VALUES (?,?)', undef, $nick, $content);
}

sub recall_notes {
  my ($self, $nick, $query, $limit) = @_;
  $limit //= 10;
  my $rows;
  if ($nick) {
    $rows = $self->_dbh->selectall_arrayref(
      'SELECT id, nick, content FROM notes WHERE nick = ? AND content LIKE ? ORDER BY id DESC LIMIT ?',
      { Slice => {} }, $nick, "%$query%", $limit,
    );
  } else {
    $rows = $self->_dbh->selectall_arrayref(
      'SELECT id, nick, content FROM notes WHERE content LIKE ? ORDER BY id DESC LIMIT ?',
      { Slice => {} }, "%$query%", $limit,
    );
  }
  return join("\n", map { "#$_->{id} [$_->{nick}] $_->{content}" } @$rows);
}

sub get_persona_settings {
  my ($self, $bot_name) = @_;
  my $rows = $self->_dbh->selectall_arrayref(
    'SELECT trait_key, trait_value FROM persona_settings WHERE bot_name = ? ORDER BY trait_key',
    { Slice => {} }, $bot_name,
  );
  return { map { $_->{trait_key} => $_->{trait_value} } @$rows };
}

sub set_persona_setting {
  my ($self, $bot_name, $trait_key, $trait_value) = @_;
  $self->_dbh->do(
    q{INSERT INTO persona_settings (bot_name, trait_key, trait_value, updated_at)
      VALUES (?,?,?,CURRENT_TIMESTAMP)
      ON CONFLICT(bot_name, trait_key)
      DO UPDATE SET trait_value=excluded.trait_value, updated_at=CURRENT_TIMESTAMP},
    undef, $bot_name, $trait_key, "$trait_value",
  );
}

sub update_note {
  my ($self, $id, $content) = @_;
  my $rows = $self->_dbh->do('UPDATE notes SET content = ? WHERE id = ?', undef, $content, $id);
  return $rows > 0;
}

sub delete_note {
  my ($self, $id) = @_;
  my $rows = $self->_dbh->do('DELETE FROM notes WHERE id = ?', undef, $id);
  return $rows > 0;
}

__PACKAGE__->meta->make_immutable;

1;
