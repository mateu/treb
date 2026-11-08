"""D1-D6: BrokerRejection, runner-crash logging, and the shared sandbox limit constants."""
import ast
import contextlib
import inspect
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from broker import Broker, BrokerRejection
import runner

HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parents[1]
# D2: every deployed module whose raise sites were converted.
D2_MODULES = ['broker.py', 'repository.py', 'runner.py',
              'verification.py', 'references.py', 'reconcile_pending_pull_request.py']


class BrokerRejectionTypeTests(unittest.TestCase):
    """AC-1."""

    def test_broker_rejection_subclasses_value_error(self):
        self.assertTrue(issubclass(BrokerRejection, ValueError))

    def test_no_raise_valueerror_with_string_constant_in_deployed_modules(self):
        for name in D2_MODULES:
            source = (HERE / name).read_text()
            tree = ast.parse(source, filename=name)
            for node in ast.walk(tree):
                if not isinstance(node, ast.Raise):
                    continue
                exc = node.exc
                if not (isinstance(exc, ast.Call) and isinstance(exc.func, ast.Name)
                        and exc.func.id == 'ValueError'):
                    continue
                is_constant_string = (len(exc.args) == 1 and not exc.keywords
                                      and isinstance(exc.args[0], ast.Constant)
                                      and isinstance(exc.args[0].value, str))
                self.assertFalse(is_constant_string,
                                 f'{name}:{exc.lineno} raises ValueError with a string '
                                 'constant; use BrokerRejection')


class RecordRejectionAuditTests(unittest.TestCase):
    """AC-2."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.b = Broker(self.tmp.name)
        self.addCleanup(self.b.db.close)
        self.req = dict(action='run', scope='a' * 64, requester='mateu',
                        channel='#ai', network='irc.perl.org')

    def records(self):
        return [dict(row) for row in self.b.db.execute('SELECT * FROM rejections ORDER BY seq')]

    def test_broker_rejection_recorded_verbatim_through_handle(self):
        req = self.req | dict(requester='BAD REQUESTER!', files={}, argv=[], title='t')
        with self.assertRaises(BrokerRejection) as ctx:
            self.b.handle(req)
        self.assertEqual(self.records()[-1]['reason'], 'invalid requester identity')
        self.assertEqual(ctx.exception.rejection['message'], 'request rejected by Workbench policy')

    def test_broker_rejection_matches_issue_example_message(self):
        message = 'task deadline reached; terminal report reserved'
        self.b.record_rejection(self.req, BrokerRejection(message))
        self.assertEqual(self.records()[-1]['reason'], message)

    def test_unlisted_broker_rejection_still_recorded_verbatim(self):
        # 'invalid requester identity' is a fixed broker-authored string but is
        # NOT in SAFE_REASONS; only the BrokerRejection type makes this verbatim.
        self.assertNotIn('invalid requester identity', __import__('broker').SAFE_REASONS)
        self.b.record_rejection(self.req, BrokerRejection('invalid requester identity'))
        self.assertEqual(self.records()[-1]['reason'], 'invalid requester identity')

    def test_public_envelope_identical_for_broker_rejection_and_plain_valueerror(self):
        broker_result = self.b.record_rejection(self.req, BrokerRejection('invalid requester identity'))
        plain_result = self.b.record_rejection(self.req, ValueError('invalid requester identity'))
        for key in ('code', 'message', 'disposition'):
            self.assertEqual(broker_result[key], plain_result[key])
        # The stored audit reason still differs: verbatim vs. unclassified.
        self.assertEqual(self.records()[-2]['reason'], 'invalid requester identity')
        self.assertEqual(self.records()[-1]['reason'], 'unclassified broker error')

    def test_plain_valueerror_with_secret_like_text_stays_unclassified(self):
        # Mirrors existing test_bounded_retention_and_untrusted_errors (untouched).
        self.b.record_rejection(self.req, ValueError('SECRET_SOURCE /credential/token'))
        self.assertEqual(self.records()[-1]['reason'], 'unclassified broker error')
        self.assertNotIn('SECRET', json.dumps(self.records()))


class RunnerErrorLoggingTests(unittest.TestCase):
    """AC-3."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.b = Broker(self.tmp.name)
        self.addCleanup(self.b.db.close)
        self.req = dict(action='run', scope='a' * 64, requester='mateu', channel='#ai',
                        network='irc.perl.org', files={'main.py': 'print(1)'},
                        argv=['/usr/bin/python3', 'main.py'], title='t')

    def captured_error_lines(self, fn):
        buf = io.StringIO()
        with contextlib.redirect_stderr(buf):
            result = fn()
        lines = [line for line in buf.getvalue().splitlines() if line.startswith('WORKBENCH_ERROR ')]
        return result, [json.loads(line[len('WORKBENCH_ERROR '):]) for line in lines]

    def test_runner_exception_logs_one_line_and_keeps_runner_error_result(self):
        long_message = 'boom\n\t ' + 'x' * 300 + '  trailing'

        def exploding(job):
            raise RuntimeError(long_message)

        self.b.execute = exploding
        job, events = self.captured_error_lines(lambda: self.b.handle(self.req))
        self.assertEqual(job['state'], 'failed')
        self.assertEqual(job['result']['reason'], 'runner_error')
        self.assertIsNone(job['result']['exit_code'])
        self.assertEqual(len(events), 1)
        event = events[0]
        self.assertEqual(event, {
            'action': 'run', 'channel': '#ai', 'job': job['id'], 'kind': 'runner_error',
            'scope': self.req['scope'][:12], 'error_type': 'RuntimeError', 'error': event['error'],
        })
        self.assertLessEqual(len(event['error']), 200)
        self.assertNotIn('\n', event['error'])
        self.assertNotIn('\t', event['error'])
        # Never file contents, argv or output.
        self.assertNotIn('main.py', json.dumps(event))
        self.assertNotIn('print(1)', json.dumps(event))

    def test_no_error_line_when_runner_succeeds(self):
        self.b.execute = lambda job: {'reason': 'exited', 'exit_code': 0, 'output': 'ok'}
        _, events = self.captured_error_lines(lambda: self.b.handle(self.req))
        self.assertEqual(events, [])


class RunnerLimitConstantsTests(unittest.TestCase):
    """AC-4: D5 constants defined and used; no literal 20/268435456 in log_limit."""

    def test_runner_constant_values(self):
        self.assertEqual(runner.TIME_LIMIT_SECONDS, 20)
        self.assertEqual(runner.MEMORY_LIMIT_BYTES, 256 * 1024 * 1024)

    def test_run_default_seconds_uses_constant(self):
        sig = inspect.signature(runner.run)
        self.assertEqual(sig.parameters['seconds'].default, runner.TIME_LIMIT_SECONDS)

    def test_run_passes_memory_limit_bytes_to_systemd(self):
        popen_calls = []
        popen = subprocess.Popen

        def launch(cmd, **kwargs):
            popen_calls.append(cmd)
            return popen(['/usr/bin/true'], **kwargs)

        def fake_run(cmd, **kwargs):
            if cmd[:3] == ['/usr/bin/systemctl', '--user', 'show']:
                return subprocess.CompletedProcess(cmd, 0, stdout=b'success\n')
            return subprocess.CompletedProcess(cmd, 0)

        with patch.object(runner.subprocess, 'Popen', side_effect=launch), \
                patch.object(runner.subprocess, 'run', side_effect=fake_run):
            runner.run({'files': {'a.py': 'pass'}, 'argv': ['/usr/bin/python3', 'a.py']})
        self.assertIn('RuntimeMaxSec=' + str(runner.TIME_LIMIT_SECONDS), popen_calls[0])
        self.assertIn('MemoryMax=' + str(runner.MEMORY_LIMIT_BYTES), popen_calls[0])

    def test_log_limit_mapping_has_no_hard_coded_limit_literals(self):
        source = (HERE / 'broker.py').read_text()
        self.assertNotIn("(20, 's')", source)
        self.assertNotIn('268435456', source)
        self.assertIn('TIME_LIMIT_SECONDS', source)
        self.assertIn('MEMORY_LIMIT_BYTES', source)


class WorkbenchPerlLimitTextTests(unittest.TestCase):
    """AC-5/D6: lib/Bot/Runtime/Workbench.pm names the real sandbox limits."""

    def workbench_text(self):
        return (REPO_ROOT / 'lib' / 'Bot' / 'Runtime' / 'Workbench.pm').read_text()

    def test_perl_text_mentions_runner_derived_limit_values(self):
        text = self.workbench_text()
        self.assertTrue(f'{runner.TIME_LIMIT_SECONDS} s' in text
                        or f'{runner.TIME_LIMIT_SECONDS} seconds' in text)
        self.assertIn(f'{runner.MEMORY_LIMIT_BYTES // (1024 * 1024)} MiB', text)
        self.assertIn(f'{runner.MAX_OUTPUT_BYTES // 1024} KiB', text)
        self.assertIn(f'{runner.MAX_GIST_INPUT_BYTES // 1024} KiB', text)
        self.assertIn(f'{runner.MAX_INPUT_BYTES // 1024} KiB', text)


if __name__ == '__main__':
    unittest.main()
