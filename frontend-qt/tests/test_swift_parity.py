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


def _make_arm64_macho(
    filetype: int,
    exported_syms: tuple[str, ...] | None = None,
    undef_syms: tuple[str, ...] = (),
) -> bytes:
    """Build a minimal 64-bit arm64 Mach-O with __TEXT, __LINKEDIT, LC_SYMTAB, and LC_CODE_SIGNATURE."""
    from nspb_qt.win import build_app, macho_sign, toolchain as tc

    if exported_syms is None:
        exported_syms = build_app.REQUIRED_DYLIB_SYMBOLS
    strtab = bytearray(b'\x00')
    nlists = bytearray()
    for sym in exported_syms:
        strx = len(strtab)
        strtab.extend(sym.encode('utf-8') + b'\x00')
        # N_SECT (0x0e) | N_EXT (0x01) = 0x0f
        nlists.extend(struct.pack('<IBBHQ', strx, 0x0F, 1, 0, 0x100))
    for sym in undef_syms:
        strx = len(strtab)
        strtab.extend(sym.encode('utf-8') + b'\x00')
        # N_UNDF (0x00) | N_EXT (0x01) = 0x01
        nlists.extend(struct.pack('<IBBHQ', strx, 0x01, 0, 0, 0))
    while len(strtab) % 8:
        strtab.append(0)

    symoff = 0x800
    stroff = symoff + len(nlists)
    nsyms = len(exported_syms) + len(undef_syms)

    ncmds = 4
    text_cmd = struct.pack(
        '<II16sQQQQiiII',
        macho_sign.LC_SEGMENT_64, 72, b'__TEXT'.ljust(16, b'\x00'),
        0, 0x1000, 0, 0x1000, 5, 5, 0, 0,
    )
    linkedit_cmd = struct.pack(
        '<II16sQQQQiiII',
        macho_sign.LC_SEGMENT_64, 72, b'__LINKEDIT'.ljust(16, b'\x00'),
        0x1000, 0x4000, 0x1000, 0, 1, 1, 0, 0,
    )
    symtab_cmd = struct.pack('<IIIIII', 0x2, 24, symoff, nsyms, stroff, len(strtab))
    sig_cmd = struct.pack('<IIII', macho_sign.LC_CODE_SIGNATURE, 16, 0x1000, 0)
    loads = text_cmd + linkedit_cmd + symtab_cmd + sig_cmd
    hdr = struct.pack(
        '<IIIIIIII',
        tc.MACHO_MAGIC_64, tc.CPU_TYPE_ARM64, 0, filetype, ncmds, len(loads), 0, 0,
    )
    buf = bytearray((hdr + loads).ljust(0x1000, b'\x00'))
    buf[symoff:symoff + len(nlists)] = nlists
    buf[stroff:stroff + len(strtab)] = strtab
    return bytes(buf)


def _ensure_model_mod():
    """Import nspb_qt.model even on headless CI runners without PySide6 installed."""
    injected = False
    try:
        import PySide6.QtCore  # noqa: F401
        from PySide6.QtWidgets import QApplication
        if QApplication.instance() is None:
            QApplication([])
    except ImportError:
        import types

        injected = True
        qt_pkg = types.ModuleType('PySide6')
        qt_core = types.ModuleType('PySide6.QtCore')

        class _BoundSignal:
            def __init__(self) -> None:
                self._cbs: list = []

            def connect(self, cb) -> None:
                self._cbs.append(cb)

            def emit(self, *args) -> None:
                for cb in list(self._cbs):
                    cb(*args)

        class Signal:
            def __init__(self, *_a) -> None:
                self._name = ''

            def __set_name__(self, _owner, name: str) -> None:
                self._name = f'_sig_{name}'

            def __get__(self, inst, owner=None):
                if inst is None:
                    return self
                sig = getattr(inst, self._name, None)
                if sig is None:
                    sig = _BoundSignal()
                    setattr(inst, self._name, sig)
                return sig

        def Slot(*_a, **_kw):
            def _dec(fn):
                return fn
            return _dec

        class QObject:
            def __init__(self, *_a, **_kw) -> None:
                pass

            def thread(self):
                return None

            def deleteLater(self) -> None:
                pass

        class QThread:
            @staticmethod
            def currentThread():
                return None

        class Qt:
            QueuedConnection = 1

        class QMetaObject:
            @staticmethod
            def invokeMethod(obj, name: str, *_a) -> None:
                fn = getattr(obj, name, None)
                if callable(fn):
                    fn()

        class QSettings:
            IniFormat = 1

            def __init__(self, *_a, **_kw) -> None:
                self._store: dict[str, object] = {}

            def value(self, k: str, default=None, defaultValue=None, **_kw):
                fb = defaultValue if defaultValue is not None else default
                return self._store.get(k, fb)

            def setValue(self, k: str, v) -> None:
                self._store[k] = v

            def remove(self, k: str) -> None:
                self._store.pop(k, None)

        qt_core.QObject = QObject
        qt_core.Signal = Signal
        qt_core.Slot = Slot
        qt_core.Q_ARG = lambda *_a: None
        qt_core.QThread = QThread
        qt_core.Qt = Qt
        qt_core.QMetaObject = QMetaObject
        qt_core.QSettings = QSettings
        qt_pkg.QtCore = qt_core
        sys.modules['PySide6'] = qt_pkg
        sys.modules['PySide6.QtCore'] = qt_core

    from nspb_qt import model as model_mod
    return model_mod, injected


class SharedShellParityTests(unittest.TestCase):
    """Headless tests for the Windows shared-shell pipeline that run on every CI OS without PySide6."""

    def setUp(self) -> None:
        from unittest import mock

        self._model_mod, self._injected_qt_stub = _ensure_model_mod()
        self._state_tmp = tempfile.TemporaryDirectory()
        state_dir = Path(self._state_tmp.name) / 'state'
        self._p_state = mock.patch.object(lib, 'default_state_dir', return_value=state_dir)
        self._p_state.start()

        class _DictSettings:
            def __init__(self, *_a, **_kw) -> None:
                self._d: dict[str, object] = {}

            def value(self, k: str, default=None, defaultValue=None, **_kw):
                fb = defaultValue if defaultValue is not None else default
                return self._d.get(k, fb)

            def setValue(self, k: str, v) -> None:
                self._d[k] = v

            def remove(self, k: str) -> None:
                self._d.pop(k, None)

        self._p_qsettings = mock.patch.object(self._model_mod, 'QSettings', side_effect=_DictSettings)
        self._p_qsettings.start()

    def tearDown(self) -> None:
        self._p_qsettings.stop()
        self._p_state.stop()
        self._state_tmp.cleanup()
        if self._injected_qt_stub:
            import nspb_qt
            sys.modules.pop('nspb_qt.model', None)
            sys.modules.pop('PySide6.QtCore', None)
            sys.modules.pop('PySide6', None)
            if hasattr(nspb_qt, 'model'):
                delattr(nspb_qt, 'model')

    def test_shared_mode_two_games_same_out_dir_packaged_win_and_sidecar_cleanup(self) -> None:
        """Build two different games into one shared out_dir under a simulated packaged Windows launcher,
        verify per-game archives at <out>/games/<TID>, reopen each game to send its data, and verify no .idx/.tmp leaks.
        """
        import importlib.util
        import json
        import plistlib
        import subprocess
        import time
        from unittest import mock
        from nspb_qt.win import build_app, macho_sign, shell_export, toolchain as tc

        model_mod = self._model_mod
        Model = model_mod.Model

        eng = Path(os.environ.get('NSPB_ENGINE_DIR') or (ROOT / 'engine'))
        if not (eng / 'scripts' / 'build_ipa_from_nsp.py').is_file():
            self.skipTest('engine/ is not synced')

        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            # 0. Verify build_app.check_dylib enforces the required exported symbols and rejects __mh_execute_header
            good_dylib = root / 'good.dylib'
            good_dylib.write_bytes(_make_arm64_macho(tc.MH_DYLIB))
            build_app.check_dylib(good_dylib)

            bad_missing = root / 'missing_sym.dylib'
            bad_missing.write_bytes(_make_arm64_macho(tc.MH_DYLIB, exported_syms=build_app.REQUIRED_DYLIB_SYMBOLS[:-1]))
            with self.assertRaises(SystemExit):
                build_app.check_dylib(bad_missing)

            bad_mhexec = root / 'mhexec.dylib'
            bad_mhexec.write_bytes(_make_arm64_macho(tc.MH_DYLIB, undef_syms=('___mh_execute_header',)))
            with self.assertRaises(SystemExit):
                build_app.check_dylib(bad_mhexec)

            # 1. Use the real packaged Windows launcher bundle when NSPB_PACKAGED_BUNDLE_DIR is set, else simulate it
            real_bundle = os.environ.get('NSPB_PACKAGED_BUNDLE_DIR')
            if real_bundle:
                bundle_dir = Path(real_bundle)
                tpl = bundle_dir / 'shell_template' / 'DmShell.app'
                self.assertTrue((tpl / 'DmShell').is_file(), f'packaged DmShell missing at {tpl}')
            else:
                bundle_dir = root / 'dist' / 'NX2Apple' / '_internal'
                tpl = bundle_dir / 'shell_template' / 'DmShell.app'
                tpl.mkdir(parents=True)
                (tpl / 'DmShell').write_bytes(_make_arm64_macho(tc.MH_EXECUTE))
                with open(tpl / 'Info.plist', 'wb') as f:
                    plistlib.dump({'CFBundleExecutable': 'DmShell', 'CFBundleIdentifier': 'org.nxnative.shell'}, f)

            fake_windir = root / 'Windows'
            fonts_dir = fake_windir / 'Fonts'
            fonts_dir.mkdir(parents=True)
            std_font = fonts_dir / 'arial.ttf'
            std_font.write_bytes(b'WIN_ARIAL_TTF_BYTES')
            letter_font = fonts_dir / 'arialbd.ttf'
            letter_font.write_bytes(b'WIN_ARIALBD_TTF_BYTES')

            p = mock.patch.object(Model, 'check_deps', lambda self: None)
            p.start()
            self.addCleanup(p.stop)

            m = Model()
            m.repo_path = str(eng if real_bundle else ROOT)
            m.python_path = sys.executable
            m.deps_checked = True
            m.deps = [model_mod.Dep('python', 'dep.python', 'dep.python.hint', model_mod.DepState.OK)]

            tid1 = '010015100B514000'
            tid2 = '01007EF00011E000'
            # Game 1 has a bracketed Title ID in the filename, Game 2 has no Title ID in the filename
            base1 = root / 'inputs1' / f'Super Mario Bros. Wonder [{tid1}][v0].nsp'
            base1.parent.mkdir(parents=True)
            base1.write_bytes(b'game1')
            base2 = root / 'inputs2' / 'The Legend of Zelda Breath of the Wild.nsp'
            base2.parent.mkdir(parents=True)
            base2.write_bytes(b'game2')
            keys_f = root / 'prod.keys'
            keys_f.write_bytes(b'keys')

            shared_out = root / 'shared_out'
            shared_out.mkdir()
            shell_root = root / 'shell_cache'
            m.settings.setValue('shellRoot', str(shell_root))
            m.keys_path = str(keys_f)
            m.out_dir = str(shared_out)
            m.ipa_kind = 'shared'

            real_popen = model_mod.subprocess.Popen
            seen_cmds: list[tuple[list[str], dict[str, str]]] = []
            current_build = {'tid': tid1, 'name': 'Super Mario Bros. Wonder', 'romfs': b'ROMFS_GAME_ONE_1111', 'aoc': b'AOC_GAME_ONE_1111'}

            class FakePopen:
                def __new__(cls, cmd, **kw):
                    cmd_list = [str(c) for c in cmd]
                    if '--progress' not in cmd_list:
                        return real_popen(cmd, **kw)
                    inst = super().__new__(cls)
                    seen_cmds.append((cmd_list, dict(kw.get('env') or {})))
                    inst.returncode = 0
                    inst.stdout = []
                    if '--shell-framework' in cmd_list:
                        btid = str(current_build['tid'])
                        bname = str(current_build['name'])
                        fw_parent = Path(cmd_list[cmd_list.index('--shell-framework') + 1])
                        fw_dir = fw_parent / f'DmGame{btid}.framework'
                        fw_dir.mkdir(parents=True, exist_ok=True)
                        fw_bin = fw_dir / f'DmGame{btid}'
                        fw_bin.write_bytes(_make_arm64_macho(tc.MH_DYLIB))
                        macho_sign.sign(fw_bin, f'org.nxnative.{btid.lower()}.DmGame', None)
                        (fw_dir / 'game.manifest.json').write_text(json.dumps({
                            'schema': 1,
                            'title_id': btid,
                            'name': bname,
                            'loader': 'FH',
                            'framework': f'DmGame{btid}.framework',
                            'framework_executable': f'DmGame{btid}',
                        }), encoding='utf-8')
                        w_dir = Path(cmd_list[cmd_list.index('--work-dir') + 1])
                        v0 = w_dir / 'extract' / 'v0'
                        v0.mkdir(parents=True, exist_ok=True)
                        (v0 / 'RomFS.img').write_bytes(bytes(current_build['romfs']))
                        aoc_dir = w_dir / 'aoc'
                        aoc_dir.mkdir(parents=True, exist_ok=True)
                        (aoc_dir / '0.img').write_bytes(bytes(current_build['aoc']))
                    return inst

                def wait(self):
                    return 0

            # Verify supports_shell_framework succeeds on case-sensitive filesystems (dm/ios/Shell and dm/ios/framework)
            real_is_dir = Path.is_dir
            with mock.patch.object(
                Path,
                'is_dir',
                autospec=True,
                side_effect=lambda p: False if p.parts[-3:] == ('dm', 'ios', 'shell') else real_is_dir(p),
            ):
                self.assertTrue(m.supports_shell_framework())

            # Verify start_build stops early if DmShell.app template is missing
            missing_outcomes: list[tuple[bool, str]] = []
            m.base_path = str(base1)
            m.finished.connect(lambda ok, msg: missing_outcomes.append((ok, msg)))
            with mock.patch.object(model_mod.subprocess, 'Popen', FakePopen), \
                 mock.patch.object(shell_export, 'find_shell_template', return_value=None):
                m.start_build()
            self.assertEqual(len(seen_cmds), 0)
            self.assertTrue(missing_outcomes and not missing_outcomes[-1][0])

            real_se_run = shell_export.subprocess.run
            ext_font_calls: list[list[str]] = []

            def checked_se_run(cmd, *a, **kw):
                cmd_list = [str(c) for c in cmd]
                if any(c.endswith('make_ext_font.py') for c in cmd_list):
                    ext_font_calls.append(cmd_list)
                    if len(cmd_list) < 4 or Path(cmd_list[3]) != letter_font:
                        return subprocess.CompletedProcess(cmd_list, 1, '', f'bad letter font: {cmd_list}')
                    Path(cmd_list[2]).write_bytes(b'EXT_TTF_BYTES')
                    return subprocess.CompletedProcess(cmd_list, 0, 'ok\n', '')
                return real_se_run(cmd, *a, **kw)

            # 2. Build Game 1 and Game 2 in shared mode into the SAME out_dir under simulated packaged Windows env
            win_env = {
                'WINDIR': str(fake_windir),
                'NSPB_SHELL_TEMPLATE': '',
                'NSPB_STD_FONT': '',
                'NSPB_LETTER_FONT': '',
            }
            outcomes: list[tuple[bool, str]] = []
            m.finished.connect(lambda ok, msg: outcomes.append((ok, msg)))

            def _wait_outcomes() -> None:
                for _ in range(100):
                    try:
                        from PySide6.QtWidgets import QApplication
                        app = QApplication.instance() or QApplication([])
                        app.processEvents()
                    except ImportError:
                        pass
                    if outcomes:
                        break
                    time.sleep(0.05)

            with (
                mock.patch.object(model_mod.subprocess, 'Popen', FakePopen),
                mock.patch.dict(os.environ, win_env, clear=False),
                mock.patch.object(shell_export.pu, 'IS_WIN', True),
                mock.patch.object(shell_export.pu, 'no_window_kwargs', return_value={}),
                mock.patch.object(sys, 'frozen', True, create=True),
                mock.patch.object(sys, '_MEIPASS', str(bundle_dir), create=True),
                mock.patch.object(shell_export.subprocess, 'run', side_effect=checked_se_run),
            ):
                # Build Game 1
                outcomes.clear()
                m.base_path = str(base1)
                m.start_build()
                _wait_outcomes()
                self.assertTrue(outcomes and outcomes[-1][0], f'Game 1 build failed: {outcomes}')

                # Build Game 2 (same out_dir, input filename has NO Title ID, same byte length RomFS/AOC to test content check)
                outcomes.clear()
                current_build = {
                    'tid': tid2,
                    'name': 'Breath of the Wild',
                    'romfs': b'ROMFS_GAME_TWO_2222',
                    'aoc': b'AOC_GAME_TWO_2222',
                }
                m.base_path = str(base2)
                m.start_build()
                _wait_outcomes()
                self.assertTrue(outcomes and outcomes[-1][0], f'Game 2 build failed: {outcomes}')

            self.assertTrue(ext_font_calls, '_prepare_fonts must invoke make_ext_font.py')
            self.assertEqual(Path(ext_font_calls[0][3]), letter_font)

            # Verify both games' archives exist side-by-side under <shared_out>/games/<TID> without overwriting each other
            arch1 = shared_out / 'games' / tid1
            arch2 = shared_out / 'games' / tid2
            self.assertEqual((arch1 / 'romfs.img').read_bytes(), b'ROMFS_GAME_ONE_1111')
            self.assertEqual((arch1 / 'aoc' / '0.img').read_bytes(), b'AOC_GAME_ONE_1111')
            self.assertEqual((arch2 / 'romfs.img').read_bytes(), b'ROMFS_GAME_TWO_2222')
            self.assertEqual((arch2 / 'aoc' / '0.img').read_bytes(), b'AOC_GAME_TWO_2222')

            # Verify library recorded both games under their verified 16-hex Title IDs
            g1 = next((g for g in m.library.games if g.title_id == tid1), None)
            g2 = next((g for g in m.library.games if g.title_id == tid2), None)
            self.assertIsNotNone(g1)
            self.assertIsNotNone(g2)
            assert g1 is not None and g2 is not None
            self.assertEqual(g1.archive_path, str(arch1))
            self.assertEqual(g2.archive_path, str(arch2))
            self.assertEqual(g2.name, 'Breath of the Wild')

            # 3. Reopen the FIRST game entry and send its game data to a staging drive folder
            drive_dir = root / 'drive_staging'
            drive_dir.mkdir()
            m.load_game_from_library(g1)
            self.assertEqual(m.effective_archive_path(), str(arch1))
            self.assertEqual(m.packed_title_id, tid1)
            ok_d1, dest_d1 = m.copy_archive_to_drive(str(drive_dir))
            self.assertTrue(ok_d1, dest_d1)
            self.assertEqual((drive_dir / tid1 / 'romfs.img').read_bytes(), b'ROMFS_GAME_ONE_1111')
            self.assertEqual((drive_dir / tid1 / 'aoc' / '0.img').read_bytes(), b'AOC_GAME_ONE_1111')

            # Reopen the SECOND game entry and send its game data to the same staging drive folder
            m.load_game_from_library(g2)
            self.assertEqual(m.effective_archive_path(), str(arch2))
            self.assertEqual(m.packed_title_id, tid2)
            ok_d2, dest_d2 = m.copy_archive_to_drive(str(drive_dir))
            self.assertTrue(ok_d2, dest_d2)
            self.assertEqual((drive_dir / tid2 / 'romfs.img').read_bytes(), b'ROMFS_GAME_TWO_2222')
            self.assertEqual((drive_dir / tid2 / 'aoc' / '0.img').read_bytes(), b'AOC_GAME_TWO_2222')
            # First game's staged data is still untouched
            self.assertEqual((drive_dir / tid1 / 'romfs.img').read_bytes(), b'ROMFS_GAME_ONE_1111')

            # 4. Verify export/NX2Apple.ipa contains both frameworks and no .tmp or .idx sidecars leaked in export/
            expected_ipa = shell_root / 'export' / 'NX2Apple.ipa'
            self.assertTrue(expected_ipa.is_file())
            export_entries = sorted(p.name for p in expected_ipa.parent.iterdir())
            self.assertEqual(export_entries, ['NX2Apple.ipa'], f'unexpected sidecar files in export/: {export_entries}')

            with zipfile.ZipFile(expected_ipa) as zf:
                names = set(zf.namelist())
                self.assertIn('Payload/DmShell.app/DmShell', names)
                self.assertIn(f'Payload/DmShell.app/Frameworks/DmGame{tid1}.framework/DmGame{tid1}', names)
                self.assertIn(f'Payload/DmShell.app/Frameworks/DmGame{tid2}.framework/DmGame{tid2}', names)
                self.assertEqual(zf.read('Payload/DmShell.app/dm/font/standard.ttf'), b'WIN_ARIAL_TTF_BYTES')
                self.assertEqual(zf.read('Payload/DmShell.app/dm/font/nintendo_ext.ttf'), b'EXT_TTF_BYTES')
                for exec_entry in (
                    'Payload/DmShell.app/DmShell',
                    f'Payload/DmShell.app/Frameworks/DmGame{tid1}.framework/DmGame{tid1}',
                    f'Payload/DmShell.app/Frameworks/DmGame{tid2}.framework/DmGame{tid2}',
                ):
                    mode = (zf.getinfo(exec_entry).external_attr >> 16) & 0o777
                    self.assertEqual(mode, 0o755, f'{exec_entry} mode is {oct(mode)}, expected 0o755')

            # 5. Verify a failed pack_ipa keeps previous NX2Apple.ipa intact and cleans up .tmp + .tmp.idx sidecars
            before_ipa_bytes = expected_ipa.read_bytes()
            fw2_cached = shell_root / 'frameworks' / f'DmGame{tid2}.framework'

            def failing_pack_with_sidecars(cmd, *a, **kw):
                cmd_list = [str(c) for c in cmd]
                if any(c.endswith('pack_ipa.py') for c in cmd_list):
                    tmp_target = Path(cmd_list[2])
                    tmp_target.write_bytes(b'corrupt_partial_zip')
                    Path(f'{tmp_target}.idx').write_text('0\t1\t0\tdeadbeef\tfoo\n', encoding='utf-8')
                    Path(f'{tmp_target}.partial').write_bytes(b'partial')
                    return subprocess.CompletedProcess(cmd_list, 1, '', 'simulated pack_ipa failure')
                return checked_se_run(cmd, *a, **kw)

            with (
                mock.patch.dict(os.environ, win_env, clear=False),
                mock.patch.object(shell_export.pu, 'IS_WIN', True),
                mock.patch.object(shell_export.pu, 'no_window_kwargs', return_value={}),
                mock.patch.object(sys, 'frozen', True, create=True),
                mock.patch.object(sys, '_MEIPASS', str(bundle_dir), create=True),
                mock.patch.object(shell_export.subprocess, 'run', side_effect=failing_pack_with_sidecars),
            ):
                ok_fail, _ipa_fail, _msg_fail, _notes_fail = shell_export.export_shell(
                    root=shell_root,
                    repo=eng,
                    framework=fw2_cached,
                    title_id=tid2,
                    name='Breath of the Wild',
                )
            self.assertFalse(ok_fail)
            self.assertEqual(expected_ipa.read_bytes(), before_ipa_bytes)
            export_entries_after_fail = sorted(p.name for p in expected_ipa.parent.iterdir())
            self.assertEqual(export_entries_after_fail, ['NX2Apple.ipa'])

            # 6. Verify find_shell_template fallback passes --engine and build_shell_template.py accepts it
            spec = importlib.util.spec_from_file_location(
                'build_shell_template', ROOT / 'tools' / 'build_shell_template.py'
            )
            assert spec is not None and spec.loader is not None
            bst = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(bst)
            fb_root = root / 'fb_shell'
            fb_out = fb_root / 'template' / 'DmShell.app'

            def fake_build_template(out_app: Path, engine: Path | None = None) -> Path:
                self.assertEqual(engine, eng)
                out_app.mkdir(parents=True, exist_ok=True)
                (out_app / 'DmShell').write_bytes(_make_arm64_macho(tc.MH_EXECUTE))
                with open(out_app / 'Info.plist', 'wb') as pf:
                    plistlib.dump({'CFBundleExecutable': 'DmShell'}, pf)
                return out_app

            with mock.patch.object(bst, 'build_template', side_effect=fake_build_template):
                rc = bst.main(['--engine', str(eng), '--out', str(fb_out)])
            self.assertEqual(rc, 0)
            self.assertTrue((fb_out / 'DmShell').is_file())


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

    def setUp(self) -> None:
        from unittest import mock
        from PySide6.QtCore import QSettings
        from nspb_qt import library as lib_mod, model as model_mod

        self._state_tmp = tempfile.TemporaryDirectory()
        state_dir = Path(self._state_tmp.name) / 'state'
        ini_file = str(Path(self._state_tmp.name) / 'settings.ini')
        self._p_state = mock.patch.object(lib_mod, 'default_state_dir', return_value=state_dir)
        self._p_qsettings = mock.patch.object(
            model_mod, 'QSettings', side_effect=lambda *a, **kw: QSettings(ini_file, QSettings.IniFormat)
        )
        self._p_state.start()
        self._p_qsettings.start()

    def tearDown(self) -> None:
        self._p_qsettings.stop()
        self._p_state.stop()
        self._state_tmp.cleanup()

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

    def test_reveal_button_tracks_the_mode_with_both_saved_fallbacks(self) -> None:
        from unittest import mock
        from nspb_qt import platform_util as pu
        from nspb_qt.model import Model
        from nspb_qt.ui import MainWindow

        with mock.patch.object(Model, 'check_deps', lambda self: None):
            m = Model()
        root = Path(self._state_tmp.name)
        m.settings.setValue('shellRoot', str(root / 'shell'))
        m.base_path = str(root / 'Game [010063301BD50000].nsp')
        m.out_dir = str(root / 'out')
        shared = root / 'shell' / 'export' / 'NX2Apple.ipa'
        shared.parent.mkdir(parents=True)
        with zipfile.ZipFile(shared, 'w') as ipa:
            ipa.writestr('Payload/DmShell.app/Info.plist', b'fixture')
            ipa.writestr('Payload/DmShell.app/DmShell', b'fixture')
        game = lib.LibraryGame(title_id='010063301BD50000', name='Fixture', ipa_path=str(shared))
        m.library.upsert(game)
        m.library.selected_id = game.title_id
        m.ipa_path = str(shared)
        w = MainWindow(m)
        self.addCleanup(self._delete, m, w)
        revealed = []
        with mock.patch.object(pu, 'reveal', side_effect=revealed.append):
            w._on_ipa_kind_changed('shared')
            self.assertFalse(w.step1_reveal_btn.isHidden())
            w.step1_reveal_btn.click()
            self.assertEqual(revealed, [str(shared)])

            w._on_ipa_kind_changed('oneGame')
            self.assertTrue(w.step1_reveal_btn.isHidden())

            named = root / 'ProfileSuppliedName.ipa'
            with zipfile.ZipFile(named, 'w') as ipa:
                ipa.writestr('Payload/DmIOS.app/Info.plist', b'fixture')
                ipa.writestr('Payload/DmIOS.app/DmIOS', b'fixture')
            m.ipa_path = str(named)
            m.library.selected.ipa_path = str(named)
            w._refresh_install_card()
            self.assertFalse(w.step1_reveal_btn.isHidden())
            w.step1_reveal_btn.click()
            self.assertEqual(revealed, [str(shared), str(named)])

            shared.unlink()
            w._on_ipa_kind_changed('shared')
            self.assertTrue(w.step1_reveal_btn.isHidden())

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
            with zipfile.ZipFile(fake_ipa, 'w') as ipa:
                ipa.writestr('Payload/DmShell.app/Info.plist', b'fixture')
                ipa.writestr('Payload/DmShell.app/DmShell', b'fixture')
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
            import types
            from nspb_qt.win import sdk_fetch
            self.assertTrue(callable(sdk_fetch._win_path))
            injected_cs = False
            try:
                import capstone  # noqa: F401
            except ModuleNotFoundError:
                class _StubCs:
                    def __init__(self, *_a, **_kw) -> None:
                        self.detail = False

                    def disasm_lite(self, buf: bytes, base: int):
                        for off in range(0, len(buf), 4):
                            yield (base + off, 4, 'mov', 'x0, x18')

                cs_mod = types.ModuleType('capstone')
                cs_mod.CS_ARCH_ARM64 = 1
                cs_mod.CS_MODE_ARM = 0
                cs_mod.Cs = _StubCs
                cs_arm64 = types.ModuleType('capstone.arm64')
                cs_arm64.ARM64_OP_IMM = 1
                cs_arm64.ARM64_OP_MEM = 2
                cs_arm64.ARM64_OP_REG = 3
                sys.modules['capstone'] = cs_mod
                sys.modules['capstone.arm64'] = cs_arm64
                injected_cs = True
            try:
                from nspb_qt.win import mp_worker
                img_tmp = td_path / 'test_x18.bin'
                img_tmp.write_bytes(b'\xe0\x03\x12\xaa' * 16)
                mp_worker.init_x18(str(img_tmp))
                try:
                    self.assertEqual(len(mp_worker.run_x18_job((0, 64))), 16)
                finally:
                    mp_worker._close_mmap()
            finally:
                if injected_cs:
                    sys.modules.pop('nspb_qt.win.mp_worker', None)
                    sys.modules.pop('capstone.arm64', None)
                    sys.modules.pop('capstone', None)

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

    def test_shared_mode_builds_framework_and_exports_nx2apple_ipa_with_shell(self) -> None:
        """Verify shared-app mode builds DmGame<ID>.framework and packs Payload/DmShell.app into NX2Apple.ipa."""
        import importlib.util
        import json
        import plistlib
        import struct
        import subprocess
        import time
        import zipfile
        from unittest import mock
        from nspb_qt import model as model_mod
        from nspb_qt.model import Model
        from nspb_qt.win import build_app, macho_sign, shell_export, toolchain as tc

        def make_arm64_macho(
            filetype: int,
            exported_syms: tuple[str, ...] = build_app.REQUIRED_DYLIB_SYMBOLS,
            undef_syms: tuple[str, ...] = (),
        ) -> bytes:
            # Minimal 64-bit arm64 Mach-O with __TEXT, __LINKEDIT, LC_SYMTAB, and LC_CODE_SIGNATURE
            strtab = bytearray(b'\x00')
            nlists = bytearray()
            for sym in exported_syms:
                strx = len(strtab)
                strtab.extend(sym.encode('utf-8') + b'\x00')
                # N_SECT (0x0e) | N_EXT (0x01) = 0x0f
                nlists.extend(struct.pack('<IBBHQ', strx, 0x0F, 1, 0, 0x100))
            for sym in undef_syms:
                strx = len(strtab)
                strtab.extend(sym.encode('utf-8') + b'\x00')
                # N_UNDF (0x00) | N_EXT (0x01) = 0x01
                nlists.extend(struct.pack('<IBBHQ', strx, 0x01, 0, 0, 0))
            while len(strtab) % 8:
                strtab.append(0)

            symoff = 0x800
            stroff = symoff + len(nlists)
            nsyms = len(exported_syms) + len(undef_syms)

            ncmds = 4
            text_cmd = struct.pack(
                '<II16sQQQQiiII',
                macho_sign.LC_SEGMENT_64, 72, b'__TEXT'.ljust(16, b'\x00'),
                0, 0x1000, 0, 0x1000, 5, 5, 0, 0,
            )
            linkedit_cmd = struct.pack(
                '<II16sQQQQiiII',
                macho_sign.LC_SEGMENT_64, 72, b'__LINKEDIT'.ljust(16, b'\x00'),
                0x1000, 0x4000, 0x1000, 0, 1, 1, 0, 0,
            )
            symtab_cmd = struct.pack('<IIIIII', 0x2, 24, symoff, nsyms, stroff, len(strtab))
            sig_cmd = struct.pack('<IIII', macho_sign.LC_CODE_SIGNATURE, 16, 0x1000, 0)
            loads = text_cmd + linkedit_cmd + symtab_cmd + sig_cmd
            hdr = struct.pack(
                '<IIIIIIII',
                tc.MACHO_MAGIC_64, tc.CPU_TYPE_ARM64, 0, filetype, ncmds, len(loads), 0, 0,
            )
            buf = bytearray((hdr + loads).ljust(0x1000, b'\x00'))
            buf[symoff:symoff + len(nlists)] = nlists
            buf[stroff:stroff + len(strtab)] = strtab
            return bytes(buf)

        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            # 0. Verify build_app.check_dylib enforces the required exported symbols and rejects __mh_execute_header
            good_dylib = root / 'good.dylib'
            good_dylib.write_bytes(make_arm64_macho(tc.MH_DYLIB))
            build_app.check_dylib(good_dylib)

            bad_missing = root / 'missing_sym.dylib'
            bad_missing.write_bytes(make_arm64_macho(tc.MH_DYLIB, exported_syms=build_app.REQUIRED_DYLIB_SYMBOLS[:-1]))
            with self.assertRaises(SystemExit):
                build_app.check_dylib(bad_missing)

            bad_mhexec = root / 'mhexec.dylib'
            bad_mhexec.write_bytes(make_arm64_macho(tc.MH_DYLIB, undef_syms=('___mh_execute_header',)))
            with self.assertRaises(SystemExit):
                build_app.check_dylib(bad_mhexec)

            # 1. Create a realistic DmShell.app template
            tpl = root / 'template' / 'DmShell.app'
            tpl.mkdir(parents=True)
            (tpl / 'DmShell').write_bytes(make_arm64_macho(tc.MH_EXECUTE))
            with open(tpl / 'Info.plist', 'wb') as f:
                plistlib.dump({'CFBundleExecutable': 'DmShell', 'CFBundleIdentifier': 'org.nxnative.shell'}, f)

            # 2. Verify start_build passes --shell-framework in shared mode vs -o + DM_FULL_ROMFS=1 in oneGame mode
            eng = ROOT / 'engine'
            if not (eng / 'scripts' / 'build_ipa_from_nsp.py').is_file():
                self.skipTest('engine/ is not synced')

            p = mock.patch.object(Model, 'check_deps', lambda self: None)
            p.start()
            self.addCleanup(p.stop)

            m = Model()
            m.repo_path = str(ROOT)
            m.deps_checked = True
            m.deps = [model_mod.Dep('python', 'dep.python', 'dep.python.hint', model_mod.DepState.OK)]
            tid1 = '010015100B514000'
            tid2 = '01007EF00011E000'
            base_nsp = root / f'Game [{tid1}][v0].nsp'
            base_nsp.write_bytes(b'x')
            keys_f = root / 'prod.keys'
            keys_f.write_bytes(b'x')
            out_dir = root / 'out'
            out_dir.mkdir()
            shell_root = root / 'shell_cache'
            m.settings.setValue('shellRoot', str(shell_root))
            m.base_path = str(base_nsp)
            m.keys_path = str(keys_f)
            m.out_dir = str(out_dir)

            real_popen = model_mod.subprocess.Popen
            seen_cmds: list[tuple[list[str], dict[str, str]]] = []
            cur_game = {'tid': tid1, 'name': 'Super Mario Bros. Wonder', 'romfs': b'DMROMFS1_game1'}

            class FakePopen:
                def __new__(cls, cmd, **kw):
                    cmd_list = [str(c) for c in cmd]
                    if '--progress' not in cmd_list:
                        return real_popen(cmd, **kw)
                    inst = super().__new__(cls)
                    seen_cmds.append((cmd_list, dict(kw.get('env') or {})))
                    inst.returncode = 0
                    inst.stdout = []
                    if '--shell-framework' in cmd_list:
                        btid = str(cur_game['tid'])
                        bname = str(cur_game['name'])
                        fw_parent = Path(cmd_list[cmd_list.index('--shell-framework') + 1])
                        fw_dir = fw_parent / f'DmGame{btid}.framework'
                        fw_dir.mkdir(parents=True, exist_ok=True)
                        fw_bin = fw_dir / f'DmGame{btid}'
                        fw_bin.write_bytes(make_arm64_macho(tc.MH_DYLIB))
                        macho_sign.sign(fw_bin, f'org.nxnative.{btid.lower()}.DmGame', None)
                        (fw_dir / 'game.manifest.json').write_text(json.dumps({
                            'schema': 1,
                            'title_id': btid,
                            'name': bname,
                            'loader': 'FH',
                            'framework': f'DmGame{btid}.framework',
                            'framework_executable': f'DmGame{btid}',
                        }), encoding='utf-8')
                        w_dir = Path(cmd_list[cmd_list.index('--work-dir') + 1])
                        v0 = w_dir / 'extract' / 'v0'
                        v0.mkdir(parents=True, exist_ok=True)
                        (v0 / 'RomFS.img').write_bytes(bytes(cur_game['romfs']))
                    return inst

                def wait(self):
                    return 0

            # Verify start_build checks for DmShell.app template before starting the long build
            m.ipa_kind = 'shared'
            missing_outcomes: list[tuple[bool, str]] = []
            m.finished.connect(lambda ok, msg: missing_outcomes.append((ok, msg)))
            with mock.patch.object(model_mod.subprocess, 'Popen', FakePopen), \
                 mock.patch.object(shell_export, 'find_shell_template', return_value=None):
                m.start_build()
            self.assertEqual(len(seen_cmds), 0, 'build must not start when DmShell.app template is missing')
            self.assertTrue(missing_outcomes and not missing_outcomes[-1][0])

            std_font = root / 'standard.ttf'
            std_font.write_bytes(b'STD_TTF_BYTES')
            letter_font = root / 'letter_bold.ttf'
            letter_font.write_bytes(b'LETTER_TTF_BYTES')
            real_se_run = shell_export.subprocess.run
            ext_font_calls: list[list[str]] = []

            def checked_se_run(cmd, *a, **kw):
                cmd_list = [str(c) for c in cmd]
                if any(c.endswith('make_ext_font.py') for c in cmd_list):
                    ext_font_calls.append(cmd_list)
                    # make_ext_font.py must receive both the output path and the letter font path
                    if len(cmd_list) < 4 or cmd_list[3] != str(letter_font):
                        return subprocess.CompletedProcess(cmd_list, 1, '', 'missing letter font argument')
                    Path(cmd_list[2]).write_bytes(b'EXT_TTF_BYTES')
                    return subprocess.CompletedProcess(cmd_list, 0, 'ok\n', '')
                return real_se_run(cmd, *a, **kw)

            outcomes: list[tuple[bool, str]] = []
            m.finished.connect(lambda ok, msg: outcomes.append((ok, msg)))
            with mock.patch.object(model_mod.subprocess, 'Popen', FakePopen), \
                 mock.patch.dict(os.environ, {
                     'NSPB_SHELL_TEMPLATE': str(tpl),
                     'NSPB_STD_FONT': str(std_font),
                     'NSPB_LETTER_FONT': str(letter_font),
                 }, clear=False), \
                 mock.patch.object(shell_export.subprocess, 'run', side_effect=checked_se_run):
                outcomes.clear()
                m.start_build()
                for _ in range(100):
                    self.app.processEvents()
                    if outcomes:
                        break
                    time.sleep(0.05)

            self.assertTrue(ext_font_calls, '_prepare_fonts must invoke make_ext_font.py')
            self.assertEqual(ext_font_calls[0][3], str(letter_font))

            build_cmds = [(c, e) for c, e in seen_cmds if '--progress' in c]
            self.assertEqual(len(build_cmds), 1)
            shared_cmd, shared_env = build_cmds[0]
            self.assertIn('--shell-framework', shared_cmd)
            self.assertNotIn('-o', shared_cmd)
            self.assertNotIn('DM_FULL_ROMFS', shared_env)

            expected_ipa = shell_root / 'export' / 'NX2Apple.ipa'
            self.assertEqual(Path(m.ipa_path), expected_ipa)
            self.assertTrue(expected_ipa.is_file())
            self.assertTrue((shell_root / 'shell.json').is_file())
            self.assertTrue((shell_root / 'frameworks' / f'DmGame{tid1}.framework' / f'DmGame{tid1}').is_file())

            # 3. Build a second game with the SAME out_dir through Model.start_build and verify MainWindow._copy_archive_to_drive
            base2_nsp = root / 'Breath of the Wild.nsp'
            base2_nsp.write_bytes(b'y')
            cur_game = {'tid': tid2, 'name': 'Breath of the Wild', 'romfs': b'DMROMFS1_game2'}
            m.base_path = str(base2_nsp)
            with mock.patch.object(model_mod.subprocess, 'Popen', FakePopen), \
                 mock.patch.dict(os.environ, {
                     'NSPB_SHELL_TEMPLATE': str(tpl),
                     'NSPB_STD_FONT': str(std_font),
                     'NSPB_LETTER_FONT': str(letter_font),
                 }, clear=False), \
                 mock.patch.object(shell_export.subprocess, 'run', side_effect=checked_se_run):
                outcomes.clear()
                m.start_build()
                for _ in range(100):
                    self.app.processEvents()
                    if outcomes:
                        break
                    time.sleep(0.05)
            self.assertTrue(outcomes and outcomes[-1][0])
            ipa2 = expected_ipa
            fw2_src = shell_root / 'frameworks' / f'DmGame{tid2}.framework'

            from nspb_qt.ui import MainWindow
            w = MainWindow(m)
            self.addCleanup(self._delete, m, w)
            drive_ui = root / 'drive_ui'
            drive_ui.mkdir()
            w._drive_folder = str(drive_ui)
            g1_item = next(g for g in m.library.games if g.title_id == tid1)
            g2_item = next(g for g in m.library.games if g.title_id == tid2)
            m.load_game_from_library(g1_item)
            w._copy_archive_to_drive()
            self.assertEqual((drive_ui / tid1 / 'romfs.img').read_bytes(), b'DMROMFS1_game1')
            m.load_game_from_library(g2_item)
            w._copy_archive_to_drive()
            self.assertEqual((drive_ui / tid2 / 'romfs.img').read_bytes(), b'DMROMFS1_game2')
            self.assertEqual((drive_ui / tid1 / 'romfs.img').read_bytes(), b'DMROMFS1_game1')

            with zipfile.ZipFile(ipa2) as zf:
                names = set(zf.namelist())
                self.assertIn('Payload/DmShell.app/DmShell', names)
                self.assertIn(f'Payload/DmShell.app/Frameworks/DmGame{tid1}.framework/DmGame{tid1}', names)
                self.assertIn(f'Payload/DmShell.app/Frameworks/DmGame{tid2}.framework/DmGame{tid2}', names)
                self.assertIn('Payload/DmShell.app/dm/font/standard.ttf', names)
                self.assertIn('Payload/DmShell.app/dm/font/nintendo_ext.ttf', names)
                self.assertEqual(zf.read('Payload/DmShell.app/dm/font/standard.ttf'), b'STD_TTF_BYTES')
                self.assertEqual(zf.read('Payload/DmShell.app/dm/font/nintendo_ext.ttf'), b'EXT_TTF_BYTES')
                # Verify Unix executable permission bits (0755) on DmShell and both framework binaries
                for exec_entry in (
                    'Payload/DmShell.app/DmShell',
                    f'Payload/DmShell.app/Frameworks/DmGame{tid1}.framework/DmGame{tid1}',
                    f'Payload/DmShell.app/Frameworks/DmGame{tid2}.framework/DmGame{tid2}',
                ):
                    mode = (zf.getinfo(exec_entry).external_attr >> 16) & 0o777
                    self.assertEqual(mode, 0o755, f'{exec_entry} mode is {oct(mode)}, expected 0o755')
                # Verify DmShell carries Increased Memory Limit entitlement while DmGame dylibs carry none
                shell_bytes = zf.read('Payload/DmShell.app/DmShell')
                self.assertIn(b'com.apple.developer.kernel.increased-memory-limit', shell_bytes)
                fw1_bytes = zf.read(f'Payload/DmShell.app/Frameworks/DmGame{tid1}.framework/DmGame{tid1}')
                self.assertNotIn(b'com.apple.developer.kernel.increased-memory-limit', fw1_bytes)

            # 3b. Verify a failed export keeps the previous export/NX2Apple.ipa byte-for-byte intact
            before_ipa_bytes = expected_ipa.read_bytes()

            def failing_pack_run(cmd, *a, **kw):
                cmd_list = [str(c) for c in cmd]
                if any(c.endswith('pack_ipa.py') for c in cmd_list):
                    return subprocess.CompletedProcess(cmd_list, 1, '', 'simulated pack_ipa failure')
                return checked_se_run(cmd, *a, **kw)

            with mock.patch.dict(os.environ, {
                     'NSPB_SHELL_TEMPLATE': str(tpl),
                     'NSPB_STD_FONT': str(std_font),
                     'NSPB_LETTER_FONT': str(letter_font),
                 }, clear=False), \
                 mock.patch.object(shell_export.subprocess, 'run', side_effect=failing_pack_run):
                ok_fail, _ipa_fail, _msg_fail, _notes_fail = shell_export.export_shell(
                    root=shell_root,
                    repo=eng,
                    framework=fw2_src,
                    title_id=tid2,
                    name='Breath of the Wild',
                )
            self.assertFalse(ok_fail)
            self.assertTrue(expected_ipa.is_file(), 'previous NX2Apple.ipa must not be deleted on export failure')
            self.assertEqual(expected_ipa.read_bytes(), before_ipa_bytes)
            leftover_tmps = [p for p in expected_ipa.parent.iterdir() if p.name.endswith('.tmp')]
            self.assertEqual(leftover_tmps, [])

            # 3c. Verify find_shell_template fallback passes --engine and build_shell_template.py accepts it
            spec = importlib.util.spec_from_file_location(
                'build_shell_template', ROOT / 'tools' / 'build_shell_template.py'
            )
            assert spec is not None and spec.loader is not None
            bst = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(bst)
            fb_root = root / 'fb_shell'
            fb_out = fb_root / 'template' / 'DmShell.app'

            def fake_build_template(out_app: Path, engine: Path | None = None) -> Path:
                self.assertEqual(engine, eng)
                out_app.mkdir(parents=True, exist_ok=True)
                (out_app / 'DmShell').write_bytes(make_arm64_macho(tc.MH_EXECUTE))
                with open(out_app / 'Info.plist', 'wb') as pf:
                    plistlib.dump({'CFBundleExecutable': 'DmShell'}, pf)
                return out_app

            with mock.patch.object(bst, 'build_template', side_effect=fake_build_template):
                rc = bst.main(['--engine', str(eng), '--out', str(fb_out)])
            self.assertEqual(rc, 0)
            self.assertTrue((fb_out / 'DmShell').is_file())

            fb_root2 = root / 'fb_shell2'

            def fake_builder_run(cmd, *a, **kw):
                cmd_list = [str(c) for c in cmd]
                if any(c.endswith('build_shell_template.py') for c in cmd_list):
                    with mock.patch.object(bst, 'build_template', side_effect=fake_build_template):
                        code = bst.main(cmd_list[2:])
                    return subprocess.CompletedProcess(cmd_list, code, 'built\n', '')
                return real_se_run(cmd, *a, **kw)

            with mock.patch.dict(os.environ, {'NSPB_SHELL_TEMPLATE': ''}, clear=False), \
                 mock.patch.object(shell_export.pu, 'IS_WIN', False), \
                 mock.patch.object(shell_export.subprocess, 'run', side_effect=fake_builder_run):
                found_tpl = shell_export.find_shell_template(eng, root=fb_root2)
            self.assertEqual(found_tpl, fb_root2 / 'template' / 'DmShell.app')

            # 4. Verify oneGame mode passes -o <tid>.ipa when out_dir is set, omits -o when out_dir is empty, and sets DM_FULL_ROMFS=1
            seen_cmds.clear()
            m.ipa_kind = 'oneGame'
            with mock.patch.object(model_mod.subprocess, 'Popen', FakePopen):
                m.start_build()
                m._thread.join(5)
            one_builds = [(c, e) for c, e in seen_cmds if '--progress' in c]
            self.assertEqual(len(one_builds), 1)
            one_cmd, one_env = one_builds[0]
            self.assertNotIn('--shell-framework', one_cmd)
            self.assertIn('-o', one_cmd)
            self.assertEqual(one_env.get('DM_FULL_ROMFS'), '1')

            seen_cmds.clear()
            m.out_dir = ''
            with mock.patch.object(model_mod.subprocess, 'Popen', FakePopen):
                m.start_build()
                m._thread.join(5)
            one_no_out = [(c, e) for c, e in seen_cmds if '--progress' in c]
            self.assertEqual(len(one_no_out), 1)
            self.assertNotIn('-o', one_no_out[0][0])

    def test_build_qt_workflow_packages_dmshell_template(self) -> None:
        wf = (ROOT / '.github' / 'workflows' / 'build-qt.yml').read_text(encoding='utf-8')
        self.assertIn('shell-template:', wf)
        self.assertIn('tools/build_shell_template.py', wf)
        self.assertIn('--hidden-import nspb_qt.win.shell_export', wf)
        self.assertIn('--add-data "shell_template${PATHSEP}shell_template"', wf)


if __name__ == '__main__':
    unittest.main()
