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
2. Starts a fake Ollama-compatible local HTTP endpoint for deterministic model replies.
3. Launches **Burt** and **Treb** as real `perl` processes with dedicated harness env + sqlite DBs.
4. Launches a simulated human IRC client (`Alice`) in the same channel.
5. Runs scripted scenarios:
   - Burt joins first, then Treb joins.
   - Human sends substantive prompts to both bots.
   - Human issues `:time` command (command path check).
   - Human asks Burt to prompt Treb (bounded bot-to-bot exchange).
6. Produces transcript + lightweight guardrail evaluation (shape checks, not exact prose matching).

Run it:

```bash
script/run-local-irc-harness.sh
```

Artifacts land under:

- `log/irc-harness/<timestamp>/transcript.log`
- `log/irc-harness/<timestamp>/evaluation.txt`
- `log/irc-harness/<timestamp>/summary.json`
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

