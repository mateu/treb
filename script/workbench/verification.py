"""Operator-owned completion contracts. Never load policy from candidate files."""
import hashlib
import json
from pathlib import Path

from repository import validate_destination, validate_files
from runner import validate


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


class Verification:
    def __init__(self, policies):
        # Freeze a private copy for the broker lifetime (no model-controlled reload).
        self.policies = json.loads(json.dumps(policies))
        self.runtime = self.runtime_identity()
        for key, policy in self.policies.items():
            branch, project = key.split(':')
            validate_destination(branch, project, policy['base_sha'])
            validate_files(policy['baseline'])
            validate_files(policy['checks'])
            validate({'files': policy['checks'], 'argv': policy['argv']})
            if (not policy['checks'] or not isinstance(policy['editable'], list)
                    or not set(policy['editable']) <= set(policy['baseline'])
                    or not isinstance(policy['additions'], list)
                    or any(p not in ('tests/', 't/') for p in policy['additions'])
                    or policy.get('source_baseline') not in (None, 'current_verified')
                    or not any(a.startswith('/checks/') for a in policy['argv'])):
                raise ValueError('invalid verification policy')

    @classmethod
    def load(cls, path):
        path = Path(path)
        if path.is_symlink() or path.stat().st_mode & 0o022:
            raise ValueError('verification policy must not be symlink/group/world writable')
        return cls(json.loads(path.read_text()))

    def policy(self, snapshot):
        key = snapshot['branch'] + ':' + snapshot['project']
        if key not in self.policies:
            raise ValueError('operator verification policy required for this project')
        policy = self.policies[key]
        if policy.get('source_baseline') == 'current_verified':
            # Dictionary's explicit opt-in advances only the effective baseline.
            # The policy/checks themselves remain frozen; source comes only from
            # the broker-owned snapshot and its identity binds each test/publish.
            policy = json.loads(json.dumps(policy))
            policy['base_sha'] = snapshot['base_sha']
            policy['baseline'] = snapshot['files']
        elif (policy['base_sha'] != snapshot['base_sha']
                or policy['baseline'] != snapshot['files']):
            raise ValueError('verification baseline changed; operator review required')
        return policy

    def identity(self, policy):
        if self.runtime != self.runtime_identity():
            raise ValueError('verification runtime changed; restart/review required')
        return digest({'policy': policy, 'runtime': self.runtime})

    @staticmethod
    def runtime_identity():
        # Selected executable/runner identity, NOT a complete OS dependency lock.
        return {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in (
            Path(__file__).with_name('runner.py'), Path('/usr/bin/python3'), Path('/usr/bin/perl'))}

    def prepare(self, snapshot, files):
        policy = self.policy(snapshot)
        editable = set(policy['editable'])
        for name, content in policy['baseline'].items():
            if name not in files:
                raise ValueError('baseline files cannot be deleted: ' + name)
            if name not in editable and files[name] != content:
                raise ValueError('protected baseline file changed: ' + name)
        for name in set(files) - set(policy['baseline']):
            if not any(name.startswith(p) for p in policy['additions']):
                raise ValueError('new files restricted to approved regression directories: ' + name)
        return policy
