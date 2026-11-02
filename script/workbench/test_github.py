"""Account-scoped GitHub tools: policy, authorization, redaction, receipts (mocked transport)."""
import hashlib
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
import urllib.error
import urllib.parse
from unittest.mock import patch

import broker
from broker import Broker
import github
from github import GitHub, GitHubError, GitHubPolicyError, classify, safe_file_path

TOKEN = 'ghp_' + 'S3cr3tT0kenValue' * 2
SHA1, SHA2, SHA3, SHA4 = 'a' * 40, 'b' * 40, 'c' * 40, 'd' * 40


class Response:
    def __init__(self, status=200, data=None, headers=None, raw=None):
        self.status = status
        self.headers = {'X-GitHub-Request-Id': 'REQ-%d' % status} | (headers or {})
        self.raw = raw if raw is not None else (b'' if data is None else json.dumps(data).encode())

    def read(self, n=-1):
        return self.raw if n < 0 else self.raw[:n]

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


def http_error(status, data=None, headers=None):
    body = io.BytesIO(json.dumps(data or {}).encode())
    return urllib.error.HTTPError('https://api.github.com/x', status, 'error',
                                  {'X-GitHub-Request-Id': 'ERR-%d' % status} | (headers or {}), body)


class FakeOpener:
    """Scripted transport. Routes map (METHOD, path) to a Response, exception, or callable."""
    def __init__(self, routes=None):
        self.routes = dict(routes or {})
        self.calls = []

    def open(self, req, timeout=None):
        url = urllib.parse.urlsplit(req.full_url)
        assert url.scheme == 'https' and url.netloc == 'api.github.com', req.full_url
        body = json.loads(req.data) if req.data else None
        self.calls.append({'method': req.get_method(), 'path': url.path, 'query': url.query, 'body': body,
                           'raw': req.data, 'headers': dict(req.header_items()), 'timeout': timeout})
        outcome = self.routes.get((req.get_method(), url.path), Response(200, {}))
        if callable(outcome) and not isinstance(outcome, Response):
            outcome = outcome(req)
        if isinstance(outcome, BaseException):
            raise outcome
        return outcome


def token_file(directory, value=TOKEN, mode=0o600):
    path = Path(directory) / 'token'
    path.write_text(value + '\n')
    path.chmod(mode)
    return path


DENIED = [
    ('DELETE', '/repos/o/r'),
    ('POST', '/repos/o/r/transfer'),
    ('POST', '/repos/o/r/keys'), ('DELETE', '/repos/o/r/keys/1'),
    ('POST', '/repos/o/r/hooks'), ('PATCH', '/repos/o/r/hooks/1'), ('POST', '/repos/o/r/hooks/1/pings'),
    ('PUT', '/repos/o/r/actions/secrets/X'), ('DELETE', '/repos/o/r/actions/secrets/X'),
    ('POST', '/repos/o/r/actions/variables'), ('PATCH', '/repos/o/r/actions/variables/X'),
    ('PUT', '/repos/o/r/dependabot/secrets/X'),
    ('PUT', '/repos/o/r/codespaces/secrets/X'),
    ('PUT', '/repos/o/r/environments/prod/secrets/X'),
    ('POST', '/repos/o/r/environments/prod/variables'),
    ('PUT', '/repos/o/r/collaborators/u'), ('DELETE', '/repos/o/r/collaborators/u'),
    ('PATCH', '/repos/o/r/invitations/1'), ('DELETE', '/repos/o/r/invitations/1'),
    ('POST', '/user/keys'), ('DELETE', '/user/keys/1'),
    ('POST', '/user/gpg_keys'), ('POST', '/user/ssh_signing_keys'),
    ('POST', '/user/emails'), ('DELETE', '/user/emails'), ('PATCH', '/user/emails'),
    ('POST', '/user/social_accounts'), ('DELETE', '/user/social_accounts'),
    ('PATCH', '/user'),
    ('PUT', '/user/codespaces/secrets/X'),
    ('PUT', '/user/installations/1/repositories/2'), ('DELETE', '/user/installations/1/repositories/2'),
    ('PATCH', '/user/memberships/orgs/o'),
    ('POST', '/authorizations'), ('DELETE', '/authorizations/1'),
    ('DELETE', '/applications/1/token'), ('POST', '/applications/1/token'),
    ('POST', '/app/installations/1/access_tokens'), ('POST', '/app-manifests/c/conversions'),
    ('DELETE', '/installation/token'), ('POST', '/admin/users'),
    ('PATCH', '/orgs/o'), ('PUT', '/orgs/o/memberships/u'), ('DELETE', '/orgs/o/members/u'),
    ('POST', '/orgs/o/invitations'), ('PUT', '/orgs/o/outside_collaborators/u'),
    ('POST', '/orgs/o/hooks'), ('PUT', '/orgs/o/actions/secrets/X'), ('POST', '/orgs/o/teams'),
    ('PUT', '/teams/1/members/u'), ('PATCH', '/enterprises/e/settings'),
]
ALLOWED = [
    ('GET', '/repos/o/r'), ('PATCH', '/repos/o/r'), ('GET', '/repos/o/r/hooks'), ('GET', '/repos/o/r/keys'),
    ('GET', '/repos/o/r/collaborators'), ('GET', '/repos/o/r/actions/secrets'),
    ('POST', '/repos/o/r/issues'), ('POST', '/repos/o/r/issues/1/comments'), ('POST', '/repos/o/r/pulls'),
    ('PUT', '/repos/o/r/pulls/1/merge'), ('PUT', '/repos/o/r/contents/README.md'),
    ('DELETE', '/repos/o/r/git/refs/heads/topic'), ('DELETE', '/repos/o/r/issues/comments/1'),
    ('POST', '/repos/o/r/actions/workflows/ci.yml/dispatches'), ('POST', '/repos/o/r/actions/runs/1/rerun'),
    ('POST', '/repos/o/r/forks'), ('POST', '/repos/o/r/hookshot'), ('PUT', '/repos/o/r/keystone'),
    ('POST', '/repos/o/r/issues/1/labels'), ('POST', '/repos/o/r/transfers'),
    ('GET', '/user'), ('GET', '/user/keys'), ('GET', '/user/emails'), ('POST', '/user/repos'),
    ('PUT', '/user/starred/o/r'), ('PUT', '/user/following/u'), ('POST', '/gists'), ('PATCH', '/gists/1'),
    ('PUT', '/notifications'), ('PATCH', '/notifications/threads/1'),
    ('GET', '/orgs/o/members'), ('POST', '/orgs/o/repos'), ('GET', '/user/installations'),
]


class PolicyTests(unittest.TestCase):
    def test_every_denylist_entry_is_blocked(self):
        for method, path in DENIED:
            with self.subTest(method=method, path=path), self.assertRaises(GitHubPolicyError):
                classify(method, path)

    def test_close_but_allowed_paths_pass(self):
        for method, path in ALLOWED:
            with self.subTest(method=method, path=path):
                route = classify(method, path, {} if method not in ('GET', 'HEAD') else None)
                self.assertEqual(route.write, method not in ('GET', 'HEAD'))

    def test_every_rule_has_coverage(self):
        policy = [github._policy_segments(github._segments(p)) for _, p in DENIED]
        for methods, pattern, _ in github.DENY_RULES:
            self.assertTrue(any(github._match(pattern, segments) for segments in policy), pattern)

    def test_normalization_bypass_attempts_are_blocked(self):
        blocked = [
            ('DELETE', '/REPOS/O/R'), ('DELETE', '/repos//o/r'), ('DELETE', '/repos/o/r/'),
            ('DELETE', '/repos/o//r//'), ('POST', '/repos/o/r/HOOKS'), ('post', '/repos/o/r/hooks'),
            ('POST', '/repos/o/r/%68ooks'), ('POST', '/repos/o/r/%48OOKS'), ('PUT', '/repos/o/r/actions/%73ecrets/X'),
            ('DELETE', '/repositories/12345'), ('POST', '/repositories/12345/hooks'),
            ('PUT', '/repositories/1/environments/prod/secrets/X'), ('PUT', '/organizations/9/members/u'),
            ('PATCH', '/USER'), ('PATCH', '/user/'), ('POST', '/User/Keys'),
            ('POST', '/%75ser/keys'), ('POST', '/user/%6Beys'), ('PATCH', '/%55SER'),
            ('POST', '/repos/o/r/%74ransfer'), ('DELETE', '/%72epos/o/r'),
        ]
        for method, path in blocked:
            with self.subTest(path=path), self.assertRaises(GitHubPolicyError):
                classify(method, path)
        malformed = ['/repos/o/r/x/../hooks', '/repos/o/r/./hooks', '/repos/o/r/%2e%2e/hooks', '/repos/o/r/%2E/hooks',
                     '/repos/o%2Fr/hooks', '/repos/o/r%2fhooks', '/repos/o/r/%252e%252e', '/repos/o/r/hooks?x=1',
                     '/repos/o/r/hooks%3Fx=1', '/repos/o/r/hooks#frag', '/repos/o/r/hooks%23', '/repos/o\\r/hooks',
                     '/repos/o/r/hooks%5c', '/repos/o/r/ho oks', '/repos/o/r/hooks\n', '/repos/o/r/%00',
                     '/repos/o/r/%ff', '/repos/o/r/%', '/', '//']
        for path in malformed:
            with self.subTest(path=path), self.assertRaises(GitHubError):
                classify('POST', path, {})

    def test_absolute_urls_and_host_changes_are_rejected(self):
        for path in ('https://api.github.com/user', 'http://evil.example/user', '//evil.example/user',
                     'api.github.com/user', 'user', '', None, 7):
            with self.subTest(path=path), self.assertRaises(GitHubError):
                classify('GET', path)
        route = classify('GET', '/@evil.example/user')
        self.assertEqual(urllib.parse.urlsplit(github.API + route.wire).netloc, 'api.github.com')

    def test_graphql_queries_are_reads_and_mutations_denied(self):
        self.assertFalse(classify('POST', '/graphql', {'query': '{ viewer { login } }'}).write)
        self.assertFalse(classify('POST', '/GraphQL/', {'query': 'query { viewer { login } }'}).write)
        for query in ('mutation { deleteRepository }', 'MUTATION{x}', 'query{a} mutation{b}', 'subscription{x}'):
            with self.subTest(query=query), self.assertRaises(GitHubPolicyError):
                classify('POST', '/graphql', {'query': query})
        for method, body in (('GET', None), ('POST', None), ('POST', {'query': 5})):
            with self.assertRaises(GitHubPolicyError):
                classify(method, '/graphql', body)

    def test_methods_and_bodies(self):
        for method in ('TRACE', 'OPTIONS', 'CONNECT', '', None):
            with self.assertRaises(GitHubError):
                classify(method, '/user')
        with self.assertRaises(GitHubError):
            classify('GET', '/user', {'x': 1})

    def test_query_validation(self):
        self.assertEqual(github.encode_query({'per_page': 100, 'page': 2, 'all': True, 'q': 'a b'}),
                         'per_page=100&page=2&all=true&q=a+b')
        for query in ([('a', 1)], {'a': [1]}, {'a': {'b': 1}}, {'a b': 1}, {'a': 'x' * 1025},
                      {str(i): i for i in range(33)}):
            with self.subTest(query=query), self.assertRaises(GitHubError):
                github.encode_query(query)

    def test_file_paths(self):
        for path in ('README.md', 'a/b/c.txt', '.github/workflows/ci.yml', 'dir/.gitignore'):
            self.assertEqual(safe_file_path(path), path)
        for path in ('../x', 'a/../b', '/abs', 'a//b', 'a/./b', '.git', '.git/config', 'a/.GIT/x', 'a\\b',
                     'a/', '', 'x\x00', 'x' * 1025, None):
            with self.subTest(path=path), self.assertRaises(GitHubError):
                safe_file_path(path)


class ClientTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        os.chmod(self.tmp.name, 0o700)
        self.token_path = token_file(self.tmp.name)
        self.opener = FakeOpener()
        self.client = GitHub(self.token_path, opener=self.opener)

    def test_token_file_requirements(self):
        self.assertEqual(self.client.token(), TOKEN)
        self.token_path.chmod(0o640)
        with self.assertRaises(GitHubError): self.client.token()
        self.token_path.chmod(0o600)
        link = Path(self.tmp.name) / 'link'
        link.symlink_to(self.token_path)
        with self.assertRaises(GitHubError): GitHub(link).token()
        with self.assertRaises(GitHubError): GitHub(Path(self.tmp.name) / 'missing').token()
        os.mkdir(Path(self.tmp.name) / 'dir')
        with self.assertRaises(GitHubError): GitHub(Path(self.tmp.name) / 'dir').token()
        bad = token_file(Path(self.tmp.name) / 'dir', 'not a token!')
        with self.assertRaises(GitHubError): GitHub(bad).token()
        os.chmod(self.tmp.name, 0o777)
        try:
            with self.assertRaises(GitHubError): self.client.token()
        finally:
            os.chmod(self.tmp.name, 0o700)
        with patch.dict(os.environ, {'BURT_GITHUB_TOKEN_FILE': str(self.token_path)}):
            self.assertEqual(GitHub().token_file, self.token_path)

    def test_default_token_location(self):
        with patch.dict(os.environ, {}, clear=True):
            self.assertEqual(GitHub().token_file, Path.home() / '.config/burt-github/token')

    def test_request_uses_api_host_token_header_and_no_retry(self):
        self.opener.routes[('POST', '/repos/o/r/issues')] = urllib.error.URLError('reset')
        with self.assertRaises(github.GitHubTransportError) as caught:
            self.client.api('POST', '/repos/o/r/issues', body={'title': 't'})
        self.assertEqual(len(self.opener.calls), 1)
        self.assertEqual(self.opener.calls[0]['headers']['Authorization'], 'token ' + TOKEN)
        self.assertNotIn(TOKEN, repr(caught.exception) + str(caught.exception) + repr(vars(caught.exception)))

    def test_pagination_and_query(self):
        link = ('<https://api.github.com/repositories/1/issues?per_page=2&page=3>; rel="next", '
                '<https://evil.example/x?page=9>; rel="last"')
        self.opener.routes[('GET', '/repos/o/r/issues')] = Response(200, [{'n': 1}], {'Link': link})
        result = self.client.api('GET', '/repos/o/r/issues', {'per_page': 2, 'page': 2})
        self.assertEqual(self.opener.calls[0]['query'], 'per_page=2&page=2')
        self.assertEqual(result['pagination'], {'next': {'path': '/repositories/1/issues',
                                                         'query': {'per_page': '2', 'page': '3'}}})
        self.assertNotIn('_scopes', result)
        follow = result['pagination']['next']
        self.client.api('GET', follow['path'], follow['query'])
        self.assertEqual(self.opener.calls[1]['path'], '/repositories/1/issues')

    def test_size_bounds(self):
        with self.assertRaises(GitHubError):
            self.client.api('POST', '/gists', body={'x': 'y' * github.MAX_BODY})
        self.assertEqual(self.opener.calls, [])
        self.opener.routes[('GET', '/big')] = Response(200, raw=b'[' + b'1,' * github.MAX_RESPONSE + b'1]')
        result = self.client.api('GET', '/big')
        self.assertTrue(result['truncated'])
        self.assertIsNone(result['data'])

    def test_redaction_of_echoed_token(self):
        self.opener.routes[('GET', '/echo')] = Response(200, {'value': 'x' + TOKEN, TOKEN: [TOKEN]})
        self.opener.routes[('POST', '/echo')] = http_error(422, {'message': 'bad ' + TOKEN, 'errors': [TOKEN]})
        result = self.client.api('GET', '/echo')
        self.assertNotIn(TOKEN, json.dumps(result))
        with self.assertRaises(github.GitHubHTTPError) as caught:
            self.client.api('POST', '/echo', body={})
        self.assertNotIn(TOKEN, json.dumps(caught.exception.receipt()) + str(caught.exception))

    def test_redirects_are_not_followed(self):
        self.opener.routes[('GET', '/repos/o/r/tarball')] = http_error(302, headers={'Location': 'https://x?token=t'})
        with self.assertRaises(github.GitHubHTTPError) as caught:
            self.client.api('GET', '/repos/o/r/tarball')
        self.assertEqual(caught.exception.receipt()['status'], 302)
        self.assertNotIn('token=t', json.dumps(caught.exception.receipt()))

    def test_whoami_caches_identity_and_scopes(self):
        self.opener.routes[('GET', '/user')] = Response(200, {'login': 'some-account', 'id': 7, 'type': 'User'},
                                                        {'X-OAuth-Scopes': 'repo, workflow, gist'})
        first = self.client.whoami()
        self.assertEqual(first, {'login': 'some-account', 'id': 7, 'type': 'User', 'request_id': 'REQ-200',
                                 'scopes': ['gist', 'repo', 'workflow']})
        self.assertEqual(self.client.whoami(), first)
        self.assertEqual(len(self.opener.calls), 1)

    def test_read_file_dir_and_binary(self):
        import base64
        self.opener.routes[('GET', '/repos/o/r/contents/docs/a%20b.md')] = Response(200, {
            'type': 'file', 'path': 'docs/a b.md', 'sha': SHA1, 'size': 2, 'encoding': 'base64',
            'content': base64.b64encode('hé'.encode()).decode()})
        self.opener.routes[('GET', '/repos/o/r/contents')] = Response(200, [
            {'name': 'x', 'path': 'x', 'type': 'file', 'size': 1, 'sha': SHA2, 'url': 'drop'}])
        self.opener.routes[('GET', '/repos/o/r/contents/bin')] = Response(200, {
            'type': 'file', 'path': 'bin', 'encoding': 'base64', 'content': base64.b64encode(b'\xff\x00').decode()})
        result = self.client.read('o/r', 'main', 'docs/a b.md')
        self.assertEqual((result['content'], result['encoding']), ('hé', 'utf-8'))
        self.assertEqual(self.opener.calls[0]['query'], 'ref=main')
        root = self.client.read('o/r', 'main', '')
        self.assertEqual(root['entries'], [{'name': 'x', 'path': 'x', 'type': 'file', 'size': 1, 'sha': SHA2}])
        self.assertEqual(self.client.read('o/r', SHA1, 'bin')['encoding'], 'base64')
        # GitHub line-wraps Base64 file content at 60 columns.
        text = 'line of text\n' * 40
        encoded = base64.b64encode(text.encode()).decode()
        wrapped = '\n'.join(encoded[i:i + 60] for i in range(0, len(encoded), 60)) + '\n'
        self.opener.routes[('GET', '/repos/o/r/contents/wrapped.txt')] = Response(200, {
            'type': 'file', 'path': 'wrapped.txt', 'encoding': 'base64', 'content': wrapped})
        self.assertEqual(self.client.read('o/r', 'main', 'wrapped.txt')['content'], text)
        for repo, path in (('o/r/x', 'a'), ('../r', 'a'), ('o/r', '../x'), ('o/r', '.git/config')):
            with self.assertRaises(GitHubError):
                self.client.read(repo, 'main', path)


class BrokerGitHubTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        os.chmod(self.tmp.name, 0o700)
        self.b = Broker(Path(self.tmp.name) / 'state')
        self.addCleanup(self.b.db.close)
        self.opener = FakeOpener({('GET', '/user'): Response(200, {'login': 'acct', 'id': 1, 'type': 'User'},
                                                             {'X-OAuth-Scopes': 'repo'})})
        self.b.github = GitHub(token_file(self.tmp.name), opener=self.opener)
        env = patch.dict(os.environ, {'BURT_GITHUB_WRITERS': 'MaTeU, Other[x] ', 'BURT_GITHUB_WRITE_CAP': ''})
        env.start()
        self.addCleanup(env.stop)

    def env(self, action, requester='mateu', scope='e' * 64, **fields):
        return {'action': action, 'scope': scope, 'requester': requester, 'channel': '#ai',
                'network': 'irc.perl.org'} | fields

    def api(self, method, path, requester='mateu', scope='e' * 64, **fields):
        return self.b.handle(self.env('github_api', requester, scope, method=method, path=path, **fields))

    def audit(self):
        return [dict(r) for r in self.b.db.execute('SELECT * FROM github_requests ORDER BY seq')]

    def test_reads_for_any_trusted_requester_and_writes_only_for_writers(self):
        self.assertTrue(self.api('GET', '/repos/o/r', requester='visitor')['ok'])
        with self.assertRaisesRegex(ValueError, 'allowlisted trusted requester') as caught:
            self.api('POST', '/repos/o/r/issues', requester='visitor', body={'title': 't'})
        self.assertEqual((caught.exception.rejection['code'], caught.exception.rejection['message']),
                         ('github_policy', 'GitHub writes require an allowlisted trusted requester'))
        with self.assertRaisesRegex(ValueError, 'allowlisted trusted requester'):
            self.b.handle(self.env('github_commit_files', 'visitor', repo='o/r', branch='b', files={'a': 'b'},
                                   message='m'))
        self.assertEqual([c['method'] for c in self.opener.calls], ['GET'])
        self.assertTrue(self.api('POST', '/repos/o/r/issues', body={'title': 't'})['ok'])
        self.assertTrue(self.api('POST', '/repos/o/r/issues', requester='other{x}', body={'title': 't'})['ok'])
        graphql = self.api('POST', '/graphql', requester='visitor', body={'query': '{ viewer { login } }'})
        self.assertTrue(graphql['ok'])
        self.assertFalse(graphql['write'])
        with patch.dict(os.environ, {'BURT_GITHUB_WRITERS': ''}):
            with self.assertRaisesRegex(ValueError, 'allowlisted'):
                self.api('PUT', '/user/starred/o/r')
        with patch.dict(os.environ, {}, clear=True):
            with self.assertRaisesRegex(ValueError, 'allowlisted'):
                self.api('PUT', '/user/starred/o/r')

    def test_requester_cannot_be_supplied_through_tool_arguments(self):
        for extra in ({'writer': 'mateu'}, {'trusted_requester': 'mateu'}, {'token': 'x'}, {'url': 'https://x'}):
            with self.subTest(extra=extra), self.assertRaisesRegex(ValueError, 'invalid action or fields'):
                self.api('POST', '/repos/o/r/issues', requester='visitor', **extra)
        self.assertEqual(self.opener.calls, [])

    def test_whoami_reports_identity_writer_status_and_budget(self):
        result = self.b.handle(self.env('github_whoami', 'visitor'))
        self.assertEqual((result['login'], result['scopes'], result['requester'], result['requester_can_write'],
                          result['write_cap'], result['writes_used']), ('acct', ['repo'], 'visitor', False, 60, 0))
        self.assertTrue(self.b.handle(self.env('github_whoami'))['requester_can_write'])

    def test_denied_operations_never_reach_github_and_report_policy(self):
        with self.assertRaises(GitHubPolicyError) as caught:
            self.api('DELETE', '/Repos/o/r/')
        self.assertEqual(self.opener.calls, [])
        rejection = caught.exception.rejection
        self.assertEqual((rejection['code'], rejection['message'], rejection['action']),
                         ('github_policy', 'GitHub operation is denied by broker policy: repository deletion',
                          'github_api'))
        self.assertEqual(self.b.db.execute('SELECT COUNT(*) FROM github_write_budgets').fetchone()[0], 0)

    def test_write_transport_failure_is_uncertain_not_retried_and_not_blocking(self):
        self.opener.routes[('POST', '/repos/o/r/issues')] = TimeoutError('timed out')
        result = self.api('POST', '/repos/o/r/issues', body={'title': 't'})
        self.assertEqual({k: result[k] for k in ('ok', 'outcome_uncertain', 'retried', 'method', 'path', 'request_id')},
                         {'ok': False, 'outcome_uncertain': True, 'retried': False, 'method': 'POST',
                          'path': '/repos/o/r/issues', 'request_id': None})
        self.assertIn('verify', result['instruction'])
        self.assertEqual(len(self.opener.calls), 1)
        self.opener.routes[('PATCH', '/repos/o/r/issues/1')] = http_error(502, {'message': 'bad gateway'})
        result = self.api('PATCH', '/repos/o/r/issues/1', body={'state': 'closed'})
        self.assertTrue(result['outcome_uncertain'])
        self.assertEqual((result['status'], result['request_id']), (502, 'ERR-502'))
        self.assertEqual(len(self.opener.calls), 2)
        for table in ('pending_pull_request_operations', 'publication_attempts'):
            self.assertEqual(self.b.db.execute(f'SELECT COUNT(*) FROM {table}').fetchone()[0], 0)
        budget = self.b.db.execute('SELECT * FROM task_phase_budgets WHERE task_id=?', ('e' * 64,)).fetchone()
        self.assertIsNone(budget['terminal_reason'])
        self.assertEqual(budget['public_writes'], 0)
        self.assertTrue(self.api('GET', '/repos/o/r/issues/1')['ok'])

    def test_read_failures_are_not_uncertain(self):
        self.opener.routes[('GET', '/repos/o/r')] = http_error(503)
        result = self.api('GET', '/repos/o/r')
        self.assertEqual((result['ok'], result['error'], result['status']), (False, 'github_unavailable', 503))
        self.assertNotIn('outcome_uncertain', result)

    def test_4xx_passthrough(self):
        self.opener.routes[('POST', '/repos/o/r/pulls')] = http_error(422, {
            'message': 'Validation Failed', 'documentation_url': 'https://docs.github.com/rest/pulls',
            'errors': [{'resource': 'PullRequest', 'code': 'custom', 'message': 'exists'}]})
        result = self.api('POST', '/repos/o/r/pulls', body={'head': 'x', 'base': 'main'})
        self.assertEqual(result, {'ok': False, 'status': 422, 'message': 'Validation Failed',
                                  'documentation_url': 'https://docs.github.com/rest/pulls', 'request_id': 'ERR-422',
                                  'errors': [{'resource': 'PullRequest', 'code': 'custom', 'message': 'exists'}],
                                  'write': True, 'writes_remaining': 59})
        self.opener.routes[('GET', '/repos/o/missing')] = http_error(404, {'message': 'Not Found',
                                                                         'documentation_url': 'https://evil/x'})
        result = self.api('GET', '/repos/o/missing')
        self.assertEqual((result['status'], result['message'], result['documentation_url']), (404, 'Not Found', None))

    def test_write_cap_is_per_task_and_separate_from_publication_budget(self):
        with patch.dict(os.environ, {'BURT_GITHUB_WRITE_CAP': '2'}):
            self.assertEqual(self.api('PUT', '/user/starred/o/r')['writes_remaining'], 1)
            self.opener.routes[('PUT', '/user/starred/o/x')] = urllib.error.URLError('lost')
            self.assertEqual(self.api('PUT', '/user/starred/o/x')['writes_remaining'], 0)
            with self.assertRaises(ValueError) as caught:
                self.api('PUT', '/user/starred/o/y')
            self.assertEqual(caught.exception.rejection['code'], 'budget_exhausted')
            self.assertTrue(self.api('GET', '/user/starred')['ok'])
            self.assertEqual(self.api('PUT', '/user/starred/o/r', scope='f' * 64)['writes_remaining'], 1)
            # The counter follows broker task identity, not the requester, and
            # survives a resume that binds a fresh scope to the same task.
            self.b.db.execute('INSERT INTO task_scopes VALUES (?,?,?,?,?,?)',
                              ('9' * 64, 'e' * 64, 'mateu', '#ai', 'irc.perl.org', 0))
            with self.assertRaises(ValueError):
                self.api('PUT', '/user/starred/o/z', scope='9' * 64)
        self.assertEqual(self.b.github_write_cap(), 60)
        self.assertEqual(self.b.db.execute('SELECT public_writes FROM task_phase_budgets WHERE task_id=?',
                                           ('e' * 64,)).fetchone()[0], 0)

    def test_audit_rows_have_metadata_digest_and_no_secrets(self):
        body = {'title': 'secret body ' + TOKEN}
        self.api('POST', '/repos//o/r/issues/', body=body)
        row = self.audit()[-1]
        raw = self.opener.calls[-1]['raw']
        self.assertEqual({k: row[k] for k in ('task_id', 'requester', 'channel', 'action', 'method', 'path',
                                              'status', 'request_id', 'body_sha256')},
                         {'task_id': 'e' * 64, 'requester': 'mateu', 'channel': '#ai', 'action': 'github_api',
                          'method': 'POST', 'path': '/repos/o/r/issues', 'status': 200, 'request_id': 'REQ-200',
                          'body_sha256': hashlib.sha256(raw).hexdigest()})
        dump = json.dumps(self.audit()) + json.dumps([dict(r) for r in self.b.db.execute('SELECT * FROM rejections')])
        self.assertNotIn(TOKEN, dump)
        self.assertNotIn('secret body', dump)
        with patch('broker.GITHUB_AUDIT_LIMIT', 3):
            for i in range(5):
                self.api('GET', f'/repos/o/r/issues/{i}')
            self.assertEqual(len(self.audit()), 3)
        with patch('broker.time.time', return_value=10 ** 10):
            self.b.prune_audit()
        self.assertEqual(self.audit(), [])

    def test_results_and_rejections_redact_the_token(self):
        self.opener.routes[('GET', '/echo')] = Response(200, {'leak': TOKEN})
        self.assertNotIn(TOKEN, json.dumps(self.api('GET', '/echo')))
        self.opener.routes[('POST', '/echo')] = http_error(500, {'message': TOKEN})
        self.assertNotIn(TOKEN, json.dumps(self.api('POST', '/echo', body={})))
        self.b.github.token_file.chmod(0o644)
        with self.assertRaises(GitHubError) as caught:
            self.api('GET', '/user/repos')
        self.assertNotIn(TOKEN, json.dumps(caught.exception.rejection) + str(caught.exception))

    def commit(self, requester='mateu', **fields):
        return self.b.handle(self.env('github_commit_files', requester, **({
            'repo': 'o/r', 'branch': 'topic', 'files': {'a.txt': 'new', 'bin/run': {'content': '#!/bin/sh\n',
                                                                                    'mode': '100755'},
                                                     'old.txt': None},
            'message': 'Update files'} | fields)))

    def git_routes(self, branch_exists=True):
        r = self.opener.routes
        r[('GET', '/repos/o/r/git/ref/heads/topic')] = (Response(200, {'object': {'sha': SHA1}}) if branch_exists
                                                       else http_error(404, {'message': 'Not Found'}))
        r[('GET', '/repos/o/r')] = Response(200, {'default_branch': 'trunk'})
        r[('GET', '/repos/o/r/git/ref/heads/trunk')] = Response(200, {'object': {'sha': SHA4}})
        r[('GET', f'/repos/o/r/git/commits/{SHA1}')] = Response(200, {'tree': {'sha': SHA2}})
        r[('GET', f'/repos/o/r/git/commits/{SHA4}')] = Response(200, {'tree': {'sha': SHA2}})
        r[('POST', '/repos/o/r/git/trees')] = Response(201, {'sha': SHA3})
        r[('POST', '/repos/o/r/git/commits')] = Response(201, {'sha': 'e' * 40})
        r[('PATCH', '/repos/o/r/git/refs/heads/topic')] = Response(200, {'object': {'sha': 'e' * 40}})
        r[('POST', '/repos/o/r/git/refs')] = Response(201, {'object': {'sha': 'e' * 40}})

    def test_commit_files_existing_branch_with_delete(self):
        self.git_routes()
        result = self.commit()
        self.assertEqual([(c['method'], c['path']) for c in self.opener.calls], [
            ('GET', '/repos/o/r/git/ref/heads/topic'), ('GET', f'/repos/o/r/git/commits/{SHA1}'),
            ('POST', '/repos/o/r/git/trees'), ('POST', '/repos/o/r/git/commits'),
            ('PATCH', '/repos/o/r/git/refs/heads/topic')])
        self.assertEqual(self.opener.calls[2]['body'], {'base_tree': SHA2, 'tree': [
            {'path': 'a.txt', 'mode': '100644', 'type': 'blob', 'content': 'new'},
            {'path': 'bin/run', 'mode': '100755', 'type': 'blob', 'content': '#!/bin/sh\n'},
            {'path': 'old.txt', 'mode': '100644', 'type': 'blob', 'sha': None}]})
        self.assertEqual(self.opener.calls[3]['body'], {'message': 'Update files', 'tree': SHA3, 'parents': [SHA1]})
        self.assertEqual(self.opener.calls[4]['body'], {'sha': 'e' * 40, 'force': False})
        self.assertEqual((result['ok'], result['created_branch'], result['commit_sha'], result['commit_url'],
                          result['files_written'], result['files_deleted'], result['writes_remaining']),
                         (True, False, 'e' * 40, 'https://github.com/o/r/commit/' + 'e' * 40, 2, 1, 59))
        self.assertEqual(len(self.audit()), 5)

    def test_commit_files_creates_missing_branch_from_default_or_base_ref(self):
        self.git_routes(branch_exists=False)
        result = self.commit()
        self.assertTrue(result['created_branch'])
        self.assertEqual(result['parent_sha'], SHA4)
        self.assertEqual(self.opener.calls[-1]['path'], '/repos/o/r/git/refs')
        self.assertEqual(self.opener.calls[-1]['body'], {'ref': 'refs/heads/topic', 'sha': 'e' * 40})
        self.assertNotIn('PATCH', [c['method'] for c in self.opener.calls])
        self.opener.calls.clear()
        result = self.commit(base_ref=SHA1)
        self.assertEqual(result['parent_sha'], SHA1)
        self.assertNotIn(('GET', '/repos/o/r'), [(c['method'], c['path']) for c in self.opener.calls])
        self.opener.calls.clear()
        result = self.commit(create_branch=False)
        self.assertEqual((result['ok'], result['status']), (False, 404))
        self.assertEqual(len(self.opener.calls), 1)

    def _tested_job(self, *, passed=True):
        from test_repository import FakeRepository
        self.b.repository = FakeRepository()
        self.b.repository.exists = True
        self.b.repository.files = {'old.txt': 'old', 'keep.txt': 'keep'}
        self.b.execute = lambda job: {'reason': 'exited', 'exit_code': 0 if passed else 1, 'output': 'suite result'}
        snapshot = self.b.handle(self.env('repo_read', branch='burt/dictionary', project='dictionary'))
        return self.b.handle(self.env('repo_run', snapshot_id=snapshot['snapshot_id'],
            changes={'new.txt': 'tested'}, delete=['old.txt'], argv=['/bin/sh', '-c', 'true'], title='suite'))

    def _tested_commit(self, job, **fields):
        return self.b.handle(self.env('github_commit_files', repo='burt-agent/workspace',
            branch='burt/dictionary', from_job=job['id'], message='Tested commit') | fields)

    def _tested_routes(self, *, exists=True, parent=SHA1):
        self.git_routes()
        for (method, path), response in list(self.opener.routes.items()):
            if path.startswith('/repos/o/r/'):
                self.opener.routes[(method, path.replace('/repos/o/r/', '/repos/burt-agent/workspace/').replace('/heads/topic', '/heads/burt/dictionary'))] = response
        self.opener.routes[('GET', '/repos/burt-agent/workspace/git/ref/heads/burt/dictionary')] = (
            Response(200, {'object': {'sha': parent}}) if exists else http_error(404))

    def test_from_job_maps_exact_tested_bundle_and_snapshot_deletions(self):
        job = self._tested_job()
        self._tested_routes()
        receipt = self._tested_commit(job)
        self.assertTrue(receipt['tested'])
        self.assertEqual(receipt['job_id'], job['id'])
        self.assertEqual(receipt['test_argv'], ['/bin/sh', '-c', 'true'])
        self.assertEqual(receipt['test_summary']['exit_code'], 0)
        tree = next(c['body']['tree'] for c in self.opener.calls if c['path'].endswith('/git/trees'))
        self.assertEqual({e['path']: e.get('content') for e in tree}, {
            'projects/dictionary/new.txt': 'tested', 'projects/dictionary/keep.txt': 'keep',
            'projects/dictionary/old.txt': None})
        self.assertEqual(receipt['parent_sha'], SHA1)

    def test_other_repo_anyone_read_run_and_writer_commit(self):
        from test_repository import OtherRepository
        self.b.repository = OtherRepository(); self.b.repository.exists = True
        self.b.repository.files = {'README.md': 'hello'}
        self.b.repository.entries = [dict(path='README.md', mode='100644', type='blob', size=5, sha='1'*40)]
        self.b.execute = lambda job: {'reason': 'exited', 'exit_code': 0}
        snapshot = self.b.handle(self.env('repo_read', repo='other/demo'))
        job = self.b.handle(self.env('repo_run', snapshot_id=snapshot['snapshot_id'],
            changes={'README.md': 'tested'}, delete=[], argv=['/bin/sh', '-c', 'true'], title='suite'))
        for target in ('trunk',):
            with self.assertRaisesRegex(ValueError, 'default branch'):
                self._tested_commit(job, repo='other/demo', branch=target)
        with self.assertRaisesRegex(ValueError, 'allowlisted'):
            self._tested_commit(job, repo='other/demo', branch='feature', requester='visitor')
        self.assertEqual(self.opener.calls, [])
        self.git_routes()
        for (method, path), response in list(self.opener.routes.items()):
            if path.startswith('/repos/o/r/'):
                self.opener.routes[(method, path.replace('/repos/o/r/', '/repos/other/demo/').replace('/heads/topic', '/heads/feature'))] = response
        self.opener.routes[('GET', '/repos/other/demo')] = Response(200, {'default_branch': 'trunk'})
        self.opener.routes[('GET', '/repos/other/demo/git/ref/heads/feature')] = http_error(404)
        with self.assertRaisesRegex(ValueError, 'match tested snapshot'):
            self._tested_commit(job, repo='wrong/repo', branch='feature')
        self.opener.routes[('GET', '/repos/other/demo/git/ref/heads/trunk')] = Response(200, {'object': {'sha': SHA4}})
        with self.assertRaisesRegex(ValueError, 'branch moved'):
            self._tested_commit(job, repo='other/demo', branch='trunk-feature', base_ref=SHA4)
        self.opener.routes[('GET', '/repos/other/demo')] = Response(200, {'default_branch': 'feature'})
        with self.assertRaisesRegex(ValueError, 'default branch'):
            self._tested_commit(job, repo='other/demo', branch='feature')
        self.opener.routes[('GET', '/repos/other/demo')] = Response(200, {'default_branch': 'trunk'})
        self.opener.routes[('GET', '/repos/other/demo/git/ref/heads/feature')] = Response(200, {'object': {'sha': SHA4}})
        with self.assertRaises(ValueError):
            self._tested_commit(job, repo='other/demo', branch='feature')
        self.assertTrue(all(c['method'] == 'GET' for c in self.opener.calls))
        self.opener.routes[('GET', '/repos/other/demo/git/ref/heads/feature')] = http_error(404)
        self.assertTrue(self._tested_commit(job, repo='other/demo', branch='feature')['tested'])
        tree = next(c['body']['tree'] for c in self.opener.calls if c['path'].endswith('/git/trees'))
        self.assertEqual(tree[0]['path'], 'README.md')
        visitor = self.b.handle(self.env('repo_read', requester='visitor', scope='f'*64, repo='other/demo'))
        self.assertEqual(self.b.handle(self.env('repo_run', requester='visitor', scope='f'*64,
            snapshot_id=visitor['snapshot_id'], changes={}, delete=[], argv=['/bin/sh', '-c', 'true'], title='suite'))['state'], 'passed')

    def test_user_repo_creation_writer_gate(self):
        with self.assertRaisesRegex(ValueError, 'allowlisted'):
            self.api('POST', '/user/repos', requester='visitor', body={'name': 'demo', 'auto_init': True})
        self.assertEqual(self.opener.calls, [])
        self.assertTrue(self.api('POST', '/user/repos', body={'name': 'demo', 'auto_init': True})['ok'])

    def test_plain_commit_receipt_does_not_claim_tests(self):
        self.git_routes()
        receipt = self.commit()
        self.assertIs(receipt['tested'], False)
        self.assertNotIn('job_id', receipt)

    def test_from_job_validation_happens_before_github_io(self):
        job = self._tested_job()
        for fields in ({'files': {'forged': 'x'}}, {'repo': 'other/repo'}, {'base_ref': SHA4},
                       {'scope': 'f' * 64}, {'from_job': 'bad'}):
            with self.subTest(fields=fields), self.assertRaises(ValueError):
                self._tested_commit(job, **fields)
        self.assertEqual(self.opener.calls, [])
        self.assertEqual(self.b.db.execute('SELECT COUNT(*) FROM github_write_budgets').fetchone()[0], 0)

    def test_from_job_rejects_failed_and_diagnostic_jobs(self):
        failed = self._tested_job(passed=False)
        with self.assertRaises(ValueError): self._tested_commit(failed)
        self.b.execute = lambda job: {'reason': 'exited', 'exit_code': 0}
        diagnostic = self.b.handle(self.env('repo_diagnose', id=failed['id'], argv=['/bin/sh', '-c', 'true'], title='diagnostic'))
        with self.assertRaises(ValueError): self._tested_commit(diagnostic)
        self.assertEqual(self.opener.calls, [])

    def test_from_job_survives_resume_with_same_task_identity(self):
        job = self._tested_job()
        checkpoint = self.b.handle(self.env('task_checkpoint', phase='stopped', reason='iteration_limit'))
        self.b.handle(self.env('task_resume', scope='f' * 64, checkpoint_id=checkpoint['checkpoint_id']))
        self._tested_routes()
        receipt = self._tested_commit(job, scope='f' * 64)
        self.assertEqual(receipt['job_id'], job['id'])
        self.assertTrue(receipt['tested'])

    def test_commit_requires_exactly_one_source_and_rejects_non_repository_job(self):
        with self.assertRaises(ValueError):
            self.b.handle(self.env('github_commit_files', repo='o/r', branch='topic', message='missing source'))
        self.b.execute = lambda job: {'reason': 'exited', 'exit_code': 0}
        job = self.b.handle(self.env('run', files={'main.py': 'print(1)'}, argv=['/usr/bin/python3', '/work/main.py'], title='standalone'))
        with self.assertRaises(ValueError): self._tested_commit(job)
        self.assertEqual(self.opener.calls, [])

    def test_from_job_detects_moved_parent_before_object_writes(self):
        job = self._tested_job()
        self._tested_routes(parent=SHA4)
        with self.assertRaises(ValueError): self._tested_commit(job)
        self.assertTrue(self.opener.calls)
        self.assertTrue(all(c['method'] == 'GET' for c in self.opener.calls))

    def test_legacy_pending_publications_do_not_gate_new_work(self):
        job = self._tested_job()
        self.b.db.execute("UPDATE jobs SET state='uncertain' WHERE id=?", (job['id'],))
        self.b.record_publication_attempt(job['id'])
        self.b.db.commit()
        self.assertEqual(self.b.publication_attempt_count(), 0)
        self.assertTrue(self.api('POST', '/repos/o/r/issues', scope='f' * 64, body={'title': 'new'})['ok'])
        reopened = Broker(Path(self.tmp.name) / 'state')
        self.addCleanup(reopened.db.close)
        self.assertEqual(reopened.db.execute('SELECT state FROM jobs WHERE id=?', (job['id'],)).fetchone()['state'], 'uncertain')
        self.assertIsNotNone(reopened.db.execute("SELECT name FROM sqlite_master WHERE name='direct_repo_publications'").fetchone())

    def test_from_job_original_missing_branch_rechecks_fallback_before_writes(self):
        job = self._tested_job()
        destination = json.loads(self.b.db.execute('SELECT destination FROM repo_jobs WHERE id=?', (job['id'],)).fetchone()[0])
        row = self.b.db.execute('SELECT snapshot FROM repo_snapshots WHERE id=?', (destination['snapshot_id'],)).fetchone()
        snapshot = json.loads(row[0]); snapshot['exists'] = False
        self.b.db.execute('UPDATE repo_snapshots SET snapshot=? WHERE id=?', (json.dumps(snapshot), destination['snapshot_id']))
        self.b.db.commit()
        self._tested_routes(exists=False)
        main = ('GET', '/repos/burt-agent/workspace/git/ref/heads/main')
        self.opener.routes[main] = Response(200, {'object': {'sha': SHA4}})
        with self.assertRaisesRegex(ValueError, 'branch moved since the tested snapshot'):
            self._tested_commit(job)
        self.assertTrue(all(c['method'] == 'GET' for c in self.opener.calls))
        self.opener.calls.clear()
        self.opener.routes[main] = Response(200, {'object': {'sha': SHA1}})
        self.assertTrue(self._tested_commit(job)['tested'])

    def test_from_job_deleted_snapshot_branch_has_no_write_calls(self):
        job = self._tested_job()
        self._tested_routes(exists=False)
        with self.assertRaisesRegex(ValueError, 'branch moved since the tested snapshot'):
            self._tested_commit(job)
        self.assertTrue(all(c['method'] == 'GET' for c in self.opener.calls))

    def test_from_job_non_writer_has_no_github_calls(self):
        job = self._tested_job()
        with patch.dict(os.environ, {'BURT_GITHUB_WRITERS': ''}):
            with self.assertRaisesRegex(ValueError, 'allowlisted'):
                self._tested_commit(job)
        self.assertEqual(self.opener.calls, [])

    def test_from_job_rejects_snapshot_branch_disappearing(self):
        job = self._tested_job()
        self._tested_routes(exists=False)
        with self.assertRaises(ValueError): self._tested_commit(job)
        self.assertTrue(all(c['method'] == 'GET' for c in self.opener.calls))

    def test_from_job_new_branch_uses_snapshot_sha_not_default_branch(self):
        job = self._tested_job()
        self._tested_routes()
        self.opener.routes[('GET', '/repos/burt-agent/workspace/git/ref/heads/new-topic')] = http_error(404)
        receipt = self._tested_commit(job, branch='new-topic')
        self.assertEqual(receipt['parent_sha'], SHA1)
        self.assertTrue(receipt['created_branch'])
        self.assertNotIn('/repos/burt-agent/workspace', [c['path'] for c in self.opener.calls])
        self.opener.calls.clear()
        self.opener.routes[('GET', '/repos/burt-agent/workspace/git/ref/heads/new-topic')] = Response(200, {'object': {'sha': SHA1}})
        with self.assertRaises(ValueError): self._tested_commit(job, branch='new-topic')
        self.assertTrue(all(c['method'] == 'GET' for c in self.opener.calls))

    def test_commit_files_rejects_unsafe_paths_before_io_and_budget(self):
        for files in ({'../x': 'a'}, {'/abs': 'a'}, {'.git/config': 'a'}, {'a/.Git/hooks/x': 'a'}, {'a\\b': 'a'},
                      {'a//b': 'a'}, {}, {'a': 5}, {'a': {'content': 'x', 'mode': '120000'}},
                      {f'f{i}': 'x' for i in range(101)}, {'big': 'x' * (github.MAX_COMMIT_BYTES + 1)}):
            with self.subTest(files=list(files)[:2]), self.assertRaises(GitHubError):
                self.commit(files=files)
        for fields in ({'branch': '../main'}, {'branch': 'refs/heads/x'}, {'branch': 'a..b'}, {'branch': 'x.lock'},
                       {'repo': 'o/r/x'}, {'message': ''}, {'base_ref': 'a b'}, {'create_branch': 'yes'}):
            with self.subTest(fields=fields), self.assertRaises(GitHubError):
                self.commit(**fields)
        self.assertEqual(self.opener.calls, [])
        self.assertEqual(self.b.db.execute('SELECT COUNT(*) FROM github_write_budgets').fetchone()[0], 0)

    def test_commit_failures_before_and_at_ref_write(self):
        self.git_routes()
        self.opener.routes[('POST', '/repos/o/r/git/trees')] = urllib.error.URLError('reset')
        result = self.commit()
        self.assertNotIn('outcome_uncertain', result)
        self.assertEqual(result['error'], 'github_unavailable')
        self.assertIn('No branch', result['instruction'])
        self.git_routes()
        self.opener.calls.clear()
        self.opener.routes[('PATCH', '/repos/o/r/git/refs/heads/topic')] = urllib.error.URLError('reset')
        result = self.commit()
        self.assertTrue(result['outcome_uncertain'])
        self.assertEqual((result['method'], result['path']), ('PATCH', '/repos/o/r/git/refs/heads/topic'))
        self.assertEqual([c['method'] for c in self.opener.calls].count('PATCH'), 1)
        self.git_routes()
        self.opener.routes[('PATCH', '/repos/o/r/git/refs/heads/topic')] = http_error(422, {
            'message': 'Update is not a fast forward'})
        result = self.commit()
        self.assertEqual((result['ok'], result['status'], result['message']),
                         (False, 422, 'Update is not a fast forward'))
        self.opener.routes[('GET', '/repos/o/r/git/ref/heads/topic')] = Response(200, {'unexpected': True})
        with self.assertRaisesRegex(GitHubError, 'no branch was changed'):
            self.commit()

    def test_github_read_through_broker(self):
        self.opener.routes[('GET', '/repos/o/r/contents/x')] = Response(200, {
            'type': 'file', 'path': 'x', 'encoding': 'base64', 'content': 'aGk='})
        result = self.b.handle(self.env('github_read', 'visitor', repo='o/r', ref='main', path='x'))
        self.assertEqual(result['content'], 'hi')

    def test_github_actions_respect_task_terminal_state(self):
        self.b.admit_transition('e' * 64, 'status')
        self.b.db.execute('UPDATE task_phase_budgets SET deadline=0 WHERE task_id=?', ('e' * 64,))
        with self.assertRaisesRegex(ValueError, 'deadline'):
            self.api('GET', '/user')
        with self.assertRaisesRegex(ValueError, 'terminal'):
            self.api('PUT', '/user/starred/o/r')
        self.assertEqual(self.opener.calls, [])


if __name__ == '__main__':
    unittest.main()
