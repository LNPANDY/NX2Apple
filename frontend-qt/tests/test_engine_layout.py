"""Which engine the Qt front end builds from (LNPANDY/NX2Apple#214): the checkout's engine/ (synced first when it is stale or missing),
or a folder that is an engine tree itself (an installed release's engine)."""
from __future__ import annotations

import importlib
import os
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

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


class BundledEngine(unittest.TestCase):
    """The Windows zip carries the engine tree inside the app folder: a player needs no git, repo or sync."""

    def setUp(self):
        self.r = Path(tempfile.mkdtemp(prefix='qt-engine-bundled-')).resolve()   # resolve: bundled_engine() resolves the exe path too
        self.addCleanup(shutil.rmtree, self.r, True)
        self.app = self.r / 'app'
        self.app.mkdir()
        self.exe = self.app / 'NX2Apple.exe'
        self.exe.write_text('x')
        self.set_frozen(True)

    def set_frozen(self, frozen: bool) -> None:
        saved = (getattr(sys, 'frozen', None), sys.executable)
        self.addCleanup(self.restore, *saved)
        if frozen:
            sys.frozen = True
        elif hasattr(sys, 'frozen'):
            del sys.frozen
        sys.executable = str(self.exe)

    @staticmethod
    def restore(frozen, executable) -> None:
        if frozen is None:
            if hasattr(sys, 'frozen'):
                del sys.frozen
        else:
            sys.frozen = frozen
        sys.executable = executable

    def tree(self, base: Path, games: bool = True, script: bool = True) -> Path:
        eng = base / 'engine'
        if games:
            (eng / 'dm' / 'games').mkdir(parents=True, exist_ok=True)
        if script:
            (eng / 'scripts').mkdir(parents=True, exist_ok=True)
            (eng / 'scripts' / 'build_ipa_from_nsp.py').write_text('x')
        return eng

    def checkout(self) -> Path:
        """A repo checkout with tools/engine.py and a synced engine/ (the old route)."""
        repo = self.r / 'repo'
        for rel in ('tools/engine.py', '.upstream-ref'):
            (repo / rel).parent.mkdir(parents=True, exist_ok=True)
            (repo / rel).write_text('x')
        (repo / 'engine' / MARKER).parent.mkdir(parents=True)
        (repo / 'engine' / MARKER).write_text('x')
        return repo

    def test_a_complete_tree_inside_the_app_folder_is_found(self):
        eng = self.tree(self.app)
        self.assertEqual(engine.bundled_engine(), str(eng))

    def test_a_complete_tree_beside_the_app_folder_is_found_too(self):
        eng = self.tree(self.r)
        self.assertEqual(engine.bundled_engine(), str(eng))

    def test_an_incomplete_tree_is_not_a_bundled_engine(self):
        eng = self.tree(self.app, script=False)
        self.assertEqual(engine.bundled_engine(), '')
        self.assertEqual(engine.engine_root(''), '')
        self.assertFalse(engine.is_checkout(''))
        shutil.rmtree(eng)
        self.tree(self.app, games=False)
        self.assertEqual(engine.bundled_engine(), '')

    def test_an_incomplete_tree_leaves_the_repo_route_in_place(self):
        self.tree(self.app, script=False)
        repo = self.checkout()
        self.assertEqual(engine.engine_root(str(repo)), str(repo / 'engine'))
        self.assertTrue(engine.is_checkout(str(repo)))

    def test_no_tree_is_no_bundled_engine(self):
        self.assertEqual(engine.bundled_engine(), '')
        self.assertEqual(engine.engine_root(''), '')

    def test_a_run_that_is_not_frozen_ignores_a_tree_beside_it(self):
        self.tree(self.app)
        self.set_frozen(False)
        self.assertEqual(engine.bundled_engine(), '')
        self.assertEqual(engine.engine_root(''), '')
        self.assertFalse(engine.is_checkout(''))

    def test_a_bundled_tree_is_a_checkout_without_a_repo_path(self):
        eng = self.tree(self.app)
        self.assertTrue(engine.is_checkout(''))
        self.assertEqual(engine.engine_root(''), str(eng))
        self.assertFalse(engine.needs_sync_before_build(''))

    def test_the_bundled_tree_wins_over_a_repo_checkout_and_is_never_stale(self):
        eng = self.tree(self.app)
        repo = self.checkout()   # engine/ has no stamp: without the bundle it is stale
        self.assertEqual(engine.engine_root(str(repo)), str(eng))
        self.assertFalse(engine.is_stale(str(repo)))
        self.assertFalse(engine.needs_sync_before_build(str(repo)))
        self.set_frozen(False)
        self.assertTrue(engine.is_stale(str(repo)))
        self.assertEqual(engine.engine_root(str(repo)), str(repo / 'engine'))

    def test_release_tools_never_clone_or_update_a_selected_git_checkout(self):
        try:
            with mock.patch.object(sys, 'frozen', False):
                from nspb_qt.model import Model
        except ModuleNotFoundError as exc:
            if exc.name == 'PySide6':
                self.skipTest('PySide6 is not installed')
            raise
        bundled = self.tree(self.app)
        checkout = self.checkout()
        (checkout / '.git').mkdir()
        model = Model.__new__(Model)
        model.repo_path = str(checkout)
        with mock.patch.dict(os.environ, {'NSPB_REPO': str(checkout)}):
            self.assertEqual(Path(model._find_repo()).resolve(), bundled.resolve())
        self.assertFalse(model.repo_is_git)
        with mock.patch.object(Model, 'git_binary', side_effect=AssertionError('must not start Git')):
            model.update_repo()
            model.clone_repo()
        self.set_frozen(False)
        self.assertTrue(model.repo_is_git)
        with mock.patch.dict(os.environ, {'NSPB_REPO': str(checkout)}):
            self.assertEqual(model._find_repo(), str(checkout))

    def test_external_venv_python_finds_bundled_engine_via_internal_layout(self):
        """A child venv python has sys.frozen=False, but __file__ is inside _internal/nspb_qt/."""
        self.set_frozen(False)
        eng = self.tree(self.r)
        fake_file = self.app / '_internal' / 'nspb_qt' / 'engine.py'
        fake_file.parent.mkdir(parents=True, exist_ok=True)
        fake_file.write_text('x')
        orig_file = engine.__file__
        try:
            engine.__file__ = str(fake_file)
            self.assertEqual(engine.bundled_engine(), str(eng))
            self.assertEqual(engine.engine_root(''), str(eng))
        finally:
            engine.__file__ = orig_file


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
