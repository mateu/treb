# Treb sandboxing for dummies

This is the simple version.

## What this does

Treb is allowed to:
- run from `/home/hunter/dev/treb`
- read and write inside that directory
- use the network for IRC, search, and URL summaries

Treb is *not* being put in a perfect prison. This is just a safer launch shape than `perl treb.pl` in a random shell.

## Files

- `script/run-treb.sh` → normal reproducible launcher
- `script/run-treb-sandbox.sh` → same launcher, but wrapped in a systemd sandbox scope

## Normal start

From the repo directory:

```bash
./script/run-treb.sh
```

This:
- moves into the repo
- activates your local Perl library if present
- loads `treb.env`
- runs `treb.pl`

## Sandboxed start

From the repo directory:

```bash
./script/run-treb-sandbox.sh
```

This uses `systemd-run --user --scope` to add a few safety rails:
- `NoNewPrivileges=yes`
- `PrivateTmp=yes`
- `ProtectSystem=strict`
- writable path limited to `/home/hunter/dev/treb`

## Recommended tmux usage

Start a tmux session:

```bash
tmux new -s treb
```

Then run:

```bash
cd /home/hunter/dev/treb
./script/run-treb-sandbox.sh
```

Detach with:

```bash
Ctrl-b d
```

Reattach with:

```bash
tmux attach -t treb
```

## If the sandbox launch fails

Try the plain launcher first:

```bash
cd /home/hunter/dev/treb
./script/run-treb.sh
```

If plain works but sandbox fails, the problem is probably sandbox restrictions rather than Treb itself.

## What this does NOT do

- It does not block outbound network.
- It does not separate code from runtime data.
- It does not make Treb bulletproof.

It just gives you a cleaner, safer way to run it.

## Good next step later

If Treb becomes stable and permanent, the next upgrade is:
- dedicated user
- real systemd service
- separate runtime data dir
