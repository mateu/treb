import base64
import json
from pathlib import Path
import subprocess
import time
import unittest
from urllib.error import HTTPError
from repository import Repository, validate_destination, validate_files
import test_broker

A, B, C, D = (c*40 for c in 'abcd')


class FakeRepository(Repository):
    def __init__(self):
        self.calls = []
        self.exists = False
        self.head = A
        self.files = {}
        self.entries = None
        self.fail_write = False

    def api(self, path, payload=None, method=None):
        self.calls.append((path, payload, method))
        if path == '/user': return {'login':'burt-agent'}
        if path == '/repos/burt-agent/workspace':
            return {'full_name':'burt-agent/workspace','private':False,'permissions':{'push':True}}
        if payload is not None:
            if self.fail_write: raise TimeoutError()
            if path.endswith('/git/trees'): return {'sha':C}
            if path.endswith('/git/commits'): return {'sha':D}
            if path.endswith('/git/refs') or '/git/refs/heads/' in path:
                self.exists, self.head = True, D
                return {'ref':'refs/heads/burt/dictionary', 'object':{'sha':D}}
            raise AssertionError(path)
        if '/git/ref/heads/' in path:
            if not self.exists and not path.endswith('/main'):
                raise HTTPError(path,404,'missing',{},None)
            return {'object':{'sha':self.head}}
        if '/git/commits/' in path: return {'tree':{'sha':B}}
        if '/git/trees/' in path:
            entries = self.entries if self.entries is not None else [dict(path='projects/dictionary/'+n,
                        mode='100644',type='blob',size=len(v.encode()),sha=str(i)*40)
                        for i,(n,v) in enumerate(self.files.items(), 1)]
            return {'tree':entries, 'truncated':False}
        if '/git/blobs/' in path:
            idx = int(path.rsplit('/',1)[1][0])-1
            return {'encoding':'base64','content':base64.b64encode(list(self.files.values())[idx].encode()).decode()}
        raise AssertionError(path)


class RepositoryTests(unittest.TestCase):
    def test_paths_and_destination(self):
        for b,p in [('main','dictionary'),('burt/../main','x'),('burt/x','../x'),('burt/x','')]:
            with self.assertRaises(ValueError): validate_destination(b,p)
        for files in ({'../x':'x'},{'.github/x':'x'},{'a//b':'x'},{'a':'x','a/b':'y'},
                      {'a':'\x00'},{'a':'x'*131073},{'a':1}):
            with self.assertRaises(ValueError): validate_files(files)
        validate_files({'lib/Dictionary.pm':'1;', 't/client.t':'ok 1'})

    def test_read_new_and_existing(self):
        r=FakeRepository()
        self.assertFalse(r.snapshot('burt/dictionary','dictionary')['exists'])
        r.exists=True
        r.files={'lib/Client.pm':'1;', 't/client.t':'ok 1'}
        snapshot=r.snapshot('burt/dictionary','dictionary')
        self.assertEqual(snapshot['files'],r.files)
        self.assertEqual(snapshot['base_sha'],A)
        self.assertFalse(any(p is not None for _,p,_ in r.calls))

    def test_symlinks_submodules_and_binary_fail_closed(self):
        for mode,kind in [('120000','blob'),('160000','commit')]:
            r=FakeRepository();r.entries=[dict(path='projects/dictionary/x', mode=mode,type=kind,size=1,sha=A)]
            with self.assertRaises(ValueError): r.snapshot('burt/dictionary','dictionary')
        r=FakeRepository();r.entries=[dict(path='projects/dictionary',type='blob')]
        with self.assertRaises(ValueError): r.snapshot('burt/dictionary','dictionary')
        r=FakeRepository();r.files={'bad.txt':'\x00'}
        with self.assertRaises(ValueError): r.snapshot('burt/dictionary','dictionary')

    def test_only_project_changes_and_no_force_push(self):
        for exists in (False,True):
            r=FakeRepository();r.exists=exists;r.files={'old.txt':'old'}
            snapshot=r.snapshot('burt/dictionary','dictionary')
            url=r.publish(snapshot,{'lib/Client.pm':'1;'},'tested client')
            self.assertTrue(url.endswith('/'+D))
            writes=[(path,p,method) for path,p,method in r.calls if p is not None]
            tree=writes[0][1]
            self.assertEqual(tree['base_tree'],B)
            self.assertEqual(tree['tree'],[{'path':'projects/dictionary/lib/Client.pm','mode':'100644','type':'blob','content':'1;'},
                                          {'path':'projects/dictionary/old.txt','mode':'100644','type':'blob','sha':None}])
            self.assertEqual(writes[1][1]['parents'],[A])
            if exists:
                self.assertEqual(writes[2][1],{'sha':D,'force':False})
                self.assertEqual(writes[2][2],'PATCH')
            else: self.assertEqual(writes[2][1]['ref'],'refs/heads/burt/dictionary')


class RepositoryBrokerTests(unittest.TestCase):
    post = test_broker.BrokerTests.post
    publish = test_broker.BrokerTests.publish

    def setUp(self):
        test_broker.BrokerTests.setUp(self)
        self.repo=FakeRepository();self.b.repository=self.repo
        snapshot=self.b.handle(self.b.capability_envelope('repo_read', self.req['scope'], self.req['channel'], self.req['network']) | dict(action='repo_read',branch='burt/dictionary',project='dictionary'))
        self.repo_req={k:v for k,v in self.req.items() if k not in ('files','argv','title')}|dict(
                  action='repo_run',snapshot_id=snapshot['snapshot_id'],
                  changes={'lib/main.py':'print(42)','t/test.py':'assert 42==42'},delete=[],
                  argv=['/bin/sh','-c','true'],title='repository test')

    def request(self, action):
        return self.b.capability_envelope(action, self.req['scope'], self.req['channel'], self.req['network'])

    def checkpoint(self, scope=None, requester='mateu'):
        scope = scope or self.req['scope']
        return self.b.handle(self.b.capability_envelope('task_checkpoint', scope, '#ai', 'irc.perl.org')
                             | {'action': 'task_checkpoint', 'requester': requester,
                                'phase': 'stopped', 'reason': 'iteration_limit'})

    def repo_publish(self, job):
        # Existing explicit-job cases exercise the broker's durable-offer path.
        return self.b._handle(self.b.capability_envelope('repo_publish', self.req['scope'], self.req['channel'], self.req['network'])|{'action':'repo_publish','id':job['id']}, _confirmed_publication=True)

    def direct_repo_publish(self, scope='b' * 64):
        return self.b.handle(self.b.capability_envelope('repo_publish', scope, self.req['channel'], self.req['network'])
                             | {'action':'repo_publish', 'requester':'mateu'})

    def test_exact_transcript_crosses_runtime_grant_to_broker_fake_publication_boundary(self):
        # The Perl runtime is the producer.  Capture its actual no-ID envelope,
        # then feed it to the Python broker with a fake repository write edge.
        self.b.db.execute('INSERT INTO task_scopes VALUES (?,?,?,?,?,?)',
                          (self.req['scope'], self.req['scope'], 'mateu', '#ai', 'irc.perl.org', time.time()))
        self.b.db.commit()
        job = self.b.handle(self.repo_req)
        # The later exact human request must discover durable prior work, not
        # only a job created within the former 900-second convenience window.
        self.b.db.execute('UPDATE jobs SET created=? WHERE id=?', (time.time() - 3600, job['id']))
        self.b.db.commit()
        root = Path(__file__).resolve().parents[2]
        perl = r'''use strict; use warnings; use JSON::PP; use lib 'lib'; use Bot::Runtime::Workbench;
{ package BoundaryBot; sub _bot_name_slug { 'burt' } sub get_nickname { 'burt_bot' }
  sub _is_human_nick { $_[1] ne 'system' } sub _pending_raid { $_[0]{pending} }
  sub _send_to_channel {} }
{ package BoundaryTool; sub text_result { $_[1] } }
$ENV{BURT_WORKBENCH_SOCKET} = '/not/a/socket'; $ENV{IRC_SERVER} = 'irc.perl.org';
my $bot = bless { pending => { channel => '#ai', expires_at => time + 60, messages => [
  { nick => 'mateu', source_kind => 'conversation', queued_at => time,
    msg => 'burt_bot: read burt-agent/workspace project dictionary on branch burt/dictionary, run the tests, and push if they pass.' } ] } }, 'BoundaryBot';
my %defs = map { $_->{name} => $_ } @{ Bot::Runtime::Workbench::tool_specs($bot) };
no warnings 'redefine'; local *Bot::Runtime::Workbench::broker_call = sub { print JSON::PP::encode_json($_[0]); return '{"state":"passed"}' };
$defs{publish_repo}{code}->(bless({}, 'BoundaryTool'), {});'''
        produced = subprocess.run(['script/with-burt-env.sh', 'perl', '-Ilib', '-e', perl], cwd=root,
                                  text=True, capture_output=True)
        self.assertEqual(produced.returncode, 0, produced.stderr)
        envelope = json.loads(produced.stdout)
        self.assertEqual(envelope['capability'], 'publish_repo')
        self.assertNotIn('id', envelope)
        self.assertNotIn('destination', envelope)
        published = self.b.handle(envelope)
        self.assertEqual((published['id'], published['state']), (job['id'], 'published'))
        self.assertEqual(len([1 for _, payload, _ in self.repo.calls if payload is not None]), 3)
        with self.assertRaisesRegex(ValueError, 'selects its job'):
            self.b.handle(self.b.capability_envelope('repo_publish', 'c' * 64, '#ai', 'irc.perl.org')
                          | {'action':'repo_publish', 'requester':'mateu', 'id':job['id']})

    def test_direct_publish_binds_prior_candidate_then_revalidates_before_fake_write(self):
        # A prior immutable passed job remains eligible for a later current human
        # request; freshness is established by current policy/base validation,
        # not a wall-clock discard of the saved tested bundle.
        self.b.db.execute('INSERT INTO task_scopes VALUES (?,?,?,?,?,?)',
                          (self.req['scope'], self.req['scope'], 'mateu', '#ai', 'irc.perl.org', time.time()))
        self.b.db.commit()
        job = self.b.handle(self.repo_req)
        self.b.db.execute('UPDATE jobs SET created=? WHERE id=?',
                          (time.time() - 3600, job['id']))
        # Simulate the original coding request expiring before the later human
        # publication request arrives; the fresh request owns write authority.
        self.b.db.execute('UPDATE task_phase_budgets SET deadline=? WHERE task_id=?',
                          (time.time() - 1, self.req['scope']))
        self.b.db.commit()
        self.repo.head = C
        with self.assertRaisesRegex(ValueError, 'branch changed; read project and retest'):
            self.direct_repo_publish()
        bound = self.b.db.execute('SELECT job_id FROM direct_repo_publications WHERE scope=?',
                                  ('b' * 64,)).fetchone()
        self.assertEqual(bound['job_id'], job['id'])
        self.assertFalse(any(payload is not None for _, payload, _ in self.repo.calls))
        self.repo.head = A
        published = self.direct_repo_publish()
        self.assertEqual((published['id'], published['state']), (job['id'], 'published'))
        self.assertEqual(len([1 for _, payload, _ in self.repo.calls if payload is not None]), 3)
        original_budget = self.b.db.execute(
            'SELECT public_writes FROM task_phase_budgets WHERE task_id=?', (self.req['scope'],)).fetchone()
        self.assertEqual(original_budget['public_writes'], 1)
        attempt = self.b.db.execute('SELECT attempted FROM publication_attempts WHERE job_id=?',
                                    (job['id'],)).fetchone()
        self.assertIsNotNone(attempt)
        self.assertGreater(attempt['attempted'], time.time() - 60)

    def test_old_candidate_uses_current_publication_attempt_limit(self):
        self.b.db.execute('INSERT INTO task_scopes VALUES (?,?,?,?,?,?)',
                          (self.req['scope'], self.req['scope'], 'mateu', '#ai', 'irc.perl.org', time.time()))
        self.b.db.commit()
        job = self.b.handle(self.repo_req)
        self.b.db.execute('UPDATE jobs SET created=? WHERE id=?',
                          (time.time() - 2 * 86400, job['id']))
        now = time.time()
        for n in range(10):
            self.b.db.execute('INSERT INTO publication_attempts VALUES (?,?)',
                              (f'{n:032x}', now))
        self.b.db.commit()
        with self.assertRaisesRegex(ValueError, 'global limit: 10 submissions per day'):
            self.direct_repo_publish()
        self.assertFalse(any(payload is not None for _, payload, _ in self.repo.calls))

    def test_daily_attempt_limit_keeps_preupgrade_current_publications(self):
        now = time.time()
        for n in range(10):
            self.b.db.execute('INSERT INTO jobs VALUES (?,?,?,?,?,?,?,?,?)',
                              (f'{n + 100:032x}', self.req['scope'], f'legacy-{n}', now,
                               '{}', 'legacy', '{}', 'published', None))
        self.b.db.commit()
        self.assertEqual(self.b.publication_attempt_count(now), 10)

    def test_direct_publish_initializes_missing_legacy_task_budget(self):
        self.b.db.execute('INSERT INTO task_scopes VALUES (?,?,?,?,?,?)',
                          (self.req['scope'], self.req['scope'], 'mateu', '#ai', 'irc.perl.org', time.time()))
        self.b.db.commit()
        job = self.b.handle(self.repo_req)
        # Simulate a passed repository job persisted before phase budgets existed.
        self.b.db.execute('DELETE FROM task_phase_budgets WHERE task_id=?', (self.req['scope'],))
        self.b.db.commit()
        published = self.direct_repo_publish()
        self.assertEqual((published['id'], published['state']), (job['id'], 'published'))
        budget = self.b.db.execute('SELECT public_writes FROM task_phase_budgets WHERE task_id=?',
                                   (self.req['scope'],)).fetchone()
        self.assertEqual(budget['public_writes'], 1)

    def test_direct_publish_retry_keeps_its_initial_job_binding(self):
        self.b.db.execute('INSERT INTO task_scopes VALUES (?,?,?,?,?,?)',
                          (self.req['scope'], self.req['scope'], 'mateu', '#ai', 'irc.perl.org', time.time()))
        self.b.db.commit()
        first = self.b.handle(self.repo_req)
        initial = self.direct_repo_publish()
        self.assertEqual((initial['id'], initial['state']), (first['id'], 'published'))
        writes = len([1 for _, payload, _ in self.repo.calls if payload is not None])
        later_scope = 'd' * 64
        later_id = 'e' * 32
        self.b.db.execute('INSERT INTO task_scopes VALUES (?,?,?,?,?,?)',
                          (later_scope, later_scope, 'mateu', '#ai', 'irc.perl.org', time.time()))
        first_row = self.b.db.execute('SELECT * FROM jobs WHERE id=?', (first['id'],)).fetchone()
        self.b.db.execute('INSERT INTO jobs VALUES (?,?,?,?,?,?,?,?,?)',
                          (later_id, later_scope, 'later-passed-job', time.time(), first_row['files'],
                           first_row['title'], first_row['result'], 'passed', None))
        destination = self.b.db.execute('SELECT destination FROM repo_jobs WHERE id=?', (first['id'],)).fetchone()['destination']
        self.b.db.execute('INSERT INTO repo_jobs VALUES (?,?)', (later_id, destination))
        self.b.db.commit()
        retried = self.direct_repo_publish()
        self.assertEqual((retried['id'], retried['state']), (first['id'], 'published'))
        self.assertEqual(len([1 for _, payload, _ in self.repo.calls if payload is not None]), writes)

    def test_direct_publish_preserves_material_candidate_across_later_base_only_test(self):
        # Transcript regression: a natural task changes query parsing, then a
        # later full-suite run against the base snapshot must not shadow it.
        self.b.db.execute('INSERT INTO task_scopes VALUES (?,?,?,?,?,?)',
                          (self.req['scope'], self.req['scope'], 'mateu', '#ai', 'irc.perl.org', time.time()))
        self.b.db.commit()
        self.repo.files = {'lib/query.py':'def parse(query): return query'}
        snapshot = self.b.handle(self.b.capability_envelope('repo_read', self.req['scope'], '#ai', 'irc.perl.org') | {
            'action':'repo_read', 'branch':'burt/dictionary', 'project':'dictionary'})
        changed_req = self.repo_req | {'snapshot_id': snapshot['snapshot_id']}
        changed = self.b.handle(changed_req | {
            'changes': {'lib/query.py':'def parse(qtype, idtype): return qtype, idtype'},
            'title':'query-string request style (qtype/idtype/id/lang)'})
        base_only = self.b.handle(changed_req | {
            'changes': {}, 'title':'full offline suite on burt/dictionary'})
        candidate = self.b.db.execute('SELECT job_id FROM repository_candidates').fetchone()
        self.assertEqual(candidate['job_id'], changed['id'])
        published = self.direct_repo_publish()
        self.assertEqual((published['id'], published['state']), (changed['id'], 'published'))
        self.assertNotEqual(base_only['id'], published['id'])

    def test_direct_publish_recovers_legacy_candidate_from_its_origin_scope(self):
        self.b.db.execute('INSERT INTO task_scopes VALUES (?,?,?,?,?,?)',
                          (self.req['scope'], self.req['scope'], 'mateu', '#ai', 'irc.perl.org', time.time()))
        self.b.db.commit()
        job = self.b.handle(self.repo_req)
        destination = json.loads(self.b.db.execute('SELECT destination FROM repo_jobs WHERE id=?',
                                                   (job['id'],)).fetchone()['destination'])
        destination.pop('candidate_material')
        self.b.db.execute('UPDATE repo_jobs SET destination=? WHERE id=?',
                          (json.dumps(destination), job['id']))
        self.b.db.execute('DELETE FROM repository_candidates WHERE job_id=?', (job['id'],))
        self.b.db.commit()
        published = self.direct_repo_publish()
        self.assertEqual((published['id'], published['state']), (job['id'], 'published'))

    def test_cached_material_retest_refreshes_repository_candidate(self):
        self.b.db.execute('INSERT INTO task_scopes VALUES (?,?,?,?,?,?)',
                          (self.req['scope'], self.req['scope'], 'mateu', '#ai', 'irc.perl.org', time.time()))
        self.b.db.commit()
        first_req = self.repo_req | {'changes': {'lib/main.py':'print("A")'}}
        first = self.b.handle(first_req)
        second = self.b.handle(self.repo_req | {'changes': {'lib/main.py':'print("B")'}})
        replayed = self.b.handle(first_req)
        self.assertEqual(replayed['id'], first['id'])
        candidate = self.b.db.execute('SELECT job_id FROM repository_candidates').fetchone()
        self.assertEqual(candidate['job_id'], first['id'])
        self.assertNotEqual(candidate['job_id'], second['id'])

    def test_direct_publish_ignores_prior_completed_candidate(self):
        self.b.db.execute('INSERT INTO task_scopes VALUES (?,?,?,?,?,?)',
                          (self.req['scope'], self.req['scope'], 'mateu', '#ai', 'irc.perl.org', time.time()))
        self.b.db.commit()
        completed = self.b.handle(self.repo_req)
        self.assertEqual(self.direct_repo_publish()['id'], completed['id'])
        other_scope = 'c' * 64
        self.b.db.execute('INSERT INTO task_scopes VALUES (?,?,?,?,?,?)',
                          (other_scope, other_scope, 'mateu', '#ai', 'irc.perl.org', time.time()))
        self.b.db.commit()
        snapshot = self.b.handle(self.b.capability_envelope('repo_read', other_scope, '#ai', 'irc.perl.org') | {
            'action':'repo_read', 'branch':'burt/other-project', 'project':'other-project'})
        pending = self.b.handle(self.b.capability_envelope('repo_run', other_scope, '#ai', 'irc.perl.org') | {
            'action':'repo_run', 'snapshot_id': snapshot['snapshot_id'],
            'changes': {'lib/other.py':'print(1)'}, 'delete': [], 'argv': ['/bin/sh','-c','true'],
            'title':'other project candidate'})
        request = self.b.capability_envelope('repo_publish', 'd' * 64, '#ai', 'irc.perl.org') | {
            'action':'repo_publish', 'requester':'mateu'}
        selected = self.b.direct_repository_publication_job(request)
        self.assertEqual((selected['id'], selected['state']), (pending['id'], 'passed'))

    def test_direct_publish_rejects_multiple_project_candidates(self):
        self.b.db.execute('INSERT INTO task_scopes VALUES (?,?,?,?,?,?)',
                          (self.req['scope'], self.req['scope'], 'mateu', '#ai', 'irc.perl.org', time.time()))
        self.b.db.commit()
        self.b.handle(self.repo_req)
        snapshot = self.b.handle(self.b.capability_envelope('repo_read', self.req['scope'], '#ai', 'irc.perl.org') | {
            'action':'repo_read', 'branch':'burt/other-project', 'project':'other-project'})
        self.b.handle(self.repo_req | {
            'snapshot_id': snapshot['snapshot_id'],
            'changes': {'lib/other.py':'print(1)'},
            'title':'other project candidate'})
        with self.assertRaisesRegex(ValueError, 'one unambiguous saved project candidate'):
            self.direct_repo_publish()
        self.assertFalse(any(payload is not None for _, payload, _ in self.repo.calls))

    def test_edit_authority_can_read_its_required_snapshot(self):
        req=self.b.capability_envelope('repo_run', self.req['scope'], self.req['channel'], self.req['network']) | {
            'action':'repo_read', 'branch':'burt/dictionary', 'project':'dictionary'}
        snapshot=self.b.handle(req)
        self.assertIn('snapshot_id', snapshot)
        self.assertEqual(snapshot['files'], self.repo.files)

    def test_repo_idempotence_restart_exact_inputs_and_destination(self):
        r=self.b.handle(self.repo_req)
        self.assertEqual(self.runs[-1]['files'],self.repo_req['changes'])
        with self.assertRaises(ValueError): self.publish(r)
        self.repo_publish(r)
        # Publisher returns stored URL even after restart, without networking.
        from broker import Broker
        second=Broker(self.tmp.name,self.token);self.addCleanup(second.db.close)
        result=second._handle(second.capability_envelope('repo_publish',self.req['scope'],self.req['channel'],self.req['network'])|{'action':'repo_publish','id':r['id']}, _confirmed_publication=True)
        self.assertEqual(result['state'],'published')
        self.assertEqual(self.repo_publish(r)['url'],result['url'])
        self.assertEqual(len([1 for _,p,_ in self.repo.calls if p is not None]),3)
        gist=self.b.handle(self.b.capability_envelope('run','f'*64,self.req['channel'],self.req['network']) | {k:v for k,v in self.req.items() if k not in ('scope','capability','grant')})
        self.req['scope']='f'*64
        with self.assertRaises(ValueError): self.repo_publish(gist)

    def test_stale_and_ambiguous(self):
        r=self.b.handle(self.repo_req)
        self.repo.head=B
        with self.assertRaisesRegex(ValueError,'branch changed'): self.repo_publish(r)
        self.assertFalse(any(p is not None for _,p,_ in self.repo.calls))
        with self.assertRaisesRegex(ValueError,'branch changed'): self.b.handle(self.repo_req)
        self.repo.head=A;self.repo.fail_write=True
        with self.assertRaisesRegex(ValueError,'reconciliation'): self.repo_publish(r)
        self.assertEqual(self.b.db.execute('SELECT state FROM jobs WHERE id=?',(r['id'],)).fetchone()[0],'uncertain')
        count=len(self.repo.calls)
        with self.assertRaises(ValueError): self.repo_publish(r)
        self.assertEqual(count,len(self.repo.calls))

    def test_failed_scope_and_substituted_destination(self):
        r=self.b.handle(self.repo_req)
        with self.assertRaises(ValueError): self.b.handle(self.repo_req|{'action':'repo_publish','id':r['id']})
        self.req['scope']='b'*64
        with self.assertRaises(ValueError): self.repo_publish(r)
        self.req['scope']='a'*64
        self.b.execute=lambda job:{'reason':'output_limit','exit_code':0}
        failed=self.b.handle(self.repo_req|{'title':'truncated'})
        with self.assertRaises(ValueError): self.repo_publish(failed)

    def repair(self, job, **changes):
        return self.b.handle(self.b.capability_envelope('repo_repair', self.req['scope'], self.req['channel'], self.req['network'])
                             | dict(action='repo_repair',id=job['id'],changes={'lib/main.py':'print(43)'},
                                    delete=[],argv=self.repo_req['argv'],title='repair') | changes)

    def test_resumed_scope_accesses_same_task_resources_but_not_another_task(self):
        original = self.b.handle(self.repo_req)
        checkpoint = self.checkpoint()
        resumed_scope = 'b' * 64
        resume = self.b.capability_envelope('task_resume', resumed_scope, '#ai', 'irc.perl.org')
        resumed_task = self.b.handle(resume | {'action': 'task_resume', 'checkpoint_id': checkpoint['checkpoint_id'],
                                               'requester': 'mateu'})
        self.assertEqual(resumed_task['latest_repository_job'],
                         {'id': original['id'], 'state': 'passed'})

        def resumed(action):
            return self.b.capability_envelope(action, resumed_scope, '#ai', 'irc.perl.org')

        inspected = self.b.handle(resumed('repo_inspect') | {'action': 'repo_inspect', 'id': original['id']})
        self.assertEqual(inspected['id'], original['id'])
        repaired = self.b.handle(resumed('repo_repair') | {
            'action': 'repo_repair', 'id': original['id'],
            'changes': {'lib/main.py': 'print(43)'}, 'delete': [],
            'argv': self.repo_req['argv'], 'title': 'resumed repair'})
        self.assertEqual(repaired['state'], 'passed')
        published = self.b._handle(resumed('repo_publish') | {'action': 'repo_publish', 'id': repaired['id']}, _confirmed_publication=True)
        self.assertEqual(published['state'], 'published')
        self.assertGreaterEqual(self.b.db.execute(
            "SELECT COUNT(*) FROM resource_checkpoints WHERE resource_id=?", (repaired['id'],)).fetchone()[0], 3)

        other_scope = 'c' * 64
        self.checkpoint(other_scope)
        denied = self.b.capability_envelope('repo_inspect', other_scope, '#ai', 'irc.perl.org')
        with self.assertRaisesRegex(ValueError, 'repository job not found'):
            self.b.handle(denied | {'action': 'repo_inspect', 'id': original['id']})

    def test_saved_jobs_repair_and_diagnose_after_snapshot_expiry(self):
        original=self.b.handle(self.repo_req)
        snapshot_id=json.loads(self.b.db.execute('SELECT destination FROM repo_jobs WHERE id=?',
                                                  (original['id'],)).fetchone()[0])['snapshot_id']
        self.b.db.execute('UPDATE repo_snapshots SET expires=0 WHERE id=?', (snapshot_id,))
        self.b.db.commit()
        with self.assertRaisesRegex(ValueError, 'snapshot expired'):
            self.b.handle(self.repo_req)
        repaired=self.repair(original)
        self.assertEqual(repaired['state'], 'passed')
        diagnostic=self.b.handle(self.request('repo_diagnose') | {
            'action':'repo_diagnose', 'id':original['id'],
            'argv':['/usr/bin/python3','-c','print(1)'], 'title':'expired snapshot diagnostic'})
        self.assertEqual(diagnostic['state'], 'passed')

    def test_checkpointed_jobs_keep_their_snapshot_through_pruning(self):
        original=self.b.handle(self.repo_req)
        snapshot_id=json.loads(self.b.db.execute('SELECT destination FROM repo_jobs WHERE id=?',
                                                  (original['id'],)).fetchone()[0])['snapshot_id']
        self.checkpoint()
        self.b.db.execute('UPDATE jobs SET created=0 WHERE id=?', (original['id'],))
        self.b.db.execute('UPDATE repo_snapshots SET created=0,expires=0 WHERE id=?', (snapshot_id,))
        self.b.db.commit()
        other=self.b.capability_envelope('run', 'b'*64, '#ai', 'irc.perl.org') | {k:v for k,v in self.req.items() if k not in ('scope','capability','grant')} | {'title':'unrelated retention trigger'}
        self.b.handle(other)
        self.checkpoint()
        self.assertIsNotNone(self.b.db.execute('SELECT id FROM repo_snapshots WHERE id=?', (snapshot_id,)).fetchone())
        self.assertIsNotNone(self.b.db.execute('SELECT id FROM jobs WHERE id=?', (original['id'],)).fetchone())
        self.assertEqual(self.repair(original)['state'], 'passed')

    def test_repair_preserves_bundle_and_publishes_only_retested_inputs(self):
        self.b.execute=lambda job: {'reason':'exited','exit_code':1,'output':'broken'}
        original=self.b.handle(self.repo_req)
        self.b.execute=lambda job: self.runs.append(job) or {'reason':'exited','exit_code':0,'output':'ok'}
        fixed=self.repair(original)
        self.assertNotEqual(original['id'],fixed['id'])
        expected=self.repo_req['changes'] | {'lib/main.py':'print(43)'}
        self.assertEqual(self.runs[-1]['files'],expected)
        self.assertEqual(self.b.db.execute('SELECT files FROM jobs WHERE id=?',(original['id'],)).fetchone()[0],json.dumps(self.repo_req['changes']))
        self.assertEqual(self.repair(original)['id'],fixed['id'])
        self.assertEqual(len(self.runs),1)
        with self.assertRaises(ValueError): self.repo_publish(original)
        self.repo_publish(fixed)
        tree=next(p['tree'] for _,p,_ in self.repo.calls if p is not None and 'tree' in p)
        self.assertEqual({x['path'].removeprefix('projects/dictionary/'):x['content'] for x in tree},expected)

    def test_inspect_and_repair_scope_and_stale_base(self):
        job=self.b.handle(self.repo_req)
        req=self.request('repo_inspect') | dict(action='repo_inspect',id=job['id'])
        inspected=self.b.handle(req)
        self.assertEqual(inspected['files'],self.repo_req['changes'])
        self.assertEqual(inspected['attempts_remaining'],12)
        with self.assertRaises(ValueError): self.b.handle(req | {'scope':'b'*64})
        self.req['scope']='b'*64
        with self.assertRaises(ValueError): self.repair(job)
        self.req['scope']='a'*64
        self.repo.head=B
        with self.assertRaisesRegex(ValueError,'branch changed'): self.repair(job)
        self.assertEqual(len(self.runs),1)

    def test_repair_rejects_bad_paths_deletion_and_overflow(self):
        job=self.b.handle(self.repo_req)
        for change in ({'changes':{'../escape':'x'}}, {'changes':{'bad':'x'*131073}},
                       {'delete':['missing']}, {'delete':['lib/main.py']},
                       {'changes':{},'delete':['t/test.py','t/test.py']},
                       {'changes':{'bad':'\x00'}}, {'argv':['/usr/bin/curl']}):
            with self.assertRaises(ValueError): self.repair(job,**change)
        fixed=self.repair(job,changes={},delete=['lib/main.py'])
        self.assertEqual(self.runs[-1]['files'],{'t/test.py':'assert 42==42'})
        self.assertEqual(fixed['state'],'passed')

    def test_repair_shares_thirteen_attempt_quota_with_diagnostics(self):
        job=self.b.handle(self.repo_req)
        for i in range(11): self.b.handle(self.req | {'title':str(i)})
        fixed=self.repair(job)
        self.assertEqual(fixed['attempts_remaining'],0)
        # Idempotence still works at quota; new jobs cannot bypass it.
        self.assertEqual(self.repair(job)['id'],fixed['id'])
        with self.assertRaisesRegex(ValueError,'13 sandbox attempts'): self.repair(job,title='fourteenth')
        self.repo_publish(fixed)
        with self.assertRaises(ValueError): self.repair(fixed,title='after publication')

    def test_diagnostics_keep_exact_source_and_can_never_publish(self):
        self.b.execute=lambda job: {'reason':'exited','exit_code':1,'output':'failure'}
        original=self.b.handle(self.repo_req)
        self.b.execute=lambda job: self.runs.append(job) or {'reason':'exited','exit_code':0,'output':'diagnostic'}
        request=self.request('repo_diagnose') | dict(
            action='repo_diagnose',id=original['id'],argv=['/usr/bin/perl','-e','print 42'],title='diagnostic')
        diagnostic=self.b.handle(request)
        self.assertEqual(self.runs[-1]['files'],self.repo_req['changes'])
        self.assertEqual(diagnostic['attempts_remaining'],11)
        self.assertEqual(diagnostic['state'],'passed')
        with self.assertRaisesRegex(ValueError,'diagnostic jobs cannot be published'): self.repo_publish(diagnostic)
        with self.assertRaisesRegex(ValueError,'original repository test job'): self.repair(diagnostic)
        from broker import Broker
        second=Broker(self.tmp.name,self.token);self.addCleanup(second.db.close)
        with self.assertRaisesRegex(ValueError,'diagnostic jobs cannot be published'):
            second._handle(second.capability_envelope('repo_publish',self.req['scope'],self.req['channel'],self.req['network']) | dict(action='repo_publish',id=diagnostic['id']), _confirmed_publication=True)
        with self.assertRaises(ValueError): self.b.handle(request | {'scope':'b'*64})
        self.assertFalse(any(p is not None for _,p,_ in self.repo.calls))
