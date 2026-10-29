#!/usr/bin/env python3
"""Private, no-publishing Burt experiment. Execute on clawd, never live state.

Tasks expose only task.json to the model. Trusted evaluate.py stays host-side;
any hidden generated-code tests it requests run through runner.run, not Python
on the operator host. See note/BURT_RELIABILITY_EXPERIMENT.md.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import random
import re
import signal
import socketserver
import subprocess
import sys
import threading
import time

from broker import Broker, Handler
from repository import validate_destination, validate_files
from runner import run, validate


COMPARISON_ARMS = ('current32k', 'current64k', 'refined32k', 'refined64k')
ARM_SETTINGS = {
    'current32k': dict(context_tokens=32768, workflow='current', notebook=False),
    'current64k': dict(context_tokens=65536, workflow='current', notebook=False),
    'refined32k': dict(context_tokens=32768, workflow='refined', notebook=False),
    'refined64k': dict(context_tokens=65536, workflow='refined', notebook=False),
    # Historical names retain their exact meaning; never relabel old artifacts.
    'baseline': dict(context_tokens=8192, workflow='current', notebook=False),
    'notebook': dict(context_tokens=8192, workflow='current', notebook=True),
    'notebook-stronger': dict(context_tokens=8192, workflow='current', notebook=True),
    'context32k': dict(context_tokens=32768, workflow='current', notebook=False),
}
REFINED_WORKFLOW = (
    'Use an evidence-driven repair cycle within the unchanged execution budget. '
    'First reproduce the observed failure on the original complete project. '
    'Before patching, state a falsifiable cause and run a discriminating check that '
    'could reject it; inspect the actual failure output, not just the exit status. '
    'Make the smallest supported patch, preserve original assertions and project files, '
    'and inspect any remaining failures before revising the hypothesis. '
    'Reserve at least one of the five sandbox executions for the final complete-suite '
    'command on the final project bundle. Do not substitute a passing diagnostic or '
    'narrow test for final full-suite verification. Report unresolved blockers honestly.'
)
LIMITS = dict(max_iterations=13, max_executions=5, deadline_seconds=1800,
              sandbox_seconds=20, sandbox_output_bytes=65536,
              model_output_tokens='unchanged provider default; no request override',
              notebook_chars=4096)


def arm_settings(arm):
    try:
        return dict(ARM_SETTINGS[arm], workflow_prompt=REFINED_WORKFLOW
                    if ARM_SETTINGS[arm]['workflow'] == 'refined' else '')
    except KeyError:
        raise ValueError('unknown arm: ' + arm) from None






def source_identity(repo):
    tracked = subprocess.check_output(['git', '-C', str(repo), 'ls-files', '-z']).split(b'\0')
    hashes = {os.fsdecode(p): hashlib.sha256((repo / os.fsdecode(p)).read_bytes()).hexdigest()
              for p in tracked if p and (repo / os.fsdecode(p)).is_file()}
    return dict(revision=subprocess.check_output(['git', '-C', str(repo), 'rev-parse', 'HEAD'],
                                                text=True).strip(), hashes=hashes,
                tracked_dirty=bool(subprocess.check_output(
                    ['git', '-C', str(repo), 'status', '--porcelain', '--untracked-files=no'])))




def canonical(value):
    return json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(',', ':')).encode()


def digest(value):
    return hashlib.sha256(canonical(value)).hexdigest()


def write_json(path, value):
    Path(path).write_text(json.dumps(value, sort_keys=True, ensure_ascii=False, indent=2) + '\n')




def load_task(path):
    task = json.loads(Path(path).read_text())
    if not re.fullmatch('[a-z][a-z0-9-]{0,49}', task['id']):
        raise ValueError('invalid task id')
    if not isinstance(task['prompt'], str) or not task['prompt'].strip():
        raise ValueError('task prompt required')
    if any(k in task for k in ('operator_findings', 'solution', 'hidden_plan')):
        raise ValueError('solution/hidden evaluation must not enter task.json')
    validate({'files': task['files'], 'argv': task['argv']})
    validate_files(task['files'])
    task.setdefault('branch', 'burt/' + task['id'])
    task.setdefault('project', task['id'])
    validate_destination(task['branch'], task['project'])
    return task


class Snapshot:
    def __init__(self, task):
        self.task = task
        self.base_sha = digest(task['files'])[:40]

    def snapshot(self, branch, project):
        if (branch, project) != (self.task['branch'], self.task['project']):
            raise ValueError('experiment task destination is fixed')
        return dict(branch=branch, project=project, base_sha=self.base_sha, tree_sha=self.base_sha,
                    exists=True, files=self.task['files'].copy())

    def publish(self, *_):
        raise ValueError('experiment NEVER publishes')


class ExperimentBroker(Broker):
    def __init__(self, base, task, deadline, execute=run):
        super().__init__(base, token=Path(base) / 'NO_TOKEN', execute=execute)
        self.repository = Snapshot(task)
        self.deadline = deadline
        self.trace = Path(base) / 'broker-events.jsonl'

    def handle(self, req, **kwargs):
        started = time.time()
        result = None
        error = None
        try:
            if req.get('action') in ('publish', 'repo_publish'):
                raise ValueError('experiment NEVER publishes')
            if started >= self.deadline:
                raise ValueError('fixed experiment deadline reached')
            result = super().handle(req, **kwargs)
            return result
        except Exception as exc:
            error = str(exc)
            raise
        finally:
            with self.trace.open('a') as trace:
                trace.write(json.dumps(dict(started=started, elapsed=time.time()-started,
                                            request=req, result=result, error=error,
                                            internal_diagnostic=kwargs.get('_diagnostic', False))) + '\n')


def namespace_command(repo, state, ipc, config, env_file, perl_root):
    # Same model network and Perl dependency mounts as run-burt-isolated.sh;
    # no live DB, publisher credential, hidden evaluator, host home or IRC client.
    args = ['/usr/bin/bwrap', '--unshare-user', '--unshare-pid', '--unshare-ipc',
            '--unshare-uts', '--unshare-cgroup', '--die-with-parent', '--new-session',
            '--cap-drop', 'ALL', '--ro-bind', '/usr', '/usr', '--symlink', 'usr/bin', '/bin',
            '--symlink', 'usr/lib', '/lib', '--symlink', 'usr/lib64', '/lib64',
            '--proc', '/proc', '--dev', '/dev']
    for p in ('/etc/resolv.conf', '/etc/hosts', '/etc/nsswitch.conf', '/etc/ssl/certs', '/etc/localtime'):
        args += ['--ro-bind', p, p]
    for source, target in ((perl_root, '/perl5'), (repo / 'lib', '/app/lib'),
                           (repo / 'burt.pl', '/app/burt.pl'),
                           (repo / 'base.persona.txt', '/app/base.persona.txt'),
                           (repo / 'burt.persona.txt', '/app/burt.persona.txt'),
                           (repo / 'burt.mission.txt', '/app/burt.mission.txt'),
                           (env_file, '/app/burt.env'),
                           (repo / 'script/workbench/reliability-trial.pl', '/trial.pl'),
                           (repo / 'script/workbench/ExperimentPlugin.pm', '/ExperimentPlugin.pm'),
                           (config, '/trial.json'), (ipc, '/broker')):
        args += ['--ro-bind', str(source), target]
    args += ['--bind', str(state), '/state', '--size', '33554432', '--tmpfs', '/tmp',
             '--chdir', '/app', '--remount-ro', '/', '--clearenv',
             '--setenv', 'PATH', '/usr/bin:/bin', '--setenv', 'HOME', '/tmp',
             '--setenv', 'USER', 'burt', '--setenv', 'LANG', 'C.UTF-8',
             '/bin/bash', '--noprofile', '--norc', '-c',
             'set -euo pipefail\n'
             'eval "$(perl -I/perl5/lib/perl5 -Mlocal::lib=/perl5)"\n'
             'set -a\nsource /app/burt.env\nset +a\n'
             'export DB_FILE=/state/unused.sqlite BURT_WORKBENCH_SOCKET=/broker/broker.sock\n'
             'exec /usr/bin/perl -I/app/lib -I/ /trial.pl']
    return args


def final_bundle(broker, pending):
    # Latest full-project job, NEVER a diagnostic or an earlier lucky pass.
    # The fresh broker journal is authoritative even when the model times out
    # before final metadata is written, or pending references an earlier job.
    rows = broker.db.execute('SELECT j.*, r.destination FROM jobs j JOIN repo_jobs r USING(id) '
                             'ORDER BY j.created DESC, j.rowid DESC')
    for row in rows:
        destination = json.loads(row['destination'])
        if not destination.get('diagnostic_only'):
            return dict(id=row['id'], files=json.loads(row['files']), result=json.loads(row['result']),
                        state=row['state'], destination=destination)
    return None








def usage_summary(state):
    """Preserve provider-native usage fields; do not fabricate normalized costs."""
    responses = []
    events = state / 'events.jsonl'
    if not events.exists():
        return responses
    for line in events.read_text().splitlines():
        item = json.loads(line)
        if item['event'] != 'model_response':
            continue
        response = item.get('response', {})
        if not isinstance(response, dict):
            continue
        native = {k:response[k] for k in ('usage','prompt_eval_count','eval_count','total_duration',
                                        'load_duration','prompt_eval_duration','eval_duration') if k in response}
        responses.append(dict(iteration=item['iteration'], provider_native=native))
    return responses


def run_trial(task_path, arm, model, output, repo, env_file, perl_root, trial_identity=None,
              experiment_manifest_sha256=None, expected_effective_route=None):
    task = load_task(task_path)
    output.mkdir(parents=True, mode=0o700, exist_ok=False)
    state = output / 'model-state'
    state.mkdir(mode=0o700)
    ipc = output / 'ipc'
    ipc.mkdir(mode=0o700)
    started = time.time()
    deadline = started + LIMITS['deadline_seconds']
    config = dict(task=task, arm=arm, model=model, **arm_settings(arm), deadline=deadline,
                  **LIMITS, trial_identity=trial_identity or {},
                  expected_effective_route=expected_effective_route)
    write_json(output / 'trial.json', config)
    manifest = dict(config=config, task_sha256=digest(task), source=source_identity(repo),
        experiment_manifest_sha256=experiment_manifest_sha256,
        environment_sha256=hashlib.sha256(env_file.read_bytes()).hexdigest(),
        provider_options='Inherited unchanged from private burt.env except MODEL; fallback explicitly disabled',
        publication=False, irc_connected=False, live_database_mounted=False,
        scope='offline seeded-repository repair, production mission + no-publish Workbench subset',
        usage_cost='Provider token usage recorded when exposed; monetary cost unavailable')
    write_json(output / 'manifest.json', manifest)
    b = ExperimentBroker(output, task, deadline)
    socket_path = ipc / 'broker.sock'
    # AF_UNIX path length is limited; require a short output root.
    if len(str(socket_path).encode()) >= 104:
        raise ValueError('output path too long for Unix socket; use short private /tmp root')
    with socketserver.UnixStreamServer(str(socket_path), Handler) as server:
        # sqlite connections are deliberately created/used in one broker thread.
        b.db.close()
        def serve():
            import sqlite3
            b.db = sqlite3.connect(output / 'jobs.sqlite')
            b.db.row_factory = sqlite3.Row
            server.broker = b
            server.serve_forever(poll_interval=0.1)
            b.db.close()
        thread = threading.Thread(target=serve, daemon=True)
        thread.start()
        command = namespace_command(repo, state, ipc, output/'trial.json', env_file, perl_root)
        write_json(output / 'launcher-argv.json', command)
        timed_out = False
        with (output/'stdout.log').open('w') as stdout, (output/'stderr.log').open('w') as stderr:
            process = subprocess.Popen(command, stdout=stdout, stderr=stderr, start_new_session=True)
            try:
                returncode = process.wait(timeout=max(1, deadline-time.time()))
            except subprocess.TimeoutExpired:
                timed_out = True
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    returncode = process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    returncode = process.wait()
        server.shutdown()
        thread.join()
    import sqlite3
    b.db = sqlite3.connect(output / 'jobs.sqlite')
    b.db.row_factory = sqlite3.Row
    try:
        metadata = json.loads((state/'final.json').read_text()) if (state/'final.json').exists() else {}
    except (ValueError, OSError) as exc:
        metadata = {'metadata_error': str(exc)}
    effective_route = json.loads((state/'effective-route.json').read_text()) if (state/'effective-route.json').exists() else None
    bundle = final_bundle(b, metadata.get('pending', {}))
    rows = [dict(row) for row in b.db.execute('SELECT id,state,result FROM jobs ORDER BY created')]
    b.db.close()
    write_json(output/'final-bundle.json', bundle)
    try:
        acceptance = evaluate(task_path.parent, output/'final-bundle.json', output,
                              final_response=metadata.get('terminal_response', '')) if bundle else {'status':'no_candidate'}
    except Exception as exc:
        acceptance = {'status':'evaluator_error','reason':str(exc)}
    write_json(output/'acceptance.json', acceptance)
    summary = dict(task=task['id'],arm=arm,model=model,returncode=returncode,timed_out=timed_out,
                   trial_identity=trial_identity or {}, arm_settings=arm_settings(arm), limits=LIMITS,
                   effective_route=effective_route,
                   experiment_manifest_sha256=experiment_manifest_sha256,
                   elapsed_seconds=time.time()-started,metadata=metadata,executions=len(rows),jobs=rows,
                   final_job=bundle['id'] if bundle else None, acceptance=acceptance,
                   score=score_candidate(task,bundle,acceptance),usage=usage_summary(state))
    write_json(output/'summary.json', summary)
    return summary




