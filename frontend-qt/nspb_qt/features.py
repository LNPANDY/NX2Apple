"""KeyCheck (pure-Python AES-128-XTS NCA header verifier), CheatFiles, and Diagnostics.

Mirrors KeyCheck.swift, CheatFiles.swift, and Diagnostics.swift from the Mac Swift launcher.
"""
from __future__ import annotations

import os
import platform
import re
import shutil
import struct
import zipfile
from dataclasses import dataclass, field
from pathlib import Path

# ---------------------------------------------------------------------------
# Pure-Python AES-128-ECB & Nintendo Switch AES-128-XTS (for 1 KB NCA header)
# ---------------------------------------------------------------------------

_SBOX = (
    0x63, 0x7c, 0x77, 0x7b, 0xf2, 0x6b, 0x6f, 0xc5, 0x30, 0x01, 0x67, 0x2b, 0xfe, 0xd7, 0xab, 0x76,
    0xca, 0x82, 0xc9, 0x7d, 0xfa, 0x59, 0x47, 0xf0, 0xad, 0xd4, 0xa2, 0xaf, 0x9c, 0xa4, 0x72, 0xc0,
    0xb7, 0xfd, 0x93, 0x26, 0x36, 0x3f, 0xf7, 0xcc, 0x34, 0xa5, 0xe5, 0xf1, 0x71, 0xd8, 0x31, 0x15,
    0x04, 0xc7, 0x23, 0xc3, 0x18, 0x96, 0x05, 0x9a, 0x07, 0x12, 0x80, 0xe2, 0xeb, 0x27, 0xb2, 0x75,
    0x09, 0x83, 0x2c, 0x1a, 0x1b, 0x6e, 0x5a, 0xa0, 0x52, 0x3b, 0xd6, 0xb3, 0x29, 0xe3, 0x2f, 0x84,
    0x53, 0xd1, 0x00, 0xed, 0x20, 0xfc, 0xb1, 0x5b, 0x6a, 0xcb, 0xbe, 0x39, 0x4a, 0x4c, 0x58, 0xcf,
    0xd0, 0xef, 0xaa, 0xfb, 0x43, 0x4d, 0x33, 0x85, 0x45, 0xf9, 0x02, 0x7f, 0x50, 0x3c, 0x9f, 0xa8,
    0x51, 0xa3, 0x40, 0x8f, 0x92, 0x9d, 0x38, 0xf5, 0xbc, 0xb6, 0xda, 0x21, 0x10, 0xff, 0xf3, 0xd2,
    0xcd, 0x0c, 0x13, 0xec, 0x5f, 0x97, 0x44, 0x17, 0xc4, 0xa7, 0x7e, 0x3d, 0x64, 0x5d, 0x19, 0x73,
    0x60, 0x81, 0x4f, 0xdc, 0x22, 0x2a, 0x90, 0x88, 0x46, 0xee, 0xb8, 0x14, 0xde, 0x5e, 0x0b, 0xdb,
    0xe0, 0x32, 0x3a, 0x0a, 0x49, 0x06, 0x24, 0x5c, 0xc2, 0xd3, 0xac, 0x62, 0x91, 0x95, 0xe4, 0x79,
    0xe7, 0xc8, 0x37, 0x6d, 0x8d, 0xd5, 0x4e, 0xa9, 0x6c, 0x56, 0xf4, 0xea, 0x65, 0x7a, 0xae, 0x08,
    0xba, 0x78, 0x25, 0x2e, 0x1c, 0xa6, 0xb4, 0xc6, 0xe8, 0xdd, 0x74, 0x1f, 0x4b, 0xbd, 0x8b, 0x8a,
    0x70, 0x3e, 0xb5, 0x66, 0x48, 0x03, 0xf6, 0x0e, 0x61, 0x35, 0x57, 0xb9, 0x86, 0xc1, 0x1d, 0x9e,
    0xe1, 0xf8, 0x98, 0x11, 0x69, 0xd9, 0x8e, 0x94, 0x9b, 0x1e, 0x87, 0xe9, 0xce, 0x55, 0x28, 0xdf,
    0x8c, 0xa1, 0x89, 0x0d, 0xbf, 0xe6, 0x42, 0x68, 0x41, 0x99, 0x2d, 0x0f, 0xb0, 0x54, 0xbb, 0x16,
)

_INV_SBOX = [0] * 256
for _i, _v in enumerate(_SBOX):
    _INV_SBOX[_v] = _i

_RCON = (0x00, 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1B, 0x36)


def _xtime(a: int) -> int:
    return ((a << 1) ^ 0x1B) & 0xFF if (a & 0x80) else (a << 1)


def _gmul(a: int, b: int) -> int:
    p = 0
    for _ in range(8):
        if b & 1:
            p ^= a
        hi = a & 0x80
        a = (a << 1) & 0xFF
        if hi:
            a ^= 0x1B
        b >>= 1
    return p


def _expand_key_128(key: bytes) -> list[list[int]]:
    w = [list(key[i:i + 4]) for i in range(0, 16, 4)]
    for i in range(4, 44):
        temp = list(w[i - 1])
        if i % 4 == 0:
            temp = [_SBOX[temp[1]] ^ _RCON[i // 4], _SBOX[temp[2]], _SBOX[temp[3]], _SBOX[temp[0]]]
        w.append([w[i - 4][j] ^ temp[j] for j in range(4)])
    return [[w[r * 4 + c][row] for c in range(4) for row in range(4)] for r in range(11)]


def _aes128_encrypt_block(block: bytes, rkeys: list[list[int]]) -> bytes:
    s = [block[i] ^ rkeys[0][i] for i in range(16)]
    for r in range(1, 10):
        # SubBytes + ShiftRows
        s = [
            _SBOX[s[0]], _SBOX[s[5]], _SBOX[s[10]], _SBOX[s[15]],
            _SBOX[s[4]], _SBOX[s[9]], _SBOX[s[14]], _SBOX[s[3]],
            _SBOX[s[8]], _SBOX[s[13]], _SBOX[s[2]], _SBOX[s[7]],
            _SBOX[s[12]], _SBOX[s[1]], _SBOX[s[6]], _SBOX[s[11]],
        ]
        # MixColumns + AddRoundKey
        rk = rkeys[r]
        ns = [0] * 16
        for c in range(4):
            i = c * 4
            a0, a1, a2, a3 = s[i], s[i + 1], s[i + 2], s[i + 3]
            t = a0 ^ a1 ^ a2 ^ a3
            ns[i] = a0 ^ t ^ _xtime(a0 ^ a1) ^ rk[i]
            ns[i + 1] = a1 ^ t ^ _xtime(a1 ^ a2) ^ rk[i + 1]
            ns[i + 2] = a2 ^ t ^ _xtime(a2 ^ a3) ^ rk[i + 2]
            ns[i + 3] = a3 ^ t ^ _xtime(a3 ^ a0) ^ rk[i + 3]
        s = ns
    s = [
        _SBOX[s[0]], _SBOX[s[5]], _SBOX[s[10]], _SBOX[s[15]],
        _SBOX[s[4]], _SBOX[s[9]], _SBOX[s[14]], _SBOX[s[3]],
        _SBOX[s[8]], _SBOX[s[13]], _SBOX[s[2]], _SBOX[s[7]],
        _SBOX[s[12]], _SBOX[s[1]], _SBOX[s[6]], _SBOX[s[11]],
    ]
    rk = rkeys[10]
    return bytes(s[i] ^ rk[i] for i in range(16))


def _aes128_decrypt_block(block: bytes, rkeys: list[list[int]]) -> bytes:
    s = [block[i] ^ rkeys[10][i] for i in range(16)]
    for r in range(9, 0, -1):
        # InvShiftRows + InvSubBytes
        s = [
            _INV_SBOX[s[0]], _INV_SBOX[s[13]], _INV_SBOX[s[10]], _INV_SBOX[s[7]],
            _INV_SBOX[s[4]], _INV_SBOX[s[1]], _INV_SBOX[s[14]], _INV_SBOX[s[11]],
            _INV_SBOX[s[8]], _INV_SBOX[s[5]], _INV_SBOX[s[2]], _INV_SBOX[s[15]],
            _INV_SBOX[s[12]], _INV_SBOX[s[9]], _INV_SBOX[s[6]], _INV_SBOX[s[3]],
        ]
        rk = rkeys[r]
        s = [s[i] ^ rk[i] for i in range(16)]
        # InvMixColumns
        ns = [0] * 16
        for c in range(4):
            i = c * 4
            a0, a1, a2, a3 = s[i], s[i + 1], s[i + 2], s[i + 3]
            ns[i] = _gmul(a0, 0x0e) ^ _gmul(a1, 0x0b) ^ _gmul(a2, 0x0d) ^ _gmul(a3, 0x09)
            ns[i + 1] = _gmul(a0, 0x09) ^ _gmul(a1, 0x0e) ^ _gmul(a2, 0x0b) ^ _gmul(a3, 0x0d)
            ns[i + 2] = _gmul(a0, 0x0d) ^ _gmul(a1, 0x09) ^ _gmul(a2, 0x0e) ^ _gmul(a3, 0x0b)
            ns[i + 3] = _gmul(a0, 0x0b) ^ _gmul(a1, 0x0d) ^ _gmul(a2, 0x09) ^ _gmul(a3, 0x0e)
        s = ns
    s = [
        _INV_SBOX[s[0]], _INV_SBOX[s[13]], _INV_SBOX[s[10]], _INV_SBOX[s[7]],
        _INV_SBOX[s[4]], _INV_SBOX[s[1]], _INV_SBOX[s[14]], _INV_SBOX[s[11]],
        _INV_SBOX[s[8]], _INV_SBOX[s[5]], _INV_SBOX[s[2]], _INV_SBOX[s[15]],
        _INV_SBOX[s[12]], _INV_SBOX[s[9]], _INV_SBOX[s[6]], _INV_SBOX[s[3]],
    ]
    rk = rkeys[0]
    return bytes(s[i] ^ rk[i] for i in range(16))


def decrypt_nca_sector(cipher: bytes, sector: int, key1: bytes, key2: bytes) -> bytes:
    """Decrypt a 0x200-byte Nintendo Switch NCA header sector with AES-128-XTS."""
    rk1 = _expand_key_128(key1)
    rk2 = _expand_key_128(key2)
    # Nintendo Switch tweak is big-endian sector number
    tweak = list(_aes128_encrypt_block(sector.to_bytes(16, 'big'), rk2))
    out = bytearray(len(cipher))
    for off in range(0, len(cipher), 16):
        xored = bytes(cipher[off + i] ^ tweak[i] for i in range(16))
        dec = _aes128_decrypt_block(xored, rk1)
        for i in range(16):
            out[off + i] = dec[i] ^ tweak[i]
        # GF(2^128) multiply tweak by alpha (little-endian carry)
        carry = 0
        for i in range(16):
            nxt = (tweak[i] >> 7) & 1
            tweak[i] = ((tweak[i] << 1) | carry) & 0xFF
            carry = nxt
        if carry:
            tweak[0] ^= 0x87
    return bytes(out)


# ---------------------------------------------------------------------------
# KeyCheck (mirrors KeyCheck.swift)
# ---------------------------------------------------------------------------

@dataclass
class KeyVerdict:
    kind: str  # 'fits', 'unreadableKeys', 'missingHeaderKey', 'wrongHeaderKey', 'missingKey', 'cannotCheck'
    part: str = ''      # 'base', 'update', 'dlc'
    key: str = ''
    firmware: str | None = None
    reason: str = ''


class KeyCheck:
    KEY_AREA_NAMES = ['application', 'ocean', 'system']
    FIRMWARE_BY_GEN = {
        '00': '1.0.0',
        '01': '1.0.0',
        '02': '3.0.0',
        '03': '3.0.1',
        '04': '4.0.0',
        '05': '5.0.0',
        '06': '6.0.0',
        '07': '6.2.0',
        '08': '7.0.0',
        '09': '8.1.0',
        '0a': '9.0.0',
        '0b': '9.1.0',
        '0c': '12.1.0',
        '0d': '13.0.0',
        '0e': '14.0.0',
        '0f': '15.0.0',
        '10': '16.0.0',
        '11': '17.0.0',
        '12': '18.0.0',
        '13': '19.0.0',
        '14': '20.0.0',
        '15': '21.0.0',
    }

    @staticmethod
    def firmware_for_key(key_name: str) -> str | None:
        suf = key_name[-2:].lower() if len(key_name) >= 2 else ''
        return KeyCheck.FIRMWARE_BY_GEN.get(suf)

    @staticmethod
    def parse_keys(text: str) -> dict[str, str]:
        out: dict[str, str] = {}
        for line in text.splitlines():
            s = line.split('#', 1)[0].strip()
            if '=' not in s:
                continue
            k, v = s.split('=', 1)
            k = k.strip().lower()
            v = v.strip().lower()
            if k and len(v) >= 16 and len(v) % 2 == 0 and all(c in '0123456789abcdef' for c in v):
                out[k] = v
        return out

    @staticmethod
    def load_keys(path: str) -> dict[str, str] | None:
        if not path or not os.path.isfile(path):
            return None
        try:
            with open(path, encoding='utf-8', errors='replace') as f:
                return KeyCheck.parse_keys(f.read())
        except OSError:
            return None

    @staticmethod
    def check(
        keys_path: str,
        base_path: str,
        update_path: str = '',
        dlc_paths: list[str] | None = None,
    ) -> KeyVerdict:
        keys = KeyCheck.load_keys(keys_path)
        if keys is None:
            return KeyVerdict('unreadableKeys')
        hk_hex = keys.get('header_key', '')
        if len(hk_hex) != 64:
            return KeyVerdict('missingHeaderKey')
        header_key = bytes.fromhex(hk_hex)

        items: list[tuple[str, str]] = [('base', base_path)]
        if update_path:
            items.append(('update', update_path))
        for dp in (dlc_paths or []):
            if dp:
                items.append(('dlc', dp))

        cannot_check: KeyVerdict | None = None
        for part, path in items:
            if not path or not os.path.isfile(path):
                continue
            v = KeyCheck._check_package(path, part, keys, header_key)
            if v.kind in ('wrongHeaderKey', 'missingKey'):
                return v
            if v.kind == 'cannotCheck' and cannot_check is None:
                cannot_check = v

        return cannot_check or KeyVerdict('fits')

    @staticmethod
    def _check_package(
        path: str,
        part: str,
        keys: dict[str, str],
        header_key: bytes,
    ) -> KeyVerdict:
        ext = os.path.splitext(path)[1].lower()
        if ext in ('.xci', '.xcz'):
            return KeyVerdict('cannotCheck', part=part, reason=ext[1:].upper())
        try:
            with open(path, 'rb') as f:
                head = f.read(16)
                if len(head) < 16 or head[:4] != b'PFS0':
                    return KeyVerdict('cannotCheck', part=part, reason=os.path.basename(path))
                count, str_size, _ = struct.unpack_from('<III', head, 4)
                if count <= 0 or count > 4096 or str_size > 1_000_000:
                    return KeyVerdict('cannotCheck', part=part, reason=os.path.basename(path))
                entries_raw = f.read(count * 24)
                str_tab = f.read(str_size)
                if len(entries_raw) < count * 24 or len(str_tab) < str_size:
                    return KeyVerdict('cannotCheck', part=part, reason=os.path.basename(path))
                data_base = 16 + count * 24 + str_size

                tik_entry = None
                best_nca = None
                for i in range(count):
                    off, sz, soff, _ = struct.unpack_from('<QQII', entries_raw, i * 24)
                    end = str_tab.find(b'\x00', soff)
                    name = str_tab[soff:end if end != -1 else len(str_tab)].decode('utf-8', errors='replace')
                    low = name.lower()
                    if low.endswith('.tik') and sz >= 0x286:
                        tik_entry = (off, sz)
                    elif low.endswith('.nca') and not low.endswith('.cnmt.nca') and sz >= 0x400:
                        if best_nca is None or sz > best_nca[1]:
                            best_nca = (off, sz)
                    elif low.endswith('.ncz') and best_nca is None:
                        return KeyVerdict('cannotCheck', part=part, reason='NSZ')

                if best_nca is None:
                    return KeyVerdict('cannotCheck', part=part, reason=os.path.basename(path))

                tik_gen: int | None = None
                if tik_entry is not None:
                    f.seek(data_base + tik_entry[0] + 0x285)
                    b = f.read(1)
                    if len(b) == 1:
                        tik_gen = b[0]

                f.seek(data_base + best_nca[0] + 0x200)
                sector1 = f.read(0x200)
                if len(sector1) < 0x200:
                    return KeyVerdict('cannotCheck', part=part, reason=os.path.basename(path))
        except OSError:
            return KeyVerdict('cannotCheck', part=part, reason=os.path.basename(path))

        plain1 = decrypt_nca_sector(sector1, 1, header_key[:16], header_key[16:32])
        if plain1[:4] not in (b'NCA2', b'NCA3'):
            return KeyVerdict('wrongHeaderKey', part=part)

        old_gen = plain1[0x06]
        new_gen = plain1[0x20]
        raw_gen = max(old_gen, new_gen)
        gen = max(0, raw_gen - 1)
        key_idx = plain1[0x07]
        has_rights_id = any(b != 0 for b in plain1[0x30:0x40])

        if has_rights_id:
            tgen = max(0, tik_gen - 1) if tik_gen is not None else gen
            g_str = f'{tgen:02x}'
            tk = f'titlekek_{g_str}'
            mk = f'master_key_{g_str}'
            if tk not in keys and mk not in keys:
                return KeyVerdict('missingKey', part=part, key=mk, firmware=KeyCheck.firmware_for_key(mk))
        else:
            g_str = f'{gen:02x}'
            area = KeyCheck.KEY_AREA_NAMES[key_idx] if 0 <= key_idx < len(KeyCheck.KEY_AREA_NAMES) else 'application'
            ka = f'key_area_key_{area}_{g_str}'
            mk = f'master_key_{g_str}'
            if ka not in keys and mk not in keys:
                return KeyVerdict('missingKey', part=part, key=mk, firmware=KeyCheck.firmware_for_key(mk))

        return KeyVerdict('fits')


# ---------------------------------------------------------------------------
# CheatFiles (mirrors CheatFiles.swift)
# ---------------------------------------------------------------------------

@dataclass
class CheatItem:
    name: str
    lines: list[str] = field(default_factory=list)
    is_master: bool = False

    @property
    def is_valid(self) -> bool:
        if not self.lines:
            return False
        for ln in self.lines:
            parts = ln.split()
            if not parts or any(len(p) != 8 or not all(c in '0123456789abcdefABCDEF' for c in p) for p in parts):
                return False
        return True

    @property
    def runs_once(self) -> bool:
        if not self.is_valid:
            return False
        for ln in self.lines:
            first = ln.split()[0].upper()
            if not (first.startswith('04') or first.startswith('08')):
                return False
        return True


@dataclass
class CheatBuildFile:
    build_id: str
    path: str
    cheats: list[CheatItem]
    enabled: set[str]


class CheatFiles:
    BUILD_ID_RE = re.compile(r'^([0-9A-Fa-f]{16})\.txt$')

    @staticmethod
    def cheats_dir(title_id: str, work_dir: str | None = None, archive_dir: str | None = None, state_dir: Path | None = None) -> str:
        tid = title_id.upper()
        if archive_dir and os.path.isdir(archive_dir):
            return os.path.join(archive_dir, 'cheats')
        if work_dir and os.path.isdir(work_dir):
            return os.path.join(work_dir, 'cheats', tid)
        from . import library as lib
        base = state_dir or lib.default_state_dir()
        return str(base / 'cheats' / tid)

    @staticmethod
    def read_build_id(work_dir: str | None = None, ipa_path: str | None = None, title_id: str = '') -> str | None:
        # 1. Check <work_dir>/main.fixups.tsv or <work_dir>/<tid>/main.fixups.tsv
        candidates: list[str] = []
        if work_dir and os.path.isdir(work_dir):
            candidates.append(os.path.join(work_dir, 'main.fixups.tsv'))
            if title_id:
                candidates.append(os.path.join(work_dir, title_id.upper(), 'main.fixups.tsv'))
            try:
                for sub in os.listdir(work_dir):
                    p = os.path.join(work_dir, sub, 'main.fixups.tsv')
                    if os.path.isfile(p):
                        candidates.append(p)
            except OSError:
                pass

        for p in candidates:
            if os.path.isfile(p):
                bid = CheatFiles._parse_fixups_build_id_file(p)
                if bid:
                    return bid

        # 2. Check inside .ipa
        if ipa_path and os.path.isfile(ipa_path):
            try:
                with zipfile.ZipFile(ipa_path, 'r') as zf:
                    for name in zf.namelist():
                        if name.endswith('main.fixups.tsv'):
                            head = zf.read(name)[:1024].decode('utf-8', errors='replace')
                            bid = CheatFiles._parse_fixups_build_id_text(head)
                            if bid:
                                return bid
            except Exception:
                pass
        return None

    @staticmethod
    def _parse_fixups_build_id_file(path: str) -> str | None:
        try:
            with open(path, encoding='utf-8', errors='replace') as f:
                return CheatFiles._parse_fixups_build_id_text(f.read(1024))
        except OSError:
            return None

    @staticmethod
    def _parse_fixups_build_id_text(text: str) -> str | None:
        for line in text.splitlines():
            if line.startswith('# BUILD_ID'):
                parts = line.split()
                if len(parts) >= 3 and len(parts[2]) >= 16:
                    cand = parts[2][:16].upper()
                    if all(c in '0123456789ABCDEF' for c in cand):
                        return cand
        return None

    @staticmethod
    def parse_txt(text: str) -> list[CheatItem]:
        items: list[CheatItem] = []
        curr: CheatItem | None = None
        for raw in text.splitlines():
            line = raw.strip()
            if not line or line.startswith('#') or line.startswith('//'):
                continue
            if line.startswith('[') and line.endswith(']') and len(line) > 2:
                curr = CheatItem(name=line[1:-1].strip(), is_master=False)
                items.append(curr)
            elif line.startswith('{') and line.endswith('}') and len(line) > 2:
                curr = CheatItem(name=line[1:-1].strip(), is_master=True)
                items.append(curr)
            elif curr is not None:
                curr.lines.append(line)
        return items

    @staticmethod
    def load_folder(folder: str, title_id: str) -> tuple[bool, list[CheatBuildFile]]:
        """Return (master_enabled, build_files)."""
        tid = title_id.upper()
        off_marker = os.path.join(folder, f'.cheats-off-{tid}')
        master_on = not os.path.exists(off_marker)
        if not os.path.isdir(folder):
            return master_on, []
        files: list[CheatBuildFile] = []
        try:
            entries = sorted(os.listdir(folder))
        except OSError:
            return master_on, []
        for name in entries:
            m = CheatFiles.BUILD_ID_RE.match(name)
            if not m:
                continue
            bid = m.group(1).upper()
            txt_path = os.path.join(folder, name)
            en_path = os.path.join(folder, f'{bid}.enabled')
            try:
                text = Path(txt_path).read_text(encoding='utf-8', errors='replace')
            except OSError:
                continue
            cheats = CheatFiles.parse_txt(text)
            enabled: set[str] = set()
            if os.path.isfile(en_path):
                try:
                    for ln in Path(en_path).read_text(encoding='utf-8', errors='replace').splitlines():
                        s = ln.strip()
                        if s:
                            enabled.add(s)
                except OSError:
                    pass
            files.append(CheatBuildFile(build_id=bid, path=txt_path, cheats=cheats, enabled=enabled))
        return master_on, files

    @staticmethod
    def set_master(folder: str, title_id: str, enabled: bool) -> None:
        os.makedirs(folder, exist_ok=True)
        off_marker = os.path.join(folder, f'.cheats-off-{title_id.upper()}')
        if enabled:
            if os.path.exists(off_marker):
                try:
                    os.remove(off_marker)
                except OSError:
                    pass
        else:
            try:
                Path(off_marker).write_text('', encoding='utf-8')
            except OSError:
                pass

    @staticmethod
    def set_cheat_enabled(folder: str, build_id: str, cheat_name: str, enabled: bool) -> None:
        os.makedirs(folder, exist_ok=True)
        bid = build_id.upper()
        en_path = Path(folder) / f'{bid}.enabled'
        current: list[str] = []
        if en_path.is_file():
            try:
                current = [ln.strip() for ln in en_path.read_text(encoding='utf-8', errors='replace').splitlines() if ln.strip()]
            except OSError:
                current = []
        if enabled and cheat_name not in current:
            current.append(cheat_name)
        elif not enabled and cheat_name in current:
            current = [x for x in current if x != cheat_name]
        try:
            en_path.write_text('\n'.join(current) + ('\n' if current else ''), encoding='utf-8')
        except OSError:
            pass

    @staticmethod
    def import_paths(paths: list[str], dest_folder: str, title_id: str = '') -> tuple[int, list[str]]:
        """Import <buildID>.txt files from given file or directory paths. Return (imported_count, rejected_names)."""
        os.makedirs(dest_folder, exist_ok=True)
        imported = 0
        rejected: list[str] = []
        for p in paths:
            if os.path.isfile(p):
                bn = os.path.basename(p)
                m = CheatFiles.BUILD_ID_RE.match(bn)
                if m:
                    dst = os.path.join(dest_folder, f'{m.group(1).upper()}.txt')
                    try:
                        if os.path.abspath(p) != os.path.abspath(dst):
                            shutil.copy2(p, dst)
                        imported += 1
                    except OSError:
                        rejected.append(bn)
                else:
                    rejected.append(bn)
            elif os.path.isdir(p):
                for root, _, files in os.walk(p):
                    if title_id and len(title_id) == 16:
                        # If walking an Atmosphere SD card with many title IDs, filter by title_id if present in path
                        other_tids = re.findall(r'[0-9A-Fa-f]{16}', root)
                        if other_tids and all(t.upper() != title_id.upper() for t in other_tids):
                            continue
                    for fn in files:
                        m = CheatFiles.BUILD_ID_RE.match(fn)
                        if m:
                            src = os.path.join(root, fn)
                            dst = os.path.join(dest_folder, f'{m.group(1).upper()}.txt')
                            try:
                                if os.path.abspath(src) != os.path.abspath(dst):
                                    shutil.copy2(src, dst)
                                imported += 1
                            except OSError:
                                pass
        return imported, rejected


# ---------------------------------------------------------------------------
# Diagnostics (mirrors Diagnostics.swift)
# ---------------------------------------------------------------------------

class Diagnostics:
    @staticmethod
    def redact(text: str) -> str:
        home = os.path.expanduser('~')
        out = text
        if home:
            out = out.replace(home, '~')
            out = out.replace(home.replace('\\', '/'), '~')
        # Redact --keys <path>
        out = re.sub(r'(--keys\s+)("[^"]+"|\'[^\']+\'|\S+)', r'\1<redacted>', out)
        return out

    @staticmethod
    def format_report(
        app_version: str,
        repo_path: str,
        deps: list,
        last_log: str,
    ) -> str:
        lines = [
            '## NX2Apple Diagnostics',
            f'- Launcher: v{app_version} (Qt / {platform.system()})',
            f'- OS: {platform.platform()} ({platform.machine()})',
            f'- Python: {platform.python_version()}',
        ]
        if repo_path:
            lines.append(f'- Engine repo: `{Diagnostics.redact(repo_path)}`')
        else:
            lines.append('- Engine repo: (not set)')

        lines.append('')
        lines.append('### Dependencies')
        for d in deps:
            state = 'OK' if getattr(d, 'ok', False) else ('Optional' if not getattr(d, 'required', True) else 'MISSING')
            detail = Diagnostics.redact(str(getattr(d, 'detail', '')))
            lines.append(f'- {getattr(d, "name", "")}: [{state}] {detail}')

        if last_log.strip():
            tail = last_log.strip().splitlines()[-50:]
            redacted_tail = Diagnostics.redact('\n'.join(tail))
            lines.append('')
            lines.append('### Last Build Log (last 50 lines)')
            lines.append('```')
            lines.append(redacted_tail)
            lines.append('```')
        return '\n'.join(lines)
