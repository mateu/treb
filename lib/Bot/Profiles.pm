package Bot::Profiles;

# Per-bot settings for the household. Everything that differs between Treb,
# Burt, Astrid and critic lives here; the runtime itself is Bot::HouseBot.

use strict;
use warnings;

use Exporter 'import';
our @EXPORT_OK = qw(profile_for profile_names);

my @BASE_BRAINFREEZE = (
  '*brainfreeze*',
  '*buffering...*',
  '*hamster needs a breather*',
  '*neurons recharging*',
  '*getty forgot to pay the electricity bill again*',
  '*thinking intensifies... slowly*',
);

my %PROFILES = (
  treb => {
    trait_defaults => {
      ambient_public_reply_pct     => 0,
      public_thread_window_seconds => 0,
      bot_reply_pct                => 50,
      bot_reply_max_turns          => 1,
      non_substantive_allow_pct    => 0,
    },
    mcp_server_name            => 'bert-tools',
    default_filtered_bot_nicks => 'burt_bot',
    bare_utility_commands      => 1,
    brainfreeze                => [@BASE_BRAINFREEZE, '*basement WiFi acting up*'],
    allow_bert_non_substantive => 1,
    public_messages            => 'standard',
    utility_style              => 'strict',
    utility_notes_mode         => 'direct_only',
  },
  astrid => {
    trait_defaults => {
      ambient_public_reply_pct     => 0,
      public_thread_window_seconds => 0,
      bot_reply_pct                => 25,
      bot_reply_max_turns          => 1,
      non_substantive_allow_pct    => 0,
    },
    mcp_server_name            => 'bert-tools',
    default_filtered_bot_nicks => 'burt_bot',
    bare_utility_commands      => 0,
    brainfreeze                => [@BASE_BRAINFREEZE, '*basement WiFi acting up*'],
    allow_bert_non_substantive => 1,
    public_messages            => 'standard',
    utility_style              => 'relaxed',
    utility_notes_mode         => 'utility_prefixed',
  },
  critic => {
    default_nick          => 'critic_bot',
    default_identity_slug => 'critic',
    trait_defaults => {
      ambient_public_reply_pct     => 0,
      public_thread_window_seconds => 0,
      bot_reply_pct                => 50,
      bot_reply_max_turns          => 1,
      non_substantive_allow_pct    => 0,
    },
    mcp_server_name            => 'bert-tools',
    default_filtered_bot_nicks => 'burt_bot',
    bare_utility_commands      => 1,
    brainfreeze                => [@BASE_BRAINFREEZE, '*treehouse WiFi acting up*', '*rope ladder jammed*'],
    allow_bert_non_substantive => 1,
    public_messages            => 'standard',
    utility_style              => 'strict',
    utility_notes_mode         => 'direct_only',
  },
  # Burt is intentionally more conversational/atmospheric: ambient replies,
  # an open-thread window, a one-reply lock for the filtered bot lane, and
  # extra guards against parenthetical stage directions.
  burt => {
    trait_defaults => {
      ambient_public_reply_pct     => 50,
      public_thread_window_seconds => 45,
      bot_reply_pct                => 25,
      bot_reply_max_turns          => 1,
      non_substantive_allow_pct    => 0,
    },
    mcp_server_name            => 'burt-tools',
    default_filtered_bot_nicks => '',
    bare_utility_commands      => 0,
    brainfreeze                => [
      (map { s/getty/geteu/r } @BASE_BRAINFREEZE), '*basement WiFi acting up*',
    ],
    allow_bert_non_substantive => 0,
    public_messages            => 'ambient',
    utility_style              => 'relaxed',
    utility_notes_mode         => 'direct_only',
    parenthetical_guards       => 1,
    return_cumulative_send     => 1,
  },
);

sub profile_names { sort keys %PROFILES }

sub profile_for {
  my ($name) = @_;
  die 'profile_for requires a profile name' unless defined $name && length $name;
  my $profile = $PROFILES{lc $name}
    or die "Unknown bot profile '$name' (known: " . join(', ', profile_names()) . ')';
  return { name => lc $name, %$profile };
}

1;
