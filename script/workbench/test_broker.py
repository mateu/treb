import json
from pathlib import Path
import tempfile
import time
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
        self.req = dict(action='run', scope='a'*64, capability='edit_test', grant='b1bb9ad6930eaa6c19e1ff53a03596d14cf56b7d02598413f52b942e3e516d93', channel='#ai', network='irc.perl.org',
                        files={'main.py': 'print(42)\n', 'test.py': 'assert 6*7==42\n'},
                        argv=['/usr/bin/python3', '/work/test.py'], title='test')

    def post(self, payload):
        self.posts.append(payload)
        return 'https://gist.github.com/burt-agent/abcdef'

    def publish(self, job):
        return self.b.handle({k:self.req[k] for k in ('scope', 'channel', 'network')}
                             | {'capability':'publish_gist', 'grant':'651dd50e7ef8d6ee04e34ce5b6844653529b739e54d693e8d1f6e8ff9abeef87', 'action':'publish', 'id':job['id']})

    def test_capability_grant_is_required_and_action_bound(self):
        for request in (
            {k:v for k,v in self.req.items() if k not in ('capability', 'grant')},
            self.req | {'grant': '0' * 64},
            self.req | {'capability': 'read_status'},
            self.req | {'action': 'publish', 'id': '0' * 32},
        ):
            with self.assertRaisesRegex(ValueError, 'capability|action'):
                self.b.handle(request)
        # The exact runtime-shaped envelope remains acceptable for its action.
        self.assertEqual(self.b.handle(self.req)['state'], 'passed')

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

    def test_test_channel_allowed_without_widening_boundary(self):
        r = self.b.handle(self.req | {'channel':'#mateu-test', 'grant':'5d8e24c11404ff3205a576035858801de0067350db9649f99b7d4f9e38c569a2'})
        self.assertEqual(r['state'], 'passed')
        for channel in ('#mateu-test-other', '#AI', 'mateu', '#other'):
            with self.assertRaises(ValueError):
                self.b.handle(self.req | {'channel':channel})
        with self.assertRaises(ValueError):
            self.b.handle(self.req | {'channel':'#mateu-test', 'network':'irc.other'})

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
        self.req['grant'] = '98d4412bd6e494e71d8fa5db3821efdf8340ca898f201f039f0dad29021d7169'
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
                               | {'capability':'publish_gist','grant':'651dd50e7ef8d6ee04e34ce5b6844653529b739e54d693e8d1f6e8ff9abeef87','action':'publish','id':r['id']})
        self.assertEqual(result['url'], 'https://gist.github.com/burt-agent/abcdef')

    def proposal(self, action, params, requester='mateu', **changes):
        return self.b.handle(self.b.capability_envelope(action, self.req['scope'], self.req['channel'], self.req['network'])
                             | dict(action='proposal_create', proposal_action=action, params=params,
                                    requester=requester) | changes)

    def confirm(self, requester='mateu', scope='b'*64, **changes):
        return self.b.handle(self.b.capability_envelope('proposal_confirm', scope,
                             self.req['channel'], self.req['network'])
                             | dict(action='proposal_confirm', requester=requester, confirmed_at=time.time()) | changes)

    def test_durable_proposal_requires_unique_same_scope_confirmation(self):
        self.b.references.read = lambda key: {'reference':key, 'untrusted':True}
        proposal = self.proposal('reference', {'key':'python-json'})
        self.assertEqual(proposal['state'], 'proposed')
        with self.assertRaisesRegex(ValueError, 'missing or ambiguous'):
            self.confirm(requester='other')
        with self.assertRaisesRegex(ValueError, 'later fresh'):
            self.confirm(scope=self.req['scope'])
        created = self.b.db.execute('SELECT created FROM proposals WHERE id=?',
                                    (proposal['proposal_id'],)).fetchone()[0]
        with self.assertRaisesRegex(ValueError, 'missing or ambiguous'):
            self.confirm(confirmed_at=created)
        result = self.confirm()
        self.assertEqual((result['confirmed_action'], result['reference']), ('reference', 'python-json'))
        self.assertEqual(self.b.db.execute('SELECT state FROM proposals WHERE id=?',
                         (proposal['proposal_id'],)).fetchone()[0], 'consumed')
        with self.assertRaisesRegex(ValueError, 'missing or ambiguous'):
            self.confirm()

    def test_repeated_identical_proposal_reuses_pending_row(self):
        self.b.references.read = lambda key: {'reference':key, 'untrusted':True}
        first = self.proposal('reference', {'key':'python-json'})
        second = self.proposal('reference', {'key':'python-json'})
        self.assertEqual(second, first)
        self.assertEqual(self.b.db.execute('SELECT COUNT(*) FROM proposals').fetchone()[0], 1)
        self.assertEqual(self.confirm()['reference'], 'python-json')
        different = self.proposal('reference', {'key':'python-csv'})
        self.assertNotEqual(different['proposal_id'], first['proposal_id'])
        self.assertEqual(self.b.db.execute('SELECT COUNT(*) FROM proposals').fetchone()[0], 2)

    def test_proposal_accepts_casemapped_irc_requester_identities(self):
        for requester in ('mateu~', '_mateu', '{mateu'):
            proposal = self.proposal('reference', {'key':'python-json'}, requester=requester)
            self.assertEqual(proposal['state'], 'proposed')

    def test_confirmation_rejects_ambiguity_expiry_and_altered_parameters(self):
        one = self.proposal('reference', {'key':'python-json'})
        two = self.proposal('reference', {'key':'python-csv'})
        with self.assertRaisesRegex(ValueError, 'missing or ambiguous'):
            self.confirm()
        self.b.db.execute('UPDATE proposals SET expires=0 WHERE id=?', (one['proposal_id'],))
        self.b.db.execute('UPDATE proposals SET state="consumed" WHERE id=?', (two['proposal_id'],))
        self.b.db.commit()
        with self.assertRaisesRegex(ValueError, 'missing or ambiguous'):
            self.confirm()
        with self.assertRaisesRegex(ValueError, 'action or fields'):
            self.proposal('reference', {'key':'python-json', 'id':'0'*32})

    def test_publication_confirmation_needs_fresh_destination_grant_and_survives_restart(self):
        job = self.b.handle(self.req)
        proposal = self.proposal('publish', {'id':job['id']})
        with self.assertRaisesRegex(ValueError, 'fresh explicit publication authority'):
            self.confirm()
        second = Broker(self.tmp.name, self.token)
        self.addCleanup(second.db.close)
        second.post_gist = self.post
        confirmation_scope = 'b'*64
        envelope = second.capability_envelope('proposal_confirm', confirmation_scope, '#ai', 'irc.perl.org')
        publish = second.capability_envelope('publish', confirmation_scope, '#ai', 'irc.perl.org')
        result = second.handle(envelope | dict(action='proposal_confirm', requester='mateu',
                               confirmed_at=time.time(), publish_capability=publish['capability'], publish_grant=publish['grant']))
        self.assertEqual((result['confirmed_action'], result['state']), ('publish', 'published'))
        with self.assertRaisesRegex(ValueError, 'missing or ambiguous'):
            second.handle(envelope | dict(action='proposal_confirm', requester='mateu',
                          confirmed_at=time.time(), publish_capability=publish['capability'], publish_grant=publish['grant']))

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
