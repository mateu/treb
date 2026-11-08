#!/usr/bin/python3 -I
"""Summarize new WORKBENCH_LIMIT journal lines into a daily operator report."""
import argparse
import json
import subprocess
import sys
from collections import Counter
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

PREFIX = "WORKBENCH_LIMIT "
DEFAULT_CURSOR = Path.home() / ".local/share/burt-workbench/limit-report.cursor"
MAX_CHARS = 3500
MAX_LATEST = 10
TZ = ZoneInfo("America/Denver")


def _format_bytes(n):
    if n is None:
        return "-"
    if n >= 1024 * 1024:
        return f"{n / (1024 * 1024):.1f} MiB"
    if n >= 1024:
        return f"{n / 1024:.1f} KiB"
    return f"{n} bytes"


def _format_quantity(value, limit, unit):
    if unit == "bytes":
        return f"{_format_bytes(value)} of {_format_bytes(limit)}"
    value_str = "-" if value is None else str(value)
    limit_str = "-" if limit is None else str(limit)
    return f"{value_str} of {limit_str} {unit}"


def _format_event(when, payload):
    kind = payload.get("kind", "-")
    action = payload.get("action", "-")
    job = payload.get("job")
    job_short = job[:8] if isinstance(job, str) and job else "-"
    quantity = _format_quantity(payload.get("value"), payload.get("limit"), payload.get("unit", "-"))
    channel = payload.get("channel", "-")
    stamp = when.strftime("%m-%d %H:%M")
    return f"- {stamp} {kind} {action} job {job_short} {quantity} ({channel})"


def _iter_events(lines):
    for line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue
        message = entry.get("MESSAGE") if isinstance(entry, dict) else None
        if not isinstance(message, str) or not message.startswith(PREFIX):
            continue
        try:
            payload = json.loads(message[len(PREFIX):])
        except json.JSONDecodeError:
            continue
        if not isinstance(payload, dict):
            continue
        try:
            when = datetime.fromtimestamp(int(entry["__REALTIME_TIMESTAMP"]) / 1_000_000, tz=TZ)
        except (KeyError, TypeError, ValueError):
            continue
        yield when, payload


def build_report(lines, first_run):
    """Pure: turn journalctl -o json lines into report text, or NO_REPLY."""
    events = sorted(_iter_events(lines), key=lambda item: item[0])
    if not events:
        return "NO_REPLY"
    counts = Counter(payload.get("kind", "unknown") for _, payload in events)
    period = "in the last 24 hours" if first_run else "since the last report"
    out = [f"Burt Workbench limits {period}: {len(events)} events"]
    for kind, count in sorted(counts.items(), key=lambda kv: (-kv[1], kv[0])):
        out.append(f"- {kind}: {count}")
    out.append("Latest:")
    for when, payload in reversed(events[-MAX_LATEST:]):
        out.append(_format_event(when, payload))
    out.append("Details: journalctl --user -u burt-workbench.service --grep WORKBENCH_LIMIT")
    text = "\n".join(out)
    if len(text) > MAX_CHARS:
        text = text[:MAX_CHARS - 1].rstrip() + "…"
    return text


def _last_cursor(lines):
    """Pure: the __CURSOR of the last journalctl record line, or None."""
    if not lines:
        return None
    try:
        entry = json.loads(lines[-1])
    except json.JSONDecodeError:
        return None
    cursor = entry.get("__CURSOR") if isinstance(entry, dict) else None
    return cursor if isinstance(cursor, str) and cursor else None


def _write_cursor(cursor_path, cursor):
    tmp_path = cursor_path.with_name(cursor_path.name + ".tmp")
    tmp_path.write_text(cursor, encoding="utf-8")
    tmp_path.chmod(0o600)
    tmp_path.rename(cursor_path)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cursor-file", default=str(DEFAULT_CURSOR))
    args = parser.parse_args(argv)
    cursor_path = Path(args.cursor_file)
    saved_cursor = None
    if cursor_path.exists():
        saved_cursor = cursor_path.read_text(encoding="utf-8").strip() or None
    first_run = saved_cursor is None
    command = ["journalctl", "--user", "-u", "burt-workbench.service", "-o", "json", "--no-pager"]
    command.append("--since=-24h" if first_run else f"--after-cursor={saved_cursor}")
    try:
        completed = subprocess.run(command, capture_output=True, text=True, check=False)
    except OSError as exc:
        print(f"limit_report: journalctl failed to run: {exc}", file=sys.stderr)
        return 1
    if completed.returncode != 0:
        detail = completed.stderr.strip() or f"exit {completed.returncode}"
        print(f"limit_report: journalctl failed: {detail}", file=sys.stderr)
        return 1
    lines = completed.stdout.splitlines()
    new_cursor = _last_cursor(lines)
    if new_cursor is not None:
        _write_cursor(cursor_path, new_cursor)
    print(build_report(lines, first_run))
    return 0


if __name__ == "__main__":
    sys.exit(main())
