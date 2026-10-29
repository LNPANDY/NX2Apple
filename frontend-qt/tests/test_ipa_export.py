"""Synthetic export fixtures: no game files, Apple tools, or device needed."""
from __future__ import annotations

import os
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest import mock

QT = Path(__file__).resolve().parents[1]
ROOT = QT.parent
sys.path.insert(0, str(QT))
os.environ.setdefault('QT_QPA_PLATFORM', 'offscreen')

try:
    from PySide6.QtCore import QSettings
    from PySide6.QtWidgets import QApplication
except ImportError:
    QApplication = None

from nspb_qt.win import build_app


class Fixture(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix='export-test-')
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)


@unittest.skipIf(QApplication is None, 'PySide6 is not installed')
class IPAExport(Fixture):
    @classmethod
    def setUpClass(cls):
        cls.app = QApplication.instance() or QApplication([])

    def setUp(self):
        super().setUp()
        from nspb_qt import model
        self.module = model
        self.settings = QSettings(str(self.root / 'settings.ini'), QSettings.IniFormat)
        for patch in (
            mock.patch.object(model, 'QSettings', return_value=self.settings),
            mock.patch.object(model.pu, 'find_python', return_value=(sys.executable, True, '3')),
            mock.patch.object(model.pu, 'find_dotnet', return_value=('', False)),
            mock.patch.object(model.Model, '_find_repo', return_value=str(self.root)),
            mock.patch.object(model.Model, 'check_deps'),
            mock.patch.object(Path, 'home', return_value=self.root),
        ):
            patch.start()
            self.addCleanup(patch.stop)
        marker = self.root / 'dm/tools/nx_extract/Program.cs'
        marker.parent.mkdir(parents=True)
        marker.write_text('// synthetic repository marker', encoding='utf-8')
        self.m = model.Model()
        self.m.base_path = str(self.root / 'Synthetic [0100000000000000].nsp')
        self.m.keys_path = str(self.root / 'synthetic-key-path')
        self.m.out_dir = str(self.root)
        self.notes = []
        self.m.finished.connect(lambda ok, note: self.notes.append((ok, note)))
        self.addCleanup(self.settings.sync)

    def _start(self, bundle=False, target='ios', windows=False, emit_output=True):
        self.m.bundle_ipa = bundle
        self.m.target = target
        self.thread = mock.Mock()
        self.process = mock.Mock()
        output = self.root / '0100000000000000.ipa'
        output.write_bytes(b'synthetic IPA output')
        self.process.stdout = ['[1/1] pack\n']
        if emit_output:
            self.process.stdout.append(f'output IPA: {output}\n')
        self.process.returncode = 0
        self.popen = mock.Mock(return_value=self.process)
        for patch in (
            mock.patch.object(self.module.threading, 'Thread', return_value=self.thread),
            mock.patch.object(self.module.subprocess, 'Popen', self.popen),
            mock.patch.object(self.module.pu, 'IS_WIN', windows),
            mock.patch.object(self.module.pu, 'no_window_kwargs', return_value={}),
            mock.patch.object(self.module.pu, 'child_env',
                              return_value={'DM_FULL_ROMFS': 'inherited', 'DM_COPY_ROMFS': 'inherited'}),
            mock.patch.object(self.m, 'supports_work_dir', return_value=True),
            mock.patch.object(self.m, 'pack_archive'),
            mock.patch('nspb_qt.win.shim.build_env', side_effect=lambda env, **kw: env),
            mock.patch('nspb_qt.win.shim.verify_shim', return_value=(True, '')),
        ):
            patch.start()
            self.addCleanup(patch.stop)
        self.m.start_build()
        # The worker must not re-read mutable preferences after it has started.
        self.m.bundle_ipa = not bundle
        self.m.target = 'ios' if target == 'mac-app' else 'mac-app'
        self.worker = self.module.threading.Thread.call_args.kwargs['target']
        self.worker()
        return self.popen.call_args.args[0], self.popen.call_args.kwargs['env']

    def test_slim_command_environment_and_archive_on_both_hosts(self):
        for windows in (False, True):
            with self.subTest(windows=windows):
                args, env = self._start(windows=windows)
                self.assertEqual(args[args.index('--romfs') + 1], 'separate')
                self.assertIn('--keep-extracted', args)
                self.assertEqual(env['DM_COPY_ROMFS'], 'NO')
                self.assertNotIn('DM_FULL_ROMFS', env)
                self.assertEqual(self.m.output_mode, 'separate')
                self.m.pack_archive.assert_called_once_with()
                self.assertEqual('-m' in args, windows)

    def test_bundled_command_environment_and_no_archive_on_both_hosts(self):
        for windows in (False, True):
            with self.subTest(windows=windows):
                args, env = self._start(bundle=True, windows=windows)
                self.assertEqual(args[args.index('--romfs') + 1], 'bundle')
                self.assertNotIn('--keep-extracted', args)
                self.assertEqual(env['DM_COPY_ROMFS'], 'YES')
                self.assertEqual(env['DM_FULL_ROMFS'], '1')
                self.assertEqual(self.m.output_mode, 'bundle')
                self.m.pack_archive.assert_not_called()
                self.assertEqual(self.notes[-1], (True, self.m.t('msg.bundledDone')))
                self.assertEqual(self.m.stages[-1].state, 'done')

    def test_bundled_failure_is_not_reported_as_success(self):
        self._start(bundle=True)
        self.notes.clear()
        self.process.returncode = 1
        self.worker()
        self.assertFalse(self.notes[-1][0])
        self.m.pack_archive.assert_not_called()

    def test_bundled_missing_output_is_not_reported_as_success(self):
        self._start(bundle=True)
        self.notes.clear()
        Path(self.m.ipa_path).unlink()
        self.worker()
        self.assertEqual(self.notes[-1], (False, self.m.t('msg.ipaMissing')))
        self.assertEqual(self.m.stages[-1].state, 'failed')
        self.m.pack_archive.assert_not_called()

    def test_selected_output_path_is_kept_without_output_line(self):
        args, _ = self._start(bundle=True, emit_output=False)
        self.assertEqual(self.m.ipa_path, args[args.index('-o') + 1])
        self.assertTrue(Path(self.m.ipa_path).is_file())
        self.assertEqual(self.notes[-1], (True, self.m.t('msg.bundledDone')))
        self.m.pack_archive.assert_not_called()

    def test_mac_app_does_not_get_ipa_options_or_environment_overrides(self):
        args, env = self._start(bundle=True, target='mac-app')
        self.assertEqual(args[args.index('--platform') + 1], 'mac-app')
        self.assertNotIn('--romfs', args)
        self.assertNotIn('--keep-extracted', args)
        self.assertEqual(env['DM_COPY_ROMFS'], 'inherited')
        self.assertEqual(env['DM_FULL_ROMFS'], 'inherited')
        self.assertEqual(self.m.output_mode, 'mac-app')
        self.m.pack_archive.assert_not_called()

    def test_preference_defaults_off_and_persists_both_values(self):
        self.assertFalse(self.m.bundle_ipa)
        for value in (True, False):
            self.m.bundle_ipa = value
            self.settings.sync()
            self.assertEqual(self.module.Model().bundle_ipa, value)

    def test_checkbox_persistence_ios_visibility_and_running_lock(self):
        from nspb_qt.ui import MainWindow
        w = MainWindow(self.m)
        self.addCleanup(w.close)
        w.bundle_ipa_check.setChecked(True)
        self.assertTrue(self.module.Model().bundle_ipa)
        self.m.running = True
        w._refresh_running()
        self.assertFalse(w.bundle_ipa_check.isEnabled())
        self.m.running = False
        self.m.target = 'mac-app'
        w._refresh_running()
        self.assertTrue(w.bundle_ipa_check.isHidden())
        self.assertTrue(w.bundle_ipa_note.isHidden())
        self.m.target = 'ios'
        w._refresh_running()
        self.assertFalse(w.bundle_ipa_check.isHidden())
        self.assertTrue(w.bundle_ipa_check.isEnabled())
        self.assertTrue(w.bundle_ipa_check.isChecked())

    def test_bundled_completion_uses_snapshot_and_omits_archive_instructions(self):
        from nspb_qt.ui import MainWindow
        w = MainWindow(self.m)
        self.addCleanup(w.close)
        self.m.output_mode = 'bundle'
        self.m.bundle_ipa = False
        self.m.target = 'mac-app'
        self.m.ipa_path = 'synthetic.ipa'
        self.m.archive_path = 'must-not-appear'
        w._on_finished(True, '')
        self.assertIn(self.m.t('msg.bundledDone'), w.footer.text())
        self.assertIn(self.m.t('install.bundled'), w.footer.text())
        self.assertNotIn('must-not-appear', w.footer.text())


class WindowsIPAPacking(Fixture):
    def setUp(self):
        super().setUp()
        self.app = self.root / 'DmIOS.app'
        self.app.mkdir()
        (self.app / 'DmIOS').write_bytes(b'synthetic executable')
        (self.app / 'romfs').mkdir()
        (self.app / 'romfs/stale').write_bytes(b'stale data')
        (self.app / 'romfs.img').write_bytes(b'stale image')
        (self.app / 'aoc').mkdir()
        (self.app / 'aoc/stale').write_bytes(b'stale DLC')
        self.msl = self.root / 'msl'
        (self.msl / 'nvn').mkdir(parents=True)
        (self.msl / 'nvn/test.metallib').write_bytes(b'synthetic shader library')
        self.romfs = self.root / 'RomFS'
        self.romfs.mkdir()
        (self.romfs / 'marker').write_bytes(b'synthetic game data')
        self.aoc = self.root / 'aoc'
        self.aoc.mkdir()
        (self.aoc / '1.img').write_bytes(b'synthetic DLC data')
        self.ipa = self.root / 'synthetic.ipa'

    def _pack(self, romfs, env):
        build_app.pack_ipa(ROOT, self.app, self.msl, 'nvn', self.aoc, romfs,
                           self.ipa, '', env)
        with zipfile.ZipFile(self.ipa) as z:
            return {name: z.read(name) for name in z.namelist() if not name.endswith('/')}

    def test_bundled_directory_has_game_data_and_dlc(self):
        entries = self._pack(self.romfs, {'DM_FULL_ROMFS': '1'})
        self.assertEqual(entries['Payload/DmIOS.app/romfs/marker'], b'synthetic game data')
        self.assertEqual(entries['Payload/DmIOS.app/aoc/1.img'], b'synthetic DLC data')
        self.assertNotIn('Payload/DmIOS.app/romfs.img', entries)
        self.assertNotIn('Payload/DmIOS.app/romfs/stale', entries)

    def test_bundled_image_is_romfs_img_and_passes_marker_validation(self):
        image = self.root / 'RomFS.img'
        build_app.py(ROOT / 'dm/tools/romfs_image.py', self.romfs, image)
        build_app.py(ROOT / 'dm/tools/romfs.py', image, 'marker')
        entries = self._pack(image, {'DM_COPY_ROMFS': 'YES'})
        self.assertEqual(entries['Payload/DmIOS.app/romfs.img'], image.read_bytes())
        self.assertEqual(entries['Payload/DmIOS.app/aoc/1.img'], b'synthetic DLC data')
        self.assertNotIn('Payload/DmIOS.app/romfs/stale', entries)
        self.assertNotIn('Payload/DmIOS.app/romfs', entries)

    def test_separate_overrides_inherited_full_and_omits_stale_resources(self):
        entries = self._pack(self.romfs, {'DM_COPY_ROMFS': 'NO', 'DM_FULL_ROMFS': '1'})
        self.assertFalse(any('/romfs' in name for name in entries))
        self.assertEqual(entries['Payload/DmIOS.app/aoc/1.img'], b'synthetic DLC data')
        self.assertNotIn('Payload/DmIOS.app/aoc/stale', entries)
        self.assertIn('Payload/DmIOS.app/DmIOS', entries)


if __name__ == '__main__':
    unittest.main()
