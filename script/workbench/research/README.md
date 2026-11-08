# Trusted-coding reliability trial (historical)

This folder holds the frozen 32K-gate comparison used for the one-off trusted-coding
reliability experiment described in [`note/BURT_TRUSTED_CODING.md`](../../../note/BURT_TRUSTED_CODING.md).
It is **not deployed**: production Burt never imports anything here, and nothing in
this folder is wired into `burt.pl` or the broker service.

## What generated what

- `trusted_experiment.py` is the operator-run launcher (`prepare` / `preflight` / `run`).
  It is not a package; it adds its parent `script/workbench/` directory to `sys.path`
  so it can import the real broker modules (`broker.py`, `runner.py`, `references.py`,
  `verification.py`), the same pattern `launch.py` uses.
- `trial_support.py` runs one trial end to end: launches the sandboxed model process,
  drives the broker over a Unix socket, and writes `summary.json`/`manifest.json`.
  It also adds `script/workbench/` to `sys.path` for the same reason, and bind-mounts
  `reliability-trial.pl` and `ExperimentPlugin.pm` from this folder into the sandbox.
- `experiment_tasks.py` defines the three frozen coding tasks (CSV, inventory-fold,
  Perl tag-merge) and their reference solutions.
- `reliability-trial.pl` runs inside the disposable bwrap sandbox: it loads the task,
  sets up a `Langertha::Raider`, and records the model's attempt.
- `ExperimentPlugin.pm` is the Raider plugin that records model/tool events for the trial.

## How to run it

From a clean committed checkout on clawd, with its existing Perl dependency root:

```sh
python3 script/workbench/research/trusted_experiment.py prepare --root /tmp/NEW-SHORT-ROOT
python3 script/workbench/research/trusted_experiment.py preflight --root /tmp/NEW-SHORT-ROOT
python3 script/workbench/research/trusted_experiment.py run --root /tmp/NEW-SHORT-ROOT
```

See `note/BURT_TRUSTED_CODING.md` for the full contract (verification policy, network
limits, and what the trial does and doesn't prove). `test_trusted_experiment.py` stays
in `script/workbench/` (not here) so normal CI test discovery still runs it; it adds
this folder to `sys.path` to import `trusted_experiment` and `trial_support`.
