"""Which engine the Qt front end builds from (LNPANDY/NX2Apple#214): the checkout's engine/ (synced first when it is stale or missing),
or a folder that is an engine tree itself (an installed release's engine)."""
from __future__ import annotations

import importlib
import io
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

    def test_stamp_key_ignores_crlf_line_endings(self):
        self.new_layout()
        self.touch('patches/fork_env_switches.tsv', 'name\tclass\tmeaning\nDM_X\tdebug\tx\n')
        lf_key = engine.stamp_key(self.r)
        for rel in ('.upstream-ref', 'patches/series', 'patches/0001-a.patch', 'patches/fork_env_switches.tsv'):
            p = self.r / rel
            p.write_bytes(p.read_bytes().replace(b'\r\n', b'\n').replace(b'\n', b'\r\n'))
        self.assertEqual(engine.stamp_key(self.r), lf_key)


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

    def _write_real_manifest(self, eng: Path) -> list[str]:
        sys.path.insert(0, str(ROOT / 'tools'))
        tools_engine = importlib.import_module('engine')
        count = tools_engine.write_files_manifest(eng)
        self.assertGreater(count, 0)
        return (eng / '.engine-files').read_text(encoding='utf-8').splitlines()

    def test_bundled_engine_prunes_stale_upgrade_files_from_real_manifest(self):
        import stat
        eng = self.tree(self.app)
        (eng / '.engine-id').write_text('a' * 40 + '-' + 'b' * 12 + '\n', encoding='utf-8')
        (eng / '.upstream-ref').write_text('a' * 40 + '\n', encoding='utf-8')
        for rel in (
            'dm/games/01007EF00011E000/game.tsv',
            'dm/games/01007EF00011E000/shader_facts.tsv',
            'dm/games/0100F2C0115B6000/game.tsv',
            'dm/games/0100F2C0115B6000/shader_facts.tsv',
            'dm/tools/nx_extract_bin/nx_extract.exe',
            'dm/gfx/tools/spirv_cross_bin/spirv-cross.exe',
        ):
            p = eng / rel
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text('current\n', encoding='utf-8')

        entries = self._write_real_manifest(eng)
        self.assertIn('.engine-id', entries)
        self.assertIn('scripts/build_ipa_from_nsp.py', entries)
        self.assertIn('dm/tools/nx_extract_bin/nx_extract.exe', entries)

        # Simulate stale v1.4.0 / v1.3.0 files + read-only stale file + retired game runtime artifacts.
        stale_files = (
            'dm/games/01007EF00011E000/shader_facts_manual.tsv',
            'dm/games/0100F2C0115B6000/shader_facts_manual.tsv',
            'dm/games/010014C011146000/patches.py',
            'dm/games/010014C011146000/c1_full.tsv',
            'dm/games/010014C011146000/cb_extent.tsv',
            'dm/games/010014C011146000/__pycache__/patches.cpython-312.pyc',
            'scripts/stale_orphan.pyc',
        )
        for rel in stale_files:
            p = eng / rel
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text('stale\n', encoding='utf-8')
        ro_stale = eng / 'dm/games/01007EF00011E000/readonly_old.tsv'
        ro_stale.write_text('ro\n', encoding='utf-8')
        os.chmod(ro_stale, stat.S_IREAD)
        self.addCleanup(lambda: os.chmod(ro_stale, stat.S_IWRITE | stat.S_IREAD) if ro_stale.exists() else None)

        # Runtime derived shader tables for still-managed games and live bytecode caches must survive.
        live_c1 = eng / 'dm/games/01007EF00011E000/c1_full.tsv'
        live_cb = eng / 'dm/games/01007EF00011E000/cb_extent.tsv'
        live_c1.write_text('# chain b-1 inputs abc \n', encoding='utf-8')
        live_cb.write_text('# chain b-1 inputs abc \n', encoding='utf-8')
        live_pycache = eng / 'scripts' / '__pycache__' / 'build_ipa_from_nsp.cpython-312.pyc'
        live_pycache.parent.mkdir(parents=True, exist_ok=True)
        live_pycache.write_bytes(b'pyc')
        live_loose_pyc = eng / 'scripts' / 'build_ipa_from_nsp.pyc'
        live_loose_pyc.write_bytes(b'pyc')

        custom_user = eng / 'custom_notes' / 'keep.txt'
        custom_user.parent.mkdir(parents=True, exist_ok=True)
        custom_user.write_text('user data', encoding='utf-8')
        outside_dir = self.r / 'outside_secret_dir'
        outside_dir.mkdir(parents=True, exist_ok=True)
        outside_file = outside_dir / 'secret.txt'
        outside_file.write_text('do not delete', encoding='utf-8')
        escape_link = eng / 'dm' / 'escape_link'
        try:
            escape_link.symlink_to(outside_dir)
            has_symlink = True
        except OSError:
            has_symlink = False

        # bundled_engine() stays lightweight for Qt UI thread callers and must NOT block on disk walk.
        self.assertEqual(engine.bundled_engine(), str(eng))
        self.assertTrue((eng / stale_files[0]).is_file(), 'bundled_engine() must not prune synchronously on UI thread')

        # Background / explicit entry performs full idempotent pruning.
        pruned = engine.ensure_bundled_engine_pruned()
        self.assertIn(stale_files[0], pruned)
        self.assertIn('dm/games/01007EF00011E000/readonly_old.tsv', pruned)
        for rel in stale_files:
            self.assertFalse((eng / rel).exists(), f'{rel} must be pruned')
        self.assertFalse(ro_stale.exists())
        self.assertFalse((eng / 'dm/games/010014C011146000').exists(), 'retired game dir + orphan __pycache__ must be removed')
        self.assertTrue(live_c1.is_file(), 'c1_full.tsv for still-managed game must survive')
        self.assertTrue(live_cb.is_file(), 'cb_extent.tsv for still-managed game must survive')
        self.assertTrue((eng / 'dm/games/01007EF00011E000/shader_facts.tsv').is_file())
        self.assertTrue((eng / 'dm/games/0100F2C0115B6000/shader_facts.tsv').is_file())
        self.assertTrue((eng / 'dm/tools/nx_extract_bin/nx_extract.exe').is_file())
        self.assertTrue((eng / 'dm/gfx/tools/spirv_cross_bin/spirv-cross.exe').is_file())
        self.assertTrue((eng / 'scripts/build_ipa_from_nsp.py').is_file())
        self.assertTrue(live_pycache.is_file())
        self.assertTrue(live_loose_pyc.is_file())
        self.assertTrue(custom_user.is_file())
        if has_symlink:
            self.assertFalse(escape_link.is_symlink())
            self.assertTrue(outside_file.is_file(), 'symlink target outside engine_dir must never be touched')

    def test_prune_blocks_ntfs_junction_and_never_caches_failed_prune(self):
        eng = self.tree(self.r / 'junc_and_cache')
        (eng / '.engine-id').write_text('a' * 40 + '-' + 'b' * 12 + '\n', encoding='utf-8')
        (eng / 'dm/games/01007EF00011E000/game.tsv').parent.mkdir(parents=True, exist_ok=True)
        (eng / 'dm/games/01007EF00011E000/game.tsv').write_text('ok\n', encoding='utf-8')
        self._write_real_manifest(eng)

        # Simulate a Windows NTFS junction directory (where Path.is_symlink() is False on Windows)
        junc_dir = eng / 'dm' / 'fake_junction'
        junc_dir.mkdir(parents=True)
        inner_secret = junc_dir / 'do_not_delete.txt'
        inner_secret.write_text('target file', encoding='utf-8')
        orig_is_link_or_junc = engine._is_link_or_junction

        def fake_is_junc(p: Path) -> bool:
            return p == junc_dir or orig_is_link_or_junc(p)

        # When _remove_dir_link fails (e.g. non-empty dir fallback rmdir fails), inner files stay untouched
        # and cache must NOT record success so a later run retries.
        with mock.patch.object(engine, '_is_link_or_junction', side_effect=fake_is_junc), \
                mock.patch.object(engine, '_remove_dir_link', return_value=False):
            engine.ensure_bundled_engine_pruned(eng)
        self.assertTrue(inner_secret.is_file(), 'junction target must never be walked/deleted')
        self.assertNotIn(os.path.realpath(eng), engine._PRUNED_BUNDLED, 'failed prune must never poison cache')

        # Now test real unlink failure on a stale file -> cache stays empty -> succeeds when unlocked -> cached thereafter.
        shutil.rmtree(junc_dir)
        stale = eng / 'dm/games/01007EF00011E000/shader_facts_manual.tsv'
        stale.write_text('stale\n', encoding='utf-8')
        with mock.patch.object(engine, '_unlink_file', return_value=False):
            engine.ensure_bundled_engine_pruned(eng)
        self.assertTrue(stale.is_file())
        self.assertNotIn(os.path.realpath(eng), engine._PRUNED_BUNDLED)

        removed = engine.ensure_bundled_engine_pruned(eng)
        self.assertEqual(removed, ['dm/games/01007EF00011E000/shader_facts_manual.tsv'])
        self.assertFalse(stale.exists())
        self.assertIn(os.path.realpath(eng), engine._PRUNED_BUNDLED)
        # Subsequent call with unchanged manifest signature is a cached no-op
        with mock.patch.object(engine, '_prune_stale_bundled_engine_files_checked') as spy:
            self.assertEqual(engine.ensure_bundled_engine_pruned(eng), [])
            spy.assert_not_called()

    def test_model_check_deps_worker_prunes_in_background_thread(self):
        import types
        injected_stub = False
        before_mods = set(sys.modules)
        try:
            try:
                with mock.patch.object(sys, 'frozen', False):
                    from nspb_qt.model import Model
            except ModuleNotFoundError as exc:
                if exc.name != 'PySide6':
                    raise
                injected_stub = True
                qt_pkg = types.ModuleType('PySide6')
                qt_core = types.ModuleType('PySide6.QtCore')

                class _BoundSignal:
                    def connect(self, _cb):
                        pass

                    def emit(self, *_a):
                        pass

                class Signal:
                    def __init__(self, *_a):
                        self._name = ''

                    def __set_name__(self, _owner, name):
                        self._name = f'_sig_{name}'

                    def __get__(self, inst, owner=None):
                        if inst is None:
                            return self
                        sig = getattr(inst, self._name, None)
                        if sig is None:
                            sig = _BoundSignal()
                            setattr(inst, self._name, sig)
                        return sig

                class QObject:
                    def __init__(self, *_a, **_kw):
                        pass

                class QThread:
                    pass

                class Qt:
                    QueuedConnection = object()

                class QMetaObject:
                    @staticmethod
                    def invokeMethod(*_a, **_kw):
                        pass

                class QSettings:
                    IniFormat = 1

                qt_core.QObject = QObject
                qt_core.Signal = Signal
                qt_core.Slot = lambda *_a, **_kw: (lambda fn: fn)
                qt_core.Q_ARG = lambda _t, v: v
                qt_core.QThread = QThread
                qt_core.Qt = Qt
                qt_core.QMetaObject = QMetaObject
                qt_core.QSettings = QSettings
                qt_pkg.QtCore = qt_core
                sys.modules['PySide6'] = qt_pkg
                sys.modules['PySide6.QtCore'] = qt_core
                with mock.patch.object(sys, 'frozen', False):
                    from nspb_qt.model import Model

            m = Model.__new__(Model)
            m.build_upstream = 'nxnative'
            m.repo_path = ''
            with mock.patch.object(engine, 'ensure_bundled_engine_pruned') as prune_spy, \
                    mock.patch.object(Model, '_check_deps', return_value=None):
                m._check_deps_worker()
            prune_spy.assert_called_once()
        finally:
            if injected_stub:
                import nspb_qt
                for mod_name in list(sys.modules):
                    if mod_name not in before_mods and (
                        mod_name == 'PySide6'
                        or mod_name.startswith('PySide6.')
                        or mod_name == 'nspb_qt.model'
                    ):
                        sys.modules.pop(mod_name, None)
                if 'nspb_qt.model' not in before_mods and hasattr(nspb_qt, 'model'):
                    delattr(nspb_qt, 'model')

    def test_win_driver_main_prunes_stale_engine_files_before_loading_upstream(self):
        from nspb_qt.win import driver
        eng = self.tree(self.r / 'isolated_driver_eng')
        (eng / '.engine-id').write_text('a' * 40 + '-' + 'b' * 12 + '\n', encoding='utf-8')
        (eng / 'dm/games/01007EF00011E000/shader_facts.tsv').parent.mkdir(parents=True, exist_ok=True)
        (eng / 'dm/games/01007EF00011E000/shader_facts.tsv').write_text('ok\n', encoding='utf-8')
        self._write_real_manifest(eng)
        stale = eng / 'dm/games/01007EF00011E000/shader_facts_manual.tsv'
        stale.write_text('stale\n', encoding='utf-8')

        seen_stale_during_load: list[bool] = []
        fake_mod = mock.MagicMock()
        fake_mod.cli.return_value = 0

        def fake_load(repo: Path):
            seen_stale_during_load.append(stale.exists())
            return fake_mod

        with mock.patch.dict(os.environ, {'NSPB_REPO': str(eng), 'NSPB_ALLOW_NON_WINDOWS': '1'}), \
                mock.patch.object(driver, 'load_upstream', side_effect=fake_load), \
                mock.patch.object(driver, 'patch', lambda _m, _r: None):
            rc = driver.main(['--help'])
        self.assertEqual(rc, 0)
        self.assertEqual(seen_stale_during_load, [False])
        self.assertFalse(stale.exists())

    def test_prune_never_touches_git_repos_or_corrupt_manifests(self):
        # 1) Directory containing .git (dir or worktree file) must never be pruned
        for git_kind in ('dir', 'file'):
            eng = self.tree(self.r / f'git_{git_kind}')
            (eng / '.engine-id').write_text('a' * 40 + '-' + 'b' * 12 + '\n', encoding='utf-8')
            (eng / 'dm/games/01007EF00011E000').mkdir(parents=True, exist_ok=True)
            (eng / 'dm/games/01007EF00011E000/shader_facts.tsv').write_text('ok\n', encoding='utf-8')
            self._write_real_manifest(eng)
            untracked = eng / 'dm/games/01007EF00011E000/shader_facts_manual.tsv'
            untracked.write_text('keep me\n', encoding='utf-8')
            if git_kind == 'dir':
                (eng / '.git').mkdir()
            else:
                (eng / '.git').write_text('gitdir: ../.git/worktrees/x\n', encoding='utf-8')
            self.assertEqual(engine.prune_stale_bundled_engine_files(eng), [])
            self.assertTrue(untracked.is_file())

        # 2) Empty, truncated (missing scripts/build_ipa_from_nsp.py), malformed, or symlink .engine-files
        bad_cases = (
            '',
            '.engine-id\ndm/games/01007EF00011E000/shader_facts.tsv\n',
            '.engine-id\n../escape\ndm/a\nscripts/build_ipa_from_nsp.py\n',
            '.engine-id\nC:\\bad\\path\ndm/a\nscripts/build_ipa_from_nsp.py\n',
        )
        for idx, payload in enumerate(bad_cases):
            eng = self.tree(self.r / f'bad_{idx}')
            (eng / '.engine-id').write_text('a' * 40 + '-' + 'b' * 12 + '\n', encoding='utf-8')
            target = eng / 'dm/games/01007EF00011E000/shader_facts_manual.tsv'
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text('keep me\n', encoding='utf-8')
            (eng / '.engine-files').write_text(payload, encoding='utf-8')
            self.assertEqual(engine.prune_stale_bundled_engine_files(eng), [])
            self.assertTrue(target.is_file(), f'case {idx} must not delete files')

        # 3) Symlinked .engine-files must be refused
        eng_sym = self.tree(self.r / 'sym_manifest')
        (eng_sym / '.engine-id').write_text('a' * 40 + '-' + 'b' * 12 + '\n', encoding='utf-8')
        keep_file = eng_sym / 'dm/games/01007EF00011E000/shader_facts_manual.tsv'
        keep_file.parent.mkdir(parents=True, exist_ok=True)
        keep_file.write_text('keep me\n', encoding='utf-8')
        real_manifest = self.r / 'real_manifest.txt'
        real_manifest.write_text('.engine-id\ndm/a\nscripts/build_ipa_from_nsp.py\n', encoding='utf-8')
        try:
            (eng_sym / '.engine-files').symlink_to(real_manifest)
            self.assertEqual(engine.prune_stale_bundled_engine_files(eng_sym), [])
            self.assertTrue(keep_file.is_file())
        except OSError:
            pass


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

    def test_sync_closes_the_output_pipe_after_success_or_failure(self):
        for status in (0, 1):
            with self.subTest(status=status):
                output = io.StringIO('engine: sync output\n')
                process = mock.Mock(stdout=output, **{'wait.return_value': status})
                self.addCleanup(output.close)
                lines: list[str] = []
                with mock.patch.object(engine.subprocess, 'Popen', return_value=process):
                    engine.run_sync(['unused'], str(self.r), lines.append)
                self.assertTrue(output.closed)
                self.assertEqual(lines, ['engine: sync output\n'])
                process.wait.assert_called_once_with()

    def test_a_tool_that_cannot_start_is_a_general_stop(self):
        lines: list[str] = []
        ok, kind = engine.run_sync([str(self.r / 'no-such-python')], str(self.r), lines.append)
        self.assertEqual((ok, kind), (False, engine.ENGINE_SYNC))
        self.assertTrue(lines)


class MultiUpstreamDetectionTests(unittest.TestCase):
    def setUp(self):
        self.r = Path(tempfile.mkdtemp(prefix='qt-upstream-'))
        self.addCleanup(shutil.rmtree, self.r, True)

    def touch(self, rel: str | Path, text: str = 'x') -> None:
        f = self.r / rel
        f.parent.mkdir(parents=True, exist_ok=True)
        f.write_text(text)

    def test_detection_for_empty_and_unknown_directories(self):
        self.assertIsNone(engine.detect_upstream(''))
        self.assertIsNone(engine.detect_upstream(str(self.r)))
        self.assertFalse(engine.is_upstream_tree('', 'nxnative'))
        self.assertFalse(engine.is_upstream_tree(str(self.r), 'nxnative'))
        self.assertFalse(engine.is_upstream_tree(str(self.r), 's2arm'))
        self.assertFalse(engine.is_upstream_tree(str(self.r), 'macnativegames'))

    def test_detection_for_nxnative(self):
        self.touch(MARKER)
        self.assertTrue(engine.is_upstream_tree(str(self.r), 'nxnative'))
        self.assertEqual(engine.detect_upstream(str(self.r)), 'nxnative')
        self.assertTrue(engine.is_checkout(str(self.r)))

    def test_detection_for_s2arm(self):
        self.touch('pack/jobs/main.py')
        self.touch('runtime/rewriter/rewriter.c')
        self.assertTrue(engine.is_upstream_tree(str(self.r), 's2arm'))
        self.assertFalse(engine.is_upstream_tree(str(self.r), 'nxnative'))
        self.assertEqual(engine.detect_upstream(str(self.r)), 's2arm')
        self.assertFalse(engine.is_checkout(str(self.r)))

    def test_detection_for_macnativegames(self):
        self.touch('build_app.py')
        self.touch('games/totk/README.md')
        self.assertTrue(engine.is_upstream_tree(str(self.r), 'macnativegames'))
        self.assertFalse(engine.is_upstream_tree(str(self.r), 'nxnative'))
        self.assertEqual(engine.detect_upstream(str(self.r)), 'macnativegames')
        self.assertFalse(engine.is_checkout(str(self.r)))


if __name__ == '__main__':
    unittest.main()
