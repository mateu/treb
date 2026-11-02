# Operator friends

Friends are nick-only identities folded with Bot::IRCIdentity::irc_fold (including
the configured IRC_CASEMAPPING); there is no hostmask authentication. Anyone using
a listed nick receives the register. Friendship grants no authority: the GitHub
writer allowlist and all tool policies are unchanged.

Any profile may opt in with BOT_FRIENDS_FILE. Burt additionally accepts
BURT_FRIENDS_FILE, taking precedence. No file is selected implicitly.
BOT_FRIEND_JOIN_COOLDOWN_SECONDS defaults to 21600 (6 hours); a nonnegative
integer of up to eight digits is accepted. Cooldowns are per folded nick/channel,
in memory, reset on restart. Netsplit quits seed cooldowns to suppress reconnect
greetings. Within cooldown joins follow the ordinary greeting policy.
One collective greeting is requested when multiple friends join in a batch.
Ambient reply probability is deliberately unchanged.

The file is loaded once per process. Missing, malformed, oversized (>64 KiB),
duplicate folded nicks, invalid records, more than 20 friends, and about/tone
values over 500 characters disable the feature with a log message. Restart after
changing configuration. about and tone are optional descriptive strings, not
privilege or policy overrides. Profiles appear only when relevant to the current
batch (speaker, join, or exact nick mention); they are never a global roster.
The existing conversation history may still remember earlier relevant context.

## Deployment (operator only; not performed by this PR)

1. Copy burt.friends.example.json to
   ~/.local/share/burt-irc/burt.friends.json and replace placeholder blurbs.
   Keep ownership with the operator and permissions 0600.
2. Set BURT_FRIENDS_FILE=/app/burt.friends.json in the existing host file
   ~/.local/share/burt-irc/burt.env. Optionally set
   BOT_FRIEND_JOIN_COOLDOWN_SECONDS=21600 there.
3. Deploy this code through the normal operator process and restart Burt.
   script/run-burt-isolated.sh adds an optional read-only bind of that exact
   host JSON to /app/burt.friends.json if it exists. It is outside writable
   /state; do not put operator configuration in the model-writable state tree.
4. Confirm the startup/first-event logs and a controlled friend join. Do not
   repeatedly rejoin to test: cooldown is intentional. No token changes needed.

For a non-isolated bot, point BOT_FRIENDS_FILE to an operator-owned read-only file.
No other bot is enabled by the example or launcher change.
