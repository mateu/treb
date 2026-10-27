# Burt trusted coding experiment — v1

Scope: isolated experiment only; no IRC client, publication, production source,
service, model configuration or live databases change. Both arms use explicit
32768 application-compactor budget (not a hard provider context cap), 13 model
iterations, five sandbox executions, 1800-second trial deadline, same DeepSeek
route and no fallback. All generated execution remains offline in bwrap/cgroups.

## Frozen design (before model trials)

Compare current32k command-only broker vs gated32k intervention package on three
new stdlib CLI task families, two paired repetitions, randomized within blocks
(seed 20261027), twelve scheduled trials. The intervention is the completion gate,
not a model swap. Both arms get identical shell diagnostics, job inspection,
targeted repairs and fixed-key brokered documentation. Document retrieval is
cached/frozen before trials and not a separately randomized intervention.
No inference about the independent effect of network tools is warranted.

The tasks cover quoted/multiline/BOM CSV, inventory reconciliation, and Perl
JSON normalization. Model-visible task JSON contains only prompt, original files,
and the baseline suite command. Operator-owned policies pin source baseline and
base identity, permit narrowly named source edits and new tests under tests/ or
t/, and keep all baseline tests, fixtures and docs byte-identical. The gate uses
fixed read-only external black-box checks. A separate held-out black-box evaluator
scores each final immutable candidate, including failures and budget exhaustion.
No model trial is rerun to improve its score. Missing artifacts are infrastructure
failures/unscored, not silently accepted successes. Honest unresolved blockers are
reported separately from verified working code.

Primary measures: independent functional acceptance, baseline preservation,
false-success claims, trusted-gate acceptance, executions, tokens and elapsed time.
A small pilot is feasibility evidence, not production proficiency or superiority.
Keep candidate command success distinct from trusted acceptance and independent
held-out acceptance. The gate is an honest-agent reliability boundary, not proof
against deliberately malicious code or arbitrary same-UID process manipulation.

## Prerequisites

Freeze source commit and task/check hashes. Execute positive/negative controls
through the same broker, fixed verifier, runner and evaluator used by the trials.
Prove no external/LAN/loopback/metadata networking, host-home/credentials access,
and runtime writes to protected source/checks. Independently review the gate,
fixture/evaluator contracts and preflight controls before any scored model call.
Record effective model/dependency route, source/task/policy identities and docs
hashes per trial, with fallback disabled. Stop on source/task/config drift.
