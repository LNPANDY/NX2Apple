"""Which engine the Qt front end builds from (LNPANDY/NX2Apple#214): the checkout's engine/ (synced first when it is stale or missing),
or a folder that is an engine tree itself (an installed release's engine)."""
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

    def test_an_engine_tree_is_its_own_root(self):
        self.touch(MARKER)
        self.assertTrue(engine.is_checkout(str(self.r)))
        self.assertEqual(engine.engine_root(str(self.r)), str(self.r))
        self.assertFalse(engine.is_stale(str(self.r)))
        self.assertFalse(engine.needs_sync_before_build(str(self.r)))

    def test_a_checkout_builds_from_engine_whether_it_is_current_or_stale(self):
        self.new_layout()
        self.synced_engine()
        self.assertFalse(engine.is_stale(str(self.r)))
        self.assertEqual(engine.engine_root(str(self.r)), str(self.r / 'engine'))
        self.touch('patches/0001-a.patch', 'changed\n')
        self.assertTrue(engine.is_stale(str(self.r)))
        self.assertEqual(engine.engine_root(str(self.r)), str(self.r / 'engine'))   # no committed tree to fall back to
        self.assertTrue(engine.needs_sync_before_build(str(self.r)))

    def test_a_commit_made_in_engine_makes_it_stale(self):
        self.new_layout()
        self.synced_engine()
        self.touch('engine/.git/refs/heads/nx2apple', 'c' * 40 + '\n')
        self.assertTrue(engine.is_stale(str(self.r)))

    def test_a_checkout_without_an_engine_is_synced_before_a_build(self):
        self.new_layout()
        self.assertTrue(engine.is_checkout(str(self.r)))
        self.assertTrue(engine.needs_sync_before_build(str(self.r)))
        self.assertEqual(engine.engine_root(str(self.r)), str(self.r / 'engine'))
        self.synced_engine()
        self.assertFalse(engine.needs_sync_before_build(str(self.r)))

    def test_the_sync_command_runs_the_checkouts_tool(self):
        self.assertEqual(engine.sync_command('/c', 'py'), ['py', str(Path('/c/tools/engine.py')), 'sync'])


class OnlineSync(unittest.TestCase):
    """A release carries no engine: the first start downloads it, and a failed fetch is a failure row (no Qt needed)."""

    def setUp(self):
        self.r = Path(tempfile.mkdtemp(prefix='qt-engine-sync-'))
        self.addCleanup(shutil.rmtree, self.r, True)

    def tool(self, source: str) -> list[str]:
        (self.r / 'engine.py').write_text(source)
        return [sys.executable, str(self.r / 'engine.py')]

    def test_a_failed_fetch_is_the_offline_row_and_any_other_stop_the_general_one(self):
        src = (ROOT / 'tools' / 'engine.py').read_text(encoding='utf-8')
        self.assertIn('cannot fetch ', src, 'tools/engine.py no longer says "cannot fetch": update engine.failure_kind')
        self.assertEqual(engine.failure_kind('engine: cannot fetch aaaaaaaaaaaa from https://github.com/seedds/nxnative.git: Could not resolve host\n'),
                         engine.ENGINE_OFFLINE)
        self.assertEqual(engine.failure_kind('0003-x.patch does not apply to the pin aaaaaaaaaaaa\n'), engine.ENGINE_SYNC)
        self.assertEqual(engine.failure_kind(''), engine.ENGINE_SYNC)

    def test_no_network_ends_in_the_offline_kind_with_the_tools_lines_in_the_log(self):
        cmd = self.tool("import sys\nprint('engine: cannot fetch abc from https://github.com/seedds/nxnative.git: Could not resolve host: github.com')\nsys.exit(2)\n")
        lines: list[str] = []
        ok, kind = engine.run_sync(cmd, str(self.r), lines.append)
        self.assertFalse(ok)
        self.assertEqual(kind, engine.ENGINE_OFFLINE)
        self.assertIn('cannot fetch', ''.join(lines))

    def test_another_stop_is_the_general_kind_and_a_working_sync_has_none(self):
        ok, kind = engine.run_sync(self.tool("import sys\nprint('boom')\nsys.exit(1)\n"), str(self.r), lambda _l: None)
        self.assertEqual((ok, kind), (False, engine.ENGINE_SYNC))
        self.assertEqual(engine.run_sync(self.tool("print('engine: ready')\n"), str(self.r), lambda _l: None), (True, None))

    def test_a_tool_that_cannot_start_is_a_general_stop(self):
        lines: list[str] = []
        ok, kind = engine.run_sync([str(self.r / 'no-such-python')], str(self.r), lines.append)
        self.assertEqual((ok, kind), (False, engine.ENGINE_SYNC))
        self.assertTrue(lines)


if __name__ == '__main__':
    unittest.main()
