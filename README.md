# treb

Treb is Bert backwards: a quieter attic offshoot IRC bot.

Current baseline:
- IRC-first behavior
- mission loaded from `treb.mission.txt`
- local env contract in `treb.env.example`
- Perl deps declared in `cpanfile`

This repo is the clean home for the bot, separate from the earlier Squirt/Koan testbed history.


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

