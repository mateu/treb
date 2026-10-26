#!/usr/bin/python3
"""Narrow local IPC: run immutable text inputs; publish only successful bundles."""
import hashlib
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

from runner import run, validate
from repository import Repository, validate_destination, validate_files

BASE = Path.home() / '.local/share/burt-workbench'
TOKEN = Path.home() / '.config/burt-publisher/gist.token'
MAX_REQUEST = 300000


class Broker:
    def __init__(self, base=BASE, token=TOKEN, execute=run):
        self.base, self.token, self.execute = Path(base), Path(token), execute
        self.base.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.db = sqlite3.connect(self.base / 'jobs.sqlite')
        self.db.row_factory = sqlite3.Row
        self.db.execute('''CREATE TABLE IF NOT EXISTS jobs
            (id TEXT PRIMARY KEY, scope TEXT, digest TEXT, created REAL,
             files TEXT, title TEXT, result TEXT, state TEXT, url TEXT,
             UNIQUE(scope,digest))''')
        self.db.execute('CREATE TABLE IF NOT EXISTS repo_jobs (id TEXT PRIMARY KEY, destination TEXT NOT NULL)')
        self.db.commit()
        self.repository = Repository()

    def handle(self, req):
        if not isinstance(req, dict):
            raise ValueError('object required')
        action = req.get('action')
        allowed = {'action', 'scope', 'channel', 'network'}
        fields = {'run': {'files','argv','title'}, 'publish': {'id'},
                  'repo_read': {'branch','project'},
                  'repo_run': {'files','argv','title','branch','project','base_sha'},
                  'repo_publish': {'id'}}
        allowed |= fields.get(action, set())
        if set(req) != allowed or action not in fields:
            raise ValueError('invalid action or fields')
        if req['channel'] != '#ai' or req['network'] != 'irc.perl.org':
            raise ValueError('workbench is restricted to irc.perl.org #ai')
        scope = req['scope']
        if not isinstance(scope, str) or not re.fullmatch(r'[a-f0-9]{64}', scope):
            raise ValueError('invalid turn scope')
        destination = None
        if action == 'repo_read':
            validate_destination(req['branch'], req['project'])
            return self.repository.snapshot(req['branch'], req['project'])
        if action == 'repo_run':
            validate_destination(req['branch'], req['project'], req['base_sha'])
            snapshot = self.repository.snapshot(req['branch'], req['project'])
            if snapshot['base_sha'] != req['base_sha']:
                raise ValueError('branch changed; read project and retest against the new base')
            destination = {k: snapshot[k] for k in ('branch','project','base_sha','exists')}
        if action in ('run', 'repo_run'):
            files, argv = validate({'files': req['files'], 'argv': req['argv']})
            # Gists use flat filenames. No extraction, generated paths, symlinks,
            # stdout-as-files, or host file reads are part of publishing.
            if action == 'repo_run':
                validate_files(files)
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
            now = time.time()
            # Retain a bounded journal; ambiguous submissions remain for manual reconciliation.
            self.db.execute("DELETE FROM jobs WHERE created<? AND state NOT IN ('publishing','uncertain')", (now - 7*86400,))
            count = self.db.execute('SELECT COUNT(*) FROM jobs WHERE created>?', (now - 3600,)).fetchone()[0]
            if count >= 30:
                raise ValueError('global limit: 30 sandbox runs per hour')
            if self.db.execute('SELECT COUNT(*) FROM jobs WHERE scope=?', (scope,)).fetchone()[0] >= 5:
                raise ValueError('limit: 5 sandbox attempts per IRC request')
            job_id = uuid.uuid4().hex
            self.db.execute('INSERT INTO jobs VALUES (?,?,?,?,?,?,?,?,?)',
                            (job_id, scope, digest, now, json.dumps(files), title, '{}', 'running', None))
            if destination:
                self.db.execute('INSERT INTO repo_jobs VALUES (?,?)', (job_id, json.dumps(destination)))
            self.db.execute('DELETE FROM repo_jobs WHERE id NOT IN (SELECT id FROM jobs)')
            self.db.commit()
            try:
                result = self.execute({'files': files, 'argv': argv})
            except Exception:
                result = {'reason': 'runner_error', 'exit_code': None, 'output': ''}
            state = 'passed' if result.get('reason') == 'exited' and result.get('exit_code') == 0 else 'failed'
            # Logs are data, not publisher instructions. Never publish logs implicitly.
            result['output'] = result.get('output', '')[:8192]
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
            return self.publish_repository(job, json.loads(repo_job['destination']))
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

    @staticmethod
    def result(job):
        return {'id': job['id'], 'state': job['state'], 'result': json.loads(job['result']),
                'url': job['url'], 'files': list(json.loads(job['files']))}


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


class Handler(socketserver.StreamRequestHandler):
    def handle(self):
        self.request.settimeout(5)
        try:
            raw = self.rfile.readline(MAX_REQUEST + 1)
            if len(raw) > MAX_REQUEST or not raw.endswith(b'\n'):
                raise ValueError('oversized or unterminated request')
            result = self.server.broker.handle(json.loads(raw))
        except (ValueError, TypeError, KeyError) as exc:
            result = {'error': str(exc)[:300]}
        except Exception:
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
        server.broker = Broker()
        os.chmod(path, 0o600)
        server.serve_forever()


if __name__ == '__main__':
    main()
