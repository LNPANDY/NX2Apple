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
    def __init__(self, body: bytes, max_chunk: int = 32, *, status: int = 200, url: str = '') -> None:
        self._body = body
        self._pos = 0
        self._max_chunk = max_chunk
        self.status = status
        self._url = url
        self.read_calls = 0

    def geturl(self) -> str:
        return self._url

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
            if 'api.nlib.cc' in url or 'ec.nintendo.com' in url:
                raise OSError('HTTP 404 from direct endpoint')
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

    def test_nintendo_store_us_next_data_switch2_priority_and_hk_og_fallback(self) -> None:
        self.assertIn('assets.nintendo.com', kb.ALLOWED_IMAGE_HOSTS)
        self.assertIn('04008E001F098000', kb.KNOWN_BANNERS)

        sw2_tid = '0400FACE12340000'
        asset_url = 'https://assets.nintendo.com/image/upload/q_auto/f_auto/store/software/switch2/70010000125145/60f801a1'
        us_html = (
            '<html><head><script id="__NEXT_DATA__" type="application/json">'
            + json.dumps({'props': {'pageProps': {'linkedData': {'@type': 'VideoGame', 'image': asset_url}}}})
            + '</script></head></html>'
        ).encode('utf-8')
        wide_png = _make_wide_png(1920, 1080)
        requested: list[str] = []

        def fake_sw2(req, timeout=15):
            url = req.full_url if hasattr(req, 'full_url') else str(req)
            requested.append(url)
            if url == f'https://ec.nintendo.com/apps/{sw2_tid}/US':
                return _ChunkedResp(us_html, url='https://www.nintendo.com/us/store/products/demo-switch-2/')
            if url == asset_url:
                return _ChunkedResp(wide_png, url=asset_url)
            if 'api.nlib.cc' in url or url == lib.ArtworkStore.TITLEDB_URL:
                raise AssertionError(f'Switch 2 store hit must not query {url}')
            return _ChunkedResp(b'', status=404, url=url)

        with tempfile.TemporaryDirectory() as td:
            store = lib.ArtworkStore(state_dir=Path(td))
            with mock.patch('urllib.request.urlopen', side_effect=fake_sw2):
                store._fetch_one(sw2_tid)
            self.assertEqual(requested, [f'https://ec.nintendo.com/apps/{sw2_tid}/US', asset_url])
            self.assertTrue((store.banners_dir / f'{sw2_tid}.png').is_file())
            self.assertIsNotNone(store.image_path(sw2_tid))

        # US 404 -> HK reversed OpenGraph fallback
        hk_tid = '0100AA11BB220000'
        hk_img = 'https://img-eshop.cdn.nintendo.net/i/0123456789abcdef0123456789abcdef.png'
        hk_html = f'<html><head><meta content="{hk_img}" property="og:image" /></head></html>'.encode('utf-8')
        hk_seen: list[str] = []

        def fake_hk(req, timeout=15):
            url = req.full_url if hasattr(req, 'full_url') else str(req)
            hk_seen.append(url)
            if url.endswith('/US'):
                return _ChunkedResp(b'', status=404, url=url)
            if url.endswith('/HK'):
                return _ChunkedResp(hk_html, url='https://ec.nintendo.com/HK/zh/titles/70010000065198')
            if url == hk_img:
                return _ChunkedResp(wide_png, url=hk_img)
            return _ChunkedResp(b'', status=404, url=url)

        state, data = kb.fetch_nintendo_store_banner(hk_tid, opener=fake_hk)
        self.assertEqual(state, 'ok')
        self.assertEqual(data, wide_png)
        self.assertEqual(hk_seen, [
            f'https://ec.nintendo.com/apps/{hk_tid}/US',
            f'https://ec.nintendo.com/apps/{hk_tid}/HK',
            hk_img,
        ])

    def test_nintendo_store_security_redirects_portrait_rejection_and_5xx_recovery(self) -> None:
        tid = '0400DEAD99990000'
        asset_url = 'https://assets.nintendo.com/image/upload/q_auto/f_auto/store/software/switch/70010000000001/abc'
        regex_html = f'{{"image":"{asset_url}"}}'.encode('utf-8')
        wide_png = _make_wide_png(1920, 1080)
        portrait_png = _make_wide_png(400, 600)

        # 1. Disallowed store redirect host is rejected
        def bad_store(req, timeout=15):
            url = req.full_url if hasattr(req, 'full_url') else str(req)
            if 'ec.nintendo.com' in url:
                return _ChunkedResp(regex_html, url='https://evil.example/fake')
            raise AssertionError('must not fetch image after disallowed store redirect')

        self.assertEqual(kb.fetch_nintendo_store_banner(tid, opener=bad_store), ('not_found', None))

        # 2. Disallowed image redirect host is rejected
        def bad_img_host(req, timeout=15):
            url = req.full_url if hasattr(req, 'full_url') else str(req)
            if url.endswith('/US'):
                return _ChunkedResp(regex_html, url='https://www.nintendo.com/us/store/products/demo/')
            if url == asset_url:
                return _ChunkedResp(wide_png, url='https://evil-cdn.example/banner.png')
            return _ChunkedResp(b'', status=404, url=url)

        self.assertEqual(kb.fetch_nintendo_store_banner(tid, opener=bad_img_host), ('not_found', None))

        # 3. Portrait image (width <= height) is rejected
        def portrait_img(req, timeout=15):
            url = req.full_url if hasattr(req, 'full_url') else str(req)
            if url.endswith('/US'):
                return _ChunkedResp(regex_html, url='https://www.nintendo.com/us/store/products/demo/')
            if url == asset_url:
                return _ChunkedResp(portrait_png, url=asset_url)
            return _ChunkedResp(b'', status=404, url=url)

        self.assertEqual(kb.fetch_nintendo_store_banner(tid, opener=portrait_img), ('not_found', None))

        # 4. 5xx returns transient and never poisons negative cache; ArtworkStore recovers and enforces batch budget
        def server_503(req, timeout=15):
            url = req.full_url if hasattr(req, 'full_url') else str(req)
            return _ChunkedResp(b'', status=503, url=url)

        self.assertEqual(kb.fetch_nintendo_store_banner(tid, opener=server_503), ('transient', None))

        clock_now = [100.0]
        calls: list[str] = []

        def slow_timeout(req, timeout=15):
            url = req.full_url if hasattr(req, 'full_url') else str(req)
            calls.append(url)
            clock_now[0] += 13.0
            raise TimeoutError('simulated offline timeout')

        with tempfile.TemporaryDirectory() as td:
            store = lib.ArtworkStore(state_dir=Path(td), clock=lambda: clock_now[0])
            with mock.patch('urllib.request.urlopen', side_effect=slow_timeout):
                self.assertFalse(store._try_store_banner('0400000000010000'))
                self.assertTrue(store._probe_budget_exhausted())
                prev = len(calls)
                # Further probes are skipped while budget is exhausted.
                self.assertFalse(store._try_store_banner('0400000000020000'))
                self.assertEqual(len(calls), prev)

            # After cooldown, transient failure is not cached and recovers cleanly.
            clock_now[0] += lib.ArtworkStore.DIRECT_PROBE_COOLDOWN + 1.0
            def recovered(req, timeout=15):
                url = req.full_url if hasattr(req, 'full_url') else str(req)
                if url.endswith('/US'):
                    return _ChunkedResp(regex_html, url='https://www.nintendo.com/us/store/products/demo/')
                if url == asset_url:
                    return _ChunkedResp(wide_png, url=asset_url)
                return _ChunkedResp(b'', status=404, url=url)

            with mock.patch('urllib.request.urlopen', side_effect=recovered):
                self.assertTrue(store._try_store_banner('0400000000010000'))
                self.assertTrue((store.banners_dir / '0400000000010000.png').is_file())

    def test_pre_hop_redirect_handler_blocks_ssrf_downgrade_and_suffix_bypass(self) -> None:
        # Host normalization & suffix-bypass checks
        self.assertTrue(kb.is_allowed_store_url('https://www.nintendo.com/us/store/products/demo/'))
        self.assertTrue(kb.is_allowed_store_url('https://store.nintendo.com.hk/70010000000001'))
        self.assertTrue(kb.is_allowed_banner_url('HTTPS://assets.nintendo.com./image/upload/x'))
        self.assertFalse(kb.is_allowed_store_url('https://evilnintendo.com/us/'))
        self.assertFalse(kb.is_allowed_store_url('https://evilnintendo.com.hk/hk/'))
        self.assertFalse(kb.is_allowed_store_url('https://evil-store.nintendo.com.hk/hk/'))
        self.assertFalse(kb.is_allowed_store_url('http://www.nintendo.com/us/'))

        store_handler = kb._AllowedRedirectHandler(kb.is_allowed_store_url)
        img_handler = kb._AllowedRedirectHandler(kb.is_allowed_banner_url)
        store_req = kb.urllib.request.Request('https://ec.nintendo.com/apps/04008E001F098000/US')
        img_req = kb.urllib.request.Request('https://assets.nintendo.com/image/upload/demo')

        # Disallowed hops must raise _PolicyRejectionError BEFORE any next-hop request is issued
        for bad_target in (
            'http://www.nintendo.com/us/store/products/demo/',
            'https://127.0.0.1/admin',
            'http://169.254.169.254/latest/meta-data/',
            'https://evil.example/bounce',
            'https://evilnintendo.com/us/store/',
            'https://evilnintendo.com.hk/hk/',
        ):
            with self.assertRaises(kb._PolicyRejectionError, msg=bad_target):
                store_handler.redirect_request(store_req, None, 302, 'Found', {}, bad_target)

        for bad_img_target in (
            'http://assets.nintendo.com/image/upload/demo',
            'https://127.0.0.1/a.jpg',
            'https://evil.example/a.jpg',
            'https://evilassets.nintendo.com/a.jpg',
        ):
            with self.assertRaises(kb._PolicyRejectionError, msg=bad_img_target):
                img_handler.redirect_request(img_req, None, 302, 'Found', {}, bad_img_target)

        # Allowed hops produce a valid next-hop Request
        ok_store = store_handler.redirect_request(
            store_req, None, 302, 'Found', {}, 'https://store.nintendo.com.hk/70010000000001'
        )
        self.assertEqual(ok_store.full_url, 'https://store.nintendo.com.hk/70010000000001')
        ok_img = img_handler.redirect_request(
            img_req, None, 302, 'Found', {}, 'https://img-eshop.cdn.nintendo.net/i/abc123.jpg'
        )
        self.assertEqual(ok_img.full_url, 'https://img-eshop.cdn.nintendo.net/i/abc123.jpg')

        # Policy rejection / oversized payload in _try_nlib_banner must NOT consume the 24s transient error budget
        clock_now = [200.0]

        def policy_rejected_urlopen(req, timeout=8):
            clock_now[0] += 30.0
            raise kb._PolicyRejectionError('disallowed redirect target')

        with tempfile.TemporaryDirectory() as td:
            store = lib.ArtworkStore(state_dir=Path(td), clock=lambda: clock_now[0])
            with mock.patch('urllib.request.urlopen', side_effect=policy_rejected_urlopen):
                self.assertFalse(store._try_nlib_banner('0100CAFE12340000'))
            self.assertFalse(store._probe_budget_exhausted())
            self.assertEqual(store._probe_error_elapsed, 0.0)

    def test_nintendo_store_fallback_works_without_pyside6(self) -> None:
        """Verify Nintendo store parser, pure-Python JPEG/PNG/WebP dimension checks, and ensure_cached_banner with PySide6 blocked."""
        script = f"""
import importlib.util
import json
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
        if fullname.split('.')[0] in BLOCKED:
            return None
        if hasattr(self._wrapped, 'find_spec'):
            return self._wrapped.find_spec(fullname, path, target)
        return None

sys.meta_path = [_BlockFinder(f) for f in sys.meta_path]
assert importlib.util.find_spec('PySide6') is None
assert importlib.util.find_spec('PIL') is None

sys.path.insert(0, {str(ROOT)!r})
from nspb_qt import known_banners as kb

def make_png(w, h):
    rows = bytearray()
    for _y in range(h):
        rows.append(0)
        rows.extend(b'\\x20\\x80\\xc0' * w)
    def ch(t, p):
        return struct.pack('>I', len(p)) + t + p + struct.pack('>I', zlib.crc32(t + p) & 0xFFFFFFFF)
    ihdr = struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)
    return b'\\x89PNG\\r\\n\\x1a\\n' + ch(b'IHDR', ihdr) + ch(b'IDAT', zlib.compress(bytes(rows))) + ch(b'IEND', b'')

# Minimal valid JPEG SOF0 header for 1920x1080
fake_jpg = b'\\xff\\xd8\\xff\\xc0' + struct.pack('>HBHH', 11, 8, 1080, 1920) + b'\\x01\\x01\\x11\\x00\\xff\\xd9'
assert kb.image_dimensions(fake_jpg) == (1920, 1080)
assert kb.is_valid_landscape_image_bytes(fake_jpg)

# Minimal valid WebP VP8X header for 1920x1080
vp8x = b'RIFF' + struct.pack('<I', 22) + b'WEBP' + b'VP8X' + struct.pack('<I', 10) + b'\\x00\\x00\\x00\\x00' + (1919).to_bytes(3, 'little') + (1079).to_bytes(3, 'little')
assert kb.image_dimensions(vp8x) == (1920, 1080)
assert kb.is_valid_landscape_image_bytes(vp8x)

# Portrait PNG rejected
portrait = make_png(40, 80)
assert kb.image_dimensions(portrait) == (40, 80)
assert not kb.is_valid_landscape_image_bytes(portrait)

class _Resp:
    def __init__(self, body, url, status=200):
        self._body = body
        self._url = url
        self.status = status
    def geturl(self):
        return self._url
    def read(self, n=-1):
        out = self._body
        self._body = b''
        return out
    def __enter__(self):
        return self
    def __exit__(self, *_a):
        return False

tid = '0400FACE56780000'
asset = 'https://assets.nintendo.com/image/upload/q_auto/f_auto/store/software/switch2/70010000125145/60f801a1'
html = ('<script id="__NEXT_DATA__">' + json.dumps({{'props': {{'pageProps': {{'linkedData': {{'image': asset}}}}}}}}) + '</script>').encode('utf-8')
wide = make_png(160, 90)

def opener(req, timeout=8):
    u = req.full_url
    if u.endswith('/US'):
        return _Resp(html, 'https://www.nintendo.com/us/store/products/demo/')
    if u == asset:
        return _Resp(wide, asset)
    return _Resp(b'', u, status=404)

with tempfile.TemporaryDirectory() as td:
    saved = kb.ensure_cached_banner(tid, td, opener=opener)
    assert saved is not None and Path(saved).is_file(), saved
print('OK_NO_PYSIDE6')
"""
        with tempfile.TemporaryDirectory() as td:
            script_path = Path(td) / 'verify_store_no_pyside6.py'
            script_path.write_text(script, encoding='utf-8')
            r = subprocess.run([sys.executable, str(script_path)], capture_output=True, text=True, check=False)
            self.assertEqual(r.returncode, 0, f'stdout={r.stdout}\nstderr={r.stderr}')
            self.assertIn('OK_NO_PYSIDE6', r.stdout)


if __name__ == '__main__':
    unittest.main()
