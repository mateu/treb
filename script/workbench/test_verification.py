import copy
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from broker import Broker
from verification import Verification
from references import References
from test_repository import FakeRepository, A


class VerificationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.files = {'main.py': 'print(1)', 'tests/test.py': 'assert True', 'data.txt': 'fixture'}
        self.policy = dict(base_sha=A, baseline=self.files.copy(), editable=['main.py'],
                           additions=['tests/'], argv=['/usr/bin/python3', '-I', '/checks/verify.py'],
                           checks={'verify.py': 'raise SystemExit(1)'})
        self.gate = Verification({'burt/dictionary:dictionary': self.policy})
        self.executions = []
        def execute(job, checks):
            self.executions.append((job, checks))
            return {'reason': 'exited', 'exit_code': 1, 'output': 'PASS forged by candidate'}
        self.b = Broker(self.tmp.name, verification=self.gate, verify_execute=execute)
        self.addCleanup(self.b.db.close)
        self.repo = FakeRepository()
        self.repo.files = self.files.copy()
        self.b.repository = self.repo
        self.snapshot = self.b.handle(Broker.capability_envelope('repo_read', 'a'*64, '#ai', 'irc.perl.org') | dict(
            action='repo_read', branch='burt/dictionary', project='dictionary'))
        self.req = Broker.capability_envelope('repo_run', 'a'*64, '#ai', 'irc.perl.org') | dict(
            action='repo_run', snapshot_id=self.snapshot['snapshot_id'], changes={}, delete=[],
            argv=['/bin/sh', '-c', 'true'], title='control')

    def repo_run(self, files=None, title='control'):
        files = self.files if files is None else files
        changes = {name: value for name, value in files.items() if self.files.get(name) != value}
        deleted = sorted(set(self.files) - set(files))
        return Broker.capability_envelope('repo_run', 'a'*64, '#ai', 'irc.perl.org') | dict(
            action='repo_run', snapshot_id=self.snapshot['snapshot_id'], changes=changes, delete=deleted,
            argv=['/bin/sh', '-c', 'true'], title=title)

    def request(self, action):
        return self.b.capability_envelope(action, self.req['scope'], self.req['channel'], self.req['network'])

    def test_model_command_and_fake_success_cannot_replace_gate(self):
        job = self.b.handle(self.req)
        self.assertEqual(job['state'], 'failed')
        self.assertEqual(self.executions[0][0]['argv'], self.policy['argv'])
        self.assertEqual(job['result']['requested_argv'], self.req['argv'])
        self.assertEqual(job['result']['verification']['kind'], 'trusted_checks')

    def test_protection_and_unknown_policy_fail_before_execution(self):
        for name in ['tests/test.py', 'data.txt']:
            for change in ['replace', 'delete']:
                files = self.files.copy()
                if change == 'replace': files[name] = 'weakened'
                else: del files[name]
                with self.assertRaises(ValueError): self.b.handle(self.repo_run(files))
        with self.assertRaises(ValueError):
            self.b.handle(self.repo_run(self.files | {'unittest.py': 'shadow'}))
        self.b.verification = Verification({})
        with self.assertRaisesRegex(ValueError, 'policy required'): self.b.handle(self.req)
        self.assertEqual(self.executions, [])

    def test_new_regression_and_edited_source_allowed(self):
        self.b.handle(self.repo_run(self.files | {'main.py': 'print(2)', 'tests/new.py': 'assert True'}))
        self.assertEqual(len(self.executions), 1)

    def test_baseline_drift_fails_closed(self):
        self.repo.files['data.txt'] = 'changed'
        with self.assertRaisesRegex(ValueError, 'branch changed'): self.b.handle(self.req)

    def test_current_verified_mode_derives_snapshot_but_preserves_protection(self):
        autonomous = copy.deepcopy(self.policy)
        autonomous['source_baseline'] = 'current_verified'
        self.b.verification = Verification({'burt/dictionary:dictionary': autonomous})
        self.repo.files['data.txt'] = 'advanced fixture'
        self.snapshot = self.b.handle(Broker.capability_envelope('repo_read', 'b'*64, '#ai', 'irc.perl.org') | dict(
            action='repo_read', branch='burt/dictionary', project='dictionary'))
        self.req = Broker.capability_envelope('repo_run', 'b'*64, '#ai', 'irc.perl.org') | dict(
            action='repo_run', snapshot_id=self.snapshot['snapshot_id'], changes={}, delete=[],
            argv=['/bin/sh', '-c', 'true'], title='autonomous control')
        self.b.handle(self.req)
        with self.assertRaisesRegex(ValueError, 'protected baseline file changed'):
            self.b.handle(self.req | {'changes': {'data.txt': 'weakened'}, 'title': 'tamper'})

    def test_invalid_source_baseline_mode_fails_closed(self):
        invalid = copy.deepcopy(self.policy)
        invalid['source_baseline'] = 'anything'
        with self.assertRaisesRegex(ValueError, 'invalid verification policy'):
            Verification({'burt/dictionary:dictionary': invalid})
        non_dictionary = copy.deepcopy(self.policy)
        non_dictionary['source_baseline'] = 'current_verified'
        with self.assertRaisesRegex(ValueError, 'invalid verification policy'):
            Verification({'burt/other:other': non_dictionary})

    def test_policy_identity_invalidates_dedup_and_publication(self):
        self.b.verify_execute = lambda job, checks: {'reason': 'exited', 'exit_code': 0}
        first = self.b.handle(self.req)
        self.assertEqual(first['state'], 'passed')
        changed = copy.deepcopy(self.policy)
        changed['checks']['verify.py'] += '\n# new policy'
        self.b.verification = Verification({'burt/dictionary:dictionary': changed})
        publish = self.request('repo_publish')
        with self.assertRaisesRegex(ValueError, 'receipt missing or stale'):
            self.b._handle(publish | {'action': 'repo_publish', 'id': first['id']}, _confirmed_publication=True)
        second = self.b.handle(self.req)
        self.assertNotEqual(first['id'], second['id'])

    def test_legacy_acceptance_cannot_publish_after_gate_enabled(self):
        self.b.verification = None
        self.b.execute = lambda job: {'reason': 'exited', 'exit_code': 0}
        job = self.b.handle(self.req)
        self.b.verification = self.gate
        publish = self.request('repo_publish')
        with self.assertRaisesRegex(ValueError, 'receipt missing or stale'):
            self.b._handle(publish | {'action': 'repo_publish', 'id': job['id']}, _confirmed_publication=True)

    def test_final_execution_reserved(self):
        job = self.b.handle(self.req)
        self.b.execute = lambda job: {'reason': 'exited', 'exit_code': 0}
        req = self.request('repo_diagnose')
        for i in range(11):
            self.b.handle(req | {'action': 'repo_diagnose', 'id': job['id'], 'argv': ['/bin/sh', '-c', 'true'], 'title': str(i)})
        with self.assertRaisesRegex(ValueError, 'reserved'):
            self.b.handle(req | {'action': 'repo_diagnose', 'id': job['id'], 'argv': ['/bin/sh', '-c', 'true'], 'title': 'last'})
        standalone = self.b.capability_envelope('run', self.req['scope'], self.req['channel'], self.req['network']) | {
            'action': 'run', 'files': {'main.py': 'print(1)'},
            'argv': ['/usr/bin/python3', '/work/main.py'], 'title': 'must not consume verification reserve'}
        with self.assertRaisesRegex(ValueError, 'reserved'):
            self.b.handle(standalone)
        result = self.b.handle(self.repo_run(title='final'))
        self.assertEqual(result['attempts_remaining'], 0)

    def test_resumed_diagnostics_still_reserve_final_verification_attempt(self):
        job = self.b.handle(self.req)
        diagnostic = self.request('repo_diagnose')
        for i in range(10):
            self.b.handle(diagnostic | {'action': 'repo_diagnose', 'id': job['id'],
                                        'argv': ['/bin/sh', '-c', 'true'], 'title': str(i)})
        checkpoint = self.b.handle(self.b.capability_envelope('task_checkpoint', 'a'*64, '#ai', 'irc.perl.org') | {
            'action': 'task_checkpoint', 'requester': 'mateu', 'phase': 'stopped', 'reason': 'iteration_limit'})
        resumed_scope = 'b' * 64
        self.b.handle(self.b.capability_envelope('task_resume', resumed_scope, '#ai', 'irc.perl.org') | {
            'action': 'task_resume', 'checkpoint_id': checkpoint['checkpoint_id'], 'requester': 'mateu'})
        resumed = self.b.capability_envelope('repo_diagnose', resumed_scope, '#ai', 'irc.perl.org')
        self.b.handle(resumed | {'action': 'repo_diagnose', 'id': job['id'],
                                 'argv': ['/bin/sh', '-c', 'true'], 'title': 'resumed diagnostic'})
        with self.assertRaisesRegex(ValueError, 'reserved'):
            self.b.handle(resumed | {'action': 'repo_diagnose', 'id': job['id'],
                                     'argv': ['/bin/sh', '-c', 'true'], 'title': 'reserved final'})

    def test_reference_cannot_accept_url_or_escape_catalog(self):
        for key in ['https://127.0.0.1/', '../token', 'http://169.254.169.254/', 4]:
            with self.assertRaises(ValueError): References().read(key)


if __name__ == '__main__':
    unittest.main()
