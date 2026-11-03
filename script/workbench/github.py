"""Account-scoped GitHub REST client for Burt's workbench broker.

The broker owns the credential and the HTTP transport. Callers supply only an
API path below https://api.github.com. Every path is normalized and checked
against a data-driven denylist before any network I/O, and the token is never
returned in a result, exception, or audit record.
"""
import base64
import hashlib
import http.client
import json
import os
from pathlib import Path
import re
import stat
import time
import urllib.error
import urllib.parse
import urllib.request

API_HOST = 'api.github.com'
API = 'https://' + API_HOST
DEFAULT_TOKEN = Path.home() / '.config/burt-github/token'
MAX_BODY = 256 * 1024
MAX_RESPONSE = 256 * 1024
MAX_ERROR_RESPONSE = 64 * 1024
MAX_QUERY_PARAMS = 32
MAX_COMMIT_FILES = 100
MAX_COMMIT_BYTES = 512 * 1024
MAX_DIRECTORY_ENTRIES = 500
REQUEST_TIMEOUT = 15
# Below the runtime's 45-second synchronous IPC alarm.
OPERATION_DEADLINE = 35
IDENTITY_TTL = 3600
READ_METHODS = frozenset(('GET', 'HEAD'))
WRITE_METHODS = frozenset(('POST', 'PUT', 'PATCH', 'DELETE'))
SHA = re.compile(r'[a-f0-9]{40}')
REPO = re.compile(r'[A-Za-z0-9_.-]{1,100}/[A-Za-z0-9_.-]{1,100}')
SEGMENT_SAFE = "-._~!$&'()*+,;=:@"

# Policy is data, matched against normalized lowercase path segments. `*`
# matches one segment and `**` matches zero or more. Alias routes
# (/repositories/{id}, /organizations/{id}) are rewritten before matching.
W = WRITE_METHODS
DENY_RULES = (
    (frozenset({'DELETE'}), 'repos/*/*', 'repository deletion'),
    (W, 'repos/*/*/transfer', 'repository transfer'),
    (W, 'repos/*/*/keys/**', 'deploy keys'),
    (W, 'repos/*/*/hooks/**', 'repository webhooks'),
    (W, 'repos/*/*/actions/secrets/**', 'repository secrets'),
    (W, 'repos/*/*/actions/variables/**', 'repository variables'),
    (W, 'repos/*/*/dependabot/secrets/**', 'repository secrets'),
    (W, 'repos/*/*/codespaces/secrets/**', 'repository secrets'),
    (W, 'repos/*/*/environments/*/secrets/**', 'repository secrets'),
    (W, 'repos/*/*/environments/*/variables/**', 'repository variables'),
    (W, 'repos/*/*/collaborators/**', 'repository collaborators'),
    (W, 'repos/*/*/invitations/**', 'repository invitations'),
    (W, 'user/keys/**', 'account keys'),
    (W, 'user/gpg_keys/**', 'account keys'),
    (W, 'user/ssh_signing_keys/**', 'account keys'),
    (W, 'user/emails/**', 'account emails'),
    (W, 'user/social_accounts/**', 'account profile'),
    (frozenset({'PATCH'}), 'user', 'account profile'),
    (W, 'user/codespaces/secrets/**', 'account secrets'),
    (W, 'user/installations/**', 'app installations'),
    (W, 'user/memberships/**', 'organization membership'),
    (W, 'authorizations/**', 'authorizations'),
    (W, 'applications/**', 'applications'),
    (W, 'app/**', 'applications'),
    (W, 'app-manifests/**', 'applications'),
    (W, 'installation/**', 'app installations'),
    (W, 'orgs/**', 'organization administration'),
    (W, 'teams/**', 'organization administration'),
    (W, 'enterprises/**', 'organization administration'),
    (W, 'admin/**', 'organization administration'),
)
# Ordinary account work that would otherwise match an organization rule.
ALLOW_RULES = (
    (frozenset({'POST'}), 'orgs/*/repos'),
)
DENY_REASONS = frozenset(reason for _, _, reason in DENY_RULES) | {'GraphQL mutation'}


class GitHubError(ValueError):
    """A policy or validation failure before, or without, a GitHub write."""


class GitHubPolicyError(GitHubError):
    def __init__(self, reason):
        super().__init__('GitHub operation is denied by broker policy: ' + reason)
        self.reason = reason


class GitHubHTTPError(GitHubError):
    """A definite 3xx/4xx GitHub response: GitHub decided; nothing is ambiguous."""
    def __init__(self, status, message, documentation_url, request_id, errors=None):
        super().__init__('GitHub rejected the request')
        self.status, self.message = status, message
        self.documentation_url, self.request_id, self.errors = documentation_url, request_id, errors

    def receipt(self):
        receipt = {'ok': False, 'status': self.status, 'message': self.message,
                   'documentation_url': self.documentation_url, 'request_id': self.request_id}
        if self.errors is not None:
            receipt['errors'] = self.errors
        return receipt


class GitHubTransportError(Exception):
    """A lost response or 5xx: the server may or may not have applied a write."""
    def __init__(self, method, path, status=None, request_id=None):
        super().__init__('GitHub transport failed')
        self.method, self.path, self.status, self.request_id = method, path, status, request_id


class Route:
    def __init__(self, method, segments, write):
        self.method, self.segments, self.write = method, segments, write
        self.wire = '/' + '/'.join(urllib.parse.quote(s, safe=SEGMENT_SAFE) for s in segments)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def _segments(path):
    if not isinstance(path, str) or not path.startswith('/') or path.startswith('//') or len(path) > 2048:
        raise GitHubError('GitHub path must be an API path beginning with a single /')
    if any(c in path for c in '?#\\') or any(ord(c) <= 0x20 or ord(c) == 0x7f for c in path):
        raise GitHubError('GitHub path must not contain a query, fragment, backslash, or whitespace')
    segments = []
    for raw in path.split('/')[1:]:
        if raw == '':
            continue  # duplicate or trailing slash
        try:
            segment = urllib.parse.unquote(raw, errors='strict')
        except UnicodeDecodeError:
            raise GitHubError('GitHub path has invalid percent-encoding') from None
        if (segment in ('.', '..') or any(c in segment for c in '/\\?#%')
                or any(ord(c) < 0x20 or ord(c) == 0x7f for c in segment)):
            raise GitHubError('GitHub path segment is not allowed')
        segments.append(segment)
    if not segments:
        raise GitHubError('GitHub path must name an API resource')
    return segments


def _policy_segments(segments):
    folded = [s.casefold() for s in segments]
    if folded[0] == 'repositories' and len(folded) >= 2:
        return ['repos', folded[1], folded[1]] + folded[2:]
    if folded[0] == 'organizations' and len(folded) >= 2:
        return ['orgs'] + folded[1:]
    return folded


def _match(pattern, segments):
    parts = pattern.split('/')
    def rec(i, j):
        if i == len(parts):
            return j == len(segments)
        if parts[i] == '**':
            return any(rec(i + 1, k) for k in range(j, len(segments) + 1))
        return j < len(segments) and parts[i] in ('*', segments[j]) and rec(i + 1, j + 1)
    return rec(0, 0)


def denial(method, segments):
    policy = _policy_segments(segments)
    if any(method in methods and _match(pattern, policy) for methods, pattern in ALLOW_RULES):
        return None
    for methods, pattern, reason in DENY_RULES:
        if method in methods and _match(pattern, policy):
            return reason
    return None


def classify(method, path, body=None):
    """Normalize one request and decide read/write before any network I/O."""
    method = method.upper() if isinstance(method, str) else ''
    if method not in READ_METHODS | WRITE_METHODS:
        raise GitHubError('GitHub method must be GET, HEAD, POST, PUT, PATCH, or DELETE')
    segments = _segments(path)
    reason = denial(method, segments)
    if reason:
        raise GitHubPolicyError(reason)
    write = method in WRITE_METHODS
    if [s.casefold() for s in segments] == ['graphql']:
        # GraphQL is admitted only as a read: queries cannot mutate, and
        # mutations would bypass the REST denylist.
        query = body.get('query') if isinstance(body, dict) else None
        if method != 'POST' or not isinstance(query, str) or re.search(r'mutation|subscription', query, re.I):
            raise GitHubPolicyError('GraphQL mutation')
        write = False
    if method in READ_METHODS and body is not None:
        raise GitHubError('GitHub GET/HEAD requests take no body')
    return Route(method, segments, write)


def encode_query(query):
    if query is None:
        return ''
    if not isinstance(query, dict) or len(query) > MAX_QUERY_PARAMS:
        raise GitHubError('GitHub query must be an object of at most 32 scalar parameters')
    items = []
    for key, value in query.items():
        if not isinstance(key, str) or not re.fullmatch(r'[A-Za-z0-9_.\[\]-]{1,64}', key):
            raise GitHubError('invalid GitHub query parameter name')
        if isinstance(value, bool):
            value = 'true' if value else 'false'
        elif isinstance(value, int):
            value = str(value)
        if not isinstance(value, str) or len(value) > 1024:
            raise GitHubError('GitHub query values must be short strings, integers, or booleans')
        items.append((key, value))
    return urllib.parse.urlencode(items)


def safe_file_path(path):
    if (not isinstance(path, str) or not 1 <= len(path) <= 1024 or path.startswith('/') or '\\' in path
            or any(ord(c) < 0x20 or ord(c) == 0x7f for c in path)):
        raise GitHubError('repository file paths must be relative, without traversal or .git')
    parts = path.split('/')
    if any(part in ('', '.', '..') or part.casefold() == '.git' for part in parts):
        raise GitHubError('repository file paths must be relative, without traversal or .git')
    return path


def safe_branch(name, label='branch'):
    if (not isinstance(name, str) or not re.fullmatch(r'[A-Za-z0-9._/-]{1,255}', name)
            or name.startswith(('/', '-', 'refs/')) or name.endswith(('/', '.', '.lock')) or '//' in name
            or any(part in ('.', '..') or part.startswith('.') for part in name.split('/')) or '..' in name):
        raise GitHubError('invalid ' + label + ' name')
    return name


def safe_repo(repo):
    if not isinstance(repo, str) or not REPO.fullmatch(repo) or any(p in ('.', '..') for p in repo.split('/')):
        raise GitHubError('repository must be owner/name')
    return repo


def body_digest(payload):
    return hashlib.sha256(payload).hexdigest() if payload is not None else None


def _request_id(headers):
    value = headers.get('X-GitHub-Request-Id', '') if headers else ''
    return value if isinstance(value, str) and re.fullmatch(r'[A-Za-z0-9_.:-]{1,128}', value) else None


def _pagination(headers):
    links = {}
    for part in (headers.get('Link', '') if headers else '').split(','):
        match = re.fullmatch(r'\s*<([^>]{1,2048})>\s*;\s*rel="(next|prev|first|last)"\s*', part)
        if not match:
            continue
        url = urllib.parse.urlsplit(match.group(1))
        if url.scheme != 'https' or url.netloc != API_HOST:
            continue
        links[match.group(2)] = {'path': url.path,
                                 'query': dict(urllib.parse.parse_qsl(url.query, keep_blank_values=True))}
    return links or None


def redact(value, secret):
    if not secret:
        return value
    if isinstance(value, str):
        return value.replace(secret, '[redacted]')
    if isinstance(value, list):
        return [redact(item, secret) for item in value]
    if isinstance(value, dict):
        return {redact(k, secret): redact(v, secret) for k, v in value.items()}
    return value


class GitHub:
    def __init__(self, token_file=None, opener=None, clock=time.monotonic):
        self.token_file = Path(token_file or os.environ.get('BURT_GITHUB_TOKEN_FILE') or DEFAULT_TOKEN)
        self.opener = opener or urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
        self.clock = clock
        self.secret = None
        self.identity = None

    def token(self):
        path = self.token_file
        try:
            info = os.lstat(path)
            parent = os.stat(path.parent)
        except FileNotFoundError:
            raise GitHubError('GitHub credential is not installed; ask the operator') from None
        if not stat.S_ISREG(info.st_mode):
            raise GitHubError('GitHub credential must be a regular file, not a symlink')
        if info.st_mode & 0o077 or info.st_uid != os.getuid() or parent.st_mode & 0o022:
            raise GitHubError('GitHub credential requires an owner-only mode 600 file in a private directory')
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        try:
            opened = os.fstat(fd)
            if (opened.st_dev, opened.st_ino) != (info.st_dev, info.st_ino):
                raise GitHubError('GitHub credential changed while reading')
            raw = os.read(fd, 4097)
        finally:
            os.close(fd)
        token = raw.decode('ascii', errors='replace').strip()
        if len(raw) > 4096 or not re.fullmatch(r'[A-Za-z0-9_]{20,255}', token):
            raise GitHubError('GitHub credential is malformed')
        self.secret = token
        return token

    def redact(self, value):
        return redact(value, self.secret)

    def request(self, method, path, query=None, body=None, audit=None, deadline=None, max_body=MAX_BODY):
        route = classify(method, path, body)
        qs = encode_query(query)
        payload = None if body is None else json.dumps(body, separators=(',', ':'), ensure_ascii=False).encode()
        if payload is not None and len(payload) > max_body:
            raise GitHubError('GitHub request body exceeds bound')
        url = API + route.wire + ('?' + qs if qs else '')
        if urllib.parse.urlsplit(url).netloc != API_HOST:
            raise GitHubError('GitHub path must be an API path beginning with a single /')
        timeout = REQUEST_TIMEOUT
        if deadline is not None:
            timeout = min(timeout, deadline - self.clock())
            if timeout < 1:
                raise GitHubError('GitHub operation deadline exceeded before sending')
        headers = {'Authorization': 'token ' + self.token(), 'Accept': 'application/vnd.github+json',
                   'X-GitHub-Api-Version': '2022-11-28', 'User-Agent': 'burt-workbench'}
        if payload is not None:
            headers['Content-Type'] = 'application/json'
        req = urllib.request.Request(url, data=payload, method=route.method, headers=headers)
        status, response_headers = None, None
        def record(status, request_id):
            if audit:
                audit(route.method, route.wire, status, request_id, body_digest(payload))
        try:
            with self.opener.open(req, timeout=timeout) as response:
                status, response_headers = response.status, response.headers
                raw = response.read(MAX_RESPONSE + 1)
        except urllib.error.HTTPError as exc:
            status, response_headers = exc.code, exc.headers
            request_id = _request_id(response_headers)
            record(status, request_id)
            if not isinstance(status, int) or status >= 500:
                raise GitHubTransportError(route.method, route.wire, status, request_id) from None
            try:
                data = json.loads(exc.read(MAX_ERROR_RESPONSE).decode('utf-8'))
            except Exception:
                data = {}
            data = data if isinstance(data, dict) else {}
            message = data.get('message') if isinstance(data.get('message'), str) else None
            if 300 <= status < 400:
                message = 'GitHub redirect was not followed'
            message = ''.join(c for c in re.sub(r'\s+', ' ', message or 'GitHub rejected the request')
                              if c.isprintable())[:1000]
            doc = data.get('documentation_url')
            doc = doc if isinstance(doc, str) and doc.startswith('https://docs.github.com/') and len(doc) <= 300 else None
            errors = data.get('errors')
            if errors is not None and len(json.dumps(errors)) > 4000:
                errors = None
            raise GitHubHTTPError(status, self.redact(message), doc, request_id, self.redact(errors)) from None
        except (urllib.error.URLError, http.client.HTTPException, OSError, ValueError):
            request_id = _request_id(response_headers)
            record(status, request_id)
            raise GitHubTransportError(route.method, route.wire, status, request_id) from None
        request_id = _request_id(response_headers)
        record(status, request_id)
        result = {'ok': 200 <= status < 300, 'status': status, 'request_id': request_id, 'write': route.write}
        if len(raw) > MAX_RESPONSE:
            result.update(data=None, truncated=True,
                          hint='response exceeds 256 KiB; use per_page/page, a narrower path, or github_read')
        else:
            try:
                result['data'] = json.loads(raw.decode('utf-8')) if raw else None
            except (UnicodeDecodeError, ValueError):
                result['text'] = raw.decode('utf-8', errors='replace')
        pagination = _pagination(response_headers)
        if pagination:
            result['pagination'] = pagination
        remaining = response_headers.get('X-RateLimit-Remaining') if response_headers else None
        if isinstance(remaining, str) and remaining.isdigit():
            result['rate_limit_remaining'] = int(remaining)
        result['_scopes'] = response_headers.get('X-OAuth-Scopes', '') if response_headers else ''
        return self.redact(result)

    def api(self, method, path, query=None, body=None, audit=None):
        result = self.request(method, path, query, body, audit=audit)
        result.pop('_scopes', None)
        data = result.get('data')
        # Contents API writes create commits; surface a canonical receipt URL.
        commit = data.get('commit') if isinstance(data, dict) else None
        repo = '/'.join(_segments(path)[1:3]) if _segments(path)[0].casefold() == 'repos' else None
        if (result['write'] and result['ok'] and isinstance(commit, dict) and isinstance(commit.get('sha'), str)
                and SHA.fullmatch(commit['sha']) and repo and REPO.fullmatch(repo)):
            result['commit_url'] = f'https://github.com/{repo}/commit/{commit["sha"]}'
        # Promote only canonical artifact identifiers into broker receipt metadata.
        if result['write'] and result['ok'] and isinstance(data, dict):
            url = data.get('html_url', '')
            if isinstance(url, str) and re.fullmatch(
                    r'https://(?:github\.com/burt-agent/[\w.-]+/pull/[1-9][0-9]*|gist\.github\.com/burt-agent/[a-f0-9]+)', url):
                result['artifact_url'] = url
        return result

    def whoami(self, audit=None):
        digest = hashlib.sha256(self.token().encode()).hexdigest()
        cached = self.identity
        if not cached or cached['digest'] != digest or self.clock() - cached['at'] > IDENTITY_TTL:
            response = self.request('GET', '/user', audit=audit)
            data = response.get('data')
            if not isinstance(data, dict) or not isinstance(data.get('login'), str):
                raise GitHubError('GitHub identity response is invalid')
            cached = self.identity = {
                'digest': digest, 'at': self.clock(), 'request_id': response['request_id'],
                'login': data['login'], 'id': data.get('id'), 'type': data.get('type'),
                'scopes': sorted(s.strip() for s in response['_scopes'].split(',') if s.strip())}
        return {k: v for k, v in cached.items() if k not in ('digest', 'at')}

    def read(self, repo, ref, path, audit=None):
        safe_repo(repo)
        if not isinstance(ref, str) or not 1 <= len(ref) <= 255 or any(ord(c) <= 0x20 for c in ref):
            raise GitHubError('invalid ref')
        if not isinstance(path, str):
            raise GitHubError('repository file paths must be relative, without traversal or .git')
        path = path.strip('/')
        if path:
            safe_file_path(path)
        target = f'/repos/{repo}/contents' + ('/' + '/'.join(urllib.parse.quote(p, safe='') for p in path.split('/'))
                                              if path else '')
        response = self.request('GET', target, {'ref': ref}, audit=audit)
        data = response.get('data')
        receipt = {'ok': True, 'repo': repo, 'ref': ref, 'request_id': response['request_id']}
        if isinstance(data, list):
            entries = [{'name': x.get('name'), 'path': x.get('path'), 'type': x.get('type'),
                        'size': x.get('size'), 'sha': x.get('sha')} for x in data if isinstance(x, dict)]
            return receipt | {'type': 'dir', 'path': path, 'entries': entries[:MAX_DIRECTORY_ENTRIES],
                              'truncated': len(entries) > MAX_DIRECTORY_ENTRIES or bool(response.get('truncated'))}
        if not isinstance(data, dict):
            raise GitHubError('GitHub contents response is invalid or exceeds bound')
        meta = {'type': data.get('type'), 'path': data.get('path', path), 'sha': data.get('sha'), 'size': data.get('size')}
        if data.get('type') == 'symlink':
            return receipt | meta | {'target': data.get('target')}
        if data.get('type') != 'file':
            return receipt | meta
        if data.get('encoding') != 'base64' or not isinstance(data.get('content'), str):
            return receipt | meta | {'content': None, 'note': 'file too large for the contents API; use git/blobs'}
        try:
            content = base64.b64decode(data['content'], validate=False)
        except ValueError:
            raise GitHubError('GitHub file response is invalid') from None
        try:
            return receipt | meta | {'encoding': 'utf-8', 'content': content.decode('utf-8')}
        except UnicodeDecodeError:
            return receipt | meta | {'encoding': 'base64', 'content': base64.b64encode(content).decode()}

    @staticmethod
    def validate_commit(repo, branch, base_ref, files, message):
        safe_repo(repo)
        safe_branch(branch)
        if base_ref is not None and not SHA.fullmatch(base_ref if isinstance(base_ref, str) else ''):
            safe_branch(base_ref, 'base_ref')
        if not isinstance(message, str) or not message.strip() or len(message) > 10000:
            raise GitHubError('commit message must be 1..10000 characters')
        if not isinstance(files, dict) or not 1 <= len(files) <= MAX_COMMIT_FILES:
            raise GitHubError('files must map 1..100 repository paths to content or null')
        entries, total = [], 0
        for path, value in files.items():
            safe_file_path(path)
            mode = '100644'
            if isinstance(value, dict):
                if set(value) - {'content', 'mode'} or 'content' not in value:
                    raise GitHubError('file objects take content and optional mode')
                mode = value.get('mode', '100644')
                value = value['content']
                if mode not in ('100644', '100755'):
                    raise GitHubError('file mode must be 100644 or 100755')
            if value is not None and not isinstance(value, str):
                raise GitHubError('file content must be a UTF-8 string, or null to delete')
            total += len(value.encode('utf-8')) if value is not None else 0
            entries.append((path, mode, value))
        if total > MAX_COMMIT_BYTES:
            raise GitHubError('commit content exceeds 512 KiB')
        return entries

    def _prepare_commit(self, call, repo, git, branch, base_ref, create_branch, entries, message, expected_parent=None, require_new_branch=False, expected_exists=None):
        try:
            parent = call('GET', f'{git}/ref/heads/{branch}')['data']['object']['sha']
            created = False
        except GitHubHTTPError as exc:
            if exc.status == 404 and expected_exists is True:
                raise GitHubError('branch moved since the tested snapshot; re-read and re-test') from None
            if exc.status != 404 or not create_branch:
                raise
            if base_ref is None:
                base_ref = call('GET', f'/repos/{repo}')['data']['default_branch']
                safe_branch(base_ref, 'base_ref')
            if SHA.fullmatch(base_ref):
                parent = base_ref
            else:
                parent = call('GET', f'{git}/ref/heads/{base_ref}')['data']['object']['sha']
            created = True
        if not isinstance(parent, str) or not SHA.fullmatch(parent):
            raise GitHubError('GitHub returned an invalid branch head')
        if expected_exists is not None and expected_exists != (not created):
            raise GitHubError('branch moved since the tested snapshot; re-read and re-test')
        if require_new_branch and not created:
            raise GitHubError('target must match snapshot branch or be a new branch from the tested base')
        if expected_parent is not None and parent != expected_parent:
            raise GitHubError('branch moved since the tested snapshot; re-read and re-test')
        if expected_exists is False and created:
            fallback = call('GET', f'{git}/ref/heads/main')['data']['object']['sha']
            if fallback != expected_parent:
                raise GitHubError('branch moved since the tested snapshot; re-read and re-test')
        base_tree = call('GET', f'{git}/commits/{parent}')['data']['tree']['sha']
        tree = [{'path': path, 'mode': mode, 'type': 'blob', 'content': value} if value is not None
                else {'path': path, 'mode': mode, 'type': 'blob', 'sha': None} for path, mode, value in entries]
        tree_sha = call('POST', f'{git}/trees', {'base_tree': base_tree, 'tree': tree},
                        max_body=4 * MAX_COMMIT_BYTES)['data']['sha']
        commit_sha = call('POST', f'{git}/commits', {'message': message, 'tree': tree_sha, 'parents': [parent]},
                          max_body=4 * MAX_COMMIT_BYTES)['data']['sha']
        if not all(isinstance(s, str) and SHA.fullmatch(s) for s in (tree_sha, commit_sha)):
            raise GitHubError('GitHub returned an invalid commit')
        return parent, created, tree_sha, commit_sha

    def commit_files(self, repo, branch, base_ref, files, message, create_branch=True, audit=None, expected_parent=None, require_new_branch=False, expected_exists=None):
        """One atomic commit: unreferenced objects first, then a single ref write."""
        entries = self.validate_commit(repo, branch, base_ref, files, message)
        deadline = self.clock() + OPERATION_DEADLINE
        git = f'/repos/{repo}/git'
        def call(method, path, body=None, **kw):
            return self.request(method, path, body=body, audit=audit, deadline=deadline, **kw)
        try:
            parent, created, tree_sha, commit_sha = self._prepare_commit(call, repo, git, branch, base_ref,
                                                                        create_branch, entries, message, expected_parent, require_new_branch, expected_exists)
        except (KeyError, TypeError, IndexError):
            raise GitHubError('GitHub returned an unexpected response; no branch was changed') from None
        # The only reference-changing request. Objects above are unreachable
        # until it succeeds, so a failure before it leaves the branch untouched.
        try:
            if created:
                ref = call('POST', f'{git}/refs', {'ref': 'refs/heads/' + branch, 'sha': commit_sha})
            else:
                ref = call('PATCH', f'{git}/refs/heads/{branch}', {'sha': commit_sha, 'force': False})
        except GitHubTransportError as exc:
            exc.ref_write = True
            raise
        return {'ok': True, 'write': True, 'repo': repo, 'branch': branch, 'created_branch': created,
                'parent_sha': parent, 'tree_sha': tree_sha, 'commit_sha': commit_sha,
                'commit_url': f'https://github.com/{repo}/commit/{commit_sha}',
                'files_written': sum(1 for _, _, v in entries if v is not None),
                'files_deleted': sum(1 for _, _, v in entries if v is None),
                'request_id': ref.get('request_id')}
