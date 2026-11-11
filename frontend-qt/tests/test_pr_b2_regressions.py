"""Regression tests for PR B2:
- BUG-12: Unified archive extraction guard, shared quota ledger, unconditional failed-target cleanup
  with `.old` rollback, and minimal `PYTHONPATH` sanitization when not frozen.
- BUG-10 & BUG-04 (Win): Real `settings.py` `DM_LANG` extraction, `gen_manifest.py --profile`,
  loose `msl/` packing and ZIP32 65,533 entry limit guard, and `build_nx_extract` SHA verification.
- BUG-22, BUG-17 (Qt), and UX 3.2.1-3.2.3: Atomic `library.json` writes, concurrent `ArtworkStore`
  index locking, FAT32 4 GiB - 1 preflight and overwrite-delta free-space accounting, bare `0400...`
  and header-parsed Title IDs for renamed `.nsp`/`.xci`, skipped-file diagnostics, `"game framework"`
  PSO polling, `oneGame` staged `-o` output path, pre-build `missingKey`/low-space blocking, and
  new build failure classifications (`metalToolchain`, `profileUpdateMismatch`, `freeAppleIdLimit`).

Every test in this module runs to `ok` even in headless Python CI environments without `PySide6`.
"""
from __future__ import annotations

from collections import namedtuple
import io
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import threading
import types
import unittest
from unittest import mock
import zipfile

os.environ.setdefault('QT_QPA_PLATFORM', 'offscreen')

ROOT = Path(__file__).resolve().parents[2]
QT_DIR = ROOT / 'frontend-qt'
if str(QT_DIR) not in sys.path:
    sys.path.insert(0, str(QT_DIR))

from nspb_qt import app_update  # noqa: E402
from nspb_qt import build_failure as bf  # noqa: E402
from nspb_qt import features as feat  # noqa: E402
from nspb_qt import inputs  # noqa: E402
from nspb_qt import library as lib  # noqa: E402
from nspb_qt import platform_util as pu  # noqa: E402
from nspb_qt.win import archive_guard as ag  # noqa: E402
from nspb_qt.win import build_app  # noqa: E402
from nspb_qt.win import driver as win_driver  # noqa: E402
from nspb_qt.win import sdk_fetch  # noqa: E402
from nspb_qt.win import shell_export  # noqa: E402
from nspb_qt.win import toolchain as tc  # noqa: E402


def _load_model_with_qt_fallback():
    """Import `nspb_qt.model`, installing a minimal `PySide6.QtCore` stub if PySide6 is absent."""
    try:
        from nspb_qt import model as model_mod
        return model_mod, False, lambda: None
    except ImportError:
        pass

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

        def value(self, k: str, default: object = '', **kw) -> object:
            fallback = kw.get('defaultValue', default)
            return self._d.get(k, fallback)

        def setValue(self, k: str, v: object) -> None:
            self._d[k] = v

        def remove(self, k: str) -> None:
            self._d.pop(k, None)

    class _FakeQt:
        QueuedConnection = 0

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

    return model_mod, True, _cleanup


# ---- Binary fixture builders matching Nintendo PFS0 / HFS0 / NCA3 / Ticket specs & features.py ----

def _encrypt_nca_header(plain: bytes, header_key: bytes) -> bytes:
    """Encrypt a 0x400-byte NCA header with Nintendo AES-128-XTS (0x200-byte sectors)."""
    assert len(plain) == 0x400 and len(header_key) == 32
    rk1 = feat._expand_key_128(header_key[:16])
    rk2 = feat._expand_key_128(header_key[16:])
    out = bytearray()
    for sector in range(2):
        t = bytearray(feat._aes128_encrypt_block(sector.to_bytes(16, 'big'), rk2))
        sec_plain = plain[sector * 0x200:(sector + 1) * 0x200]
        for blk in range(0, 0x200, 16):
            ct = bytes(a ^ b for a, b in zip(sec_plain[blk:blk + 16], t))
            enc = feat._aes128_encrypt_block(ct, rk1)
            out.extend(a ^ b for a, b in zip(enc, t))
            carry = 0
            for i in range(16):
                nc = (t[i] >> 7) & 1
                t[i] = ((t[i] << 1) | carry) & 0xFF
                carry = nc
            if carry:
                t[0] ^= 0x87
    return bytes(out)


def _make_nca(header_key: bytes, title_id: int, *, content_type: int = 1, key_gen: int = 1) -> bytes:
    plain = bytearray(0x400)
    plain[0x200:0x204] = b'NCA3'
    plain[0x205] = content_type  # 0 = Program, 1 = Meta
    plain[0x206] = key_gen if key_gen <= 2 else 2
    plain[0x207] = 0  # application key area
    struct.pack_into('<Q', plain, 0x210, title_id)
    if key_gen > 2:
        plain[0x220] = key_gen
    enc = _encrypt_nca_header(bytes(plain), header_key)
    assert feat.decrypt_nca_sector(enc[0x200:0x400], 1, header_key[:16], header_key[16:])[:4] == b'NCA3'
    return enc + b'\x00' * 0x200


def _make_ticket(title_id: int, key_gen: int = 0) -> bytes:
    tik = bytearray(0x2C0)
    tik[0x281] = 0  # common ticket
    tik[0x2A0:0x2B0] = title_id.to_bytes(8, 'big') + bytes([0] * 7 + [key_gen])
    return bytes(tik)


def _build_pfs0(entries: list[tuple[str, bytes]]) -> bytes:
    str_tab = bytearray()
    offsets: list[int] = []
    for name, _ in entries:
        offsets.append(len(str_tab))
        str_tab.extend(name.encode('ascii') + b'\x00')
    while len(str_tab) % 16 != 0:
        str_tab.append(0)
    ent_tab = bytearray()
    cur = 0
    for (_, data), noff in zip(entries, offsets):
        ent_tab.extend(struct.pack('<QQII', cur, len(data), noff, 0))
        cur += len(data)
    head = struct.pack('<4sIII', b'PFS0', len(entries), len(str_tab), 0)
    return head + bytes(ent_tab) + bytes(str_tab) + b''.join(d for _, d in entries)


def _build_hfs0(entries: list[tuple[str, bytes]]) -> bytes:
    """Build an HFS0 partition table (64-byte entries) used by XCI gamecards."""
    str_tab = bytearray()
    offsets: list[int] = []
    for name, _ in entries:
        offsets.append(len(str_tab))
        str_tab.extend(name.encode('ascii') + b'\x00')
    while len(str_tab) % 16 != 0:
        str_tab.append(0)
    ent_tab = bytearray()
    cur = 0
    for (_, data), noff in zip(entries, offsets):
        # HFS0 entry: u64 offset, u64 size, u32 name_off, u32 hash_target_size, u64 reserved, 32B sha256
        ent_tab.extend(struct.pack('<QQIIQ32s', cur, len(data), noff, 0, 0, b'\x00' * 32))
        cur += len(data)
    head = struct.pack('<4sIII', b'HFS0', len(entries), len(str_tab), 0)
    return head + bytes(ent_tab) + bytes(str_tab) + b''.join(d for _, d in entries)


def _build_xci(secure_entries: list[tuple[str, bytes]]) -> bytes:
    """Build a minimal XCI header (`HEAD` at 0x100, root HFS0 offset at 0x130) with a `secure` partition."""
    secure_hfs0 = _build_hfs0(secure_entries)
    root_hfs0 = _build_hfs0([('normal', _build_hfs0([])), ('secure', secure_hfs0)])
    root_off = 0xF000
    buf = bytearray(root_off)
    buf[0x100:0x104] = b'HEAD'
    struct.pack_into('<Q', buf, 0x130, root_off)
    buf.extend(root_hfs0)
    return bytes(buf)


def _make_zip_with_symlink(zip_path: Path, regular: list[tuple[str, bytes]], symlinks: list[tuple[str, str]]) -> Path:
    with zipfile.ZipFile(zip_path, 'w', compression=zipfile.ZIP_DEFLATED) as zf:
        for rel, body in regular:
            zf.writestr(rel, body)
        for rel, target in symlinks:
            zi = zipfile.ZipInfo(rel)
            zi.create_system = 3  # Unix
            zi.external_attr = (0o120777 << 16)
            zf.writestr(zi, target.encode('utf-8'))
    return zip_path


# =====================================================================
# 1. BUG-12: Archive Guard, Shared Quota Ledger, Rollback & PYTHONPATH
# =====================================================================

class ArchiveGuardAndRollbackTests(unittest.TestCase):
    def test_rejects_traversal_drive_ads_prefix_collision_and_escaping_symlinks(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            # Prefix collision check: `/tmp/x/dotnet-evil` must NOT pass `is_within(..., '/tmp/x/dotnet')`
            self.assertFalse(ag.is_within(root / 'dotnet-evil' / 'pwn.dll', root / 'dotnet'))
            self.assertTrue(ag.is_same_or_within(root / 'flat', root / 'flat'))

            for bad_member in (
                '../escape.txt',
                'sub/../../escape.txt',
                '/abs/escape.txt',
                '\\abs\\escape.txt',
                'C:drive_rel.txt',
                'dir/file.txt:$DATA',
            ):
                zpath = root / 'bad.zip'
                with zipfile.ZipFile(zpath, 'w') as zf:
                    zf.writestr(bad_member, b'evil')
                out = root / 'out'
                with self.assertRaises(ag.ArchiveSafetyError, msg=bad_member):
                    ag.extract_zip_safely(zpath, out)

            for bad_link_target in ('../../outside.txt', '/etc/passwd', 'C:\\Windows\\win.ini'):
                zlink = _make_zip_with_symlink(
                    root / 'badlink.zip',
                    [('real.txt', b'hello')],
                    [('sub/link.txt', bad_link_target)],
                )
                with self.assertRaises(ag.ArchiveSafetyError, msg=bad_link_target):
                    ag.extract_zip_safely(zlink, root / 'out_link')

            # Flat root archive extracts cleanly
            zflat = _make_zip_with_symlink(
                root / 'flat.zip',
                [('SDKSettings.json', b'{"Version":"18.2"}'), ('sub/a.txt', b'1234')],
                [('sub/alias.txt', 'a.txt')],
            )
            out_flat = root / 'out_flat'
            ag.extract_zip_safely(zflat, out_flat)
            self.assertEqual((out_flat / 'sub' / 'alias.txt').read_bytes(), b'1234')

    def test_shared_quota_ledger_spans_regular_files_unix_symlinks_and_tbd_stubs_and_blocks_dir_loops(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            payload = b'--- !tapi-tbd\n' + (b'A' * 400)
            zpath = _make_zip_with_symlink(
                root / 'sdk.zip',
                [
                    ('usr/lib/libReal.tbd', payload),
                    # Text symlink stub expanded later by `repair_tbd_stubs`
                    ('usr/lib/libTextStub.tbd', b'libReal.tbd'),
                ],
                [
                    # Unix symlink materialized during `extract_zip_safely`
                    ('usr/lib/libUnixSym.tbd', 'libReal.tbd'),
                ],
            )

            # 1) Regular + Unix symlink exceeds byte budget during symlink materialization
            tight_bytes = ag.ArchiveQuota(max_entries=50, max_bytes=len(payload) + 100)
            with self.assertRaises(ag.ArchiveSafetyError):
                ag.extract_zip_safely(zpath, root / 'fail_unix', quota=tight_bytes)

            # 2) Regular + Unix symlink fits, then `repair_tbd_stubs` sharing the SAME ledger exceeds budget
            shared = ag.ArchiveQuota(max_entries=50, max_bytes=len(payload) * 2 + 50)
            out_sdk = root / 'stage_sdk'
            ag.extract_zip_safely(zpath, out_sdk, quota=shared)
            with self.assertRaises(ag.ArchiveSafetyError):
                tc.repair_tbd_stubs(out_sdk, quota=shared, error_cls=ag.ArchiveSafetyError)

            # 3) Recursive directory symlink (`a/loop -> ..`) is rejected
            zloop = _make_zip_with_symlink(
                root / 'loop.zip',
                [('a/file.txt', b'ok')],
                [('a/loop', '..')],
            )
            with self.assertRaises(ag.ArchiveSafetyError):
                ag.extract_zip_safely(zloop, root / 'out_loop')

    def test_install_staged_tree_cleans_half_written_target_on_both_first_install_and_overwrite_rollback(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            target = root / 'installed_tool'

            # Case A: First-time install (no prior `.old` backup) leaves a half-written `target` then fails
            staged1 = root / 'staged1'
            staged1.mkdir()
            (staged1 / 'good.bin').write_bytes(b'v1')

            def partial_fail_move(_src: str, dst: str) -> None:
                Path(dst).mkdir(parents=True, exist_ok=True)
                (Path(dst) / 'partial_corrupt.bin').write_bytes(b'half')
                raise OSError('simulated mid-move disk error')

            with self.assertRaises(ag.ArchiveSafetyError):
                ag.install_staged_tree(staged1, target, move_fn=partial_fail_move)
            self.assertFalse(target.exists(), 'Half-written target must be unconditionally removed on first install failure')

            # Succeeding first install
            ag.install_staged_tree(staged1, target, validator=lambda d: (d / 'good.bin').is_file())
            self.assertEqual((target / 'good.bin').read_bytes(), b'v1')

            # Case B: Overwrite install (prior `target` backed up to `.installed_tool.old`) leaves half-written target then fails
            staged2 = root / 'staged2'
            staged2.mkdir()
            (staged2 / 'good.bin').write_bytes(b'v2')

            with self.assertRaises(app_update.StageError):
                ag.install_staged_tree(
                    staged2,
                    target,
                    validator=lambda d: (d / 'good.bin').is_file(),
                    move_fn=partial_fail_move,
                    error_cls=app_update.StageError,
                )
            # Target must be rolled back cleanly to v1 with no leftover partial file and no `.old` directory
            self.assertTrue((target / 'good.bin').is_file())
            self.assertEqual((target / 'good.bin').read_bytes(), b'v1')
            self.assertFalse((target / 'partial_corrupt.bin').exists())
            self.assertFalse((root / '.installed_tool.old').exists())

    def test_relaunch_env_preserves_user_pythonpath_when_not_frozen_and_strips_only_meipass_when_frozen(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            target_dir = Path(td) / 'App'
            meipass_dir = Path(td) / '_MEI12345'
            user_lib = str(Path(td) / 'my_custom_site_packages')
            sep = ';' if os.name == 'nt' else os.pathsep

            # Non-frozen source run: user PYTHONPATH and PYTHONHOME must stay untouched
            base_env = {
                'PYTHONPATH': sep.join([user_lib, '/opt/extra_py']),
                'PYTHONHOME': '/custom/pyhome',
            }
            with mock.patch.object(sys, 'frozen', False, create=True), \
                 mock.patch.object(sys, '_MEIPASS', None, create=True):
                cleaned_normal = app_update._sanitize_relaunch_env(base_env, target_dir)
            self.assertEqual(cleaned_normal['PYTHONPATH'], base_env['PYTHONPATH'])
            self.assertEqual(cleaned_normal['PYTHONHOME'], '/custom/pyhome')

            # Frozen PyInstaller run: `_MEIPASS` and `target/_internal` are stripped, user entry stays
            frozen_env = {
                'PYTHONPATH': sep.join([str(meipass_dir), user_lib, str(target_dir / '_internal')]),
                'PYTHONHOME': str(meipass_dir),
                '_MEIPASS': str(meipass_dir),
            }
            with mock.patch.object(sys, 'frozen', True, create=True), \
                 mock.patch.object(sys, '_MEIPASS', str(meipass_dir), create=True):
                cleaned_frozen = app_update._sanitize_relaunch_env(frozen_env, target_dir)
            self.assertEqual(cleaned_frozen.get('PYTHONPATH'), user_lib)
            self.assertNotIn('PYTHONHOME', cleaned_frozen)
            self.assertNotIn('_MEIPASS', cleaned_frozen)


# =====================================================================
# 2. BUG-10 & BUG-04 (Win): Real Engine Contracts, 65,533 Guard & SHA
# =====================================================================

class WindowsEngineContractTests(unittest.TestCase):
    def test_extract_default_lang_matches_real_engine_settings_py_output(self) -> None:
        """Run the real `engine/dm/games/settings.py` on both multi-language non-English (`ja` + `ko`)
        and single-language (`ja`-only) NACP files (`SupportedLanguageFlag` at `0x302C` per `nacp.py`)
        and verify `build_app.extract_default_lang` extracts `'ja'` rather than forcing `'en-US'`."""
        settings_py = ROOT / 'engine' / 'dm' / 'games' / 'settings.py'
        real_gd = ROOT / 'engine' / 'dm' / 'games' / '0100000000010000'
        self.assertTrue(settings_py.is_file(), f'Missing real engine script: {settings_py}')
        self.assertTrue((real_gd / 'game.tsv').is_file(), f'Missing real game profile: {real_gd}')
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            patched = tmp / 'patched'
            patched.mkdir()
            # 1) Multi-language non-English NACP (`(1 << 2) | (1 << 12)` at 0x302C -> `ja` + `ko`)
            nacp_multi = bytearray(0x4000)
            struct.pack_into('<I', nacp_multi, 0x302C, (1 << 2) | (1 << 12))
            nacp_multi_path = tmp / 'control_multi.nacp'
            nacp_multi_path.write_bytes(bytes(nacp_multi))
            out_multi = tmp / 'launcher_multi.json'

            r = subprocess.run(
                [sys.executable, str(settings_py), str(real_gd), str(patched), str(nacp_multi_path), str(out_multi)],
                capture_output=True,
                text=True,
                env=dict(os.environ, GFXAPI='nvn'),
            )
            self.assertEqual(r.returncode, 0, r.stderr or r.stdout)
            real_obj = json.loads(out_multi.read_text(encoding='utf-8'))
            self.assertNotIn('language', real_obj)
            self.assertEqual(build_app.extract_default_lang(real_obj, fallback='en-US'), 'ja')

            # 2) Single-language Japanese-only NACP (`1 << 2` at 0x302C -> `settings.py` omits `DM_LANG` row)
            nacp_mono = bytearray(0x4000)
            struct.pack_into('<I', nacp_mono, 0x302C, 1 << 2)
            nacp_mono_path = tmp / 'control_mono.nacp'
            nacp_mono_path.write_bytes(bytes(nacp_mono))
            out_mono = tmp / 'launcher_mono.json'
            r2 = subprocess.run(
                [sys.executable, str(settings_py), str(real_gd), str(patched), str(nacp_mono_path), str(out_mono)],
                capture_output=True,
                text=True,
                env=dict(os.environ, GFXAPI='nvn'),
            )
            self.assertEqual(r2.returncode, 0, r2.stderr or r2.stdout)
            mono_obj = json.loads(out_mono.read_text(encoding='utf-8'))
            self.assertEqual(
                build_app.extract_default_lang(mono_obj, fallback='en-US', nacp_path=nacp_mono_path),
                'ja',
            )
            # Legacy top-level `language` fallback still works
            self.assertEqual(build_app.extract_default_lang({'language': 'ko'}, fallback='en-US'), 'ko')

    def test_build_manifest_args_passes_profile_to_real_gen_manifest_for_switch2_console(self) -> None:
        """Run the real `engine/dm/ios/tools/gen_manifest.py` with `build_app.build_manifest_args`
        against the real Switch 2 profile `0400C3F00006E000` and verify `"console": "switch2"`."""
        gen_manifest = ROOT / 'engine' / 'dm' / 'ios' / 'tools' / 'gen_manifest.py'
        real_sw2_gd = ROOT / 'engine' / 'dm' / 'games' / '0400C3F00006E000'
        self.assertTrue(gen_manifest.is_file(), f'Missing real engine script: {gen_manifest}')
        self.assertTrue((real_sw2_gd / 'game.tsv').is_file(), f'Missing real Switch 2 profile: {real_sw2_gd}')
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            patched = tmp / 'patched'
            patched.mkdir()
            out_manifest = tmp / 'game.manifest.json'

            argv = build_app.build_manifest_args(
                repo=ROOT / 'engine',
                out_manifest=out_manifest,
                game='0400C3F00006E000',
                name='Mario Kart World',
                version='1.0.0',
                pkg='v0',
                mods=['main'],
                chain_ver='1.0',
                marker='romfs/track.bin',
                romfs_id='',
                fw_name='DmGame0400C3F00006E000',
                patched=patched,
                gd=real_sw2_gd,
            )
            self.assertIn('--profile', argv)
            r = subprocess.run([sys.executable, *map(str, argv)], capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stderr or r.stdout)
            manifest = json.loads(out_manifest.read_text(encoding='utf-8'))
            self.assertEqual(manifest.get('console'), 'switch2')

    def test_shell_export_packs_loose_msl_and_refuses_ipa_above_zip32_entry_limit(self) -> None:
        import plistlib
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            root = tmp / 'shell_root'
            tpl = root / 'template' / 'DmShell.app'
            tpl.mkdir(parents=True)
            (tpl / 'DmShell').write_bytes(b'\xcf\xfa\xed\xfe' + b'\x00' * 28)
            with open(tpl / 'Info.plist', 'wb') as pf:
                plistlib.dump({'CFBundleIdentifier': 'org.nxnative.shell'}, pf)

            fw = tmp / 'DmGame_0100000000010000.framework'
            msl_b = fw / 'msl' / 'b-1.0'
            msl_b.mkdir(parents=True)
            (fw / 'DmGame_0100000000010000').write_bytes(b'\xcf\xfa\xed\xfe' + b'\x00' * 28)
            (fw / 'game.manifest.json').write_text(
                json.dumps({
                    'id': '0100000000010000',
                    'name': 'Test Game',
                    'loader': 'FH',
                    'framework_executable': 'DmGame_0100000000010000',
                }),
                encoding='utf-8',
            )
            for idx in range(6):
                (msl_b / f'{idx:04d}_b.metallib').write_bytes(b'MTLB' + b'\x00' * 32)

            with mock.patch.object(shell_export.macho_sign, 'sign', lambda *_a, **_k: None), \
                 mock.patch.object(shell_export, '_prepare_fonts', lambda *_a, **_k: None), \
                 mock.patch.object(shell_export, '_update_shell_plist', lambda *_a, **_k: None):
                # 1) Unpacked count > 10 triggers `_pack_loose_shader_dirs` via real `shader_lib.py` -> fits <= 10!
                ok, ipa_path, _msg, _notes = shell_export.export_shell(
                    root=root,
                    repo=ROOT / 'engine',
                    framework=fw,
                    title_id='0100000000010000',
                    name='Test Game',
                    python_exe=sys.executable,
                    entry_limit=10,
                )
                self.assertTrue(ok, _msg)
                with zipfile.ZipFile(ipa_path, 'r') as zf:
                    names = set(zf.namelist())
                self.assertIn(
                    'Payload/DmShell.app/Frameworks/DmGame0100000000010000.framework/msl/b-1.0.img',
                    names,
                )

                # 2) Exceeding the ZIP32 entry limit even after packing aborts cleanly without leaving a corrupt IPA
                Path(ipa_path).unlink()
                ok_over, ipa_over, err_over, _ = shell_export.export_shell(
                    root=root,
                    repo=ROOT / 'engine',
                    framework=fw,
                    title_id='0100000000010000',
                    name='Test Game',
                    python_exe=sys.executable,
                    entry_limit=3,
                )
                self.assertFalse(ok_over)
                self.assertEqual(ipa_over, '')
                self.assertIn('3', err_over)
                self.assertFalse(Path(ipa_path).exists())

    def test_driver_build_nx_extract_verifies_sha_on_existing_cached_binary(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            repo = tmp / 'engine'
            proj = repo / 'dm' / 'tools' / 'nx_extract'
            proj.mkdir(parents=True)
            (proj / 'Program.cs').write_text('// source v2\n', encoding='utf-8')
            (proj / 'nx_extract.csproj').write_text('<Project/>\n', encoding='utf-8')

            work = tmp / 'work'
            logs = tmp / 'logs'
            logs.mkdir()
            nx_dir = work / 'tools' / 'nx_extract'
            nx_dir.mkdir(parents=True)
            cached_exe = nx_dir / 'nx_extract.exe'
            cached_exe.write_bytes(b'MZ-stale')

            class FakeUpstreamMod:
                BuildError = RuntimeError
                extract_bytes = staticmethod(lambda *_a, **_k: 0)
                say = staticmethod(lambda *_a, **_k: None)
                rmtree = staticmethod(lambda p: shutil.rmtree(p, ignore_errors=True))
                called_build = False

                @classmethod
                def run(cls, cmd, _log, env=None):
                    cls.called_build = True
                    out_idx = cmd.index('-o') + 1
                    (Path(cmd[out_idx]) / 'nx_extract.exe').write_bytes(b'MZ-fresh')

            fake_mod = FakeUpstreamMod()
            with mock.patch.object(win_driver, '_UPSTREAM_RUN', win_driver._UPSTREAM_RUN):
                win_driver.patch(fake_mod, repo)

                # Calculate expected SHA via a second probe
                seen_shas: list[str] = []

                def fake_subproc_run(cmd, *a, **kw):
                    exe_str = str(cmd[0])
                    data = Path(exe_str).read_bytes() if Path(exe_str).is_file() else b''
                    if data == b'MZ-stale':
                        seen_shas.append('stale')
                        return subprocess.CompletedProcess(cmd, 0, '0000000000000000\n', '')
                    # Return the real in-repo SHA for the freshly rebuilt binary
                    import hashlib
                    h = hashlib.sha256()
                    for f in sorted([*proj.glob('*.cs'), *proj.glob('*.csproj')], key=lambda p: p.name):
                        h.update(f.name.encode('utf-8') + b'\0' + f.read_bytes() + b'\0')
                    seen_shas.append('fresh')
                    return subprocess.CompletedProcess(cmd, 0, h.hexdigest()[:16] + '\n', '')

                with mock.patch.object(win_driver.subprocess, 'run', side_effect=fake_subproc_run):
                    res = fake_mod.build_nx_extract(repo, work, logs, {})
            self.assertTrue(FakeUpstreamMod.called_build, 'Stale cached nx_extract.exe must trigger rebuild')
            self.assertEqual(seen_shas, ['stale', 'fresh'])
            self.assertEqual((res.parent / 'nx_extract.exe').read_bytes(), b'MZ-fresh')


# =====================================================================
# 3. BUG-22, BUG-17 & UX 3.2.1-3.2.3: Library, Inputs, Model & Failures
# =====================================================================

class LibraryInputsAndModelTests(unittest.TestCase):
    def test_library_save_is_atomic_and_artwork_store_deduplicates_concurrent_index_fetch(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            state_dir = Path(td) / 'state'
            gl = lib.GameLibrary(state_dir=state_dir)
            gl.upsert(lib.LibraryGame(title_id='0100000000010000', name='Mario'))
            orig_bytes = gl.file_path.read_bytes()

            # Simulate atomic `os.replace` failure: original `library.json` stays intact and no `.tmp` leaks
            gl.games[0].name = 'Corrupted Attempt'
            with mock.patch('os.replace', side_effect=OSError('simulated crash')):
                gl.save()
                with self.assertRaises(OSError):
                    lib._atomic_write_text(gl.file_path, '{"corrupt": true}')
            self.assertEqual(gl.file_path.read_bytes(), orig_bytes)
            leftovers = [p.name for p in state_dir.iterdir() if p.name != 'library.json']
            self.assertEqual(leftovers, [])

            # ArtworkStore: 8 threads requesting banners concurrently fetch TITLEDB_URL only ONCE
            art = lib.ArtworkStore(state_dir=state_dir)
            fetch_calls = 0
            fetch_lock = threading.Lock()
            barrier = threading.Barrier(8)
            sample_db = json.dumps({
                f'010000000001{i:01x}000': {'id': f'010000000001{i:01x}000', 'bannerUrl': ''}
                for i in range(8)
            }).encode('utf-8')

            class _FakeResp:
                def __init__(self, body: bytes) -> None:
                    self._bio = io.BytesIO(body)

                def read(self, n: int = -1) -> bytes:
                    return self._bio.read(n)

                def __enter__(self):
                    return self

                def __exit__(self, *_a):
                    return False

            def fake_urlopen(req, timeout=20):
                nonlocal fetch_calls
                url = req.full_url if hasattr(req, 'full_url') else str(req)
                if url == lib.ArtworkStore.TITLEDB_URL:
                    with fetch_lock:
                        fetch_calls += 1
                    return _FakeResp(sample_db)
                raise OSError('no banner image needed')

            def worker(idx: int) -> None:
                barrier.wait(timeout=5)
                art._fetch_one(f'010000000001{idx:01x}000')

            with mock.patch('urllib.request.urlopen', side_effect=fake_urlopen):
                threads = [threading.Thread(target=worker, args=(i,)) for i in range(8)]
                for th in threads:
                    th.start()
                for th in threads:
                    th.join(timeout=10)

            self.assertEqual(fetch_calls, 1)
            self.assertTrue((art.banners_dir / 'banners_index.json').is_file())

    def test_fat32_oversize_guard_and_overwrite_space_delta_in_drive_copy_and_model(self) -> None:
        DiskUsage = namedtuple('usage', ['total', 'used', 'free'])
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            dest_root = tmp / 'usb_drive'
            tid = '01007EF00011E000'
            existing_dir = dest_root / tid
            existing_dir.mkdir(parents=True)
            # Pre-existing 3 GiB `romfs.img` on the USB drive that will be overwritten
            old_size = 3 * 1024 ** 3
            new_size = 3 * 1024 ** 3 + 200 * 1024 ** 2  # 3.2 GiB (net delta = 200 MiB)

            real_getsize = os.path.getsize
            real_isfile = os.path.isfile
            target_romfs = os.path.abspath(str(existing_dir / 'romfs.img'))

            def fake_isfile(p):
                if os.path.abspath(os.fspath(p)) == target_romfs:
                    return True
                return real_isfile(p)

            def fake_getsize(p):
                if os.path.abspath(os.fspath(p)) == target_romfs:
                    return old_size
                return real_getsize(p)

            # 1) Overwrite space accounting: only 1 GiB free, 3.2 GiB file overwriting 3.0 GiB old file needs 200 MiB -> PASSES
            with mock.patch('os.path.isfile', side_effect=fake_isfile), \
                 mock.patch('os.path.getsize', side_effect=fake_getsize), \
                 mock.patch('shutil.disk_usage', return_value=DiskUsage(64 * 1024 ** 3, 63 * 1024 ** 3, 1 * 1024 ** 3)), \
                 mock.patch.object(lib.DriveCopy, 'filesystem_type', return_value='exfat'):
                err = lib.DriveCopy.preflight_copy({'romfs.img': new_size}, str(dest_root), tid)
                self.assertIsNone(err)

            # 2) FAT32 / vfat volume rejects any file > 4 GiB - 1 (`FAT32_LIMIT`) in both `DriveCopy` and `Model._copy_archive_files`
            oversize = lib.DriveCopy.FAT32_LIMIT + 1
            with mock.patch('shutil.disk_usage', return_value=DiskUsage(64 * 1024 ** 3, 0, 64 * 1024 ** 3)), \
                 mock.patch.object(lib.DriveCopy, 'filesystem_type', return_value='msdos'):
                fat_err = lib.DriveCopy.preflight_copy({'romfs.img': oversize}, str(dest_root), tid)
                self.assertIsNotNone(fat_err)
                self.assertIn('FAT32', fat_err)

                model_mod, _, cleanup = _load_model_with_qt_fallback()
                try:
                    arch_src = tmp / 'arch_src'
                    arch_src.mkdir()
                    fake_romfs = arch_src / 'romfs.img'
                    fake_romfs.write_bytes(b'x')
                    real_stat = os.stat

                    class _FakeStat:
                        def __init__(self, st, sz: int):
                            self._st = st
                            self.st_size = sz

                        def __getattr__(self, k):
                            return getattr(self._st, k)

                    def fake_stat(p, *a, **kw):
                        st = real_stat(p, *a, **kw)
                        try:
                            if os.path.abspath(os.fspath(p)) == os.path.abspath(str(fake_romfs)):
                                return _FakeStat(st, oversize)
                        except TypeError:
                            pass
                        return st

                    with mock.patch('os.stat', side_effect=fake_stat):
                        ok, cancelled, m_err = model_mod.Model._copy_archive_files(
                            str(arch_src), str(dest_root), tid
                        )
                    self.assertFalse(ok)
                    self.assertFalse(cancelled)
                    self.assertIn('FAT32', m_err)
                finally:
                    cleanup()

    def test_bare_switch2_tid_header_parsed_nsp_xci_and_skipped_files_diagnostics(self) -> None:
        # 1) Bare 0400... Switch 2 Title ID without brackets
        self.assertEqual(inputs.title_id('Mario_Kart_World_0400000000010000_v0.nsp'), 0x0400000000010000)
        self.assertEqual(lib.clean_game_name('Mario_Kart_World_0400000000010000_v0.nsp'), 'Mario Kart World')

        header_key = bytes((i * 5 + 9) & 0xFF for i in range(32))
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            keys_file = tmp / 'prod.keys'
            keys_file.write_text(f'header_key = {header_key.hex()}\n', encoding='utf-8')

            games_dir = tmp / 'Games'
            games_dir.mkdir()
            # Renamed NSP without Title ID in filename (NCA header only, no ticket)
            zelda_nsp = games_dir / 'The Legend of Zelda Breath of the Wild.nsp'
            zelda_nsp.write_bytes(_build_pfs0([
                ('0001.cnmt.nca', _make_nca(header_key, 0x01007EF00011E000, content_type=1)),
                ('0002.nca', _make_nca(header_key, 0x01007EF00011E000, content_type=0)),
            ]))
            # Renamed XCI without Title ID in filename (HFS0 secure partition with ticket + NCA)
            metroid_xci = games_dir / 'Metroid Dread Clean Dump.xci'
            metroid_xci.write_bytes(_build_xci([
                ('010093801237C0000000000000000000.tik', _make_ticket(0x010093801237C000)),
                ('abcd.cnmt.nca', _make_nca(header_key, 0x010093801237C000, content_type=1)),
            ]))
            # Bare Switch 2 NSP
            mk_nsp = games_dir / 'Mario_Kart_World_0400000000010000_v0.nsp'
            mk_nsp.write_bytes(_build_pfs0([
                ('0003.cnmt.nca', _make_nca(header_key, 0x0400000000010000, content_type=1)),
            ]))
            # Orphan update + orphan DLC + unextracted archives
            (games_dir / 'Orphan Update [0100C2500FC20800][v65536].nsp').write_bytes(
                _build_pfs0([('u.cnmt.nca', _make_nca(header_key, 0x0100C2500FC20800, content_type=1))])
            )
            (games_dir / 'Orphan DLC [010055D009F79001].nsp').write_bytes(
                _build_pfs0([('d.cnmt.nca', _make_nca(header_key, 0x010055D009F79001, content_type=1))])
            )
            (games_dir / 'PackedGame.7z').write_bytes(b'7z' + b'\x00' * 32)
            (games_dir / 'SplitDump.nsp.00').write_bytes(b'\x00' * 32)

            gl = lib.GameLibrary(state_dir=tmp / 'state')
            gl.set_games_folder(str(games_dir), repo_path=str(ROOT / 'engine'), default_keys=str(keys_file))
            tids = {g.title_id for g in gl.games}
            self.assertEqual(tids, {'01007EF00011E000', '010093801237C000', '0400000000010000'})
            self.assertEqual(len(gl.skipped_files), 4)
            self.assertEqual(
                {(s.name, s.kind) for s in gl.skipped_files},
                {
                    ('Orphan Update [0100C2500FC20800][v65536].nsp', 'orphan'),
                    ('Orphan DLC [010055D009F79001].nsp', 'orphan'),
                    ('PackedGame.7z', 'archive'),
                    ('SplitDump.nsp.00', 'archive'),
                },
            )

            # `record_completed_ios` must keep both renamed games separate (never overwrite '0100000000000000')
            gl2 = lib.GameLibrary(state_dir=tmp / 'state2')
            g_a = gl2.record_completed_ios(
                title_id='',
                base_path=str(zelda_nsp),
                keys_path=str(keys_file),
                repo_path=str(ROOT / 'engine'),
            )
            g_b = gl2.record_completed_ios(
                title_id='',
                base_path=str(metroid_xci),
                keys_path=str(keys_file),
                repo_path=str(ROOT / 'engine'),
            )
            self.assertEqual(g_a.title_id, '01007EF00011E000')
            self.assertEqual(g_b.title_id, '010093801237C000')
            self.assertEqual(len(gl2.games), 2)

    def test_model_game_framework_pso_polling_onegame_staged_output_and_prebuild_blocks(self) -> None:
        """Verify `Model` behavior both normally and under simulated headless CI without PySide6."""
        model_mod, _, cleanup = _load_model_with_qt_fallback()
        DiskUsage = namedtuple('usage', ['total', 'used', 'free'])
        header_key = bytes((i * 3 + 11) & 0xFF for i in range(32))
        try:
            with tempfile.TemporaryDirectory() as td:
                tmp = Path(td)
                old_keys = tmp / 'old_prod.keys'
                old_keys.write_text(
                    f'header_key = {header_key.hex()}\n'
                    + 'key_area_key_application_00 = ' + ('11' * 16) + '\n',
                    encoding='utf-8',
                )
                full_keys = tmp / 'prod.keys'
                full_keys.write_text(
                    f'header_key = {header_key.hex()}\n'
                    + '\n'.join(f'key_area_key_application_{r:02x} = ' + f'{r:02x}' * 16 for r in range(0x14))
                    + '\n',
                    encoding='utf-8',
                )

                # Package needing master_key_12 (key_gen = 0x13 on its Program NCA)
                shared_dir = tmp / 'shared_roms'
                shared_dir.mkdir()
                game1 = shared_dir / 'Zelda [01008CF01BAAC000][v0].nsp'
                game1.write_bytes(_build_pfs0([
                    ('a.cnmt.nca', _make_nca(header_key, 0x01008CF01BAAC000, content_type=1, key_gen=0x13)),
                    ('prog.nca', _make_nca(header_key, 0x01008CF01BAAC000, content_type=0, key_gen=0x13)),
                ]))
                other_game = shared_dir / 'Other [0100000000010000][v0].nsp'
                other_game.write_bytes(_build_pfs0([
                    ('b.cnmt.nca', _make_nca(header_key, 0x0100000000010000, content_type=1, key_gen=1)),
                    ('other_prog.nca', _make_nca(header_key, 0x0100000000010000, content_type=0, key_gen=1)),
                ]))

                with mock.patch.object(model_mod.Model, 'check_deps', lambda self: None), \
                     mock.patch.object(pu, 'find_python', return_value=(sys.executable, True, '3.12.0')), \
                     mock.patch.object(pu, 'find_dotnet', return_value=('', False)), \
                     mock.patch.object(lib, 'default_state_dir', lambda: tmp / 'state'):
                    m = model_mod.Model()
                m.repo_path = str(ROOT)
                m.deps = [
                    model_mod.Dep('python', 'dep.python', 'dep.python.hint', model_mod.DepState.OK, sys.executable),
                ]
                m.deps_checked = True

                # 1) Pre-build `missingKey` guard blocks `can_build` and `start_build`
                m.base_path = str(game1)
                m.keys_path = str(old_keys)
                self.assertFalse(m.can_build)
                self.assertIn('master_key_12', m.prebuild_block_reason())
                emitted: list[tuple[bool, str]] = []
                m.finished.connect(lambda ok, msg: emitted.append((ok, msg)))
                m.start_build()
                self.assertEqual(len(emitted), 1)
                self.assertFalse(emitted[0][0])
                self.assertIn('master_key_12', emitted[0][1])

                # 2) Pre-build low-disk-space guard on `.nsz` (3.5x peak factor)
                nsz_pkg = tmp / 'BigGame [0100453019AA8000][v0].nsz'
                nsz_pkg.write_bytes(_build_pfs0([
                    ('c.cnmt.nca', _make_nca(header_key, 0x0100453019AA8000, content_type=1, key_gen=1)),
                ]))
                m.base_path = str(nsz_pkg)
                m.keys_path = str(full_keys)
                real_stat = os.stat

                class _FakeNszStat:
                    def __init__(self, st):
                        self._st = st
                        self.st_size = 4 * 1024 ** 3

                    def __getattr__(self, k):
                        return getattr(self._st, k)

                def fake_nsz_stat(p, *a, **kw):
                    st = real_stat(p, *a, **kw)
                    try:
                        if os.path.abspath(os.fspath(p)) == os.path.abspath(str(nsz_pkg)):
                            return _FakeNszStat(st)
                    except TypeError:
                        pass
                    return st

                with mock.patch('os.stat', side_effect=fake_nsz_stat), \
                     mock.patch('shutil.disk_usage', return_value=DiskUsage(100 * 1024 ** 3, 92 * 1024 ** 3, 8 * 1024 ** 3)):
                    self.assertFalse(m.can_build)
                    self.assertTrue(bool(m.prebuild_block_reason()))

                # 3) `[6/7] game framework …` starts `_start_pso_poll` and updates batch progress from pso_offline work/log
                work_dir = tmp / 'pso_work'
                mac_work = work_dir / 'pso' / 'mac-work'
                mac_work.mkdir(parents=True)
                (mac_work / 'bases.mtl4-json').write_text('{"bases":[]}\n', encoding='utf-8')
                logs_dir = work_dir / 'logs'
                logs_dir.mkdir(parents=True)
                (logs_dir / 'pso_offline_mac.log').write_text(
                    'pso_offline: g18p: batch 3/4: ready\n',
                    encoding='utf-8',
                )
                m.effective_work_dir = str(work_dir)
                m.stages = []
                try:
                    m._on_line('[12:00:01] [6/7] game framework …')
                    self.assertEqual(len(m.stages), 1)
                    self.assertEqual(m.stages[0].name, 'game framework')
                    self.assertAlmostEqual(m.stages[0].percent, 75.0)
                    self.assertIn('3 / 4', m.stages[0].detail)
                finally:
                    m._stop_pso_poll()

                # 4) `oneGame` in a shared folder (staged input) resolves & moves the staged `.ipa` into `base_dir`
                #    when `out_dir` is empty (omitting `-o`), and passes `-o <out_dir>/<tid>.ipa` when `out_dir` is set
                m.base_path = str(game1)
                m.keys_path = str(full_keys)
                m.out_dir = ''
                m.ipa_kind = 'oneGame'
                seen_cmds: list[list[str]] = []

                class _FakePopen:
                    def __init__(self, cmd, **_kw):
                        cmd_list = [str(c) for c in cmd]
                        seen_cmds.append(cmd_list)
                        if '--progress' in cmd_list and '-o' not in cmd_list:
                            staged_in = Path(cmd_list[2])
                            if staged_in.is_dir():
                                staged_ipa = staged_in / 'Zelda.ipa'
                                with zipfile.ZipFile(staged_ipa, 'w') as zf:
                                    zf.writestr('Payload/DmIOS.app/Info.plist', b'<plist/>')
                                    zf.writestr('Payload/DmIOS.app/DmIOS', b'\xcf\xfa\xed\xfe')
                        self.stdout = io.StringIO('')
                        self.returncode = 0

                    def wait(self):
                        return 0

                    def poll(self):
                        return 0

                with mock.patch.object(model_mod.engine, 'needs_sync_before_build', return_value=False), \
                     mock.patch.object(model_mod.subprocess, 'Popen', _FakePopen), \
                     mock.patch('shutil.disk_usage', return_value=DiskUsage(500 * 1024 ** 3, 0, 500 * 1024 ** 3)):
                    m.start_build()
                    m._thread.join(5)
                build_cmds = [c for c in seen_cmds if '--progress' in c]
                self.assertEqual(len(build_cmds), 1)
                self.assertNotIn('-o', build_cmds[0])
                self.assertEqual(Path(m.ipa_path), shared_dir / 'Zelda.ipa')
                self.assertTrue((shared_dir / 'Zelda.ipa').is_file())

                seen_cmds.clear()
                explicit_out = tmp / 'explicit_out'
                explicit_out.mkdir()
                m.out_dir = str(explicit_out)
                with mock.patch.object(model_mod.engine, 'needs_sync_before_build', return_value=False), \
                     mock.patch.object(model_mod.subprocess, 'Popen', _FakePopen), \
                     mock.patch('shutil.disk_usage', return_value=DiskUsage(500 * 1024 ** 3, 0, 500 * 1024 ** 3)):
                    m.start_build()
                    m._thread.join(5)
                build_cmds = [c for c in seen_cmds if '--progress' in c]
                self.assertEqual(len(build_cmds), 1)
                self.assertIn('-o', build_cmds[0])
                out_arg = build_cmds[0][build_cmds[0].index('-o') + 1]
                self.assertEqual(Path(out_arg), explicit_out / '01008CF01BAAC000.ipa')
        finally:
            cleanup()

    def test_model_fallback_runs_without_pyside6_installed(self) -> None:
        """Verify `_load_model_with_qt_fallback` executes without skipping when `PySide6` is absent."""
        code = (
            "import importlib.abc, sys, unittest\n"
            "class _BlockPySide6(importlib.abc.MetaPathFinder):\n"
            "    def find_spec(self, fullname, path, target=None):\n"
            "        if fullname == 'PySide6' or fullname.startswith('PySide6.'):\n"
            "            raise ModuleNotFoundError('No module named PySide6')\n"
            "        return None\n"
            "sys.meta_path.insert(0, _BlockPySide6())\n"
            "sys.path.insert(0, 'frontend-qt/tests')\n"
            "import test_pr_b2_regressions as mod\n"
            "suite = unittest.defaultTestLoader.loadTestsFromName(\n"
            "    'LibraryInputsAndModelTests.test_model_game_framework_pso_polling_onegame_staged_output_and_prebuild_blocks', mod\n"
            ")\n"
            "res = unittest.TextTestRunner(verbosity=2).run(suite)\n"
            "assert res.wasSuccessful() and res.testsRun == 1 and len(res.skipped) == 0\n"
        )
        proc = subprocess.run(
            [sys.executable, '-c', code],
            cwd=str(ROOT),
            capture_output=True,
            text=True,
            timeout=90,
        )
        self.assertEqual(proc.returncode, 0, msg=f'stdout={proc.stdout}\nstderr={proc.stderr}')

    def test_new_build_failure_classifications_and_zero_semicolons_across_all_languages(self) -> None:
        # 1) Missing Xcode MetalToolchain (verbatim from `build_ipa_from_nsp.py:831`)
        f_metal = bf.classify(
            'FAIL: metal cannot compile shaders (cannot execute tool metal): install the Metal '
            'Toolchain with: xcodebuild -downloadComponent MetalToolchain'
        )
        self.assertEqual(f_metal.kind, bf.METAL_TOOLCHAIN)
        self.assertEqual(f_metal.what_key, 'fail.metalToolchain.what')

        # 2) Update version mismatch against profile (verbatim from `build_ipa_from_nsp.py:3186`)
        f_prof = bf.classify(
            'FAIL: game profile totk has no build for v131072 (it registers v0 1.0.0, v65536 1.1.0)'
        )
        self.assertEqual(f_prof.kind, bf.PROFILE_UPDATE_MISMATCH)

        # 3) Free Apple ID 10-App-ID (#1087) vs 3-app active sideload limit
        f_apple = bf.classify(
            'error: Communication with Apple failed: Your maximum App ID limit has been reached. '
            'You may create up to 10 App IDs every 7 days.'
        )
        self.assertEqual(f_apple.kind, bf.APP_ID_LIMIT)
        f_three = bf.classify(
            'ERROR: This device has reached the maximum number of installed apps using a free developer profile (code -36607).'
        )
        self.assertEqual(f_three.kind, bf.FREE_APPLE_ID_LIMIT)

        # 4) All 12 new localization keys across all 10 languages contain zero ASCII or fullwidth semicolons
        new_keys = (
            'library.skippedArchive',
            'library.skippedBanner',
            'library.skippedDetails',
            'library.skippedOrphan',
            'library.skippedTitle',
            'status.lowDiskSpace',
            'fail.metalToolchain.what',
            'fail.metalToolchain.next',
            'fail.profileUpdateMismatch.what',
            'fail.profileUpdateMismatch.next',
            'fail.freeAppleIdLimit.what',
            'fail.freeAppleIdLimit.next',
        )
        for p in sorted((ROOT / 'frontend' / 'l10n').glob('*.json')):
            table = json.loads(p.read_text(encoding='utf-8'))
            for k in new_keys:
                self.assertIn(k, table, f'{p.name} missing {k}')
                self.assertNotIn(';', table[k], f'{p.name}:{k} contains ASCII semicolon')
                self.assertNotIn('；', table[k], f'{p.name}:{k} contains fullwidth semicolon')


if __name__ == '__main__':
    unittest.main()
