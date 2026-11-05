"""The "Older devices" switch writes the profile key the host reads: hle_profile.c read_env takes tex_bc_cpu from the environment as
DM_PROF_TEX_BC_CPU. It used to write DM_TEX_BC_CPU, which nothing reads, so the switch did nothing."""
from __future__ import annotations

import ast
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class OlderDevicesEnvTest(unittest.TestCase):
    def test_the_switch_writes_the_profile_key_the_host_reads(self):
        # Read from the source: importing nspb_qt.model needs PySide6
        tree = ast.parse((ROOT / 'frontend-qt/nspb_qt/model.py').read_text(encoding='utf-8'))
        values = [ast.literal_eval(n.value) for n in tree.body if isinstance(n, ast.Assign)
                  and any(isinstance(t, ast.Name) and t.id == 'BC_ON_CPU_ENV_TEXT' for t in n.targets)]
        self.assertEqual(values, ['DM_PROF_TEX_BC_CPU=1\n'])
        host = ROOT / 'engine/dm/host/hle_profile.c'
        if not host.exists():
            self.skipTest('engine/ is not synced')
        source = host.read_text(encoding='utf-8')
        self.assertIn('"DM_PROF_%s"', source)
        self.assertIn('"TEX_BC_CPU"', source)


if __name__ == '__main__':
    unittest.main()
