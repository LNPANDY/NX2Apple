"""Tests for external upstream engine download, extraction, and storage in frontend-qt."""
from __future__ import annotations

import os
from pathlib import Path
import shutil
import stat
import sys
import tempfile
import unittest
from unittest import mock
import zipfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'frontend-qt'))

from nspb_qt import upstream_store


class UpstreamStoreTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = Path(tempfile.mkdtemp(prefix='upstream-store-test-'))
        self.addCleanup(shutil.rmtree, self.temp_dir, True)
        self.store_root = self.temp_dir / 'upstreams'

    def _make_s2arm_zip(self, zip_name: str = 's2arm.zip', *, complete: bool = True, wrapper: str = 'S2Arm-main') -> Path:
        zip_path = self.temp_dir / zip_name
        prefix = f'{wrapper}/' if wrapper else ''
        with zipfile.ZipFile(zip_path, 'w') as zf:
            zf.writestr('__MACOSX/._S2Arm-main', 'junk')
            zf.writestr(f'{prefix}pack/jobs/main.py', '#!/usr/bin/env python3\n')
            if complete:
                zf.writestr(f'{prefix}runtime/rewriter/rewriter.c', '/* rewriter */\n')
                zf.writestr(f'{prefix}pack/oneclick/oneclick.sh', '#!/bin/bash\n')
                zf.writestr(f'{prefix}pack/orch/oneclick_win.py', '#!/usr/bin/env python3\n')
        return zip_path

    def test_available_upstreams(self) -> None:
        with mock.patch.dict(os.environ, {}, clear=False):
            os.environ.pop('NX2APPLE_MULTI_UPSTREAM', None)
            self.assertEqual(upstream_store.available_upstreams(is_windows=True), ('nxnative', 's2arm'))
            self.assertEqual(upstream_store.available_upstreams(is_windows=False), ('nxnative', 's2arm'))
        with mock.patch.dict(os.environ, {'NX2APPLE_MULTI_UPSTREAM': '0'}, clear=False):
            self.assertEqual(upstream_store.available_upstreams(is_windows=True), ('nxnative',))

    def test_format_download_progress(self) -> None:
        frac, text = upstream_store.format_download_progress(10 * 1024 * 1024, 40 * 1024 * 1024)
        self.assertAlmostEqual(frac or 0.0, 0.25)
        self.assertEqual(text, '10.0 / 40.0 MB (25%)')

        frac_unknown, text_unknown = upstream_store.format_download_progress(5 * 1024 * 1024, None)
        self.assertIsNone(frac_unknown)
        self.assertEqual(text_unknown, '5.0 MB')

    def test_install_upstream_zip_unwraps_github_folder_and_cleans_temp(self) -> None:
        zip_path = self._make_s2arm_zip()
        installed = upstream_store.install_upstream_zip(zip_path, 's2arm', self.store_root, is_windows=False)
        self.assertEqual(installed, self.store_root / 's2arm')
        self.assertEqual(
            upstream_store.usable_managed_path('s2arm', self.store_root, is_windows=False),
            str(installed),
        )
        self.assertEqual(
            upstream_store.usable_managed_path('s2arm', self.store_root, is_windows=True),
            str(installed),
        )
        if os.name != 'nt':
            mode = (installed / 'pack' / 'oneclick' / 'oneclick.sh').stat().st_mode
            self.assertTrue(bool(mode & stat.S_IXUSR))
        leftovers = [p.name for p in self.store_root.iterdir() if p.name.startswith('.')]
        self.assertEqual(leftovers, [])

    def test_install_rejects_incomplete_or_corrupt_zip_and_preserves_existing_tree(self) -> None:
        good_zip = self._make_s2arm_zip('good.zip', complete=True)
        installed = upstream_store.install_upstream_zip(good_zip, 's2arm', self.store_root, is_windows=False)
        marker = installed / 'marker.txt'
        marker.write_text('keep-me', encoding='utf-8')

        incomplete_zip = self._make_s2arm_zip('incomplete.zip', complete=False)
        with self.assertRaises(upstream_store.UpstreamInstallError) as ctx:
            upstream_store.install_upstream_zip(incomplete_zip, 's2arm', self.store_root, is_windows=False)
        self.assertEqual(ctx.exception.kind, 'extract')
        self.assertEqual(marker.read_text(encoding='utf-8'), 'keep-me')

        corrupt_zip = self.temp_dir / 'corrupt.zip'
        corrupt_zip.write_bytes(b'not-a-zip-archive')
        with self.assertRaises(upstream_store.UpstreamInstallError) as ctx2:
            upstream_store.install_upstream_zip(corrupt_zip, 's2arm', self.store_root, is_windows=False)
        self.assertEqual(ctx2.exception.kind, 'extract')
        self.assertEqual(marker.read_text(encoding='utf-8'), 'keep-me')
        leftovers = [p.name for p in self.store_root.iterdir() if p.name.startswith('.')]
        self.assertEqual(leftovers, [])

    def test_download_and_install_upstream_callbacks_and_failure(self) -> None:
        source_zip = self._make_s2arm_zip('remote.zip', complete=True)
        payload = source_zip.read_bytes()
        events: list[str] = []

        def fake_downloader(url: str, dest: Path, on_progress) -> None:
            self.assertIn('S2Arm', url)
            if on_progress:
                on_progress(len(payload) // 2, len(payload))
            dest.write_bytes(payload)
            if on_progress:
                on_progress(len(payload), len(payload))

        installed = upstream_store.download_and_install_upstream(
            's2arm',
            self.store_root,
            downloader=fake_downloader,
            on_progress=lambda w, e: events.append(f'p:{w}/{e}'),
            on_extracting=lambda: events.append('extracting'),
            is_windows=False,
        )
        self.assertEqual(installed, self.store_root / 's2arm')
        self.assertEqual(events[-1], 'extracting')
        self.assertTrue(any(ev.startswith('p:') for ev in events))
        leftovers = [p.name for p in self.store_root.iterdir() if p.name.startswith('.')]
        self.assertEqual(leftovers, [])

        def failing_downloader(_url: str, _dest: Path, _on_progress) -> None:
            raise upstream_store.UpstreamInstallError('download', 'network offline')

        with self.assertRaises(upstream_store.UpstreamInstallError) as fail_ctx:
            upstream_store.download_and_install_upstream(
                's2arm',
                self.store_root,
                downloader=failing_downloader,
                is_windows=False,
            )
        self.assertEqual(fail_ctx.exception.kind, 'download')

        with self.assertRaises(upstream_store.UpstreamInstallError) as unsup_ctx:
            upstream_store.download_and_install_upstream('nxnative', self.store_root)
        self.assertEqual(unsup_ctx.exception.kind, 'unsupported')

    def test_upstream_metadata_helpers(self) -> None:
        self.assertEqual(upstream_store.upstream_display_name('nxnative'), 'nxnative')
        self.assertEqual(upstream_store.upstream_display_name('s2arm'), 'S2Arm')
        self.assertEqual(upstream_store.upstream_display_name('macnativegames'), 'MacNativeGames')
        self.assertTrue(upstream_store.upstream_is_builtin('nxnative'))
        self.assertFalse(upstream_store.upstream_is_builtin('s2arm'))
        self.assertEqual(upstream_store.upstream_note_key('s2arm'), 'upstream.s2armCardNote')

    def test_download_and_install_cancellation_cleans_staging(self) -> None:
        import threading

        cancel_ev = threading.Event()
        source_zip = self._make_s2arm_zip('cancel.zip', complete=True)
        payload = source_zip.read_bytes()

        def cancelling_downloader(_url: str, dest: Path, on_progress, cancel_event=None) -> None:
            self.assertIs(cancel_event, cancel_ev)
            dest.write_bytes(payload[:64])
            cancel_ev.set()
            if on_progress:
                on_progress(64, len(payload))

        with self.assertRaises(upstream_store.UpstreamInstallError) as ctx:
            upstream_store.download_and_install_upstream(
                's2arm',
                self.store_root,
                downloader=cancelling_downloader,
                cancel_event=cancel_ev,
                is_windows=False,
            )
        self.assertEqual(ctx.exception.kind, 'cancelled')
        self.assertEqual(upstream_store.usable_managed_path('s2arm', self.store_root, is_windows=False), '')
        leftovers = list(self.store_root.iterdir()) if self.store_root.exists() else []
        self.assertEqual(leftovers, [])

    def test_coordinator_auto_install_cancel_and_stale_generation(self) -> None:
        import threading

        source_zip = self._make_s2arm_zip('coord.zip', complete=True)
        payload = source_zip.read_bytes()
        installed_events: list[tuple[str, Path]] = []
        running = False

        coord = upstream_store.UpstreamDownloadCoordinator(
            root=self.store_root,
            is_running=lambda: running,
            on_installed=lambda k, p: installed_events.append((k, p)),
        )
        self.assertEqual(coord.state('nxnative'), ('builtin', None, ''))
        self.assertEqual(coord.state('s2arm', installed=False), ('not_installed', None, ''))

        # 1. Cancel mid-flight resets state immediately and stale worker cannot overwrite restarted download
        first_entered = threading.Event()
        release_first = threading.Event()
        call_count = 0
        call_lock = threading.Lock()

        def gated_downloader(_url: str, dest: Path, on_progress, cancel_event=None) -> None:
            nonlocal call_count
            with call_lock:
                call_count += 1
                idx = call_count
            if idx == 1:
                if on_progress:
                    on_progress(128, 1024)
                first_entered.set()
                release_first.wait(timeout=5.0)
                raise upstream_store.UpstreamInstallError('download', 'stale failure')
            dest.write_bytes(payload)
            if on_progress:
                on_progress(len(payload), len(payload))

        t1 = coord.start_download('s2arm', downloader=gated_downloader, is_windows=False)
        self.assertIsNotNone(t1)
        self.assertTrue(first_entered.wait(timeout=5.0))
        self.assertTrue(coord.is_busy('s2arm'))

        self.assertTrue(coord.cancel('s2arm'))
        self.assertEqual(coord.state('s2arm', installed=False), ('not_installed', None, ''))

        t2 = coord.start_download('s2arm', downloader=gated_downloader, is_windows=False)
        self.assertIsNotNone(t2)
        assert t2 is not None
        t2.join(timeout=5.0)
        self.assertEqual(len(installed_events), 1)
        self.assertEqual(installed_events[0][0], 's2arm')
        self.assertEqual(coord.state('s2arm', installed=True), ('installed', None, ''))

        release_first.set()
        assert t1 is not None
        t1.join(timeout=5.0)
        self.assertEqual(coord.state('s2arm', installed=True), ('installed', None, ''))
        self.assertEqual(len(installed_events), 1)


try:
    from PySide6.QtCore import QSettings
    from PySide6.QtWidgets import QApplication
    HAS_PYSIDE6 = True
except ImportError:
    HAS_PYSIDE6 = False


@unittest.skipUnless(HAS_PYSIDE6, 'PySide6 required for Qt Model/MainWindow engine dropdown tests')
class QtEngineDropdownTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        os.environ.setdefault('QT_QPA_PLATFORM', 'offscreen')
        cls._app = QApplication.instance() or QApplication([])

    def setUp(self) -> None:
        self.temp_dir = Path(tempfile.mkdtemp(prefix='qt-engine-dropdown-test-'))
        self.addCleanup(shutil.rmtree, self.temp_dir, True)
        QSettings.setDefaultFormat(QSettings.Format.IniFormat)
        QSettings.setPath(QSettings.Format.IniFormat, QSettings.Scope.UserScope, str(self.temp_dir / 'settings'))
        self._env_patch = mock.patch.dict(
            os.environ,
            {
                'NX2APPLE_UPSTREAMS_DIR': str(self.temp_dir / 'upstreams'),
                'NX2APPLE_MULTI_UPSTREAM': '1',
            },
            clear=False,
        )
        self._env_patch.start()
        self.addCleanup(self._env_patch.stop)

    def _make_s2arm_bytes(self) -> bytes:
        zip_path = self.temp_dir / 's2arm-src.zip'
        with zipfile.ZipFile(zip_path, 'w') as zf:
            zf.writestr('S2Arm-main/pack/jobs/main.py', '#!/usr/bin/env python3\n')
            zf.writestr('S2Arm-main/runtime/rewriter/rewriter.c', '/* rewriter */\n')
            zf.writestr('S2Arm-main/pack/oneclick/oneclick.sh', '#!/bin/bash\n')
            zf.writestr('S2Arm-main/pack/orch/oneclick_win.py', '#!/usr/bin/env python3\n')
        return zip_path.read_bytes()

    def test_model_auto_switches_on_install_unless_build_running(self) -> None:
        from nspb_qt import model

        payload = self._make_s2arm_bytes()
        m = model.Model()
        self.assertEqual(m.build_upstream, 'nxnative')

        t = m.download_upstream('s2arm', downloader=lambda _u, dest, _p: dest.write_bytes(payload))
        self.assertIsNotNone(t)
        assert t is not None
        t.join(timeout=5.0)
        self.assertEqual(m.build_upstream, 's2arm')
        self.assertEqual(m.upstream_auto_switch_revision, 1)

        # Reset to nxnative and verify running=True prevents auto-switch on install
        m.select_upstream('nxnative')
        m.s2arm_path = ''
        shutil.rmtree(self.temp_dir / 'upstreams', ignore_errors=True)

        import threading
        entered = threading.Event()
        proceed = threading.Event()

        def slow_dl(_u: str, dest: Path, _p) -> None:
            entered.set()
            proceed.wait(timeout=5.0)
            dest.write_bytes(payload)

        t2 = m.download_upstream('s2arm', downloader=slow_dl)
        self.assertIsNotNone(t2)
        self.assertTrue(entered.wait(timeout=5.0))
        m.running = True
        proceed.set()
        assert t2 is not None
        t2.join(timeout=5.0)
        self.assertTrue(m.is_upstream_installed('s2arm'))
        self.assertEqual(m.build_upstream, 'nxnative')
        self.assertEqual(m.upstream_auto_switch_revision, 1)

    def test_mainwindow_removes_by_nxnative_and_renders_dropdown_rows(self) -> None:
        from nspb_qt import model, ui

        m = model.Model()
        win = ui.MainWindow(m, perform_startup_checks=False)
        self.addCleanup(win.close)
        self.assertFalse(hasattr(win, 'sub_label'))
        self.assertEqual(win.title_label.text(), 'NX2Apple')

        popup = win._ensure_engine_popup()
        win._refresh_engine_popup()
        self.assertEqual(tuple(win._eng_popup_rows.keys()), ('nxnative', 's2arm'))
        self.assertEqual(win._eng_popup_rows['s2arm']['btn'].text(), m.t('upstream.download'))
        self.assertFalse(popup.isVisible())


if __name__ == '__main__':
    unittest.main()
