#!/usr/bin/env python3
"""Small local autoresearch-style evaluator for Treb IRC harness work.

Primary score = live green count over N live harness runs.
Gatekeepers must pass first:
  1) python3 test/irc_harness_evaluate.py
  2) deterministic harness pass
  3) no command-path regression in deterministic harness result

Outputs a machine-readable JSON summary plus a short human summary under:
  log/irc-autoresearch/<timestamp>/
"""

from __future__ import annotations

import argparse
import concurrent.futures
import datetime as dt
import json
import os
import pathlib
import re
import subprocess
import sys
from dataclasses import dataclass, asdict
from typing import Any

ROOT = pathlib.Path(__file__).resolve().parents[1]
OUT_ROOT = ROOT / "log" / "irc-autoresearch"


@dataclass
class CmdResult:
    cmd: list[str]
    rc: int
    stdout: str
    stderr: str


@dataclass
class HarnessRun:
    label: str
    rc: int
    run_dir: str | None
    summary_ok: bool | None
    command_path_ok: bool | None
    classification: str
    failure_shape: list[str]


def now_slug() -> str:
    return dt.datetime.now().strftime("%Y%m%d-%H%M%S")


def run_cmd(cmd: list[str], env: dict[str, str] | None = None) -> CmdResult:
    proc = subprocess.run(
        cmd,
        cwd=ROOT,
        env=env,
        capture_output=True,
        text=True,
    )
    return CmdResult(cmd=cmd, rc=proc.returncode, stdout=proc.stdout, stderr=proc.stderr)


def parse_json_from_stdout(s: str) -> dict[str, Any] | None:
    start = s.find("{")
    end = s.rfind("}")
    if start == -1 or end == -1 or end <= start:
        return None
    blob = s[start : end + 1]
    try:
        return json.loads(blob)
    except json.JSONDecodeError:
        return None


def load_eval_lines(run_dir: pathlib.Path | None) -> list[str]:
    if not run_dir:
        return []
    p = run_dir / "evaluation.txt"
    if not p.exists():
        return []
    return [ln.strip() for ln in p.read_text(encoding="utf-8", errors="replace").splitlines() if ln.strip()]


def command_path_ok(eval_lines: list[str]) -> bool | None:
    if not eval_lines:
        return None
    for line in eval_lines:
        low = line.lower()
        if "command path" in low:
            return line.startswith("PASS")
    return None


def classify_run(rc: int, summary_ok: bool | None, cmd_ok: bool | None) -> tuple[str, list[str]]:
    failures: list[str] = []
    if rc != 0:
        failures.append("nonzero_exit")
    if summary_ok is False:
        failures.append("evaluator_failed")
    if cmd_ok is False:
        failures.append("command_path_regression")
    if cmd_ok is None:
        failures.append("command_path_unknown")

    green = rc == 0 and summary_ok is True and cmd_ok is True
    if green:
        return "green", []
    if cmd_ok is True:
        return "near-miss", failures or ["unknown_near_miss"]
    return "fail", failures or ["unknown_fail"]


def run_harness(label: str, mode: str) -> HarnessRun:
    result = run_cmd(["python3", "script/irc_harness.py", "--mode", mode])
    summary = parse_json_from_stdout(result.stdout)
    run_dir_str = summary.get("run_dir") if isinstance(summary, dict) else None
    run_dir = pathlib.Path(run_dir_str) if run_dir_str else None
    summary_ok = summary.get("ok") if isinstance(summary, dict) and "ok" in summary else None
    eval_lines = load_eval_lines(run_dir)
    cmd_ok = command_path_ok(eval_lines)
    classification, failure_shape = classify_run(result.rc, summary_ok, cmd_ok)
    return HarnessRun(
        label=label,
        rc=result.rc,
        run_dir=run_dir_str,
        summary_ok=summary_ok,
        command_path_ok=cmd_ok,
        classification=classification,
        failure_shape=failure_shape,
    )


def ensure_clean_git(allow_dirty: bool) -> tuple[bool, str]:
    if allow_dirty:
        return True, "skipped (allow-dirty)"
    r = run_cmd(["git", "status", "--porcelain"])
    if r.rc != 0:
        return False, "git status failed"
    if r.stdout.strip():
        return False, "working tree is dirty"
    return True, "clean"


def write_text(path: pathlib.Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


def main() -> int:
    ap = argparse.ArgumentParser(description="Run local autoresearch-style harness eval.")
    ap.add_argument("--live-runs", type=int, default=3, choices=[1, 3, 5], help="Number of live runs (default: 3)")
    ap.add_argument("--jobs", type=int, default=3, help="Parallel live jobs (default: 3)")
    ap.add_argument("--live-mode", choices=["real", "deterministic"], default="real", help="Mode for live runs")
    ap.add_argument("--allow-dirty", action="store_true", help="Allow dirty git state")
    args = ap.parse_args()

    out_dir = OUT_ROOT / now_slug()
    out_dir.mkdir(parents=True, exist_ok=True)

    git_ok, git_msg = ensure_clean_git(args.allow_dirty)

    gatekeepers: dict[str, Any] = {
        "git_clean": {"ok": git_ok, "detail": git_msg},
    }

    py_eval = run_cmd(["python3", "test/irc_harness_evaluate.py"])
    gatekeepers["python_eval_test"] = {"ok": py_eval.rc == 0, "rc": py_eval.rc}
    write_text(out_dir / "gatekeeper-python-eval.stdout.log", py_eval.stdout)
    write_text(out_dir / "gatekeeper-python-eval.stderr.log", py_eval.stderr)

    det_run = run_harness("gatekeeper-deterministic", "deterministic")
    gatekeepers["deterministic_harness"] = {
        "ok": det_run.rc == 0 and det_run.summary_ok is True,
        "rc": det_run.rc,
        "run_dir": det_run.run_dir,
        "summary_ok": det_run.summary_ok,
        "command_path_ok": det_run.command_path_ok,
    }

    gatekeepers_ok = (
        gatekeepers["git_clean"]["ok"]
        and gatekeepers["python_eval_test"]["ok"]
        and gatekeepers["deterministic_harness"]["ok"]
        and gatekeepers["deterministic_harness"]["command_path_ok"] is True
    )

    live_runs: list[HarnessRun] = []
    if gatekeepers_ok:
        jobs = max(1, min(args.jobs, args.live_runs))
        with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as ex:
            futs = [
                ex.submit(run_harness, f"live-{i+1}", args.live_mode)
                for i in range(args.live_runs)
            ]
            for fut in concurrent.futures.as_completed(futs):
                live_runs.append(fut.result())
        live_runs.sort(key=lambda x: x.label)

    green_count = sum(1 for r in live_runs if r.classification == "green")
    near_miss_count = sum(1 for r in live_runs if r.classification == "near-miss")
    fail_count = sum(1 for r in live_runs if r.classification == "fail")

    summary = {
        "timestamp": dt.datetime.now(dt.timezone.utc).isoformat(),
        "repo": str(ROOT),
        "output_dir": str(out_dir),
        "config": {
            "live_runs": args.live_runs,
            "jobs": max(1, min(args.jobs, args.live_runs)),
            "live_mode": args.live_mode,
            "allow_dirty": args.allow_dirty,
        },
        "gatekeepers": gatekeepers,
        "gatekeepers_ok": gatekeepers_ok,
        "primary_metric": {
            "name": "live_green_count",
            "value": green_count,
            "total_live_runs": len(live_runs),
        },
        "secondary": {
            "near_miss_count": near_miss_count,
            "fail_count": fail_count,
        },
        "live_runs": [asdict(r) for r in live_runs],
    }

    summary_json = out_dir / "summary.json"
    write_text(summary_json, json.dumps(summary, indent=2) + "\n")

    lines = [
        "Treb autoresearch-style harness evaluation",
        f"output_dir: {out_dir}",
        "",
        f"gatekeepers_ok: {gatekeepers_ok}",
        f"- git_clean: {gatekeepers['git_clean']['ok']} ({gatekeepers['git_clean']['detail']})",
        f"- python_eval_test: {gatekeepers['python_eval_test']['ok']} (rc={gatekeepers['python_eval_test']['rc']})",
        (
            "- deterministic_harness: "
            f"{gatekeepers['deterministic_harness']['ok']} "
            f"(rc={gatekeepers['deterministic_harness']['rc']}, "
            f"command_path_ok={gatekeepers['deterministic_harness']['command_path_ok']})"
        ),
        "",
        f"primary metric (live green count): {green_count}/{len(live_runs)}",
        f"secondary: near-miss={near_miss_count}, fail={fail_count}",
    ]
    for r in live_runs:
        lines.append(
            f"- {r.label}: {r.classification} rc={r.rc} summary_ok={r.summary_ok} "
            f"command_path_ok={r.command_path_ok} run_dir={r.run_dir}"
        )
    write_text(out_dir / "summary.txt", "\n".join(lines) + "\n")

    print(json.dumps({
        "summary_json": str(summary_json),
        "summary_txt": str(out_dir / "summary.txt"),
        "gatekeepers_ok": gatekeepers_ok,
        "live_green_count": green_count,
        "live_total": len(live_runs),
    }, indent=2))

    return 0 if gatekeepers_ok else 2


if __name__ == "__main__":
    sys.exit(main())
