#!/usr/bin/python3 -I
"""Operator-only offline prototype. One bounded JSON job on stdin; JSON result."""
import json
import os
from pathlib import Path, PurePosixPath
import selectors
import subprocess
import sys
import tempfile
import time
import uuid

MAX_BYTES = 65536


def validate(job):
    if not isinstance(job, dict) or set(job) != {'files', 'argv'}:
        raise ValueError('job requires exactly files and argv')
    files, argv = job['files'], job['argv']
    if not isinstance(files, dict) or not 1 <= len(files) <= 32:
        raise ValueError('files must contain 1..32 text files')
    total = 0
    for name, content in files.items():
        path = PurePosixPath(name)
        if (not name or path.is_absolute() or any(p in ('.', '..', '') for p in name.split('/'))
                or len(name) > 200 or not isinstance(content, str)):
            raise ValueError('invalid text file')
        total += len(content.encode())
    if total > MAX_BYTES:
        raise ValueError('input files exceed 64 KiB')
    if (not isinstance(argv, list) or not 1 <= len(argv) <= 32
            or any(not isinstance(a, str) or '\x00' in a or len(a) > 4096 for a in argv)
            or argv[0] not in ('/usr/bin/python3', '/usr/bin/perl', '/bin/sh')):
        raise ValueError('invalid command; use absolute python3, perl, or sh')
    return files, argv


def run(job, seconds=20, checks=None):
    files, argv = validate(job)
    if checks is not None:
        validate({'files': checks, 'argv': argv})
    unit = 'burt-workbench-' + uuid.uuid4().hex
    # Do not forward the operator environment (including tokens or tracing flags).
    env = {'PATH': '/usr/bin:/bin', 'HOME': str(Path.home()),
           'XDG_RUNTIME_DIR': '/run/user/' + str(os.getuid()),
           'DBUS_SESSION_BUS_ADDRESS': 'unix:path=/run/user/' + str(os.getuid()) + '/bus'}
    with tempfile.TemporaryDirectory(prefix='burt-workbench-') as directory:
        root = Path(directory)
        for name, content in files.items():
            target = root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(content)
        # Verification inputs are supplied ONLY by the operator-side broker.
        # Both source and tests stay read-only throughout trusted verification.
        checks_dir = root / '.operator-checks'
        if checks is not None:
            checks_dir.mkdir()
            for name, content in checks.items():
                target = checks_dir / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text(content)
        cmd = ['/usr/bin/systemd-run', '--user', '--quiet', '--wait', '--pipe', '--collect',
               '--unit=' + unit, '-p', 'RuntimeMaxSec=' + str(seconds),
               '-p', 'TimeoutStopSec=2', '-p', 'KillMode=control-group',
               '-p', 'MemoryMax=256M', '-p', 'MemorySwapMax=0', '-p', 'TasksMax=32',
               '-p', 'LimitFSIZE=1048576', '-p', 'LimitCORE=0', '-p', 'LimitNOFILE=64',
               '-p', 'NoNewPrivileges=yes', '/usr/bin/bwrap', '--unshare-all',
               '--die-with-parent', '--new-session', '--cap-drop', 'ALL',
               '--ro-bind', '/usr', '/usr', '--symlink', 'usr/bin', '/bin',
               '--symlink', 'usr/lib', '/lib', '--symlink', 'usr/lib64', '/lib64',
               '--proc', '/proc', '--dev', '/dev', '--size', '16777216', '--tmpfs', '/tmp',
               '--ro-bind', directory, '/input', '--size', '16777216', '--tmpfs', '/work',
               '--chdir', '/work', '--clearenv', '--setenv', 'PATH', '/usr/bin:/bin',
               '--setenv', 'HOME', '/tmp', '/bin/sh', '-c',
               'cp -R /input/. /work/ && exec "$@"', 'burt-job', *argv]
        if checks is not None:
            # Do not nest the private checks under /input or expose host paths.
            source_dir = root / '.operator-source'
            source_dir.mkdir()
            for name, content in files.items():
                target = source_dir / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text(content)
            start = cmd.index('--ro-bind', cmd.index('--tmpfs') + 2)
            cmd[start:] = ['--ro-bind', str(source_dir), '/work',
                          '--ro-bind', str(checks_dir), '/checks', '--chdir', '/work',
                          '--clearenv', '--setenv', 'PATH', '/usr/bin:/bin',
                          '--setenv', 'HOME', '/tmp', '--setenv', 'PYTHONDONTWRITEBYTECODE', '1', *argv]
        output = bytearray()
        reason = 'exited'
        started = time.monotonic()
        proc = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, env=env)
        try:
            with selectors.DefaultSelector() as sel:
                sel.register(proc.stdout, selectors.EVENT_READ)
                while sel.get_map():
                    if time.monotonic() - started > seconds + 5:
                        reason = 'supervisor_timeout'
                        break
                    for key, _ in sel.select(0.1):
                        chunk = os.read(key.fd, 4096)
                        if not chunk:
                            sel.unregister(key.fileobj)
                            continue
                        remaining = MAX_BYTES - len(output)
                        output.extend(chunk[:remaining])
                        if len(chunk) > remaining:
                            reason = 'output_limit'
                            break
                    if reason == 'output_limit':
                        break
            if reason == 'exited':
                proc.wait(timeout=3)
        finally:
            # Stop the whole cgroup, not merely the systemd-run client.
            subprocess.run(['/usr/bin/systemctl', '--user', 'stop', unit + '.service'],
                                     env=env, stdout=subprocess.DEVNULL,
                                     stderr=subprocess.DEVNULL, timeout=8)
            if proc.poll() is None:
                proc.kill()
            proc.wait(timeout=3)
            proc.stdout.close()
        return {'exit_code': proc.returncode, 'reason': reason,
                'output': output.decode('utf-8', errors='replace'),
                'elapsed_seconds': round(time.monotonic() - started, 2)}


if __name__ == '__main__':
    try:
        raw = sys.stdin.buffer.read(262145)
        if len(raw) > 262144:
            raise ValueError('job JSON exceeds 256 KiB')
        print(json.dumps(run(json.loads(raw))))
    except Exception as exc:
        print(json.dumps({'error': str(exc)}))
        sys.exit(1)
