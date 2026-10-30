# Opt-in trusted coding gate

This feature is experimental and **not deployed**. Production Burt is unchanged.
The frozen comparison protocol is [BURT_TRUSTED_CODING_PROTOCOL.md](BURT_TRUSTED_CODING_PROTOCOL.md).

## Authority and behavior

- Chat/model process: existing narrow Workbench tools. No publisher credentials.
- Generated code: offline disposable bwrap namespaces and bounded systemd cgroups;
  no host homes, credentials, user bus or publisher state. Shell diagnostics can
  use installed `/usr/bin` utilities; Python/Perl core libraries are available.
- Broker: policy selection, fixed verification, public-document retrieval, journal
  and existing separate publication authority. Experiment publishing is disabled.

`BURT_VERIFICATION_POLICY` on the **broker service** selects an operator-owned JSON
policy file outside all model-writable mounts. Its keys are `burt/branch:project`;
values contain `base_sha`, complete original `baseline` files, explicit `editable`
existing paths, permitted `additions` (`tests/` and/or `t/`), fixed absolute `argv`,
and operator-written `checks` text files. Verification argv addresses `/checks/`.
Missing projects, baseline drift, deleted files, protected edits, or unapproved
new paths fail closed. Policies are frozen in memory for the broker lifetime.
Pinned policies require review/restart to adopt a new baseline; a Burt-written
branch head never automatically becomes the protected baseline. Dictionary may
explicitly set `source_baseline` to `current_verified`: only then does the broker
derive a snapshot-bound effective base/baseline from its own current repository
snapshot. It does not rewrite the operator policy, and immutable checks,
editable/additions restrictions, receipt identity, stale-base rejection, and
exact-tested-artifact publication remain enforced.

In gated mode, repository run/repair executes the **policy command**, not the
model-selected argv, with both `/work` and `/checks` mounted read-only. Use `/tmp`
for scratch. Diagnostics use their requested argv in a disposable writable copy,
remain unpublishable, and cannot consume the last reserved execution. Repeating a
cached diagnostic costs no execution. Unknown/modified runtime identities require
review/restart. Receipts bind policy, candidate, fixed command, selected runner and
interpreter hashes; publication rechecks policy and base. These selected hashes
are not a complete lock of the OS/stdlib/shared-library dependency tree.

No policy environment variable means the previous command-only behavior remains
for backward compatibility. Such results carry `command_only_unverified`, **not
independent correctness evidence**. Enabling gated mode cannot grandfather old
passed jobs into trusted acceptance or publication.

The example experimental contract and launcher are in
`script/workbench/{verification.py,trusted_experiment.py,experiment_tasks.py}`.
Do not mount the operator task/solution/evaluator files into the model namespace.
The gate's regression discovery runs `tests/**/test*.py` and `t/**/*.t`, in addition
to the fixed original baseline and operator acceptance cases. A policy for a
project with different conventions needs an explicitly reviewed complete command.

## Network and dependencies

`read_coding_reference` accepts only five fixed documentation identifiers:
`python-json`, `python-unittest`, `python-csv`, `perl-json-pp`, `perl-test-more`.
The broker makes bounded HTTPS GETs with no caller URL, cookies, authorization,
redirect following or environment proxies. Responses carry provenance hashes,
truncation flags and untrusted text. They are never executed or used as policy.
The experiment freezes these responses before trials so both arms see identical
bytes. This is documentation access, **not general network access for code**.

There is no host package installation or writable dependency cache. The first
benchmark requires only core Python/Perl libraries. Tasks needing third-party
packages should use separately reviewed, pinned, credential-free dependency
builds mounted read-only; do not run package hooks in the broker/publisher host.

## Verification limits

This is a reliability gate for an honest coding agent, not adversarial proof that
arbitrary code is correct. Source executing within a test process can terminate
or tamper with that process. The experiment additionally uses separate immutable
black-box checks which launch the CLI as a child and verify exact JSON results.
Even this small test set cannot establish general proficiency or production
safety. Report functional acceptance, preservation, trusted gate, model claims,
and publication separately. Larger repositories, third-party dependencies,
interactive servers and real API integrations are not covered by this pilot.

## Reproducing without production changes

Use a clean committed checkout on clawd with its existing Perl dependency root:

```sh
python3 script/workbench/trusted_experiment.py prepare --root /tmp/NEW-SHORT-ROOT
python3 script/workbench/trusted_experiment.py preflight --root /tmp/NEW-SHORT-ROOT
# Independently audit the controls and frozen source before:
python3 script/workbench/trusted_experiment.py run --root /tmp/NEW-SHORT-ROOT
```

Run detached for long comparisons. Use a fresh root; never rerun a scored trial
or overwrite old evidence. Environment-file access is host-side and private; the
record contains only its digest. The model process receives the existing model
configuration but no live bot DB or IRC client, and generated programs receive
neither. Both arms explicitly use the 32768 application-compactor budget; this
is not a provider-input hard cap or a change to the production default.
