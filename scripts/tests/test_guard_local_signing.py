import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('patcher', Path(__file__).resolve().parents[1] / 'patch-claude-webguard.py')
patcher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(patcher)


class LocalSigningTests(unittest.TestCase):
    def test_official_team_and_keychain_claims_are_removed(self):
        original = {'com.apple.application-identifier': 'TEAM.app', 'com.apple.developer.team-identifier': 'TEAM',
                    'keychain-access-groups': ['TEAM.group'], 'com.apple.security.application-groups': ['TEAM.shared']}
        self.assertEqual(patcher.local_entitlements(original), {})

    def test_normal_runtime_permissions_remain(self):
        permissions = {'com.apple.security.cs.allow-jit': True, 'com.apple.security.device.camera': True,
                       'com.apple.security.virtualization': True}
        self.assertEqual(patcher.local_entitlements(permissions), permissions)

    def test_input_is_not_mutated(self):
        original = {'application-identifier': 'TEAM.app', 'com.apple.security.cs.allow-jit': True}
        result = patcher.local_entitlements(original)
        self.assertIn('application-identifier', original)
        self.assertNotIn('application-identifier', result)


if __name__ == '__main__':
    unittest.main()
