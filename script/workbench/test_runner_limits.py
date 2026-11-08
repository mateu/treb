import subprocess
import unittest
from unittest.mock import patch

import runner


class LimitLabelTests(unittest.TestCase):
    """D1: label time/memory kills; never remap output_limit/supervisor_timeout."""

    def run_with_probe(self, probe_stdout=b'', probe_returncode=0, argv=None):
        popen_calls = []
        run_calls = []
        popen = subprocess.Popen

        def launch(cmd, **kwargs):
            popen_calls.append(cmd)
            return popen(['/usr/bin/true'], **kwargs)

        def fake_run(cmd, **kwargs):
            run_calls.append(cmd)
            if cmd[:3] == ['/usr/bin/systemctl', '--user', 'show']:
                return subprocess.CompletedProcess(cmd, probe_returncode, stdout=probe_stdout)
            return subprocess.CompletedProcess(cmd, 0)

        with patch.object(runner.subprocess, 'Popen', side_effect=launch), \
                patch.object(runner.subprocess, 'run', side_effect=fake_run):
            result = runner.run({'files': {'a.py': 'pass'}, 'argv': argv or ['/usr/bin/python3', 'a.py']})
        return popen_calls, run_calls, result

    def systemctl_calls(self, run_calls):
        return [c[2] for c in run_calls if c[:2] == ['/usr/bin/systemctl', '--user']]

    def test_timeout_maps_to_time_limit(self):
        popen_calls, run_calls, result = self.run_with_probe(probe_stdout=b'timeout\n')
        self.assertEqual(result['reason'], 'time_limit')
        self.assertEqual(self.systemctl_calls(run_calls), ['show', 'stop', 'reset-failed'])
        self.assertNotIn('--collect', popen_calls[0])

    def test_oom_kill_maps_to_memory_limit(self):
        popen_calls, run_calls, result = self.run_with_probe(probe_stdout=b'oom-kill\n')
        self.assertEqual(result['reason'], 'memory_limit')
        self.assertEqual(self.systemctl_calls(run_calls), ['show', 'stop', 'reset-failed'])
        self.assertNotIn('--collect', popen_calls[0])

    def test_other_result_leaves_exited_unlabeled(self):
        _, run_calls, result = self.run_with_probe(probe_stdout=b'success\n')
        self.assertEqual(result['reason'], 'exited')
        self.assertEqual(self.systemctl_calls(run_calls), ['show', 'stop', 'reset-failed'])

    def test_failing_query_leaves_exited_unlabeled(self):
        _, run_calls, result = self.run_with_probe(probe_stdout=b'', probe_returncode=1)
        self.assertEqual(result['reason'], 'exited')
        self.assertEqual(self.systemctl_calls(run_calls), ['show', 'stop', 'reset-failed'])

    def test_probe_exception_leaves_exited_unlabeled(self):
        popen = subprocess.Popen

        def launch(cmd, **kwargs):
            return popen(['/usr/bin/true'], **kwargs)

        run_calls = []

        def fake_run(cmd, **kwargs):
            run_calls.append(cmd)
            if cmd[:3] == ['/usr/bin/systemctl', '--user', 'show']:
                raise subprocess.TimeoutExpired(cmd, 8)
            return subprocess.CompletedProcess(cmd, 0)

        with patch.object(runner.subprocess, 'Popen', side_effect=launch), \
                patch.object(runner.subprocess, 'run', side_effect=fake_run):
            result = runner.run({'files': {'a.py': 'pass'}, 'argv': ['/usr/bin/python3', 'a.py']})
        self.assertEqual(result['reason'], 'exited')
        self.assertEqual(self.systemctl_calls(run_calls), ['show', 'stop', 'reset-failed'])

    def test_output_limit_is_not_remapped_and_skips_probe(self):
        popen = subprocess.Popen

        def launch(cmd, **kwargs):
            return popen(['/usr/bin/python3', '-c',
                          "import sys; sys.stdout.write('a' * 70000)"], **kwargs)

        run_calls = []

        def fake_run(cmd, **kwargs):
            run_calls.append(cmd)
            return subprocess.CompletedProcess(cmd, 0)

        with patch.object(runner.subprocess, 'Popen', side_effect=launch), \
                patch.object(runner.subprocess, 'run', side_effect=fake_run):
            result = runner.run({'files': {'a.py': 'pass'}, 'argv': ['/usr/bin/python3', 'a.py']})
        self.assertEqual(result['reason'], 'output_limit')
        # No Result query for a reason that already took precedence.
        self.assertEqual(self.systemctl_calls(run_calls), ['stop', 'reset-failed'])

    def test_supervisor_timeout_is_not_remapped_and_skips_probe(self):
        popen = subprocess.Popen

        def launch(cmd, **kwargs):
            return popen(['/bin/sleep', '5'], **kwargs)

        run_calls = []

        def fake_run(cmd, **kwargs):
            run_calls.append(cmd)
            return subprocess.CompletedProcess(cmd, 0)

        with patch.object(runner.subprocess, 'Popen', side_effect=launch), \
                patch.object(runner.subprocess, 'run', side_effect=fake_run):
            result = runner.run({'files': {'a.py': 'pass'}, 'argv': ['/usr/bin/python3', 'a.py']},
                                seconds=-4.9)
        self.assertEqual(result['reason'], 'supervisor_timeout')
        self.assertEqual(self.systemctl_calls(run_calls), ['stop', 'reset-failed'])


if __name__ == '__main__':
    unittest.main()
