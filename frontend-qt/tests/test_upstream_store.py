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

    def test_version_receipt_eocd_legacy_fallback_and_remote_parsing(self) -> None:
        old_sha = '1111111111111111111111111111111111111111'
        new_sha = '2222222222222222222222222222222222222222'

        zip_path = self.temp_dir / 's2arm-eocd.zip'
        with zipfile.ZipFile(zip_path, 'w') as zf:
            zf.writestr('S2Arm-main/pack/jobs/main.py', '#!/usr/bin/env python3\n')
            zf.writestr('S2Arm-main/runtime/rewriter/rewriter.c', '/* rewriter */\n')
            zf.writestr('S2Arm-main/pack/oneclick/oneclick.sh', '#!/bin/bash\n')
            zf.writestr('S2Arm-main/pack/orch/oneclick_win.py', '#!/usr/bin/env python3\n')
            zf.comment = old_sha.upper().encode('utf-8')

        self.assertEqual(upstream_store.extract_git_commit_from_zip(zip_path), old_sha)

        remote_v057 = upstream_store.UpstreamRemoteInfo(kind='s2arm', commit=old_sha, version='v0.5.7', date='2026.11.10')
        installed = upstream_store.install_upstream_zip(
            zip_path,
            's2arm',
            self.store_root,
            remote_info=remote_v057,
            is_windows=False,
        )
        receipt = upstream_store.read_local_receipt('s2arm', str(installed), is_windows=False)
        self.assertIsNotNone(receipt)
        assert receipt is not None
        self.assertEqual(receipt.commit, old_sha)
        self.assertEqual(receipt.version, 'v0.5.7')
        self.assertFalse(upstream_store.has_update(receipt, remote_v057))

        # Failed update preserves old receipt and directory
        bad_zip = self._make_s2arm_zip('incomplete-update.zip', complete=False)
        with self.assertRaises(upstream_store.UpstreamInstallError):
            upstream_store.install_upstream_zip(bad_zip, 's2arm', self.store_root, is_windows=False)
        preserved = upstream_store.read_local_receipt('s2arm', str(installed), is_windows=False)
        self.assertEqual(preserved, receipt)

        # Legacy install without .upstream-version.json falls back to entry mtime and flags update
        (installed / upstream_store.RECEIPT_FILENAME).unlink()
        entry = installed / 'pack' / 'jobs' / 'main.py'
        os.utime(entry, (1_763_424_000, 1_763_424_000))
        legacy = upstream_store.read_local_receipt('s2arm', str(installed), is_windows=False)
        self.assertIsNotNone(legacy)
        assert legacy is not None
        self.assertIsNone(legacy.commit)
        self.assertEqual(legacy.version, '2025.11.18')
        self.assertTrue(upstream_store.has_update(legacy, remote_v057))

        # Remote parsing via Git Smart HTTP info/refs: exact tag, ahead (+), annotated ^{}, ignore impactor-*
        tag_obj_sha = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
        refs_exact = (
            '001e# service=git-upload-pack\n'
            f'00000159{new_sha} HEAD\x00multi_ack\n'
            f'003d{new_sha} refs/heads/main\n'
            f'0040{old_sha} refs/tags/impactor-1.0\n'
            f'003e{tag_obj_sha} refs/tags/v0.5.8\n'
            f'0041{new_sha} refs/tags/v0.5.8^{{}}\n'
        )
        refs_ahead = (
            f'003d{new_sha} refs/heads/main\n'
            f'0040{new_sha} refs/tags/impactor-2.0\n'
            f'003e{old_sha} refs/tags/v0.5.8\n'
        )
        refs_notags = f'003d{new_sha} refs/heads/main\n'
        exact = upstream_store.parse_info_refs('s2arm', refs_exact)
        ahead = upstream_store.parse_info_refs('s2arm', refs_ahead)
        fallback = upstream_store.parse_info_refs('s2arm', refs_notags)
        self.assertIsNotNone(exact)
        self.assertIsNotNone(ahead)
        self.assertIsNotNone(fallback)
        assert exact and ahead and fallback
        self.assertEqual(exact.version, 'v0.5.8')
        self.assertEqual(ahead.version, 'v0.5.8+')
        self.assertEqual(fallback.version, new_sha[:7])

        # MacNativeGames source-YYYYMMDD-<sha> tags: exact vs ahead (+) and same-day SHA comparison
        mng_refs_ahead = (
            f'003d{new_sha} refs/heads/main\n'
            f'0050{old_sha} refs/tags/source-20261118-{old_sha[:8]}\n'
        )
        mng_remote = upstream_store.parse_info_refs('macnativegames', mng_refs_ahead)
        assert mng_remote is not None
        self.assertEqual(mng_remote.version, '2026.11.18+')
        mng_local_old = upstream_store.UpstreamVersionReceipt(commit=old_sha, version='2026.11.18', installed_at='2026.11.18')
        self.assertTrue(upstream_store.has_update(mng_local_old, mng_remote))

        # First-time download without remote_info auto-queries info/refs for semantic tag receipt
        first_root = self.temp_dir / 'first-dl'
        first_payload = zip_path.read_bytes()
        installed_first = upstream_store.download_and_install_upstream(
            's2arm',
            first_root,
            downloader=lambda _u, dst, _p: dst.write_bytes(first_payload),
            fetch_text=lambda _u: refs_ahead,
            is_windows=False,
        )
        first_rec = upstream_store.read_local_receipt('s2arm', str(installed_first), is_windows=False)
        assert first_rec is not None
        self.assertEqual(first_rec.commit, old_sha)
        self.assertEqual(first_rec.version, 'v0.5.8+')

        # Built-in .upstream-ref short SHA
        fake_repo = self.temp_dir / 'repo'
        fake_repo.mkdir()
        (fake_repo / '.upstream-ref').write_text('0b5fd6020093abcdef1234567890abcdef123456\n', encoding='utf-8')
        builtin_rec = upstream_store.read_local_receipt('nxnative', repo_path=str(fake_repo))
        assert builtin_rec is not None
        self.assertEqual(builtin_rec.version, '0b5fd60')
        self.assertEqual(
            upstream_store.compact_badge_text('nxnative', builtin_rec, update_available=False, builtin_fallback='Built-in', installed_fallback='Installed'),
            '0b5fd60',
        )
        self.assertEqual(
            upstream_store.compact_badge_text('s2arm', receipt, update_available=True, builtin_fallback='Built-in', installed_fallback='Installed'),
            'v0.5.7 ↑',
        )

    def test_version_checker_caches_success_and_never_caches_failure(self) -> None:
        now_box = [1000.0]
        hits: list[str] = []
        should_fail = [True]
        sha = '3333333333333333333333333333333333333333'

        def fake_fetch(url: str):
            hits.append(url)
            if should_fail[0]:
                raise RuntimeError('offline')
            return f'003d{sha} refs/heads/main\n003e{sha} refs/tags/v0.5.8\n'

        checker = upstream_store.UpstreamVersionChecker(now_fn=lambda: now_box[0])
        threads = checker.check_async(('s2arm',), is_installed=lambda k: k == 's2arm', fetch_text=fake_fetch)
        for t in threads:
            t.join(timeout=5.0)
        self.assertIsNone(checker.remote_info('s2arm'))
        self.assertEqual(len(hits), 1)

        # Retry immediately after failure succeeds
        should_fail[0] = False
        threads = checker.check_async(('s2arm',), is_installed=lambda k: k == 's2arm', fetch_text=fake_fetch)
        for t in threads:
            t.join(timeout=5.0)
        info = checker.remote_info('s2arm')
        self.assertIsNotNone(info)
        assert info is not None
        self.assertEqual(info.version, 'v0.5.8')
        hits_after_ok = len(hits)

        # Within 10-minute TTL, cached result skips network
        now_box[0] += 300.0
        threads = checker.check_async(('s2arm',), is_installed=lambda k: k == 's2arm', fetch_text=fake_fetch)
        self.assertEqual(threads, [])
        self.assertEqual(len(hits), hits_after_ok)

        # After TTL expires, fetches again
        now_box[0] += 400.0
        threads = checker.check_async(('s2arm',), is_installed=lambda k: k == 's2arm', fetch_text=fake_fetch)
        for t in threads:
            t.join(timeout=5.0)
        self.assertGreater(len(hits), hits_after_ok)


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

        self.assertEqual(win.eng_active_title.text(), m.t('engine.switcherTitle'))
        self.assertEqual(win.eng_experimental_badge.text(), m.t('engine.experimental'))
        self.assertEqual(win.eng_active_sub.text(), m.t('engine.switcherNote'))
        self.assertEqual(win.eng_dropdown_btn.text(), 'nxnative  ▾')

        popup = win._ensure_engine_popup()
        win._refresh_engine_popup()
        self.assertEqual(tuple(win._eng_popup_rows.keys()), ('nxnative', 's2arm'))
        self.assertEqual(win._eng_popup_rows['s2arm']['btn'].text(), m.t('upstream.download'))
        self.assertTrue(win._eng_popup_rows['nxnative']['exp_badge'].isHidden())
        self.assertFalse(win._eng_popup_rows['s2arm']['exp_badge'].isHidden())
        self.assertEqual(win._eng_popup_rows['s2arm']['exp_badge'].text(), m.t('engine.experimental'))
        self.assertFalse(popup.isVisible())

        # Install S2Arm with an older SHA, inject newer remote info, verify compact badge + Update button
        old_sha = '1111111111111111111111111111111111111111'
        new_sha = '2222222222222222222222222222222222222222'
        zip_path = self.temp_dir / 's2arm-old.zip'
        with zipfile.ZipFile(zip_path, 'w') as zf:
            zf.writestr('S2Arm-main/pack/jobs/main.py', '#!/usr/bin/env python3\n')
            zf.writestr('S2Arm-main/runtime/rewriter/rewriter.c', '/* rewriter */\n')
            zf.writestr('S2Arm-main/pack/oneclick/oneclick.sh', '#!/bin/bash\n')
            zf.writestr('S2Arm-main/pack/orch/oneclick_win.py', '#!/usr/bin/env python3\n')
            zf.comment = old_sha.encode('utf-8')
        installed = upstream_store.install_upstream_zip(
            zip_path,
            's2arm',
            self.temp_dir / 'upstreams',
            remote_info=upstream_store.UpstreamRemoteInfo('s2arm', old_sha, 'v0.5.7', '2026.11.10'),
            is_windows=False,
        )
        m.s2arm_path = str(installed)
        m.select_upstream('s2arm')
        m._upstream_version_checker.set_remote_info(
            's2arm',
            upstream_store.UpstreamRemoteInfo('s2arm', new_sha, 'v0.5.8', '2026.11.19'),
        )
        win._refresh_engine_switcher()
        win._refresh_engine_popup()
        self.assertEqual(win.eng_active_badge.text(), 'v0.5.7 ↑')
        self.assertIn('v0.5.8', win.eng_active_badge.toolTip())
        self.assertFalse(win._eng_popup_rows['s2arm']['update_btn'].isHidden())
        self.assertEqual(win._eng_popup_rows['s2arm']['update_btn'].text(), m.t('upstream.update'))
        self.assertTrue(win._eng_popup_rows['nxnative']['update_btn'].isHidden())

        # Same-commit local short-hash receipt upgrades to semantic remote version on disk and UI
        upstream_store.write_version_receipt(
            installed,
            upstream_store.UpstreamVersionReceipt(commit=new_sha, version=new_sha[:7], installed_at='2026.11.19'),
        )
        m._upstream_version_checker.set_remote_info(
            's2arm',
            upstream_store.UpstreamRemoteInfo('s2arm', new_sha, 'v0.5.8+', '2026.11.19'),
        )
        win._refresh_engine_switcher()
        self.assertEqual(win.eng_active_badge.text(), 'v0.5.8+')
        upgraded_disk = upstream_store.read_local_receipt('s2arm', str(installed), is_windows=False)
        assert upgraded_disk is not None
        self.assertEqual(upgraded_disk.version, 'v0.5.8+')


if __name__ == '__main__':
    unittest.main()
