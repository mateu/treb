import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import runner


class Perl5Tests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.source = Path(self.tmp.name) / 'perl5'
        (self.source / 'lib/perl5').mkdir(parents=True)
        self.environment = patch.dict(os.environ, BURT_SANDBOX_PERL5=str(self.source))
        self.environment.start()
        self.addCleanup(self.environment.stop)

    def capture(self, checks=None):
        captured = []
        popen = subprocess.Popen
        def launch(cmd, **kwargs):
            captured.extend(cmd)
            return popen(['/usr/bin/true'], **kwargs)
        with patch.object(runner.subprocess, 'Popen', side_effect=launch), \
                patch.object(runner.subprocess, 'run'):
            result = runner.run({'files': {'a': '1'}, 'argv': ['/usr/bin/perl', '-e', '1']},
                                checks=checks)
        return captured, result

    def test_both_command_shapes(self):
        for checks in (None, {'check.pl': '1;'}):
            with self.subTest(checks=checks):
                cmd, result = self.capture(checks)
                self.assertIn('--unshare-all', cmd)
                self.assertNotIn('--share-net', cmd)
                i = cmd.index('/perl5')
                self.assertEqual(cmd[i-2:i+1], ['--ro-bind', str(self.source), '/perl5'])
                self.assertEqual(cmd.count('/perl5'), 1)
                i = cmd.index('PERL5LIB')
                self.assertEqual(cmd[i-1:i+2], ['--setenv', 'PERL5LIB', '/perl5/lib/perl5'])
                self.assertLess(i, cmd.index('/usr/bin/perl'))
                self.assertEqual(result['perl5'], 'mounted')
                self.assertNotIn(str(self.source), str(result))
                i = cmd.index('PATH', cmd.index('--clearenv'))
                self.assertEqual(cmd[i+1], '/usr/bin:/bin')

    def test_unsafe_or_missing_skipped_for_both_shapes(self):
        for target in (self.source, self.source / 'lib/perl5'):
            for mode in (0o775, 0o757):
                target.chmod(mode)
                for checks in (None, {'check.pl': '1;'}):
                    cmd, result = self.capture(checks)
                    self.assertNotIn('/perl5', cmd)
                    self.assertNotIn('PERL5LIB', cmd)
                    self.assertEqual(result['perl5'], 'skipped')
                target.chmod(0o755)
        for source in (str(self.source / 'missing'), 'relative'):
            with patch.dict(os.environ, BURT_SANDBOX_PERL5=source):
                self.assertIsNone(runner.sandbox_perl5())
        with patch.object(runner.os, 'getuid', return_value=-1):
            self.assertIsNone(runner.sandbox_perl5())
        (self.source / 'lib/perl5').rmdir()
        (self.source / 'lib/perl5').symlink_to('/usr')
        self.assertIsNone(runner.sandbox_perl5())

    def test_default_source(self):
        with patch.dict(os.environ, {}, clear=True), \
                patch.object(runner.Path, 'home', return_value=Path(self.tmp.name)):
            self.assertEqual(runner.sandbox_perl5(), self.source)


class RealSandboxTests(unittest.TestCase):
    def test_moose_and_offline(self):
        if not shutil.which('bwrap'):
            self.skipTest('bwrap unavailable')
        source = runner.sandbox_perl5()
        if source is None or not (source / 'lib/perl5/Moose.pm').is_file():
            self.skipTest('safe operator local::lib with Moose unavailable')
        popen = subprocess.Popen
        def launch(cmd, **kwargs):
            return popen(cmd[cmd.index('/usr/bin/bwrap'):], **kwargs)
        script = """use Moose; use IO::Socket::INET;
die "network available" if IO::Socket::INET->new(
PeerAddr=>'1.1.1.1', PeerPort=>80, Proto=>'tcp', Timeout=>1);
open my $f, '>', '/perl5/should-not-write' and die "writable";
print "1";
"""
        for checks in (None, {'check.pl': script}):
            with patch.object(runner.subprocess, 'Popen', side_effect=launch), \
                    patch.object(runner.subprocess, 'run'):
                result = runner.run({'files': {'main.pl': script},
                                     'argv': ['/usr/bin/perl',
                                              '/checks/check.pl' if checks else 'main.pl']},
                                    checks=checks)
            self.assertEqual(result['exit_code'], 0, result)
            self.assertEqual(result['output'], '1')
