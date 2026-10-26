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
  nested paths are supported. 32 files/64 KiB; no hidden files, symlinks,
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
