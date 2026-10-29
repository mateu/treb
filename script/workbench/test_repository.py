import base64
import json
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

    def repo_publish(self, job):
        return self.b.handle(self.b.capability_envelope('repo_publish', self.req['scope'], self.req['channel'], self.req['network'])|{'action':'repo_publish','id':job['id']})

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
        result=second.handle(second.capability_envelope('repo_publish',self.req['scope'],self.req['channel'],self.req['network'])|{'action':'repo_publish','id':r['id']})
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
        self.assertEqual(inspected['attempts_remaining'],4)
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

    def test_repair_shares_five_attempt_quota_with_diagnostics(self):
        job=self.b.handle(self.repo_req)
        for i in range(3): self.b.handle(self.req | {'title':str(i)})
        fixed=self.repair(job)
        self.assertEqual(fixed['attempts_remaining'],0)
        # Idempotence still works at quota; new jobs cannot bypass it.
        self.assertEqual(self.repair(job)['id'],fixed['id'])
        with self.assertRaisesRegex(ValueError,'5 sandbox attempts'): self.repair(job,title='sixth')
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
        self.assertEqual(diagnostic['attempts_remaining'],3)
        self.assertEqual(diagnostic['state'],'passed')
        with self.assertRaisesRegex(ValueError,'diagnostic jobs cannot be published'): self.repo_publish(diagnostic)
        with self.assertRaisesRegex(ValueError,'original repository test job'): self.repair(diagnostic)
        from broker import Broker
        second=Broker(self.tmp.name,self.token);self.addCleanup(second.db.close)
        with self.assertRaisesRegex(ValueError,'diagnostic jobs cannot be published'):
            second.handle(second.capability_envelope('repo_publish',self.req['scope'],self.req['channel'],self.req['network']) | dict(action='repo_publish',id=diagnostic['id']))
        with self.assertRaises(ValueError): self.b.handle(request | {'scope':'b'*64})
        self.assertFalse(any(p is not None for _,p,_ in self.repo.calls))
