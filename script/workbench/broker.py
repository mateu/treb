#!/usr/bin/python3
"""Narrow local IPC: run immutable text inputs; publish only successful bundles."""
import hashlib
import hmac
import json
import os
from pathlib import Path
import re
import socketserver
import sqlite3
import time
import urllib.error
import urllib.request
import uuid

from runner import run, validate, MAX_JSON_BYTES, MAX_INPUT_BYTES, MAX_GIST_INPUT_BYTES, InputSizeError
from repository import Repository, validate_destination, validate_files
from verification import Verification
from references import References

BASE = Path.home() / '.local/share/burt-workbench'
TOKEN = Path.home() / '.config/burt-publisher/gist.token'
MAX_REQUEST = MAX_JSON_BYTES
MAX_ATTEMPTS = 5

# Operator-only audit: fixed strings, never arbitrary exception/source text.
AUDIT_LIMIT = 512
AUDIT_TTL = 7 * 86400
ACTIONS = frozenset(('run', 'publish', 'repo_read', 'repo_run', 'repo_publish',
                     'repo_inspect', 'repo_repair', 'repo_diagnose', 'reference', 'task_status'))
ACTION_CAPABILITY = {
    'reference': 'read_status', 'repo_read': 'read_status', 'repo_inspect': 'read_status',
    'run': 'edit_test', 'repo_run': 'edit_test', 'repo_repair': 'edit_test',
    'repo_diagnose': 'edit_test', 'task_status': 'edit_test',
    'publish': 'publish_gist', 'repo_publish': 'publish_repo',
}
SAFE_REASONS = frozenset({
    'Burt gist credential is not installed; ask the operator',
    'branch changed; read project and retest against the new base',
    'branch changed; read project and retest before publishing',
    'delete only existing files, without also replacing them',
    'diagnostic jobs cannot be published; rerun the complete project suite',
    'encoded project response exceeds transport bound',
    'expected public writable burt-agent/workspace',
    'file/directory collision',
    'files must contain 1..32 text files',
    'gist credential is not owned by burt-agent',
    'gist credential must have mode 600',
    'gist submission failed or response was lost; operator reconciliation required; do not retry',
    'global limit: 10 gist submissions per day',
    'global limit: 10 submissions per day',
    'global limit: 30 sandbox runs per hour',
    'input files exceed 64 KiB',
    'invalid action or fields',
    'invalid base commit',
    'invalid branch head',
    'invalid command; use absolute python3, perl, or sh',
    'invalid commit tree',
    'invalid created commit',
    'invalid created tree',
    'invalid job id',
    'invalid project slug',
    'invalid task status',
    'invalid text file',
    'invalid title',
    'invalid turn scope',
    'invalid verification policy',
    'job JSON exceeds 2 MiB',
    'job not found in this request',
    'job publication destination does not match tool',
    'job requires exactly files and argv',
    'last execution reserved for trusted project verification',
    'limit: 5 sandbox attempts per IRC request',
    'limit: one gist submission per IRC request',
    'limit: one submission per IRC request',
    'object required',
    'only a successful, recent, unsubmitted job can be published',
    'only an unsubmitted completed job can be repaired',
    'operator verification policy required for this project',
    'oversized or unterminated request',
    'project contains unsupported or oversized files',
    'project directory is not a tree',
    'project exceeds 64 KiB',
    'project requires 1..32 text files',
    'reference URL changed',
    'reference deadline exceeded',
    'repair requires file replacements and an explicit deletion list',
    'repository credential must belong to burt-agent',
    'repository credential requires private directory and mode 600',
    'repository job not found in this request',
    'repository operation deadline exceeded',
    'repository response exceeds bound',
    'repository submission failed or response lost; operator reconciliation required; do not retry',
    'repository tree exceeds bound',
    'task channel mismatch',
    'trusted verification receipt missing or stale; retest',
    'unexpected gist owner or URL',
    'unexpected updated ref',
    'unsupported blob encoding',
    'use a burt/<lowercase-slug> branch; main is never writable',
    'use flat ASCII filenames and text without NUL',
    'use safe relative text paths; no hidden files, traversal or NUL',
    'use the original repository test job, not a diagnostic',
    'verification baseline changed; operator review required',
    'verification policy must not be symlink/group/world writable',
    'verification runtime changed; restart/review required',
    'workbench is restricted to irc.perl.org #ai or #mateu-test',
})


class Broker:
    def __init__(self, base=BASE, token=TOKEN, execute=run, verification=None, verify_execute=None):
        self.base, self.token, self.execute = Path(base), Path(token), execute
        self.base.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.db = sqlite3.connect(self.base / 'jobs.sqlite')
        self.db.row_factory = sqlite3.Row
        self.db.execute('''CREATE TABLE IF NOT EXISTS jobs
            (id TEXT PRIMARY KEY, scope TEXT, digest TEXT, created REAL,
             files TEXT, title TEXT, result TEXT, state TEXT, url TEXT,
             UNIQUE(scope,digest))''')
        self.db.execute('CREATE TABLE IF NOT EXISTS repo_jobs (id TEXT PRIMARY KEY, destination TEXT NOT NULL)')
        self.db.execute('''CREATE TABLE IF NOT EXISTS rejections
            (seq INTEGER PRIMARY KEY, created REAL, scope TEXT, channel TEXT,
             network TEXT, action TEXT, request_sha256 TEXT, reason TEXT, error_kind TEXT)''')
        self.db.execute('''CREATE TABLE IF NOT EXISTS task_status
            (scope TEXT PRIMARY KEY, channel TEXT, network TEXT, created REAL,
             updated REAL, phase TEXT, reason TEXT)''')
        (self.base / 'jobs.sqlite').chmod(0o600)
        self.prune_audit()
        self.db.commit()
        self.repository = Repository()
        self.verification = verification
        self.verify_execute = verify_execute or (lambda job, checks: run(job, checks=checks))
        self.references = References()

    def prune_audit(self):
        now = time.time()
        self.db.execute('DELETE FROM rejections WHERE created<?', (now - AUDIT_TTL,))
        self.db.execute('DELETE FROM rejections WHERE seq NOT IN '
                        '(SELECT seq FROM rejections ORDER BY seq DESC LIMIT ?)', (AUDIT_LIMIT,))
        self.db.execute('DELETE FROM task_status WHERE updated<?', (now - AUDIT_TTL,))
        self.db.execute('DELETE FROM task_status WHERE scope NOT IN '
                        '(SELECT scope FROM task_status ORDER BY updated DESC LIMIT ?)', (AUDIT_LIMIT,))

    def record_rejection(self, req, exc, raw=None):
        # Scope/channel/action come only from the trusted runtime IPC envelope.
        # Invalid/malformed envelopes have NULL metadata, not attacker text.
        original = req
        req = req if isinstance(req, dict) else {}
        scope = req.get('scope')
        scope = scope if isinstance(scope, str) and re.fullmatch('[a-f0-9]{64}', scope) else None
        channel = req.get('channel') if req.get('channel') in ('#ai', '#mateu-test') else None
        network = 'irc.perl.org' if req.get('network') == 'irc.perl.org' else None
        action = req.get('action')
        action = action if isinstance(action, str) and action in ACTIONS else None
        digest = hashlib.sha256(raw if raw is not None else
            json.dumps(original, sort_keys=True, ensure_ascii=True).encode()).hexdigest()
        message = str(exc)
        reason = message if message in SAFE_REASONS or isinstance(exc, InputSizeError) else 'unclassified broker error'
        for prefix in ('baseline files cannot be deleted: ', 'protected baseline file changed: ',
                       'new files restricted to approved regression directories: ', 'unknown reference; available: '):
            if message.startswith(prefix):
                reason = prefix.rstrip(': ')
        kind = ('validation' if isinstance(exc, ValueError) else
                'type' if isinstance(exc, TypeError) else
                'missing_field' if isinstance(exc, KeyError) else
                'transport' if isinstance(exc, (TimeoutError, OSError)) else 'internal')
        self.db.execute('INSERT INTO rejections VALUES (NULL,?,?,?,?,?,?,?,?)',
                        (time.time(), scope, channel, network, action, digest, reason, kind))
        self.prune_audit()
        self.db.commit()

    @staticmethod
    def capability_envelope(action, scope, channel, network):
        capability = ACTION_CAPABILITY[action]
        grant = hashlib.sha256(json.dumps(
            [scope, channel, network, capability], separators=(',', ':'), ensure_ascii=True).encode()).hexdigest()
        return {'scope': scope, 'capability': capability, 'grant': grant,
                'channel': channel, 'network': network}

    def handle(self, req, _diagnostic=False):
        try:
            return self._handle(req, _diagnostic=_diagnostic)
        except Exception as exc:
            self.record_rejection(req, exc)
            raise

    def _handle(self, req, _diagnostic=False):
        if not isinstance(req, dict):
            raise ValueError('object required')
        action = req.get('action')
        allowed = {'action', 'scope', 'capability', 'grant', 'channel', 'network'}
        fields = {'run': {'files','argv','title'}, 'publish': {'id'},
                  'repo_read': {'branch','project'},
                  'repo_run': {'files','argv','title','branch','project','base_sha'},
                  'repo_publish': {'id'}, 'repo_inspect': {'id'},
                  'repo_repair': {'id','changes','delete','argv','title'},
                  'repo_diagnose': {'id','argv','title'}}
        fields['reference'] = {'key'}
        fields['task_status'] = {'phase', 'reason'}
        allowed |= fields.get(action, set())
        if set(req) != allowed or action not in fields:
            raise ValueError('invalid action or fields')
        if req['channel'] not in ('#ai', '#mateu-test') or req['network'] != 'irc.perl.org':
            raise ValueError('workbench is restricted to irc.perl.org #ai or #mateu-test')
        scope = req['scope']
        if not isinstance(scope, str) or not re.fullmatch(r'[a-f0-9]{64}', scope):
            raise ValueError('invalid turn scope')
        capability = req['capability']
        expected_capability = ACTION_CAPABILITY[action]
        expected_grant = self.capability_envelope(
            action, scope, req['channel'], req['network'])['grant']
        if (capability != expected_capability or not isinstance(req['grant'], str)
                or not hmac.compare_digest(req['grant'], expected_grant)):
            raise ValueError('invalid capability grant')
        if action == 'task_status':
            if (req['phase'] not in ('started', 'stopped', 'reported') or req['reason'] not in
                    ('admitted', 'deadline', 'iteration_limit', 'runtime_error', 'no_report',
                     'final_report', 'execution_limit')):
                raise ValueError('invalid task status')
            old = self.db.execute('SELECT channel FROM task_status WHERE scope=?', (scope,)).fetchone()
            if old and old['channel'] != req['channel']:
                raise ValueError('task channel mismatch')
            now = time.time()
            self.db.execute('INSERT INTO task_status VALUES (?,?,?,?,?,?,?) '
                            'ON CONFLICT(scope) DO UPDATE SET updated=excluded.updated, '
                            'phase=excluded.phase,reason=excluded.reason',
                            (scope, req['channel'], req['network'], now, now, req['phase'], req['reason']))
            self.prune_audit()
            self.db.commit()
            # No audit/read tool is exposed to the model. Return only actual job metadata.
            return {'jobs': [dict(row) for row in self.db.execute(
                'SELECT id,state FROM jobs WHERE scope=? ORDER BY created,id', (scope,))]}
        if action == 'reference':
            return self.references.read(req['key'])
        if action in ('repo_inspect', 'repo_repair', 'repo_diagnose'):
            job_id = req['id']
            if not isinstance(job_id, str) or not re.fullmatch(r'[a-f0-9]{32}', job_id):
                raise ValueError('invalid job id')
            job = self.db.execute('SELECT * FROM jobs WHERE id=? AND scope=?', (job_id, scope)).fetchone()
            dest = self.db.execute('SELECT destination FROM repo_jobs WHERE id=?', (job_id,)).fetchone()
            if not job or not dest:
                raise ValueError('repository job not found in this request')
            destination = json.loads(dest['destination'])
            if action == 'repo_inspect':
                return self.result(job) | {'files': json.loads(job['files']), 'destination': destination}
            if job['state'] not in ('passed', 'failed'):
                raise ValueError('only an unsubmitted completed job can be repaired')
            if destination.get('diagnostic_only'):
                raise ValueError('use the original repository test job, not a diagnostic')
            if action == 'repo_diagnose':
                # Same exact source, different diagnostic argv. This job can NEVER
                # publish, even if its command exits zero.
                return Broker._handle(self, self.capability_envelope('repo_run', req['scope'], req['channel'], req['network'])
                                     | {k: req[k] for k in ('argv','title')}
                                     | {'action':'repo_run', 'files':json.loads(job['files']),
                                        **{k: destination[k] for k in ('branch','project','base_sha')}},
                                     _diagnostic=True)
            changes, deleted = req['changes'], req['delete']
            if (not isinstance(changes, dict) or not isinstance(deleted, list)
                    or any(not isinstance(n, str) for n in deleted)
                    or len(deleted) != len(set(deleted))):
                raise ValueError('repair requires file replacements and an explicit deletion list')
            files = json.loads(job['files'])
            if any(n not in files or n in changes for n in deleted):
                raise ValueError('delete only existing files, without also replacing them')
            files.update(changes)
            for name in deleted:
                del files[name]
            # Re-enter the ordinary run path: same destination/base, full validation,
            # quota, fresh base check and new immutable job. No publication here.
            return self._handle(self.capability_envelope('repo_run', req['scope'], req['channel'], req['network'])
                               | {k: req[k] for k in ('argv','title')}
                               | {'action': 'repo_run', 'files': files,
                                  **{k: destination[k] for k in ('branch','project','base_sha')}})
        destination = None
        policy = None
        if action == 'repo_read':
            validate_destination(req['branch'], req['project'])
            return self.repository.snapshot(req['branch'], req['project'])
        if action == 'repo_run':
            validate_destination(req['branch'], req['project'], req['base_sha'])
            snapshot = self.repository.snapshot(req['branch'], req['project'])
            if snapshot['base_sha'] != req['base_sha']:
                raise ValueError('branch changed; read project and retest against the new base')
            destination = {k: snapshot[k] for k in ('branch','project','base_sha','exists')}
            if self.verification is not None:
                policy = self.verification.policy(snapshot)
                destination['verification_policy'] = self.verification.identity(policy)
            if _diagnostic:
                destination['diagnostic_only'] = True
        if action in ('run', 'repo_run'):
            files, argv = validate({'files': req['files'], 'argv': req['argv']},
                                   max_input_bytes=MAX_INPUT_BYTES if action == 'repo_run' else MAX_GIST_INPUT_BYTES)
            # Gists use flat filenames. No extraction, generated paths, symlinks,
            # stdout-as-files, or host file reads are part of publishing.
            if action == 'repo_run':
                validate_files(files)
                if policy is not None and not _diagnostic:
                    self.verification.prepare(snapshot, files)
            elif any(not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,99}', n)
                   or '\x00' in v for n, v in files.items()):
                raise ValueError('use flat ASCII filenames and text without NUL')
            title = req['title']
            if not isinstance(title, str) or not 1 <= len(title) <= 200 or any(ord(c) < 32 for c in title):
                raise ValueError('invalid title')
            digest = hashlib.sha256(json.dumps([files, argv, title, destination], sort_keys=True).encode()).hexdigest()
            old = self.db.execute('SELECT * FROM jobs WHERE scope=? AND digest=?', (scope, digest)).fetchone()
            if old:
                return self.result(old)
            if (_diagnostic and self.verification is not None and self.db.execute(
                    'SELECT COUNT(*) FROM jobs WHERE scope=?', (scope,)).fetchone()[0] >= MAX_ATTEMPTS - 1):
                raise ValueError('last execution reserved for trusted project verification')
            now = time.time()
            # Retain a bounded journal; ambiguous submissions remain for manual reconciliation.
            self.db.execute("DELETE FROM jobs WHERE created<? AND state NOT IN ('publishing','uncertain')", (now - 7*86400,))
            count = self.db.execute('SELECT COUNT(*) FROM jobs WHERE created>?', (now - 3600,)).fetchone()[0]
            if count >= 30:
                raise ValueError('global limit: 30 sandbox runs per hour')
            if self.db.execute('SELECT COUNT(*) FROM jobs WHERE scope=?', (scope,)).fetchone()[0] >= MAX_ATTEMPTS:
                raise ValueError('limit: 5 sandbox attempts per IRC request')
            job_id = uuid.uuid4().hex
            self.db.execute('INSERT INTO jobs VALUES (?,?,?,?,?,?,?,?,?)',
                            (job_id, scope, digest, now, json.dumps(files), title, '{}', 'running', None))
            if destination:
                self.db.execute('INSERT INTO repo_jobs VALUES (?,?)', (job_id, json.dumps(destination)))
            self.db.execute('DELETE FROM repo_jobs WHERE id NOT IN (SELECT id FROM jobs)')
            self.db.commit()
            try:
                if policy is not None and not _diagnostic:
                    result = self.verify_execute({'files': files, 'argv': policy['argv']}, policy['checks'])
                    result['requested_argv'] = argv
                    result['verification'] = {'policy_sha256': self.verification.identity(policy),
                                              'argv': policy['argv'], 'kind': 'trusted_checks'}
                else:
                    result = self.execute({'files': files, 'argv': argv})
            except Exception:
                result = {'reason': 'runner_error', 'exit_code': None, 'output': ''}
            result['argv'] = policy['argv'] if policy is not None and not _diagnostic else argv
            if action == 'repo_run' and policy is None:
                result['verification'] = {'kind': 'command_only_unverified'}
            state = 'passed' if result.get('reason') == 'exited' and result.get('exit_code') == 0 else 'failed'
            if _diagnostic:
                result['verification'] = {'kind': 'diagnostic_only'}
            # Logs are data, not publisher instructions. Never publish logs implicitly.
            output = result.get('output', '')
            result['output_truncated'] = len(output) > 8192
            result['output'] = output if len(output) <= 8192 else output[:4096] + '\n[output excerpted]\n' + output[-4096:]
            self.db.execute('UPDATE jobs SET result=?,state=? WHERE id=?', (json.dumps(result), state, job_id))
            self.db.commit()
            return self.result(self.db.execute('SELECT * FROM jobs WHERE id=?', (job_id,)).fetchone())
        job_id = req['id']
        if not isinstance(job_id, str) or not re.fullmatch(r'[a-f0-9]{32}', job_id):
            raise ValueError('invalid job id')
        job = self.db.execute('SELECT * FROM jobs WHERE id=? AND scope=?', (job_id, scope)).fetchone()
        if not job:
            raise ValueError('job not found in this request')
        repo_job = self.db.execute('SELECT destination FROM repo_jobs WHERE id=?', (job_id,)).fetchone()
        if bool(repo_job) != (action == 'repo_publish'):
            raise ValueError('job publication destination does not match tool')
        if job['state'] == 'published':
            return self.result(job)
        if job['state'] != 'passed' or job['created'] < time.time() - 900:
            raise ValueError('only a successful, recent, unsubmitted job can be published')
        if repo_job:
            destination = json.loads(repo_job['destination'])
            if destination.get('diagnostic_only'):
                raise ValueError('diagnostic jobs cannot be published; rerun the complete project suite')
            return self.publish_repository(job, destination)
        if not self.token.is_file():
            raise ValueError('Burt gist credential is not installed; ask the operator')
        if self.token.stat().st_mode & 0o077:
            raise ValueError('gist credential must have mode 600')
        # Check rate budget before crossing the irreversible network boundary.
        n = self.db.execute("SELECT COUNT(*) FROM jobs WHERE created>? AND state IN ('published','publishing','uncertain')", (time.time()-86400,)).fetchone()[0]
        if n >= 10:
            raise ValueError('global limit: 10 gist submissions per day')
        if self.db.execute("SELECT COUNT(*) FROM jobs WHERE scope=? AND state IN ('published','publishing','uncertain')", (scope,)).fetchone()[0]:
            raise ValueError('limit: one gist submission per IRC request')
        self.db.execute("UPDATE jobs SET state='publishing' WHERE id=?", (job_id,))
        self.db.commit()
        payload = {'description': job['title'], 'public': True,
                   'files': {n: {'content': c} for n, c in json.loads(job['files']).items()}}
        try:
            url = self.post_gist(payload)
        except Exception:
            # A lost response may mean GitHub created the gist. Never blindly retry.
            self.db.execute("UPDATE jobs SET state='uncertain' WHERE id=?", (job_id,))
            self.db.commit()
            raise ValueError('gist submission failed or response was lost; operator reconciliation required; do not retry') from None
        self.db.execute("UPDATE jobs SET state='published',url=? WHERE id=?", (url, job_id))
        self.db.commit()
        return self.result(self.db.execute('SELECT * FROM jobs WHERE id=?', (job_id,)).fetchone())

    def publish_repository(self, job, destination):
        # Read/preflight before marking submitted; no writes on stale bases.
        snapshot = self.repository.snapshot(destination['branch'], destination['project'])
        if self.verification is not None:
            policy = self.verification.prepare(snapshot, json.loads(job['files']))
            receipt = json.loads(job['result']).get('verification', {})
            if (destination.get('verification_policy') != self.verification.identity(policy)
                    or receipt.get('policy_sha256') != self.verification.identity(policy)
                    or receipt.get('kind') != 'trusted_checks'):
                raise ValueError('trusted verification receipt missing or stale; retest')
        if any(snapshot[k] != destination[k] for k in ('base_sha','exists')):
            raise ValueError('branch changed; read project and retest before publishing')
        n = self.db.execute("SELECT COUNT(*) FROM jobs WHERE created>? AND state IN ('published','publishing','uncertain')", (time.time()-86400,)).fetchone()[0]
        if n >= 10:
            raise ValueError('global limit: 10 submissions per day')
        if self.db.execute("SELECT COUNT(*) FROM jobs WHERE scope=? AND state IN ('published','publishing','uncertain')", (job['scope'],)).fetchone()[0]:
            raise ValueError('limit: one submission per IRC request')
        self.db.execute("UPDATE jobs SET state='publishing' WHERE id=?", (job['id'],))
        self.db.commit()
        try:
            url = self.repository.publish(snapshot, json.loads(job['files']), job['title'])
        except Exception:
            self.db.execute("UPDATE jobs SET state='uncertain' WHERE id=?", (job['id'],))
            self.db.commit()
            raise ValueError('repository submission failed or response lost; operator reconciliation required; do not retry') from None
        self.db.execute("UPDATE jobs SET state='published',url=? WHERE id=?", (url, job['id']))
        self.db.commit()
        return self.result(self.db.execute('SELECT * FROM jobs WHERE id=?', (job['id'],)).fetchone())

    def post_gist(self, payload):
        # No caller-supplied URL, credential, proxy, redirect or GitHub identity.
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
        headers = {'Authorization': 'Bearer ' + self.token.read_text().strip(),
                   'Accept': 'application/vnd.github+json', 'User-Agent': 'burt-workbench',
                   'Content-Type': 'application/json'}
        with opener.open(urllib.request.Request('https://api.github.com/user', headers=headers), timeout=10) as response:
            identity = json.loads(response.read(100000))
        if identity.get('login') != 'burt-agent':
            raise ValueError('gist credential is not owned by burt-agent')
        request = urllib.request.Request('https://api.github.com/gists',
                                         data=json.dumps(payload).encode(), headers=headers)
        with opener.open(request, timeout=15) as response:
            data = json.loads(response.read(300000))
        url = data.get('html_url', '')
        if data.get('owner', {}).get('login') != 'burt-agent' or not re.fullmatch(r'https://gist.github.com/burt-agent/[a-f0-9]+', url):
            raise ValueError('unexpected gist owner or URL')
        return url

    def result(self, job):
        return {'id': job['id'], 'state': job['state'], 'result': json.loads(job['result']),
                'url': job['url'], 'files': list(json.loads(job['files'])),
                'attempts_remaining': max(0, MAX_ATTEMPTS - self.db.execute(
                    'SELECT COUNT(*) FROM jobs WHERE scope=?', (job['scope'],)).fetchone()[0])}


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


class Handler(socketserver.StreamRequestHandler):
    def handle(self):
        self.request.settimeout(5)
        raw, req, dispatched = b'', None, False
        try:
            raw = self.rfile.readline(MAX_REQUEST + 1)
            if len(raw) > MAX_REQUEST or not raw.endswith(b'\n'):
                raise ValueError('oversized or unterminated request')
            req = json.loads(raw)
            dispatched = True
            result = self.server.broker.handle(req)
        except (ValueError, TypeError, KeyError) as exc:
            if not dispatched:
                self.server.broker.record_rejection(req, exc, raw=raw)
            result = {'error': str(exc)[:300]}
        except Exception as exc:
            if not dispatched:
                self.server.broker.record_rejection(req, exc, raw=raw)
            result = {'error': 'broker unavailable; operator inspection required'}
        try:
            self.wfile.write(json.dumps(result).encode() + b'\n')
        except (BrokenPipeError, TimeoutError):
            pass


def main():
    os.umask(0o077)
    BASE.mkdir(parents=True, exist_ok=True)
    ipc = BASE / 'ipc'
    ipc.mkdir(mode=0o700, exist_ok=True)
    path = ipc / 'broker.sock'
    if path.exists():
        path.unlink()
    # Serialized, bounded jobs: at most one execution or publication at a time.
    with socketserver.UnixStreamServer(str(path), Handler) as server:
        policy_path = os.environ.get('BURT_VERIFICATION_POLICY')
        server.broker = Broker(verification=Verification.load(policy_path) if policy_path else None)
        os.chmod(path, 0o600)
        server.serve_forever()


if __name__ == '__main__':
    main()
