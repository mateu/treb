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


class LargeBundleBrokerTests(unittest.TestCase):
    setUp = test_repository.RepositoryBrokerTests.setUp
    post = test_repository.RepositoryBrokerTests.post
    repair = test_repository.RepositoryBrokerTests.repair
    repo_publish = test_repository.RepositoryBrokerTests.repo_publish
    def test_repair_inspect_publish_and_overflow(self):
        files = {'lib/main.py': 'x' * 70000, 't/test.py': 'x' * 61072}
        self.repo.files = files.copy()
        req = self.repo_req | {'files': files}
        job = self.b.handle(req)
        self.assertEqual(job['state'], 'passed')
        with self.assertRaisesRegex(InputSizeError, 'submitted_bytes=131073.*excess_bytes=1'):
            self.repair(job, changes={'lib/main.py': files['lib/main.py'] + 'x'})
        self.assertEqual(len(self.runs), 1)
        reason = self.b.db.execute('SELECT reason FROM rejections').fetchone()[0]
        self.assertIn('allowed_bytes=131072', reason)
        fixed = self.repair(job, changes={'lib/main.py': 'y' * 70000})
        inspected = self.b.handle({k: req[k] for k in ('scope', 'channel', 'network')} |
                                 {'action': 'repo_inspect', 'id': fixed['id']})
        self.assertEqual(inspected['files'], files | {'lib/main.py': 'y' * 70000})
        self.repo_publish(fixed)
        tree = next(p['tree'] for _, p, _ in self.repo.calls if p and 'tree' in p)
        self.assertEqual({e['path'].removeprefix('projects/dictionary/'): e['content'] for e in tree}, inspected['files'])
        self.assertEqual(len(self.runs), 2)


class LargeWireTests(unittest.TestCase):
    setUp = test_rejection_audit.RejectionAuditTests.setUp
    wire = test_rejection_audit.RejectionAuditTests.wire
    def test_escaped_large_wire_roundtrip(self):
        # Use run rather than repository policy fixtures: the real wire handler,
        # no network or sandbox execution needed for this transport contract.
        req = {k: self.req[k] for k in ('scope', 'channel', 'network')}
        req |= dict(action='run', files={'large.txt': '\x01' * 131072},
                    argv=['/bin/sh'], title='large wire')
        result = self.wire(json.dumps(req).encode() + b'\n')
        self.assertNotIn('error', result)
        saved = self.b.db.execute('SELECT files FROM jobs WHERE id=?', (result['id'],)).fetchone()[0]
        self.assertEqual(json.loads(saved), req['files'])
        req['files']['large.txt'] += 'x'
        result = self.wire(json.dumps(req).encode() + b'\n')
        self.assertIn('submitted_bytes=131073 allowed_bytes=131072 excess_bytes=1', result['error'])
        self.assertEqual(self.b.db.execute('SELECT COUNT(*) FROM jobs').fetchone()[0], 1)
