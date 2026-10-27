import unittest
from trusted_experiment import score, evaluator_verdict


class ScoringTests(unittest.TestCase):
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
