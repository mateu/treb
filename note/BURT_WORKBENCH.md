# Burt coding and public publishing on clawd

Opt-in tools: `run_code`, `publish_gist`, `read_repo_project`,
`run_repo_project`, and `publish_repo`. Disabled unless
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
No package installs, secret access or arbitrary HTTP tool. Repository publishing
uses a separate fine-grained credential as described below.

Authorization is derived from the active runtime envelope: Burt identity,
irc.perl.org, #ai, unexpired directly addressed human coding request. Publication
also requires the word “gist” in that request. Model arguments cannot change
network/channel/request scope. Any human in #ai can ask; nick matching is **not
authenticated owner identity**. Reminder/bot/ambient/history-only turns cannot
publish. No independent external-source instructions can create authority,
although this is not a semantic intent or prompt-injection proof.

Repository tools are fixed to public `burt-agent/workspace`. The separate
`~/.config/burt-publisher/github.token` must authenticate as `burt-agent`, with
push access to this repository; parent 0700/file 0600. It never enters either
namespace. The publisher uses GitHub's tree/commit/ref API, not a shell or Git
checkout, and refuses redirects/proxies.

* `read_repo_project(branch, project)`: only `burt/<lowercase-slug>` branches;
  missing branches read from `main`. Returns the current `base_sha` and complete
  project text bundle, relative to `projects/<project>/`.
* `run_repo_project(branch, project, base_sha, files, argv, title)`: test the
  **complete desired project**, including unchanged source/tests/docs. Safe
  nested paths are supported. 32 files/128 KiB aggregate UTF-8 source; no hidden files, symlinks,
  submodules or binary files. Omitted existing project files are deleted upon
  publication; everything outside the selected project is preserved.
* `publish_repo(id)`: publishes only that stored successful bundle. Requires a
  current addressed human coding request containing `repo`/`repository` and
  `publish`/`push`/`commit`. It cannot change destination or publish gist jobs.
  Rechecks branch head; stale bases require rereading and retesting. Creates
  `burt/*` branches or non-force updates them; never writes `main`, opens PRs,
  merges or executes repository content. Returns an actual commit URL.

Example initial request (after recovering API details):

> burt_bot: read branch burt/dictionary, project dictionary in the workspace repo.
> Write a Perl dictionary client with fixture-based tests. If endpoint or schema
> details are missing, use a clearly labelled configurable stub, document all
> assumptions, and do not claim live API compatibility. Test the complete project
> and publish it to that repository branch; return the commit link and results.

Continuation:

> burt_bot: read project dictionary on branch burt/dictionary in the workspace
> repo. Add URL-encoding edge-case tests and fix any failures. Preserve existing
> files, test the complete project and publish the update to the same repo branch.

All channel humans have the same narrow publishing authority as for gists;
this is not authenticated owner-only access. Gist/repository submission quotas
are shared. Repository partial-write/lost-reply failures remain uncertain, even
if only unreachable Git objects may have been created. The operator must inspect
GitHub branch heads and the journal; do not blindly resubmit.

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
`python3 -m unittest discover -s script/workbench -p 'test_*.py'` from the repository root checks publisher
immutability/idempotence/failure isolation/quotas. Existing `verify.py` in the
operator prototype checks real runner isolation/resource bounds.

Optional **publishing** acceptance check: `script/run-burt-isolated.sh model-check`
creates a real model-backed FizzBuzz project and public gist through the same
tools, inside the same filesystem boundary. It uses an explicit synthetic
operator #ai envelope, without connecting another IRC client or sending any IRC
messages. This is not a no-side-effect diagnostic; run only when publication is
authorized. The normal start mode never mounts this smoke script.
`model-repo-check` and `model-repo-continue-check` perform real model-backed
initial/continuation acceptance checks in `projects/repository-smoke/` on branch
`burt/tool-smoke`. These publish real commits but send no IRC messages. Verify
the public tree against the immutable journal bundle after both steps.

To roll back: stop Burt, preserve the new live DB, restore the saved service
configuration and (if retaining new conversation/reminder state) SQLite-backup
the new DB back to its original DB path. Reload systemd and start only the
original `burt-sandbox.service`. Do not delete the new DB or publication journal.

## Current clawd deployment

The repository tools run from pinned source
`/home/hunter/.local/share/burt-irc/releases/fabf3cb`, not `~/dev/treb`.
The bot database remains `~/.local/share/burt-irc/data/burt.sqlite`, and the
broker journal remains `~/.local/share/burt-workbench/jobs.sqlite`.
The host deployment ledger is `~/.local/share/burt-irc/deployment.json`.
The pre-repository-tools service drop-in, broker sources, and SQLite backups
are at `~/.local/share/burt-irc/backup-repo-tools-20261026T215021Z/`.

To revert only this extension: stop `burt-sandbox.service`, then
`burt-workbench.service`; preserve the current databases; restore that backup's
`80-workbench.conf` to the bot service drop-in directory and its `broker.py`,
`runner.py`, and `launch.py` to `~/.local/share/burt-workbench/`. Leave the live
bot database and publication journal in place: the added table is compatible
with the older broker and avoids losing publication history. Reload systemd,
start the broker, then start only the canonical bot service. The old release
`47fb0ed` remains available. Do not restore the older journal over new writes.

Acceptance evidence: a fresh model turn created the project, then a separate
turn read it, preserved addition and added subtraction with 35 passing
assertions. The public project files matched the exact stored tested bundle.
No IRC messages were sent by these synthetic checks. Read-only IRC WHOIS
confirmed the live `burt_bot` in `#ai` after deployment; both services had zero
restarts and the namespace isolation probe passed.

* Initial: <https://github.com/burt-agent/workspace/commit/a9c79c8dd48d17c9c65c855b7810f7c1e8d7d7aa>
* Continuation: <https://github.com/burt-agent/workspace/commit/3935003b9b0ae37b57d8ba2876cae000154a1ec9>

These are synthetic model/tool acceptance checks, not a completed dictionary
project or evidence of a real channel user's task succeeding.

## Coding task visibility and lifetime

Fresh admitted human coding envelopes get `BOT_CODING_TASK_TTL_SECONDS`
(default 1800 seconds, hard configuration ceiling 3600) when processing starts,
not the five-minute conversational output TTL. Admission uses the existing
Workbench gate; stale queued messages, ambient chat, other bots/channels and
reminder wakes gain no authority. This fixed deadline is never extended by a
tool or retry, so the job scope is stable. Existing five-attempt broker quota,
13 model-iteration limit, job freshness and publishing gates remain unchanged.
This is an admission/tool/output deadline, not cancellation of an in-flight
model HTTP request. Rate-limit retry budgets still apply.

The runtime reports coding start, each execution/publication start and result
(job ID, state, exit code, canonical publication URL), and an explicit stopped
notice on expiry/error/silent or empty output. Source, generated stdout and
model titles are never copied into progress notices. Broker errors do not
establish publication failure: uncertain writes still require reconciliation.
IRC delivery remains best effort. Active model turns are volatile across
restart; immutable bundles and results survive in the broker journal. No
background continuation or automatic re-publication is implied.

Dictionary recovery on Forge: all three original failed 17-file bundles and
results were exported read-only from the clawd journal into
`~/.local/share/burt-recovery/`, keyed by original job ID. They are untrusted
source snapshots, not a passing or published project. Do not execute them on
the operator host; repair/test through the isolated runner.

### Coding-status rollout (2026-10-26)

Active Burt source is now `~/.local/share/burt-irc/releases/9d98315` on clawd.
The broker has not changed. Backup/rollback instructions and SQLite backups:
`~/.local/share/burt-irc/backup-coding-status-20261026T231449Z/`.
Restore only its saved `80-workbench.conf`, daemon-reload and restart Burt to
revert this change; keep the live databases and broker journal in place.

Verification: 52 Perl test files / 1,036 assertions; 17 Python broker tests;
namespace probe; both database quick_checks; read-only WHOIS confirms `#ai`
and `#mateu-test`; zero service restarts. No live coding task or IRC progress
message delivery was exercised during rollout. Dictionary recovery archive on
Forge: `~/.local/share/burt-recovery/dictionary-recovery.tar.gz`.

## Bounded repair loop

`inspect_repo_job(id)` recovers complete saved files, result, destination and
remaining quota within the **same current request**. `repair_repo_project(id,
changes, delete, argv, title)` applies complete replacements only to named files;
all omitted files survive exactly. Deletions must be explicit. It revalidates
paths, input sizes, fresh branch base and the shared five-run quota, and creates
a new immutable repository job. Publishing still requires that new job to pass,
current publication permission, a recent result and an unchanged remote base.
No previous request gains renewed publication authority.

Runtime budget reminders survive in-loop context compaction and point to the
latest saved repository job. Failed final attempts stop before another model
call, with a deterministic quota notice. Verbose results retain the error head
and terminal summary tail, marked `output_truncated`; new results record `argv`.
The ordinary 13-iteration bound, 30-minute task deadline, five execution attempts,
offline runner and credential-isolated publisher are unchanged.

`diagnose_repo_job(id, argv, title)` runs diagnostics against the saved complete
repository source without copying it through the gist-oriented flat-file tool.
It consumes the same execution quota but is durably marked diagnostic-only;
even exit 0 can never be published, including after broker restart. Diagnostics
cannot replace the latest complete-project result. Once a repository test job
exists, the runtime directs run_code attempts to this diagnostic tool instead.

### Repair-loop deployment and acceptance (2026-10-27 UTC)

Clawd runs pinned runtime `d8cd8c565ac3308eff9cbeee0bb375d4c93197c7` at
`~/.local/share/burt-irc/releases/d8cd8c5`; rollback files and consistent database
backups are in `~/.local/share/burt-irc/backup-repair-loop-20261027T001741Z`.
Restore its broker files and `80-workbench.conf`, daemon-reload, and restart the
canonical broker then Burt to roll back code; do not replace live journals with
old backups. No schema change was made. Other bots remained stopped.

Verification: 53 Perl files / 1,052 assertions; 23 broker tests; both hosted CI
runs on the deployed runtime commit passed. Isolated namespace/IPC probe,
database quick checks, source hashes, zero automatic service restarts, and IRC
WHOIS presence in #ai and #mateu-test passed after deployment. The first probe
raced broker socket startup; the subsequent probe passed.

An unassisted model replay still misdiagnosed the generated code and stopped
correctly at its execution budget. Do NOT describe that as a successful repair.
Independent negative/positive controls isolated two real project defects:
Encode's canonical `utf-8-strict` name missed the client regex, and a single-quoted
Latin-1 fixture contained literal Perl-style escapes instead of actual bytes.
With those operator findings supplied, the production model repaired the original
bundle in one run: job `d29bdf29225f4ffd8964978c2aaa1eda`, complete original suite
`/usr/bin/perl -Ilib t/dictionary.t`, exit zero, 17 files retained, 15 byte-for-byte
unchanged, all expected assertions retained. This is **guided model acceptance**,
not proof of reliable autonomous diagnosis or a live IRC coding request.

No dictionary code was published. Evidence and the exact passed bundle/result
are at clawd:`~/.local/share/burt-recovery/20261027-verified-repair/` (private),
including a consistent copy of the separate acceptance journal. Original live
failed jobs are untouched. The temporary acceptance broker has been stopped.

### Isolated channel retry (2026-10-27)

Coding and explicit publication requests are now accepted in exactly `#ai` and
`#mateu-test` on irc.perl.org. The bot forwards the actual current request channel
to the broker; channel remains part of the request scope. Fresh directly addressed
human envelopes, publication wording, deadlines, attempt limits, offline execution
and fixed publication destinations are unchanged. This authorizes any human in
either channel under the existing nick classification, not authenticated ownership.

Deploy this commit as a new pinned release, update the existing `80-workbench.conf`
source paths, and replace only host broker.py from the same commit. Stop Burt and
the broker before SQLite backup. Back up the drop-in, broker.py and deployment.json
in `~/.local/share/burt-irc/backup-mateu-test-<UTC>/`, together with consistent backups
of bot and broker databases. Rollback: stop both units, restore broker.py and the
saved drop-in, daemon-reload, start broker then Burt. Leave current databases in
place (no schema change); older backups are recovery points, not automatic rollback.
The runtime source remains authoritative via systemctl ExecStart/WorkingDirectory;
record exact release and backup in deployment.json under `mateu_test_authorization`.

## Rejected calls and terminal task status

The broker journal now adds two operator-only tables (additive schema; older code
can still use the same jobs database):

- `rejections`: timestamp, validated runtime scope/channel/network/action,
  canonical request SHA-256, fixed validation reason and error category. Invalid
  envelopes have NULL metadata. Malformed/oversized wire requests are hashed only
  over the bounded bytes actually read, without inventing a scope. Known dynamic
  validation reasons omit path suffixes. Unknown exception messages are discarded
  as `unclassified broker error`, not persisted verbatim. Extend `SAFE_REASONS`
  when adding new fixed validation messages.
- `task_status`: admitted scope/channel, creation/update times, and fixed lifecycle
  phase/reason. `reported` means a final model report, **not** verified completion.
  Join the scope to `jobs` and `rejections` to reconcile the actual outcome. A
  process crash can leave `started`; it does not imply continued background work.

Each audit table retains at most 512 records and seven days, pruned on startup
and audit writes. These are logical row/retention bounds; they do not shrink the
shared SQLite file or change job retention. The database is mode 0600, outside
the bot namespace. No source, arbitrary exception text, credentials, titles or
stdout are added to audit records. Neither table has a model-readable tool.
Rejected calls create no executable job ID and consume no execution/publication
quota. Existing immutable failed-run bundles and results are unchanged.

Internal runtime lifecycle IPC uses the scope frozen at trusted admission, so
expiry and pending cleanup cannot change the lookup. Terminal notices query
actual job IDs/states from the broker: zero jobs means `No project bundle was
saved`; saved jobs list only real IDs/states. If IPC fails, status is unavailable,
not zero. Rejection causes stay operator-only and are never echoed into IRC.
This does not recover lost model context or renew any tool/publication authority.

Deploy runtime and broker.py from the same pinned commit. Stop canonical
`burt-sandbox.service` then `burt-workbench.service`, privately save existing
source drop-in, broker code and deployment ledger, and make consistent SQLite
backups before installing. Keep other bots/configuration/policy unchanged. Start
broker then Burt and verify source hashes, database quick checks, namespace/IPC
and IRC registration. For rollback restore saved code/drop-in/ledger and restart
in that order; **keep live databases**, including the new audit evidence.
Authoritative source remains the canonical service ExecStart/WorkingDirectory,
not a development checkout. Record exact release and rollback in deployment.json.

## Project headroom (128 KiB)

Repository source bundles (including unchanged tests/docs) now allow exactly 131,072 UTF-8
content bytes across at most 32 files. Runner, repository read, repair and
publication use the same bound. Captured stdout/stderr remains 65,536 bytes; standalone run_code/gist admission also
remains 65,536 input bytes;
output overflow still fails the job. Transport/standalone JSON envelopes allow
2 MiB to accommodate worst-case JSON escaping and the separately bounded argv;
this does not increase source, output, execution, model or publication quotas.
Oversize errors and private rejection records report submitted_bytes,
allowed_bytes and excess_bytes, never source text. Existing audit retention is
unchanged. The repository API response bound stays 1,500,000 bytes.

Deployment: export the reviewed/CI-green commit to
`~/.local/share/burt-irc/releases/<sha12>`, use the existing reversible pinned
service rollout, and copy all six broker modules from that same release. Preserve
live SQLite state and policy bytes; verify source/module hashes, offline runner,
namespace/IPC, databases, service restart counters and IRC rejoin. The dictionary
baseline-review hold is independent of this limit change and must not be silently
renewed. An operator-only replay can use the frozen baseline and a separate
journal without publishing or changing the live policy.
