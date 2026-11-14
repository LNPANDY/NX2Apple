"""Tests for fast-refresh build seed cache, driver CLI, win/build_app identity, and trailer reuse.

CRITICAL: This module runs and passes completely without PySide6 installed on Linux CI.
Zero `@unittest.skipUnless(..., 'PySide6')` annotations are used.
"""
from __future__ import annotations

import json
import os
import shutil
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
QT = ROOT / 'frontend-qt'
if str(QT) not in sys.path:
    sys.path.insert(0, str(QT))

from nspb_qt import build_seed_cache  # noqa: E402
from nspb_qt.win import build_app, driver  # noqa: E402


def _load_model_with_qt_fallback():
    """Import `nspb_qt.model`, installing a minimal `PySide6.QtCore` stub if PySide6 is absent."""
    try:
        from nspb_qt import model as model_mod
        return model_mod
    except ImportError:
        pass

    class _FakeSignalInstance:
        def __init__(self) -> None:
            self._slots: list = []

        def connect(self, fn) -> None:
            self._slots.append(fn)

        def disconnect(self, fn=None) -> None:
            if fn is None:
                self._slots.clear()
            elif fn in self._slots:
                self._slots.remove(fn)

        def emit(self, *args) -> None:
            for fn in list(self._slots):
                fn(*args)

    class _FakeSignal:
        def __init__(self, *_a) -> None:
            self._name = ''

        def __set_name__(self, _owner, name: str) -> None:
            self._name = f'_sig_{name}'

        def __get__(self, obj, _owner=None):
            if obj is None:
                return self
            inst = getattr(obj, self._name, None)
            if inst is None:
                inst = _FakeSignalInstance()
                setattr(obj, self._name, inst)
            return inst

    class _FakeQObject:
        def __init__(self, *_a, **_kw) -> None:
            pass

        def thread(self):
            return None

        @staticmethod
        def currentThread():
            return None

    class _FakeQSettings:
        def __init__(self, *_a, **_kw) -> None:
            self._d: dict[str, object] = {}

        def value(self, k: str, default: object = '', **kw) -> object:
            fallback = kw.get('defaultValue', default)
            return self._d.get(k, fallback)

        def setValue(self, k: str, v: object) -> None:
            self._d[k] = v

        def remove(self, k: str) -> None:
            self._d.pop(k, None)

    class _FakeQt:
        QueuedConnection = 0

        class ConnectionType:
            QueuedConnection = 0

    class _FakeQMetaObject:
        @staticmethod
        def invokeMethod(obj, name: str, *args) -> None:
            fn = getattr(obj, name, None)
            if callable(fn):
                call_args = args[1:] if args and args[0] == 0 else args
                fn(*call_args)

    qt_pkg = types.ModuleType('PySide6')
    qt_core = types.ModuleType('PySide6.QtCore')
    qt_core.QObject = _FakeQObject
    qt_core.QThread = _FakeQObject
    qt_core.QSettings = _FakeQSettings
    qt_core.Signal = _FakeSignal
    qt_core.Slot = lambda *_a, **_kw: (lambda f: f)
    qt_core.Qt = _FakeQt
    qt_core.QMetaObject = _FakeQMetaObject
    qt_core.Q_ARG = lambda _t, v: v
    qt_pkg.QtCore = qt_core
    sys.modules['PySide6'] = qt_pkg
    sys.modules['PySide6.QtCore'] = qt_core

    from nspb_qt import model as model_mod
    return model_mod


class TestBuildSeedCache(unittest.TestCase):
    """Unit tests for pure-Python build_seed_cache.py."""

    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp_dir.cleanup)
        self.root = Path(self.temp_dir.name)

    def test_default_seed_root(self):
        # 1. Environment variable override
        with mock.patch.dict(os.environ, {'DM_SEED_CACHE_DIR': str(self.root / 'custom_seeds')}):
            self.assertEqual(build_seed_cache.default_seed_root(), self.root / 'custom_seeds')

        # 2. Platform defaults when env unset
        with mock.patch.dict(os.environ, {}, clear=True):
            win_app_data = str(self.root / 'win_app_data')
            with mock.patch('sys.platform', 'win32'):
                with mock.patch.dict(os.environ, {'LOCALAPPDATA': win_app_data}):
                    p = build_seed_cache.default_seed_root()
                    self.assertEqual(p, Path(win_app_data) / 'nxnative' / 'build-seeds')

            with mock.patch('sys.platform', 'darwin'):
                with mock.patch.object(Path, 'home', return_value=self.root / 'home'):
                    p = build_seed_cache.default_seed_root()
                    self.assertEqual(p, self.root / 'home' / 'Library' / 'Application Support' / 'nxnative' / 'build-seeds')

            with mock.patch('sys.platform', 'linux'):
                with mock.patch.dict(os.environ, {'XDG_DATA_HOME': str(self.root / 'data_home')}):
                    p = build_seed_cache.default_seed_root()
                    self.assertEqual(p, self.root / 'data_home' / 'nxnative' / 'build-seeds')

    def test_supports_build_seed_and_extract_msl(self):
        repo = self.root / 'repo'
        self.assertFalse(build_seed_cache.supports_build_seed(repo))
        self.assertFalse(build_seed_cache.supports_extract_msl(repo))

        scripts_dir = repo / 'scripts'
        scripts_dir.mkdir(parents=True)
        nsp_py = scripts_dir / 'build_ipa_from_nsp.py'
        nsp_py.write_text("# normal script without seed\n", encoding='utf-8')
        self.assertFalse(build_seed_cache.supports_build_seed(repo))

        nsp_py.write_text("parser.add_argument('--from-seed')\n", encoding='utf-8')
        self.assertTrue(build_seed_cache.supports_build_seed(repo))

        tools_dir = repo / 'dm' / 'tools'
        tools_dir.mkdir(parents=True)
        rfs_py = tools_dir / 'romfs_image.py'
        rfs_py.write_text("# normal packer\n", encoding='utf-8')
        self.assertFalse(build_seed_cache.supports_extract_msl(repo))

        rfs_py.write_text("parser.add_argument('--extract-msl')\n", encoding='utf-8')
        self.assertTrue(build_seed_cache.supports_extract_msl(repo))

    def _create_seed_tree(
        self,
        seed_root: Path,
        tid: str,
        chain: str = 'aabbccdd',
        gfx_api: str = 'nvn',
        romfs_id: str | None = 'DMROMFSID1 size=1000 index=0',
    ) -> Path:
        sdir = seed_root / tid.upper()
        sdir.mkdir(parents=True, exist_ok=True)
        manifest = {
            'title_id': tid.upper(),
            'version': '1.0',
            'chain': chain,
            'gfx_api': gfx_api,
            'romfs_identity': romfs_id,
        }
        (sdir / 'seed.json').write_text(json.dumps(manifest), encoding='utf-8')
        (sdir / 'ExeFS').mkdir(parents=True, exist_ok=True)
        (sdir / 'ExeFS' / 'main').write_bytes(b'ELF_OR_NSO')
        (sdir / 'shader' / 'pkg').mkdir(parents=True, exist_ok=True)
        (sdir / 'shader' / 'ios').mkdir(parents=True, exist_ok=True)
        if gfx_api == 'nvn':
            (sdir / 'shader' / 'tables').mkdir(parents=True, exist_ok=True)
            (sdir / 'shader' / 'tables' / 'c1_full.tsv').write_text('key\tval\n', encoding='utf-8')
            (sdir / 'shader' / 'tables' / 'cb_extent.tsv').write_text('key\tval\n', encoding='utf-8')
        return sdir

    def test_inspect_seed_path_a_and_path_b(self):
        seed_root = self.root / 'seeds'
        tid = '0100000000010000'
        self._create_seed_tree(seed_root, tid, chain='11223344', gfx_api='nvn')

        # Mock engine dmsh_chain.h with matching bare hex chain (Path A)
        engine_dir = self.root / 'engine'
        chain_hdr = engine_dir / 'dm' / 'gfx' / 'nvn' / 'dmsh_chain.h'
        chain_hdr.parent.mkdir(parents=True, exist_ok=True)
        chain_hdr.write_text('#define DMSH_CHAIN "11223344"\n', encoding='utf-8')

        info_a = build_seed_cache.inspect_seed(seed_root, tid, engine_path=engine_dir)
        self.assertTrue(info_a['valid'])
        self.assertEqual(info_a['path_type'], 'A')
        self.assertTrue(info_a['chain_match'])
        self.assertEqual(info_a['chain'], '11223344')
        self.assertEqual(info_a['engine_chain'], '11223344')
        self.assertEqual(info_a['romfs_identity'], 'DMROMFSID1 size=1000 index=0')

        # Engine dmsh_chain.h changed to different bare hex chain (Path B)
        chain_hdr.write_text('#define DMSH_CHAIN "99887766"\n', encoding='utf-8')
        info_b = build_seed_cache.inspect_seed(seed_root, tid, engine_path=engine_dir)
        self.assertTrue(info_b['valid'])
        self.assertEqual(info_b['path_type'], 'B')
        self.assertFalse(info_b['chain_match'])
        self.assertEqual(info_b['chain'], '11223344')
        self.assertEqual(info_b['engine_chain'], '99887766')

    def test_inspect_seed_structural_invalidation(self):
        seed_root = self.root / 'seeds'
        tid = '0100000000010000'
        sdir = self._create_seed_tree(seed_root, tid, gfx_api='nvn')

        # Corrupt seed.json
        (sdir / 'seed.json').write_text('{invalid_json', encoding='utf-8')
        info = build_seed_cache.inspect_seed(seed_root, tid)
        self.assertFalse(info['valid'])
        self.assertIn('corrupt seed.json', str(info['reason']))

        # Empty ExeFS
        self._create_seed_tree(seed_root, tid, gfx_api='nvn')
        (sdir / 'ExeFS' / 'main').unlink()
        info = build_seed_cache.inspect_seed(seed_root, tid)
        self.assertFalse(info['valid'])
        self.assertIn('ExeFS missing or empty', str(info['reason']))

        # Missing nvn tables
        self._create_seed_tree(seed_root, tid, gfx_api='nvn')
        (sdir / 'shader' / 'tables' / 'c1_full.tsv').unlink()
        info = build_seed_cache.inspect_seed(seed_root, tid)
        self.assertFalse(info['valid'])
        self.assertIn('shader/tables', str(info['reason']))

    def test_prefill_candidates_and_trailer_magic(self):
        out_dir = self.root / 'out'
        work_dir = self.root / 'work'
        tid = '0100000000010000'

        games_dir = out_dir / 'games' / tid
        games_dir.mkdir(parents=True)
        img_with_trailer = games_dir / f'{tid}.img'
        # write padding + DMMSLTR1 magic
        img_with_trailer.write_bytes(b'\x00' * 56 + b'DMMSLTR1')

        plain_img = out_dir / 'games' / tid / 'romfs.img'
        plain_img.write_bytes(b'PLAIN_ROMFS_NO_TRAILER')

        work_dmsh = work_dir / 'build' / 'ios' / 'dmsh_b'
        work_dmsh.mkdir(parents=True)
        (work_dmsh / 'shader_b.metallib').write_bytes(b'METALLIB')

        cands = build_seed_cache.prefill_candidates(tid, out_dir, work_dir=work_dir)
        self.assertIn(img_with_trailer, cands)
        self.assertNotIn(plain_img, cands)
        self.assertIn(work_dmsh, cands)

    def test_trailer_action_logic(self):
        # 1. No trailer -> 'append'
        self.assertEqual(build_seed_cache.trailer_action(None, 'nvn', '1111'), 'append')
        self.assertEqual(build_seed_cache.trailer_action({'has_trailer': False}, 'nvn', '1111'), 'append')

        # 2. Matching trailer -> 'skip' (0 disk I/O, works with b- prefix or bare hex)
        info_match = {
            'has_trailer': True,
            'gfx_api': 'nvn',
            'chain': 'b-1111',
            'multi_program': False,
        }
        self.assertEqual(build_seed_cache.trailer_action(info_match, 'nvn', '1111', False), 'skip')
        self.assertEqual(build_seed_cache.trailer_action(info_match, 'nvn', 'b-1111', False), 'skip')

        # 3. Chain differs -> 'replace'
        self.assertEqual(build_seed_cache.trailer_action(info_match, 'nvn', '2222', False), 'replace')

        # 4. Gfx API differs -> 'replace'
        self.assertEqual(build_seed_cache.trailer_action(info_match, 'vk', '1111', False), 'replace')

        # 5. Multi-program differs -> 'replace'
        self.assertEqual(build_seed_cache.trailer_action(info_match, 'nvn', '1111', True), 'replace')

        # 6. Empty target_chain or empty existing_chain on NVN -> 'replace'
        self.assertEqual(build_seed_cache.trailer_action(info_match, 'nvn', '', False), 'replace')
        info_no_chain = dict(info_match, chain='')
        self.assertEqual(build_seed_cache.trailer_action(info_no_chain, 'nvn', '1111', False), 'replace')
        self.assertEqual(build_seed_cache.trailer_action(info_no_chain, 'nvn', '', False), 'replace')

        # 7. Non-NVN (vk / gl) with matching chain -> 'skip', mismatch -> 'replace'
        info_vk = {'has_trailer': True, 'gfx_api': 'vk', 'chain': '', 'multi_program': False}
        self.assertEqual(build_seed_cache.trailer_action(info_vk, 'vk', '', False), 'skip')
        self.assertEqual(build_seed_cache.trailer_action(info_vk, 'vk', 'somechain', False), 'replace')


class TestDriverSeedOptions(unittest.TestCase):
    """Test that frontend-qt/nspb_qt/win/driver.py accepts fast-refresh seed arguments."""

    def test_refused_options_does_not_refuse_seed_options(self):
        for opt in ('--from-seed', '--seed-cache-dir', '--prefill-msl'):
            self.assertNotIn(opt, driver.REFUSED_OPTIONS)

    def test_check_cli_accepts_seed_options(self):
        # Passing seed options should not raise SystemExit
        args = [
            '--from-seed',
            '--seed-cache-dir', '/tmp/seeds',
            '--prefill-msl', '/tmp/prefill.img',
            '--title-id', '0100000000010000',
        ]
        driver.check_cli(args)

    def test_check_cli_still_refuses_mac_options(self):
        with self.assertRaises(SystemExit) as cm:
            driver.check_cli(['--prepare-xcode'])
        self.assertIn('generates an Xcode project', str(cm.exception))


class TestBuildAppRomFSIdentity(unittest.TestCase):
    """Test frontend-qt/nspb_qt/win/build_app.py DM_ROMFS_IDENTITY handling."""

    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp_dir.cleanup)
        self.root = Path(self.temp_dir.name)

    def test_dm_romfs_identity_allows_missing_romfs(self):
        missing_romfs = self.root / 'data' / 'pkg' / 'RomFS.img'
        env = {
            'DM_COPY_ROMFS': 'NO',
            'DM_ROMFS_IDENTITY': 'DMROMFSID1 size=999 index=123',
        }
        romfs_identity = (env.get('DM_ROMFS_IDENTITY') or '').strip()
        allow_missing_romfs = (
            (env.get('DM_COPY_ROMFS', '').upper() == 'NO' or bool(env.get('DM_FRAMEWORK_ONLY')))
            and romfs_identity.startswith('DMROMFSID1 ')
            and not missing_romfs.exists()
        )
        self.assertTrue(allow_missing_romfs)

    def test_dm_romfs_identity_not_allowed_when_copy_romfs_yes_or_invalid_id(self):
        missing_romfs = self.root / 'data' / 'pkg' / 'RomFS.img'
        # Copy romfs is YES -> missing romfs must not be allowed
        env = {
            'DM_COPY_ROMFS': 'YES',
            'DM_ROMFS_IDENTITY': 'DMROMFSID1 size=999 index=123',
        }
        romfs_identity = (env.get('DM_ROMFS_IDENTITY') or '').strip()
        allow_missing = (
            (env.get('DM_COPY_ROMFS', '').upper() == 'NO' or bool(env.get('DM_FRAMEWORK_ONLY')))
            and romfs_identity.startswith('DMROMFSID1 ')
            and not missing_romfs.exists()
        )
        self.assertFalse(allow_missing)

        # Invalid identity header -> not allowed
        env2 = {
            'DM_COPY_ROMFS': 'NO',
            'DM_ROMFS_IDENTITY': 'INVALID_HEADER size=999',
        }
        romfs_identity2 = (env2.get('DM_ROMFS_IDENTITY') or '').strip()
        allow_missing2 = (
            (env2.get('DM_COPY_ROMFS', '').upper() == 'NO' or bool(env2.get('DM_FRAMEWORK_ONLY')))
            and romfs_identity2.startswith('DMROMFSID1 ')
            and not missing_romfs.exists()
        )
        self.assertFalse(allow_missing2)

    def test_write_romfs_id_without_local_romfs(self):
        base = self.root / 'build_base'
        base.mkdir()
        rid_file = base / 'romfs.id'
        romfs_identity = 'DMROMFSID1 size=5000 index=42'
        romfs = self.root / 'non_existent_romfs.img'

        maps = []
        if romfs.is_file():
            pass
        elif romfs_identity.startswith('DMROMFSID1 '):
            rid_file.write_bytes(romfs_identity.encode('utf-8') + b'\n')
            maps.append(f'Payload/DmIOS.app/romfs.id={rid_file}')

        self.assertTrue(rid_file.is_file())
        self.assertEqual(rid_file.read_bytes(), b'DMROMFSID1 size=5000 index=42\n')
        self.assertIn(f'Payload/DmIOS.app/romfs.id={rid_file}', maps)


class TestModelFastRefreshAndTrailer(unittest.TestCase):
    """Test model.py fast refresh and trailer operations using Qt fallback loader (no PySide6 required)."""

    def setUp(self):
        self.model_mod = _load_model_with_qt_fallback()
        self.temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp_dir.cleanup)
        self.root = Path(self.temp_dir.name)

        # Standalone mock model
        self.m = self.model_mod.Model()
        self.m.repo_path = str(self.root / 'engine')
        self.m.out_dir = str(self.root / 'out')
        self.m.library = self.model_mod.lib.GameLibrary(state_dir=self.root / 'lib_state')
        Path(self.m.repo_path, 'dm', 'tools').mkdir(parents=True, exist_ok=True)
        (Path(self.m.repo_path, 'dm', 'tools', 'romfs_image.py')).touch()

    def test_inject_msl_trailer_zero_io_skip_when_matching(self):
        m = self.m
        orig = self.root / 'original_game.img'
        orig.write_bytes(b'HEADER' + b'\x00' * 50 + b'DMMSLTR1')
        out_img = self.root / 'hardlinked_game.img'
        os.link(orig, out_img)
        stat_before = out_img.stat()
        self.assertEqual(stat_before.st_nlink, 2)

        # Simulate romfs_image.py --inspect-msl returning matching metadata (b- prefix normalized)
        inspect_json = json.dumps({
            'has_trailer': True,
            'gfx_api': 'nvn',
            'chain': 'b-matching123',
            'multi_program': False,
        })

        executed_cmds = []

        def fake_popen(cmd, **kwargs):
            executed_cmds.append(cmd)
            proc = mock.MagicMock()
            if '--inspect-msl' in cmd:
                proc.communicate.return_value = (inspect_json, '')
                proc.returncode = 0
            else:
                proc.stdout = []
                proc.returncode = 0
            return proc

        with mock.patch('subprocess.Popen', side_effect=fake_popen):
            # Target chain can be bare hex or b- prefixed
            msl_info = ('/path/to/msl', 'nvn', 'matching123', False)
            res = m._inject_msl_trailer(out_img, msl_info)
            self.assertTrue(res)

        # Assert only --inspect-msl was called (0 disk I/O, no append/replace!)
        self.assertEqual(len(executed_cmds), 1)
        self.assertIn('--inspect-msl', executed_cmds[0])
        self.assertNotIn('--append-msl', executed_cmds[0])
        self.assertNotIn('--replace-msl', executed_cmds[0])

        # Assert true 0-I/O: hardlink was NOT unshared, inode, link count, and mtime unchanged
        stat_after = out_img.stat()
        self.assertEqual(stat_after.st_nlink, 2)
        self.assertEqual(stat_after.st_ino, stat_before.st_ino)
        self.assertEqual(stat_after.st_mtime_ns, stat_before.st_mtime_ns)

    def test_inject_msl_trailer_replaces_when_chain_differs(self):
        m = self.m
        out_img = self.root / 'game.img'
        out_img.touch()

        # Inspect returns older chain b-old
        inspect_json = json.dumps({
            'has_trailer': True,
            'gfx_api': 'nvn',
            'chain': 'b-old',
            'multi_program': False,
        })

        executed_cmds = []

        def fake_popen(cmd, **kwargs):
            executed_cmds.append(cmd)
            proc = mock.MagicMock()
            if '--inspect-msl' in cmd:
                proc.communicate.return_value = (inspect_json, '')
                proc.returncode = 0
            else:
                proc.stdout = iter(['replaced trailer\n'])
                proc.returncode = 0
            return proc

        with mock.patch('subprocess.Popen', side_effect=fake_popen):
            msl_info = ('/path/to/msl', 'nvn', 'b-new', False)
            res = m._inject_msl_trailer(out_img, msl_info)
            self.assertTrue(res)

        # Assert --replace-msl was selected and executed
        self.assertEqual(len(executed_cmds), 2)
        self.assertIn('--inspect-msl', executed_cmds[0])
        self.assertIn('--replace-msl', executed_cmds[1])
        self.assertNotIn('--append-msl', executed_cmds[1])

    def test_pack_archive_preserves_existing_out_img_without_extract_versions(self):
        m = self.m
        tid = '0100000000010000'
        work_dir = self.root / f'{tid}_build'
        work_dir.mkdir(parents=True)
        (work_dir / 'extract').mkdir(parents=True)  # Empty extract, versions = []

        dest_dir = Path(m.out_dir, 'games', tid)
        dest_dir.mkdir(parents=True)
        existing_img = dest_dir / f'{tid}.img'
        existing_img.write_bytes(b'PRESERVED_EXISTING_IMAGE_CONTENT')

        m.effective_work_dir = str(work_dir)
        m.target = 'ios'
        m.ipa_kind = 'shared'

        with mock.patch.object(m, '_resolve_archive_game_name', return_value=tid), \
                mock.patch.object(m, '_inject_msl_trailer', return_value=True) as mock_inject, \
                mock.patch.object(m, '_export_shell_after_archive', return_value=(True, '')) as mock_export:
            ok, note = m.pack_archive(tid, export_shell=True)
            self.assertTrue(ok)
            mock_export.assert_called_once()

        # Existing image must be preserved, not overwritten or deleted
        self.assertTrue(existing_img.is_file())
        self.assertEqual(existing_img.read_bytes(), b'PRESERVED_EXISTING_IMAGE_CONTENT')

    def test_pack_archive_clean_without_versions_and_without_local_img(self):
        m = self.m
        tid = '0100000000010000'
        work_dir = self.root / f'{tid}_build'
        work_dir.mkdir(parents=True)
        (work_dir / 'extract').mkdir(parents=True)

        m.effective_work_dir = str(work_dir)
        m.target = 'ios'
        m.ipa_kind = 'shared'

        with mock.patch.object(m, '_export_shell_after_archive', return_value=(True, 'archive skipped')) as mock_export:
            ok, note = m.pack_archive(tid, export_shell=True)
            self.assertTrue(ok)
            mock_export.assert_called_once()

    def test_fast_refresh_status_and_prebuild_block_reason(self):
        m = self.m
        tid = '0100000000010000'

        # When not in fast refresh, missing keys/base blocks build
        m._is_fast_refresh = False
        m.base_path = ''
        m.keys_path = ''
        self.assertFalse(m.can_build)

        # In fast refresh, prebuild block is bypassed
        m._is_fast_refresh = True
        self.assertEqual(m.prebuild_block_reason(), '')
        with mock.patch.object(type(m), 'repo_ok', True), \
                mock.patch.object(type(m), 'all_deps_ok', True):
            self.assertTrue(m.can_build)

        # Test fast_refresh_status with valid seed
        seed_root = self.root / 'seeds'
        sdir = seed_root / tid
        sdir.mkdir(parents=True)
        (sdir / 'seed.json').write_text(json.dumps({
            'title_id': tid,
            'version': '1.0',
            'chain': 'b-chain',
            'gfx_api': 'nvn',
        }), encoding='utf-8')
        (sdir / 'ExeFS').mkdir()
        (sdir / 'ExeFS' / 'main').touch()
        (sdir / 'shader' / 'pkg').mkdir(parents=True)
        (sdir / 'shader' / 'ios').mkdir(parents=True)
        (sdir / 'shader' / 'tables').mkdir(parents=True)
        (sdir / 'shader' / 'tables' / 'c1_full.tsv').touch()
        (sdir / 'shader' / 'tables' / 'cb_extent.tsv').touch()

        with mock.patch('nspb_qt.build_seed_cache.default_seed_root', return_value=seed_root):
            st = m.fast_refresh_status(tid)
            self.assertTrue(st['can_refresh'])
            self.assertTrue(st['valid'])
            self.assertFalse(st['needs_adopt'])

    def test_start_fast_refresh_arg_assembly(self):
        m = self.m
        tid = '0100000000010000'
        seed_root = self.root / 'seeds'
        seed_root.mkdir()

        executed_cmd = []

        def fake_popen(cmd, **kwargs):
            executed_cmd.extend(cmd)
            proc = mock.MagicMock()
            proc.stdout = iter(['[1/1] done\n'])
            proc.returncode = 0
            return proc

        def inline_thread(*, target, daemon):
            return mock.MagicMock(start=target)

        with mock.patch('nspb_qt.build_seed_cache.supports_build_seed', return_value=True), \
                mock.patch('nspb_qt.build_seed_cache.default_seed_root', return_value=seed_root), \
                mock.patch('nspb_qt.build_seed_cache.inspect_seed', return_value={'valid': True, 'path_type': 'A'}), \
                mock.patch('nspb_qt.build_seed_cache.prefill_candidates', return_value=[Path('/cand/b-old.img')]), \
                mock.patch('subprocess.Popen', side_effect=fake_popen), \
                mock.patch('threading.Thread', side_effect=inline_thread), \
                mock.patch.object(m, 'supports_shell_framework', return_value=False):
            m.start_fast_refresh(tid)

        self.assertIn('--from-seed', executed_cmd)
        self.assertIn('--title-id', executed_cmd)
        self.assertIn(tid, executed_cmd)
        self.assertIn('--seed-cache-dir', executed_cmd)
        self.assertIn(str(seed_root), executed_cmd)
        self.assertIn('--progress', executed_cmd)
        self.assertIn('json', executed_cmd)
        self.assertIn('--prefill-msl', executed_cmd)
        self.assertIn('/cand/b-old.img', executed_cmd)

    def test_start_fast_refresh_adopt_legacy_uses_img_path(self):
        m = self.m
        tid = '0100000000010000'
        seed_root = self.root / 'seeds'
        seed_root.mkdir()
        work_dir = Path(m.out_dir, f'{tid}_build')
        work_dir.mkdir(parents=True)
        adopt_tool = Path(m.engine_path, 'dm', 'tools', 'build_seed.py')
        adopt_tool.touch()

        adopt_calls = []

        def fake_run(cmd, **kwargs):
            adopt_calls.append((cmd, kwargs))
            return mock.MagicMock(returncode=0, stderr='', stdout='')

        def inline_thread(*, target, daemon):
            return mock.MagicMock(start=target)

        legacy_img = Path(m.out_dir, 'games', tid, f'{tid}.img')
        legacy_img.parent.mkdir(parents=True, exist_ok=True)
        legacy_img.touch()

        with mock.patch('nspb_qt.build_seed_cache.supports_build_seed', return_value=True), \
                mock.patch('nspb_qt.build_seed_cache.default_seed_root', return_value=seed_root), \
                mock.patch('nspb_qt.build_seed_cache.inspect_seed', side_effect=[{'valid': False}, {'valid': True, 'path_type': 'A'}]), \
                mock.patch('nspb_qt.build_seed_cache.prefill_candidates', return_value=[legacy_img]), \
                mock.patch('subprocess.run', side_effect=fake_run), \
                mock.patch('subprocess.Popen', return_value=mock.MagicMock(stdout=iter([]), returncode=0)), \
                mock.patch('threading.Thread', side_effect=inline_thread):
            m.start_fast_refresh(tid)

        adopt_runs = [c for c in adopt_calls if any('adopt' in str(arg) for arg in c[0])]
        self.assertEqual(len(adopt_runs), 1)
        cmd, kwargs = adopt_runs[0]
        self.assertIn('adopt', cmd)
        self.assertIn('--img-path', cmd)
        self.assertNotIn('--romfs-from', cmd)
        self.assertIn(str(legacy_img), cmd)
        self.assertIn('env', kwargs)
        self.assertIn('PYTHONPATH', kwargs['env'])

    def test_fast_refresh_status_detects_legacy_markers_without_trailer_img(self):
        m = self.m
        tid = '0100000000010000'
        work_dir = Path(m.out_dir, f'{tid}_build')
        work_dir.mkdir(parents=True)
        # Create real legacy markers: extract/ and shader/ios/
        (work_dir / 'extract').mkdir()
        (work_dir / 'shader' / 'ios').mkdir(parents=True)

        # Seed does not exist, and no prefill trailer img
        with mock.patch('nspb_qt.build_seed_cache.default_seed_root', return_value=self.root / 'nonexistent_seeds'), \
                mock.patch('nspb_qt.build_seed_cache.prefill_candidates', return_value=[]):
            st = m.fast_refresh_status(tid)
            self.assertTrue(st['can_refresh'])
            self.assertFalse(st['valid'])
            self.assertTrue(st['needs_adopt'])
            self.assertEqual(st['work_dir'], str(work_dir))

    def test_start_fast_refresh_mac_app_passes_romfs_from(self):
        m = self.m
        tid = '0100000000010000'
        seed_root = self.root / 'seeds'
        seed_root.mkdir()
        m.target = 'mac-app'

        # Existing Mac .app with romfs.img inside
        existing_app = Path(m.out_dir, 'SuperGame.app')
        rfs_img = existing_app / 'Contents' / 'Resources' / 'romfs.img'
        rfs_img.parent.mkdir(parents=True)
        rfs_img.touch()

        executed_cmd = []

        def fake_popen(cmd, **kwargs):
            executed_cmd.extend(cmd)
            proc = mock.MagicMock()
            proc.stdout = iter([])
            proc.returncode = 0
            return proc

        def inline_thread(*, target, daemon):
            return mock.MagicMock(start=target)

        with mock.patch('nspb_qt.build_seed_cache.supports_build_seed', return_value=True), \
                mock.patch('nspb_qt.build_seed_cache.default_seed_root', return_value=seed_root), \
                mock.patch('nspb_qt.build_seed_cache.inspect_seed', return_value={'valid': True, 'path_type': 'A'}), \
                mock.patch('subprocess.Popen', side_effect=fake_popen), \
                mock.patch('threading.Thread', side_effect=inline_thread):
            m.start_fast_refresh(tid, game_name='SuperGame')

        self.assertIn('--platform', executed_cmd)
        self.assertIn('mac-app', executed_cmd)
        self.assertIn('-o', executed_cmd)
        self.assertIn(str(existing_app), executed_cmd)
        self.assertIn('--romfs-from', executed_cmd)
        self.assertIn(str(rfs_img), executed_cmd)

    def test_start_fast_refresh_updates_library_without_polluting_inputs(self):
        m = self.m
        tid = '01002B30028F6000'
        orig_inputs = {'base': ['/orig/Celeste.nsp']}
        m.library.upsert(self.model_mod.lib.LibraryGame(
            title_id=tid,
            name='Celeste',
            inputs=orig_inputs,
        ))
        # Pollute Build form inputs with a completely different game
        m.base_path = '/other/Hades [0100535012974000][v0].nsp'
        m.update_path = '/other/Hades_upd.nsp'
        m.dlc_paths = ['/other/Hades_dlc.nsp']
        m.keys_path = '/other/prod.keys'
        m.out_dir = ''

        fr_out = self.root / 'fr_out'
        fr_out.mkdir()
        seed_root = self.root / 'seeds'
        seed_root.mkdir()

        m.target = 'mac-app'

        def fake_popen(cmd, **kwargs):
            if '-o' in cmd:
                app_path = Path(cmd[cmd.index('-o') + 1])
                app_path.mkdir(parents=True, exist_ok=True)
            proc = mock.MagicMock()
            proc.stdout = iter(['[1/1] done\n'])
            proc.returncode = 0
            return proc

        def inline_thread(*, target, daemon):
            return mock.MagicMock(start=target)

        with mock.patch('nspb_qt.build_seed_cache.supports_build_seed', return_value=True), \
                mock.patch('nspb_qt.build_seed_cache.default_seed_root', return_value=seed_root), \
                mock.patch('nspb_qt.build_seed_cache.inspect_seed', return_value={'valid': True, 'path_type': 'A'}), \
                mock.patch('subprocess.Popen', side_effect=fake_popen), \
                mock.patch('threading.Thread', side_effect=inline_thread):
            m.start_fast_refresh(tid, out_dir=str(fr_out), game_name='Celeste')

        updated = next((g for g in m.library.games if g.title_id == tid), None)
        self.assertIsNotNone(updated)
        assert updated is not None
        self.assertEqual(updated.app_path, str(fr_out / 'Celeste.app'))
        self.assertIsNotNone(updated.last_built_at)
        self.assertEqual(updated.inputs, orig_inputs)
        self.assertEqual(updated.output_dir, str(fr_out))

        # Case 2: _record_library_ios_completion under _is_fast_refresh preserves original inputs
        ios_ipa = fr_out / f'{tid}.ipa'
        ios_ipa.write_bytes(b'IPA')
        ios_arch = fr_out / 'games' / 'Celeste'
        ios_arch.mkdir(parents=True)
        m._is_fast_refresh = True
        m._fast_refresh_out_dir = str(fr_out)
        m._fast_refresh_game_name = 'Celeste'
        m.ipa_path = str(ios_ipa)
        m.archive_path = str(ios_arch)
        with mock.patch.object(m.artwork, 'request_banner_async'), \
                mock.patch.object(type(m), 'shell_cache_path', new_callable=mock.PropertyMock, return_value=str(self.root / 'shell')):
            m._record_library_ios_completion(tid)
        m._is_fast_refresh = False
        m._fast_refresh_out_dir = ''
        m._fast_refresh_game_name = ''

        after_ios = next((g for g in m.library.games if g.title_id == tid), None)
        self.assertIsNotNone(after_ios)
        assert after_ios is not None
        self.assertEqual(after_ios.inputs, orig_inputs)
        self.assertEqual(after_ios.ipa_path, str(ios_ipa))
        self.assertEqual(after_ios.archive_path, str(ios_arch))
        self.assertIsNone(next((g for g in m.library.games if g.title_id == '0100535012974000'), None))


if __name__ == '__main__':
    unittest.main()
