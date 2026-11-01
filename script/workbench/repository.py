"""Fixed public repository. No checkout, shell, caller URLs, or host paths."""
import base64
import json
from pathlib import Path
import re
import time
import urllib.error
import urllib.request

from runner import MAX_INPUT_BYTES, MAX_JSON_BYTES, InputSizeError

REPO = 'burt-agent/workspace'
TOKEN = Path.home() / '.config/burt-publisher/github.token'
SHA = r'[a-f0-9]{40}'


class GitHubHTTPRejected(ValueError):
    """A bounded, safe-to-report GitHub 4xx response after a write attempt."""
    def __init__(self, status, message, request_id):
        super().__init__('GitHub rejected the pull request operation')
        self.status = status
        self.message = message
        self.request_id = request_id

    @classmethod
    def from_http_error(cls, error):
        status = error.code
        if not isinstance(status, int) or not 400 <= status < 500:
            raise ValueError('not a deterministic GitHub HTTP rejection')
        try:
            body = error.read(8193)
            data = json.loads(body.decode('utf-8'))
            message = data.get('message') if isinstance(data, dict) else None
        except (UnicodeDecodeError, ValueError, json.JSONDecodeError):
            message = None
        if not isinstance(message, str):
            message = 'GitHub rejected the request'
        message = re.sub(r'\s+', ' ', message).strip()
        message = ''.join(char for char in message if char.isprintable())[:240]
        if not message:
            message = 'GitHub rejected the request'
        headers = error.headers or {}
        request_id = headers.get('X-GitHub-Request-Id', '')
        request_id = request_id if isinstance(request_id, str) and re.fullmatch(r'[A-Za-z0-9_.:-]{1,128}', request_id) else None
        return cls(status, message, request_id)

    def audit_reason(self):
        suffix = ' [request ' + self.request_id + ']' if self.request_id else ''
        return 'GitHub HTTP ' + str(self.status) + ': ' + self.message + suffix


class PullRequestUncertain(ValueError):
    def __init__(self, pull):
        super().__init__('pull request submission outcome is uncertain; inspect before retrying')
        self.pull = pull


def validate_pull_request(branch, expected_head_sha=None):
    if not isinstance(branch, str) or not re.fullmatch(r'burt/[a-z0-9][a-z0-9-]{0,59}', branch):
        raise ValueError('use a burt/<lowercase-slug> head branch for a pull request')
    if expected_head_sha is not None and (not isinstance(expected_head_sha, str)
                                          or not re.fullmatch(SHA, expected_head_sha)):
        raise ValueError('invalid expected branch head')


def validate_destination(branch, project, base_sha=None):
    if not isinstance(branch, str) or not re.fullmatch(r'burt/[a-z0-9][a-z0-9-]{0,59}', branch):
        raise ValueError('use a burt/<lowercase-slug> branch; main is never writable')
    if not isinstance(project, str) or not re.fullmatch(r'[a-z0-9][a-z0-9-]{0,59}', project):
        raise ValueError('invalid project slug')
    if base_sha is not None and (not isinstance(base_sha, str) or not re.fullmatch(SHA, base_sha)):
        raise ValueError('invalid base commit')


def validate_files(files):
    if not isinstance(files, dict) or not 1 <= len(files) <= 32:
        raise ValueError('project requires 1..32 text files')
    total = 0
    for name, content in files.items():
        if (not isinstance(name, str) or len(name) > 160
                or not all(re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,99}', p) for p in name.split('/'))
                or not isinstance(content, str) or '\x00' in content):
            raise ValueError('use safe relative text paths; no hidden files, traversal or NUL')
        if any(other.startswith(name + '/') for other in files):
            raise ValueError('file/directory collision')
        total += len(content.encode('utf-8'))
    if total > MAX_INPUT_BYTES:
        raise InputSizeError(total, 'project')


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


class Repository:
    def __init__(self, token=TOKEN):
        self.token = Path(token)
        self.deadline = None

    def api(self, path, payload=None, method=None):
        if (not self.token.is_file() or self.token.is_symlink()
                or self.token.stat().st_mode & 0o077 or self.token.parent.stat().st_mode & 0o077):
            raise ValueError('repository credential requires private directory and mode 600')
        headers = {'Authorization': 'Bearer ' + self.token.read_text().strip(),
                   'Accept': 'application/vnd.github+json', 'User-Agent': 'burt-workbench',
                   'Content-Type': 'application/json'}
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
        request = urllib.request.Request('https://api.github.com' + path, headers=headers,
                    data=None if payload is None else json.dumps(payload).encode(), method=method)
        remaining = 8 if self.deadline is None else min(8, self.deadline - time.monotonic())
        if remaining <= 0:
            raise ValueError('repository operation deadline exceeded')
        with opener.open(request, timeout=remaining) as response:
            raw = response.read(1500001)
        if len(raw) > 1500000:
            raise ValueError('repository response exceeds bound')
        return json.loads(raw)

    def verify(self):
        if self.api('/user').get('login') != 'burt-agent':
            raise ValueError('repository credential must belong to burt-agent')
        repo = self.api('/repos/' + REPO)
        if repo.get('full_name') != REPO or repo.get('private') is not False or not repo.get('permissions', {}).get('push'):
            raise ValueError('expected public writable burt-agent/workspace')

    def pull_request(self, number):
        if not isinstance(number, int) or isinstance(number, bool) or number < 1:
            raise ValueError('invalid pull request number')
        self.deadline = time.monotonic() + 14
        self.verify()
        return self._validated_pull(self.api('/repos/' + REPO + '/pulls/' + str(number)))

    @staticmethod
    def _validated_pull(data):
        if not isinstance(data, dict):
            raise ValueError('invalid pull request response')
        number, head, base, url = data.get('number'), data.get('head', {}), data.get('base', {}), data.get('html_url', '')
        if (not isinstance(number, int) or not isinstance(head, dict) or not isinstance(base, dict)
                or not re.fullmatch(r'burt/[a-z0-9][a-z0-9-]{0,59}', head.get('ref', ''))
                or not re.fullmatch(SHA, head.get('sha', '')) or data.get('state') not in ('open', 'closed')
                or base.get('ref') != 'main' or base.get('repo', {}).get('full_name') != REPO
                or head.get('repo', {}).get('full_name') != REPO
                or not re.fullmatch(r'https://github\.com/burt-agent/workspace/pull/[1-9][0-9]*', url)):
            raise ValueError('unexpected pull request response')
        return {'number': number, 'branch': head['ref'], 'head_sha': head['sha'], 'base': 'main',
                'state': data['state'], 'merged': bool(data.get('merged')), 'mergeable': data.get('mergeable'), 'url': url}

    def _find_pull(self, branch, expected_head_sha):
        data = self.api('/repos/' + REPO + '/pulls?state=all&head=burt-agent:' + branch + '&base=main')
        if not isinstance(data, list) or len(data) > 100:
            raise ValueError('invalid pull request list response')
        matches = [self._validated_pull(item) for item in data]
        matches = [item for item in matches if item['branch'] == branch and item['head_sha'] == expected_head_sha]
        if len(matches) > 1:
            raise ValueError('ambiguous pull request response')
        return matches[0] if matches else None

    def find_pull_request(self, branch, expected_head_sha):
        """Read exactly one fixed-repository PR identity without a mutation."""
        validate_pull_request(branch, expected_head_sha)
        self.deadline = time.monotonic() + 14
        self.verify()
        return self._find_pull(branch, expected_head_sha)

    def create_pull_request(self, branch, expected_head_sha, title):
        validate_pull_request(branch, expected_head_sha)
        if not isinstance(title, str) or not 1 <= len(title) <= 200 or '\x00' in title:
            raise ValueError('invalid pull request title')
        self.deadline = time.monotonic() + 16
        self.verify()
        prefix = '/repos/' + REPO
        head = self.api(prefix + '/git/ref/heads/' + branch).get('object', {}).get('sha', '')
        if head != expected_head_sha:
            raise ValueError('branch head changed; reread and retest before creating a pull request')
        existing = self._find_pull(branch, expected_head_sha)
        if existing:
            return existing | {'created': False}
        try:
            created = self.api(prefix + '/pulls', {'title': title, 'head': branch, 'base': 'main'}, 'POST')
        except urllib.error.HTTPError as exc:
            if 400 <= exc.code < 500:
                raise GitHubHTTPRejected.from_http_error(exc) from None
            created = None
        except Exception:
            created = None
        if created is None:
            # The write crossed GitHub's irreversible boundary. A second
            # outage while reconciling must remain an uncertainty, never turn
            # into a retryable transport failure that permits another write.
            try:
                existing = self._find_pull(branch, expected_head_sha)
            except Exception:
                existing = None
            if existing:
                return existing | {'created': False}
            raise ValueError('pull request submission outcome is uncertain; inspect before retrying') from None
        result = self._validated_pull(created)
        if result['branch'] != branch or result['head_sha'] != expected_head_sha:
            # GitHub accepted the write, but its resource no longer matches the
            # precondition we checked. Carry the actual identity so the broker
            # can durably reconcile it and stop further writes.
            raise PullRequestUncertain(result)
        return result | {'created': True}

    def merge_pull_request(self, number, expected_head_sha):
        current = self.pull_request(number)
        validate_pull_request(current['branch'], expected_head_sha)
        if current['head_sha'] != expected_head_sha:
            raise ValueError('pull request head changed; inspect and retest before merging')
        if current['merged']:
            return current | {'merged_now': False}
        if current['state'] != 'open' or current['mergeable'] is False:
            raise ValueError('pull request is not mergeable under normal GitHub protections')
        try:
            merged = self.api('/repos/' + REPO + '/pulls/' + str(number) + '/merge',
                              {'sha': expected_head_sha, 'merge_method': 'squash'}, 'PUT')
        except urllib.error.HTTPError as exc:
            if 400 <= exc.code < 500:
                raise GitHubHTTPRejected.from_http_error(exc) from None
            merged = None
        except Exception:
            merged = None
        if merged is None:
            # As above, preserve the uncertain write receipt if the readback
            # cannot be reached; the caller must inspect before retrying.
            try:
                reconciled = self.pull_request(number)
            except Exception:
                reconciled = None
            if reconciled and reconciled['merged'] and reconciled['head_sha'] == expected_head_sha:
                return reconciled | {'merged_now': False}
            raise ValueError('pull request merge outcome is uncertain; inspect before retrying') from None
        if not isinstance(merged, dict) or merged.get('merged') is not True or not re.fullmatch(SHA, merged.get('sha', '')):
            raise ValueError('pull request was not merged under normal GitHub protections')
        # A validated merge response is authoritative even if the optional
        # readback is unavailable. Preserve it rather than losing a confirmed
        # outcome to a later transport error.
        return current | {'state': 'closed', 'merged': True, 'merged_now': True, 'merge_sha': merged['sha']}

    def snapshot(self, branch, project):
        validate_destination(branch, project)
        self.deadline = time.monotonic() + 14
        self.verify()
        prefix = '/repos/' + REPO
        exists = True
        try:
            ref = self.api(prefix + '/git/ref/heads/' + branch)
        except urllib.error.HTTPError as exc:
            if exc.code != 404:
                raise
            exists = False
            ref = self.api(prefix + '/git/ref/heads/main')
        sha = ref.get('object', {}).get('sha', '')
        if not re.fullmatch(SHA, sha):
            raise ValueError('invalid branch head')
        commit = self.api(prefix + '/git/commits/' + sha)
        tree_sha = commit.get('tree', {}).get('sha', '')
        if not re.fullmatch(SHA, tree_sha):
            raise ValueError('invalid commit tree')
        tree = self.api(prefix + '/git/trees/' + tree_sha + '?recursive=1')
        if tree.get('truncated') or not isinstance(tree.get('tree'), list) or len(tree['tree']) > 5000:
            raise ValueError('repository tree exceeds bound')
        root = 'projects/' + project
        files = {}
        for entry in tree['tree']:
            name = entry.get('path', '')
            # Reject symlink/submodule/file at a directory prefix too.
            if name in ('projects', root) and entry.get('type') != 'tree':
                raise ValueError('project directory is not a tree')
            if not name.startswith(root + '/') or entry.get('type') == 'tree':
                continue
            if (entry.get('mode') != '100644' or entry.get('type') != 'blob'
                    or not re.fullmatch(SHA, entry.get('sha', ''))
                    or not isinstance(entry.get('size'), int)
                    or len(files) >= 32):
                raise ValueError('project contains unsupported or oversized files')
            if entry['size'] > MAX_INPUT_BYTES:
                raise InputSizeError(sum(len(v.encode('utf-8')) for v in files.values()) + entry['size'], 'project')
            relative = name[len(root)+1:]
            validate_files({relative: ''})
            blob = self.api(prefix + '/git/blobs/' + entry['sha'])
            if blob.get('encoding') != 'base64':
                raise ValueError('unsupported blob encoding')
            content = base64.b64decode(blob['content']).decode('utf-8')
            files[relative] = content
            validate_files(files)
        result = dict(repository=REPO, branch=branch, project=project, base_sha=sha,
                      exists=exists, tree_sha=tree_sha, files=files)
        if len(json.dumps(result).encode()) > MAX_JSON_BYTES:
            raise ValueError('encoded project response exceeds transport bound')
        return result

    def publish(self, snapshot, files, title):
        validate_destination(snapshot['branch'], snapshot['project'], snapshot['base_sha'])
        validate_files(files)
        self.deadline = time.monotonic() + 16
        # Fresh identity proof immediately before writes. Files are immutable inputs
        # loaded by Broker, not generated files or caller-selected host paths.
        self.verify()
        prefix = '/repos/' + REPO
        root = 'projects/' + snapshot['project'] + '/'
        entries = [{'path': root+n, 'mode':'100644', 'type':'blob', 'content':c}
                   for n,c in sorted(files.items())]
        entries += [{'path':root+n, 'mode':'100644', 'type':'blob', 'sha':None}
                    for n in sorted(set(snapshot['files']) - set(files))]
        tree = self.api(prefix + '/git/trees', {'base_tree':snapshot['tree_sha'], 'tree':entries})
        if not re.fullmatch(SHA, tree.get('sha', '')):
            raise ValueError('invalid created tree')
        commit = self.api(prefix + '/git/commits', {'message':title, 'tree':tree['sha'],
                            'parents':[snapshot['base_sha']]})
        sha = commit.get('sha', '')
        if not re.fullmatch(SHA, sha):
            raise ValueError('invalid created commit')
        branch = snapshot['branch']
        if snapshot['exists']:
            # Never force: concurrent branch changes reject this sibling commit.
            result = self.api(prefix + '/git/refs/heads/' + branch, {'sha':sha, 'force':False}, 'PATCH')
        else:
            result = self.api(prefix + '/git/refs', {'ref':'refs/heads/' + branch, 'sha':sha})
        if result.get('ref') != 'refs/heads/' + branch or result.get('object', {}).get('sha') != sha:
            raise ValueError('unexpected updated ref')
        return 'https://github.com/' + REPO + '/commit/' + sha
