"""Tests for PR 4 game update catalog, RomFS identity, refresh queue, and Qt refresh dialogs.

CRITICAL: The core test class runs cleanly without PySide6 installed (verified via an explicit
no-PySide6 import guard test and zero skip markers on core logic).
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
QT = ROOT / 'frontend-qt'
if str(QT) not in sys.path:
    sys.path.insert(0, str(QT))

from nspb_qt import library as lib_mod  # noqa: E402
from nspb_qt import refresh_flow as rf  # noqa: E402


class RefreshFlowCoreTests(unittest.TestCase):
    def setUp(self) -> None:
        rf.clear_romfs_identity_cache()
        self._td = tempfile.TemporaryDirectory()
        self.tmp = Path(self._td.name)

    def tearDown(self) -> None:
        self._td.cleanup()

    def _engine_romfs_tool(self) -> Path:
        tool = ROOT / 'engine' / 'dm' / 'tools' / 'romfs_image.py'
        self.assertTrue(tool.is_file(), f'Expected synced engine tool at {tool}')
        return tool

    def _run_romfs_tool(self, args: list[str]) -> str:
        tool = self._engine_romfs_tool()
        proc = subprocess.run(
            [sys.executable, str(tool), *args],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(proc.returncode, 0, f'romfs_image.py failed: {proc.stdout}\n{proc.stderr}')
        return proc.stdout.strip()

    def _make_repo(self, chain: str = 'a5e7fb6e4fa4') -> Path:
        repo = self.tmp / f'repo-{chain}'
        hdr = repo / 'dm' / 'gfx' / 'nvn' / 'dmsh_chain.h'
        hdr.parent.mkdir(parents=True, exist_ok=True)
        hdr.write_text(f'#define DMSH_CHAIN "{chain}"\n', encoding='utf-8')
        script = repo / 'scripts' / 'build_ipa_from_nsp.py'
        script.parent.mkdir(parents=True, exist_ok=True)
        script.write_text('# --from-seed\n', encoding='utf-8')
        return repo

    def _create_seed(
        self,
        seed_root: Path,
        tid: str,
        *,
        chain: str = 'a5e7fb6e4fa4',
        romfs_identity: str = 'DMROMFSID1 size=64 index=1',
    ) -> None:
        sdir = seed_root / tid.upper()
        (sdir / 'ExeFS').mkdir(parents=True, exist_ok=True)
        (sdir / 'shader' / 'pkg').mkdir(parents=True, exist_ok=True)
        (sdir / 'shader' / 'tables').mkdir(parents=True, exist_ok=True)
        (sdir / 'shader' / 'ios').mkdir(parents=True, exist_ok=True)
        (sdir / 'ExeFS' / 'main').write_bytes(b'bin')
        (sdir / 'shader' / 'tables' / 'c1_full.tsv').write_text('c1', encoding='utf-8')
        (sdir / 'shader' / 'tables' / 'cb_extent.tsv').write_text('cb', encoding='utf-8')
        (sdir / 'shader' / 'ios' / f'b-{chain}.img').write_bytes(b'msl')
        (sdir / 'seed.json').write_text(
            json.dumps(
                {
                    'schema': 1,
                    'title_id': tid.upper(),
                    'base_title_id': tid.upper(),
                    'app_name': 'Sample Game',
                    'gfx_api': 'nvn',
                    'chain': chain,
                    'romfs_identity': romfs_identity,
                }
            ),
            encoding='utf-8',
        )

    def test_import_succeeds_without_pyside6_installed(self) -> None:
        code = (
            'import sys\n'
            'for k in ("PySide6", "PySide6.QtCore", "PySide6.QtGui", "PySide6.QtWidgets"):\n'
            '    sys.modules[k] = None\n'
            f'sys.path.insert(0, {str(QT)!r})\n'
            'from nspb_qt import refresh_flow as mod\n'
            'assert mod.HAS_QT is False\n'
            'assert len(mod.GAME_UPDATED_VERSIONS) == 48\n'
        )
        proc = subprocess.run([sys.executable, '-c', code], capture_output=True, text=True, check=False)
        self.assertEqual(proc.returncode, 0, proc.stderr)

    def test_catalog_48_titles_match_swift_source_exactly(self) -> None:
        self.assertEqual(len(rf.GAME_UPDATED_VERSIONS), 48)
        counts: dict[str, int] = {}
        for ver in rf.GAME_UPDATED_VERSIONS.values():
            counts[ver] = counts.get(ver, 0) + 1
        self.assertEqual(counts, {'1.5.0': 18, '1.4.0': 19, '1.3.0': 8, '1.2.2': 3})
        self.assertEqual(rf.catalog_version_for('0100152000022000'), '1.5.0')
        self.assertEqual(rf.catalog_version_for('0100111100001111'), '1.2.0')
        self.assertEqual(rf.release_base_version('1.5.0-local'), '1.5.0')

        swift_file = ROOT / 'frontend' / 'Sources' / 'NXCore' / 'GameUpdateCatalog.swift'
        swift_txt = swift_file.read_text(encoding='utf-8')
        swift_pairs = dict(re.findall(r'"([0-9A-Fa-f]{16})"\s*:\s*"(\d+\.\d+\.\d+)"', swift_txt))
        self.assertEqual(swift_pairs, rf.GAME_UPDATED_VERSIONS)

    def test_romfs_identity_matches_real_engine_tool_and_rejects_corruption(self) -> None:
        src = self.tmp / 'romfs-src'
        (src / 'sub').mkdir(parents=True, exist_ok=True)
        (src / 'hello.txt').write_text('switch-data\n', encoding='utf-8')
        (src / 'sub' / 'bin.dat').write_bytes(b'\x5A' * 99)

        img = self.tmp / 'game.img'
        self._run_romfs_tool([str(src), str(img)])
        base_id_line = self._run_romfs_tool(['--identity', str(img), '0100152000022000', '1.0', 'abc'])

        parsed = rf.parse_romfs_identity(base_id_line)
        self.assertIsNotNone(parsed)
        assert parsed is not None
        digest = rf.compute_romfs_identity(img)
        self.assertIsNotNone(digest)
        assert digest is not None
        self.assertEqual((digest.size, digest.index), (parsed.size, parsed.index))
        self.assertTrue(rf.matches_romfs_identity(img, base_id_line))

        msl_dir = self.tmp / 'msl'
        msl_dir.mkdir(parents=True, exist_ok=True)
        (msl_dir / 'shader.metallib').write_bytes(b'msl-payload')
        self._run_romfs_tool(['--append-msl', '--gfx-api', 'nvn', '--chain', 'b-a5e7fb6e4fa4', str(img), str(msl_dir)])
        self.assertTrue(rf.matches_romfs_identity(img, base_id_line))

        raw = bytearray(img.read_bytes())
        raw[-1] = 0xFF
        img.write_bytes(raw)
        self.assertIsNone(rf.compute_romfs_identity(img))
        self.assertFalse(rf.matches_romfs_identity(img, base_id_line))

        self.assertIsNone(rf.parse_romfs_identity('DMROMFSID1 title=x size= index=1'))

        overflow = self.tmp / 'overflow.img'
        overflow.write_bytes(b'DMROMFS1' + struct.pack('<QQQ', 0xFFFFFFFFFFFFFFFF, 16, 1))
        self.assertIsNone(rf.compute_romfs_identity(overflow))

        sym = self.tmp / 'sym.img'
        sym.symlink_to(overflow)
        self.assertIsNone(rf.compute_romfs_identity(sym))

    def test_scan_drive_completes_depth1_without_depth0_early_exit(self) -> None:
        src_match = self.tmp / 'src-match'
        src_other = self.tmp / 'src-other'
        src_match.mkdir()
        src_other.mkdir()
        (src_match / 'a.bin').write_bytes(b'match')
        (src_other / 'b.bin').write_bytes(b'other-longer')

        drive = self.tmp / 'usb'
        sub = drive / 'Game (0100152000022000)'
        sub.mkdir(parents=True)
        wrong_d0 = drive / 'wrong.img'
        right_d1 = sub / 'Game.img'
        self._run_romfs_tool([str(src_other), str(wrong_d0)])
        self._run_romfs_tool([str(src_match), str(right_d1)])
        exp_line = self._run_romfs_tool(['--identity', str(right_d1), '0100152000022000'])

        matched = rf.scan_drive_for_matching_img(
            drive,
            '0100152000022000',
            expected_identity=exp_line,
        )
        self.assertEqual(matched, str(right_d1))

        right_d0 = drive / '0100152000022000.img'
        shutil.copy2(right_d1, right_d0)
        os.utime(right_d0, (1_700_000_000, 1_700_000_000))
        os.utime(right_d1, (1_800_000_000, 1_800_000_000))
        matched_d0 = rf.scan_drive_for_matching_img(
            drive,
            '0100152000022000',
            expected_identity=exp_line,
        )
        self.assertEqual(matched_d0, str(right_d0))

    def test_assess_path_b_requires_local_img_for_fast_ios(self) -> None:
        tid = '0100152000022000'
        repo = self._make_repo('newchain0001')
        seeds = self.tmp / 'seeds'
        out_dir = self.tmp / 'out'
        out_dir.mkdir(parents=True, exist_ok=True)
        self._create_seed(seeds, tid, chain='oldchain0001')

        a_no_img = rf.assess_game_refresh(
            title_id=tid,
            is_marked_older=True,
            has_mac_build=False,
            mac_app_path='',
            has_ios_build=True,
            has_readable_source_inputs=False,
            out_dir=str(out_dir),
            game_name='Mario Kart',
            app_version='1.5.0',
            git_specific_changed=True,
            seed_root=seeds,
            engine_path=str(repo),
        )
        self.assertFalse(a_no_img.can_fast_ios)
        self.assertTrue(a_no_img.needs_img_guide_ios)
        self.assertEqual(a_no_img.hero_state, 'specific_full')

        img_file = out_dir / 'games' / 'Mario Kart' / 'Mario Kart.img'
        img_file.parent.mkdir(parents=True, exist_ok=True)
        img_file.write_bytes(b'\x00' * 64 + b'DMMSLTR1')
        a_with_img = rf.assess_game_refresh(
            title_id=tid,
            is_marked_older=True,
            has_mac_build=False,
            mac_app_path='',
            has_ios_build=True,
            has_readable_source_inputs=False,
            out_dir=str(out_dir),
            game_name='Mario Kart',
            app_version='1.5.0',
            git_specific_changed=None,
            seed_root=seeds,
            engine_path=str(repo),
        )
        self.assertTrue(a_with_img.can_fast_ios)
        self.assertFalse(a_with_img.needs_img_guide_ios)
        self.assertEqual(a_with_img.hero_state, 'specific_fast')

    def test_refresh_queue_dual_target_dedup_fast_first_and_single_shell_export(self) -> None:
        class _Sig:
            def __init__(self) -> None:
                self.fns: list = []

            def connect(self, fn) -> None:
                self.fns.append(fn)

            def disconnect(self, fn) -> None:
                if fn in self.fns:
                    self.fns.remove(fn)

            def emit(self, ok: bool, note: str) -> None:
                for fn in list(self.fns):
                    fn(ok, note)

        class _FakeModel:
            def __init__(self, games: list[lib_mod.LibraryGame]) -> None:
                self.running = False
                self.ipa_kind = 'shared'
                self.target = 'mac-app'
                self.base_path = ''
                self.update_path = ''
                self.dlc_paths: list[str] = []
                self.keys_path = ''
                self.out_dir = ''
                self.finished = _Sig()
                self._defer_shell_export = False
                self._queued_external_img_path = ''
                self.started: list[tuple] = []
                self.library = mock.Mock(games=games)

            def t(self, key: str, *_a) -> str:
                return key

            def log(self, _txt: str) -> None:
                pass

            def load_game_from_library(self, _g) -> None:
                pass

            def leave_game_folder(self) -> None:
                pass

            def start_fast_refresh(self, tid: str, **kw) -> None:
                self.started.append(('fast', tid, kw.get('target'), kw.get('export_shell_at_end')))
                self.running = False
                self.finished.emit(True, 'ok')

            def start_build(self, title_id: str = '') -> None:
                self.started.append(('full', title_id, self.target, not self._defer_shell_export))
                self.running = False
                self.finished.emit(True, 'ok')

        tid_a = '0100152000022000'
        tid_b = '010012101468C000'
        fm = _FakeModel([lib_mod.LibraryGame(title_id=tid_a, name='A'), lib_mod.LibraryGame(title_id=tid_b, name='B')])
        qm = rf.RefreshQueueManager(fm)

        added = qm.enqueue_many([
            rf.RefreshQueueItem(title_id=tid_b, target='ios', fast_refresh=False),
            rf.RefreshQueueItem(title_id=tid_a, target='mac-app', fast_refresh=True),
            rf.RefreshQueueItem(title_id=tid_a, target='ios', fast_refresh=True),
            rf.RefreshQueueItem(title_id=tid_a, target='mac-app', fast_refresh=False),
        ])
        self.assertEqual(added, 3)
        self.assertEqual([(it.title_id, it.target, it.fast_refresh) for it in qm.items], [
            (tid_a, 'mac-app', True),
            (tid_a, 'ios', True),
            (tid_b, 'ios', False),
        ])

        qm.start_if_idle()
        self.assertEqual(fm.started, [
            ('fast', tid_a, 'mac-app', False),
            ('fast', tid_a, 'ios', False),
            ('full', tid_b, 'ios', True),
        ])

    def test_pull_img_from_ios_device_strict_subdir_dir_copy_and_cleanup(self) -> None:
        src = self.tmp / 'pull-src'
        src.mkdir()
        (src / 'a.txt').write_text('abc', encoding='utf-8')
        master = self.tmp / 'master.img'
        self._run_romfs_tool([str(src), str(master)])
        exp_line = self._run_romfs_tool(['--identity', str(master), '0100152000022000'])

        dest_dir = self.tmp / 'out' / 'games' / 'Mario Kart'
        fake_xcrun = self.tmp / 'xcrun'
        fake_xcrun.write_text('#!/bin/sh\n', encoding='utf-8')

        class _Proc:
            def __init__(self, args: list[str], mode: str) -> None:
                self.args = args
                self.mode = mode
                self.returncode = 0

            def __enter__(self) -> '_Proc':
                return self

            def __exit__(self, *_a) -> bool:
                return False

            def communicate(self, *_a, **_kw):
                if 'info' in self.args and 'files' in self.args:
                    sub_idx = self.args.index('--subdirectory')
                    subdir = self.args[sub_idx + 1]
                    assert subdir == 'Documents/games/0100152000022000', subdir
                    json_out = self.args[self.args.index('--json-output') + 1]
                    Path(json_out).write_text(
                        json.dumps({
                            'result': {
                                'files': [
                                    {'name': '../escape.img', 'metadata': {'size': 10}},
                                    {'name': 'romfs.img', 'metadata': {'size': 100}},
                                ]
                            }
                        }),
                        encoding='utf-8',
                    )
                elif 'copy' in self.args and 'from' in self.args:
                    dst = Path(self.args[self.args.index('--destination') + 1])
                    if self.mode == 'dir':
                        dst.mkdir(parents=True, exist_ok=True)
                        shutil.copy2(master, dst / 'romfs.img')
                    else:
                        dst.write_bytes(b'corrupt')
                return ('', '')

            def poll(self):
                return self.returncode

        with mock.patch.object(rf.sys, 'platform', 'darwin'), \
             mock.patch('nspb_qt.refresh_flow.subprocess.Popen', side_effect=lambda a, **_kw: _Proc(a, 'dir')):
            ok, out_path = rf.pull_img_from_ios_device(
                device_id='UDID-1',
                bundle_id='org.nxnative.shell',
                title_id='0100152000022000',
                dest_dir=dest_dir,
                dest_filename='Mario Kart.img',
                expected_identity=exp_line,
                xcrun_path=str(fake_xcrun),
            )
        self.assertTrue(ok, out_path)
        self.assertTrue(Path(out_path).is_file())
        self.assertTrue(Path(f'{out_path}.id').is_file())

        dest_bad = self.tmp / 'out_bad' / 'games' / 'Mario Kart'
        with mock.patch.object(rf.sys, 'platform', 'darwin'), \
             mock.patch('nspb_qt.refresh_flow.subprocess.Popen', side_effect=lambda a, **_kw: _Proc(a, 'bad')):
            ok_bad, _msg = rf.pull_img_from_ios_device(
                device_id='UDID-1',
                bundle_id='org.nxnative.shell',
                title_id='0100152000022000',
                dest_dir=dest_bad,
                dest_filename='Mario Kart.img',
                expected_identity=exp_line,
                xcrun_path=str(fake_xcrun),
            )
        self.assertFalse(ok_bad)
        self.assertFalse(any('.pull.tmp' in p.name for p in dest_bad.iterdir()))


if rf.HAS_QT:
    from PySide6.QtWidgets import QApplication, QDialog, QFileDialog
    from nspb_qt.model import Model
    from nspb_qt.widgets import HeroBannerWidget

    class RefreshQtDialogsTests(unittest.TestCase):
        @classmethod
        def setUpClass(cls) -> None:
            cls._app = QApplication.instance() or QApplication([])

        def test_hero_banner_and_dialogs_and_non_native_qfiledialog(self) -> None:
            with tempfile.TemporaryDirectory() as td:
                root = Path(td)
                from PySide6.QtCore import QSettings
                from nspb_qt import model as model_mod

                with mock.patch.object(lib_mod, 'default_state_dir', return_value=root / 'state'), \
                     mock.patch.object(model_mod, 'QSettings', side_effect=lambda *a, **kw: QSettings(str(root / 's.ini'), QSettings.IniFormat)), \
                     mock.patch.object(Model, 'check_deps', lambda _self: None), \
                     mock.patch.object(lib_mod.ArtworkStore, 'request_banner_async'):
                    m = Model()
                    hero = HeroBannerWidget()
                    hero.set_data(
                        '0100152000022000',
                        'Mario Kart 8',
                        '0100152000022000',
                        m.t('library.readyMacAndIOS'),
                        '#52d97a',
                        m.t('library.play'),
                        True,
                        m.t('library.manage'),
                        None,
                        update_badge_text=m.t('library.refresh.badgeVersion', '1.5.0'),
                        refresh_label=m.t('library.refresh.fastBtn'),
                        batch_refresh_label=m.t('library.refresh.batchBtn', 2),
                        refresh_note=m.t('library.refresh.noteSpecificFast', 'Mario Kart 8', '1.5.0'),
                    )
                    self.assertIn(m.t('library.readyMacAndIOS').upper(), hero.status_lbl.text())
                    self.assertFalse(hero.refresh_btn.isHidden())

                    (root / 'MK8.app').mkdir(parents=True, exist_ok=True)
                    (root / 'MK8.ipa').write_bytes(b'ipa')
                    game = lib_mod.LibraryGame(
                        title_id='0100152000022000',
                        name='Mario Kart 8',
                        app_path=str(root / 'MK8.app'),
                        ipa_path=str(root / 'MK8.ipa'),
                    )
                    assess = rf.GameRefreshAssessment(
                        state='specific_fast',
                        has_specific_update=True,
                        version_label='1.5.0',
                        can_fast_mac=True,
                        can_fast_ios=False,
                        needs_img_guide_ios=True,
                        missing_original_package=True,
                    )
                    bd = rf.BatchRefreshDialog(m, [rf.BatchRefreshEntry(game=game, assessment=assess)])
                    self.assertEqual(bd.width(), 680)
                    self.assertEqual(len(bd._checkboxes), 2)
                    self.assertTrue(bd._checkboxes[0][0].isEnabled())
                    self.assertFalse(bd._checkboxes[1][0].isEnabled())
                    bd.close()
                    bd.deleteLater()

                    non_native_flags: list[bool] = []

                    class _TrackingQFileDialog(QFileDialog):
                        def exec(self) -> int:
                            non_native_flags.append(bool(self.testOption(QFileDialog.Option.DontUseNativeDialog)))
                            return QDialog.DialogCode.Rejected

                    with mock.patch.object(rf, 'list_connected_ios_devices', return_value=[]):
                        guide = rf.MissingImgGuideDialog(m, game, assess, drive_folder=str(root))
                    self.assertEqual(guide.width(), 680)
                    with mock.patch('nspb_qt.refresh_flow.QFileDialog', _TrackingQFileDialog):
                        guide._on_choose_img_clicked()
                    self.assertEqual(non_native_flags, [True])
                    guide.close()
                    guide.deleteLater()
                    hero.close()
                    hero.deleteLater()
                    m.deleteLater()
                    self._app.processEvents()
