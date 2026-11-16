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


if __name__ == '__main__':
    unittest.main()
