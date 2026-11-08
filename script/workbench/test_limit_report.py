"""Pure build_report formatting, journalctl argv construction, and failure handling."""
import contextlib
import io
import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import limit_report
from limit_report import build_report, main

# 2026-01-15 03:00:00 America/Denver (MST, UTC-7).
TS_1 = "1768471200000000"
# One minute later.
TS_2 = "1768471260000000"


def journal_line(message, timestamp=TS_1):
    return json.dumps({"MESSAGE": message, "__REALTIME_TIMESTAMP": timestamp})


def event_line(payload, timestamp=TS_1):
    return journal_line("WORKBENCH_LIMIT " + json.dumps(payload), timestamp)


class NoReplyTests(unittest.TestCase):
    def test_no_lines(self):
        self.assertEqual(build_report([], first_run=False), "NO_REPLY")

    def test_only_non_matching_lines(self):
        lines = [journal_line("some other service line"), journal_line("")]
        self.assertEqual(build_report(lines, first_run=False), "NO_REPLY")

    def test_only_malformed_lines(self):
        lines = [
            "not json at all",
            journal_line("WORKBENCH_LIMIT not-json-payload"),
            json.dumps({"MESSAGE": "WORKBENCH_LIMIT " + json.dumps([1, 2]), "__REALTIME_TIMESTAMP": TS_1}),
            json.dumps({"MESSAGE": "WORKBENCH_LIMIT " + json.dumps({"kind": "time_limit"})}),  # no timestamp
        ]
        self.assertEqual(build_report(lines, first_run=False), "NO_REPLY")

    def test_blank_lines_skipped(self):
        self.assertEqual(build_report(["", "   ", "\n"], first_run=False), "NO_REPLY")


class ReportFormatTests(unittest.TestCase):
    def test_header_first_run_vs_subsequent(self):
        payload = {"kind": "time_limit", "action": "run_code", "job": "abc12345xyz",
                   "channel": "#ai", "value": 23, "limit": 20, "unit": "s"}
        lines = [event_line(payload)]
        first = build_report(lines, first_run=True)
        later = build_report(lines, first_run=False)
        self.assertTrue(first.startswith("Burt Workbench limits in the last 24 hours: 1 events"))
        self.assertTrue(later.startswith("Burt Workbench limits since the last report: 1 events"))

    def test_counts_ordered_by_count_then_kind(self):
        def ev(kind):
            return event_line({"kind": kind, "action": "run_code", "job": None,
                                "channel": "#ai", "value": 1, "limit": 2, "unit": "s"})
        lines = [ev("output_limit"), ev("time_limit"), ev("time_limit"), ev("memory_limit"), ev("memory_limit")]
        text = build_report(lines, first_run=False)
        body = text.splitlines()
        self.assertIn("- memory_limit: 2", body)
        self.assertIn("- time_limit: 2", body)
        self.assertIn("- output_limit: 1", body)
        mem_idx = body.index("- memory_limit: 2")
        time_idx = body.index("- time_limit: 2")
        out_idx = body.index("- output_limit: 1")
        self.assertLess(mem_idx, time_idx)
        self.assertLess(time_idx, out_idx)

    def test_latest_event_line_format_seconds_and_job_prefix(self):
        payload = {"kind": "time_limit", "action": "run_code", "job": "abcdefgh12345",
                   "channel": "#ai", "value": 23, "limit": 20, "unit": "s", "scope": "deadbeef1234"}
        text = build_report([event_line(payload)], first_run=False)
        self.assertIn("- 01-15 03:00 time_limit run_code job abcdefgh 23 of 20 s (#ai)", text)

    def test_job_null_renders_dash(self):
        payload = {"kind": "output_limit", "action": "run_code", "job": None,
                   "channel": "#ai", "value": None, "limit": 65536, "unit": "bytes"}
        text = build_report([event_line(payload)], first_run=False)
        self.assertIn("job - - of 64.0 KiB (#ai)", text)

    def test_bytes_formatted_kib_mib(self):
        small = event_line({"kind": "input_bytes", "action": "run_repo_project", "job": None,
                             "channel": "#ai", "value": 135021, "limit": 131072, "unit": "bytes"}, TS_1)
        large = event_line({"kind": "input_bytes", "action": "run_repo_project", "job": None,
                             "channel": "#ai", "value": 5 * 1024 * 1024, "limit": 10 * 1024 * 1024,
                             "unit": "bytes"}, TS_2)
        text = build_report([small, large], first_run=False)
        self.assertIn("131.9 KiB of 128.0 KiB", text)
        self.assertIn("5.0 MiB of 10.0 MiB", text)

    def test_latest_newest_first_capped_at_ten(self):
        lines = []
        base = 1768471200000000
        for i in range(15):
            payload = {"kind": "time_limit", "action": "run_code", "job": f"job{i:04d}",
                       "channel": "#ai", "value": i, "limit": 20, "unit": "s"}
            lines.append(event_line(payload, str(base + i * 60_000_000)))
        text = build_report(lines, first_run=False)
        latest_block = text.split("Latest:\n", 1)[1].split("\nDetails:", 1)[0].splitlines()
        self.assertEqual(len(latest_block), 10)
        self.assertIn("job0014", latest_block[0])
        self.assertIn("job0005", latest_block[-1])

    def test_details_footer_present(self):
        payload = {"kind": "file_count", "action": "run_repo_project", "job": None,
                   "channel": "#ai", "value": 40, "limit": 32, "unit": "files"}
        text = build_report([event_line(payload)], first_run=False)
        self.assertTrue(text.endswith(
            "Details: journalctl --user -u burt-workbench.service --grep WORKBENCH_LIMIT"))

    def test_report_bounded_at_3500_chars_with_fifty_events(self):
        lines = []
        base = 1768471200000000
        for i in range(50):
            payload = {"kind": "project_near_limit", "action": "repair_repo_project",
                       "job": f"job-{i:032d}", "channel": "#some-very-long-irc-channel-name",
                       "value": 100000 + i, "limit": 131072, "unit": "bytes"}
            lines.append(event_line(payload, str(base + i * 60_000_000)))
        text = build_report(lines, first_run=False)
        self.assertLessEqual(len(text), limit_report.MAX_CHARS)
        self.assertIn("50 events", text)


class CursorHelperTests(unittest.TestCase):
    def test_no_lines_returns_none(self):
        self.assertIsNone(limit_report._last_cursor([]))

    def test_last_line_malformed_returns_none(self):
        self.assertIsNone(limit_report._last_cursor(["not json"]))

    def test_last_line_missing_cursor_returns_none(self):
        line = json.dumps({"MESSAGE": "irrelevant"})
        self.assertIsNone(limit_report._last_cursor([line]))

    def test_last_line_cursor_returned(self):
        lines = [
            json.dumps({"MESSAGE": "a", "__CURSOR": "s=first"}),
            json.dumps({"MESSAGE": "b", "__CURSOR": "s=second"}),
        ]
        self.assertEqual(limit_report._last_cursor(lines), "s=second")


class MainCommandTests(unittest.TestCase):
    def _run(self, cursor_path, stdout="", extra_argv=()):
        completed = subprocess.CompletedProcess(args=["journalctl"], returncode=0, stdout=stdout, stderr="")
        with patch.object(limit_report.subprocess, "run", return_value=completed) as run, \
                contextlib.redirect_stdout(io.StringIO()):
            exit_code = main(["--cursor-file", str(cursor_path), *extra_argv])
        return exit_code, run

    def test_since_added_when_cursor_file_absent(self):
        cursor_path = Path(tempfile.mkdtemp()) / "missing.cursor"
        exit_code, run = self._run(cursor_path)
        self.assertEqual(exit_code, 0)
        command = run.call_args.args[0]
        self.assertIn("--since=-24h", command)
        self.assertNotIn("--cursor-file", " ".join(command))
        self.assertFalse(any(arg.startswith("--after-cursor") for arg in command))

    def test_since_added_when_cursor_file_empty(self):
        with tempfile.TemporaryDirectory() as tmp:
            cursor_path = Path(tmp) / "empty.cursor"
            cursor_path.write_text("   \n", encoding="utf-8")
            exit_code, run = self._run(cursor_path)
        self.assertEqual(exit_code, 0)
        command = run.call_args.args[0]
        self.assertIn("--since=-24h", command)

    def test_after_cursor_used_when_cursor_file_holds_cursor(self):
        with tempfile.TemporaryDirectory() as tmp:
            cursor_path = Path(tmp) / "saved.cursor"
            cursor_path.write_text("s=abc123\n", encoding="utf-8")
            exit_code, run = self._run(cursor_path)
        self.assertEqual(exit_code, 0)
        command = run.call_args.args[0]
        self.assertIn("--after-cursor=s=abc123", command)
        self.assertNotIn("--since=-24h", command)
        self.assertFalse(any(arg.startswith("--cursor-file") for arg in command))

    def test_base_command_matches_d2(self):
        with tempfile.TemporaryDirectory() as tmp:
            cursor_path = Path(tmp) / "missing.cursor"
            _, run = self._run(cursor_path)
        command = run.call_args.args[0]
        self.assertEqual(
            command[:6],
            ["journalctl", "--user", "-u", "burt-workbench.service", "-o", "json"],
        )
        self.assertIn("--no-pager", command)

    def test_cursor_written_atomically_when_records_returned(self):
        with tempfile.TemporaryDirectory() as tmp:
            cursor_path = Path(tmp) / "saved.cursor"
            stdout = json.dumps({"MESSAGE": "irrelevant", "__CURSOR": "s=newcursor",
                                  "__REALTIME_TIMESTAMP": TS_1}) + "\n"
            exit_code, _ = self._run(cursor_path, stdout=stdout)
            self.assertEqual(exit_code, 0)
            self.assertEqual(cursor_path.read_text(encoding="utf-8"), "s=newcursor")
            self.assertEqual(oct(cursor_path.stat().st_mode & 0o777), oct(0o600))
            self.assertFalse((cursor_path.parent / (cursor_path.name + ".tmp")).exists())

    def test_cursor_unchanged_when_no_records_returned(self):
        with tempfile.TemporaryDirectory() as tmp:
            cursor_path = Path(tmp) / "saved.cursor"
            cursor_path.write_text("s=original\n", encoding="utf-8")
            exit_code, _ = self._run(cursor_path, stdout="")
            self.assertEqual(exit_code, 0)
            self.assertEqual(cursor_path.read_text(encoding="utf-8"), "s=original\n")


class MainFailureTests(unittest.TestCase):
    def test_journalctl_nonzero_exit_leaves_cursor_unchanged(self):
        completed = subprocess.CompletedProcess(args=["journalctl"], returncode=1, stdout="", stderr="boom")
        with tempfile.TemporaryDirectory() as tmp:
            cursor_path = Path(tmp) / "saved.cursor"
            cursor_path.write_text("s=oldcursor", encoding="utf-8")
            with patch.object(limit_report.subprocess, "run", return_value=completed), \
                    patch("sys.stdout") as stdout, patch("sys.stderr") as stderr:
                exit_code = main(["--cursor-file", str(cursor_path)])
            self.assertEqual(exit_code, 1)
            stdout.write.assert_not_called()
            self.assertTrue(stderr.write.called)
            self.assertEqual(cursor_path.read_text(encoding="utf-8"), "s=oldcursor")

    def test_journalctl_cannot_run_leaves_cursor_unchanged(self):
        with tempfile.TemporaryDirectory() as tmp:
            cursor_path = Path(tmp) / "saved.cursor"
            cursor_path.write_text("s=oldcursor", encoding="utf-8")
            with patch.object(limit_report.subprocess, "run", side_effect=OSError("not found")), \
                    patch("sys.stdout") as stdout, patch("sys.stderr") as stderr:
                exit_code = main(["--cursor-file", str(cursor_path)])
            self.assertEqual(exit_code, 1)
            stdout.write.assert_not_called()
            self.assertTrue(stderr.write.called)
            self.assertEqual(cursor_path.read_text(encoding="utf-8"), "s=oldcursor")

    def test_malformed_saved_cursor_passed_through_to_journalctl(self):
        completed = subprocess.CompletedProcess(
            args=["journalctl"], returncode=1, stdout="",
            stderr="Failed to seek to cursor: Invalid argument")
        with tempfile.TemporaryDirectory() as tmp:
            cursor_path = Path(tmp) / "saved.cursor"
            cursor_path.write_text("not-a-real-cursor", encoding="utf-8")
            with patch.object(limit_report.subprocess, "run", return_value=completed) as run, \
                    patch("sys.stdout") as stdout:
                exit_code = main(["--cursor-file", str(cursor_path)])
            self.assertEqual(exit_code, 1)
            stdout.write.assert_not_called()
            command = run.call_args.args[0]
            self.assertIn("--after-cursor=not-a-real-cursor", command)
            self.assertEqual(cursor_path.read_text(encoding="utf-8"), "not-a-real-cursor")


if __name__ == "__main__":
    unittest.main()
