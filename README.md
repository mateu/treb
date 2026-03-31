# treb

Treb is Bert backwards: a quieter attic offshoot IRC bot.

Current baseline:
- IRC-first behavior
- mission loaded from `treb.mission.txt`
- local env contract in `treb.env.example`
- Perl deps declared in `cpanfile`

This repo is the clean home for the bot, separate from the earlier Squirt/Koan testbed history.

## Local IRC integration harness (Burt + Treb)

A first-pass behavior-regression harness is available at:

- `script/irc_harness.py`
- wrapper: `script/run-local-irc-harness.sh`

What it does:

1. Starts a tiny local IRC server process on `127.0.0.1:6667`.
2. In deterministic mode (default), starts a fake Ollama-compatible local HTTP endpoint for deterministic model replies.
   In real mode, skips the fake endpoint and uses a real model backend (configured via env).
3. Launches **Burt** and **Treb** as real `perl` processes with dedicated harness env + sqlite DBs.
4. Launches a simulated human IRC client (`Alice`) in the same channel.
5. Runs scripted scenarios:
   - Burt joins first, then Treb joins.
   - Human runs an addressed split prompt to Burt and Treb (addressed bot should reply; non-addressed should not pile on).
   - Human issues `:time` command (command path check).
   - Human asks Burt to prompt Treb (bounded bot-to-bot exchange).
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
- The summarizer fetches a single page, extracts readable text, and asks the LLM for a short factual summary.

