# Burt coding and public gists on clawd

Opt-in tools: `run_code` and `publish_gist`. Disabled unless
`BURT_WORKBENCH_SOCKET` is set, and never registered for another bot profile.
Example in irc.perl.org `#ai`:

> burt_bot: write a Perl FizzBuzz program for 1..30, add tests for 3, 5 and 15,
> run the tests, and post the source and tests as a public gist.

## Boundaries

* **IRC runtime:** `script/run-burt-isolated.sh` uses a Bubblewrap mount/PID/user
  namespace. Only `/usr`, read-only Perl dependencies, selected read-only bot
  code/personas, its own configuration, writable `/state`, disposable `/tmp`,
  DNS/CA/timezone files, and the broker's socket directory are mounted. Host
  homes, publisher files, other bots, D-Bus/systemd sockets and host processes
  are absent. There is no generic host shell/file tool. It retains host network
  access for IRC, model APIs and existing web tools; this is **not an egress
  allowlist**. Its model credential is necessarily available to its runtime.
* **Generated programs:** the broker's `runner.py` uses fresh network/PID/mount
  namespaces, no credentials or bot state, read-only `/usr`, writable tmpfs,
  cgroup limits (256 MiB RAM/no swap/32 tasks/20 seconds), 64 KiB output and
  bounded text inputs. Absolute Python/Perl/sh argv only, executed inside the
  sandbox. Never an unsandboxed fallback; missing dependencies fail the job.
* **Publisher:** a separate host-side service owns the narrow Unix socket API.
  It runs the isolated runner, journals jobs in SQLite and posts only stored
  immutable **input source/test files**, never host paths, symlinks, generated
  files, or stdout. Generated files are discarded. It never executes published
  content on the host. A successful exit is not a code-quality/security review.

These are host-kernel namespace boundaries, not virtual machines or separate
host accounts. Trusted host processes under hunter remain trusted; the bot has
neither host filesystem nor host process-manager access.

## Publishing and authorization

Classic PAT owned by `burt-agent`, **gist scope only**, stored at
`~/.config/burt-publisher/gist.token`, parent 0700/file 0600. Do not reuse the
repository-scoped token or operator's `gh` login. Identity is checked before
POST. Only api.github.com is used; redirects/proxy environment are disabled.
Every gist is **public**, with a flat filename set supplied to `run_code`.
No repository pushes, package installs, secret access or arbitrary HTTP tool.

Authorization is derived from the active runtime envelope: Burt identity,
irc.perl.org, #ai, unexpired directly addressed human coding request. Publication
also requires the word “gist” in that request. Model arguments cannot change
network/channel/request scope. Any human in #ai can ask; nick matching is **not
authenticated owner identity**. Reminder/bot/ambient/history-only turns cannot
publish. No independent external-source instructions can create authority,
although this is not a semantic intent or prompt-injection proof.

Exact bundles/results survive service restart. Up to 5 attempts and 1 submission
per turn, 30 executions/hour, 10 submissions/day globally. Runs/publications are
idempotent per request and exact bundle. Jobs must pass and be <15 minutes old.
Failed/resource-killed/output-truncated jobs cannot publish. Lost GitHub replies
leave an uncertain record: reconcile manually, never blindly retry. Broker
restart during a POST leaves `publishing`, also fail-closed. Ordinary records
expire after seven days; ambiguous publication records are retained.

## Installation / verification

Source: `lib/Bot/Runtime/Workbench.pm`, `script/workbench/`, and the isolation
launcher. Install broker files into `~/.local/share/burt-workbench/`, its unit
into `~/.config/systemd/user/`, then enable `burt-workbench.service`.
Prepare a private `~/.local/share/burt-irc/burt.env` and data directory. Stop the
existing Burt service and use SQLite backup to migrate its DB into
`~/.local/share/burt-irc/data/burt.sqlite`; keep rollback copies. Pin source to
an exact committed release directory. Override only `burt-sandbox.service`'s
ExecStart to that release's `script/run-burt-isolated.sh` and set
`BURT_SOURCE_ROOT` to it; require/order after the broker. Add a 512 MiB/64-task
service cap. Other bot units remain stopped. Never start a duplicate IRC bot.

`script/run-burt-isolated.sh check` compiles inside the actual bot namespace.
`... probe` asserts hidden host/other-bot files and credentials, read-only code,
own state and broker connectivity. `t/workbench.t` checks runtime gates.
`python3 -m unittest test_broker.py` in `script/workbench/` checks publisher
immutability/idempotence/failure isolation/quotas. Existing `verify.py` in the
operator prototype checks real runner isolation/resource bounds.

Optional **publishing** acceptance check: `script/run-burt-isolated.sh model-check`
creates a real model-backed FizzBuzz project and public gist through the same
tools, inside the same filesystem boundary. It uses an explicit synthetic
operator #ai envelope, without connecting another IRC client or sending any IRC
messages. This is not a no-side-effect diagnostic; run only when publication is
authorized. The normal start mode never mounts this smoke script.

To roll back: stop Burt, preserve the new live DB, restore the saved service
configuration and (if retaining new conversation/reminder state) SQLite-backup
the new DB back to its original DB path. Reload systemd and start only the
original `burt-sandbox.service`. Do not delete the new DB or publication journal.
