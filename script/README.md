# Bot launch scripts

## Canonical launchers
- `run-treb.sh` — start Treb normally
- `run-burt.sh` — start Burt normally
- `run-astrid.sh` — start Astrid normally

## Optional sandbox launchers
- `run-treb-sandbox.sh` — start Treb in a transient user `systemd-run` sandbox
- `run-burt-sandbox.sh` — start Burt in a transient user `systemd-run` sandbox
- `run-astrid-sandbox.sh` — start Astrid in a transient user `systemd-run` sandbox

## Helper env wrappers
- `with-treb-env.sh <cmd>` — run an arbitrary command with Treb's environment loaded
- `with-burt-env.sh <cmd>` — run an arbitrary command with Burt's environment loaded
- `with-astrid-env.sh <cmd>` — run an arbitrary command with Astrid's environment loaded

## Quick examples
- Start a bot normally:
  - `script/run-treb.sh`
  - `script/run-burt.sh`
  - `script/run-astrid.sh`
- Start all three in one tmux session:
  - `script/tmux-agents.sh`
- Start a bot in sandbox mode:
  - `script/run-treb-sandbox.sh`
- Inspect a bot's effective environment:
  - `script/with-treb-env.sh env | rg 'IRC_|BOT_|MODEL|ENGINE'`
- Run a one-off command inside a bot's env:
  - `script/with-treb-env.sh perl -E 'say $ENV{IRC_NICKNAME}'`
- Run repo-safe syntax + test checks with the intended local::lib/bootstrap env:
  - `script/check-all.sh`
  - or individually: `script/with-burt-env.sh perl -c burt.pl`

## Rule of thumb
Use `run-*.sh` as the default human-facing entrypoint.
Use `run-*-sandbox.sh` when you explicitly want the extra sandbox wrapper.
Use `with-*-env.sh` for debugging, inspection, or one-off commands.
Use `tmux-agents.sh` when you want one attachable session with Burt, Treb, and Astrid ready in separate panes.
