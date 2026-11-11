"""Regression tests for post-build storage cleanup, zero-copy placement, `--romfs-from` reuse,
and `BuildFolder` hard-link deduplication in the Qt front end.

Runs in environments with or without `PySide6` installed (never skipped).
"""
from __future__ import annotations

import errno
import json
import os
import plistlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

QT = Path(__file__).resolve().parents[1]
if str(QT) not in sys.path:
    sys.path.insert(0, str(QT))

from nspb_qt import library as lib
from nspb_qt import post_build_cleanup as pbc
from nspb_qt.win import build_app


def _load_model_with_qt_fallback():
    """Import nspb_qt.model, installing a lightweight PySide6.QtCore stub if PySide6 is absent in CI."""
    try:
        from nspb_qt import model as model_mod
        return model_mod, lambda: None
    except ImportError:
        pass
    import types
    saved = {k: sys.modules.get(k) for k in ('PySide6', 'PySide6.QtCore', 'nspb_qt.model')}

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

        def value(self, k: str, default: object = '', *, defaultValue: object = None, type: object = None) -> object:
            fallback = defaultValue if defaultValue is not None else default
            val = self._d.get(k, fallback)
            if type is str and val is not None:
                return str(val)
            return val

        def setValue(self, k: str, v: object) -> None:
            self._d[k] = v

        def remove(self, k: str) -> None:
            self._d.pop(k, None)

    class _FakeQt:
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

    def _cleanup() -> None:
        for k, old in saved.items():
            if old is None:
                sys.modules.pop(k, None)
            else:
                sys.modules[k] = old

    return model_mod, _cleanup


class PostBuildCleanupTests(unittest.TestCase):
    def test_place_image_moves_cleans_sidecars_and_preserves_target_on_error(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            src_dir = root / 'work' / 'extract' / 'v1'
            dst_dir = root / 'out' / 'games' / '010015100B514000'
            src_dir.mkdir(parents=True)
            dst_dir.mkdir(parents=True)

            # Stale split parts from an earlier drive layout should be removed
            (dst_dir / 'romfs.idx').write_bytes(b'idx')
            (dst_dir / 'romfs.00').write_bytes(b'part0')

            src_img = src_dir / 'RomFS.img'
            src_img.write_bytes(b'DMROMFS1_v1_payload')
            (src_dir / 'RomFS.img.id').write_text('{"title":"010015100B514000"}\n', encoding='utf-8')
            (src_dir / 'RomFS.img.formats').write_text('fmt\n', encoding='utf-8')

            dst_img = dst_dir / 'romfs.img'
            mode = pbc.place_image(src_img, dst_img)
            self.assertEqual(mode, 'moved')
            self.assertEqual(dst_img.read_bytes(), b'DMROMFS1_v1_payload')
            self.assertEqual(
                Path(f'{dst_img}.id').read_text(encoding='utf-8'),
                '{"title":"010015100B514000"}\n',
            )
            self.assertFalse(src_img.exists())
            self.assertFalse((src_dir / 'RomFS.img.id').exists())
            self.assertFalse((src_dir / 'RomFS.img.formats').exists())
            self.assertFalse((dst_dir / 'romfs.idx').exists())
            self.assertFalse((dst_dir / 'romfs.00').exists())

            # Simulate cross-volume EXDEV fallback to copy + delete
            src_img.write_bytes(b'DMROMFS1_v2_payload')
            (src_dir / 'RomFS.img.id').write_text('{"title":"010015100B514000","v":2}\n', encoding='utf-8')
            real_replace = os.replace

            def exdev_on_source(a, b):
                if Path(a) == src_img:
                    raise OSError(errno.EXDEV, 'Cross-device link')
                return real_replace(a, b)

            with mock.patch('nspb_qt.post_build_cleanup.os.replace', side_effect=exdev_on_source):
                mode2 = pbc.place_image(src_img, dst_img)
            self.assertEqual(mode2, 'copied')
            self.assertEqual(dst_img.read_bytes(), b'DMROMFS1_v2_payload')
            self.assertFalse(src_img.exists())

            # Simulate disk-full failure mid-copy: existing target and .id stay untouched, no .partial left
            src_img.write_bytes(b'CORRUPTED_INCOMPLETE')
            with (
                mock.patch('nspb_qt.post_build_cleanup.os.replace', side_effect=exdev_on_source),
                mock.patch('nspb_qt.post_build_cleanup.shutil.copy2', side_effect=OSError(errno.ENOSPC, 'No space')),
            ):
                with self.assertRaises(OSError):
                    pbc.place_image(src_img, dst_img)
            self.assertEqual(dst_img.read_bytes(), b'DMROMFS1_v2_payload')
            self.assertEqual(
                Path(f'{dst_img}.id').read_text(encoding='utf-8'),
                '{"title":"010015100B514000","v":2}\n',
            )
            partials = [p.name for p in dst_dir.iterdir() if '.partial-' in p.name]
            self.assertEqual(partials, [])

    def test_place_aoc_moves_and_rolls_back_existing_target_on_failure(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            work = root / 'work'
            aoc_src = work / 'aoc'
            aoc_src.mkdir(parents=True)
            (aoc_src / '0.img').write_bytes(b'dlc_one')
            (work / 'aoc.key').write_text('stamp\n', encoding='utf-8')

            dst_aoc = root / 'out' / 'games' / '010015100B514000' / 'aoc'
            placed = pbc.place_aoc(aoc_src, dst_aoc)
            self.assertEqual(placed, 1)
            self.assertEqual((dst_aoc / '0.img').read_bytes(), b'dlc_one')
            self.assertFalse(aoc_src.exists())
            self.assertFalse((work / 'aoc.key').exists())

            # Overwrite failure after leaving a half-written target directory must clean target and restore backup
            aoc_src.mkdir(parents=True)
            (aoc_src / '1.img').write_bytes(b'dlc_two')
            real_replace = os.replace

            def fail_final_swap(a, b):
                if '.partial-' in Path(a).name and Path(b) == dst_aoc:
                    Path(b).mkdir(parents=True, exist_ok=True)
                    (Path(b) / 'half.tmp').write_bytes(b'broken')
                    raise OSError(errno.EIO, 'swap failed')
                return real_replace(a, b)

            with mock.patch('nspb_qt.post_build_cleanup.os.replace', side_effect=fail_final_swap):
                with self.assertRaises(OSError):
                    pbc.place_aoc(aoc_src, dst_aoc)
            self.assertEqual((dst_aoc / '0.img').read_bytes(), b'dlc_one')
            self.assertFalse((dst_aoc / 'half.tmp').exists())

    def test_reusable_romfs_images_discovers_games_and_renamed_apps_ignoring_symlinks(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            tid = '010015100B514000'

            # 1. games/<ID>/romfs.img
            g_img = root / 'games' / tid / 'romfs.img'
            g_img.parent.mkdir(parents=True)
            g_img.write_bytes(b'img1')
            Path(f'{g_img}.id').write_text(json.dumps({'title': tid.lower()}), encoding='utf-8')

            # 2. Renamed <DisplayName>.app matched via .id "title"
            renamed1 = root / 'Super Mario Bros Wonder.app' / 'Contents' / 'Resources' / 'romfs.img'
            renamed1.parent.mkdir(parents=True)
            renamed1.write_bytes(b'img2')
            Path(f'{renamed1}.id').write_text(json.dumps({'title': tid}), encoding='utf-8')

            # 3. Renamed .app matched via Info.plist DMTitleID when .id lacks "title"
            renamed2_app = root / 'Wonder Alt.app'
            renamed2 = renamed2_app / 'Contents' / 'Resources' / 'romfs.img'
            renamed2.parent.mkdir(parents=True)
            renamed2.write_bytes(b'img3')
            Path(f'{renamed2}.id').write_text('{}\n', encoding='utf-8')
            with open(renamed2_app / 'Contents' / 'Info.plist', 'wb') as f:
                plistlib.dump({'DMTitleID': tid.lower()}, f)

            # 4. Different game's .app and symlink .app must be ignored
            other = root / 'Other Game.app' / 'Contents' / 'Resources' / 'romfs.img'
            other.parent.mkdir(parents=True)
            other.write_bytes(b'other')
            Path(f'{other}.id').write_text(json.dumps({'title': '01007EF00011E000'}), encoding='utf-8')

            try:
                os.symlink(renamed2_app, root / 'Symlink.app')
            except OSError:
                pass

            found = pbc.reusable_romfs_images(root, tid.lower())
            self.assertEqual(found, [str(g_img), str(renamed1), str(renamed2)])

    def test_clean_work_dir_and_framework_container_safety(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            work = root / '010015100B514000_build'
            for rel_file in (
                'nsp/base.nsp',
                'nsp.partial/tmp.nsp',
                'extract/v0/RomFS.img',
                'extract/v0/RomFS.img.id',
                'extract/v0/ExeFS/main',
                'extract/v1/RomFS.img',
                'extract/v1/RomFS.img.id',
                'extract/v1/RomFS.img.formats',
                'extract/v1/ExeFS/main',
                'extract/v1/control.nacp',
                'extract/v1.partial/RomFS.img',
                'aoc/0.img',
                'aoc.key',
                'pso/mac-work/batches.g16g/000.bin',
                'pso/mac-work/key.g16g',
                'ipa/build/ios/pso/work/batches.g18p/000.bin',
                'ipa/build/ios/pso/work/key.g18p',
                'ipa/build/ios/pkg/dd/Build/Products/Release-iphoneos/DmGame.framework/DmGame',
                'ipa/build/ios/pkg/dd/Build/Intermediates.noindex/obj.o',
                'ipa/build/ios/win/Payload/DmIOS.app/DmIOS',
                'ipa/build/ios/win/obj/main.o',
                'patched_v1/main.patched.bin',
                'shader/ios/b-123456789abc/s.metallib',
                'logs/build.log',
                'profile/game.tsv',
                'run/save.bin',
                'shell-framework/DmGame010015100B514000.framework/DmGame010015100B514000',
            ):
                p = work / rel_file
                p.parent.mkdir(parents=True, exist_ok=True)
                p.write_bytes(b'data')

            pbc.clean_work_dir(work, remove_extracted_romfs=True, remove_shell_framework=False)

            for gone in (
                'nsp',
                'nsp.partial',
                'extract/v0/RomFS.img',
                'extract/v0/RomFS.img.id',
                'extract/v1/RomFS.img',
                'extract/v1/RomFS.img.id',
                'extract/v1/RomFS.img.formats',
                'extract/v1.partial',
                'aoc',
                'aoc.key',
                'pso/mac-work/batches.g16g',
                'ipa/build/ios/pso/work/batches.g18p',
                'ipa/build/ios/pkg/dd/Build/Products',
                'ipa/build/ios/win/Payload',
            ):
                self.assertFalse((work / gone).exists(), f'expected removed: {gone}')

            for kept in (
                'extract/v0/ExeFS/main',
                'extract/v1/ExeFS/main',
                'extract/v1/control.nacp',
                'pso/mac-work/key.g16g',
                'ipa/build/ios/pso/work/key.g18p',
                'ipa/build/ios/pkg/dd/Build/Intermediates.noindex/obj.o',
                'ipa/build/ios/win/obj/main.o',
                'patched_v1/main.patched.bin',
                'shader/ios/b-123456789abc/s.metallib',
                'logs/build.log',
                'profile/game.tsv',
                'run/save.bin',
                'shell-framework/DmGame010015100B514000.framework/DmGame010015100B514000',
            ):
                self.assertTrue((work / kept).exists(), f'expected preserved: {kept}')

            # Guard: never delete `<shell>/frameworks` mirror directory
            shell_mirror = root / 'shell' / 'frameworks' / 'DmGame010015100B514000.framework'
            shell_mirror.mkdir(parents=True)
            (shell_mirror / 'DmGame010015100B514000').write_bytes(b'bin')
            pbc.clean_built_framework_container(shell_mirror)
            self.assertTrue(shell_mirror.is_dir())

            # Delete `<work>/shell-framework` when passed the staging framework
            pbc.clean_built_framework_container(work / 'shell-framework' / 'DmGame010015100B514000.framework')
            self.assertFalse((work / 'shell-framework').exists())

    def test_build_app_cleans_pso_batches_and_hardlinks_framework_assets(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            repo = root / 'repo'
            gd = root / 'profile'
            gd.mkdir(parents=True)
            (gd / 'shader_pairs.tsv').write_text('pair\n', encoding='utf-8')
            w = root / 'ipa'
            msl_ios = w / 'build' / 'ios' / 'dmsh_b'

            def fake_pso_run(cmd, **_kw):
                out_idx = cmd.index('--out') + 1
                work_idx = cmd.index('--work') + 1
                out_p = Path(cmd[out_idx])
                work_p = Path(cmd[work_idx])
                out_p.mkdir(parents=True, exist_ok=True)
                (out_p / 'archive.mtl4a').write_bytes(b'MTL4A_DATA')
                (work_p / 'batches.g18p').mkdir(parents=True, exist_ok=True)
                (work_p / 'batches.g18p' / '000.mtl4a').write_bytes(b'SHARD')
                (work_p / 'key.g18p').write_text('digest\n', encoding='utf-8')
                return subprocess.CompletedProcess(cmd, 0, 'merged\n', '')

            with mock.patch.object(build_app.subprocess, 'run', side_effect=fake_pso_run):
                pso_bundle = build_app.build_pso_archive(
                    repo, w, '010015100B514000', gd,
                    lambda k, d='': 'on' if k == 'pso_mtl4' else d,
                    'nvn', msl_ios, '123456789abc', {},
                )

            self.assertEqual(pso_bundle, w / 'build/ios/pso/bundle')
            self.assertTrue((w / 'build/ios/pso/bundle/archive.mtl4a').is_file())
            self.assertFalse((w / 'build/ios/pso/work/batches.g18p').exists())
            self.assertTrue((w / 'build/ios/pso/work/key.g18p').is_file())

            fw_pso = root / 'out_fw' / 'pso'
            pbc.link_or_copy_tree(pso_bundle, fw_pso)
            self.assertEqual((fw_pso / 'archive.mtl4a').read_bytes(), b'MTL4A_DATA')
            st_src = (pso_bundle / 'archive.mtl4a').stat()
            st_dst = (fw_pso / 'archive.mtl4a').stat()
            if st_src.st_ino != 0:
                self.assertEqual(st_src.st_ino, st_dst.st_ino)

    def test_model_passes_romfs_from_and_cleans_mac_app_one_game_and_shared_shell_flows(self) -> None:
        model_mod, cleanup = _load_model_with_qt_fallback()
        self.addCleanup(cleanup)
        Model = model_mod.Model
        from nspb_qt.win import shell_export as se

        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            eng = root / 'engine'
            (eng / 'scripts').mkdir(parents=True)
            (eng / 'scripts' / 'build_ipa_from_nsp.py').write_text(
                "ap.add_argument('--work-dir')\nap.add_argument('--romfs-from')\n",
                encoding='utf-8',
            )
            (eng / 'dm' / 'tools' / 'nx_extract').mkdir(parents=True)
            (eng / 'dm' / 'tools' / 'nx_extract' / 'Program.cs').write_text('', encoding='utf-8')
            (eng / 'dm' / 'ios' / 'framework').mkdir(parents=True)

            tid = '010015100B514000'
            roms = root / 'roms'
            roms.mkdir()
            base_nsp = roms / f'Wonder [{tid}][v0].nsp'
            base_nsp.write_bytes(b'pkg')
            keys_f = root / 'prod.keys'
            keys_f.write_bytes(b'keys')
            out_dir = root / 'out'
            out_dir.mkdir()

            # Seed a renamed Mac app in out_dir so --romfs-from discovers it
            donor_app = out_dir / 'Super Mario Wonder.app'
            donor_img = donor_app / 'Contents' / 'Resources' / 'romfs.img'
            donor_img.parent.mkdir(parents=True)
            donor_img.write_bytes(b'DONOR_ROMFS')
            Path(f'{donor_img}.id').write_text(json.dumps({'title': tid}), encoding='utf-8')

            seen_cmds: list[list[str]] = []

            def make_fake_popen(mode: str):
                def _spawn(cmd, **_kw):
                    cmd_list = [str(c) for c in cmd]
                    seen_cmds.append(cmd_list)
                    w_dir = Path(cmd_list[cmd_list.index('--work-dir') + 1])
                    (w_dir / 'nsp').mkdir(parents=True, exist_ok=True)
                    (w_dir / 'nsp' / 'decompressed.nsp').write_bytes(b'nsp')
                    v0 = w_dir / 'extract' / 'v0'
                    v0.mkdir(parents=True, exist_ok=True)
                    (v0 / 'RomFS.img').write_bytes(b'EXTRACTED_IMG')
                    (v0 / 'ExeFS').mkdir(exist_ok=True)
                    (v0 / 'ExeFS' / 'main').write_bytes(b'code')
                    (w_dir / 'ipa' / 'build' / 'ios' / 'win' / 'Payload').mkdir(parents=True, exist_ok=True)
                    if mode == 'mac':
                        out_app = Path(cmd_list[cmd_list.index('-o') + 1])
                        out_app.mkdir(parents=True, exist_ok=True)
                    elif mode == 'oneGame':
                        out_ipa = Path(cmd_list[cmd_list.index('-o') + 1])
                        out_ipa.write_bytes(b'IPA_ZIP')
                    return mock.Mock(stdout=[], returncode=0, wait=lambda: 0)
                return _spawn

            with (
                mock.patch.object(Model, 'check_deps', lambda self: None),
                mock.patch.object(lib, 'default_state_dir', lambda: root / 'state'),
                mock.patch.object(lib.ArtworkStore, 'request_banner_async', lambda *_a, **_kw: None),
                mock.patch.object(model_mod.pu, 'find_python', return_value=(sys.executable, True, '3.12')),
                mock.patch.object(model_mod.pu, 'IS_WIN', False),
                mock.patch.object(model_mod.pu, 'no_window_kwargs', return_value={}),
                mock.patch.object(
                    model_mod.threading, 'Thread',
                    side_effect=lambda *, target, daemon: mock.Mock(start=target),
                ),
            ):
                m = Model()
                m.repo_path = str(eng)
                m.base_path = str(base_nsp)
                m.keys_path = str(keys_f)
                m.out_dir = str(out_dir)

                # 1. Mac app build passes --romfs-from and cleans staging after .app creation
                m.target = 'mac-app'
                with mock.patch.object(model_mod.subprocess, 'Popen', side_effect=make_fake_popen('mac')):
                    m.start_build()
                self.assertIn('--romfs-from', seen_cmds[-1])
                self.assertIn(str(donor_img), seen_cmds[-1])
                work_dir = out_dir / f'{tid}_build'
                self.assertFalse((work_dir / 'nsp').exists())
                self.assertFalse((work_dir / 'extract' / 'v0' / 'RomFS.img').exists())
                self.assertTrue((work_dir / 'extract' / 'v0' / 'ExeFS' / 'main').is_file())

                # 2. One-game IPA cleans staging and Windows Payload folder
                m.target = 'ios'
                m.ipa_kind = 'oneGame'
                with mock.patch.object(model_mod.subprocess, 'Popen', side_effect=make_fake_popen('oneGame')):
                    m.start_build()
                self.assertFalse((work_dir / 'nsp').exists())
                self.assertFalse((work_dir / 'extract' / 'v0' / 'RomFS.img').exists())
                self.assertFalse((work_dir / 'ipa' / 'build' / 'ios' / 'win' / 'Payload').exists())

                # 3. Shared shell export: retain shell-framework on failure, delete once exported & registered
                shell_root = root / 'shell_cache'
                m.settings.setValue('shellRoot', str(shell_root))
                fw_dir = work_dir / 'shell-framework' / f'DmGame{tid}.framework'
                fw_dir.mkdir(parents=True, exist_ok=True)
                (fw_dir / f'DmGame{tid}').write_bytes(b'dylib')
                m.effective_work_dir = str(work_dir)

                with mock.patch.object(se, 'export_shell', return_value=(False, '', 'err', [])):
                    ok_fail, _ = m._export_shell_after_archive(True, '')
                self.assertFalse(ok_fail)
                self.assertTrue(fw_dir.is_dir(), 'failed export must keep shell-framework for retry')

                shell_lib = se.ShellLibrary()
                shell_lib.add(se.ShellGame(title_id=tid, name='Wonder', framework=str(shell_root / 'frameworks' / fw_dir.name)))
                shell_lib.save(shell_root)
                with mock.patch.object(se, 'export_shell', return_value=(True, str(shell_root / 'export' / 'NX2Apple.ipa'), 'ok', [])):
                    ok_pass, _ = m._export_shell_after_archive(True, '')
                self.assertTrue(ok_pass)
                self.assertFalse((work_dir / 'shell-framework').exists())

    def test_build_folder_deduplicates_hardlinks_and_classifies_engine_layout(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            bf = Path(td) / '010015100B514000_build'
            (bf / 'extract' / 'v0').mkdir(parents=True)
            (bf / 'extract' / 'v0' / 'ExeFS').write_bytes(b'e' * 1000)
            (bf / 'nsp').mkdir(parents=True)
            (bf / 'nsp' / 'base.nsp').write_bytes(b'n' * 2000)

            old_c = 'b-111111111111'
            cur_c = 'b-222222222222'
            (bf / 'shader' / 'ios' / old_c).mkdir(parents=True)
            (bf / 'shader' / 'ios' / old_c / 'old.metallib').write_bytes(b'o' * 3000)
            (bf / 'shader' / 'ios' / f'{old_c}.key').write_bytes(b'k' * 100)
            (bf / 'shader' / 'ios' / cur_c).mkdir(parents=True)
            cur_lib = bf / 'shader' / 'ios' / cur_c / 'cur.metallib'
            cur_lib.write_bytes(b'c' * 4000)

            # Hard-link cur.metallib into shell-framework: total_freeable must not double-count it
            (bf / 'shell-framework' / 'msl').mkdir(parents=True)
            linked = bf / 'shell-framework' / 'msl' / 'cur.metallib'
            os.link(cur_lib, linked)
            (bf / 'shell-framework' / 'Info.plist').write_bytes(b'p' * 500)

            (bf / 'patched_v0').mkdir()
            (bf / 'patched_v0' / 'main.patched.bin').write_bytes(b'm' * 600)
            (bf / 'logs').mkdir()
            (bf / 'logs' / 'build.log').write_bytes(b'l' * 250)
            (bf / 'run').mkdir()
            (bf / 'run' / 'save.dat').write_bytes(b's' * 150)

            rep = lib.BuildFolder.inspect(str(bf), '010015100B514000', chain=cur_c)
            parts = {it.part: it.bytes for it in rep.items}
            self.assertEqual(parts.get('extracted'), 3000)
            self.assertEqual(parts.get('shaders'), 7100)
            self.assertEqual(parts.get('oldShaders'), 3100)
            # `cur.metallib` (4000 B) was already counted in `shaders`, so `xcode` only adds Info.plist (500 B)
            self.assertEqual(parts.get('xcode'), 500)
            self.assertEqual(parts.get('caches'), 600)
            self.assertEqual(rep.kept_bytes, 400)
            self.assertEqual(rep.total_freeable, 3000 + 7100 + 500 + 600)


if __name__ == '__main__':
    unittest.main()
