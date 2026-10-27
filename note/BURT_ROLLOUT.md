# Controlled Burt rollout

`BURT_CONTEXT_TOKENS=32768` in Burt's private host environment opts that runtime
into the 32K application-compactor budget used in the controlled coding trials.
It applies to the Burt instance, including ordinary conversation; other bot
profiles retain their settings. Unset preserves 8192, explicit caller budgets
win, and invalid configured values fail startup before model requests.
The 13-iteration limit and five shared sandbox executions remain unchanged.
This is not a provider hard-input cap or a claim of improved coding accuracy.

Merge integration, pinned deployment, and operator project-policy activation
are separate steps. `BURT_VERIFICATION_POLICY` belongs to the broker service;
it selects reviewed projects and fails closed for unlisted projects. No policy
is loaded from model-writable files. After each reviewed publication, renew the
exact base and baseline deliberately before a fresh-turn continuation.

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
