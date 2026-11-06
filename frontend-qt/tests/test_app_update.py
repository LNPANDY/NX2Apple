"""Tests for Windows executable naming (`NX2Apple.exe`) and self-update (`nspb_qt.app_update`)."""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import sys
import tempfile
import unittest
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from nspb_qt import app_update  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]


class AppUpdateTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix='qt-app-update-'))
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def test_qt_app_version_matches_swift_app_update_store(self) -> None:
        swift_store = (ROOT / 'frontend' / 'Sources' / 'NXModel' / 'AppUpdateStore.swift').read_text(encoding='utf-8')
        m = re.search(r'static let appVersion = "([^"]+)"', swift_store)
        self.assertIsNotNone(m, 'AppUpdateStore.appVersion not found')
        self.assertEqual(app_update.APP_VERSION, m.group(1))

    def test_build_qt_workflow_builds_nx2apple_exe_not_ns_port_builder(self) -> None:
        wf = (ROOT / '.github' / 'workflows' / 'build-qt.yml').read_text(encoding='utf-8')
        self.assertIn('--name "NX2Apple"', wf)
        self.assertNotIn('--name "NS Port Builder"', wf)
        self.assertIn("Compress-Archive -Path 'NX2Apple' -DestinationPath '../NX2Apple-windows-x64.zip'", wf)

    def test_is_newer_compares_numeric_segments_and_release_candidates(self) -> None:
        self.assertTrue(app_update.is_newer('v1.2.2', '1.2.0'))
        self.assertTrue(app_update.is_newer('v1.2.10', '1.2.2'))
        self.assertFalse(app_update.is_newer('v1.2.2', '1.2.2'))
        self.assertFalse(app_update.is_newer('v1.2.1', '1.2.2'))
        # A final release is newer than a release candidate of the same version
        self.assertTrue(app_update.is_newer('v1.2.2', '1.2.2-rc4'))
        self.assertTrue(app_update.is_newer('v1.2.2-rc4', '1.2.2-rc3'))
        self.assertFalse(app_update.is_newer('v1.2.2-rc3', '1.2.2'))

    def test_check_release_matches_nx2apple_windows_zip_and_digest(self) -> None:
        payload = {
            'tag_name': 'v1.3.0',
            'draft': False,
            'prerelease': False,
            'html_url': 'https://github.com/LNPANDY/NX2Apple/releases/tag/v1.3.0',
            'body': 'Release notes',
            'assets': [
                {
                    'name': 'NX2Apple-macOS-arm64.zip',
                    'browser_download_url': 'https://example.com/mac.zip',
                },
                {
                    'name': 'NX2Apple-windows-x64.zip',
                    'browser_download_url': 'https://example.com/NX2Apple-windows-x64.zip',
                    'digest': 'sha256:' + 'a' * 64,
                },
            ],
        }
        res = app_update.check_release(json.dumps(payload).encode('utf-8'), current='1.2.2')
        self.assertEqual(res.kind, 'found')
        assert res.release is not None
        self.assertEqual(res.release.tag, 'v1.3.0')
        self.assertEqual(res.release.url, 'https://example.com/NX2Apple-windows-x64.zip')
        self.assertEqual(res.release.digest, 'sha256:' + 'a' * 64)

    def test_check_release_reports_no_asset_when_windows_zip_missing(self) -> None:
        payload = {
            'tag_name': 'v1.3.0',
            'draft': False,
            'prerelease': False,
            'assets': [
                {
                    'name': 'NX2Apple-macOS-arm64.zip',
                    'browser_download_url': 'https://example.com/mac.zip',
                },
            ],
        }
        res = app_update.check_release(json.dumps(payload), current='1.2.2')
        self.assertEqual(res.kind, 'no_asset')
        self.assertEqual(res.tag, 'v1.3.0')

    def test_stage_zip_verifies_sha256_and_locates_nx2apple_exe(self) -> None:
        zip_path = self.tmp / 'NX2Apple-windows-x64.zip'
        with zipfile.ZipFile(zip_path, 'w') as zf:
            zf.writestr('NX2Apple/NX2Apple.exe', b'MZ-fake-exe')
            zf.writestr('NX2Apple/_internal/python312.dll', b'fake-dll')
        digest = 'sha256:' + hashlib.sha256(zip_path.read_bytes()).hexdigest()
        rel = app_update.Release(tag='v1.3.0', url='https://example.com/win.zip', digest=digest)
        staging = app_update.fresh_staging_root(self.tmp)
        staged = app_update.stage_zip(zip_path, rel, staging, require_digest=True)
        self.assertEqual(staged.exe_name, 'NX2Apple.exe')
        self.assertTrue((staged.app_dir / 'NX2Apple.exe').is_file())
        self.assertTrue((staged.app_dir / '_internal' / 'python312.dll').is_file())

    def test_stage_zip_rejects_mismatched_digest(self) -> None:
        zip_path = self.tmp / 'bad.zip'
        with zipfile.ZipFile(zip_path, 'w') as zf:
            zf.writestr('NX2Apple/NX2Apple.exe', b'MZ')
            zf.writestr('NX2Apple/_internal/x', b'1')
        rel = app_update.Release(tag='v1.3.0', url='https://example.com/win.zip', digest='sha256:' + '0' * 64)
        staging = app_update.fresh_staging_root(self.tmp)
        with self.assertRaises(app_update.StageError) as ctx:
            app_update.stage_zip(zip_path, rel, staging)
        self.assertEqual(ctx.exception.key, 'app.digestMismatch')
        self.assertFalse(zip_path.exists())

    def test_stage_zip_rejects_zip_slip_traversal(self) -> None:
        zip_path = self.tmp / 'slip.zip'
        with zipfile.ZipFile(zip_path, 'w') as zf:
            zf.writestr('../escaped.exe', b'MZ')
        rel = app_update.Release(tag='v1.3.0', url='https://example.com/win.zip', digest=None)
        staging = app_update.fresh_staging_root(self.tmp)
        with self.assertRaises(app_update.StageError) as ctx:
            app_update.stage_zip(zip_path, rel, staging)
        self.assertEqual(ctx.exception.key, 'app.unpackFail')

    def test_relaunch_windows_update_passes_unicode_env_and_strips_meipass(self) -> None:
        staged_dir = self.tmp / 'staged' / 'NX2Apple'
        staged_dir.mkdir(parents=True)
        install_dir = self.tmp / 'C_Games_中文目录' / 'NS Port Builder'
        install_dir.mkdir(parents=True)
        old_exe = install_dir / 'NS Port Builder.exe'
        old_exe.write_text('old')

        staged = app_update.StagedUpdate(
            release=app_update.Release(tag='v1.3.0', url='https://example.com/win.zip'),
            app_dir=staged_dir,
            exe_name='NX2Apple.exe',
            staging_root=self.tmp / 'staged',
        )
        captured: list[tuple[list[str], dict]] = []

        def fake_popen(cmd, **kwargs):
            captured.append((cmd, kwargs))

        old_env = os.environ.get('_MEIPASS2')
        os.environ['_MEIPASS2'] = '/tmp/stale-meipass'
        try:
            ok = app_update.relaunch_windows_update(staged, current_exe=old_exe, pid=4321, popen=fake_popen)
        finally:
            if old_env is None:
                os.environ.pop('_MEIPASS2', None)
            else:
                os.environ['_MEIPASS2'] = old_env

        self.assertTrue(ok)
        self.assertEqual(len(captured), 1)
        cmd, kwargs = captured[0]
        self.assertEqual(cmd[0], 'powershell')
        env = kwargs['env']
        self.assertNotIn('_MEIPASS2', env)
        self.assertEqual(env['NX_PID'], '4321')
        self.assertEqual(env['NX_OLD_EXE'], 'NS Port Builder.exe')
        self.assertEqual(env['NX_NEW_EXE'], 'NX2Apple.exe')
        self.assertEqual(env['NX_TARGET'], str(old_exe.resolve().parent))

    def test_library_horizontal_strip_does_not_widen_hero_or_page_and_scrolls_cards(self) -> None:
        os.environ.setdefault('QT_QPA_PLATFORM', 'offscreen')
        try:
            from PySide6.QtCore import QEvent
            from PySide6.QtWidgets import QApplication
        except ImportError:
            self.skipTest('PySide6 is not installed')

        from nspb_qt.library import LibraryGame
        from nspb_qt.model import Model
        from nspb_qt.ui import MainWindow

        app = QApplication.instance() or QApplication([])
        m = Model()
        w = MainWindow(m)

        def cleanup() -> None:
            w.close()
            w.deleteLater()
            m.deleteLater()
            app.sendPostedEvents(None, QEvent.DeferredDelete)
            app.processEvents()

        self.addCleanup(cleanup)
        m.library.games = [
            LibraryGame(title_id=f'01000000000100{i:02X}', name=f'Game {i}')
            for i in range(11)
        ]
        m.library.selected_id = m.library.games[0].title_id
        w.resize(1080, 720)
        w.show()
        w._switch_page('library')
        w._refresh_library()
        for _ in range(3):
            app.processEvents()

        self.assertLessEqual(w.library_page.minimumSizeHint().width(), 1080)
        self.assertLessEqual(w.hero.width(), 1080)
        self.assertGreater(w.coll_viewport.max_scroll(), 1000)
        self.assertEqual(w.coll_strip.x(), 0)

        for _ in range(10):
            w._scroll_collection(1)
        app.processEvents()
        self.assertEqual(m.library.selected_id, m.library.games[10].title_id)
        self.assertLess(w.coll_strip.x(), -1000)
        self.assertLessEqual(w.hero.width(), 1080)

    def test_update_buttons_show_download_progress_and_reset_when_done(self) -> None:
        os.environ.setdefault('QT_QPA_PLATFORM', 'offscreen')
        try:
            from PySide6.QtCore import QEvent
            from PySide6.QtWidgets import QApplication
        except ImportError:
            self.skipTest('PySide6 is not installed')

        from nspb_qt.model import Model
        from nspb_qt.ui import MainWindow

        app = QApplication.instance() or QApplication([])
        m = Model()
        w = MainWindow(m)

        def cleanup() -> None:
            w.close()
            w.deleteLater()
            m.deleteLater()
            app.sendPostedEvents(None, QEvent.DeferredDelete)
            app.processEvents()

        self.addCleanup(cleanup)
        m.app_update = app_update.Release(tag='v1.2.3', url='https://example.invalid/update.zip')
        w._refresh_all()
        initial_width = w.update_btn.sizeHint().width()

        m.app_update_busy = True
        m.app_update_progress = 0.62
        w._refresh_all()
        self.assertEqual(w.update_btn.text(), '62%')
        self.assertEqual(w.ver_action_btn.text(), '62%')
        self.assertEqual(w.update_btn.minimumWidth(), initial_width)
        self.assertIn('qlineargradient', w.update_btn.styleSheet())

        m.app_update_busy = False
        m.app_update_progress = None
        w._refresh_all()
        self.assertIn('v1.2.3', w.update_btn.text())
        self.assertEqual(w.update_btn.styleSheet(), '')
        self.assertEqual(w.update_btn.minimumWidth(), 0)


if __name__ == '__main__':
    unittest.main()
