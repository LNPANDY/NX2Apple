"""Unit tests for Mac Swift parity features in the Windows/Qt front end:
KeyCheck (AES-128-XTS NCA header verification), CheatFiles, GameLibrary,
BuildFolder (FreeSpace), GameDeletion, DriveCopy, Diagnostics, and the 3-page UI.
"""
from __future__ import annotations

import os
import struct
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'frontend-qt'))
os.environ.setdefault('QT_QPA_PLATFORM', 'offscreen')

from nspb_qt import features as feat
from nspb_qt import library as lib
from nspb_qt.i18n import Lang


def _encrypt_nca_sector(plain: bytes, sector: int, key1: bytes, key2: bytes) -> bytes:
    """Encrypt a 0x200-byte sector with Nintendo Switch AES-128-XTS to build real PFS0/NCA test fixtures."""
    rk1 = feat._expand_key_128(key1)
    rk2 = feat._expand_key_128(key2)
    tweak = list(feat._aes128_encrypt_block(sector.to_bytes(16, 'big'), rk2))
    out = bytearray(len(plain))
    for off in range(0, len(plain), 16):
        xored = bytes(plain[off + i] ^ tweak[i] for i in range(16))
        enc = feat._aes128_encrypt_block(xored, rk1)
        for i in range(16):
            out[off + i] = enc[i] ^ tweak[i]
        carry = 0
        for i in range(16):
            nxt = (tweak[i] >> 7) & 1
            tweak[i] = ((tweak[i] << 1) | carry) & 0xFF
            carry = nxt
        if carry:
            tweak[0] ^= 0x87
    return bytes(out)


def _make_pfs0_nsp(path: Path, header_key: bytes, key_gen: int = 0x0E, with_ticket: bool = False) -> None:
    """Build a valid PFS0 (.nsp) containing a 0x400-byte NCA3 header encrypted with AES-128-XTS."""
    plain_sector1 = bytearray(0x200)
    plain_sector1[0:4] = b'NCA3'
    plain_sector1[0x06] = 2
    plain_sector1[0x07] = 0  # application key area
    plain_sector1[0x20] = key_gen
    if with_ticket:
        plain_sector1[0x30:0x40] = b'\x01' * 16  # non-zero rights ID

    enc_sector1 = _encrypt_nca_sector(bytes(plain_sector1), 1, header_key[:16], header_key[16:32])
    nca_data = (b'\x00' * 0x200) + enc_sector1

    files: list[tuple[str, bytes]] = [('0000000000000001.nca', nca_data)]
    if with_ticket:
        tik = bytearray(0x2A0)
        tik[0x285] = key_gen
        files.append(('01007ef00011e000.tik', bytes(tik)))

    str_tab = bytearray()
    entries = bytearray()
    data_blob = bytearray()
    for name, content in files:
        soff = len(str_tab)
        str_tab.extend(name.encode('utf-8') + b'\x00')
        entries.extend(struct.pack('<QQII', len(data_blob), len(content), soff, 0))
        data_blob.extend(content)
    while len(str_tab) % 16 != 0:
        str_tab.append(0)

    head = b'PFS0' + struct.pack('<III', len(files), len(str_tab), 0)
    path.write_bytes(head + bytes(entries) + bytes(str_tab) + bytes(data_blob))


class KeyCheckTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.hk = bytes.fromhex('000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f')

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def test_valid_keys_fit_encrypted_nsp(self) -> None:
        nsp = self.dir / 'Game [01007EF00011E000].nsp'
        _make_pfs0_nsp(nsp, self.hk, key_gen=0x0E)  # 0x0E -> gen index 0x0D (13)
        keys = self.dir / 'prod.keys'
        keys.write_text(
            f'header_key = {self.hk.hex()}\n'
            f'master_key_0d = {"aa" * 16}\n',
            encoding='utf-8',
        )
        v = feat.KeyCheck.check(str(keys), str(nsp))
        self.assertEqual(v.kind, 'fits')

    def test_wrong_header_key_is_caught(self) -> None:
        nsp = self.dir / 'Game [01007EF00011E000].nsp'
        _make_pfs0_nsp(nsp, self.hk, key_gen=0x0E)
        keys = self.dir / 'prod.keys'
        keys.write_text(
            f'header_key = {"ff" * 32}\n'
            f'master_key_0d = {"aa" * 16}\n',
            encoding='utf-8',
        )
        v = feat.KeyCheck.check(str(keys), str(nsp))
        self.assertEqual(v.kind, 'wrongHeaderKey')
        self.assertEqual(v.part, 'base')

    def test_missing_newer_generation_key_reports_firmware(self) -> None:
        nsp = self.dir / 'Game [01007EF00011E000].nsp'
        _make_pfs0_nsp(nsp, self.hk, key_gen=0x14, with_ticket=True)  # 0x14 -> gen 0x13 (19.0.0)
        keys = self.dir / 'prod.keys'
        keys.write_text(
            f'header_key = {self.hk.hex()}\n'
            f'master_key_00 = {"aa" * 16}\n',
            encoding='utf-8',
        )
        v = feat.KeyCheck.check(str(keys), str(nsp))
        self.assertEqual(v.kind, 'missingKey')
        self.assertEqual(v.key, 'master_key_13')
        self.assertEqual(v.firmware, '19.0.0')


class CheatFilesTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def test_parse_and_toggle_cheats(self) -> None:
        bid = '0123456789ABCDEF'
        txt = self.dir / f'{bid}.txt'
        txt.write_text(
            '{Master Code}\n04000000 00112233 44556677\n\n'
            '[60 FPS]\n04000000 00AABBCC 00000001\n\n'
            '[Broken Cheat]\nNOT_HEX 123\n',
            encoding='utf-8',
        )
        master_on, files = feat.CheatFiles.load_folder(str(self.dir), '01007EF00011E000')
        self.assertTrue(master_on)
        self.assertEqual(len(files), 1)
        cheats = files[0].cheats
        self.assertEqual(len(cheats), 3)
        self.assertTrue(cheats[0].is_master and cheats[0].is_valid)
        self.assertTrue(cheats[1].is_valid and cheats[1].runs_once)
        self.assertFalse(cheats[2].is_valid)

        feat.CheatFiles.set_cheat_enabled(str(self.dir), bid, '60 FPS', True)
        _, files2 = feat.CheatFiles.load_folder(str(self.dir), '01007EF00011E000')
        self.assertIn('60 FPS', files2[0].enabled)

        feat.CheatFiles.set_master(str(self.dir), '01007EF00011E000', False)
        master_on2, _ = feat.CheatFiles.load_folder(str(self.dir), '01007EF00011E000')
        self.assertFalse(master_on2)

    def test_read_build_id_from_ipa(self) -> None:
        ipa = self.dir / 'test.ipa'
        with zipfile.ZipFile(ipa, 'w') as zf:
            zf.writestr('Payload/Game.app/main.fixups.tsv', '# BUILD_ID\tabcdef01234567890000\n')
        bid = feat.CheatFiles.read_build_id(ipa_path=str(ipa))
        self.assertEqual(bid, 'ABCDEF0123456789')


class LibraryAndSpaceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def test_discover_games_and_free_space(self) -> None:
        games_dir = self.dir / 'games_root'
        sub = games_dir / 'Celeste'
        sub.mkdir(parents=True)
        (sub / 'Celeste [0100F7B00BB5C000].nsp').write_bytes(b'1234')
        (sub / 'Celeste Update [0100F7B00BB5C800][v65536].nsp').write_bytes(b'5678')
        (games_dir / 'prod.keys').write_text('header_key = ' + '00' * 32, encoding='utf-8')

        library = lib.GameLibrary(state_dir=self.dir / 'state')
        library.set_games_folder(str(games_dir))
        self.assertEqual(len(library.games), 1)
        g = library.games[0]
        self.assertEqual(g.title_id, '0100F7B00BB5C000')
        self.assertTrue(g.has_inputs)

        # Create a build folder with freeable parts and a kept save
        bf = Path(g.work_dir)
        (bf / g.title_id).mkdir(parents=True)
        (bf / g.title_id / 'data.bin').write_bytes(b'x' * 4096)
        (bf / 'shaders').mkdir(parents=True)
        (bf / 'shaders' / 'lib.metallib').write_bytes(b'y' * 2048)
        (bf / 'run').mkdir(parents=True)
        (bf / 'run' / 'save.dat').write_bytes(b's' * 512)

        rep = lib.BuildFolder.inspect(str(bf), g.title_id)
        parts = {it.part: it.bytes for it in rep.items}
        self.assertEqual(parts.get('extracted'), 4096)
        self.assertEqual(parts.get('shaders'), 2048)
        self.assertEqual(rep.kept_bytes, 512)

        freed, failed = lib.BuildFolder.remove(rep, {'extracted'})
        self.assertEqual(freed, 4096)
        self.assertEqual(failed, [])
        self.assertTrue((bf / 'run' / 'save.dat').is_file())

    def test_switch2_fallback_banners(self) -> None:
        import json
        from unittest import mock

        self.assertEqual(len(lib.ArtworkStore.FALLBACK_BANNERS), 8)
        self.assertIn('0400486024DEC000', lib.ArtworkStore.FALLBACK_BANNERS)

        updated: list[str] = []
        store = lib.ArtworkStore(state_dir=self.dir / 'art_state', on_updated=updated.append)
        store.banners_dir.mkdir(parents=True, exist_ok=True)
        (store.banners_dir / 'banners_index.json').write_text(
            json.dumps({'040074A01BF12000': 'https://img-eshop.cdn.nintendo.net/i/bananza.jpg'}),
            encoding='utf-8',
        )

        png_payload = b'\x89PNG\r\n\x1a\n' + b'P' * 2048
        jpg_payload = b'\xff\xd8\xff\xe0' + b'J' * 2048
        requested_urls: list[str] = []

        class _FakeResp:
            def __init__(self, data: bytes) -> None:
                self._data = data
            def read(self) -> bytes:
                return self._data
            def __enter__(self) -> _FakeResp:
                return self
            def __exit__(self, *args: object) -> None:
                pass

        def fake_urlopen(req, timeout=15):
            url = req.full_url if hasattr(req, 'full_url') else str(req)
            requested_urls.append(url)
            return _FakeResp(png_payload if url.endswith('.png') else jpg_payload)

        with mock.patch('urllib.request.urlopen', side_effect=fake_urlopen):
            store._fetch_one('0400486024DEC000')
            store._fetch_one('040074A01BF12000')

        self.assertEqual(
            requested_urls,
            [
                lib.ArtworkStore.FALLBACK_BANNERS['0400486024DEC000'],
                'https://img-eshop.cdn.nintendo.net/i/bananza.jpg',
            ],
        )
        self.assertEqual(updated, ['0400486024DEC000', '040074A01BF12000'])
        self.assertEqual(
            store.image_path('0400486024DEC000'),
            str(store.banners_dir / '0400486024DEC000.png'),
        )
        self.assertEqual(
            store.image_path('040074A01BF12000'),
            str(store.banners_dir / '040074A01BF12000.jpg'),
        )


class ParityWindowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        try:
            from PySide6.QtWidgets import QApplication
        except ImportError as e:
            raise unittest.SkipTest(f'PySide6 not installed: {e}')
        cls.app = QApplication.instance() or QApplication([])

    def _delete(self, m, w) -> None:
        from PySide6.QtCore import QEvent
        w.close()
        w.deleteLater()
        m.deleteLater()
        self.app.sendPostedEvents(None, QEvent.DeferredDelete)
        self.app.processEvents()

    def test_three_page_navigation_and_controls(self) -> None:
        from unittest import mock
        from nspb_qt.model import Model
        from nspb_qt.ui import MainWindow

        p = mock.patch.object(Model, 'check_deps', lambda self: None)
        p.start()
        self.addCleanup(p.stop)
        m = Model()
        m.lang = Lang('en')
        w = MainWindow(m)
        self.addCleanup(self._delete, m, w)
        w.resize(1080, 760)
        w.show()
        self.app.processEvents()

        # Navigate across Library, Builds, Settings
        w._switch_page('library')
        self.assertEqual(w._current_page, 'library')
        w._switch_page('settings')
        self.assertEqual(w._current_page, 'settings')
        w._switch_page('builds')
        self.assertEqual(w._current_page, 'builds')

        # Toggle BC texture decode and One-Game IPA mode
        w.bc_switch.setChecked(True)
        w._on_bc_toggled(True)
        self.assertTrue(m.bc_on_cpu)

        w._on_ipa_kind_changed('oneGame')
        self.assertEqual(m.ipa_kind, 'oneGame')
        self.assertTrue(w.step3_container.isHidden())

        w._on_ipa_kind_changed('shared')
        self.assertEqual(m.ipa_kind, 'shared')
        self.assertFalse(w.step3_container.isHidden())
        self.assertTrue(w.lang_btn.isHidden())

        w.close()

    def test_ios26_sdk_compat_headers_in_common_flags(self) -> None:
        from nspb_qt.win import build_app
        flags = build_app.common_flags(Path('/fake/sdk'), [Path('/fake/inc')], '26.0')
        self.assertIn(f'-I{build_app.SDK_COMPAT}', flags)
        self.assertTrue((build_app.SDK_COMPAT / 'MetalFX' / 'MetalFX.h').is_file())
        self.assertTrue((build_app.SDK_COMPAT / 'CoreMotion' / 'CoreMotion.h').is_file())

    def test_ten_point_ui_and_ux_refinements(self) -> None:
        from unittest import mock
        from PySide6.QtCore import Qt
        from nspb_qt.model import Model
        from nspb_qt.ui import MainWindow

        p = mock.patch.object(Model, 'check_deps', lambda self: None)
        p.start()
        self.addCleanup(p.stop)

        with tempfile.TemporaryDirectory() as td:
            td_path = Path(td)
            m = Model()
            m.lang = Lang('zh')
            w = MainWindow(m)
            self.addCleanup(self._delete, m, w)
            w.resize(1120, 780)
            w.show()
            self.app.processEvents()

            # 1. Center navigation stays pinned at horizontal center across page switches
            centers = []
            for page_id in ('library', 'builds', 'settings'):
                w._switch_page(page_id)
                self.app.processEvents()
                nav_center = w.top_bar.nav_container.geometry().center().x()
                bar_center = w.top_bar.width() // 2
                self.assertLessEqual(abs(nav_center - bar_center), 2)
                centers.append(nav_center)
            self.assertEqual(len(set(centers)), 1, f'nav center jumped across pages: {centers}')

            # 2 & 3. Frameless window + built-in Min/Max/Close + synced AppIcon
            self.assertTrue(bool(w.windowFlags() & Qt.FramelessWindowHint))
            self.assertFalse(w.min_win_btn.isHidden())
            self.assertFalse(w.max_win_btn.isHidden())
            self.assertFalse(w.close_win_btn.isHidden())
            assets_dir = Path(ROOT / 'frontend-qt' / 'nspb_qt' / 'assets')
            self.assertTrue((assets_dir / 'app_icon.png').is_file())
            self.assertTrue((assets_dir / 'app_icon.ico').is_file())
            self.assertFalse(w.windowIcon().isNull())

            # 4. Shell cache setting row in Settings -> Build Tools
            self.assertEqual(w.cache_title_lbl.text(), '缓存文件')
            new_cache_parent = td_path / 'custom_cache_parent'
            new_cache_parent.mkdir()
            ok_move, _ = m.move_shell_cache(str(new_cache_parent))
            self.assertTrue(ok_move)
            self.assertFalse(m.shell_cache_is_default)
            self.assertEqual(Path(m.shell_cache_path).resolve(), (new_cache_parent / 'shell').resolve())
            ok_reset, _ = m.reset_shell_cache_default()
            self.assertTrue(ok_reset)
            self.assertTrue(m.shell_cache_is_default)

            # 5 & 7. Segmented control non-overlapping segments with gap >= 5px
            rects = w.ipa_kind_seg._segment_rects()
            self.assertEqual(len(rects), 2)
            r0, r1 = rects[0][2], rects[1][2]
            self.assertGreaterEqual(r1.left() - r0.right(), 5.0)

            # 6. Step 1 & Step 3 reveal buttons + Copy game data button enabled when archive exists,
            # while redundant buttons on the Start Build row stay hidden
            fake_ipa = td_path / '0100E65002BB8000.ipa'
            fake_ipa.write_bytes(b'PK\x03\x04')
            fake_romfs = td_path / 'romfs'
            fake_romfs.mkdir()
            (fake_romfs / 'romfs.img').write_bytes(b'DMROMFS1')
            m.ipa_path = str(fake_ipa)
            m.archive_path = str(fake_romfs)
            w._switch_page('builds')
            w._refresh_install_card()
            w._on_finished(True, '')
            self.assertFalse(w.step1_reveal_btn.isHidden())
            self.assertFalse(w.step3_open_romfs_btn.isHidden())
            self.assertTrue(w.drive_copy_btn.isEnabled())
            self.assertTrue(w.reveal_ipa_btn.isHidden())
            self.assertTrue(w.reveal_arc_btn.isHidden())

            # 6b. pu.reveal exists and opens file/folder without raising AttributeError
            from nspb_qt import platform_util as pu
            from unittest.mock import patch
            self.assertTrue(hasattr(pu, 'reveal') and callable(pu.reveal))
            with patch('subprocess.Popen') as mock_popen:
                self.assertTrue(pu.reveal(str(fake_ipa)))
                self.assertTrue(pu.reveal(str(fake_romfs)))
                self.assertFalse(pu.reveal(''))

            # 6c. Thin 6px activity progress bar hides percentage text so digits are not clipped
            self.assertFalse(w.act_progress.isTextVisible())

            # 6d. sdk_fetch._win_path and mp_worker multi-process helpers work
            from nspb_qt.win import sdk_fetch, mp_worker
            self.assertTrue(callable(sdk_fetch._win_path))
            img_tmp = td_path / 'test_x18.bin'
            img_tmp.write_bytes(b'\xe0\x03\x12\xaa' * 16)
            mp_worker.init_x18(str(img_tmp))
            try:
                self.assertEqual(len(mp_worker.run_x18_job((0, 64))), 16)
            finally:
                mp_worker._close_mmap()

            # 8. Stage completion marks running stage 'done' (green) instead of staying 'running' (orange)
            m.stages.clear()
            m._on_line('[17:20:01] [6/7] app build')
            self.assertEqual(m.stages[-1].state, 'running')
            m._on_line('[17:20:15] [6/7] app build ✓ (14.0s)')
            self.assertEqual(m.stages[-1].state, 'done')

            # 9. HeroBannerWidget has no 410px max-height cap, and library_page is hosted inside scroll
            self.assertGreater(w.hero.maximumHeight(), 2000)
            self.assertTrue(w.scroll.widget().isAncestorOf(w.library_page))

            # 10. Windows terminology replaces "访达" and "此 Mac"
            self.assertEqual(m.t('install.reveal'), '在文件夹中显示')
            self.assertEqual(m.t('shell.showInFinder'), '在文件夹中显示')
            self.assertIn('此电脑', m.t('shell.copyExternalNote'))
            self.assertNotIn('访达', m.t('shell.showInFinder'))
            m.lang = Lang('en')
            self.assertEqual(m.t('install.reveal'), 'Show in folder')
            self.assertIn('this PC', m.t('shell.copyExternalNote'))


if __name__ == '__main__':
    unittest.main()
