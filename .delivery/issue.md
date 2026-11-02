## Problem
Burt’s current GitHub integration is tied to one repository and narrow publication paths. The fine-grained repository token cannot perform normal account-level GitHub work, and uncertainty rows can block unrelated later work.

## Desired outcome
Burt can use an authenticated GitHub account through bounded, audited Workbench tools for normal account-authorized GitHub REST operations, file commits, and reads, while broker-enforced account-takeover protections and trusted-requester write authorization remain in force.

## Context
Completion mode: code/configuration PR. The broker owns the classic PAT and discovers identity through `GET /user`; generated code remains offline. The account is identity-agnostic at runtime. Deployment will use a new classic PAT for burt-agent at `~/.config/burt-github/token`.

## Scope
- Add broker-owned configurable GitHub client/token validation, cached identity, scopes reporting, redaction, bounded HTTP/pagination, audit/pruning, denylist, and outcome-uncertain responses.
- Add `github_whoami`, `github_api`, `github_read`, and atomic `github_commit_files` Workbench actions.
- Enforce trusted IRC requester writer allowlisting from `BURT_GITHUB_WRITERS`; reads remain available to trusted envelopes.
- Wire service/sandbox configuration and document deployment.
- Preserve legacy `burt-agent/workspace` tools.

## Non-goals
- No service deployment, token installation, live DB changes, IRC changes, repository deletion, account-admin/membership operations, secret/hook/key management, or automatic retry of non-idempotent GitHub writes.
- No merge of the delivery PR.

## Acceptance criteria
- [ ] AC-1: `github_whoami` safely reports cached `GET /user` identity and OAuth scopes from the configured private non-symlink token file.
- [ ] AC-2: General API, read, and atomic commit tools enforce bounded input/output, path-only API routing, traversal prevention, and request auditing/redaction.
- [ ] AC-3: Every denylisted sensitive endpoint is broker-blocked while nearby permitted paths work; no model-supplied requester can authorize writes.
- [ ] AC-4: Reads work for trusted non-writers; writes require casefolded `BURT_GITHUB_WRITERS`, respect the per-task cap, return 4xx receipts, and return non-retryable structured uncertainty on transport/5xx without pending blockers.
- [ ] AC-5: Existing workspace-specific tools retain passing regression coverage; runtime docs/tool definitions and deployment configuration describe the new capability accurately.

## Validation
- Pre-merge: `python3 -m unittest discover -s script/workbench -p 'test_*.py'`; targeted broker/runtime tests for AC-1–AC-5; `prove -lr t` with local::lib.
- Pre-merge: exact-head Codex review and repository CI.
- Post-merge: operator installs a new 0600 classic PAT with `repo, workflow, gist, read:org, read:user, notifications`, configures writers, restarts service, and invokes `github_whoami`.
- Environmental: live GitHub API behavior remains deployment-time verification; tests mock it.

## Implementation notes
Use the existing broker IPC and GitHub transport conventions, but keep account-scoped functionality isolated from fixed-repository behavior. Store only request metadata and body SHA-256.

## Dependencies and follow-up
No predecessor. Deployment requires an operator-provisioned classic PAT and writer allowlist. Stop at merge-ready; merging/deployment need separate authorization.
