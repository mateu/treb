import unittest
from trusted_experiment import score


class ScoringTests(unittest.TestCase):
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
