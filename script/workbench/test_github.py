import os, tempfile, unittest
from pathlib import Path
from github import denied, safe_path, safe_file_path, GitHub, GitHubError
class GitHubPolicyTests(unittest.TestCase):
 def test_denylist_and_nearby_allowed(self):
  blocked=[('DELETE','/repos/o/r'),('POST','/repos/o/r/transfer'),('POST','/repos/o/r/hooks'),('PUT','/repos/o/r/actions/secrets/x'),('PATCH','/user'),('POST','/user/keys'),('POST','/authorizations'),('POST','/orgs/o/memberships/u')]
  for method,path in blocked: self.assertTrue(denied(method,path),(method,path))
  for method,path in [('GET','/repos/o/r/hooks'),('POST','/repos/o/r/issues'),('GET','/user'),('POST','/gists')]: self.assertFalse(denied(method,path),(method,path))
 def test_paths_reject_absolute_and_traversal(self):
  for path in ('https://api.github.com/user','//api.github.com/user','/repos/../user','/repos/o/r?x=1'):
   with self.assertRaises(GitHubError): safe_path(path)
  for path in ('../x','a/../b','/a','a//b'):
   with self.assertRaises(GitHubError): safe_file_path(path)
 def test_private_regular_token_only(self):
  with tempfile.TemporaryDirectory() as d:
   p=Path(d)/'token'; p.write_text('secret-token'); p.chmod(0o600)
   self.assertEqual(GitHub(p).token(),'secret-token')
   p.chmod(0o644)
   with self.assertRaises(GitHubError): GitHub(p).token()
if __name__=='__main__': unittest.main()
