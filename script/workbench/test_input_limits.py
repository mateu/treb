"""One content budget across read/run/repair/publish; separate wire/output bounds."""
import json
import unittest

from runner import validate, InputSizeError, MAX_INPUT_BYTES, MAX_JSON_BYTES
import test_repository
import test_rejection_audit

FakeRepository = test_repository.FakeRepository


class InputLimitTests(unittest.TestCase):
    def test_utf8_aggregate_boundaries(self):
        from repository import validate_files
        for size in (65537, 131071, 131072):
            # Multibyte contents: count UTF-8 bytes, not characters or JSON bytes.
            files = {'a.txt': 'é' * (size // 2), 'b.txt': 'x' * (size % 2)}
            validate({'files': files, 'argv': ['/bin/sh']})
            validate_files(files)
        files['b.txt'] += 'x'
        for call in (lambda: validate({'files': files, 'argv': ['/bin/sh']}),
                     lambda: validate_files(files)):
            with self.assertRaises(InputSizeError) as caught:
                call()
            self.assertEqual((caught.exception.submitted_bytes, caught.exception.allowed_bytes,
                              caught.exception.excess_bytes), (131073, 131072, 1))
            self.assertIn('submitted_bytes=131073 allowed_bytes=131072 excess_bytes=1', str(caught.exception))

    def test_large_read_and_publish_including_worst_case_escaping(self):
        for content in ('x' * 131072, '\x01' * 131072, '😀' * 32768):
            r = FakeRepository()
            r.files = {'data.txt': content}
            snapshot = r.snapshot('burt/dictionary', 'dictionary')
            self.assertEqual(snapshot['files'], r.files)
            self.assertLess(len(json.dumps(snapshot).encode()), MAX_JSON_BYTES)
            r.publish(snapshot, r.files, 'large exact project')
            tree = next(p['tree'] for _, p, _ in r.calls if p and 'tree' in p)
            self.assertEqual(tree[0]['content'], content)
        r = FakeRepository()
        r.files = {'too-large.txt': 'x' * 131073}
        with self.assertRaisesRegex(InputSizeError, 'submitted_bytes=131073.*excess_bytes=1'):
            r.snapshot('burt/dictionary', 'dictionary')
        r = FakeRepository()
        r.files = {'a.txt': 'x' * 70000, 'b.txt': 'x' * 61073}
        with self.assertRaisesRegex(InputSizeError, 'excess_bytes=1'):
            r.snapshot('burt/dictionary', 'dictionary')

    def test_transport_fits_maximum_valid_escaped_source_and_argv(self):
        job = {'files': {'data.txt': '\x01' * MAX_INPUT_BYTES},
               'argv': ['/bin/sh'] + ['\x01' * 4096] * 31}
        validate(job)
        self.assertLess(len(json.dumps(job).encode()), MAX_JSON_BYTES)


def envelope(action, scope, channel, network, requester='mateu'):
    return {'action': action, 'scope': scope, 'requester': requester,
            'channel': channel, 'network': network}


class LargeBundleBrokerTests(unittest.TestCase):
    envelope = staticmethod(envelope)
    setUp = test_repository.RepositoryBrokerTests.setUp
    post = test_repository.RepositoryBrokerTests.post
    repair = test_repository.RepositoryBrokerTests.repair
    def test_repair_inspect_publish_and_overflow(self):
        files = {'lib/main.py': 'x' * 70000, 't/test.py': 'x' * 61072}
        self.repo.files = files.copy()
        snapshot = self.b.handle(envelope('repo_read', self.req['scope'], self.req['channel'], self.req['network']) | dict(
            action='repo_read', branch='burt/dictionary', project='dictionary'))
        req = envelope('repo_run', self.req['scope'], self.req['channel'], self.req['network']) | dict(
            action='repo_run', snapshot_id=snapshot['snapshot_id'], changes={}, delete=[],
            argv=['/bin/sh','-c','true'], title='large project')
        job = self.b.handle(req)
        self.assertEqual(job['state'], 'passed')
        with self.assertRaisesRegex(InputSizeError, 'submitted_bytes=131073.*excess_bytes=1'):
            self.repair(job, changes={'lib/main.py': files['lib/main.py'] + 'x'})
        self.assertEqual(len(self.runs), 1)
        reason = self.b.db.execute('SELECT reason FROM rejections').fetchone()[0]
        self.assertIn('allowed_bytes=131072', reason)
        fixed = self.repair(job, changes={'lib/main.py': 'y' * 70000})
        inspected = self.b.handle(envelope('repo_inspect', req['scope'], req['channel'], req['network']) |
                                 {'action': 'repo_inspect', 'id': fixed['id']})
        self.assertEqual(inspected['files'], files | {'lib/main.py': 'y' * 70000})
        candidate = self.b.tested_commit_candidate(envelope('github_commit_files', req['scope'], req['channel'], req['network']) | {'from_job': fixed['id'], 'repo': 'burt-agent/workspace', 'branch': 'burt/dictionary'})
        self.assertEqual({k.removeprefix('projects/dictionary/'): v for k, v in candidate['files'].items()}, inspected['files'])
        self.assertEqual(len(self.runs), 2)


class LargeWireTests(unittest.TestCase):
    setUp = test_rejection_audit.RejectionAuditTests.setUp
    wire = test_rejection_audit.RejectionAuditTests.wire
    def test_escaped_large_wire_roundtrip(self):
        # Preserve the trusted baseline; add escaped text only under the policy's
        # allowed regression directory. Exercise the real broker wire handler.
        req = self.req.copy()
        req['changes'] = {'tests/large.txt': '\x01' *
                                    (131072 - sum(len(v.encode()) for v in self.files.values()))}
        result = self.wire(json.dumps(req).encode() + b'\n')
        self.assertNotIn('error', result)
        saved = self.b.db.execute('SELECT files FROM jobs WHERE id=?', (result['id'],)).fetchone()[0]
        self.assertEqual(json.loads(saved), self.files | req['changes'])
        req['changes']['tests/large.txt'] += 'x'
        result = self.wire(json.dumps(req).encode() + b'\n')
        self.assertEqual(result['code'], 'invalid_request')
        self.assertEqual(result['message'], 'request rejected by Workbench policy')
        self.assertEqual(self.b.db.execute('SELECT COUNT(*) FROM jobs').fetchone()[0], 1)

    def test_gist_input_budget_is_not_widened(self):
        req = envelope('run', self.req['scope'], self.req['channel'], self.req['network'])
        req |= dict(action='run', files={'main.py': 'x' * 65537},
                    argv=['/bin/sh'], title='unchanged gist bound')
        with self.assertRaisesRegex(InputSizeError, 'submitted_bytes=65537 allowed_bytes=65536 excess_bytes=1'):
            self.b.handle(req)
        self.assertEqual(self.b.db.execute('SELECT COUNT(*) FROM jobs').fetchone()[0], 0)


class RejectionReasonTests(unittest.TestCase):
    """AC-5: InputSizeError and file-count refusals carry a fixed `reason`."""
    setUp = test_repository.RepositoryBrokerTests.setUp
    envelope = test_repository.RepositoryBrokerTests.envelope
    post = test_repository.RepositoryBrokerTests.post

    def test_input_size_error_carries_reason_unchanged_code_and_message(self):
        oversized = self.repo_req | {'changes': {'big.txt': 'x' * (MAX_INPUT_BYTES + 1)}, 'title': 'too big'}
        with self.assertRaises(InputSizeError) as caught:
            self.b.handle(oversized)
        rejection = caught.exception.rejection
        self.assertEqual(rejection['reason'], str(caught.exception))
        self.assertEqual(rejection['code'], 'invalid_request')
        self.assertEqual(rejection['message'], 'request rejected by Workbench policy')
        self.assertEqual(rejection['disposition'], 'retryable')
        audit_reason = self.b.db.execute('SELECT reason FROM rejections ORDER BY seq DESC LIMIT 1').fetchone()[0]
        self.assertEqual(audit_reason, str(caught.exception))

    def test_file_count_refusal_carries_reason_unchanged_code_and_message(self):
        # validate()'s generic file-count check runs before repository.validate_files(),
        # so repo_run's own 33-file case surfaces the shared runner message first.
        too_many = self.repo_req | {'changes': {f'f{i}.txt': 'x' for i in range(33)}, 'title': 'too many'}
        with self.assertRaisesRegex(ValueError, 'files must contain 1..32 text files') as caught:
            self.b.handle(too_many)
        rejection = caught.exception.rejection
        self.assertEqual(rejection['reason'], 'files must contain 1..32 text files')
        self.assertEqual(rejection['code'], 'invalid_request')
        self.assertEqual(rejection['message'], 'request rejected by Workbench policy')

    def test_project_file_count_message_also_carries_reason(self):
        # 'project requires 1..32 text files' (repository.validate_files) is the
        # other fixed file-count refusal named by D3; record_rejection treats it
        # identically to the runner's own message exercised above.
        rejection = self.b.record_rejection(self.repo_req, ValueError('project requires 1..32 text files'))
        self.assertEqual(rejection['reason'], 'project requires 1..32 text files')
        self.assertEqual(rejection['code'], 'invalid_request')
        self.assertEqual(rejection['message'], 'request rejected by Workbench policy')


class ProjectNearLimitTests(unittest.TestCase):
    """AC-4: an 80%-or-more project logs one line; 79% logs none."""
    setUp = test_repository.RepositoryBrokerTests.setUp
    envelope = test_repository.RepositoryBrokerTests.envelope
    post = test_repository.RepositoryBrokerTests.post

    def captured_limit_lines(self, fn):
        import contextlib
        import io
        buf = io.StringIO()
        with contextlib.redirect_stderr(buf):
            result = fn()
        lines = [line for line in buf.getvalue().splitlines() if line.startswith('WORKBENCH_LIMIT ')]
        return result, [json.loads(line[len('WORKBENCH_LIMIT '):]) for line in lines]

    def test_at_80_percent_logs_one_line(self):
        req = self.repo_req | {'changes': {'big.txt': 'x' * 104858}, 'title': 'at 80 percent'}
        job, events = self.captured_limit_lines(lambda: self.b.handle(req))
        self.assertEqual(events, [{'action': 'repo_run', 'channel': '#ai', 'job': job['id'],
                                   'kind': 'project_near_limit', 'limit': MAX_INPUT_BYTES,
                                   'scope': self.req['scope'][:12], 'unit': 'bytes', 'value': 104858}])

    def test_below_80_percent_logs_nothing(self):
        req = self.repo_req | {'changes': {'big.txt': 'x' * 104857}, 'title': 'just under 80 percent'}
        job, events = self.captured_limit_lines(lambda: self.b.handle(req))
        self.assertEqual(events, [])

    def test_replayed_job_does_not_log_again(self):
        req = self.repo_req | {'changes': {'big.txt': 'x' * 104858}, 'title': 'replay check'}
        first, _ = self.captured_limit_lines(lambda: self.b.handle(req))
        second, events = self.captured_limit_lines(lambda: self.b.handle(req))
        self.assertEqual(second['id'], first['id'])
        self.assertEqual(events, [])
