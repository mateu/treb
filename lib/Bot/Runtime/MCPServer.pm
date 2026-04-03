package Bot::Runtime::MCPServer;

use strict;
use warnings;

use Exporter 'import';
use MCP::Server;
use POE::Kernel ();

our @EXPORT_OK = qw(build_mcp_server);

sub _trim {
  my ($value) = @_;
  $value = '' unless defined $value;
  $value =~ s/^\s+|\s+$//g;
  return $value;
}

sub _positive_int {
  my ($value) = @_;
  return undef unless defined $value && $value =~ /^\d+$/;
  my $int = int($value);
  return undef if $int < 1;
  return $int;
}

sub _clamp_numeric {
  my (%args) = @_;
  my $value   = $args{value};
  my $default = $args{default};
  my $min     = $args{min};
  my $max     = $args{max};

  $value = $default unless defined $value && $value =~ /^-?\d+(?:\.\d+)?$/;
  $value = int($value);
  $value = $min if $value < $min;
  $value = $max if $value > $max;
  return $value;
}

sub _log_tool_call {
  my (%args) = @_;
  my $self = $args{self};
  return unless $self->_mcp_tool_logging_enabled;
  $self->info($args{message});
}

sub _tool_specs {
  my (%args) = @_;
  my $self = $args{self};

  return [
    {
      name         => 'stay_silent',
      description  => 'Choose not to respond to the current messages. Use this when the conversation does not involve you, is not interesting, or nobody is talking to you. It is perfectly fine to say nothing.',
      input_schema => {
        type       => 'object',
        properties => {
          reason => { type => 'string', description => 'Brief internal reason for staying silent (not shown to anyone)' },
        },
        required => ['reason'],
      },
      code => sub {
        my ($tool, $tool_args) = @_;
        return $tool->text_result('__SILENT__');
      },
    },
    {
      name         => 'set_alarm',
      description  => 'Set an alarm that wakes you up after a delay in seconds. Like a timer or reminder - when it fires, you get woken up with the reason and can decide what to do: respond, call tools, or stay silent. You do NOT pre-write a message; you decide what to do when the alarm fires.',
      input_schema => {
        type       => 'object',
        properties => {
          reason        => { type => 'string', description => 'Why you are setting this alarm - this will be shown to you when it fires' },
          delay_seconds => { type => 'number', description => 'How many seconds to wait (10-3600)' },
        },
        required => ['reason', 'delay_seconds'],
      },
      code => sub {
        my ($tool, $tool_args) = @_;
        my $reason = _trim($tool_args->{reason});
        return $tool->text_result('Reason is required.') unless length $reason;
        my $delay = _clamp_numeric(
          value   => $tool_args->{delay_seconds},
          default => 10,
          min     => 10,
          max     => 3600,
        );
        my $channel = $self->_default_channel;
        POE::Kernel->delay_add( _alarm_fired => $delay, $channel, $reason );
        return $tool->text_result("Alarm set for ${delay}s: $reason");
      },
    },
    {
      name         => 'cpan_module',
      description  => 'Look up compact CPAN module metadata for a module name, like the :cpan module command.',
      input_schema => {
        type       => 'object',
        properties => {
          name => { type => 'string', description => 'CPAN module name, e.g. Moo or Bracket' },
        },
        required => ['name'],
      },
      code => sub {
        my ($tool, $tool_args) = @_;
        my $name = _trim($tool_args->{name});
        return $tool->text_result('Module name is required.') unless length $name;
        my $line = $self->_cpan_lookup('module', $name);
        _log_tool_call(self => $self, message => "MCP cpan_module called => $name");
        return $tool->text_result($line);
      },
    },
    {
      name         => 'summarize_url',
      description  => 'Fetch and summarize an http(s) URL for IRC chat.',
      input_schema => {
        type       => 'object',
        properties => {
          url => { type => 'string', description => 'Absolute URL to summarize (http or https)' },
        },
        required => ['url'],
      },
      code => sub {
        my ($tool, $tool_args) = @_;
        my $url = _trim($tool_args->{url});
        return $tool->text_result('URL is empty.') unless length $url;
        my $line = $self->_summarize_url($url);
        _log_tool_call(self => $self, message => "MCP summarize_url called => $url");
        return $tool->text_result($line);
      },
    },
    {
      name         => 'search_web',
      description  => 'Search the web and return compact result lines. Defaults to 2 results for tool use.',
      input_schema => {
        type       => 'object',
        properties => {
          query => { type => 'string', description => 'Search query text' },
          limit => { type => 'number', description => 'How many results to return (1-5, default 2)' },
        },
        required => ['query'],
      },
      code => sub {
        my ($tool, $tool_args) = @_;
        my $query = _trim($tool_args->{query});
        return $tool->text_result('Search query is empty.') unless length $query;

        my $limit = _clamp_numeric(
          value   => exists $tool_args->{limit} ? $tool_args->{limit} : undef,
          default => 2,
          min     => 1,
          max     => 5,
        );
        my $line = $self->_search_web($query, $limit);
        _log_tool_call(self => $self, message => "MCP search_web called => $query (limit=$limit)");
        return $tool->text_result($line);
      },
    },
    {
      name         => 'current_time',
      description  => 'Get the current local date and time in America/Denver. Use this when you need exact time awareness instead of guessing.',
      input_schema => {
        type       => 'object',
        properties => {},
      },
      code => sub {
        my ($tool, $tool_args) = @_;
        my $line = 'Current local time: ' . $self->_current_local_time_text . '.';
        _log_tool_call(self => $self, message => "MCP current_time called => $line");
        return $tool->text_result($line);
      },
    },
    {
      name         => 'time_in',
      description  => 'Get the current date and time in a specific IANA timezone, for example Europe/London or America/New_York.',
      input_schema => {
        type       => 'object',
        properties => {
          zone => { type => 'string', description => 'IANA timezone name like Europe/London' },
        },
        required => ['zone'],
      },
      code => sub {
        my ($tool, $tool_args) = @_;
        my $zone = _trim($tool_args->{zone});
        return $tool->text_result('Timezone is required.') unless length $zone;
        my $line = 'Current time in ' . $zone . ': ' . $self->_time_text_for_zone($zone) . '.';
        _log_tool_call(self => $self, message => "MCP time_in called for $zone => $line");
        return $tool->text_result($line);
      },
    },
    {
      name         => 'recall_history',
      description  => 'Search past conversations by keyword. Returns recent matching exchanges.',
      input_schema => {
        type       => 'object',
        properties => {
          query => { type => 'string', description => 'Keyword to search for' },
        },
        required => ['query'],
      },
      code => sub {
        my ($tool, $tool_args) = @_;
        my $query = _trim($tool_args->{query});
        return $tool->text_result('History query is required.') unless length $query;
        my $result = $self->memory->recall($query);
        return $tool->text_result($result || 'No matching conversations found.');
      },
    },
    {
      name         => 'save_note',
      description  => 'Save a note about a specific user to your persistent memory. Use this to learn about people over time - their interests, preferences, what they work on, their personality, hostmask/host they connect from, etc.',
      input_schema => {
        type       => 'object',
        properties => {
          nick    => { type => 'string', description => 'The IRC nick this note is about' },
          content => { type => 'string', description => 'What you want to remember about this person' },
        },
        required => ['nick', 'content'],
      },
      code => sub {
        my ($tool, $tool_args) = @_;
        my $nick = _trim($tool_args->{nick});
        return $tool->text_result('Nick is required.') unless length $nick;
        my $content = _trim($tool_args->{content});
        return $tool->text_result('Note content is required.') unless length $content;

        $self->memory->save_note($nick, $content);
        return $tool->text_result("Note saved about $nick.");
      },
    },
    {
      name         => 'recall_notes',
      description  => 'List or search your saved notes. Provide nick to see all notes about a person, query to search by keyword, or both.',
      input_schema => {
        type       => 'object',
        properties => {
          query => { type => 'string', description => 'Optional: keyword to search for in notes' },
          nick  => { type => 'string', description => 'Optional: only notes about this nick' },
        },
      },
      code => sub {
        my ($tool, $tool_args) = @_;
        my $nick = _trim($tool_args->{nick});
        my $query = _trim($tool_args->{query});
        my $result = $self->memory->recall_notes((length $nick ? $nick : undef), $query);
        return $tool->text_result($result || 'No matching notes found.');
      },
    },
    {
      name         => 'update_note',
      description  => 'Update an existing note by its ID. Use recall_notes first to find the ID.',
      input_schema => {
        type       => 'object',
        properties => {
          id      => { type => 'number', description => 'The note ID (shown as #N in recall_notes output)' },
          content => { type => 'string', description => 'The new content for this note' },
        },
        required => ['id', 'content'],
      },
      code => sub {
        my ($tool, $tool_args) = @_;
        my $id = _positive_int($tool_args->{id});
        return $tool->text_result('Note id must be a positive integer.') unless defined $id;
        my $content = _trim($tool_args->{content});
        return $tool->text_result('Note content is required.') unless length $content;

        if ($self->memory->update_note($id, $content)) {
          return $tool->text_result("Note #$id updated.");
        }
        return $tool->text_result("Note #$id not found.");
      },
    },
    {
      name         => 'delete_note',
      description  => 'Delete a note by its ID. Use recall_notes first to find the ID.',
      input_schema => {
        type       => 'object',
        properties => {
          id => { type => 'number', description => 'The note ID to delete (shown as #N in recall_notes output)' },
        },
        required => ['id'],
      },
      code => sub {
        my ($tool, $tool_args) = @_;
        my $id = _positive_int($tool_args->{id});
        return $tool->text_result('Note id must be a positive integer.') unless defined $id;

        if ($self->memory->delete_note($id)) {
          return $tool->text_result("Note #$id deleted.");
        }
        return $tool->text_result("Note #$id not found.");
      },
    },
    {
      name         => 'send_private_message',
      description  => 'Send a private message (PM) to a user. You MUST provide a reason that explicitly states who asked you to send this message. Be transparent - never pretend a PM is your own idea if someone else told you to send it.',
      input_schema => {
        type       => 'object',
        properties => {
          nick    => { type => 'string', description => 'The nick to send the private message to' },
          message => { type => 'string', description => 'The message to send' },
          reason  => { type => 'string', description => 'Who asked you to send this and why. Leave empty if the recipient themselves asked you to PM them.' },
        },
        required => ['nick', 'message'],
      },
      code => sub {
        my ($tool, $tool_args) = @_;
        my $nick = _trim($tool_args->{nick});
        return $tool->text_result('Nick is required.') unless length $nick;
        my $message = _trim($tool_args->{message});
        return $tool->text_result('Message is required.') unless length $message;
        my $reason = _trim($tool_args->{reason});

        $self->info("PM to $nick: $message" . ($reason ? " (reason: $reason)" : ''));
        $self->privmsg($nick => $message);
        $self->privmsg($nick => "(reason: $reason)") if $reason;
        return $tool->text_result("Private message sent to $nick.");
      },
    },
    {
      name         => 'whois',
      description  => 'Look up information about an IRC user (real name, host, channels, idle time, etc.). The result arrives asynchronously - you will see it as a system message shortly after calling this.',
      input_schema => {
        type       => 'object',
        properties => {
          nick => { type => 'string', description => 'The nick to look up' },
        },
        required => ['nick'],
      },
      code => sub {
        my ($tool, $tool_args) = @_;
        my $nick = _trim($tool_args->{nick});
        return $tool->text_result('Nick is required.') unless length $nick;
        $self->irc->yield(whois => $nick);
        return $tool->text_result("WHOIS request sent for $nick. Results will arrive shortly as a system message.");
      },
    },
  ];
}

sub build_mcp_server {
  my (%args) = @_;
  my $self = $args{self} or die 'build_mcp_server requires self';
  my $server_name = $args{server_name} || 'bot-tools';

  my $server = MCP::Server->new(name => $server_name, version => '1.0');
  for my $spec (@{_tool_specs(self => $self)}) {
    $server->tool(%{$spec});
  }

  return $server;
}

1;
