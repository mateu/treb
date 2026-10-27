#!/usr/bin/env python3
"""Frozen 32K gate comparison. Operator-only; no IRC/publishing/live-state writes."""
import argparse
import json
import os
from pathlib import Path
import random
import subprocess
import time

import trial_support as r
from experiment_tasks import tasks, solutions
from references import References, CATALOG
from verification import Verification
from runner import run

ARM = None
DOCS = {}
SPECS = {x['task']['id']: x for x in tasks()}
OriginalBroker = r.ExperimentBroker


def policy(spec):
    task = spec['task']
    return dict(base_sha=r.digest(task['files'])[:40], baseline=task['files'],
                editable=spec['editable'], additions=['tests/', 't/'],
                argv=['/usr/bin/python3', '-I', '/checks/verify.py'], checks=spec['checks'])


class TrialBroker(OriginalBroker):
    def __init__(self, base, task, deadline):
        super().__init__(base, task, deadline)
        if ARM == 'gated32k':
            self.verification = Verification({task['branch']+':'+task['project']: policy(SPECS[task['id']])})
        self.references.cache = json.loads(json.dumps(DOCS))
        # Scored calls never use mutable Internet data, even on cache miss.
        def reference(key):
            if key not in DOCS: raise ValueError('reference unavailable in frozen experiment')
            return DOCS[key]
        self.references.read = reference


def assess(task_dir, bundle_path, output_dir, **kwargs):
    spec = SPECS[task_dir.name]
    bundle = json.loads(bundle_path.read_text())
    files = bundle['files']
    preserve = all(files.get(n) == c for n, c in spec['task']['files'].items() if n not in spec['editable'])
    checks = spec['semantic']
    result = run({'files':files, 'argv':['/usr/bin/python3', '-I', '/checks/verify.py']}, checks=checks)
    r.write_json(output_dir/'independent-result.json', result)
    return dict(status='scored', semantic_passed=result['reason']=='exited' and result['exit_code']==0,
                preservation_passed=preserve, evaluator_sha256=r.digest(checks))


def score(task, bundle, acceptance):
    scored = (acceptance.get('status') == 'scored'
              and type(acceptance.get('semantic_passed')) is bool
              and type(acceptance.get('preservation_passed')) is bool)
    return dict(assessment_status=acceptance.get('status'), independently_scored=scored,
                semantic_accepted=acceptance['semantic_passed'] if scored else None,
                preservation_passed=acceptance['preservation_passed'] if scored else None,
                broker_reported_passed=bool(bundle and bundle['state']=='passed'),
                model_command_passed=(None if ARM=='gated32k' else bool(bundle and bundle['state']=='passed')),
                trusted_gate_passed=bool(bundle and bundle['state']=='passed' and
                    bundle['result'].get('verification',{}).get('kind')=='trusted_checks'))


def req(task, files, title='control'):
    return dict(action='repo_run', scope='a'*64, network='irc.perl.org', channel='#ai',
                branch=task['branch'], project=task['project'], base_sha=r.digest(task['files'])[:40],
                files=files, argv=['/bin/sh','-c','true'], title=title)


def preflight(repo, output, env_file, perl_root):
    global ARM
    report = []
    ARM = 'gated32k'
    for name, spec in SPECS.items():
        task = spec['task']
        directory = output/name
        directory.mkdir()
        b = TrialBroker(directory, task, time.time()+180)
        good = task['files'] | {spec['editable'][0]: solutions()[name]}
        for label, files, expected in [('original',task['files'],False), ('gold',good,True)]:
            job = b.handle(req(task,files,label))
            verdict = job['state']=='passed'
            bundle = dict(files=files, result=job['result'], state=job['state'])
            r.write_json(directory/(label+'.json'),bundle)
            scoredir = directory/label
            scoredir.mkdir()
            independent = assess(directory,directory/(label+'.json'),scoredir)
            report.append(dict(task=name,control=label,expected=expected,gate=verdict,
                               independent=independent['semantic_passed'],
                               matched=verdict is expected and independent['semantic_passed'] is expected))
        for label, files in [('weakened-tests',good|{'tests/test_cli.py':'pass'}),
                             ('deleted-readme',{n:c for n,c in good.items() if n!='README.md'}),
                             ('framework-shadow',good|{'unittest.py':'pass'})]:
            rejected = False
            try: b.handle(req(task,files,label))
            except ValueError: rejected=True
            report.append(dict(task=name,control=label,matched=rejected))
        b.db.close()
    probe = '''import os, socket
for p in ['/home/hunter', '/root', '/run/user', '/app/burt.env', '/input']:
    assert not os.path.exists(p), p
for p in ['/work/probe.py','/checks/verify.py']:
    try: open(p,'w').write('changed')
    except OSError: pass
    else: raise AssertionError('writable: '+p)
for host in ['1.1.1.1','127.0.0.1','192.168.1.52','169.254.169.254']:
    s=socket.socket(); s.settimeout(.25)
    try: s.connect((host,80))
    except OSError: pass
    else: raise AssertionError('network reachable: '+host)
    finally: s.close()
assert not any('TOKEN' in k or 'SECRET' in k or 'KEY' in k for k in os.environ)
print('namespace controls passed')
'''
    boundary = run({'files':{'probe.py':probe},'argv':['/usr/bin/python3','-I','/checks/verify.py']}, checks={'verify.py':probe})
    r.write_json(output/'boundary.json',boundary)
    report.append(dict(control='namespace-boundaries',matched=boundary['reason']=='exited' and boundary['exit_code']==0))
    for label, code, seconds, reason in [
        ('timeout', 'import time; time.sleep(30)', 2, None),
        ('output-limit', 'while True: print("x"*4096)', 5, 'output_limit')]:
        result = run({'files':{'probe.py':code},'argv':['/usr/bin/python3','-I','/work/probe.py']}, seconds=seconds)
        r.write_json(output/(label+'.json'),result)
        report.append(dict(control=label,matched=(result['reason']==reason if reason else result['exit_code']!=0)))
    # Exercise exact model-process setup with networking disabled; exit before raid.
    expected = None
    for arm in ['current32k','gated32k']:
        state=output/(arm+'-state'); state.mkdir()
        ipc=output/(arm+'-ipc'); ipc.mkdir()
        config=output/(arm+'.json')
        r.write_json(config,dict(task=next(iter(SPECS.values()))['task'],model='deepseek-v4.1-flash:1017-cloud',
            context_tokens=32768, notebook=False, deadline=time.time()+60, setup_only=True, **r.LIMITS))
        command=r.namespace_command(repo,state,ipc,config,env_file,perl_root)
        command.insert(1,'--unshare-net')
        result=subprocess.run(command,capture_output=True,text=True,timeout=60)
        (output/(arm+'-setup.stderr')).write_text(result.stderr)
        if result.returncode: raise ValueError('no-network model setup failed: '+result.stderr[-1000:])
        route=json.loads((state/'effective-route.json').read_text())
        common={k:v for k,v in route.items() if k!='context_tokens'}
        if expected is None: expected=common
        report.append(dict(control=arm+'-route',matched=common==expected and route['context_tokens']==32768 and route['fallback_models']==[]))
    r.write_json(output/'report.json',report)
    if not all(x['matched'] for x in report): raise ValueError('preflight controls failed')
    r.write_json(output/'preflight.json',dict(source=r.source_identity(repo),tasks_sha256=r.digest(SPECS),
        expected_common_route=expected,report_sha256=r.digest(report),all_matched=True))


def main():
    global ARM,DOCS
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action',choices=['prepare','preflight','run'])
    parser.add_argument('--root',type=Path,required=True)
    parser.add_argument('--env-file',type=Path,default=Path.home()/'.local/share/burt-irc/burt.env')
    parser.add_argument('--perl-root',type=Path,default=Path.home()/'perl5')
    args=parser.parse_args()
    os.umask(0o077)
    repo=Path(__file__).resolve().parents[2]
    root=args.root.resolve()
    if args.action=='prepare':
        root.mkdir(mode=0o700,parents=True,exist_ok=False)
        refs=References()
        docs={}
        for key in CATALOG:
            try: docs[key]=refs.read(key)
            except Exception as exc: docs[key]=dict(reference=key,unavailable=type(exc).__name__)
        r.write_json(root/'references.json',docs)
        for name,spec in SPECS.items():
            directory=root/'tasks'/name;directory.mkdir(parents=True)
            r.write_json(directory/'task.json',spec['task'])
        r.write_json(root/'tasks-freeze.json',dict(specs_sha256=r.digest(SPECS),references_sha256=r.digest(docs)))
        return
    DOCS=json.loads((root/'references.json').read_text())
    frozen=json.loads((root/'tasks-freeze.json').read_text())
    if frozen!=dict(specs_sha256=r.digest(SPECS),references_sha256=r.digest(DOCS)):
        raise ValueError('task/reference drift')
    if args.action=='preflight':
        out=root/'preflight';out.mkdir(exist_ok=False)
        preflight(repo,out,args.env_file,args.perl_root)
        return
    pre=json.loads((root/'preflight/preflight.json').read_text())
    source=r.source_identity(repo)
    if source['tracked_dirty'] or source!=pre['source'] or pre['tasks_sha256']!=r.digest(SPECS):
        raise ValueError('commit/source/task drift since reviewed preflight')
    report=json.loads((root/'preflight/report.json').read_text())
    if not pre['all_matched'] or r.digest(report)!=pre['report_sha256'] or not all(x['matched'] for x in report):
        raise ValueError('preflight evidence drift')
    schedule=[(n,repeat) for n in SPECS for repeat in [1,2]]
    rng=random.Random(20261027);rng.shuffle(schedule)
    plan=[]
    for name,repeat in schedule:
        arms=['current32k','gated32k'];rng.shuffle(arms)
        plan.extend(dict(task=name,repeat=repeat,arm=arm) for arm in arms)
    out=root/'trials';out.mkdir(exist_ok=False)
    manifest=dict(source=source,tasks_sha256=r.digest(SPECS),references_sha256=r.digest(DOCS),
        environment_sha256=r.digest(args.env_file.read_bytes().hex()),preflight=pre,schedule=plan,
        model='deepseek-v4.1-flash:1017-cloud',limits=r.LIMITS)
    r.write_json(root/'manifest.json',manifest)
    r.ExperimentBroker=TrialBroker;r.evaluate=assess;r.score_candidate=score
    r.ARM_SETTINGS['gated32k']=dict(context_tokens=32768,workflow='current',notebook=False)
    summaries=[]
    for i,item in enumerate(plan):
        ARM=item['arm']
        if r.source_identity(repo)!=source or r.digest(args.env_file.read_bytes().hex())!=manifest['environment_sha256']:
            raise ValueError('source/environment drift')
        if json.loads((root/'tasks'/item['task']/'task.json').read_text()) != SPECS[item['task']]['task']:
            raise ValueError('model-visible task drift')
        trial=r.run_trial(root/'tasks'/item['task']/'task.json',ARM,manifest['model'],out/('t%03d'%i),repo,
            args.env_file,args.perl_root,trial_identity=item,experiment_manifest_sha256=r.digest(manifest),
            expected_effective_route=pre['expected_common_route'])
        summaries.append(trial)
        r.write_json(root/'summary.json',summaries)
        print(json.dumps(dict(completed=len(summaries),total=len(plan),identity=item,score=trial['score'])),flush=True)
        if trial['acceptance'].get('status') == 'evaluator_error':
            raise ValueError('independent evaluator failed; retained unscored trial; comparison stopped')
    (root/'COMPLETE').write_text('12 scheduled trials finished; inspect scores and limitations\n')


if __name__=='__main__': main()
