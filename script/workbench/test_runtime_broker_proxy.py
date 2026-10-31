"""Offline E2E coverage for the thin runtime-to-broker envelope."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

from broker import Broker
from test_repository import FakeRepository


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
no warnings 'redefine'; local *Bot::Runtime::Workbench::broker_call=sub { print encode_json($_[0]); return '{"state":"passed"}' };
$tools{publish_repo}{code}->(bless({},'ProxyTool'),{});'''
        result = subprocess.run(
            ['script/with-burt-env.sh', 'perl', '-Ilib', '-e', perl],
            cwd=root, text=True, capture_output=True,
            env=os.environ | {'WORKBENCH_TRANSCRIPT': self.transcript},
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def test_exact_unaddressed_transcript_forwards_only_structured_provenance(self):
        envelope = self.runtime_publish_envelope()
        self.assertEqual(envelope['action'], 'repo_publish')
        self.assertEqual(envelope['requester'], 'mateu')
        self.assertEqual(envelope['channel'], '#ai')
        self.assertEqual(envelope['network'], 'irc.perl.org')
        self.assertNotIn('capability', envelope)
        self.assertNotIn('grant', envelope)
        self.assertNotIn('id', envelope)
        self.assertNotIn('destination', envelope)

    def test_runtime_dispatch_selects_saved_feature_over_later_base_only_and_stub_publishes(self):
        envelope = self.runtime_publish_envelope()
        with tempfile.TemporaryDirectory() as tmp:
            token = Path(tmp) / 'token'; token.write_text('offline-only'); token.chmod(0o600)
            broker = Broker(tmp, token, execute=lambda job: {'reason': 'exited', 'exit_code': 0,
                                                              'output': 'full offline suite passed'})
            self.addCleanup(broker.db.close)
            repo = FakeRepository(); repo.files = {'main.py': 'print(1)'}; broker.repository = repo
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
            published = broker.handle(envelope)
            self.assertEqual(published['id'], feature['id'])
            self.assertEqual(published['state'], 'published')
            self.assertEqual(len([call for call in repo.calls if call[1] is not None]), 3)


if __name__ == '__main__':
    unittest.main()
