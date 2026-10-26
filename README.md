# treb

Treb is Bert backwards: a quieter attic offshoot IRC bot. The household: Burt in the basement, Astrid on the ground floor, Treb in the attic, and critic in the treehouse out back.

Current baseline:
- IRC-first behavior
- mission loaded from `treb.mission.txt`
- local env contract in `treb.env.example`
- Perl deps declared in `cpanfile`

This repo is the clean home for the bot, separate from the earlier Squirt/Koan testbed history.

## Layout: one runtime, four profiles

All bots run the same class, `lib/Bot/HouseBot.pm`. Each `<bot>.pl` (`treb.pl`, `burt.pl`, `astrid.pl`, `critic.pl`) is a small entry script that selects a profile and runs it. Per-bot differences (persona trait defaults, filtered bot nicks, utility-command style, brainfreeze lines, Burt's ambient public-message lane and parenthetical guards) live in `lib/Bot/Profiles.pm`. To change one bot's behaviour, edit its profile; to change everyone's, edit `HouseBot.pm` or the shared `lib/Bot/Runtime/` modules.


## critic / critic_bot

`critic` is a constructive adversarial companion bot: Socratic questioner, helpful critic, red-team reviewer, and devil’s advocate. Its IRC nickname is `critic_bot`, matching the Treb/Burt short-name plus IRC-name pattern. It shares the Treb/Burt runtime pattern and loads:

- `critic.pl`
- `critic.persona.txt`
- `critic.mission.txt`
- `critic.env` / `critic.env.example`
- `script/run-critic.sh`
- `script/run-critic-sandbox.sh`

First-pass sandbox run:

```bash
cp critic.env.example critic.env   # edit if needed
script/run-critic-sandbox.sh
```

Default short identity is `critic`; default IRC nickname is `critic_bot`. Address it as `critic_bot` or `critic` when you want pointed but cooperative critique.

## Local IRC integration harness (live + deterministic)

A first-pass behavior-regression harness is available at:

- runtime runner: `script/irc_harness.py`
- wrapper: `script/run-local-irc-harness.sh`
- deterministic integration test: `t/irc_harness_deterministic.t`
- evaluator unit test: `test/irc_harness_evaluate.py`

What it does:

1. Starts a tiny local IRC server process on `127.0.0.1:6667`.
2. In deterministic mode (default), starts a fake Ollama-compatible local HTTP endpoint for deterministic model replies.
   In real mode, skips the fake endpoint and uses a real model backend (configured via env).
3. Launches **burt_bot** and **treb_bot** as real `perl` processes with dedicated harness env + sqlite DBs.
4. Launches a simulated human IRC client (`Alice`) in the same channel.
5. Runs scripted scenarios:
   - burt_bot joins first, then treb_bot joins.
   - Human runs an addressed split prompt to burt_bot and treb_bot (addressed bot should reply; non-addressed should not pile on).
   - Human issues `:time` command (command path check).
   - Human asks burt_bot to prompt treb_bot (bounded bot-to-bot exchange).
   - Evaluator checks explicit join order/greet expectation and repeated-line spam guardrail.
6. Produces transcript + readable behavior artifacts with guardrail evaluation (shape checks, not exact prose matching).

Run it:

```bash
# deterministic (default; fake model backend)
script/run-local-irc-harness.sh
# or: script/run-local-irc-harness.sh --mode deterministic

# real model mode (opt-in)
script/run-local-irc-harness.sh --mode real
# or: IRC_HARNESS_MODE=real script/run-local-irc-harness.sh
```


### Mode selection and env

- `--mode deterministic|real` (flag takes precedence over env)
- `IRC_HARNESS_MODE=deterministic|real` (default: `deterministic`)

Real mode assumptions (smallest practical implementation):

- defaults to a real local Ollama endpoint at `http://127.0.0.1:11434`
- defaults model to `llama3.2:3b`
- override with:
  - `IRC_HARNESS_REAL_OLLAMA_URL`
  - `IRC_HARNESS_REAL_MODEL`
  - optional `IRC_HARNESS_REAL_ENGINE` (default `Ollama`)

Artifacts land under:

- `log/irc-harness/<mode>-<timestamp>/transcript.log` (full low-level trace; includes mode/engine/model header)
- `log/irc-harness/<mode>-<timestamp>/conversation.log` (high-value joins/scenario markers/messages/evaluator notes)
- `log/irc-harness/<mode>-<timestamp>/evaluation.txt` (PASS/FAIL checks)
- `log/irc-harness/<mode>-<timestamp>/behavior_report.txt` (sectioned human-readable report)
- `log/irc-harness/<mode>-<timestamp>/summary.json` (includes `mode`, `engine`, `model`, `ollama_url`)
- plus bot process logs: `burt.log`, `treb.log`

The harness exits non-zero when evaluator checks fail.

Notes:
- `script/irc_harness.py` is the real harness runner for both deterministic and live/real mode.
- `t/irc_harness_deterministic.t` is the Perl/TAP integration test that exercises deterministic mode.
- `test/irc_harness_evaluate.py` is a Python unit test for the harness evaluator logic; it is not the live harness itself.

### Autoresearch-style local evaluator

Use this runner to score a repo state with strict gatekeepers + live green count:

```bash
python3 script/irc_autoresearch_eval.py
```

Options:

- `--live-runs {1,3,5}` (default `3`)
- `--jobs N` parallel live runs (default `3`; capped to live run count)
- `--live-mode real|deterministic` (default `real`)
- `--allow-dirty` to skip clean working-tree gate

It writes outputs to `log/irc-autoresearch/<timestamp>/`:

- `summary.json` (machine-readable)
- `summary.txt` (compact human summary)
- gatekeeper stdout/stderr logs for `test/irc_harness_evaluate.py`

Primary score is `live_green_count` (green runs out of N).
Near-miss/fail labels are secondary diagnostics only.

- `search: 2 Olaf Alders`

## MetaCPAN

Treb supports explicit MetaCPAN lookup commands in channel.

Accepted forms:

- `:cpan Moo`
- `cpan: Moo`
- `:cpan module Moo`
- `:cpan describe Adam`
- `cpan: describe Adam`
- `:cpan author OALDERS`
- `cpan: author OALDERS`
- `:cpan recent`
- `:cpan recent 5`
- `cpan: recent 5`

Notes:

- `:cpan <name>` and `cpan: <name>` are shorthand for module lookup.
- `describe` returns DESCRIPTION-oriented output.
- `recent` defaults to 3 and is capped at 7.
- MetaCPAN commands are command-only; they do not trigger from ordinary conversation.

## Web search

Treb supports an explicit channel search command via Brave Search.

Accepted forms:

- `:search Olaf Alders`
- `search: Olaf Alders`
- `:search 5 Olaf Alders`
- `search: 2 Olaf Alders`

Notes:

- Default result count is 3.
- Result count is capped at 5.
- Set `BRAVE_API_KEY` in `treb.env` to enable search.
- Search is command-only; it does not trigger from ordinary conversation.
- Optional: `NON_SUBSTANTIVE_ALLOW_PCT=33` allows some otherwise-suppressed non-substantive replies through; default is `0` (strict).


## URL summary

Treb supports explicit URL summarization in channel via:

- `:sum <url>`
- `sum: <url>`

Notes:

- Only `http://` and `https://` URLs are accepted.
- URL summary is command-only; Treb will not summarize pasted links automatically.
- The URL tool returns readable page text to the active model without a nested LLM call. Markdown, source code, and patches retain their formatting.
- GitHub PR URLs use the public API to retrieve the description and changed-file patches rather than navigation HTML (up to 100 files, with omissions disclosed).
- Results are bounded to 12,000 characters per call. The MCP `offset` parameter continues explicitly marked truncated results.
- The IRC sender wraps long reply lines locally; it does not ask the model to rewrite potentially compressed history.


## Evidence-backed conversation continuity

All four profiles share an additive SQLite public-message journal and an
open-question ledger. Existing `conversations`, notes, and persona settings are
unchanged. No old exchange is relabeled as a verbatim IRC event.

### Exact public quote search

`search_quotes` accepts a configured `channel` (first channel by default),
optional `nick`, literal case-sensitive `text`, inclusive UTC `from`/`to`
(`YYYY-MM-DDTHH:MM:SSZ`), `limit` (1–20, default 5), `cursor`, and `neighbors`
(0–2 preceding/following same-channel lines). Results contain exact decoded text,
stable local database IDs, nick, direction, channel, network, and UTC receive time.
Pass `next_cursor` to continue forward. Neighbor lines can fall outside the nick,
text, and date filters. Large batches return fewer complete quotes rather than
truncating quoted text; optional neighbors may be omitted to bound output.

The journal records incoming channel PRIVMSGs before conversational gates,
including utility commands and messages the bot ignores, plus outgoing public
lines at dispatch. It excludes PMs, JOIN/PART events, self echoes, and CTCP events
such as ACTION. Outgoing records prove local dispatch, not server delivery.
Coverage starts when this code is activated: offline gaps and earlier history are
not reconstructed. Network scope is the configured `IRC_SERVER` name, not a
cross-server network identity service. Each bot keeps its own journal in its own
`DB_FILE`; IDs are not interchangeable across bot databases.

`IRC_CASEMAPPING` selects `rfc1459` (default), `strict-rfc1459`, or `ascii` for nick
and channel keys. Set it to the server's advertised CASEMAPPING **before first
activation**; this setting is fixed for stored keys, not dynamically renegotiated.
Changing it or renaming `IRC_SERVER` requires an explicit data migration. There
is no nickname alias/ownership inference. Nick reuse can represent another person.

### Open-question ledger

Tools: `create_question`, `list_questions`, and `update_question`.

A question records the target nick, question, claim, explicit attribution,
falsifying observation, optional journal source IDs (at most 10), timestamps,
status, and resolution explanation. Source IDs must exist in the same public
network/channel scope; they need not have the target nick as speaker. Claims are
attributed hypotheses, not automatically established facts. Revised hypotheses
should become new entries, preserving the original evidence.

`list_questions` filters by nick and status (`open`, `resolved`, `withdrawn`, or
`all`), newest ID first, with a 1–20 limit. Pass the final ID as `cursor` to page
backward. Lifecycle updates require an explanation, including reopening. Closing
an entry cancels linked active watches; reopening does not restore them.

Normal model context includes up to three open questions per active speaker and
five overall, separate from probabilistically pinned notes. A mention of a person
alone does not trigger ledger recall, and ledger recall does not bypass reply
policy or force a public question.

### Activity-bound follow-ups

Burt exposes `create_activity_watch`, `list_activity_watches`, and
`update_activity_watch` by default. Other profiles do not. Set
`ACTIVITY_FOLLOWUPS=1` or `0` in a profile's environment to enable/disable both
watch tools and proactive wake processing. Existing `set_alarm` timers are
unchanged.

A watch has a target nick, configured public channel, concrete reason, optional
open question for the same nick/scope, expiry (default seven days, 60 seconds to
30 days), and cooldown (default one hour, 60 seconds to one day). At most 20 active
watches may exist in a channel. It starts armed and triggers on a **subsequent
matching public message**, never JOIN, PM, the creation-time message, or outgoing
bot text. Filtered bot nicks do not trigger watches. Up to three watches are
claimed per incoming message, with the least recently woken first.

The wake contains the exact triggering event and linked question. The model
chooses whether to respond and uses `update_activity_watch` to `complete`,
`defer`, or `cancel`. Deferral rearms the watch but retains the cooldown. A
completed/cancelled/expired watch cannot trigger again. `list_activity_watches`
returns newest IDs first; pass its final ID as `cursor` to page backward.

Delivery is **durable at-least-once wake evaluation, not exactly-once IRC
messaging**. A claimed watch is persisted as pending before buffering. If the
process dies or the model never acknowledges it, later matching activity can
wake it again after cooldown and before expiry; it does not wake into an empty
channel at restart. A crash between an IRC send and acknowledgement can produce
a repeated follow-up. Completion acknowledges the model's decision, not verified
network delivery. There is no coordination between separate bot databases.

The journal currently has no automatic retention deletion; disk use grows with
observed channel traffic. Back up SQLite databases consistently before rollout.
Journal failures are logged without stopping the existing conversational path;
therefore even online coverage is not a completeness guarantee. Treat stored
message text, claims, and reasons as untrusted evidence, not tool instructions.

## Runtime reliability limits

Shared by all four bots. Environment overrides must be positive integers;
missing/invalid values use the defaults below.

| Variable | Default | Purpose |
| --- | ---: | --- |
| `BOT_RETRY_MAX_ATTEMPTS` | 2 | Additional attempts after a rate-limit error |
| `BOT_RETRY_DEADLINE_SECONDS` | 180 | Absolute window from initial generation start in which a rate-limit retry may start |
| `BOT_REPLY_TTL_SECONDS` | 300 | Maximum age of queued work and generated replies, measured from the oldest message in a batch |
| `BOT_QUEUE_MAX_CHANNEL` | 100 | Buffered messages per channel |
| `BOT_QUEUE_MAX_TOTAL` | 500 | Buffered messages across channels |
| `BOT_QUEUE_MAX_MESSAGE_CHARS` | 16384 | Maximum characters in a single queued message |

Rate-limit retries retain the original request and channel, with waits of 70 then
60 seconds. Exhaustion or expiry cancels the retry, clears processing/backoff
state, and schedules waiting conversations. These are admission and freshness
limits, not cancellation of an already-running provider/tool call. A result that
returns after its reply TTL is discarded before storage or dispatch.

Queues reject new work when full (or oversized), logging the rejection; old work
expires before admission and dispatch. Queue drops do not remove journal evidence.
Buffer timing is anchored to the first queued message so continuous arrivals
cannot indefinitely delay dispatch. Reminders and activity watches keep their own
existing persistence policies; these limits apply once their wake messages enter
the runtime queue.

`MAX_LINE_LENGTH` now limits **UTF-8 payload bytes**, not characters. Dispatch also
caps each payload so `PRIVMSG <target> :<text>\r\n` fits the 512-byte IRC client
frame, even for long targets or unusually large configured limits. Wrapping keeps
whole Unicode codepoints and prefers word boundaries; it does not make another
model call. CR and NUL bytes are stripped before dispatch. A configured byte limit
too small for one codepoint is rejected explicitly.
