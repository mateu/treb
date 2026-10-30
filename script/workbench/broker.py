#!/usr/bin/python3
"""Narrow local IPC: run immutable text inputs; publish only successful bundles."""
import hashlib
import hmac
import json
import math
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
from references import References, CATALOG

BASE = Path.home() / '.local/share/burt-workbench'
TOKEN = Path.home() / '.config/burt-publisher/gist.token'
MAX_REQUEST = MAX_JSON_BYTES
MAX_ATTEMPTS = 13
MAX_MODEL_ITERATIONS = 26
MAX_PROGRESS_NOTICES = 8
MAX_PUBLIC_WRITES = 1
TERMINAL_REPORT_RESERVE = 1

# Operator-only audit: fixed strings, never arbitrary exception/source text.
AUDIT_LIMIT = 512
AUDIT_TTL = 7 * 86400
PROPOSAL_TTL = 300
SNAPSHOT_TTL = 300
REJECTION_SCHEMA_VERSION = 1
REPEAT_REJECTION_LIMIT = 3
ACTIONS = frozenset(('run', 'publish', 'repo_read', 'repo_run', 'repo_publish',
                     'repo_inspect', 'job_inspect', 'repo_repair', 'repo_diagnose', 'reference', 'task_status',
                     'task_progress', 'task_checkpoint', 'checkpoint_status', 'task_resume',
                     'proposal_create', 'proposal_confirm'))
ACTION_CAPABILITY = {
    'reference': 'read_status', 'repo_read': 'read_status', 'repo_inspect': 'read_status', 'job_inspect': 'read_status',
    'run': 'edit_test', 'repo_run': 'edit_test', 'repo_repair': 'edit_test',
    'repo_diagnose': 'edit_test', 'task_status': 'edit_test', 'task_progress': 'edit_test',
    'task_checkpoint': 'edit_test', 'checkpoint_status': 'read_status', 'task_resume': 'edit_test',
    'publish': 'publish_gist', 'repo_publish': 'publish_repo',
    'proposal_confirm': 'read_status',
}
PROPOSAL_FIELDS = {
    'reference': frozenset(('key',)),
    'repo_read': frozenset(('branch', 'project')),
    'publish': frozenset(('id',)),
    'repo_publish': frozenset(('id',)),
}
# `irc_fold` on the Perl side emits the rfc1459 canonical alphabet. Do not
# require an alphanumeric first character: IRC permits a leading special.
REQUESTER_IDENTITY = re.compile(r'[a-z0-9_{}|~][a-z0-9_{}|~\-]{0,63}')
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
    def max_attempts(self):
        return MAX_ATTEMPTS

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
             network TEXT, action TEXT, request_sha256 TEXT, reason TEXT, error_kind TEXT,
             code TEXT, schema_version INTEGER)''')
        for column, definition in (('code', 'TEXT'), ('schema_version', 'INTEGER')):
            try: self.db.execute(f'ALTER TABLE rejections ADD COLUMN {column} {definition}')
            except sqlite3.OperationalError: pass
        self.db.execute('''CREATE TABLE IF NOT EXISTS rejection_fingerprints
            (scope TEXT NOT NULL, action TEXT NOT NULL, digest TEXT NOT NULL,
             count INTEGER NOT NULL, updated REAL NOT NULL,
             PRIMARY KEY(scope, action, digest))''')
        self.db.execute('''CREATE TABLE IF NOT EXISTS task_status
            (scope TEXT PRIMARY KEY, channel TEXT, network TEXT, created REAL,
             updated REAL, phase TEXT, reason TEXT)''')
        # Checkpoints are append-only recovery receipts. A resumed task gets a
        # fresh authorization scope but retains its original task identity.
        self.db.execute('''CREATE TABLE IF NOT EXISTS task_scopes
            (scope TEXT PRIMARY KEY, task_id TEXT NOT NULL, requester TEXT NOT NULL,
             channel TEXT NOT NULL, network TEXT NOT NULL, created REAL NOT NULL)''')
        self.db.execute('''CREATE TABLE IF NOT EXISTS task_checkpoints
            (id TEXT PRIMARY KEY, task_id TEXT NOT NULL, parent TEXT, scope TEXT NOT NULL,
             requester TEXT NOT NULL, channel TEXT NOT NULL, network TEXT NOT NULL,
             created REAL NOT NULL, phase TEXT NOT NULL, reason TEXT NOT NULL)''')
        # Attempt budget is durable task state, not a count over the prunable
        # job journal. It must survive restart and job-retention pruning.
        self.db.execute('''CREATE TABLE IF NOT EXISTS task_budgets
            (task_id TEXT PRIMARY KEY, attempts INTEGER NOT NULL, updated REAL NOT NULL)''')
        self.db.execute('''CREATE TABLE IF NOT EXISTS task_publications
            (task_id TEXT PRIMARY KEY, consumed INTEGER NOT NULL, updated REAL NOT NULL)''')
        # Global public-write limits are based on attempted write time, never
        # on the age of the immutable tested job selected for publication.
        self.db.execute('''CREATE TABLE IF NOT EXISTS publication_attempts
            (job_id TEXT PRIMARY KEY, attempted REAL NOT NULL)''')
        # Authoritative lifecycle state. Legacy attempt/publication tables stay
        # migration-safe indexes, but new transitions are admitted here first.
        self.db.execute('''CREATE TABLE IF NOT EXISTS task_phase_budgets
            (task_id TEXT PRIMARY KEY, deadline REAL NOT NULL, phase TEXT NOT NULL,
             model_iterations INTEGER NOT NULL, sandbox_attempts INTEGER NOT NULL, public_writes INTEGER NOT NULL,
             progress_notices INTEGER NOT NULL, terminal_reports INTEGER NOT NULL,
             terminal_reason TEXT, updated REAL NOT NULL)''')
        self.db.execute('''CREATE TABLE IF NOT EXISTS proposals
            (id TEXT PRIMARY KEY, scope TEXT NOT NULL, requester TEXT NOT NULL,
             channel TEXT NOT NULL, network TEXT NOT NULL, action TEXT NOT NULL,
             params TEXT NOT NULL, created REAL NOT NULL, expires REAL NOT NULL,
             state TEXT NOT NULL)''')
        self.db.execute('''CREATE TABLE IF NOT EXISTS repo_snapshots
            (id TEXT PRIMARY KEY, scope TEXT NOT NULL, channel TEXT NOT NULL,
             network TEXT NOT NULL, snapshot TEXT NOT NULL, created REAL NOT NULL,
             expires REAL NOT NULL, state TEXT NOT NULL)''')
        # A direct ordinary publication request chooses once. Persisting the
        # selection makes retries idempotent and prevents later work from being
        # substituted into the original human authorization.
        self.db.execute('''CREATE TABLE IF NOT EXISTS direct_repo_publications
            (scope TEXT PRIMARY KEY, job_id TEXT NOT NULL, requester TEXT NOT NULL,
             channel TEXT NOT NULL, network TEXT NOT NULL, created REAL NOT NULL)''')
        # A successful material repository change is the durable candidate for
        # its human/channel/destination workspace. Read-only and base-only
        # verification runs deliberately do not replace it.
        self.db.execute('''CREATE TABLE IF NOT EXISTS repository_candidates
            (requester TEXT NOT NULL, channel TEXT NOT NULL, network TEXT NOT NULL,
             branch TEXT NOT NULL, project TEXT NOT NULL, job_id TEXT NOT NULL,
             created REAL NOT NULL,
             PRIMARY KEY(requester,channel,network,branch,project))''')
        # State tables above are mutable operational indexes. Keep an append-only
        # receipt for every resource transition for recovery and audit.
        self.db.execute('''CREATE TABLE IF NOT EXISTS resource_checkpoints
            (id TEXT PRIMARY KEY, resource_kind TEXT NOT NULL, resource_id TEXT NOT NULL,
             task_id TEXT NOT NULL, scope TEXT NOT NULL, requester TEXT,
             channel TEXT NOT NULL, network TEXT NOT NULL, created REAL NOT NULL,
             state TEXT NOT NULL)''')
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
        self.db.execute('DELETE FROM task_checkpoints WHERE created<?', (now - AUDIT_TTL,))
        self.db.execute('DELETE FROM task_checkpoints WHERE id NOT IN '
                        '(SELECT id FROM task_checkpoints ORDER BY created DESC LIMIT ?)', (AUDIT_LIMIT,))
        self.db.execute('DELETE FROM task_scopes WHERE task_id NOT IN (SELECT DISTINCT task_id FROM task_checkpoints) '
                        'AND created<?', (now - AUDIT_TTL,))
        self.db.execute('DELETE FROM task_budgets WHERE task_id NOT IN (SELECT DISTINCT task_id FROM task_checkpoints) '
                        'AND updated<?', (now - AUDIT_TTL,))
        self.db.execute('DELETE FROM task_publications WHERE task_id NOT IN (SELECT DISTINCT task_id FROM task_checkpoints) '
                        'AND updated<?', (now - AUDIT_TTL,))
        self.db.execute('DELETE FROM publication_attempts WHERE attempted<?', (now - AUDIT_TTL,))
        self.db.execute('DELETE FROM task_phase_budgets WHERE task_id NOT IN (SELECT DISTINCT task_id FROM task_checkpoints) '
                        'AND updated<?', (now - AUDIT_TTL,))
        self.db.execute('DELETE FROM direct_repo_publications WHERE created<?', (now - AUDIT_TTL,))
        self.db.execute('DELETE FROM repository_candidates WHERE created<?', (now - AUDIT_TTL,))
        self.db.execute('DELETE FROM repository_candidates WHERE job_id NOT IN (SELECT id FROM jobs)')
        self.db.execute('DELETE FROM resource_checkpoints WHERE created<?', (now - AUDIT_TTL,))
        self.db.execute('DELETE FROM resource_checkpoints WHERE id NOT IN '
                        '(SELECT id FROM resource_checkpoints ORDER BY created DESC,id DESC LIMIT ?)', (AUDIT_LIMIT,))
        expired_proposals = self.db.execute(
            'SELECT id,scope,channel,network FROM proposals WHERE state="proposed" AND expires<=?', (now,)).fetchall()
        self.db.execute('UPDATE proposals SET state="expired" WHERE state="proposed" AND expires<=?', (now,))
        for row in expired_proposals:
            self.resource_checkpoint('proposal', row['id'], dict(row), 'expired', now)
        self.db.execute('DELETE FROM proposals WHERE created<?', (now - AUDIT_TTL,))
        self.db.execute('DELETE FROM proposals WHERE id NOT IN '
                        '(SELECT id FROM proposals ORDER BY created DESC LIMIT ?)', (AUDIT_LIMIT,))
        expired_snapshots = self.db.execute(
            'SELECT id,scope,channel,network FROM repo_snapshots WHERE state="active" AND expires<=?', (now,)).fetchall()
        self.db.execute('UPDATE repo_snapshots SET state="expired" WHERE state="active" AND expires<=?', (now,))
        for row in expired_snapshots:
            self.resource_checkpoint('snapshot', row['id'], dict(row), 'expired', now)
        self.prune_snapshots(now)
        self.db.execute('DELETE FROM rejection_fingerprints WHERE updated<?', (now - AUDIT_TTL,))

    def recoverable_snapshot_ids(self):
        rows = self.db.execute('SELECT r.destination FROM repo_jobs r JOIN jobs j ON j.id=r.id '
                               'LEFT JOIN task_scopes s ON s.scope=j.scope WHERE j.state IN (\'passed\',\'failed\') AND EXISTS '
                               '(SELECT 1 FROM task_checkpoints c WHERE c.task_id=COALESCE(s.task_id,j.scope))').fetchall()
        return {snapshot_id for row in rows
                for snapshot_id in [json.loads(row['destination']).get('snapshot_id')] if snapshot_id}

    def prune_jobs(self, now):
        # A checkpoint is a recovery receipt, so keep the complete saved bundle
        # for every task it still names even after ordinary journal retention.
        self.db.execute("DELETE FROM jobs WHERE created<? AND state NOT IN ('publishing','uncertain') "
                        'AND NOT EXISTS (SELECT 1 FROM task_checkpoints c LEFT JOIN task_scopes s '
                        'ON s.scope=jobs.scope WHERE c.task_id=COALESCE(s.task_id,jobs.scope))',
                        (now - 7*86400,))

    def prune_snapshots(self, now):
        protected=sorted(self.recoverable_snapshot_ids())
        placeholders=','.join('?' for _ in protected)
        keep=(f' AND id NOT IN ({placeholders})' if protected else '')
        self.db.execute('DELETE FROM repo_snapshots WHERE created<?'+keep,
                        (now - AUDIT_TTL, *protected))
        self.db.execute('DELETE FROM repo_snapshots WHERE id NOT IN '
                        '(SELECT id FROM repo_snapshots ORDER BY created DESC LIMIT ?)'+keep,
                        (AUDIT_LIMIT, *protected))

    def create_snapshot(self, req):
        snapshot = self.repository.snapshot(req['branch'], req['project'])
        now = time.time()
        snapshot_id = uuid.uuid4().hex
        self.db.execute('INSERT INTO repo_snapshots VALUES (?,?,?,?,?,?,?,?)',
                        (snapshot_id, req['scope'], req['channel'], req['network'],
                         json.dumps(snapshot, sort_keys=True), now, now + SNAPSHOT_TTL, 'active'))
        self.resource_checkpoint('snapshot', snapshot_id, req, 'active', now)
        self.prune_audit()
        self.db.commit()
        return snapshot | {'snapshot_id': snapshot_id}

    def load_snapshot(self, req, snapshot_id, require_active=True):
        if not isinstance(snapshot_id, str) or not re.fullmatch(r'[a-f0-9]{32}', snapshot_id):
            raise ValueError('invalid repository snapshot id')
        row = self.db.execute('SELECT * FROM repo_snapshots WHERE id=?', (snapshot_id,)).fetchone()
        if not row or not self.resource_scope_authorized(req, row['scope'], row['channel'], row['network']):
            raise ValueError('repository snapshot not found in this request')
        if row['state'] == 'active' and row['expires'] <= time.time():
            self.db.execute('UPDATE repo_snapshots SET state="expired" WHERE id=?', (snapshot_id,))
            self.resource_checkpoint('snapshot', snapshot_id, req, 'expired')
            self.db.commit()
            row = self.db.execute('SELECT * FROM repo_snapshots WHERE id=?', (snapshot_id,)).fetchone()
        if require_active and row['state'] != 'active':
            raise ValueError('repository snapshot expired; read project again')
        return json.loads(row['snapshot']) | {'snapshot_id': snapshot_id}

    @staticmethod
    def materialize_files(base, changes, deleted):
        if (not isinstance(changes, dict) or not isinstance(deleted, list)
                or any(not isinstance(name, str) for name in deleted)
                or len(deleted) != len(set(deleted))):
            raise ValueError('repository test requires file replacements and an explicit deletion list')
        if any(name not in base or name in changes for name in deleted):
            raise ValueError('delete only existing files, without also replacing them')
        files = dict(base)
        files.update(changes)
        for name in deleted:
            del files[name]
        return files

    @staticmethod
    def candidate_delta(base, files):
        return ({name: value for name, value in files.items() if base.get(name) != value},
                sorted(set(base) - set(files)))

    def record_rejection(self, req, exc, raw=None):
        # Scope/channel/action come only from the trusted runtime IPC envelope.
        # Never reflect exception/request bytes; fingerprint them only for bounded retry control.
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
        uncertain = ('submission failed or response lost' in message
                     or 'submission failed or response was lost' in message
                     or 'publication outcome requires operator reconciliation' in message)
        stale = message.startswith('branch changed') or 'snapshot expired' in message
        budget = message.startswith(('limit:', 'global limit:'))
        code, public, disposition = (
            ('publication_uncertain', 'publication outcome requires operator reconciliation', 'terminal') if uncertain else
            ('stale_base', 'repository base changed; read and retest', 'retryable') if stale else
            ('budget_exhausted', 'request budget exhausted', 'terminal') if budget else
            ('transport_unavailable', 'broker unavailable; operator inspection required', 'retryable') if isinstance(exc, (TimeoutError, OSError)) else
            ('invalid_request', 'request rejected by Workbench policy', 'retryable'))
        reason = message if message in SAFE_REASONS or isinstance(exc, InputSizeError) else 'unclassified broker error'
        for prefix in ('baseline files cannot be deleted: ', 'protected baseline file changed: ',
                       'new files restricted to approved regression directories: ', 'unknown reference; available: '):
            if message.startswith(prefix): reason = prefix.rstrip(': ')
        kind = ('validation' if isinstance(exc, ValueError) else 'type' if isinstance(exc, TypeError) else
                'missing_field' if isinstance(exc, KeyError) else 'transport' if isinstance(exc, (TimeoutError, OSError)) else 'internal')
        repeated = 0
        if scope and action:
            self.db.execute('INSERT INTO rejection_fingerprints VALUES (?,?,?,?,?) '
                            'ON CONFLICT(scope,action,digest) DO UPDATE SET count=count+1,updated=excluded.updated',
                            (scope, action, digest, 1, time.time()))
            repeated = self.db.execute('SELECT count FROM rejection_fingerprints WHERE scope=? AND action=? AND digest=?',
                                       (scope, action, digest)).fetchone()[0]
            if repeated >= REPEAT_REJECTION_LIMIT: disposition = 'terminal'
        self.db.execute('INSERT INTO rejections (created,scope,channel,network,action,request_sha256,reason,error_kind,code,schema_version) '
                        'VALUES (?,?,?,?,?,?,?,?,?,?)',
                        (time.time(), scope, channel, network, action, digest, reason, kind, code, REJECTION_SCHEMA_VERSION))
        self.prune_audit(); self.db.commit()
        return {'rejection_schema': REJECTION_SCHEMA_VERSION, 'code': code, 'message': public,
                'action': action, 'disposition': disposition,
                'reconciliation': 'required' if uncertain else None,
                'repeat_count': min(repeated, REPEAT_REJECTION_LIMIT)}

    @staticmethod
    def capability_envelope(action, scope, channel, network):
        capability = ACTION_CAPABILITY[action]
        grant = hashlib.sha256(json.dumps(
            [scope, channel, network, capability], separators=(',', ':'), ensure_ascii=True).encode()).hexdigest()
        return {'scope': scope, 'capability': capability, 'grant': grant,
                'channel': channel, 'network': network}

    def task_binding(self, scope):
        row = self.db.execute('SELECT * FROM task_scopes WHERE scope=?', (scope,)).fetchone()
        return row or {'scope': scope, 'task_id': scope}

    def resource_scope_authorized(self, req, resource_scope, resource_channel, resource_network):
        """Authorize resources by durable task identity, never by grant reuse."""
        if resource_channel != req['channel'] or resource_network != req['network']:
            return False
        # Keep same-scope legacy rows usable before their first checkpoint.
        if resource_scope == req['scope']:
            return True
        current = self.db.execute('SELECT * FROM task_scopes WHERE scope=?', (req['scope'],)).fetchone()
        resource = self.db.execute('SELECT * FROM task_scopes WHERE scope=?', (resource_scope,)).fetchone()
        return bool(current and resource and current['task_id'] == resource['task_id']
                    and current['requester'] == resource['requester']
                    and current['channel'] == resource['channel']
                    and current['network'] == resource['network'])

    def resource_checkpoint(self, resource_kind, resource_id, req, state, now=None):
        binding = self.task_binding(req['scope'])
        requester = binding['requester'] if 'requester' in binding.keys() else None
        self.db.execute('INSERT INTO resource_checkpoints VALUES (?,?,?,?,?,?,?,?,?,?)',
                        (uuid.uuid4().hex, resource_kind, resource_id, binding['task_id'], req['scope'],
                         requester, req['channel'], req['network'],
                         time.time() if now is None else now, state))

    def load_job(self, req, job_id, error='job not found in this request'):
        job = self.db.execute('SELECT * FROM jobs WHERE id=?', (job_id,)).fetchone()
        if not job or not self.resource_scope_authorized(req, job['scope'], req['channel'], req['network']):
            raise ValueError(error)
        return job

    def task_job_rows(self, task_id):
        return self.db.execute('SELECT j.id,j.state,j.created,r.destination FROM jobs j '
                               'LEFT JOIN task_scopes s ON s.scope=j.scope LEFT JOIN repo_jobs r ON r.id=j.id '
                               'WHERE COALESCE(s.task_id,j.scope)=? ORDER BY j.created,j.id', (task_id,)).fetchall()

    @staticmethod
    def repository_candidate_key(destination):
        # Snapshot IDs and verification metadata are immutable evidence, not the
        # publication identity. A direct request selects one branch/project.
        return (destination['branch'], destination['project'])

    def direct_repository_publication_job(self, req):
        """Return the job durably bound to this direct IRC publication request."""
        requester = req.get('requester')
        if not isinstance(requester, str) or not REQUESTER_IDENTITY.fullmatch(requester):
            raise ValueError('direct repository publication requires the trusted requester')
        bound = self.db.execute('SELECT * FROM direct_repo_publications WHERE scope=?',
                                (req['scope'],)).fetchone()
        if bound:
            if (bound['requester'], bound['channel'], bound['network']) != (
                    requester, req['channel'], req['network']):
                raise ValueError('direct repository publication binding does not match request')
            row = self.db.execute('SELECT * FROM jobs WHERE id=?', (bound['job_id'],)).fetchone()
            if not row:
                raise ValueError('direct repository publication binding is unavailable')
            return row
        # Indexed candidates are fast-path evidence, but legacy passed work
        # predates that index. Recover both sets before deciding that a single
        # candidate is unambiguous; otherwise an indexed project can shadow an
        # eligible legacy project.
        indexed = self.db.execute(
            'SELECT c.job_id FROM repository_candidates c JOIN jobs j ON j.id=c.job_id '
            'JOIN repo_jobs r ON r.id=j.id '
            'WHERE c.requester=? AND c.channel=? AND c.network=? '
            'AND j.state IN ("passed","published") ORDER BY c.branch,c.project',
            (requester, req['channel'], req['network'])).fetchall()
        eligible = {}
        indexed_destinations = set()
        for candidate in indexed:
            job = self.db.execute('SELECT * FROM jobs WHERE id=?', (candidate['job_id'],)).fetchone()
            destination = json.loads(self.db.execute('SELECT destination FROM repo_jobs WHERE id=?',
                                                     (job['id'],)).fetchone()['destination'])
            key = self.repository_candidate_key(destination)
            indexed_destinations.add(key)
            if job['state'] == 'passed':
                eligible.setdefault(key, (job, destination))
        rows = self.db.execute(
            'SELECT j.* FROM jobs j JOIN repo_jobs r ON r.id=j.id '
            'JOIN task_scopes s ON s.scope=j.scope '
            'WHERE j.state="passed" AND s.requester=? '
            'AND s.channel=? AND s.network=? ORDER BY j.created,j.id',
            (requester, req['channel'], req['network'])).fetchall()
        for row in rows:
            destination = json.loads(self.db.execute('SELECT destination FROM repo_jobs WHERE id=?',
                                                     (row['id'],)).fetchone()['destination'])
            if destination.get('diagnostic_only'):
                continue
            key = self.repository_candidate_key(destination)
            if destination.get('candidate_material') is True:
                if key not in indexed_destinations:
                    eligible[key] = (row, destination)
                continue
            # Migration-safe recovery for jobs written before candidate lineage:
            # compare the immutable tested bundle with its immutable snapshot.
            try:
                # The candidate query already verifies the originating job's
                # requester/channel/network identity. Legacy snapshots belong
                # to that job's original scope, while this fresh publication
                # request intentionally has a new scope.
                snapshot = self.load_snapshot({**req, 'scope': row['scope']},
                                              destination['snapshot_id'], require_active=False)
                changes, deleted = self.candidate_delta(snapshot['files'], json.loads(row['files']))
                if (changes or deleted) and key not in indexed_destinations:
                    # Rows are oldest-first, so retain the newest tested legacy
                    # bundle for a destination while an indexed candidate keeps
                    # precedence over any recovered legacy history.
                    eligible[key] = (row, destination)
            except (KeyError, TypeError, ValueError):
                # Missing legacy evidence is not proof that a base-only run was
                # a candidate. Leave it unavailable rather than guessing.
                continue
        if len(eligible) != 1:
            raise ValueError('direct repository publication needs one unambiguous saved project candidate')
        job, destination = next(iter(eligible.values()))
        self.remember_repository_candidate(req, job['id'], destination)
        self.db.execute('INSERT INTO direct_repo_publications VALUES (?,?,?,?,?,?)',
                        (req['scope'], job['id'], requester, req['channel'], req['network'], time.time()))
        # Commit before a side effect so a retry cannot reselect different work
        # after a crash or an uncertain publication outcome.
        self.db.commit()
        return job

    def remember_repository_candidate(self, req, job_id, destination):
        """Persist an intentional changed-and-passed project candidate.

        The broker, not model prose or a later base-only test, owns this
        lineage. The candidate remains bound to the originating requester,
        IRC channel/network, and fixed repository destination.
        """
        if destination.get('diagnostic_only') or not destination.get('candidate_material'):
            return
        binding = self.task_binding(req['scope'])
        # An identity-bound task receipt is required for cross-request
        # selection. Older callers remain usable through migration fallback.
        requester = binding['requester'] if 'requester' in binding.keys() else None
        if not requester:
            return
        self.db.execute('''INSERT INTO repository_candidates VALUES (?,?,?,?,?,?,?)
                         ON CONFLICT(requester,channel,network,branch,project)
                         DO UPDATE SET job_id=excluded.job_id,created=excluded.created''',
                        (requester, req['channel'], req['network'], destination['branch'],
                         destination['project'], job_id, time.time()))

    def task_attempt_count(self, task_id):
        row = self.db.execute('SELECT attempts FROM task_budgets WHERE task_id=?', (task_id,)).fetchone()
        if row:
            return row['attempts']
        # Migration-safe baseline for a task created before durable accounting.
        attempts = len(self.task_job_rows(task_id))
        self.db.execute('INSERT OR IGNORE INTO task_budgets VALUES (?,?,?)', (task_id, attempts, time.time()))
        return attempts

    def consume_task_attempt(self, task_id, now):
        self.db.execute('INSERT INTO task_budgets VALUES (?,?,?) '
                        'ON CONFLICT(task_id) DO UPDATE SET attempts=attempts+1,updated=excluded.updated',
                        (task_id, 1, now))

    def task_publication_count(self, task_id):
        row = self.db.execute('SELECT consumed FROM task_publications WHERE task_id=?', (task_id,)).fetchone()
        if row:
            return row['consumed']
        consumed = self.db.execute('SELECT COUNT(*) FROM jobs j LEFT JOIN task_scopes s ON s.scope=j.scope '
                                   "WHERE COALESCE(s.task_id,j.scope)=? AND j.state IN ('published','publishing','uncertain')",
                                   (task_id,)).fetchone()[0]
        self.db.execute('INSERT OR IGNORE INTO task_publications VALUES (?,?,?)', (task_id, consumed, time.time()))
        return consumed

    def consume_task_publication(self, task_id, now):
        self.db.execute('INSERT INTO task_publications VALUES (?,?,?) '
                        'ON CONFLICT(task_id) DO UPDATE SET consumed=1,updated=excluded.updated',
                        (task_id, 1, now))

    def publication_attempt_count(self, now=None):
        now = time.time() if now is None else now
        # Pre-upgrade journals have no attempt receipt. Conservatively retain
        # their existing created-within-day accounting until a new attempt is
        # recorded for that job.
        return self.db.execute('SELECT COUNT(*) FROM ('
                               'SELECT job_id FROM publication_attempts WHERE attempted>? '
                               'UNION '
                               "SELECT id FROM jobs WHERE created>? AND state IN ('published','publishing','uncertain') "
                               'AND id NOT IN (SELECT job_id FROM publication_attempts))',
                               (now - 86400, now - 86400)).fetchone()[0]

    def record_publication_attempt(self, job_id, now=None):
        self.db.execute('INSERT OR IGNORE INTO publication_attempts VALUES (?,?)',
                        (job_id, time.time() if now is None else now))

    def consume_prior_task_publication_authority(self, task_id):
        now = time.time()
        # A database predating phase budgets can retain a passed job; initialize
        # its original task before enforcing its migrated publication allowance.
        row = self.ensure_task_phase_budget(task_id, now)
        if row['public_writes'] >= MAX_PUBLIC_WRITES:
            raise ValueError('limit: one submission per IRC request')
        self.db.execute('UPDATE task_phase_budgets SET public_writes=public_writes+1,updated=? WHERE task_id=?',
                        (now, task_id))

    def ensure_task_phase_budget(self, task_id, now, deadline=None):
        row = self.db.execute('SELECT * FROM task_phase_budgets WHERE task_id=?', (task_id,)).fetchone()
        if row:
            return row
        deadline = deadline if isinstance(deadline, (int, float)) and deadline > now else now + 1800
        self.db.execute('INSERT INTO task_phase_budgets VALUES (?,?,?,?,?,?,?,?,?,?)',
                        (task_id, deadline, 'started', 0, self.task_attempt_count(task_id),
                         self.task_publication_count(task_id), 0, 0, None, now))
        return self.db.execute('SELECT * FROM task_phase_budgets WHERE task_id=?', (task_id,)).fetchone()

    def task_budget_status(self, task_id, now=None):
        now = time.time() if now is None else now
        row = self.ensure_task_phase_budget(task_id, now)
        return {'phase': row['phase'], 'terminal_reason': row['terminal_reason'],
                'deadline_remaining_seconds': max(0, int(row['deadline'] - now)),
                'remaining_budget': {
                    'model_iterations': max(0, MAX_MODEL_ITERATIONS - row['model_iterations']),
                    'sandbox_executions': max(0, self.max_attempts() - row['sandbox_attempts']),
                    'public_writes': max(0, MAX_PUBLIC_WRITES - row['public_writes']),
                    'progress_notices': max(0, MAX_PROGRESS_NOTICES - row['progress_notices']),
                    'terminal_reports': max(0, TERMINAL_REPORT_RESERVE - row['terminal_reports'])}}

    def admit_transition(self, task_id, operation, now=None, deadline=None, terminal_reason=None, model_iterations=None,
                         limit_message=None, allow_after_final_report=False):
        """Atomically admit one durable task operation before its side effect."""
        now = time.time() if now is None else now
        row = self.ensure_task_phase_budget(task_id, now, deadline)
        recording_publication_uncertainty = (operation == 'terminal' and terminal_reason == 'publication_uncertain')
        if (operation not in ('status', 'checkpoint', 'terminal_report') and row['terminal_reason']
                and not (recording_publication_uncertainty
                         or (allow_after_final_report and operation == 'public_write'
                             and row['terminal_reason'] == 'final_report'))):
            raise ValueError('task is terminal; operator inspection required')
        if operation not in ('status', 'checkpoint', 'terminal_report', 'terminal') and now >= row['deadline']:
            self.db.execute('UPDATE task_phase_budgets SET phase=?,terminal_reason=?,updated=? WHERE task_id=?',
                            ('stopped', 'deadline', now, task_id))
            raise ValueError('task deadline reached; terminal report reserved')
        updates = {'phase': row['phase'], 'terminal_reason': row['terminal_reason']}
        if model_iterations is not None:
            if not isinstance(model_iterations, int) or not 0 <= model_iterations <= MAX_MODEL_ITERATIONS:
                raise ValueError('invalid model iteration count')
            updates['model_iterations'] = max(row['model_iterations'], model_iterations)
        if operation == 'sandbox':
            if row['sandbox_attempts'] >= self.max_attempts():
                raise ValueError(f'limit: {self.max_attempts()} sandbox attempts per IRC request')
            updates['sandbox_attempts'] = row['sandbox_attempts'] + 1
        elif operation == 'public_write':
            if row['public_writes'] >= MAX_PUBLIC_WRITES:
                raise ValueError(limit_message or 'limit: one submission per IRC request')
            updates['public_writes'] = row['public_writes'] + 1
        elif operation == 'progress':
            if row['progress_notices'] >= MAX_PROGRESS_NOTICES:
                raise ValueError('limit: progress notice budget exhausted')
            updates['progress_notices'] = row['progress_notices'] + 1
        elif operation == 'terminal':
            updates['phase'] = 'stopped'
            # An attempted public write may become unknowable only after it has
            # crossed the irreversible boundary. Preserve that reconciliation
            # requirement even if final reporting or the deadline came first.
            updates['terminal_reason'] = (terminal_reason if recording_publication_uncertainty
                                          else terminal_reason or row['terminal_reason'] or 'terminal')
        elif operation == 'terminal_report':
            if row['terminal_reports'] == 0:
                updates['terminal_reports'] = 1
            updates['phase'] = 'reported'
            updates['terminal_reason'] = row['terminal_reason'] or terminal_reason or 'final_report'
        if updates != {'phase': row['phase'], 'terminal_reason': row['terminal_reason']}:
            columns = ','.join(f'{key}=?' for key in updates)
            self.db.execute(f'UPDATE task_phase_budgets SET {columns},updated=? WHERE task_id=?',
                            (*updates.values(), now, task_id))
        return self.task_budget_status(task_id, now)

    def checkpoint_summary(self, row):
        jobs = self.task_job_rows(row['task_id'])
        latest_repository_job = None
        for job in reversed(jobs):
            if job['destination']:
                destination = json.loads(job['destination'])
                if not destination.get('diagnostic_only'):
                    latest_repository_job = {'id': job['id'], 'state': job['state']}
                    break
        budget = self.task_budget_status(row['task_id'])
        latest_execution_job = None
        for job in reversed(jobs):
            destination = json.loads(job['destination']) if job['destination'] else {}
            if not destination.get('diagnostic_only'):
                latest_execution_job = {'id': job['id'], 'state': job['state']}
                break
        return {'checkpoint_id': row['id'], 'task_id': row['task_id'], 'parent_checkpoint_id': row['parent'],
                'phase': row['phase'], 'reason': row['reason'],
                'jobs': [{'id': j['id'], 'state': j['state']} for j in jobs],
                'latest_repository_job': latest_repository_job, 'latest_execution_job': latest_execution_job,
                'attempts_remaining': budget['remaining_budget']['sandbox_executions'], 'budget': budget}

    def handle(self, req, _diagnostic=False):
        try:
            return self._handle(req, _diagnostic=_diagnostic)
        except Exception as exc:
            exc.rejection = self.record_rejection(req, exc)
            raise

    def _handle(self, req, _diagnostic=False, _saved_snapshot=False, _confirmed_publication=False):
        if not isinstance(req, dict):
            raise ValueError('object required')
        action = req.get('action')
        allowed = {'action', 'scope', 'capability', 'grant', 'channel', 'network'}
        fields = {'run': {'files','argv','title'}, 'publish': {'id'},
                  'repo_read': {'branch','project'},
                  'repo_run': {'snapshot_id','changes','delete','argv','title'},
                  'repo_publish': set(), 'repo_inspect': {'id'}, 'job_inspect': {'id'},
                  'repo_repair': {'id','changes','delete','argv','title'},
                  'repo_diagnose': {'id','argv','title'}}
        fields['reference'] = {'key'}
        fields['task_status'] = {'phase', 'reason'}
        fields['task_progress'] = set()
        fields['task_checkpoint'] = {'requester', 'phase', 'reason'}
        optional_fields = {'task_status': {'deadline', 'model_iterations'}, 'task_checkpoint': {'deadline'},
                           'repo_publish': {'id', 'requester'}}
        fields['checkpoint_status'] = {'checkpoint_id', 'requester'}
        fields['task_resume'] = {'checkpoint_id', 'requester'}
        optional_fields['task_resume'] = {'deadline'}
        fields['proposal_create'] = {'proposal_action', 'params', 'requester'}
        fields['proposal_confirm'] = {'requester', 'confirmed_at', 'publication_confirmation'}
        allowed |= fields.get(action, set()) | optional_fields.get(action, set())
        if action == 'proposal_confirm':
            required = {'action', 'scope', 'capability', 'grant', 'channel', 'network', 'requester', 'confirmed_at'}
            if not required <= set(req) or set(req) - allowed:
                raise ValueError('invalid action or fields')
        elif (action not in fields or not {'action', 'scope', 'capability', 'grant', 'channel', 'network'} <= set(req)
              or not fields[action] <= set(req) or set(req) - allowed):
            raise ValueError('invalid action or fields')
        if action == 'repo_publish' and not _confirmed_publication and 'id' in req:
            raise ValueError('direct repository publication selects its job from trusted task evidence')
        if req['channel'] not in ('#ai', '#mateu-test') or req['network'] != 'irc.perl.org':
            raise ValueError('workbench is restricted to irc.perl.org #ai or #mateu-test')
        scope = req['scope']
        if not isinstance(scope, str) or not re.fullmatch(r'[a-f0-9]{64}', scope):
            raise ValueError('invalid turn scope')
        capability = req['capability']
        expected_capability = (ACTION_CAPABILITY.get(req.get('proposal_action'))
                               if action == 'proposal_create' else ACTION_CAPABILITY.get(action))
        if expected_capability is None:
            raise ValueError('invalid action or fields')
        # A bounded project read is a prerequisite for an edit-authorized
        # repository test. It remains read-only but shares the edit scope.
        if (action == 'repo_read' or (action == 'proposal_create'
                                      and req.get('proposal_action') == 'repo_read')) \
                and capability in ('read_status', 'edit_test'):
            expected_capability = capability
        expected_grant = hashlib.sha256(json.dumps(
            [scope, req['channel'], req['network'], expected_capability],
            separators=(',', ':'), ensure_ascii=True).encode()).hexdigest()
        if (capability != expected_capability or not isinstance(req['grant'], str)
                or not hmac.compare_digest(req['grant'], expected_grant)):
            raise ValueError('invalid capability grant')
        # Every operation in an admitted task observes the same durable
        # deadline/terminal state before dispatch. Read/status-like operations
        # spend nothing and remain available for truthful recovery inspection.
        binding = self.task_binding(scope)
        if self.db.execute('SELECT 1 FROM task_phase_budgets WHERE task_id=?', (binding['task_id'],)).fetchone():
            self.admit_transition(binding['task_id'], 'status')
        if action == 'proposal_create':
            return self.create_proposal(req)
        if action == 'proposal_confirm':
            return self.confirm_proposal(req)
        if action in ('task_checkpoint', 'checkpoint_status', 'task_resume'):
            requester = req['requester']
            if not isinstance(requester, str) or not REQUESTER_IDENTITY.fullmatch(requester):
                raise ValueError('invalid requester identity')
            if action != 'task_checkpoint':
                checkpoint_id = req['checkpoint_id']
                if not isinstance(checkpoint_id, str) or not re.fullmatch(r'[a-f0-9]{32}', checkpoint_id):
                    raise ValueError('invalid checkpoint id')
                checkpoint = self.db.execute('SELECT * FROM task_checkpoints WHERE id=?', (checkpoint_id,)).fetchone()
                if (not checkpoint or checkpoint['requester'] != requester or checkpoint['channel'] != req['channel']
                        or checkpoint['network'] != req['network']):
                    raise ValueError('checkpoint not found for this requester')
                if action == 'checkpoint_status':
                    return self.checkpoint_summary(checkpoint)
                # A resume always derives authority from this new envelope. Old
                # grants are not accepted, and an ambiguous public write is an
                # absorbing terminal state until an operator reconciles it.
                if req['scope'] == checkpoint['scope']:
                    raise ValueError('resume requires a fresh task scope')
                if any(job['state'] in ('publishing', 'uncertain') for job in self.task_job_rows(checkpoint['task_id'])):
                    raise ValueError('publication outcome requires operator reconciliation')
                existing = self.db.execute('SELECT * FROM task_scopes WHERE scope=?', (req['scope'],)).fetchone()
                if existing:
                    raise ValueError('fresh task scope is already bound')
                now = time.time()
                deadline = req.get('deadline')
                if deadline is not None and (not isinstance(deadline, (int, float)) or not now < deadline <= now + 3600):
                    raise ValueError('invalid resume deadline')
                if deadline is not None:
                    # A resume has fresh human authority and a new bounded
                    # runtime lifetime, but preserves task-wide spend counters.
                    self.db.execute('UPDATE task_phase_budgets SET deadline=?,phase=?,terminal_reason=NULL,updated=? WHERE task_id=?',
                                    (deadline, 'started', now, checkpoint['task_id']))
                self.db.execute('INSERT INTO task_scopes VALUES (?,?,?,?,?,?)',
                                (req['scope'], checkpoint['task_id'], requester, req['channel'], req['network'], now))
                self.db.commit()
                return self.checkpoint_summary(checkpoint) | {'resumed_scope': req['scope']}
            if (req['phase'] not in ('started', 'stopped', 'reported') or req['reason'] not in
                    ('admitted', 'deadline', 'iteration_limit', 'runtime_error', 'no_report',
                     'final_report', 'execution_limit')):
                raise ValueError('invalid task status')
            binding = self.task_binding(scope)
            if 'requester' in binding.keys() and (binding['requester'] != requester or binding['channel'] != req['channel']
                                                   or binding['network'] != req['network']):
                raise ValueError('task identity mismatch')
            now = time.time()
            deadline = req.get('deadline')
            if deadline is not None and (not isinstance(deadline, (int, float)) or deadline > now + 3600):
                raise ValueError('invalid task deadline')
            terminal = req['phase'] == 'reported' and req['reason'] == 'final_report'
            self.admit_transition(binding['task_id'], 'terminal_report' if terminal else 'checkpoint', now,
                                  deadline=deadline, terminal_reason=req['reason'] if terminal else None)
            self.db.execute('INSERT OR IGNORE INTO task_scopes VALUES (?,?,?,?,?,?)',
                            (scope, binding['task_id'], requester, req['channel'], req['network'], now))
            parent = self.db.execute('SELECT id FROM task_checkpoints WHERE task_id=? ORDER BY created DESC,id DESC LIMIT 1',
                                     (binding['task_id'],)).fetchone()
            checkpoint = uuid.uuid4().hex
            self.db.execute('INSERT INTO task_checkpoints VALUES (?,?,?,?,?,?,?,?,?,?)',
                            (checkpoint, binding['task_id'], parent['id'] if parent else None, scope, requester,
                             req['channel'], req['network'], now, req['phase'], req['reason']))
            self.prune_audit()
            self.db.commit()
            row = self.db.execute('SELECT * FROM task_checkpoints WHERE id=?', (checkpoint,)).fetchone()
            return self.checkpoint_summary(row)
        if action == 'task_progress':
            budget = self.admit_transition(self.task_binding(scope)['task_id'], 'progress')
            self.db.commit()
            return {'budget': budget}
        if action == 'task_status':
            if (req['phase'] not in ('started', 'stopped', 'reported') or req['reason'] not in
                    ('admitted', 'deadline', 'iteration_limit', 'runtime_error', 'no_report',
                     'final_report', 'execution_limit')):
                raise ValueError('invalid task status')
            old = self.db.execute('SELECT channel FROM task_status WHERE scope=?', (scope,)).fetchone()
            if old and old['channel'] != req['channel']:
                raise ValueError('task channel mismatch')
            now = time.time()
            deadline = req.get('deadline')
            if deadline is not None and (not isinstance(deadline, (int, float)) or deadline > now + 3600):
                raise ValueError('invalid task deadline')
            # A final answer or no-report fallback spends the independent
            # terminal direct-report reservation; status-only stop markers
            # remain recoverable and do not poison a later admitted execution.
            terminal = (req['phase'] == 'reported' and req['reason'] == 'final_report') or req['reason'] == 'no_report'
            model_iterations = req.get('model_iterations')
            budget = self.admit_transition(self.task_binding(scope)['task_id'],
                                           'terminal_report' if terminal else 'status', now,
                                           deadline=deadline, terminal_reason=req['reason'] if terminal else None,
                                           model_iterations=model_iterations)
            self.db.execute('INSERT INTO task_status VALUES (?,?,?,?,?,?,?) '
                            'ON CONFLICT(scope) DO UPDATE SET updated=excluded.updated, '
                            'phase=excluded.phase,reason=excluded.reason',
                            (scope, req['channel'], req['network'], now, now, req['phase'], req['reason']))
            self.prune_audit()
            self.db.commit()
            # No audit/read tool is exposed to the model. Return only broker-owned
            # task facts and actual job metadata.
            return {'jobs': [{'id': row['id'], 'state': row['state']} for row in
                             self.task_job_rows(self.task_binding(scope)['task_id'])], 'budget': budget}
        if action == 'reference':
            return self.references.read(req['key'])
        if action == 'job_inspect':
            job_id = req['id']
            if not isinstance(job_id, str) or not re.fullmatch(r'[a-f0-9]{32}', job_id):
                raise ValueError('invalid job id')
            job = self.load_job(req, job_id, 'saved job not found in this request')
            return self.result(job) | {'files': json.loads(job['files'])}
        if action in ('repo_inspect', 'repo_repair', 'repo_diagnose'):
            job_id = req['id']
            if not isinstance(job_id, str) or not re.fullmatch(r'[a-f0-9]{32}', job_id):
                raise ValueError('invalid job id')
            job = self.load_job(req, job_id, 'repository job not found in this request')
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
                source = self.load_snapshot(req, destination['snapshot_id'], require_active=False)
                changes, deleted = self.candidate_delta(source['files'], json.loads(job['files']))
                return Broker._handle(self, self.capability_envelope('repo_run', req['scope'], req['channel'], req['network'])
                                     | {k: req[k] for k in ('argv','title')}
                                     | {'action':'repo_run', 'snapshot_id':source['snapshot_id'],
                                        'changes':changes, 'delete':deleted},
                                     _diagnostic=True, _saved_snapshot=True)
            files = self.materialize_files(json.loads(job['files']), req['changes'], req['delete'])
            source = self.load_snapshot(req, destination['snapshot_id'], require_active=False)
            changes, deleted = self.candidate_delta(source['files'], files)
            # Re-enter the ordinary run path through the same snapshot materializer.
            return self._handle(self.capability_envelope('repo_run', req['scope'], req['channel'], req['network'])
                               | {k: req[k] for k in ('argv','title')}
                               | {'action': 'repo_run', 'snapshot_id': source['snapshot_id'],
                                  'changes': changes, 'delete': deleted}, _saved_snapshot=True)
        destination = None
        policy = None
        if action == 'repo_read':
            validate_destination(req['branch'], req['project'])
            return self.create_snapshot(req)
        if action == 'repo_run':
            snapshot = self.load_snapshot(req, req['snapshot_id'], require_active=not _saved_snapshot)
            current = self.repository.snapshot(snapshot['branch'], snapshot['project'])
            if any(current[key] != snapshot[key] for key in ('base_sha', 'tree_sha', 'exists', 'files')):
                raise ValueError('branch changed; read project and retest against the new base')
            files = self.materialize_files(snapshot['files'], req['changes'], req['delete'])
            candidate_changes, candidate_deleted = self.candidate_delta(snapshot['files'], files)
            destination = {k: snapshot[k] for k in ('branch','project','base_sha','tree_sha','exists','snapshot_id')}
            destination['candidate_material'] = bool(candidate_changes or candidate_deleted)
            if self.verification is not None:
                policy = self.verification.policy(snapshot)
                destination['verification_policy'] = self.verification.identity(policy)
            if _diagnostic:
                destination['diagnostic_only'] = True
        if action in ('run', 'repo_run'):
            files, argv = validate({'files': files if action == 'repo_run' else req['files'], 'argv': req['argv']},
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
                # Replaying a material passed request is an explicit retest
                # selection, not stale history: restore its durable candidate
                # position so direct publication cannot select later files.
                if action == 'repo_run' and old['state'] == 'passed' and destination is not None:
                    self.remember_repository_candidate(req, old['id'], destination)
                    self.db.commit()
                return self.result(old)
            task_id = self.task_binding(scope)['task_id']
            # The final shared execution belongs to a trusted complete repository
            # verification. Diagnostics and standalone code runs cannot consume it.
            trusted_verification = action == 'repo_run' and policy is not None and not _diagnostic
            if (self.verification is not None and not trusted_verification
                    and self.task_attempt_count(task_id) >= self.max_attempts() - 1):
                raise ValueError('last execution reserved for trusted project verification')
            now = time.time()
            # Retain a bounded journal; ambiguous submissions remain for manual reconciliation.
            # Retain checkpointed bundles as well as uncertain publications.
            self.prune_jobs(now)
            count = self.db.execute('SELECT COUNT(*) FROM jobs WHERE created>?', (now - 3600,)).fetchone()[0]
            if count >= 30:
                raise ValueError('global limit: 30 sandbox runs per hour')
            self.admit_transition(task_id, 'sandbox', now)
            job_id = uuid.uuid4().hex
            self.db.execute('INSERT INTO jobs VALUES (?,?,?,?,?,?,?,?,?)',
                            (job_id, scope, digest, now, json.dumps(files), title, '{}', 'running', None))
            self.consume_task_attempt(task_id, now)
            self.resource_checkpoint('job', job_id, req, 'running', now)
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
            if action == 'repo_run' and state == 'passed' and destination is not None:
                self.remember_repository_candidate(req, job_id, destination)
            self.resource_checkpoint('job', job_id, req, state)
            self.db.commit()
            return self.result(self.db.execute('SELECT * FROM jobs WHERE id=?', (job_id,)).fetchone())
        if action == 'repo_publish' and not _confirmed_publication:
            job = self.direct_repository_publication_job(req)
        else:
            job_id = req['id']
            if not isinstance(job_id, str) or not re.fullmatch(r'[a-f0-9]{32}', job_id):
                raise ValueError('invalid job id')
            job = self.load_job(req, job_id)
        job_id = job['id']
        repo_job = self.db.execute('SELECT destination FROM repo_jobs WHERE id=?', (job_id,)).fetchone()
        if bool(repo_job) != (action == 'repo_publish'):
            raise ValueError('job publication destination does not match tool')
        job_task_id = self.task_binding(job['scope'])['task_id']
        if any(row['state'] in ('publishing', 'uncertain') for row in
               self.task_job_rows(job_task_id)):
            raise ValueError('publication outcome requires operator reconciliation')
        if job['state'] == 'published':
            return self.result(job)
        if job['state'] != 'passed' or (not repo_job and job['created'] < time.time() - 900):
            raise ValueError('only a successful, recent, unsubmitted job can be published')
        if repo_job:
            destination = json.loads(repo_job['destination'])
            if destination.get('diagnostic_only'):
                raise ValueError('diagnostic jobs cannot be published; rerun the complete project suite')
            return self.publish_repository(req, job, destination,
                                           allow_after_final_report=_confirmed_publication or action == 'repo_publish')
        if not self.token.is_file():
            raise ValueError('Burt gist credential is not installed; ask the operator')
        if self.token.stat().st_mode & 0o077:
            raise ValueError('gist credential must have mode 600')
        # Check rate budget before crossing the irreversible network boundary.
        if self.publication_attempt_count() >= 10:
            raise ValueError('global limit: 10 gist submissions per day')
        task_id = self.task_binding(scope)['task_id']
        self.admit_transition(task_id, 'public_write', limit_message='limit: one gist submission per IRC request',
                              allow_after_final_report=_confirmed_publication)
        self.consume_task_publication(task_id, time.time())
        self.record_publication_attempt(job_id)
        self.db.execute("UPDATE jobs SET state='publishing' WHERE id=?", (job_id,))
        self.resource_checkpoint('publication', job_id, req, 'publishing')
        self.db.commit()
        payload = {'description': job['title'], 'public': True,
                   'files': {n: {'content': c} for n, c in json.loads(job['files']).items()}}
        try:
            url = self.post_gist(payload)
        except Exception:
            # A lost response may mean GitHub created the gist. Never blindly retry.
            self.db.execute("UPDATE jobs SET state='uncertain' WHERE id=?", (job_id,))
            self.admit_transition(self.task_binding(scope)['task_id'], 'terminal', terminal_reason='publication_uncertain')
            self.resource_checkpoint('publication', job_id, req, 'uncertain')
            self.db.commit()
            raise ValueError('gist submission failed or response was lost; operator reconciliation required; do not retry') from None
        self.db.execute("UPDATE jobs SET state='published',url=? WHERE id=?", (url, job_id))
        self.resource_checkpoint('publication', job_id, req, 'published')
        self.db.commit()
        return self.result(self.db.execute('SELECT * FROM jobs WHERE id=?', (job_id,)).fetchone())

    def publish_repository(self, req, job, destination, allow_after_final_report=False):
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
        if self.publication_attempt_count() >= 10:
            raise ValueError('global limit: 10 submissions per day')
        job_task_id = self.task_binding(job['scope'])['task_id']
        # A direct human request carries fresh bounded write authority while the
        # older task continues to own its immutable job and publication spend.
        authority_task_id = (self.task_binding(req['scope'])['task_id']
                             if allow_after_final_report else job_task_id)
        self.admit_transition(authority_task_id, 'public_write', allow_after_final_report=allow_after_final_report)
        if authority_task_id != job_task_id:
            self.consume_prior_task_publication_authority(job_task_id)
        self.consume_task_publication(job_task_id, time.time())
        self.record_publication_attempt(job['id'])
        self.db.execute("UPDATE jobs SET state='publishing' WHERE id=?", (job['id'],))
        self.resource_checkpoint('publication', job['id'], req, 'publishing')
        self.db.commit()
        try:
            url = self.repository.publish(snapshot, json.loads(job['files']), job['title'])
        except Exception:
            self.db.execute("UPDATE jobs SET state='uncertain' WHERE id=?", (job['id'],))
            self.admit_transition(self.task_binding(job['scope'])['task_id'], 'terminal', terminal_reason='publication_uncertain')
            self.resource_checkpoint('publication', job['id'], req, 'uncertain')
            self.db.commit()
            raise ValueError('repository submission failed or response lost; operator reconciliation required; do not retry') from None
        self.db.execute("UPDATE jobs SET state='published',url=? WHERE id=?", (url, job['id']))
        self.resource_checkpoint('publication', job['id'], req, 'published')
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

    def create_proposal(self, req):
        action, params, requester = req['proposal_action'], req['params'], req['requester']
        if action not in PROPOSAL_FIELDS or not isinstance(params, dict):
            raise ValueError('invalid action or fields')
        if set(params) != PROPOSAL_FIELDS[action]:
            raise ValueError('invalid action or fields')
        if not isinstance(requester, str) or not REQUESTER_IDENTITY.fullmatch(requester):
            raise ValueError('invalid requester identity')
        if action == 'reference':
            if not isinstance(params['key'], str) or params['key'] not in CATALOG:
                raise ValueError('unknown reference; available: ' + ', '.join(CATALOG))
        elif action == 'repo_read':
            validate_destination(params['branch'], params['project'])
        else:
            job_id = params['id']
            if not isinstance(job_id, str) or not re.fullmatch(r'[a-f0-9]{32}', job_id):
                raise ValueError('invalid job id')
            job = self.load_job(req, job_id, 'proposal action is not available for this request')
            repo_job = self.db.execute('SELECT id FROM repo_jobs WHERE id=?', (job_id,)).fetchone()
            if not job or job['state'] != 'passed' or bool(repo_job) != (action == 'repo_publish'):
                raise ValueError('proposal action is not available for this request')
        canonical = json.dumps(params, sort_keys=True, separators=(',', ':'), ensure_ascii=True)
        if len(canonical.encode()) > MAX_REQUEST:
            raise ValueError('encoded project response exceeds transport bound')
        now = time.time()
        existing = self.db.execute(
            'SELECT id,expires FROM proposals WHERE scope=? AND requester=? AND channel=? AND network=? '
            'AND action=? AND params=? AND state="proposed" AND expires>? ORDER BY created,id',
            (req['scope'], requester, req['channel'], req['network'], action, canonical, now)).fetchall()
        if len(existing) == 1:
            self.db.commit()
            return {'proposal_id': existing[0]['id'], 'state': 'proposed', 'action': action,
                    'expires_at': existing[0]['expires']}
        proposal_id = uuid.uuid4().hex
        self.db.execute('INSERT INTO proposals VALUES (?,?,?,?,?,?,?,?,?,?)',
                        (proposal_id, req['scope'], requester, req['channel'], req['network'],
                         action, canonical, now, now + PROPOSAL_TTL, 'proposed'))
        self.resource_checkpoint('proposal', proposal_id, req, 'proposed', now)
        self.prune_audit()
        self.db.commit()
        return {'proposal_id': proposal_id, 'state': 'proposed', 'action': action,
                'expires_at': now + PROPOSAL_TTL}

    def confirm_proposal(self, req):
        requester = req['requester']
        if not isinstance(requester, str) or not REQUESTER_IDENTITY.fullmatch(requester):
            raise ValueError('invalid requester identity')
        confirmed_at = req['confirmed_at']
        if (isinstance(confirmed_at, bool) or not isinstance(confirmed_at, (int, float))
                or not math.isfinite(confirmed_at)):
            raise ValueError('invalid confirmation timestamp')
        self.prune_audit()
        now = time.time()
        rows = self.db.execute('SELECT * FROM proposals WHERE requester=? AND channel=? AND network=? '
                               'AND state="proposed" AND expires>? AND created<? ORDER BY created,id',
                               (requester, req['channel'], req['network'], now, confirmed_at)).fetchall()
        if len(rows) != 1:
            self.db.commit()
            raise ValueError('proposal confirmation is missing or ambiguous')
        proposal = rows[0]
        if proposal['scope'] == req['scope']:
            self.db.commit()
            raise ValueError('proposal confirmation requires a later fresh request')
        action = proposal['action']
        # For publication the durable proposal, created only after the broker
        # verified a real passed job, is the authority anchor. Its immutable
        # params bind this later natural-language approval to that exact job
        # and fixed destination. The fresh reply must still explicitly express
        # publication intent: “read it” can approve a read, never a public write.
        if action in ('publish', 'repo_publish') and req.get('publication_confirmation') is not True:
            self.db.commit()
            raise ValueError('confirmation requires explicit publication intent')
        changed = self.db.execute('UPDATE proposals SET state="consumed" WHERE id=? AND state="proposed"',
                                  (proposal['id'],)).rowcount
        if changed == 1:
            self.resource_checkpoint('proposal', proposal['id'], req, 'consumed')
        if changed != 1:
            self.db.commit()
            raise ValueError('proposal confirmation is missing or ambiguous')
        self.db.commit()
        params = json.loads(proposal['params'])
        internal = (self.capability_envelope(action, proposal['scope'], proposal['channel'], proposal['network'])
                    | params | {'action': action})
        result = self._handle(internal, _confirmed_publication=action in ('publish', 'repo_publish'))
        result['proposal_id'] = proposal['id']
        result['confirmed_action'] = action
        return result

    def result(self, job):
        return {'id': job['id'], 'state': job['state'], 'result': json.loads(job['result']),
                'url': job['url'], 'files': list(json.loads(job['files'])),
                'attempts_remaining': max(0, self.max_attempts() - self.task_attempt_count(
                    self.task_binding(job['scope'])['task_id']))}


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
            result = getattr(exc, 'rejection', None)
            if result is None:
                result = self.server.broker.record_rejection(req, exc, raw=raw)
        except Exception as exc:
            result = getattr(exc, 'rejection', None)
            if result is None:
                result = self.server.broker.record_rejection(req, exc, raw=raw)
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
