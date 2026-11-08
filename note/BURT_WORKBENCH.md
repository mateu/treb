# Burt coding and public publishing on clawd

Opt-in tools: `run_code`, `publish_gist`, `read_repo_project`,
`run_repo_project`, `inspect_repo_job`, `repair_repo_project`,
`diagnose_repo_job`, and the general GitHub account tools. Repository commits
use `github_commit_files`; the former repository publication tool is removed.
Disabled unless
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
  namespaces, no credentials or bot state, read-only `/usr`, optional read-only
  operator `~/perl5` at `/perl5` with `PERL5LIB=/perl5/lib/perl5`, writable tmpfs,
  cgroup limits (256 MiB RAM/no swap/32 tasks/20 seconds), 64 KiB output and
  bounded text inputs. Absolute Python/Perl/sh argv only, executed inside the
  sandbox. Never an unsandboxed fallback; missing dependencies fail the job.
  A job killed by the time or memory limit is labeled `time_limit` or
  `memory_limit` instead of the generic `exited`, by querying the transient
  unit's systemd `Result` before it is stopped and reset-failed; burt is told
  which limit stopped the job and is told not to treat it as a code failure.
  The broker writes one `WORKBENCH_LIMIT <json>` line to its stderr (journal)
  per limit event (`time_limit`, `memory_limit`, `output_limit`, `input_bytes`,
  `file_count`, `project_near_limit`), with sorted compact-JSON keys `kind`,
  `action`, `job`, `scope` (first 12 hex characters), `channel`, `value`,
  `limit`, `unit`. These lines are metadata only: never file contents, output,
  argv, requester or raw request bytes.
  If the sandbox runner itself raises instead of returning a result, the job
  result is still the generic `runner_error`, and the broker additionally
  writes one `WORKBENCH_ERROR <json>` line to the same stderr journal, with
  sorted compact-JSON keys `action`, `channel`, `job`, `kind` (`runner_error`),
  `scope` (first 12 hex characters), `error_type` (exception class name) and
  `error` (a whitespace-collapsed, 200-character excerpt of the exception
  text). This line is metadata only too: never file contents, argv or output.
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
No package installs, secret access or arbitrary HTTP tool. Repository commits use the account credential as described below.

The runtime derives structured provenance from the active human conversation
envelope: Burt identity, `irc.perl.org`, an allowed public channel, an unexpired
request scope, and a canonical requester identity. It does not parse prose for
magic words, nickname addressing, or publication intent. Model arguments cannot
change network, channel, requester, or scope. Reminder/bot/ambient/history-only
turns cannot dispatch because they have no active human envelope.

Sandbox repository reads and tests support any account-readable repository, for anyone in the channel.
Their GitHub reads use the account credential (`BURT_GITHUB_TOKEN_FILE`, default
`~/.config/burt-github/token`) through the broker; no token enters either
namespace. Repository commits use the same account credential and Git Data API,
not a shell or Git checkout. Redirects/proxies are refused. After deploying and
verifying this path, retire `~/.config/burt-publisher/github.token`; it is no
longer used. Keep legacy publication/uncertainty records and reconciliation
support intact; credential retirement must not erase their evidence or authorize
replay. The separate gist credential remains in use.

* `read_repo_project(repo, ref?, path?)`: snapshot a repository subtree at a branch head;
  ref defaults to its default branch, path to root. Legacy `read_repo_project(branch, project)`
  selects workspace `projects/<project>/` on `burt/<slug>`, falling back to main.
* `run_repo_project(snapshot_id, changes, delete, argv, title)`: test the
  desired project materialized from the immutable snapshot, explicit changed/new
  contents and deletions; unchanged source/tests/docs are preserved. Safe
  nested paths are supported. 32 files/128 KiB aggregate UTF-8 source; no hidden files, symlinks,
  submodules or binary files. Explicitly deleted project files are deleted upon
  commit; everything outside the selected project is preserved.
* `github_commit_files(..., from_job=job_id)`: commits the immutable input
  files of a passed repository job from the same active task. `from_job` and
  inline `files` are mutually exclusive. The broker maps the complete saved
  bundle under `projects/<project>/`, preserving everything outside that project
  and deleting omitted existing project files. Only this path returns
  `tested: true`. Standalone/diagnostic jobs, failed jobs, foreign-task jobs and
  inline contents cannot receive that claim. The destination and exact base
  come from the saved job: the branch must still match that base (or remain
  absent with the same saved fallback base). Branch movement fails closed;
  reread and retest instead of rebasing the bundle. This uses the account writer
  gate and write cap, not the retired fixed-repository publication authority.
  Use `github_api` after the commit to open or merge a pull request.
* `script/workbench/reconcile_pending_pull_request.py --task-id <task-id>`:
  operator-only recovery for one durable **PR-create** uncertainty. It is not a
  runtime/model tool and makes GitHub GET requests only. It accepts a result only
  when the stored task, `burt/*` branch, exact head SHA, fixed repository, and
  `main` base all match; then it writes a local reconciliation receipt and
  clears that task's pending row. It retains the task's terminal state, so a
  recovered receipt is never authority to retry or continue an old task. No
  result, malformed/foreign/mismatched identity, API failure, or concurrent
  replay remains blocked and leaves the pending evidence intact.
* `script/workbench/reconcile_pending_pull_request.py --task-id <task-id> --confirm-absent --operator <name>`:
  a CLI-only operator preview for the exceptional case where the operator has independently established that no PR was created. It performs only GitHub GETs and prints evidence (all-state, paginated PR search; exact branch SHA; request IDs when available), but never changes the database. Add `--yes` only after reviewing that evidence to atomically audit and retire exactly that pending `repo_pr_create` row. The commit path repeats the remote checks immediately before its transaction; any PR, branch/SHA change, API/auth/rate/pagination error, malformed evidence, changed row, or ambiguity leaves the row pending. The bounded operator identifier is required and is never accepted from IRC/model input. The normal command without `--confirm-absent` still requires an identity-matching PR.

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

Gist publication retains its narrow channel-human authority. Repository commits,
including saved-job commits, require the configured account writer gate and
account write cap; a passing test does not grant write authority. Repository partial-write/lost-reply failures remain uncertain, even
if only unreachable Git objects may have been created. The operator must inspect
GitHub branch heads and the journal; do not blindly resubmit.

Exact bundles/results survive service restart. The following publication-journal
limits describe gist publication and legacy repository records, not the account
commit write budget. Up to 5 attempts and 1 submission
per turn, 30 executions/hour, 10 submissions/day globally. Runs/publications are
idempotent per request and exact bundle. Jobs must pass and be <15 minutes old.
Failed/resource-killed/output-truncated jobs cannot publish. Lost GitHub replies
leave an uncertain record: reconcile manually, never blindly retry. For an
uncertain PR create with no known number, the operator-only reconciliation command
above may resolve only an exact GitHub identity; a no-result read is not proof
that retrying is safe. Broker restart during a POST leaves `publishing`, also
fail-closed. Ordinary records expire after seven days; ambiguous publication
records are retained.

## Installation / verification

Source: `lib/Bot/Runtime/Workbench.pm`, `script/workbench/`, and the isolation
launcher.

The runtime is a thin mechanical IPC proxy. It forwards only its active trusted
requester, channel, network, and request scope with fixed tool arguments; it does
not parse prose for capabilities, nickname authority, grants, proposals, or
confirmations. The broker remains the enforcement point for schema limits, fixed
destinations, offline execution, credentials, lifecycle/resource budgets,
immutable candidate selection, idempotent receipts, and uncertain publications.
Its bounded dispatch/rejection audit stores provenance and action metadata only,
never source, arguments, output, or secrets. Install broker files into `~/.local/share/burt-workbench/`, its unit
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

## Deployment record

The authoritative deployment state is `~/.local/share/burt-irc/deployment.json`.
Its `active_runtime` names the live `commit`, pinned `release` directory under
`~/.local/share/burt-irc/releases/`, and the `backup` directory for that
deployment; every backup directory contains a `rollback.sh`. The base
`burt-sandbox.service` unit is fail-closed and only runs the pinned release
through the committed `script/burt-sandbox.service.d/80-workbench.conf.example`
drop-in template, installed as `80-workbench.conf` with `RELEASE` filled in
(see `script/README.md`).

Retention: the active release, the 5 newest backups and the releases they
reference stay under `~/.local/share/burt-irc/`. Older backups move to
`~/.local/share/burt-irc/archive/` as a `.tgz` plus a `.list` manifest.

Dated rollout history, including prior pinned releases and their rollback
paths, now lives in `note/BURT_ROLLOUT.md` under "Rollout history".

## Coding task visibility and lifetime

A fresh trusted human envelope becomes a coding task only when its first
Workbench tool invocation occurs; ordinary addressed chat remains on the normal
conversational TTL and sends no Workbench lifecycle traffic. This deliberately
uses tool use rather than prose intent parsing. Explicit checkpoint status and
resume retain their existing recovery path. An admitted envelope gets
`BOT_CODING_TASK_TTL_SECONDS` (default 1800 seconds, hard configuration ceiling
3600), replacing rather than extending the five-minute conversational output
TTL. Stale queued messages, ambient chat, other bots/channels and reminder wakes
gain no authority. This fixed deadline is never extended by a tool or retry, so
the job scope is stable. Raider working and session history are isolated by IRC
server plus IRC-casefolded channel (or PM target), with a bounded LRU store, so
one channel's tool results and task details are not model context in another. Burt's 13-attempt broker quota and 26 model-iteration limit apply only to
admitted Burt coding tasks; other bots retain 13 model iterations. The final
verification reserve, job freshness and publishing gates remain unchanged.
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

## Bounded repair loop

`inspect_repo_job(id)` recovers complete saved files, result, destination and
remaining quota within the **same current request**. `repair_repo_project(id,
changes, delete, argv, title)` applies complete replacements only to named files;
all omitted files survive exactly. Deletions must be explicit. It revalidates
paths, input sizes, fresh branch base and the shared 13-run quota, and creates
a new immutable repository job. Publishing still requires that new job to pass,
current publication permission, a recent result and an unchanged remote base.
No previous request gains renewed publication authority.

Runtime budget reminders survive in-loop context compaction and point to the
latest saved repository job. Failed final attempts stop before another model
call, with a deterministic quota notice. Verbose results retain the error head
and terminal summary tail, marked `output_truncated`; new results record `argv`.
Burt's ordinary 26-iteration bound, 30-minute task deadline, 13 execution
attempts, offline runner and credential-isolated publisher are unchanged; other
bots retain their 13-iteration bound.

`diagnose_repo_job(id, argv, title)` runs diagnostics against the saved complete
repository source without copying it through the gist-oriented flat-file tool.
It consumes the same execution quota but is durably marked diagnostic-only;
even exit 0 can never be published, including after broker restart. Diagnostics
cannot replace the latest complete-project result. Once a repository test job
exists, the runtime directs run_code attempts to this diagnostic tool instead.

## Rejected calls and terminal task status

The broker journal now adds two operator-only tables (additive schema; older code
can still use the same jobs database):

- `rejections`: timestamp, validated runtime scope/channel/network/action,
  canonical request SHA-256, fixed validation reason and error category. Invalid
  envelopes have NULL metadata. Malformed/oversized wire requests are hashed only
  over the bounded bytes actually read, without inventing a scope. Known dynamic
  validation reasons omit path suffixes. Unknown exception messages are discarded
  as `unclassified broker error`, not persisted verbatim. Extend `SAFE_REASONS`
  when adding new fixed validation messages. A raised `BrokerRejection` (the
  broker's own fixed-string refusal, defined in `runner.py` and never
  caller-controlled bytes) is always audited verbatim, whether or not its
  message is also listed in `SAFE_REASONS`.
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
namespace/IPC, databases, service restart counters and IRC rejoin. Pinned dictionary policies retain their baseline-review hold. The explicit
dictionary `source_baseline: "current_verified"` mode instead derives a
snapshot-bound effective baseline without mutating the operator policy; it still
requires immutable checks, protected-path enforcement, and exact-artifact
publication. An operator-only replay can use a frozen baseline and a separate
journal without publishing or changing the live policy.

## General GitHub account tools

For GitHub work Burt should prefer `github_whoami`, `github_api`, `github_read`,
and `github_commit_files` alongside repository sandbox tools, which
support account-readable repositories for reads and tests, not a separate publication path. Identity is never hard-coded: `github_whoami`
reports the login, id, type and OAuth scopes from `GET /user` (cached per token
for an hour), whether the current trusted requester may write, and the task's
write budget. Burt must only claim what tool receipts show.

* **Credential.** A classic PAT for the Burt account (scopes `repo`, `workflow`,
  `gist`, `read:org`, `read:user`, `notifications`) at `BURT_GITHUB_TOKEN_FILE`,
  default `~/.config/burt-github/token`. It must be a regular file (not a
  symlink) owned by the broker user, mode 0600, in a directory that is not
  group/world writable. Only the broker reads it; it never enters the bot
  namespace, a tool result, exception, log, notice or audit row (results are
  additionally redacted against the token).
* **`github_api(method, path, query?, body?)`** is a general REST proxy to
  `https://api.github.com` only. `path` must begin with a single `/`; URLs,
  hosts, `?`/`#`, backslashes, whitespace, `.`/`..` segments, encoded `/` or
  `%`, and invalid percent-encoding are rejected. Duplicate/trailing slashes are
  collapsed and the normalized path is what is both policy-checked and sent.
  Query parameters go in the `query` object; responses carry a `pagination`
  map (`next`/`last`/... with `path` and `query`) from the `Link` header.
  Bodies are bounded to 256 KiB; responses over 256 KiB return
  `truncated: true` with no data. Redirects and proxies are disabled.
  `POST /graphql` is accepted only for read queries.
* **Denylist** (`DENY_RULES` in `script/workbench/github.py`), matched on
  case-folded segments, with `/repositories/{id}` and `/organizations/{id}`
  aliases mapped first: `DELETE /repos/{o}/{r}`; writes to `/repos/{o}/{r}/`
  `transfer`, `keys`, `hooks`, `actions/secrets`, `actions/variables`,
  `dependabot/secrets`, `codespaces/secrets`, `environments/*/secrets`,
  `environments/*/variables`, `collaborators`, `invitations`; writes to
  `/user/keys`, `/user/gpg_keys`, `/user/ssh_signing_keys`, `/user/emails`,
  `/user/social_accounts`, `/user/codespaces/secrets`, `/user/installations`,
  `/user/memberships`, and `PATCH /user`; writes to `/authorizations`,
  `/applications`, `/app`, `/app-manifests`, `/installation`; and writes under
  `/orgs`, `/teams`, `/enterprises` and `/admin`, except `POST
  /orgs/{org}/repos`. GraphQL mutations are blocked. Everything else the token
  can do is allowed.
* **Authorization.** Reads need only the trusted human envelope (Burt,
  `irc.perl.org`, `#ai`/`#mateu-test`, fresh request). Writes (POST/PUT/PATCH/
  DELETE and `github_commit_files`) additionally require the envelope's
  `irc_fold` requester to be listed in `BURT_GITHUB_WRITERS` (comma-separated,
  folded the same way; empty means no writes). The requester always comes from
  the runtime envelope, never tool arguments. Pull-request endpoints are used
  through `github_api` with the account token; account-readable repository sandbox reads and
  saved-job commits also use that account token. An installed but unsafe account token fails closed.
* **Budget.** At most `BURT_GITHUB_WRITE_CAP` (default 60) writes per task,
  reserved in the broker before sending; separate from, and never consuming,
  the legacy fixed-repository one-publication budget. Saved-job commits use this
  account write cap too; passing a job does not bypass it.
* **Failures.** 4xx/3xx responses return `status`, `message`,
  `documentation_url`, `request_id` (and bounded `errors`). A write is never
  retried; a transport failure or 5xx on a write returns `outcome_uncertain`
  with method, path and request id, and the model must verify with GETs. No
  pending/blocking rows are created.
* **`github_commit_files`** creates one atomic commit through the Git Data API:
  accepts exactly one of inline `files` or optional `from_job`. For inline files,
  it resolves the branch (or, when missing, `base_ref` or the repository default
  branch), creates a tree from inline contents (`null` deletes; an object with
  `mode: "100755"` keeps a file executable; other updates are written 100644),
  creates the commit, then performs the single fast-forward ref write (`POST
  git/refs` for a new branch, `PATCH ... force:false` otherwise). Failures
  before that ref write leave the branch untouched. Paths with traversal,
  absolute paths, backslashes or a `.git` component are rejected; at most 100
  files and 512 KiB of content. Inline commits are not tested (`tested: false`).
  With `from_job`, only a passed same-task repository job is accepted; its
  immutable complete files are mapped under `projects/<project>/`, with saved
  destination/base and no branch movement permitted. Only that commit path may
  report `tested: true`; it cannot accept replacement inline contents. Both
  modes require `BURT_GITHUB_WRITERS` and consume `BURT_GITHUB_WRITE_CAP`.
* **Audit.** `github_requests` in the broker DB records time, task, requester,
  channel, action, method, normalized path, status, request id and body SHA-256
  for every HTTP request, pruned to 7 days and 4096 rows.

### Deployment

1. Create the PAT for the Burt GitHub account, then:
   `install -d -m 700 ~/.config/burt-github` and write it with
   `install -m 600 /dev/stdin ~/.config/burt-github/token` (no symlink).
2. Create `~/.config/burt-github/workbench.env` (mode 600) with
   `BURT_GITHUB_WRITERS=<comma-separated IRC nicks>` and optionally
   `BURT_GITHUB_WRITE_CAP=60`. It contains no secret. Both
   `burt-workbench.service` and the isolated `burt-sandbox.service` override
   load it with `EnvironmentFile=-%h/.config/burt-github/workbench.env`.
   `run-burt-isolated.sh` passes only `BURT_GITHUB_WRITERS` into the bot
   namespace (a fail-fast mirror; the broker remains authoritative).
3. Install the updated broker files and unit, `systemctl --user daemon-reload`,
   restart `burt-workbench.service`, then restart Burt, and ask Burt to call
   `github_whoami`.

4. Verify fixed-workspace reads/tests and a writer-authorized saved-job commit
   use the account credential, and that inline commits do not claim tested
   provenance. Verify moved-base and non-writer requests fail closed. Then retire
   `~/.config/burt-publisher/github.token` without deleting legacy publication,
   pending uncertainty, or reconciliation records. Do not replay old tasks.


Repository sandbox workflow: anyone may read_repo_project with repo owner/name,
optional ref (repository default_branch), and optional relative path (root by default),
then run_repo_project / repair_repo_project. Files are relative to that subtree.
Without repo, legacy branch burt/<slug> and project select workspace projects/<project>
with missing branches falling back to main. Empty repositories are refused: writers
should github_api POST /user/repos {"name":"demo","auto_init":true}, then read and run,
commit the PASSED job with github_commit_files from_job to a new branch, and open a PR
using github_api. from_job cannot write the default branch; repository must match and
branch must be unchanged or new from exactly the tested SHA. Writer gate and caps apply.
The code sandbox has no network and has /usr system Perl/Python plus optional read-only CPAN modules from the operator's ~/perl5 at /perl5 (PERL5LIB set). To add a dependency, ask the operator to install it into ~/perl5. Do not attempt network installs in the sandbox.

The optional local::lib mount requires an absolute source (override with
`BURT_SANDBOX_PERL5`), broker-owned directories with no group/world write
on the source, `lib`, and `lib/perl5`; symlinks at these directories
are rejected. Missing/unsafe trees are skipped; runner
results report `perl5: mounted|skipped` without disclosing the host path.

### Limit report

A daily operator report summarizes new `WORKBENCH_LIMIT` journal lines (see
above) without a model. Install it with
`install -m 600 script/workbench/limit_report.py ~/.local/share/burt-workbench/limit_report.py`,
then create one OpenClaw command job: daily `0 8 * * *` `--tz America/Denver`,
`--name burt-workbench-limit-report`, argv
`["/usr/bin/python3","-I","/home/hunter/.local/share/burt-workbench/limit_report.py"]`,
`--announce --channel telegram --to 8197479972`. A quiet run prints exactly
`NO_REPLY`, which OpenClaw's command-job delivery suppresses; a run with new
events prints a plain-text summary.

The script tracks its own position with a cursor file, default
`~/.local/share/burt-workbench/limit-report.cursor`, overridable with
`--cursor-file`. On the first run (cursor file missing or empty) it reads the
last 24 hours; afterwards it resumes from the saved `journalctl` cursor. The
cursor only advances after a successful `journalctl` run that returned at
least one record; a failed run or a quiet run leaves it unchanged. Delete the
cursor file to reset the report to the last 24 hours.
