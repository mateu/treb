import json
from pathlib import Path
import tempfile
import unittest
from broker import Broker


class BrokerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.token = Path(self.tmp.name) / 'token'
        self.token.write_text('fake-test-only')
        self.token.chmod(0o600)
        self.runs = []
        self.posts = []
        def execute(job):
            self.runs.append(job)
            return {'reason': 'exited', 'exit_code': 0, 'output': 'ok'}
        self.b = Broker(self.tmp.name, self.token, execute)
        self.addCleanup(self.b.db.close)
        self.b.post_gist = self.post
        self.req = dict(action='run', scope='a'*64, channel='#ai', network='irc.perl.org',
                        files={'main.py': 'print(42)\n', 'test.py': 'assert 6*7==42\n'},
                        argv=['/usr/bin/python3', '/work/test.py'], title='test')

    def post(self, payload):
        self.posts.append(payload)
        return 'https://gist.github.com/burt-agent/abcdef'

    def publish(self, job):
        return self.b.handle({k:self.req[k] for k in ('scope', 'channel', 'network')}
                             | {'action':'publish', 'id':job['id']})

    def test_exact_bundle_and_idempotence(self):
        r = self.b.handle(self.req)
        self.assertEqual(r['state'], 'passed')
        self.assertEqual(self.b.handle(self.req)['id'], r['id'])
        self.assertEqual(len(self.runs), 1)
        self.assertEqual(self.publish(r)['state'], 'published')
        self.assertEqual(self.publish(r)['state'], 'published')
        self.assertEqual(len(self.posts), 1)
        self.assertEqual(self.posts[0]['files'], {n:{'content':c} for n,c in self.req['files'].items()})
        self.assertTrue(self.posts[0]['public'])

    def test_failed_and_truncated_never_publish(self):
        for result in ({'reason':'exited', 'exit_code':1}, {'reason':'output_limit', 'exit_code':0},
                       {'reason':'supervisor_timeout', 'exit_code':0}):
            self.b.execute = lambda job: result.copy()
            self.req['title'] += 'x'
            r = self.b.handle(self.req)
            self.assertEqual(r['state'], 'failed')
            with self.assertRaises(ValueError): self.publish(r)
        self.assertEqual(self.posts, [])

    def test_scope_and_channel(self):
        r = self.b.handle(self.req)
        self.req['scope'] = 'b'*64
        with self.assertRaises(ValueError): self.publish(r)
        for key, value in [('channel','#other'), ('network','irc.other')]:
            req = self.req | {key:value}
            with self.assertRaises(ValueError): self.b.handle(req)

    def test_no_host_paths_or_binary(self):
        for name, content in [('../secret','x'), ('/etc/passwd','x'), ('dir/name','x'),
                              ('ok.py','\x00'), ('-n','x')]:
            with self.assertRaises(ValueError):
                self.b.handle(self.req | {'files':{name:content}})
        self.assertEqual(self.runs, [])

    def test_invalid_host_command_and_fields(self):
        for change in ({'argv':['/usr/bin/curl','https://example.com']}, {'token':'x'},
                       {'files':{'main.py':'x'*65537}}, {'title':'a\nb'}):
            with self.assertRaises(ValueError): self.b.handle(self.req | change)

    def test_missing_or_open_token_blocks(self):
        r = self.b.handle(self.req)
        self.token.chmod(0o644)
        with self.assertRaises(ValueError): self.publish(r)
        self.token.unlink()
        with self.assertRaises(ValueError): self.publish(r)
        self.assertEqual(self.posts, [])

    def test_ambiguous_publish_cannot_retry(self):
        r = self.b.handle(self.req)
        def lost(payload):
            self.posts.append(payload)
            raise TimeoutError()
        self.b.post_gist = lost
        with self.assertRaises(ValueError): self.publish(r)
        with self.assertRaises(ValueError): self.publish(r)
        self.assertEqual(len(self.posts), 1)
        self.assertEqual(self.b.db.execute('SELECT state FROM jobs').fetchone()[0], 'uncertain')

    def test_expiry_and_per_request_quota(self):
        r = self.b.handle(self.req)
        self.b.db.execute('UPDATE jobs SET created=0')
        self.b.db.commit()
        with self.assertRaises(ValueError): self.publish(r)
        # A fresh scope can run at most five distinct attempts.
        self.req['scope'] = 'c'*64
        for i in range(5): self.b.handle(self.req | {'title':str(i)})
        with self.assertRaises(ValueError): self.b.handle(self.req | {'title':'sixth'})

    def test_one_publish_per_request(self):
        a = self.b.handle(self.req)
        b = self.b.handle(self.req | {'title':'another'})
        self.publish(a)
        with self.assertRaises(ValueError): self.publish(b)
        self.assertEqual(len(self.posts), 1)

    def test_restart_preserves_submission_and_bundle(self):
        r = self.b.handle(self.req)
        self.publish(r)
        second = Broker(self.tmp.name, self.token)
        self.addCleanup(second.db.close)
        result = second.handle({k:self.req[k] for k in ('scope','channel','network')}
                               | {'action':'publish','id':r['id']})
        self.assertEqual(result['url'], 'https://gist.github.com/burt-agent/abcdef')

    def test_verbose_failure_keeps_error_head_and_suite_summary_tail(self):
        self.b.execute=lambda job: {'reason':'exited','exit_code':1,
                                   'output':'FAILURE DETAIL\n'+'x'*12000+'\nResult: FAIL'}
        result=self.b.handle(self.req)
        self.assertTrue(result['result']['output_truncated'])
        self.assertTrue(result['result']['output'].startswith('FAILURE DETAIL'))
        self.assertTrue(result['result']['output'].endswith('Result: FAIL'))
        self.assertEqual(result['state'],'failed')
        with self.assertRaises(ValueError): self.publish(result)

if __name__ == '__main__':
    unittest.main()
