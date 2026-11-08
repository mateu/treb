# Controlled Burt rollout

`CONTEXT_TOKENS` sets the application-compactor budget; the default is 32768,
with a valid range of 8192–65536. `BURT_CONTEXT_TOKENS` is Burt's alias for the
same setting, and opts that runtime into the budget used in the controlled
coding trials. It applies to the Burt instance, including ordinary
conversation; other bot profiles retain their settings. Unset preserves the
32768 default, explicit caller budgets win, and invalid configured values fail
startup before model requests.
Burt alone uses 26 model iterations and 13 shared sandbox executions per task;
other bot profiles retain 13 iterations. The broker preserves the final
verification reserve, the 30-per-hour global execution limit, task deadline, and
publication quotas. This is not a provider hard-input cap or a claim of improved
coding accuracy.

Merge integration, pinned deployment, and operator project-policy activation
are separate steps. `BURT_VERIFICATION_POLICY` belongs to the broker service;
it selects reviewed projects and fails closed for unlisted projects. No policy
is loaded from model-writable files. Pinned policies require deliberate operator
renewal. Dictionary alone may explicitly use `source_baseline: "current_verified"`:
the broker derives a snapshot-bound effective base/baseline while immutable
operator checks and protected-path rules remain unchanged.

Keep generated code offline and publication credentials outside both namespaces.
Use three to five useful canary tasks with at least one source modification and
a fresh-turn continuation. Freeze complete-suite and independent acceptance
checks before each task, preserve original regressions, and compare the public
artifact with the immutable tested job. Treat unknown API contracts as blockers,
not fixture-tested live integrations. Stop expansion on false success, receipt
or publication mismatches, or authority/isolation regressions.

Before deployment stop Burt then broker, save service drop-ins, private
environment, matching broker modules and deployment ledger privately, and use
SQLite's backup API for both databases. Rollback restores code/configuration,
not old databases over new publication/conversation history. Start broker before
Burt, verify source hashes, namespace/IPC, database quick checks, IRC membership,
and service restart counters. The host deployment ledger records exact releases,
policy file, canary evidence and rollback path; it is authoritative over dated
historical deployment notes.

## Rollout history

The releases, backup directories and paths named below have since moved to
`~/.local/share/burt-irc/archive/` under the retention policy in
`note/BURT_WORKBENCH.md`'s "Deployment record" section; they are not live paths.

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

Workbench dispatch is accepted in exactly `#ai` and `#mateu-test` on
irc.perl.org. The bot forwards the actual current request channel to the broker;
channel remains part of the request scope. A fresh active human envelope, deadlines,
attempt limits, offline execution, fixed publication destinations, immutable
candidates, and truthful receipts remain required. No prose wording or nickname
addressing is an authorization prerequisite.

Deploy this commit as a new pinned release, update the existing `80-workbench.conf`
source paths, and replace only host broker.py from the same commit. Stop Burt and
the broker before SQLite backup. Back up the drop-in, broker.py and deployment.json
in `~/.local/share/burt-irc/backup-mateu-test-<UTC>/`, together with consistent backups
of bot and broker databases. Rollback: stop both units, restore broker.py and the
saved drop-in, daemon-reload, start broker then Burt. Leave current databases in
place (no schema change); older backups are recovery points, not automatic rollback.
The runtime source remains authoritative via systemctl ExecStart/WorkingDirectory;
record exact release and backup in deployment.json under `mateu_test_authorization`.
