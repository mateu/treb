"""Offline E2E coverage for the thin runtime-to-broker envelope."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch

from broker import Broker
from test_repository import FakeRepository
from test_github import FakeOpener, Response
from github import GitHub


# Fixed-repository PR writes share the account writer allowlist.
@patch.dict(os.environ, {'BURT_GITHUB_WRITERS': 'mateu'})
class RuntimeBrokerProxyTests(unittest.TestCase):
    transcript = ('Pick up the saved dictionary query-string feature work—not the later base-only test run. '
                  'Check the actual saved candidate, run the full offline suite against it, and push it to '
                  'burt/dictionary if everything passes. Report the actual test results and published commit.')

    def runtime_publish_envelope(self):
        root = Path(__file__).resolve().parents[2]
        perl = r'''use strict; use warnings; use JSON::PP; use lib 'lib'; use Bot::Runtime::Workbench;
{ package ProxyBot; sub _bot_name_slug {'burt'} sub _is_human_nick { $_[1] ne 'system' }
  sub _pending_raid { $_[0]{pending} } sub _send_to_channel {} }
{ package ProxyTool; sub text_result { $_[1] } }
$ENV{BURT_WORKBENCH_SOCKET}='/not/a/socket'; $ENV{IRC_SERVER}='irc.perl.org';
my $bot=bless {pending=>{channel=>'#ai',expires_at=>time+60,messages=>[
  {nick=>'mateu',source_kind=>'conversation',msg=>$ENV{WORKBENCH_TRANSCRIPT}}]}},'ProxyBot';
my %tools=map {$_->{name}=>$_} @{Bot::Runtime::Workbench::tool_specs($bot)};
no warnings 'redefine'; local *Bot::Runtime::Workbench::broker_call=sub { my $r=$_[0]; return '{"jobs":[]}' if $r->{action} eq 'task_status'; return '{"checkpoint_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","jobs":[],"attempts_remaining":13}' if $r->{action} eq 'task_checkpoint'; return '{}' if $r->{action} eq 'task_progress'; print encode_json($r); return '{"state":"passed"}' };
$tools{github_commit_files}{code}->(bless({},'ProxyTool'),{repo=>'burt-agent/workspace',branch=>'burt/dictionary',from_job=>'a'x32,message=>'tested feature'});'''
        result = subprocess.run(
            ['script/with-burt-env.sh', 'perl', '-Ilib', '-e', perl],
            cwd=root, text=True, capture_output=True,
            env=os.environ | {'WORKBENCH_TRANSCRIPT': self.transcript},
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def test_exact_unaddressed_transcript_forwards_only_structured_provenance(self):
        envelope = self.runtime_publish_envelope()
        self.assertEqual(envelope['action'], 'github_commit_files')
        self.assertEqual(envelope['from_job'], 'a' * 32)
        self.assertEqual(envelope['requester'], 'mateu')
        self.assertEqual(envelope['channel'], '#ai')
        self.assertEqual(envelope['network'], 'irc.perl.org')
        self.assertNotIn('capability', envelope)
        self.assertNotIn('grant', envelope)
        self.assertNotIn('id', envelope)
        self.assertNotIn('destination', envelope)

    def test_runtime_omits_legacy_fixed_repository_pr_tools(self):
        root = Path(__file__).resolve().parents[2]
        perl = r'''use strict; use warnings; use JSON::PP; use lib 'lib'; use Bot::Runtime::Workbench;
{ package ProxyBot; sub _bot_name_slug {'burt'} sub _is_human_nick { $_[1] ne 'system' } sub _pending_raid { $_[0]{pending} } sub _send_to_channel {} }
my $bot=bless {pending=>{channel=>'#ai',expires_at=>time+60,messages=>[]}},'ProxyBot';
my %tools=map {$_->{name}=>$_} @{Bot::Runtime::Workbench::tool_specs($bot)};
print encode_json([grep {!exists $tools{$_}} qw(create_repo_pull_request inspect_repo_pull_request merge_repo_pull_request)]);'''
        result = subprocess.run(['script/with-burt-env.sh','perl','-Ilib','-e',perl], cwd=root, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), ['create_repo_pull_request', 'inspect_repo_pull_request', 'merge_repo_pull_request'])

    def test_runtime_dispatch_selects_saved_feature_over_later_base_only_and_stub_publishes(self):
        envelope = {k: v for k, v in self.runtime_publish_envelope().items() if k in ('action', 'scope', 'requester', 'channel', 'network')}
        with tempfile.TemporaryDirectory() as tmp:
            token = Path(tmp) / 'token'; token.write_text('ghp_' + 'OfflineTestCredential' * 2); token.chmod(0o600)
            broker = Broker(tmp, token, execute=lambda job: {'reason': 'exited', 'exit_code': 0,
                                                              'output': 'full offline suite passed'})
            self.addCleanup(broker.db.close)
            repo = FakeRepository(); repo.exists = True; repo.files = {'main.py': 'print(1)'}; broker.repository = repo
            broker.db.execute('INSERT INTO task_scopes VALUES (?,?,?,?,?,?)',
                              (envelope['scope'], envelope['scope'], envelope['requester'],
                               envelope['channel'], envelope['network'], time.time()))
            broker.db.commit()
            snapshot = broker.handle(envelope | {'action': 'repo_read', 'branch': 'burt/dictionary', 'project': 'dictionary'})
            feature = broker.handle(envelope | {'action': 'repo_run', 'snapshot_id': snapshot['snapshot_id'],
                'changes': {'main.py': 'print(2)'}, 'delete': [], 'argv': ['/bin/sh', '-c', 'true'],
                'title': 'full offline suite for query-string feature'})
            base_only = broker.handle(envelope | {'action': 'repo_run', 'snapshot_id': snapshot['snapshot_id'],
                'changes': {}, 'delete': [], 'argv': ['/bin/sh', '-c', 'true'], 'title': 'base-only'})
            self.assertEqual(feature['state'], 'passed')
            self.assertEqual(feature['result']['exit_code'], 0)
            self.assertEqual(feature['result']['output'], 'full offline suite passed')
            self.assertEqual(base_only['state'], 'passed')
            prefix = '/repos/burt-agent/workspace/git'
            opener = FakeOpener({
                ('GET', prefix + '/ref/heads/burt/dictionary'): Response(200, {'object': {'sha': 'a' * 40}}),
                ('GET', prefix + '/commits/' + 'a' * 40): Response(200, {'tree': {'sha': 'b' * 40}}),
                ('POST', prefix + '/trees'): Response(201, {'sha': 'c' * 40}),
                ('POST', prefix + '/commits'): Response(201, {'sha': 'd' * 40}),
                ('PATCH', prefix + '/refs/heads/burt/dictionary'): Response(200, {})})
            broker.github = GitHub(token, opener=opener)
            published = broker.handle(envelope | {'from_job': feature['id'], 'repo': 'burt-agent/workspace', 'branch': 'burt/dictionary', 'message': 'tested feature'})
            self.assertEqual(published['job_id'], feature['id'])
            self.assertTrue(published['tested'])
            tree = next(c['body']['tree'] for c in opener.calls if c['path'].endswith('/trees'))
            self.assertEqual(tree[0]['content'], 'print(2)')

    def test_broker_rejects_legacy_fixed_repository_pr_actions(self):
        envelope = {k: v for k, v in self.runtime_publish_envelope().items() if k in ('action', 'scope', 'requester', 'channel', 'network')}
        with tempfile.TemporaryDirectory() as tmp:
            broker = Broker(tmp, Path(tmp) / 'token')
            self.addCleanup(broker.db.close)
            for action in ('repo_publish', 'repo_pr_create', 'repo_pr_inspect', 'repo_pr_merge'):
                with self.assertRaisesRegex(ValueError, 'invalid action or fields'):
                    broker.handle({k: v for k, v in envelope.items() if k in ('scope', 'requester', 'channel', 'network')} | {'action': action})


if __name__ == '__main__':
    unittest.main()
