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
- Run the primary live theater regression against Treb's real model:
  - `IRC_HARNESS_MODE=real IRC_HARNESS_REAL_MODEL='kimi-k2.5:cloud' IRC_HARNESS_SCENARIO=theater-grand-bordeaux script/run-local-irc-harness.sh`
- Run the backup live theater regression against Treb's real model:
  - `IRC_HARNESS_MODE=real IRC_HARNESS_REAL_MODEL='kimi-k2.5:cloud' IRC_HARNESS_SCENARIO=theater-graslin-nantes script/run-local-irc-harness.sh`
- Run the Marseille theater scenario when you specifically want to probe timing/interleaving behavior (graph data exists, but this case remains operationally flaky):
  - `IRC_HARNESS_MODE=real IRC_HARNESS_REAL_MODEL='kimi-k2.5:cloud' IRC_HARNESS_SCENARIO=theater-opera-marseille script/run-local-irc-harness.sh`
- Run the primary live museum regression against Treb's real model:
  - `IRC_HARNESS_MODE=real IRC_HARNESS_REAL_MODEL='kimi-k2.5:cloud' IRC_HARNESS_SCENARIO=museum-orsay script/run-local-irc-harness.sh`
- Run the backup live museum regression against Treb's real model:
  - `IRC_HARNESS_MODE=real IRC_HARNESS_REAL_MODEL='kimi-k2.5:cloud' IRC_HARNESS_SCENARIO=museum-bourse-commerce script/run-local-irc-harness.sh`
- Run the Vieille Charité museum scenario when you specifically want to observe DB-miss-then-fallback behavior (interesting, but not as clean as Orsay or Bourse):
  - `IRC_HARNESS_MODE=real IRC_HARNESS_REAL_MODEL='kimi-k2.5:cloud' IRC_HARNESS_SCENARIO=museum-vieille-charite script/run-local-irc-harness.sh`
- Run the primary live cinema regression against Treb's real model:
  - `IRC_HARNESS_MODE=real IRC_HARNESS_REAL_MODEL='kimi-k2.5:cloud' IRC_HARNESS_SCENARIO=cinema-cineum-cannes script/run-local-irc-harness.sh`
- Run the backup live cinema regression against Treb's real model:
  - `IRC_HARNESS_MODE=real IRC_HARNESS_REAL_MODEL='kimi-k2.5:cloud' IRC_HARNESS_SCENARIO=cinema-grand-rex script/run-local-irc-harness.sh`
  - Note: this case can be timing-sensitive (occasionally Treb answers only the follow-up `time:`); keep as backup.
- Run the primary live theme-park regression against Treb's real model:
  - `IRC_HARNESS_MODE=real IRC_HARNESS_REAL_MODEL='kimi-k2.5:cloud' IRC_HARNESS_SCENARIO=themepark-ok-corral script/run-local-irc-harness.sh`
- Run the backup live theme-park regression against Treb's real model:
  - `IRC_HARNESS_MODE=real IRC_HARNESS_REAL_MODEL='kimi-k2.5:cloud' IRC_HARNESS_SCENARIO=themepark-asterix script/run-local-irc-harness.sh`
  - Note: usually good, but has shown one miss in live runs; keep as backup.
- Run the legacy live Wikidata/Jena Marseille discovery scenario against Treb's real model:
  - `IRC_HARNESS_MODE=real IRC_HARNESS_REAL_MODEL='kimi-k2.5:cloud' IRC_HARNESS_SCENARIO=wikidata-theaters-marseille script/run-local-irc-harness.sh`
- Run the primary live castle regression against Treb's real model:
  - `IRC_HARNESS_MODE=real IRC_HARNESS_REAL_MODEL='kimi-k2.5:cloud' IRC_HARNESS_SCENARIO=castle-petite-malmaison script/run-local-irc-harness.sh`
- Run the backup live castle regression against Treb's real model:
  - `IRC_HARNESS_MODE=real IRC_HARNESS_REAL_MODEL='kimi-k2.5:cloud' IRC_HARNESS_SCENARIO=castle-petit-trianon script/run-local-irc-harness.sh`
- Run the Marseille castle scenario when you specifically want a legacy/flaky discovery probe rather than the stable regression path:
  - `IRC_HARNESS_MODE=real IRC_HARNESS_REAL_MODEL='kimi-k2.5:cloud' IRC_HARNESS_SCENARIO=wikidata-castle-marseille script/run-local-irc-harness.sh`
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

## Current venue-graph status summary
- The cumulative `wgraph` bundle workflow is now live and reloadable into Fuseki.
- Generated venue data now includes both `rdf:type` (`a`) and `wdt:P31` class triples so loader verification and Treb's live MCP queries agree.
- Confirmed live online successes after the `wdt:P31` fix include:
  - castles: `castle-petite-malmaison`
  - theaters: `theater-grand-bordeaux`
  - museums: `museum-orsay`
  - cinemas: `cinema-cineum-cannes`
  - theme parks: `themepark-ok-corral` and `themepark-asterix`/Parc Astérix-style opening-date asks
- Known imperfection: `theater-graslin-nantes` still fails live and remains under investigation rather than being treated as a stable regression.

## Rule of thumb
Use `run-*.sh` as the default human-facing entrypoint.
Use `run-*-sandbox.sh` when you explicitly want the extra sandbox wrapper.
Use `with-*-env.sh` for debugging, inspection, or one-off commands.
Use `tmux-agents.sh` when you want one attachable session with Burt, Treb, and Astrid ready in separate panes.

## Dependency/bootstrap gotcha
Do not assume a bare shell reflects this repo's runnable Perl environment.
Treb/Burt/Astrid may rely on user-local Perl deps installed under `~/perl5` via `local::lib`, not globally installed system modules.
If a raw `perl`/`prove` command says something like `Can't locate Moose.pm`, first rerun through the repo wrapper:
- `script/with-burt-env.sh prove -lv t/...`
- `script/with-treb-env.sh perl -c treb.pl`
- `script/check-all.sh`
Treat the wrapper scripts as the canonical bootstrap path before concluding a dependency is missing.
