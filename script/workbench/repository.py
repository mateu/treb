"""Fixed public repository. No checkout, shell, caller URLs, or host paths."""
import base64
import json
from pathlib import Path
import re
import time
import urllib.error
import urllib.request

REPO = 'burt-agent/workspace'
TOKEN = Path.home() / '.config/burt-publisher/github.token'
SHA = r'[a-f0-9]{40}'


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
    if total > 65536:
        raise ValueError('project exceeds 64 KiB')


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
                    or not isinstance(entry.get('size'), int) or entry['size'] > 65536
                    or len(files) >= 32):
                raise ValueError('project contains unsupported or oversized files')
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
        if len(json.dumps(result).encode()) > 90000:
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
