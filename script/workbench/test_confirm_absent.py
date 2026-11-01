import json
import threading
import unittest
from concurrent.futures import ThreadPoolExecutor
from urllib.error import HTTPError

from broker import confirm_absent_pending_pull_request, reconcile_pending_pull_request
from repository import Repository
import test_repository
import test_broker

A, B = test_repository.A, test_repository.B
FakeRepository = test_repository.FakeRepository


class PagedRepository(FakeRepository):
    def __init__(self):
        super().__init__()
        self.pages = {}
        self.rate_limit = False

    def api(self, path, payload=None, method=None):
        self.calls.append((path, payload, method))
        if self.rate_limit:
            raise HTTPError(path, 429, 'rate limited', {}, None)
        if '/pulls?' in path:
            page = int(path.rsplit('page=', 1)[1])
            return self.pages.get(page, [])
        return super().api(path, payload, method)


class ConfirmAbsentTests(unittest.TestCase):
    post = test_broker.BrokerTests.post
    publish = test_broker.BrokerTests.publish

    def setUp(self):
        test_repository.RepositoryBrokerTests.setUp(self)

    def envelope(self, action, scope=None, channel=None, network=None, requester='mateu'):
        return {'action': action, 'scope': scope or self.req['scope'], 'requester': requester,
                'channel': channel or self.req['channel'], 'network': network or self.req['network']}

    def request(self, action):
        return self.envelope(action)

    def absent_pending(self):
        self.repo.exists = True
        self.repo.head = A
        self.repo.fail_reconciliation = False
        task_id = test_repository.RepositoryBrokerTests.uncertain_pr_create(self)
        self.repo.pulls.clear()
        return task_id

    def confirm(self, task_id, *, commit=False, operator='hunter'):
        return confirm_absent_pending_pull_request(self.b.db, self.repo, task_id,
                                                   operator, commit=commit)

    def test_preview_is_get_only_and_changes_nothing(self):
        task_id = self.absent_pending()
        before_pending = dict(self.b.pending_pull_request(task_id))
        calls = len(self.repo.calls)
        result = self.confirm(task_id)
        self.assertFalse(result['confirmed'])
        self.assertEqual(result['evidence']['pr_count'], 0)
        self.assertEqual(dict(self.b.pending_pull_request(task_id)), before_pending)
        self.assertIsNone(self.b.db.execute('SELECT 1 FROM absent_pull_request_confirmations WHERE task_id=?',
                                            (task_id,)).fetchone())
        self.assertTrue(all(method is None for _, _, method in self.repo.calls[calls:]))

    def test_any_pr_state_blocks_absence_and_default_still_reconciles_matching_pr(self):
        task_id = test_repository.RepositoryBrokerTests.uncertain_pr_create(self)
        for state, merged in (('open', False), ('closed', False), ('closed', True)):
            with self.subTest(state=state, merged=merged):
                self.repo.pulls[1]['state'], self.repo.pulls[1]['merged'] = state, merged
                with self.assertRaisesRegex(ValueError, 'pull request exists'):
                    self.confirm(task_id)
                self.assertIsNotNone(self.b.pending_pull_request(task_id))
        result = reconcile_pending_pull_request(self.b.db, self.repo, task_id)
        self.assertTrue(result['reconciled'])

    def test_moved_missing_api_and_rate_limit_fail_closed(self):
        for kind in ('moved', 'missing', 'api', 'rate'):
            with self.subTest(kind=kind):
                task_id = self.absent_pending()
                if kind == 'moved':
                    self.repo.head = B
                elif kind == 'missing':
                    self.repo.exists = False
                elif kind == 'api':
                    self.repo.fail_reconciliation = True
                else:
                    original = self.repo.api
                    self.repo.api = lambda *a, **k: (_ for _ in ()).throw(HTTPError('/x', 429, 'rate', {}, None))
                with self.assertRaises(Exception):
                    self.confirm(task_id)
                self.assertIsNotNone(self.b.pending_pull_request(task_id))
                self.repo.fail_reconciliation = False
                if kind == 'rate': self.repo.api = original
                self.b.db.execute('DELETE FROM pending_pull_request_operations WHERE task_id=?', (task_id,))
                self.b.db.execute('DELETE FROM repository_pull_requests WHERE branch=? AND head_sha=?', ('burt/dictionary', A))
                self.b.db.execute('DELETE FROM task_phase_budgets WHERE task_id=?', (task_id,))
                self.b.db.commit()

    def test_retargeted_pr_on_any_base_blocks_absence(self):
        task_id = self.absent_pending()
        repo = PagedRepository()
        repo.exists = True
        repo.head = A
        retargeted = repo.pull(7, 'burt/dictionary', A)
        retargeted['base'] = dict(retargeted['base'], ref='develop')
        repo.pages[1] = [retargeted]
        with self.assertRaisesRegex(ValueError, 'pull request exists'):
            confirm_absent_pending_pull_request(self.b.db, repo, task_id, 'hunter', commit=True)
        self.assertIsNotNone(self.b.pending_pull_request(task_id))
        pulls_queries = [path for path, _, _ in repo.calls if '/pulls?' in path]
        self.assertTrue(pulls_queries)
        self.assertTrue(all('base=' not in path for path in pulls_queries))

    def test_paginated_list_is_read_and_blocks_later_page(self):
        task_id = self.absent_pending()
        repo = PagedRepository()
        repo.exists = True
        repo.head = A
        repo.pages[1] = [repo.pull(i + 1, 'burt/dictionary', A) for i in range(100)]
        repo.pages[2] = [repo.pull(101, 'burt/dictionary', A)]
        with self.assertRaisesRegex(ValueError, 'pull request exists'):
            confirm_absent_pending_pull_request(self.b.db, repo, task_id, 'hunter')
        paths = [path for path, _, _ in repo.calls]
        self.assertTrue(any('page=2' in path for path in paths))
        self.assertTrue(all(method is None for _, _, method in repo.calls))

    def test_commit_writes_one_audit_row_replays_and_unblocks_after_last_identity_row(self):
        first = self.absent_pending()
        second = 'f' * 64
        self.b.db.execute('INSERT INTO pending_pull_request_operations VALUES (?,?,?,?,?,?,?)',
                          (second, 'burt/dictionary', A, None, None, 'repo_pr_create', 0))
        self.b.db.commit()
        result = self.confirm(first, commit=True)
        self.assertTrue(result['confirmed'])
        audit = self.b.db.execute('SELECT operator,evidence FROM absent_pull_request_confirmations WHERE task_id=?',
                                  (first,)).fetchone()
        self.assertEqual(audit['operator'], 'hunter')
        self.assertEqual(json.loads(audit['evidence'])['branch_sha'], A)
        self.assertIsNone(self.b.pending_pull_request(first))
        self.assertIsNotNone(self.b.db.execute('SELECT 1 FROM pending_pull_request_operations WHERE task_id=?',
                                               (second,)).fetchone())
        self.assertEqual(self.b.db.execute('SELECT state FROM repository_pull_requests WHERE branch=? AND head_sha=?',
                                           ('burt/dictionary', A)).fetchone()['state'], 'create_uncertain')
        with self.assertRaisesRegex(ValueError, 'operator reconciliation'):
            self.b.admit_pull_request_write(self.request('repo_pr_create'), 'burt/dictionary', A)
        self.assertTrue(self.confirm(first, commit=True)['replayed'])
        self.confirm(second, commit=True)
        self.assertEqual(self.b.db.execute('SELECT state FROM repository_pull_requests WHERE branch=? AND head_sha=?',
                                           ('burt/dictionary', A)).fetchone()['state'], 'absent_confirmed')
        self.b.admit_pull_request_write(self.request('repo_pr_create'), 'burt/dictionary', A)

    def test_commit_concurrency_is_idempotent(self):
        task_id = self.absent_pending()
        barrier = threading.Barrier(2)
        def run():
            import sqlite3
            db = sqlite3.connect(self.b.base / 'jobs.sqlite', timeout=5)
            db.row_factory = sqlite3.Row
            try:
                barrier.wait()
                return confirm_absent_pending_pull_request(db, self.repo, task_id, 'hunter', commit=True)
            finally:
                db.close()
        with ThreadPoolExecutor(max_workers=2) as workers:
            results = list(workers.map(lambda _: run(), range(2)))
        self.assertEqual(sum(bool(row['replayed']) for row in results), 1)
        self.assertEqual(self.b.db.execute('SELECT COUNT(*) FROM absent_pull_request_confirmations WHERE task_id=?',
                                           (task_id,)).fetchone()[0], 1)


if __name__ == '__main__':
    unittest.main()
