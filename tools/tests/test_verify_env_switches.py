"""Tests for tools/verify_env_switches.py."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]
TOOL = REPO / 'tools' / 'verify_env_switches.py'
TABLE = REPO / 'engine' / 'docs' / 'env_switches.tsv'


class VerifyEnvSwitchesTests(unittest.TestCase):
    def setUp(self):
        if not TABLE.is_file():
            self.skipTest('engine/ is missing: run `python3 tools/engine.py sync` first')

    def test_accepts_a_real_switch_and_rejects_an_invented_one(self):
        with tempfile.TemporaryDirectory() as d:
            good = Path(d, 'good.md')
            good.write_text('Set `DM_IMPORTS=1` to see the imports.\n', encoding='utf-8')
            r = subprocess.run([sys.executable, str(TOOL), str(good)], capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

            bad = Path(d, 'bad.md')
            bad.write_text('Set `DM_LOG_UEMALLOC=1` to see the allocations.\n', encoding='utf-8')
            r = subprocess.run([sys.executable, str(TOOL), str(bad)], capture_output=True, text=True)
            self.assertEqual(r.returncode, 1, 'an invented switch must fail the check')
            self.assertIn('DM_LOG_UEMALLOC', r.stdout)

    def test_ignores_a_prefix_and_a_documented_family(self):
        with tempfile.TemporaryDirectory() as d:
            f = Path(d, 'prefixes.md')
            f.write_text('`DM_PROF_<key>` overrides, `DM_NVN_*` are graphics switches, `DM_MEMSTAT` is real.\n', encoding='utf-8')
            r = subprocess.run([sys.executable, str(TOOL), str(f)], capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)


if __name__ == '__main__':
    unittest.main()
