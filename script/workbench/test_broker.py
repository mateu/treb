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
        self.req = dict(action='run', scope='a'*64, requester='mateu', channel='#ai', network='irc.perl.org',
                        files={'main.py': 'print(42)\n', 'test.py': 'assert 6*7==42\n'},
                        argv=['/usr/bin/python3', '/work/test.py'], title='test')

    def post(self, payload):
        self.posts.append(payload)
        return 'https://gist.github.com/burt-agent/abcdef'

    def envelope(self, action, scope=None, channel='#ai', network='irc.perl.org', requester='mateu'):
        return {'action': action, 'scope': scope or self.req['scope'], 'requester': requester,
                'channel': channel, 'network': network}

    def publish(self, job):
        return self.b.handle(self.envelope('publish') | {'id': job['id']})

    def checkpoint(self, scope=None, requester='mateu', phase='stopped', reason='iteration_limit'):
        scope = scope or self.req['scope']
        envelope = self.envelope('task_checkpoint', scope, '#ai', 'irc.perl.org')
        return self.b.handle(envelope | {'requester': requester,
                                         'phase': phase, 'reason': reason})

    def test_checkpoint_lineage_uses_fresh_scope_and_task_wide_budget(self):
        first = self.b.handle(self.req)
        checkpoint = self.checkpoint()
        self.assertEqual(checkpoint['jobs'], [{'id': first['id'], 'state': 'passed'}])
        self.assertEqual(checkpoint['attempts_remaining'], 12)
        fresh_scope = 'b' * 64
        stale = self.envelope('task_resume', self.req['scope'], '#ai', 'irc.perl.org')
        with self.assertRaisesRegex(ValueError, 'fresh task scope'):
            self.b.handle(stale | {'action': 'task_resume', 'checkpoint_id': checkpoint['checkpoint_id'],
                                   'requester': 'mateu'})
        resume = self.envelope('task_resume', fresh_scope, '#ai', 'irc.perl.org')
        resumed = self.b.handle(resume | {'action': 'task_resume', 'checkpoint_id': checkpoint['checkpoint_id'],
                                          'requester': 'mateu'})
        self.assertEqual(resumed['resumed_scope'], fresh_scope)
        self.assertEqual(resumed['attempts_remaining'], 12)
        inspected = self.b.handle(self.envelope('job_inspect', fresh_scope, '#ai', 'irc.perl.org') | {'action': 'job_inspect', 'id': first['id']})
        self.assertEqual(inspected['files'], self.req['files'])
        self.assertEqual(inspected['state'], 'passed')
        with self.assertRaisesRegex(ValueError, 'fresh task scope is already bound'):
            self.b.handle(resume | {'action': 'task_resume', 'checkpoint_id': checkpoint['checkpoint_id'],
                                    'requester': 'mateu'})
        wrong_channel = self.envelope('checkpoint_status', 'c' * 64, '#mateu-test', 'irc.perl.org')
        with self.assertRaisesRegex(ValueError, 'checkpoint not found'):
            self.b.handle(wrong_channel | {'action': 'checkpoint_status', 'checkpoint_id': checkpoint['checkpoint_id'],
                                            'requester': 'mateu'})
        resumed_request = self.req | {'scope': fresh_scope, 'title': 'fresh'}
        second = self.b.handle(resumed_request)
        self.assertNotEqual(second['id'], first['id'])
        self.assertEqual(second['attempts_remaining'], 11)
        next_checkpoint = self.checkpoint(fresh_scope)
        self.assertEqual(next_checkpoint['parent_checkpoint_id'], checkpoint['checkpoint_id'])
        self.assertEqual([job['id'] for job in next_checkpoint['jobs']], [first['id'], second['id']])

    def test_resume_refreshes_deadline_without_resetting_task_spend(self):
        self.b.handle(self.req)
        checkpoint = self.checkpoint()
        self.b.db.execute('UPDATE task_phase_budgets SET deadline=0,terminal_reason="deadline"')
        self.b.db.commit()
        fresh_scope = 'b' * 64
        resume = self.envelope('task_resume', fresh_scope, '#ai', 'irc.perl.org')
        resumed = self.b.handle(resume | {'action': 'task_resume', 'checkpoint_id': checkpoint['checkpoint_id'],
                                          'requester': 'mateu', 'deadline': time.time() + 60})
        self.assertEqual(resumed['attempts_remaining'], 12)
        self.assertGreater(resumed['budget']['deadline_remaining_seconds'], 0)
        fresh = self.req | {'scope': fresh_scope, 'title': 'resumed'}
        self.assertEqual(self.b.handle(fresh)['attempts_remaining'], 11)

    def test_checkpointed_task_budget_survives_pruned_job_journal(self):
        for attempt in range(13):
            self.b.handle(self.req | {'title': f'attempt-{attempt}'})
        checkpoint = self.checkpoint()
        self.assertEqual(checkpoint['attempts_remaining'], 0)
        # Model the bounded job-journal retention path; durable task budget must
        # not be reconstructed from the remaining job rows.
        self.b.db.execute('DELETE FROM repo_jobs')
        self.b.db.execute('DELETE FROM jobs')
        self.b.db.commit()
        fresh_scope = 'b' * 64
        resume = self.envelope('task_resume', fresh_scope, '#ai', 'irc.perl.org')
        resumed = self.b.handle(resume | {'action': 'task_resume', 'checkpoint_id': checkpoint['checkpoint_id'],
                                          'requester': 'mateu'})
        self.assertEqual(resumed['attempts_remaining'], 0)
        sixth = self.req | {'scope': fresh_scope,
                            'title': 'must-not-run'}
        with self.assertRaisesRegex(ValueError, 'limit: 13 sandbox attempts'):
            self.b.handle(sixth)
        self.assertEqual(self.runs.__len__(), 13)

    def test_checkpointed_publication_budget_survives_pruned_job_journal(self):
        first = self.b.handle(self.req)
        self.publish(first)
        checkpoint = self.checkpoint()
        self.b.db.execute('DELETE FROM repo_jobs')
        self.b.db.execute('DELETE FROM jobs')
        self.b.db.commit()
        fresh_scope = 'b' * 64
        resume = self.envelope('task_resume', fresh_scope, '#ai', 'irc.perl.org')
        self.b.handle(resume | {'action': 'task_resume', 'checkpoint_id': checkpoint['checkpoint_id'],
                                'requester': 'mateu'})
        candidate = self.b.handle(self.req | {'scope': fresh_scope,
            'title': 'fresh-after-prune'})
        with self.assertRaisesRegex(ValueError, 'one gist submission'):
            self.b.handle(self.envelope('publish', fresh_scope, '#ai', 'irc.perl.org')
                          | {'action': 'publish', 'id': candidate['id']})

    def test_uncertain_checkpoint_is_visible_and_absorbs_resume_and_publication(self):
        job = self.b.handle(self.req)
        self.b.post_gist = lambda payload: (_ for _ in ()).throw(OSError('lost response'))
        with self.assertRaisesRegex(ValueError, 'do not retry'):
            self.publish(job)
        checkpoint = self.checkpoint()
        self.assertEqual(checkpoint['jobs'][0]['state'], 'uncertain')
        self.assertEqual(checkpoint['budget']['terminal_reason'], 'publication_uncertain')
        terminal = self.envelope('task_status', self.req['scope'], '#ai', 'irc.perl.org') | {
            'action': 'task_status', 'phase': 'reported', 'reason': 'final_report'}
        self.assertEqual(self.b.handle(terminal)['budget']['terminal_reason'], 'publication_uncertain')
        status = self.envelope('checkpoint_status', 'b' * 64, '#ai', 'irc.perl.org')
        visible = self.b.handle(status | {'action': 'checkpoint_status', 'checkpoint_id': checkpoint['checkpoint_id'],
                                          'requester': 'mateu'})
        self.assertEqual(visible['jobs'][0]['state'], 'uncertain')
        resume = self.envelope('task_resume', 'b' * 64, '#ai', 'irc.perl.org')
        with self.assertRaisesRegex(ValueError, 'operator reconciliation'):
            self.b.handle(resume | {'action': 'task_resume', 'checkpoint_id': checkpoint['checkpoint_id'],
                                    'requester': 'mateu'})
        with self.assertRaisesRegex(ValueError, 'operator reconciliation'):
            self.publish(job)

    def test_phase_budget_is_durable_and_reserves_one_terminal_report(self):
        deadline = time.time() + 120
        status = self.envelope('task_status', self.req['scope'], '#ai', 'irc.perl.org') | {
            'action': 'task_status', 'phase': 'started', 'reason': 'admitted', 'deadline': deadline,
            'model_iterations': 3}
        admitted = self.b.handle(status)
        self.assertEqual(admitted['budget']['remaining_budget']['model_iterations'], 23)
        self.assertEqual(admitted['budget']['remaining_budget']['terminal_reports'], 1)
        with self.assertRaisesRegex(ValueError, 'invalid model iteration count'):
            self.b.handle(status | {'model_iterations': 27})
        progress = self.envelope('task_progress', self.req['scope'], '#ai', 'irc.perl.org') | {'action': 'task_progress'}
        for _ in range(8):
            self.b.handle(progress)
        with self.assertRaisesRegex(ValueError, 'progress notice budget'):
            self.b.handle(progress)
        job = self.b.handle(self.req)
        checkpoint = self.checkpoint()
        self.assertEqual(checkpoint['budget']['remaining_budget']['sandbox_executions'], 12)
        terminal = status | {'phase': 'reported', 'reason': 'final_report'}
        finished = self.b.handle(terminal)
        self.assertEqual(finished['budget']['remaining_budget']['terminal_reports'], 0)
        # A late duplicate terminal callback remains idempotent rather than
        # spending a second report reservation.
        self.assertEqual(self.b.handle(terminal)['budget']['remaining_budget']['terminal_reports'], 0)
        with self.assertRaisesRegex(ValueError, 'task is terminal'):
            self.b.handle(self.req | {'title': 'late-callback'})
        restarted = Broker(self.tmp.name, self.token)
        self.addCleanup(restarted.db.close)
        row = restarted.db.execute('SELECT model_iterations,terminal_reports,terminal_reason FROM task_phase_budgets').fetchone()
        self.assertEqual(tuple(row), (3, 1, 'final_report'))
        self.assertEqual(job['state'], 'passed')

    def test_phase_budget_deadline_blocks_execution_but_not_terminal_receipt(self):
        status = self.envelope('task_status', self.req['scope'], '#ai', 'irc.perl.org') | {
            'action': 'task_status', 'phase': 'started', 'reason': 'admitted', 'deadline': time.time() + 60}
        self.b.handle(status)
        self.b.db.execute('UPDATE task_phase_budgets SET deadline=0')
        self.b.db.commit()
        with self.assertRaisesRegex(ValueError, 'task deadline reached'):
            self.b.handle(self.req)
        final = self.b.handle(status | {'phase': 'reported', 'reason': 'final_report'})
        self.assertEqual(final['budget']['terminal_reason'], 'deadline')
        self.assertEqual(final['budget']['remaining_budget']['terminal_reports'], 0)

    def test_thin_envelope_rejects_legacy_and_malformed_fields(self):
        for request in (
            {k:v for k,v in self.req.items() if k != 'requester'},
            self.req | {'capability': 'edit_test'},
            self.req | {'grant': '0' * 64},
            self.req | {'action': 'publish', 'id': '0' * 32},
        ):
            with self.assertRaisesRegex(ValueError, 'invalid action or fields'):
                self.b.handle(request)
        self.assertEqual(self.b.handle(self.req)['state'], 'passed')

    def test_exact_bundle_and_idempotence(self):
        r = self.b.handle(self.req)
        self.assertEqual(r['state'], 'passed')
        self.assertEqual(self.b.handle(self.req)['id'], r['id'])
        self.assertEqual(len(self.runs), 1)
        self.assertEqual(self.publish(r)['state'], 'published')
        self.assertEqual(self.publish(r)['state'], 'published')
        self.assertEqual(len(self.posts), 1)
        replayed = self.b.handle(self.req)
        self.assertEqual(replayed['id'], r['id'])
        self.assertEqual(replayed['state'], 'published')
        checkpoint = self.checkpoint()
        self.assertEqual(checkpoint['latest_execution_job'], {'id': r['id'], 'state': 'passed'})
        self.assertEqual(self.posts[0]['files'], {n:{'content':c} for n,c in self.req['files'].items()})
        self.assertTrue(self.posts[0]['public'])

    def test_execution_selection_migrates_from_original_column_order(self):
        self.b.db.execute('DROP TABLE task_execution_selections')
        self.b.db.execute('CREATE TABLE task_execution_selections '
                          '(task_id TEXT PRIMARY KEY, job_id TEXT NOT NULL, selected REAL NOT NULL)')
        self.b.db.execute('ALTER TABLE task_execution_selections ADD COLUMN execution_state TEXT')
        self.b.remember_task_execution_selection(self.req, 'a' * 32, 'passed', now=123.0)
        row = self.b.db.execute('SELECT * FROM task_execution_selections').fetchone()
        self.assertEqual((row['task_id'], row['job_id'], row['execution_state'], row['selected']),
                         (self.req['scope'], 'a' * 32, 'passed', 123.0))

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
        r = self.b.handle(self.req | {'channel':'#mateu-test'})
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

    def test_resource_checkpoints_have_bounded_retention(self):
        now=time.time()
        for i in range(513):
            self.b.db.execute('INSERT INTO resource_checkpoints VALUES (?,?,?,?,?,?,?,?,?,?)',
                              (f'{i:032x}', 'job', f'{i:032x}', 'a'*64, 'a'*64, 'mateu', '#ai', 'irc.perl.org', now, 'passed'))
        self.b.prune_audit(); self.b.db.commit()
        self.assertEqual(self.b.db.execute('SELECT COUNT(*) FROM resource_checkpoints').fetchone()[0], 512)

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
        # A fresh scope can run at most thirteen distinct attempts.
        self.req['scope'] = 'c'*64
        for i in range(13): self.b.handle(self.req | {'title':str(i)})
        with self.assertRaises(ValueError): self.b.handle(self.req | {'title':'fourteenth'})

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
        result = second.handle(self.envelope('publish') | {'id': r['id']})
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
