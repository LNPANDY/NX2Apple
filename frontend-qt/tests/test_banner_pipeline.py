"""Tests for Qt banner pipeline: known-banner fast path, chunked titledb fetch,
on-demand backfill during iOS packaging, and 512x512 square fallback icon generation.
"""
from __future__ import annotations

import io
import json
import os
import re
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = ROOT.parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from nspb_qt import known_banners as kb
from nspb_qt import library as lib
from nspb_qt.win import shell_export as se


def _make_wide_png(width: int = 160, height: int = 80) -> bytes:
    """Create a real 8-bit RGB PNG with red left/right wings and a green center square."""
    side = min(width, height)
    x0 = (width - side) // 2
    x1 = x0 + side
    rows = bytearray()
    for _y in range(height):
        rows.append(0)
        for x in range(width):
            if x0 <= x < x1:
                rows.extend((20, 200, 40))  # green center
            else:
                rows.extend((220, 30, 30))  # red sides

    def chunk(tag: bytes, payload: bytes) -> bytes:
        crc = zlib.crc32(tag + payload) & 0xFFFFFFFF
        return struct.pack('>I', len(payload)) + tag + payload + struct.pack('>I', crc)

    ihdr = struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0)
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', ihdr) + chunk(b'IDAT', zlib.compress(bytes(rows))) + chunk(b'IEND', b'')


def _png_dimensions(data: bytes) -> tuple[int, int]:
    assert data[:8] == b'\x89PNG\r\n\x1a\n', 'not a PNG'
    assert data[12:16] == b'IHDR', 'missing IHDR'
    return struct.unpack('>II', data[16:24])


class _ChunkedResp:
    def __init__(self, body: bytes, max_chunk: int = 32) -> None:
        self._body = body
        self._pos = 0
        self._max_chunk = max_chunk
        self.read_calls = 0

    def read(self, n: int = -1) -> bytes:
        self.read_calls += 1
        if self._pos >= len(self._body):
            return b''
        take = len(self._body) - self._pos if n < 0 else min(n, self._max_chunk, len(self._body) - self._pos)
        out = self._body[self._pos:self._pos + take]
        self._pos += take
        return out

    def __enter__(self) -> _ChunkedResp:
        return self

    def __exit__(self, *_a: object) -> bool:
        return False


class BannerPipelineTests(unittest.TestCase):
    def test_known_banners_stay_in_sync_with_swift_nxcore_table(self) -> None:
        swift_file = REPO_ROOT / 'frontend' / 'Sources' / 'NXCore' / 'KnownGameBanners.swift'
        text = swift_file.read_text(encoding='utf-8')
        m = re.search(r'package static let urls: \[String: String\] = \[(.*?)\n    \]', text, re.S)
        self.assertIsNotNone(m)
        swift_urls = dict(re.findall(r'"([0-9A-F]{16})":\s*"(https://[^"]+)"', m.group(1)))
        self.assertGreaterEqual(len(swift_urls), 150)
        self.assertEqual(kb.KNOWN_BANNERS, swift_urls)
        for tid, url in kb.KNOWN_BANNERS.items():
            self.assertTrue(kb.is_valid_title_id(tid), tid)
            self.assertTrue(kb.is_allowed_banner_url(url), url)

    def test_known_banner_fetches_single_image_without_downloading_90mb_titledb(self) -> None:
        tid = '01007EF00011E000'
        png_bytes = _make_wide_png(160, 80)
        requested: list[tuple[str, float]] = []
        updated: list[str] = []

        def fake_urlopen(req, timeout=15):
            url = req.full_url if hasattr(req, 'full_url') else str(req)
            requested.append((url, timeout))
            if url == lib.ArtworkStore.TITLEDB_URL:
                raise AssertionError('must not fetch 90 MB titledb for a known game')
            return _ChunkedResp(png_bytes, max_chunk=64)

        with tempfile.TemporaryDirectory() as td:
            store = lib.ArtworkStore(state_dir=Path(td), on_updated=updated.append)
            with mock.patch('urllib.request.urlopen', side_effect=fake_urlopen):
                store._fetch_one(tid)
            self.assertEqual(len(requested), 1)
            self.assertEqual(requested[0][0], kb.KNOWN_BANNERS[tid])
            self.assertGreaterEqual(requested[0][1], 30)
            self.assertEqual(updated, [tid])
            self.assertTrue((store.banners_dir / f'{tid}.png').is_file())
            self.assertFalse((store.banners_dir / 'banners_index.json').exists())

    def test_nlib_tier2_fetches_unknown_title_with_8s_timeout_without_titledb(self) -> None:
        unknown_tid = '0100CAFE12340000'
        expected_url = f'https://api.nlib.cc/nx/{unknown_tid}/banner/720p'
        self.assertIn('api.nlib.cc', kb.ALLOWED_IMAGE_HOSTS)
        self.assertEqual(kb.nlib_banner_url(unknown_tid), expected_url)

        png_bytes = _make_wide_png(160, 80)
        requested: list[tuple[str, float]] = []
        updated: list[str] = []

        def fake_urlopen(req, timeout=15):
            url = req.full_url if hasattr(req, 'full_url') else str(req)
            requested.append((url, timeout))
            if url == lib.ArtworkStore.TITLEDB_URL:
                raise AssertionError('must not download 90 MB titledb when nlib.cc returns 200')
            return _ChunkedResp(png_bytes, max_chunk=64)

        with tempfile.TemporaryDirectory() as td:
            store = lib.ArtworkStore(state_dir=Path(td), on_updated=updated.append)
            with mock.patch('urllib.request.urlopen', side_effect=fake_urlopen):
                store._fetch_one(unknown_tid)
            self.assertEqual(requested, [(expected_url, 8.0)])
            self.assertEqual(updated, [unknown_tid])
            self.assertTrue((store.banners_dir / f'{unknown_tid}.png').is_file())
            self.assertFalse((store.banners_dir / 'banners_index.json').exists())

    def test_titledb_uses_chunked_streaming_30s_timeout_and_never_caches_empty_or_failed_index(self) -> None:
        unknown_tid = '0100DEADBEEF0000'
        banner_url = 'https://img-eshop.cdn.nintendo.net/i/unknown-title.png'
        png_bytes = _make_wide_png(120, 60)
        titledb_timeouts: list[float] = []
        attempts = 0

        def fake_urlopen(req, timeout=15):
            nonlocal attempts
            url = req.full_url if hasattr(req, 'full_url') else str(req)
            if 'api.nlib.cc' in url:
                raise OSError('HTTP 404 from nlib.cc')
            if url == lib.ArtworkStore.TITLEDB_URL:
                titledb_timeouts.append(timeout)
                attempts += 1
                if attempts == 1:
                    raise TimeoutError('simulated transient drop')
                if attempts == 2:
                    return _ChunkedResp(b'{}', max_chunk=8)
                payload = json.dumps({
                    '7001': {'id': unknown_tid, 'bannerUrl': banner_url},
                }).encode('utf-8')
                return _ChunkedResp(payload, max_chunk=16)
            titledb_timeouts.append(timeout)
            return _ChunkedResp(png_bytes, max_chunk=64)

        with tempfile.TemporaryDirectory() as td:
            store = lib.ArtworkStore(state_dir=Path(td))
            index_file = store.banners_dir / 'banners_index.json'
            with mock.patch('urllib.request.urlopen', side_effect=fake_urlopen):
                # Attempt 1: network error must not cache failure or write index
                store._fetch_one(unknown_tid)
                self.assertFalse(index_file.exists())
                self.assertIsNone(store._titledb_cache)

                # Attempt 2: empty dict must not be written to cache
                store._fetch_one(unknown_tid)
                self.assertFalse(index_file.exists())
                self.assertIsNone(store._titledb_cache)

                # Attempt 3: succeeds with chunked stream and writes index atomically
                store._fetch_one(unknown_tid)
                self.assertTrue(index_file.is_file())
                cached_index = json.loads(index_file.read_text(encoding='utf-8'))
                self.assertEqual(cached_index, {unknown_tid: banner_url})
                self.assertTrue((store.banners_dir / f'{unknown_tid}.png').is_file())
            self.assertTrue(all(t >= 30 for t in titledb_timeouts), titledb_timeouts)

    def test_place_banner_backfills_unknown_game_via_nlib_and_creates_512_icon(self) -> None:
        unknown_tid = '0100F00DBABE0000'
        png_bytes = _make_wide_png(160, 80)
        seen: list[tuple[str, float]] = []

        def fake_opener(req, timeout=15):
            url = req.full_url if hasattr(req, 'full_url') else str(req)
            seen.append((url, timeout))
            return _ChunkedResp(png_bytes, max_chunk=64)

        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            banners = root / 'banners'
            fw = root / f'DmGame{unknown_tid}.framework'
            fw.mkdir()

            placed = se.place_banner(unknown_tid, fw, banners_dir=banners, picked=None, opener=fake_opener)
            self.assertIsNotNone(placed)
            self.assertEqual(seen, [(f'https://api.nlib.cc/nx/{unknown_tid}/banner/720p', 8.0)])
            self.assertTrue((fw / 'banner.png').is_file())
            self.assertEqual(_png_dimensions((fw / 'icon.png').read_bytes()), (512, 512))

    def test_place_banner_backfills_missing_cache_and_generates_square_fallback_icon(self) -> None:
        tid = '0400486024DEC000'
        png_bytes = _make_wide_png(160, 80)
        seen_urls: list[str] = []

        def fake_opener(req, timeout=15):
            url = req.full_url if hasattr(req, 'full_url') else str(req)
            seen_urls.append(url)
            return _ChunkedResp(png_bytes, max_chunk=64)

        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            banners = root / 'banners'
            fw = root / f'DmGame{tid}.framework'
            fw.mkdir()

            placed = se.place_banner(tid, fw, banners_dir=banners, picked=None, opener=fake_opener)
            self.assertIsNotNone(placed)
            self.assertEqual(seen_urls, [kb.KNOWN_BANNERS[tid]])
            self.assertTrue((banners / f'{tid}.png').is_file())
            self.assertTrue((fw / 'banner.png').is_file())

            icon_path = fw / 'icon.png'
            self.assertTrue(icon_path.is_file(), 'missing icon.png must be synthesized from banner')
            self.assertEqual(_png_dimensions(icon_path.read_bytes()), (512, 512))

    def test_place_banner_preserves_existing_native_icon_png(self) -> None:
        tid = '01007EF00011E000'
        png_bytes = _make_wide_png(160, 80)
        native_icon = b'\x89PNG\r\n\x1a\nNATIVE_GAME_ICON_MARKER'

        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            banners = root / 'banners'
            banners.mkdir()
            (banners / f'{tid}.png').write_bytes(png_bytes)
            fw = root / f'DmGame{tid}.framework'
            fw.mkdir()
            (fw / 'icon.png').write_bytes(native_icon)

            placed = se.place_banner(tid, fw, banners_dir=banners, picked=None, fetch_missing=False)
            self.assertEqual(placed, str(banners / f'{tid}.png'))
            self.assertEqual((fw / 'icon.png').read_bytes(), native_icon)

    def test_place_banner_works_without_pyside6_or_pillow(self) -> None:
        """Verify banner backfill and pure-Python 512x512 icon fallback with both PySide6 and PIL blocked."""
        script = f"""
import importlib.machinery
import importlib.util
import struct
import sys
import tempfile
import zlib
from pathlib import Path

BLOCKED = {{'PySide6', 'PIL'}}

class _BlockFinder:
    def __init__(self, wrapped):
        self._wrapped = wrapped
    def find_spec(self, fullname, path=None, target=None):
        top = fullname.split('.')[0]
        if top in BLOCKED:
            return None
        if hasattr(self._wrapped, 'find_spec'):
            return self._wrapped.find_spec(fullname, path, target)
        return None

sys.meta_path = [_BlockFinder(f) for f in sys.meta_path]
assert importlib.util.find_spec('PySide6') is None
assert importlib.util.find_spec('PIL') is None

sys.path.insert(0, {str(ROOT)!r})
from nspb_qt.win import shell_export as se

def make_png(w=120, h=60):
    rows = bytearray()
    for _y in range(h):
        rows.append(0)
        for x in range(w):
            rows.extend((10, 180, 20) if 30 <= x < 90 else (200, 10, 10))
    def ch(t, p):
        return struct.pack('>I', len(p)) + t + p + struct.pack('>I', zlib.crc32(t + p) & 0xFFFFFFFF)
    ihdr = struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)
    return b'\\x89PNG\\r\\n\\x1a\\n' + ch(b'IHDR', ihdr) + ch(b'IDAT', zlib.compress(bytes(rows))) + ch(b'IEND', b'')

with tempfile.TemporaryDirectory() as td:
    root = Path(td)
    banners = root / 'banners'
    banners.mkdir()
    tid = '0400486024DEC000'
    (banners / f'{{tid}}.png').write_bytes(make_png())
    fw = root / f'DmGame{{tid}}.framework'
    fw.mkdir()
    placed = se.place_banner(tid, fw, banners_dir=banners, picked=None, fetch_missing=False)
    assert placed == str(banners / f'{{tid}}.png'), placed
    icon = (fw / 'icon.png').read_bytes()
    assert icon[:8] == b'\\x89PNG\\r\\n\\x1a\\n'
    w, h = struct.unpack('>II', icon[16:24])
    assert (w, h) == (512, 512), (w, h)

    # Non-PNG unreadable banner must safely skip icon synthesis without crashing
    fw2 = root / 'DmGame0100000000010000.framework'
    fw2.mkdir()
    (banners / '0100000000010000.jpg').write_bytes(b'\\xff\\xd8\\xff\\xe0fake-jpeg-without-pillow')
    placed2 = se.place_banner('0100000000010000', fw2, banners_dir=banners, picked=None, fetch_missing=False)
    assert placed2 == str(banners / '0100000000010000.jpg')
    assert not (fw2 / 'icon.png').exists()
print('OK')
"""
        with tempfile.TemporaryDirectory() as td:
            script_path = Path(td) / 'verify_no_gui_no_pil.py'
            script_path.write_text(script, encoding='utf-8')
            r = subprocess.run([sys.executable, str(script_path)], capture_output=True, text=True, check=False)
            self.assertEqual(r.returncode, 0, f'stdout={r.stdout}\nstderr={r.stderr}')
            self.assertIn('OK', r.stdout)


if __name__ == '__main__':
    unittest.main()
