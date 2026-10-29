"""Which engine the Qt front end builds from (LNPANDY/NX2Apple#214): engine/ when synced and current, the committed tree of a
checkout from before the switch, and engine/ as the only choice (with a sync first) once the committed tree is gone."""
from __future__ import annotations

import importlib
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'frontend-qt'))

engine = importlib.import_module('nspb_qt.engine')

MARKER = Path('dm/tools/nx_extract/Program.cs')
PIN = 'a' * 40


class EngineLayoutTests(unittest.TestCase):
    def setUp(self):
        self.r = Path(tempfile.mkdtemp(prefix='qt-engine-'))
        self.addCleanup(shutil.rmtree, self.r, True)

    def touch(self, rel: str | Path, text: str = 'x') -> None:
        f = self.r / rel
        f.parent.mkdir(parents=True, exist_ok=True)
        f.write_text(text)

    def new_layout(self) -> None:
        """tools/engine.py, the pin and a one-patch series."""
        self.touch('tools/engine.py')
        self.touch('.upstream-ref', PIN + '\n')
        self.touch('patches/series', '# order\n0001-a.patch\n')
        self.touch('patches/0001-a.patch', 'patch text\n')

    def synced_engine(self) -> None:
        """engine/ as sync leaves it: the tree, a branch, and the stamp naming the key and the head."""
        self.touch(Path('engine') / MARKER)
        self.touch('engine/.git/HEAD', 'ref: refs/heads/nx2apple\n')
        self.touch('engine/.git/refs/heads/nx2apple', 'b' * 40 + '\n')
        self.touch('engine/.git/nx2apple-stamp', f'nx2apple-engine 1\npin {PIN}\nkey {engine.stamp_key(self.r)}\nhead {"b" * 40}\n')

    def test_a_checkout_from_before_the_switch_uses_its_committed_tree(self):
        self.touch(MARKER)
        self.assertTrue(engine.is_checkout(str(self.r)))
        self.assertEqual(engine.engine_root(str(self.r)), str(self.r))
        self.assertFalse(engine.is_stale(str(self.r)))

    def test_a_current_engine_wins_over_the_committed_tree(self):
        self.touch(MARKER)
        self.new_layout()
        self.synced_engine()
        self.assertFalse(engine.is_stale(str(self.r)))
        self.assertEqual(engine.engine_root(str(self.r)), str(self.r / 'engine'))

    def test_a_stale_engine_falls_back_to_the_committed_tree(self):
        self.touch(MARKER)
        self.new_layout()
        self.synced_engine()
        self.touch('patches/0001-a.patch', 'changed\n')
        self.assertTrue(engine.is_stale(str(self.r)))
        self.assertEqual(engine.engine_root(str(self.r)), str(self.r))
        self.assertFalse(engine.needs_sync_before_build(str(self.r)))

    def test_a_commit_made_in_engine_makes_it_stale(self):
        self.new_layout()
        self.synced_engine()
        self.touch('engine/.git/refs/heads/nx2apple', 'c' * 40 + '\n')
        self.assertTrue(engine.is_stale(str(self.r)))

    def test_without_a_committed_tree_the_engine_is_synced_before_a_build(self):
        self.new_layout()
        self.assertTrue(engine.is_checkout(str(self.r)))
        self.assertTrue(engine.needs_sync_before_build(str(self.r)))
        self.assertEqual(engine.engine_root(str(self.r)), str(self.r / 'engine'))
        self.synced_engine()
        self.assertFalse(engine.needs_sync_before_build(str(self.r)))

    def test_the_sync_command_runs_the_checkouts_tool(self):
        self.assertEqual(engine.sync_command('/c', 'py'), ['py', str(Path('/c/tools/engine.py')), 'sync'])


if __name__ == '__main__':
    unittest.main()
