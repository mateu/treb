"""Rejections never become executable jobs or leak source/exception payloads."""
import hashlib
import json
import socket
import threading
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from broker import Broker, Handler, MAX_REQUEST
import test_verification as fixtures


class RejectionAuditTests(unittest.TestCase):
    setUp = fixtures.VerificationTests.setUp
    def records(self):
        return [dict(row) for row in self.b.db.execute('SELECT * FROM rejections ORDER BY seq')]

    def status(self, phase='stopped', reason='iteration_limit', **kw):
        scope = kw.pop('scope', self.req['scope'])
        channel = kw.pop('channel', self.req['channel'])
        network = kw.pop('network', self.req['network'])
        envelope = self.b.capability_envelope('task_status', scope, channel, network)
        return self.b.handle(envelope | dict(action='task_status', phase=phase, reason=reason) | kw)

    def test_rejections_survive_restart_without_jobs_or_quota_cost(self):
        cases = [
            (self.req | {'files': {'main.py': 'SECRET_SOURCE'*12000}}, 'input files exceed 128 KiB: submitted_bytes=156000 allowed_bytes=131072 excess_bytes=24928'),
            (self.req | {'files': self.files | {'data.txt': 'SECRET_SOURCE'}}, 'protected baseline file changed'),
            (self.req | {'argv': ['SECRET_COMMAND']}, 'invalid command; use absolute python3, perl, or sh'),
        ]
        for req, reason in cases:
            with self.assertRaises(ValueError): self.b.handle(req)
            self.assertEqual(self.records()[-1]['reason'], reason)
            self.assertEqual(self.records()[-1]['request_sha256'], hashlib.sha256(
                json.dumps(req, sort_keys=True, ensure_ascii=True).encode()).hexdigest())
        self.assertEqual(self.status(), {'jobs': []})
        self.assertEqual(self.b.db.execute('SELECT COUNT(*) FROM jobs').fetchone()[0], 0)
        other = Broker(self.tmp.name)
        try:
            self.assertEqual(other.db.execute('SELECT COUNT(*) FROM rejections').fetchone()[0], 3)
            task = dict(other.db.execute('SELECT * FROM task_status').fetchone())
            self.assertEqual((task['phase'], task['reason']), ('stopped', 'iteration_limit'))
        finally:
            other.db.close()
        job = self.b.handle(self.req)
        self.assertEqual(job['attempts_remaining'], 4)
        # A real failed sandbox run keeps the exact files/results independently.
        saved = self.b.db.execute('SELECT * FROM jobs WHERE id=?', (job['id'],)).fetchone()
        self.assertEqual(json.loads(saved['files']), self.files)
        self.assertEqual(json.loads(saved['result'])['exit_code'], 1)
        self.assertEqual(self.status()['jobs'], [{'id': job['id'], 'state': 'failed'}])
        self.assertNotIn('SECRET', json.dumps(self.records()))
        self.assertEqual((self.b.base/'jobs.sqlite').stat().st_mode & 0o777, 0o600)

    def test_bounded_retention_and_untrusted_errors(self):
        with patch('broker.AUDIT_LIMIT', 3), patch('broker.AUDIT_TTL', 10), patch('broker.time.time', return_value=100):
            for i in range(5):
                self.b.record_rejection(self.req, ValueError('SECRET_SOURCE /credential/token'))
                self.status(phase='started', reason='admitted', scope=str(i)*64)
            self.assertEqual(len(self.records()), 3)
            self.assertEqual(self.b.db.execute('SELECT COUNT(*) FROM task_status').fetchone()[0], 3)
            self.assertEqual({r['reason'] for r in self.records()}, {'unclassified broker error'})
            self.assertNotIn('SECRET', json.dumps(self.records()))
            with patch('broker.time.time', return_value=111):
                self.b.prune_audit()
                self.assertEqual(self.records(), [])
                self.assertEqual(self.b.db.execute('SELECT COUNT(*) FROM task_status').fetchone()[0], 0)

    def wire(self, raw):
        server, client = socket.socketpair()
        replies = []
        def send():
            with client:
                client.sendall(raw)
                client.shutdown(socket.SHUT_WR)
                replies.append(client.makefile('rb').readline())
        worker = threading.Thread(target=send)
        worker.start()
        try:
            with server: Handler(server, None, SimpleNamespace(broker=self.b))
        finally:
            worker.join(timeout=5)
        self.assertFalse(worker.is_alive())
        return json.loads(replies[0])

    def test_wire_rejections_record_once_without_raw_payloads(self):
        for raw in [b'{"SECRET_SOURCE":\n', b'x'*(MAX_REQUEST+1)+b'\n',
                    json.dumps(self.req | {'argv': ['SECRET_COMMAND']}).encode()+b'\n']:
            before = len(self.records())
            self.assertIn('error', self.wire(raw))
            self.assertEqual(len(self.records()), before+1)
        self.assertEqual(self.records()[1]['reason'], 'oversized or unterminated request')
        self.assertIsNone(self.records()[0]['scope'])
        self.assertNotIn('SECRET', json.dumps(self.records()))

    def test_nonobject_requests_keep_original_digest(self):
        for req in [None, ['SECRET_SOURCE'], 7]:
            with self.assertRaisesRegex(ValueError, 'object required'): self.b.handle(req)
            record = self.records()[-1]
            self.assertEqual(record['request_sha256'], hashlib.sha256(
                json.dumps(req, sort_keys=True, ensure_ascii=True).encode()).hexdigest())
            self.assertIsNone(record['scope'])
        self.assertNotIn('SECRET_SOURCE', json.dumps(self.records()))

    def test_status_scope_binding_and_no_audit_read_api(self):
        self.status(phase='started', reason='admitted')
        job = self.b.handle(self.req)
        self.assertEqual(self.status(scope='b'*64), {'jobs': []})
        with self.assertRaisesRegex(ValueError, 'channel mismatch'):
            self.status(channel='#mateu-test')
        with self.assertRaisesRegex(ValueError, 'invalid task status'):
            self.status(reason='SECRET_SOURCE')
        with self.assertRaises(ValueError): self.b.handle(self.req | {'action': 'read_rejections'})
        self.assertEqual(self.status()['jobs'][0]['id'], job['id'])

    def test_recursive_repair_records_original_rejection_only_once(self):
        job = self.b.handle(self.req)
        req = {k: self.req[k] for k in ('scope', 'capability', 'grant', 'channel', 'network')}
        req |= dict(action='repo_repair', id=job['id'], changes={'data.txt': 'SECRET'},
                    delete=[], argv=self.req['argv'], title='repair')
        with self.assertRaises(ValueError): self.b.handle(req)
        self.assertEqual(len(self.records()), 1)
        self.assertEqual(self.records()[0]['action'], 'repo_repair')


if __name__ == '__main__':
    unittest.main()
