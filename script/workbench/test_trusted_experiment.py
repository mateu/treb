import tempfile
import time
import unittest
from trusted_experiment import TrialBroker, score, evaluator_verdict, req
from broker import Broker
from trial_support import Snapshot


class ScoringTests(unittest.TestCase):
    def test_experiment_request_uses_action_bound_capability_envelope(self):
        task = {'branch':'burt/dictionary', 'project':'dictionary', 'files':{'main.py':'pass\n'}}
        request = req(task, task['files'], 'f'*32)
        self.assertEqual(request['action'], 'repo_run')
        self.assertEqual(request['capability'], 'edit_test')
        self.assertEqual(request, Broker.capability_envelope('repo_run', 'a'*64, '#ai', 'irc.perl.org') | {
            'action':'repo_run', 'snapshot_id':'f'*32, 'changes':{}, 'delete':[],
            'argv':['/bin/sh','-c','true'], 'title':'control'})

    def test_experiment_request_materializes_explicit_changes_and_deletions(self):
        task = {'branch':'burt/dictionary', 'project':'dictionary',
                'files':{'main.py':'old\n', 'old.py':'remove\n'}}
        request = req(task, {'main.py':'new\n', 'new.py':'add\n'}, 'f'*32)
        self.assertEqual(request['changes'], {'main.py':'new\n', 'new.py':'add\n'})
        self.assertEqual(request['delete'], ['old.py'])

    def test_experiment_snapshot_has_stable_tree_identity(self):
        task = {'id':'dictionary', 'branch':'burt/dictionary', 'project':'dictionary',
                'files':{'main.py':'pass\n'}}
        snapshot = Snapshot(task).snapshot(task['branch'], task['project'])
        changed = Snapshot(task | {'files':{'main.py':'changed\n'}}).snapshot(task['branch'], task['project'])
        self.assertEqual(snapshot['tree_sha'], snapshot['base_sha'])
        self.assertNotEqual(snapshot['tree_sha'], changed['tree_sha'])

    def test_trial_broker_accepts_migrated_snapshot_request(self):
        task = {'id':'dictionary', 'branch':'burt/dictionary', 'project':'dictionary',
                'files':{'main.py':'pass\n'}}
        with tempfile.TemporaryDirectory() as base:
            broker = TrialBroker(base, task, time.time()+30)
            self.addCleanup(broker.db.close)
            broker.execute = lambda job: {'reason':'exited', 'exit_code':0, 'output':''}
            snapshot = broker.handle(Broker.capability_envelope('repo_read', 'a'*64, '#ai', 'irc.perl.org') |
                                     {'action':'repo_read', 'branch':task['branch'], 'project':task['project']})
            job = broker.handle(req(task, {'main.py':'changed\n'}, snapshot['snapshot_id']))
            self.assertEqual(job['state'], 'passed')
            for attempt in range(1, 5):
                job = broker.handle(req(task, {'main.py':'changed\n'}, snapshot['snapshot_id'], f'attempt-{attempt}'))
            self.assertEqual(job['attempts_remaining'], 0)
            with self.assertRaisesRegex(ValueError, 'limit: 5 sandbox attempts'):
                broker.handle(req(task, {'main.py':'changed\n'}, snapshot['snapshot_id'], 'sixth'))

    def test_returned_launcher_failure_is_unscored(self):
        result = evaluator_verdict({'reason':'exited', 'exit_code':1,
            'output':'Failed to find executable /usr/bin/bwrap'}, 'start-nonce', 'finish-nonce')
        self.assertEqual(result['status'], 'evaluator_error')
        self.assertIsNone(result['semantic_passed'])

    def test_started_assertion_failure_is_scored_failure(self):
        result = evaluator_verdict({'reason':'exited', 'exit_code':1,
            'output':'start-nonce\nAssertionError'}, 'start-nonce', 'finish-nonce')
        self.assertEqual(result['status'], 'scored')
        self.assertFalse(result['semantic_passed'])

    def test_zero_exit_requires_completion_and_no_resource_failure(self):
        for output, reason, expected in [('start-nonce', 'exited', None),
                ('start-nonce\nfinish-nonce', 'exited', True),
                ('start-nonce\nfinish-nonce', 'output_limit', False)]:
            result = evaluator_verdict({'reason':reason, 'exit_code':0, 'output':output},
                                       'start-nonce', 'finish-nonce')
            self.assertIs(result['semantic_passed'], expected)

    def test_evaluator_infrastructure_errors_are_unknown_not_agent_failures(self):
        bundle = {'state': 'passed', 'result': {}}
        for status in ['evaluator_error', 'unavailable', 'no_candidate']:
            result = score({}, bundle, {'status': status})
            self.assertFalse(result['independently_scored'])
            self.assertIsNone(result['semantic_accepted'])
            self.assertIsNone(result['preservation_passed'])
            self.assertEqual(result['assessment_status'], status)

    def test_real_scored_failure_remains_a_failure(self):
        result = score({}, None, {'status': 'scored', 'semantic_passed': False,
                                  'preservation_passed': True})
        self.assertTrue(result['independently_scored'])
        self.assertFalse(result['semantic_accepted'])
        self.assertTrue(result['preservation_passed'])

    def test_missing_or_nonboolean_verdict_is_unscored(self):
        for verdict in [None, 0, 'false']:
            result = score({}, None, {'status': 'scored', 'semantic_passed': verdict,
                                      'preservation_passed': True})
            self.assertFalse(result['independently_scored'])
            self.assertIsNone(result['semantic_accepted'])


if __name__ == '__main__':
    unittest.main()
