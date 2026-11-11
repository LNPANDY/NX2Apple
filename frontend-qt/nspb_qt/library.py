"""Game library, Switch 2 folder/NUP scanner, artwork store, build-folder cleaner, game deletion, and drive copy.

Mirrors the Mac Swift launcher's Library.swift, GameFolder.swift, Artwork.swift,
FreeSpace.swift, GameDeletion.swift, and DriveCopy.swift for the Windows/Qt front end.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import stat
import struct
import tempfile
import threading
import time
import urllib.request
import uuid
import zipfile
from dataclasses import dataclass, field
from functools import lru_cache
from pathlib import Path
from typing import Callable

from . import inputs as _inputs
from . import platform_util as pu


def default_state_dir() -> Path:
    env_dir = os.environ.get('NSPB_STATE_DIR')
    if env_dir:
        return Path(env_dir)
    if os.environ.get('QT_QPA_PLATFORM') == 'offscreen':
        return Path(tempfile.gettempdir()) / f'nspb-offscreen-{os.getpid()}'
    if pu.IS_WIN:
        root = Path(os.environ.get('LOCALAPPDATA') or (Path.home() / 'AppData' / 'Local'))
        return root / 'NS Port Builder'
    return Path.home() / 'Library' / 'Application Support' / 'NS Port Builder'

_TID_RE = re.compile(r'\[([0-9A-Fa-f]{16})\]')
_TID_ANY_RE = re.compile(r'(?<![0-9A-Fa-f])([0-9A-Fa-f]{16})(?![0-9A-Fa-f])')
_BARE_TID_TOKEN_RE = re.compile(r'(?:^|[-_\s.])0[14][0-9A-Fa-f]{14}(?=$|[-_\s.])')
_BARE_VER_TOKEN_RE = re.compile(r'(?:^|[-_\s.])v\d+(?=$|[-_\s.])', re.IGNORECASE)
_VER_TAG_RE = re.compile(r'\[v\d+\]', re.IGNORECASE)
_PAREN_TAG_RE = re.compile(r'\([^)]*\)')
_BRACKET_TAG_RE = re.compile(r'\[[^\]]*\]')
_KIND_SUFFIX_RE = re.compile(r'[-_\s]*(upd|update|base|dlc|patch)\s*$', re.IGNORECASE)
_UNEXTRACTED_ARCHIVE_RE = re.compile(r'\.(?:7z|rar|r\d\d|00|\d{3})$', re.IGNORECASE)

PACKAGE_EXTS = {'.nsp', '.xci', '.nsz', '.xcz'}

BUNDLED_ART: dict[str, str] = {
    '01007EF00011E000': 'docs/images/botw-2.png',
    '0100F2C0115B6000': 'docs/images/totk-2.png',
    '0100000000010000': 'docs/images/odyssey-2.png',
    '010028600EBDA000': 'docs/images/3dw-2.png',
    '0100152000022000': 'docs/images/mk8d-2.png',
    '01006A800016E000': 'docs/images/ssbu-2.png',
    '0100E95004038000': 'docs/images/xc2-1.png',
    '010074F013262000': 'docs/images/xc3-2.png',
    '0100453019AA8000': 'docs/images/xcx-1.png',
    '0100A3D008C5C000': 'docs/images/sv-1.png',
    '01001F5010DFA000': 'docs/images/pla-2.png',
    '01008F6008C5E000': 'docs/images/sword-1.png',
    '0100000011D90000': 'docs/images/bd-2.png',
    '0100F43008C44000': 'docs/images/fe-engage-1.png',
    '010055D009F78000': 'docs/images/fe3h-1.png',
    '010085000B772000': 'docs/images/feth-1.png',
    '0100D71004694000': 'docs/images/p5r-1.png',
    '0100A6301214E000': 'docs/images/smt5v-1.png',
    '010025C00D410000': 'docs/images/acnh-1.png',
    '0100626011656000': 'docs/images/dread-1.png',
    '0100C4B0034B2000': 'docs/images/mp-remastered-1.png',
    '010016501B772000': 'docs/images/mp4-1.png',
    '010049900F546000': 'docs/images/kirby-fl-2.png',
    '01004D300C5AE000': 'docs/images/krtdld-1.png',
    '01008CF01BAAC000': 'docs/images/zelda-eow-1.png',
    '01006BB00C6F0000': 'docs/images/la-1.png',
    '01002DA013484000': 'docs/images/sshd-1.png',
    '010028A017892000': 'docs/images/pikmin4-1.png',
    '0100A3900C3E2000': 'docs/images/pm-ttyd-1.png',
    '0100F8F0000A2000': 'docs/images/smbw-2.png',
    '01001B300B9BE000': 'docs/images/lm3-1.png',
    '0100C25013430000': 'docs/images/bayo3-1.png',
    '01004A400D244000': 'docs/images/astral-chain-1.png',
    '0100D870045B6000': 'docs/images/nier-1.png',
    '0100E2F017572000': 'docs/images/unicorn-1.png',
    '010057D00ECE4000': 'docs/images/octopath2-1.png',
    '0100E66010ADE000': 'docs/images/triangle-1.png',
    '0100B7D01605C000': 'docs/images/starocean2r-1.png',
    '01006C300E9F0000': 'docs/images/dq11s-1.png',
    '01006C1017892000': 'docs/images/dq3hd2d-1.png',
    '0100B04011742000': 'docs/images/mhr-2.png',
    '0100770008DD8000': 'docs/images/mhgu-1.png',
    '010010A01D54E000': 'docs/images/silksong-1.png',
    '0100633007D48000': 'docs/images/hk-1.png',
    '0100535012974000': 'docs/images/hades-1.png',
    '0100F7B00BB5C000': 'docs/images/celeste-1.png',
    '0100CD301A5C8000': 'docs/images/balatro-1.png',
    '01002E7016C46000': 'docs/images/dave-1.png',
    '010040600C5CE000': 'docs/images/cuphead-1.png',
    '0100E6500B9AC000': 'docs/images/dead-cells-1.png',
    '01006C900EC02000': 'docs/images/subnautica-1.png',
    '01000890195B8000': 'docs/images/pop-tlc-1.png',
    '0100B8E016F76000': 'docs/images/dredge-1.png',
    '0100C1F0051B6000': 'docs/images/factorio-1.png',
    '01003D20137F8000': 'docs/images/splatoon3-1.png',
    '0100B0C0115B8000': 'docs/images/sky-1.png',
    '01005CA01580E000': 'docs/images/diablo3-1.png',
    '0100C4C00A922000': 'docs/images/darksouls-1.png',
    '0100DE900C3E4000': 'docs/images/skyrim-1.png',
    '0100830004FB6000': 'docs/images/doom-1.png',
    '01003D100E9C6000': 'docs/images/witcher3-1.png',
}


def format_bytes(size: int) -> str:
    if size <= 0:
        return '0 B'
    units = ['B', 'KB', 'MB', 'GB', 'TB']
    val = float(size)
    idx = 0
    while val >= 1024.0 and idx < len(units) - 1:
        val /= 1024.0
        idx += 1
    if idx == 0:
        return f'{int(val)} B'
    if val >= 100 or idx == 1:
        return f'{val:.0f} {units[idx]}'
    return f'{val:.1f} {units[idx]}'


def shell_ipa_path(shell_cache: str) -> str:
    """The shared app's one output: `<shell cache>/export/NX2Apple.ipa` (shell_export.ipa_path)."""
    return os.path.join(shell_cache, 'export', 'NX2Apple.ipa')


def one_game_ipa_path(out_dir: str, build_key: str) -> str:
    """Where `ipa_kind == 'oneGame'` writes its IPA: `<out dir>/<title ID>.ipa`."""
    if not out_dir or not build_key:
        return ''
    return os.path.join(out_dir, f'{build_key}.ipa')


@lru_cache(maxsize=128)
def _ipa_kind(path: str, signature: tuple[int, ...]) -> str:
    """Read only the ZIP directory, cached until the file's stat signature changes.

    Output filenames are configurable or profile-supplied, but the app bundle names are fixed
    by the two exporters. No executable or game data is read or extracted.
    """
    try:
        with zipfile.ZipFile(path) as ipa:
            names = set(ipa.namelist())
    except (OSError, zipfile.BadZipFile, NotImplementedError, UnicodeError):
        return ''
    kinds = [kind for kind, app in (('shared', 'DmShell'), ('oneGame', 'DmIOS'))
             if {f'Payload/{app}.app/Info.plist', f'Payload/{app}.app/{app}'} <= names]
    return kinds[0] if len(kinds) == 1 else ''


def reveal_ipa_path(*, ipa_kind: str, shell_cache: str, out_dir: str, build_key: str,
                    last_ipa: str = '', library_ipa: str = '') -> str:
    """The IPA that the selected kind produced, for "Show in folder".

    The two kinds write different files, and `Model.ipa_path` is whatever the last build of
    *either* kind left behind, so it cannot be asked first: after switching the kind it names the
    other mode's IPA. Prefer the selected kind's expected path, then the last build and library
    record. Check the app bundle in every candidate so profile-named one-game outputs and moved
    files still work without mistaking a remembered shared IPA for a one-game output.
    """
    if ipa_kind not in ('shared', 'oneGame'):
        return ''
    shared = shell_ipa_path(shell_cache) if shell_cache else ''
    want = shared if ipa_kind == 'shared' else one_game_ipa_path(out_dir, build_key)
    for candidate in (want, last_ipa, library_ipa):
        if not candidate:
            continue
        try:
            path = os.path.realpath(candidate)
            info = os.stat(path)
        except OSError:
            continue
        signature = (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns)
        if stat.S_ISREG(info.st_mode) and _ipa_kind(path, signature) == ipa_kind:
            return candidate
    return ''


def clean_game_name(filename: str) -> str:
    stem = os.path.splitext(os.path.basename(filename))[0]
    s = _BRACKET_TAG_RE.sub('', stem)
    s = _PAREN_TAG_RE.sub('', s)
    s = _BARE_TID_TOKEN_RE.sub(' ', s)
    s = _BARE_VER_TOKEN_RE.sub(' ', s)
    s = _KIND_SUFFIX_RE.sub('', s)
    s = re.sub(r'\s+', ' ', s.replace('_', ' ')).strip(' -._')
    return s or stem


def extract_title_id(path: str, keys_path: str = '') -> str | None:
    name = os.path.basename(path)
    m = _TID_RE.search(name)
    if m:
        return m.group(1).upper()
    m2 = _TID_ANY_RE.search(name)
    if m2:
        return m2.group(1).upper()
    ext = os.path.splitext(name)[1].lower()
    if ext in PACKAGE_EXTS and os.path.isfile(path):
        pkg_tid = _inputs.package_title_id(path, keys_path)
        if pkg_tid is not None:
            return f'{pkg_tid:016X}'
    return None


def base_family_id(tid: str) -> str:
    if len(tid) != 16:
        return tid.upper()
    try:
        val = int(tid, 16)
        return f'{val & ~0x1FFF:016X}'
    except ValueError:
        return tid.upper()


def classify_tid(tid: str) -> str:
    """Return 'base', 'update', or 'dlc' based on low 12 bits of Title ID."""
    if len(tid) != 16:
        return 'base'
    try:
        low = int(tid, 16) & 0xFFF
        if low == 0x000:
            return 'base'
        if low == 0x800:
            return 'update'
        return 'dlc'
    except ValueError:
        return 'base'


# ---------------------------------------------------------------------------
# Switch 2 GameFolder & NUP scanner (mirrors GameFolder.swift)
# ---------------------------------------------------------------------------

@dataclass
class GameFolderContents:
    folder: str
    title_id: int
    updates: list[tuple[int, str]] = field(default_factory=list)
    dlc: list[tuple[int, str]] = field(default_factory=list)
    nup: str | None = None

    @property
    def title_id_hex(self) -> str:
        return f'{self.title_id:016X}' if self.title_id else ''

    @property
    def base_path(self) -> str:
        if self.nup:
            return self.nup
        base = os.path.join(self.folder, 'base')
        if os.path.isfile(os.path.join(base, 'exefs', 'main.npdm')):
            return base
        return self.updates[-1][1] if self.updates else base

    @property
    def script_input(self) -> str:
        return self.nup or self.folder

    @property
    def has_title_id(self) -> bool:
        return self.title_id != 0

    @property
    def newest_update(self) -> tuple[int, str] | None:
        return self.updates[-1] if self.updates else None


@dataclass
class GameFolderProblem:
    kind: str  # 'missing', 'noBaseFolder', 'unreadableNPDM', 'notBaseTitle', 'packageBeside', 'dlcName', 'notDLC', 'dlcRomFS', 'notNUP', 'nupPartial', 'nupDamaged', 'severalNUPs'
    arg1: object = None
    arg2: object = None


class GameFolder:
    @staticmethod
    def nup_files(folder: str) -> list[str]:
        try:
            entries = sorted(os.listdir(folder))
        except OSError:
            return []
        out = []
        for name in entries:
            if not name.startswith('._') and name.lower().endswith('.nup'):
                full = os.path.join(folder, name)
                if os.path.isfile(full):
                    out.append(name)
        return out

    @staticmethod
    def is_direct_candidate(path: str) -> bool:
        if not path:
            return False
        return _inputs.is_direct_game_folder_candidate(path)

    @staticmethod
    def is_candidate(path: str) -> bool:
        if not path:
            return False
        return _inputs.is_game_folder_candidate(path)

    @staticmethod
    def program_id(npdm_bytes: bytes) -> int | None:
        if len(npdm_bytes) < 0x78 or npdm_bytes[:4] != b'META':
            return None
        off, size = struct.unpack_from('<II', npdm_bytes, 0x70)
        if size < 0x18 or off + 0x18 > len(npdm_bytes):
            return None
        if npdm_bytes[off:off + 4] != b'ACI0':
            return None
        return struct.unpack_from('<Q', npdm_bytes, off + 0x10)[0]

    @staticmethod
    def read_nup(path: str) -> GameFolderContents | GameFolderProblem:
        name = os.path.basename(path)
        try:
            size = os.path.getsize(path)
            with open(path, 'rb') as f:
                head = f.read(0x80)
                if len(head) != 0x80 or head[:3] != b'NUP' or head[3] != 1:
                    return GameFolderProblem('notNUP', name)
                expected_size = struct.unpack_from('<Q', head, 0x40)[0]
                if expected_size != size:
                    return GameFolderProblem('nupPartial', name)
                toc = struct.unpack_from('<Q', head, 0x08)[0]
                toc_size = struct.unpack_from('<Q', head, 0x10)[0]
                toc_sha = head[0x18:0x38]
                count = struct.unpack_from('<I', head, 0x48)[0]
                min_table = 0x30 + count * 0x40
                if count <= 0 or count >= 100_000 or toc + min_table > size:
                    return GameFolderProblem('notNUP', name)
                f.seek(toc)
                if any(toc_sha):
                    if not min_table <= toc_size <= (256 << 20) or toc + toc_size > size:
                        return GameFolderProblem('nupDamaged', name)
                    toc_bytes = f.read(toc_size)
                    if len(toc_bytes) != toc_size or hashlib.sha256(toc_bytes).digest() != toc_sha:
                        return GameFolderProblem('nupDamaged', name)
                    table = toc_bytes[:min_table]
                else:
                    table = f.read(min_table)
                if len(table) != min_table or table[:4] != b'TOC\x01':
                    return GameFolderProblem('notNUP', name)
        except OSError:
            return GameFolderProblem('notNUP', name)

        base = 0
        update_title = 0
        updates: list[tuple[int, str]] = []
        addons: list[int] = []
        for i in range(count):
            o = 0x30 + i * 0x40
            tid = struct.unpack_from('<Q', table, o)[0]
            ver = struct.unpack_from('<I', table, o + 20)[0]
            kind = table[o + 24]
            if kind == 0:
                base = tid
            elif kind == 1:
                updates.append((ver, path))
                if update_title == 0:
                    update_title = tid & ~0xFFF
            elif kind == 2:
                addons.append(tid)
        app = base if (base != 0 and (base & 0xFFF) == 0) else update_title
        updates.sort(key=lambda x: x[0])
        addons.sort()
        return GameFolderContents(
            folder=os.path.dirname(path),
            title_id=app,
            updates=updates,
            dlc=[(t, path) for t in addons],
            nup=path,
        )

    @staticmethod
    def scan(raw_folder: str) -> GameFolderContents | GameFolderProblem:
        folder = _inputs.resolve_game_folder(raw_folder)
        if folder.lower().endswith('.nup') and os.path.isfile(folder):
            return GameFolder.read_nup(folder)
        try:
            top = sorted(os.listdir(folder))
        except OSError:
            return GameFolderProblem('missing', 'base/exefs/main.npdm')

        for name in top:
            if not name.startswith('._') and os.path.splitext(name)[1].lower() in PACKAGE_EXTS:
                if os.path.isfile(os.path.join(folder, name)):
                    return GameFolderProblem('packageBeside', name)

        nups = GameFolder.nup_files(folder)
        if len(nups) > 1:
            return GameFolderProblem('severalNUPs', len(nups))
        if len(nups) == 1:
            return GameFolder.read_nup(os.path.join(folder, nups[0]))

        def subdirs(p: str) -> list[str]:
            if not os.path.isdir(p):
                return []
            try:
                return sorted(d for d in os.listdir(p) if not d.startswith('.') and os.path.isdir(os.path.join(p, d)))
            except OSError:
                return []

        updates_dir = os.path.join(folder, 'updates')
        versions = [v for v in subdirs(updates_dir) if v.isascii() and v.isdigit()]
        updates = sorted((int(v), os.path.join(updates_dir, v)) for v in versions)
        base_npdm = os.path.join(folder, 'base', 'exefs', 'main.npdm')
        if os.path.isfile(base_npdm):
            has_romfs = os.path.isdir(os.path.join(folder, 'base', 'romfs')) or any(
                os.path.isdir(os.path.join(u_path, 'romfs')) for _, u_path in updates
            )
            if not has_romfs:
                return GameFolderProblem('missing', 'base/romfs')
            npdm_path = base_npdm
        else:
            code_updates = [(ver, u_path) for ver, u_path in updates if os.path.isfile(os.path.join(u_path, 'exefs', 'main.npdm'))]
            if code_updates:
                full_updates = [(ver, u_path) for ver, u_path in code_updates if os.path.isdir(os.path.join(u_path, 'romfs'))]
                if not full_updates:
                    return GameFolderProblem('missing', f'updates/{code_updates[-1][0]}/romfs')
                npdm_path = os.path.join(full_updates[-1][1], 'exefs', 'main.npdm')
            else:
                if os.path.isfile(os.path.join(folder, 'exefs', 'main.npdm')) and not os.path.exists(os.path.join(folder, 'base')):
                    return GameFolderProblem('noBaseFolder')
                return GameFolderProblem('missing', 'base/exefs/main.npdm')

        try:
            with open(npdm_path, 'rb') as f:
                data = f.read()
        except OSError:
            return GameFolderProblem('unreadableNPDM')

        app = GameFolder.program_id(data)
        if app is None:
            return GameFolderProblem('unreadableNPDM')
        if (app & 0xFFF) != 0:
            return GameFolderProblem('notBaseTitle', app)

        updates = sorted((int(v), os.path.join(updates_dir, v)) for v in versions)
        dlc: list[tuple[int, str]] = []
        dlc_dir = os.path.join(folder, 'dlc')
        for name in subdirs(dlc_dir):
            dpath = os.path.join(dlc_dir, name)
            if len(name) > 16:
                return GameFolderProblem('dlcName', name)
            try:
                tid = int(name, 16)
            except ValueError:
                return GameFolderProblem('dlcName', name)
            if not (tid > app + 0x1000 and tid - app - 0x1000 <= 2000):
                return GameFolderProblem('notDLC', name, tid)
            numbered = [sub for sub in subdirs(dpath) if os.path.isdir(os.path.join(dpath, sub, 'romfs'))]
            cnt = len(numbered) if numbered else (1 if os.path.isdir(os.path.join(dpath, 'romfs')) else 0)
            if cnt != 1:
                return GameFolderProblem('dlcRomFS', name, cnt)
            dlc.append((tid, dpath))

        dlc.sort(key=lambda x: x[0])
        return GameFolderContents(folder=folder, title_id=app, updates=updates, dlc=dlc)

    @staticmethod
    def profile_name(title_id: str | int, repo_path: str) -> str | None:
        if not repo_path:
            return None
        tid_hex = f'{title_id:016X}' if isinstance(title_id, int) else title_id.upper()
        tsv = os.path.join(repo_path, 'dm', 'games', tid_hex, 'game.tsv')
        if not os.path.isfile(tsv):
            return None
        try:
            with open(tsv, encoding='utf-8', errors='replace') as f:
                for line in f:
                    if line.startswith('name\t'):
                        val = line[5:].strip()
                        return val if val else None
        except OSError:
            pass
        return None

    @staticmethod
    def profile_is_switch2(title_id: str, repo_path: str) -> bool:
        if not repo_path or len(title_id) != 16:
            return False
        tsv = os.path.join(repo_path, 'dm', 'games', title_id.upper(), 'game.tsv')
        if not os.path.isfile(tsv):
            return False
        try:
            with open(tsv, encoding='utf-8', errors='replace') as f:
                first = f.readline()
                return first.startswith('#') and '(Switch 2' in first
        except OSError:
            return False

    @staticmethod
    def engine_has_profile(title_id: int | str, repo_path: str) -> bool:
        if not repo_path:
            return False
        tid_hex = f'{title_id:016X}' if isinstance(title_id, int) else title_id.upper()
        return os.path.isfile(os.path.join(repo_path, 'dm', 'games', tid_hex, 'game.tsv'))

    @staticmethod
    def engine_builds_folders(repo_path: str) -> bool:
        return bool(repo_path and os.path.isfile(os.path.join(repo_path, 'scripts', 'pack_dump.py')))

    @staticmethod
    def engine_builds_nups(repo_path: str) -> bool:
        return bool(repo_path and os.path.isfile(os.path.join(repo_path, 'scripts', 'pack_nup.py')))


# ---------------------------------------------------------------------------
# LibraryGame & GameLibrary (mirrors Library.swift)
# ---------------------------------------------------------------------------

@dataclass
class LibraryGame:
    title_id: str
    name: str
    app_path: str = ''
    ipa_path: str = ''
    archive_path: str = ''
    ios_app_path: str = ''
    installed_device: str = ''
    output_dir: str = ''
    inputs: dict[str, list[str]] = field(default_factory=dict)
    added_at: float = field(default_factory=time.time)
    last_built_at: float | None = None
    built_chain_tag: str = ''
    _extra: dict = field(default_factory=dict, repr=False, compare=False)

    @property
    def id(self) -> str:
        return self.title_id

    @property
    def has_app(self) -> bool:
        return bool(self.app_path and os.path.exists(self.app_path))

    @property
    def has_ipa(self) -> bool:
        return bool(self.ipa_path and os.path.isfile(self.ipa_path))

    @property
    def has_ios_app(self) -> bool:
        return bool(self.ios_app_path and os.path.exists(self.ios_app_path))

    @property
    def has_archive(self) -> bool:
        return bool(self.archive_path and os.path.isdir(self.archive_path))

    @property
    def has_any_build(self) -> bool:
        return self.has_app or self.has_ipa or self.has_ios_app or self.has_archive

    @property
    def has_inputs(self) -> bool:
        base = (self.inputs.get('base') or [''])[0]
        if not base or not os.path.exists(base):
            return False
        if GameFolder.is_candidate(base):
            return True
        keys = (self.inputs.get('keys') or [''])[0]
        return bool(keys and os.path.isfile(keys))

    @property
    def can_rebuild(self) -> bool:
        base = (self.inputs.get('base') or [''])[0]
        return bool(base and os.path.exists(base))

    @property
    def work_dir(self) -> str | None:
        out = self.output_dir
        if not out:
            base = (self.inputs.get('base') or [''])[0]
            if base:
                out = os.path.dirname(base)
        if not out:
            return None
        return os.path.join(out, f'{self.title_id}_build')

    def is_switch2(self, repo_path: str) -> bool:
        return GameFolder.profile_is_switch2(self.title_id, repo_path)

    def to_dict(self) -> dict:
        out = dict(self._extra)
        if not out.get('id'):
            out['id'] = str(uuid.uuid4()).upper()
            self._extra['id'] = out['id']
        out.update({
            'titleID': self.title_id,
            'name': self.name,
            'appPath': self.app_path,
            'ipaPath': self.ipa_path,
            'archivePath': self.archive_path,
            'iosAppPath': self.ios_app_path,
            'installedDevice': self.installed_device,
            'outputDir': self.output_dir,
            'inputs': self.inputs,
            'addedAt': self.added_at,
            'lastBuiltAt': self.last_built_at,
            'builtChainTag': self.built_chain_tag,
        })
        return out

    @classmethod
    def from_dict(cls, d: dict) -> LibraryGame:
        app_path = str(d.get('appPath') or '')
        known = {
            'titleID', 'title_id', 'name', 'appPath', 'ipaPath', 'archivePath',
            'iosAppPath', 'installedDevice', 'outputDir', 'inputs', 'addedAt',
            'lastBuiltAt', 'builtChainTag',
        }
        extra = {k: v for k, v in d.items() if k not in known}
        return cls(
            title_id=str(d.get('titleID') or d.get('title_id') or '').upper(),
            name=str(d.get('name') or ''),
            app_path=app_path if os.path.isdir(app_path) else '',
            ipa_path=str(d.get('ipaPath') or ''),
            archive_path=str(d.get('archivePath') or ''),
            ios_app_path=str(d.get('iosAppPath') or ''),
            installed_device=str(d.get('installedDevice') or ''),
            output_dir=str(d.get('outputDir') or d.get('outputDirectory') or ''),
            inputs=dict(d.get('inputs') or {}),
            added_at=float(d.get('addedAt') or time.time()),
            last_built_at=float(d['lastBuiltAt']) if d.get('lastBuiltAt') is not None else None,
            built_chain_tag=str(d.get('builtChainTag') or ''),
            _extra=extra,
        )


@dataclass(frozen=True)
class SkippedFile:
    path: str
    name: str
    kind: str  # 'orphan' or 'archive'


def _atomic_write_text(dest: Path, text: str) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = dest.parent / f'.{dest.name}.{uuid.uuid4().hex}.tmp'
    try:
        with open(tmp_path, 'w', encoding='utf-8') as f:
            f.write(text)
            f.flush()
            try:
                os.fsync(f.fileno())
            except OSError:
                pass
        os.replace(tmp_path, dest)
    except BaseException:
        try:
            if tmp_path.exists():
                tmp_path.unlink()
        except OSError:
            pass
        raise


class GameLibrary:
    def __init__(self, state_dir: Path | None = None) -> None:
        self.state_dir = state_dir or default_state_dir()
        self.file_path = self.state_dir / 'library.json'
        self.games: list[LibraryGame] = []
        self.skipped_files: list[SkippedFile] = []
        self.selected_id: str | None = None
        self.games_folder: str = ''
        self._extra_top: dict = {}
        self.load()

    @property
    def selected(self) -> LibraryGame | None:
        if self.selected_id:
            for g in self.games:
                if g.title_id == self.selected_id:
                    return g
        return self.games[0] if self.games else None

    def select(self, title_id: str | None) -> None:
        self.selected_id = title_id.upper() if title_id else None

    def load(self) -> None:
        if not self.file_path.is_file():
            return
        try:
            raw = json.loads(self.file_path.read_text(encoding='utf-8'))
            if isinstance(raw, list):
                self.games = [LibraryGame.from_dict(x) for x in raw if isinstance(x, dict)]
            elif isinstance(raw, dict):
                self.games = [LibraryGame.from_dict(x) for x in raw.get('games', []) if isinstance(x, dict)]
                self.games_folder = str(raw.get('gamesFolder') or raw.get('folder') or '')
                self.selected_id = raw.get('selectedID')
                self._extra_top = {
                    k: v for k, v in raw.items()
                    if k not in ('games', 'gamesFolder', 'selectedID')
                }
            if self.games and not self.selected_id:
                self.selected_id = self.games[0].title_id
        except Exception:
            pass

    def save(self) -> None:
        try:
            payload = dict(self._extra_top)
            if 'folder' in payload or self.games_folder:
                payload['folder'] = self.games_folder or payload.get('folder', '')
            payload.update({
                'gamesFolder': self.games_folder,
                'selectedID': self.selected_id,
                'games': [g.to_dict() for g in self.games],
            })
            _atomic_write_text(self.file_path, json.dumps(payload, indent=2, ensure_ascii=False))
        except OSError:
            pass

    def set_games_folder(self, folder: str, repo_path: str = '', default_keys: str = '') -> None:
        self.games_folder = folder
        if folder and os.path.isdir(folder):
            self.rescan_games_folder(repo_path=repo_path, default_keys=default_keys)
        else:
            self.skipped_files = []
        self.save()

    def remove(self, title_id: str) -> None:
        tid = title_id.upper()
        self.games = [g for g in self.games if g.title_id != tid]
        if self.selected_id == tid:
            self.selected_id = self.games[0].title_id if self.games else None
        self.save()

    def upsert(self, game: LibraryGame) -> LibraryGame:
        tid = game.title_id.upper()
        game.title_id = tid
        for i, existing in enumerate(self.games):
            if existing.title_id == tid:
                if not game.name or game.name == tid:
                    game.name = existing.name
                if not game.app_path and existing.has_app:
                    game.app_path = existing.app_path
                if not game.ipa_path:
                    game.ipa_path = existing.ipa_path
                if not game.archive_path:
                    game.archive_path = existing.archive_path
                if not game.ios_app_path:
                    game.ios_app_path = existing.ios_app_path
                if not game.installed_device:
                    game.installed_device = existing.installed_device
                if not game.output_dir:
                    game.output_dir = existing.output_dir
                if not game.inputs:
                    game.inputs = existing.inputs
                if game.last_built_at is None:
                    game.last_built_at = existing.last_built_at
                if existing._extra:
                    merged_extra = dict(existing._extra)
                    merged_extra.update(game._extra)
                    game._extra = merged_extra
                self.games[i] = game
                self.save()
                return game
        self.games.insert(0, game)
        if not self.selected_id:
            self.selected_id = game.title_id
        self.save()
        return game

    def remember_inputs(
        self,
        base_path: str,
        update_path: str,
        dlc_paths: list[str],
        keys_path: str,
        output_dir: str,
        repo_path: str = '',
        title_id: str | None = None,
    ) -> LibraryGame | None:
        if not base_path:
            return None
        tid = title_id or ''
        name = ''
        if not tid and GameFolder.is_candidate(base_path):
            res = GameFolder.scan(base_path if not os.path.basename(base_path) == 'base' else os.path.dirname(base_path))
            if isinstance(res, GameFolderContents) and res.has_title_id:
                tid = res.title_id_hex
                name = GameFolder.profile_name(tid, repo_path) or clean_game_name(res.folder)
        if not tid:
            tid_raw = extract_title_id(base_path, keys_path=keys_path)
            if tid_raw:
                tid = base_family_id(tid_raw)
        if not tid:
            return None
        if not name:
            name = GameFolder.profile_name(tid, repo_path) or (tid if title_id else clean_game_name(base_path))

        inputs: dict[str, list[str]] = {'base': [base_path]}
        if update_path:
            inputs['update'] = [update_path]
        if dlc_paths:
            inputs['dlc'] = list(dlc_paths)
        if keys_path:
            inputs['keys'] = [keys_path]

        out = output_dir or os.path.dirname(base_path)
        ipa_candidate = os.path.join(out, f'{tid if title_id else name}.ipa')
        archive_candidate = os.path.join(out, 'games', tid)
        game = LibraryGame(
            title_id=tid,
            name=name,
            ipa_path=ipa_candidate if os.path.isfile(ipa_candidate) else '',
            archive_path=archive_candidate if os.path.isdir(archive_candidate) else '',
            output_dir=output_dir,
            inputs=inputs,
        )
        g = self.upsert(game)
        self.selected_id = g.title_id
        self.save()
        return g

    def record_completed_ios(
        self,
        ipa_path: str = '',
        archive_path: str = '',
        base_path: str = '',
        output_dir: str = '',
        inputs: dict[str, list[str]] | None = None,
        repo_path: str = '',
        title_id: str | None = None,
        name: str = '',
        keys_path: str = '',
    ) -> LibraryGame | None:
        inputs_dict = dict(inputs or {})
        if keys_path and 'keys' not in inputs_dict:
            inputs_dict['keys'] = [keys_path]
        if base_path and 'base' not in inputs_dict:
            inputs_dict['base'] = [base_path]
        tid = ''
        if title_id and re.fullmatch(r'[0-9A-Fa-f]{16}', title_id.strip()):
            tid = title_id.strip().upper()
        elif title_id:
            tid = title_id.strip()
        if not tid and archive_path:
            bn = os.path.basename(archive_path.rstrip('/\\'))
            if re.fullmatch(r'[0-9A-Fa-f]{16}', bn):
                tid = bn.upper()
        keys_hint = keys_path or (inputs_dict.get('keys') or [''])[0]
        if not tid and base_path:
            if GameFolder.is_candidate(base_path):
                res = GameFolder.scan(base_path if os.path.basename(base_path) != 'base' else os.path.dirname(base_path))
                if isinstance(res, GameFolderContents) and res.has_title_id:
                    tid = res.title_id_hex
            if not tid:
                tid_raw = extract_title_id(base_path, keys_path=keys_hint)
                if tid_raw:
                    tid = base_family_id(tid_raw)
        if not tid and ipa_path:
            tid_raw = extract_title_id(ipa_path, keys_path=keys_hint)
            if tid_raw:
                tid = base_family_id(tid_raw)
        if not tid:
            tid = _inputs.build_key(base_path or ipa_path or 'game', keys_hint).upper()

        resolved_name = name.strip() or GameFolder.profile_name(tid, repo_path)
        if not resolved_name:
            if ipa_path and os.path.basename(ipa_path).lower() != 'nx2apple.ipa':
                resolved_name = clean_game_name(ipa_path)
            elif base_path:
                resolved_name = clean_game_name(base_path)
            else:
                resolved_name = tid

        game = LibraryGame(
            title_id=tid,
            name=resolved_name,
            ipa_path=ipa_path if (ipa_path and os.path.isfile(ipa_path)) else '',
            archive_path=archive_path if (archive_path and os.path.isdir(archive_path)) else '',
            output_dir=output_dir,
            inputs=inputs_dict,
            last_built_at=time.time(),
        )
        g = self.upsert(game)
        self.selected_id = g.title_id
        self.save()
        return g

    def rescan_games_folder(self, repo_path: str = '', default_keys: str = '') -> int:
        folder = self.games_folder
        if not folder or not os.path.isdir(folder):
            self.skipped_files = []
            return 0
        skipped: list[SkippedFile] = []
        discovered = self.discover_in_folder(
            folder,
            repo_path=repo_path,
            default_keys=default_keys,
            out_skipped=skipped,
        )
        self.skipped_files = skipped
        count = 0
        for g in discovered:
            self.upsert(g)
            count += 1
        self.save()
        return count

    @staticmethod
    def discover_in_folder(
        folder: str,
        repo_path: str = '',
        default_keys: str = '',
        *,
        out_skipped: list[SkippedFile] | None = None,
    ) -> list[LibraryGame]:
        if not folder or not os.path.isdir(folder):
            return []
        families: dict[str, dict[str, list[str]]] = {}
        names: dict[str, str] = {}
        ipas: dict[str, str] = {}
        archives: dict[str, str] = {}
        skipped_archives: list[SkippedFile] = []
        pending_packages: list[tuple[str, str]] = []
        found_keys = default_keys if (default_keys and os.path.isfile(default_keys)) else ''

        def walk_dir(curr: str, depth: int) -> None:
            nonlocal found_keys
            if depth > 3:
                return
            if _inputs.is_dump_directory(curr) if depth == 0 else GameFolder.is_direct_candidate(curr):
                res = GameFolder.scan(curr)
                if isinstance(res, GameFolderContents) and res.has_title_id:
                    tid = res.title_id_hex
                    families.setdefault(tid, {})['base'] = [res.script_input]
                    if res.newest_update:
                        families[tid]['update'] = [res.newest_update[1]]
                    if res.dlc:
                        families[tid]['dlc'] = [p for _, p in res.dlc]
                    names[tid] = GameFolder.profile_name(tid, repo_path) or clean_game_name(res.folder)
                return

            try:
                entries = sorted(os.listdir(curr))
            except OSError:
                return

            for entry in entries:
                if entry.startswith('.'):
                    continue
                full = os.path.join(curr, entry)
                low = entry.lower()
                if os.path.isfile(full):
                    if low in ('prod.keys', 'keys.txt') or low.endswith('.keys'):
                        if not found_keys:
                            found_keys = full
                        continue
                    ext = os.path.splitext(low)[1]
                    if ext == '.nup':
                        res = GameFolder.read_nup(full)
                        if isinstance(res, GameFolderContents) and res.has_title_id:
                            tid = res.title_id_hex
                            families.setdefault(tid, {})['base'] = [full]
                            names[tid] = GameFolder.profile_name(tid, repo_path) or clean_game_name(full)
                    elif ext in PACKAGE_EXTS:
                        pending_packages.append((full, entry))
                    elif ext == '.ipa':
                        tid_raw = extract_title_id(entry)
                        if tid_raw:
                            ipas[base_family_id(tid_raw)] = full
                    elif _UNEXTRACTED_ARCHIVE_RE.search(low):
                        skipped_archives.append(SkippedFile(path=full, name=entry, kind='archive'))
                elif os.path.isdir(full):
                    if entry.endswith('_build'):
                        continue
                    if entry == 'games':
                        try:
                            for sub in os.listdir(full):
                                sub_full = os.path.join(full, sub)
                                if len(sub) == 16 and os.path.isdir(sub_full):
                                    archives[sub.upper()] = sub_full
                        except OSError:
                            pass
                        continue
                    walk_dir(full, depth + 1)

        walk_dir(folder, 0)

        for full, entry in pending_packages:
            tid_raw = extract_title_id(full, keys_path=found_keys)
            if tid_raw:
                fam = base_family_id(tid_raw)
                kind = classify_tid(tid_raw)
                slot = families.setdefault(fam, {})
                if kind == 'base':
                    slot['base'] = [full]
                    names[fam] = GameFolder.profile_name(fam, repo_path) or clean_game_name(entry)
                elif kind == 'update':
                    slot.setdefault('update', []).append(full)
                else:
                    slot.setdefault('dlc', []).append(full)

        orphan_skipped: list[SkippedFile] = []
        results: list[LibraryGame] = []
        for tid, slots in families.items():
            if 'base' not in slots:
                for p in slots.get('update', []) + slots.get('dlc', []):
                    orphan_skipped.append(SkippedFile(path=p, name=os.path.basename(p), kind='orphan'))
                continue
            if found_keys and 'keys' not in slots:
                slots['keys'] = [found_keys]
            if 'update' in slots and len(slots['update']) > 1:
                slots['update'] = [sorted(slots['update'], key=lambda p: (_inputs.update_version(os.path.basename(p)), p))[-1]]
            gname = names.get(tid) or GameFolder.profile_name(tid, repo_path) or tid
            base_dir = os.path.dirname(slots['base'][0])
            other_files = slots.get('update', []) + slots.get('dlc', [])
            if other_files and any(not os.path.abspath(p).startswith(os.path.abspath(base_dir) + os.sep) for p in other_files):
                parent_dir = os.path.dirname(base_dir)
                if parent_dir and os.path.abspath(parent_dir).startswith(os.path.abspath(folder)):
                    base_dir = parent_dir
            ipa = ipas.get(tid, '')
            if not ipa:
                cand = os.path.join(base_dir, f'{gname}.ipa')
                if os.path.isfile(cand):
                    ipa = cand
            arch = archives.get(tid, '')
            if not arch:
                cand_arch = os.path.join(base_dir, 'games', tid)
                if os.path.isdir(cand_arch):
                    arch = cand_arch
            results.append(
                LibraryGame(
                    title_id=tid,
                    name=gname,
                    ipa_path=ipa,
                    archive_path=arch,
                    output_dir=base_dir,
                    inputs=slots,
                )
            )
        if out_skipped is not None:
            seen_paths: set[str] = set()
            for item in orphan_skipped + skipped_archives:
                norm = os.path.normcase(os.path.abspath(item.path))
                if norm not in seen_paths:
                    seen_paths.add(norm)
                    out_skipped.append(item)
        return results


# ---------------------------------------------------------------------------
# ArtworkStore & eShop Banner fetcher (mirrors Artwork.swift & BannerPick.swift)
# ---------------------------------------------------------------------------

class ArtworkStore:
    TITLEDB_URL = 'https://raw.githubusercontent.com/blawar/titledb/master/US.en.json'
    FALLBACK_BANNERS: dict[str, str] = {
        '0400245021D2C000': 'https://cdn2.steamgriddb.com/grid/4019460f699df3ca57bb36a6cc8b1ce5.png',  # Yoshi and the Mysterious Book
        '0400380020056000': 'https://cdn2.steamgriddb.com/grid/220a08c045f283231e519ed83cd21466.png',  # Splatoon Raiders
        '04003F40232DE000': 'https://cdn2.steamgriddb.com/grid/30430599d3640690ebddef63609c5f31.png',  # Hyrule Warriors: Age of Imprisonment
        '0400486024DEC000': 'https://cdn2.steamgriddb.com/grid/925526bdfb5910517494acb4db2537d5.png',  # The Legend of Zelda: Ocarina of Time
        '04007EF01F8AE000': 'https://cdn2.steamgriddb.com/grid/f73cc1e0813d90b30a22ca9af2e9c8b0.png',  # Fire Emblem: Fortune's Weave
        '0400A3A01EE4C000': 'https://cdn2.steamgriddb.com/grid/00b97e285bef52b2826cfbeecd4d30f7.png',  # Pokémon Pokopia
        '0400D4201C6EA000': 'https://cdn2.steamgriddb.com/grid/eb3353d1afeb0b6b1c6507bb5d39c757.png',  # Mario Tennis Fever
        '0400E88025B1A000': 'https://cdn2.steamgriddb.com/grid/a82908cc940793dc1d63acfc0218b2f9.jpg',  # Star Fox
    }

    def __init__(self, state_dir: Path | None = None, on_updated: Callable[[str], None] | None = None) -> None:
        self.state_dir = state_dir or default_state_dir()
        self.banners_dir = self.state_dir / 'banners'
        self.custom_file = self.state_dir / 'custom_artwork.json'
        self.on_updated = on_updated
        self.custom_paths: dict[str, str] = {}
        self._fetching: set[str] = set()
        self._titledb_cache: dict[str, str] | None = None
        self._lock = threading.Lock()
        self._index_lock = threading.Lock()
        self._load_custom()

    def _load_custom(self) -> None:
        if self.custom_file.is_file():
            try:
                data = json.loads(self.custom_file.read_text(encoding='utf-8'))
                if isinstance(data, dict):
                    self.custom_paths = {k.upper(): str(v) for k, v in data.items() if v}
            except Exception:
                pass

    def _save_custom(self) -> None:
        try:
            self.state_dir.mkdir(parents=True, exist_ok=True)
            self.custom_file.write_text(json.dumps(self.custom_paths, indent=2), encoding='utf-8')
        except OSError:
            pass

    def set_custom(self, title_id: str, image_path: str) -> None:
        tid = title_id.upper()
        self.custom_paths[tid] = image_path
        self._save_custom()
        if self.on_updated:
            self.on_updated(tid)

    def clear_custom(self, title_id: str) -> None:
        tid = title_id.upper()
        self.custom_paths.pop(tid, None)
        self._save_custom()
        if self.on_updated:
            self.on_updated(tid)

    def has_custom(self, title_id: str) -> bool:
        tid = title_id.upper()
        p = self.custom_paths.get(tid, '')
        return bool(p and os.path.isfile(p))

    def image_path(self, title_id: str, repo_path: str = '') -> str | None:
        tid = title_id.upper()
        custom = self.custom_paths.get(tid, '')
        if custom and os.path.isfile(custom):
            return custom
        cached = self.banners_dir / f'{tid}.jpg'
        if cached.is_file():
            return str(cached)
        cached_png = self.banners_dir / f'{tid}.png'
        if cached_png.is_file():
            return str(cached_png)
        if repo_path:
            gal = self._gallery_map(repo_path)
            if tid in gal:
                p = os.path.join(repo_path, 'docs', 'images', gal[tid])
                if os.path.isfile(p):
                    return p
            if tid in BUNDLED_ART:
                bundled = os.path.join(repo_path, BUNDLED_ART[tid])
                if os.path.isfile(bundled):
                    return bundled
        return None

    def _gallery_map(self, repo_path: str) -> dict[str, str]:
        cache: dict[str, dict[str, str]] = getattr(self, '_gal_cache', {})
        if repo_path in cache:
            return cache[repo_path]
        out: dict[str, str] = {}
        tsv = os.path.join(repo_path, 'docs', 'images', 'gallery.tsv')
        if os.path.isfile(tsv):
            try:
                with open(tsv, encoding='utf-8', errors='replace') as f:
                    for line in f:
                        if not line or line.startswith('#'):
                            continue
                        parts = line.rstrip('\r\n').split('\t')
                        if len(parts) >= 4 and len(parts[3]) == 16:
                            out[parts[3].upper()] = parts[0]
            except OSError:
                pass
        cache[repo_path] = out
        self._gal_cache = cache
        return out

    def request_banner_async(self, title_id: str) -> None:
        if os.environ.get('QT_QPA_PLATFORM') == 'offscreen':
            return
        tid = title_id.upper()
        if self.has_custom(tid) or (self.banners_dir / f'{tid}.jpg').is_file() or (self.banners_dir / f'{tid}.png').is_file():
            return
        with self._lock:
            if tid in self._fetching:
                return
            self._fetching.add(tid)

        def worker() -> None:
            try:
                self._fetch_one(tid)
            finally:
                with self._lock:
                    self._fetching.discard(tid)

        threading.Thread(target=worker, daemon=True).start()

    def _load_or_fetch_index(self) -> dict[str, str]:
        with self._index_lock:
            if self._titledb_cache is not None:
                return self._titledb_cache
            index_file = self.banners_dir / 'banners_index.json'
            mapping: dict[str, str] = {}
            if index_file.is_file():
                try:
                    loaded = json.loads(index_file.read_text(encoding='utf-8'))
                    if isinstance(loaded, dict):
                        mapping = {str(k).upper(): str(v) for k, v in loaded.items() if k and v}
                except Exception:
                    mapping = {}
            if mapping:
                self._titledb_cache = mapping
                return mapping
            try:
                req = urllib.request.Request(self.TITLEDB_URL, headers={'User-Agent': 'NX2Apple/1.1'})
                with urllib.request.urlopen(req, timeout=15) as resp:
                    raw = json.loads(resp.read().decode('utf-8', errors='replace'))
                if isinstance(raw, dict):
                    for entry in raw.values():
                        if isinstance(entry, dict):
                            etid = str(entry.get('id') or '').upper()
                            burl = str(entry.get('bannerUrl') or '')
                            if len(etid) == 16 and burl.startswith('http'):
                                mapping[etid] = burl
                    _atomic_write_text(index_file, json.dumps(mapping))
                    self._titledb_cache = mapping
            except Exception:
                pass
            return mapping

    def _fetch_one(self, tid: str) -> None:
        mapping = self._load_or_fetch_index()
        url = mapping.get(tid) or self.FALLBACK_BANNERS.get(tid)
        if not url:
            return
        try:
            req = urllib.request.Request(url, headers={'User-Agent': 'NX2Apple/1.1'})
            with urllib.request.urlopen(req, timeout=15) as resp:
                data = resp.read()
            if len(data) > 1024:
                self.banners_dir.mkdir(parents=True, exist_ok=True)
                ext = 'png' if data[:8] == b'\x89PNG\r\n\x1a\n' else 'jpg'
                dest = self.banners_dir / f'{tid}.{ext}'
                tmp_dest = self.banners_dir / f'.{tid}.{uuid.uuid4().hex}.{ext}.tmp'
                try:
                    tmp_dest.write_bytes(data)
                    os.replace(tmp_dest, dest)
                finally:
                    if tmp_dest.exists():
                        try:
                            tmp_dest.unlink()
                        except OSError:
                            pass
                if self.on_updated:
                    self.on_updated(tid)
        except Exception:
            pass


# ---------------------------------------------------------------------------
# BuildFolder Space Measurement & Cleanup (mirrors FreeSpace.swift)
# ---------------------------------------------------------------------------

@dataclass
class BuildFolderItem:
    part: str  # 'extracted', 'shaders', 'oldShaders', 'xcode', 'caches'
    bytes: int
    paths: list[str]


@dataclass
class BuildFolderReport:
    folder: str
    items: list[BuildFolderItem]
    kept_bytes: int

    @property
    def total_freeable(self) -> int:
        # oldShaders is a subset of shaders
        return sum(i.bytes for i in self.items if i.part != 'oldShaders')


class BuildFolder:
    PART_ORDER = ['extracted', 'shaders', 'oldShaders', 'xcode', 'caches']
    _CHAIN_VER_RE = re.compile(r'^(?:mac-)?(b-[0-9a-f]{12})(?:\.key|\.img(?:\.part)?)?$')

    @staticmethod
    def size(path: str, seen_inodes: set[tuple[int, int]] | None = None) -> int:
        if not path or not os.path.lexists(path):
            return 0
        seen = seen_inodes if seen_inodes is not None else set()
        try:
            st0 = os.lstat(path)
        except OSError:
            return 0
        if stat.S_ISLNK(st0.st_mode):
            return 0
        if stat.S_ISREG(st0.st_mode):
            if st0.st_ino != 0:
                ident = (st0.st_dev, st0.st_ino)
                if ident in seen:
                    return 0
                seen.add(ident)
            return st0.st_size
        total = 0
        for root, _, files in os.walk(path, followlinks=False):
            for f in files:
                fp = os.path.join(root, f)
                try:
                    st = os.lstat(fp)
                    if stat.S_ISLNK(st.st_mode) or not stat.S_ISREG(st.st_mode):
                        continue
                    if st.st_ino != 0:
                        ident = (st.st_dev, st.st_ino)
                        if ident in seen:
                            continue
                        seen.add(ident)
                    total += st.st_size
                except OSError:
                    pass
        return total

    @staticmethod
    def location(game: LibraryGame) -> str | None:
        w = game.work_dir
        if w and os.path.isdir(w):
            return w
        return None

    @staticmethod
    def part_of(name: str, title_id: str = '') -> str | None:
        base = name
        for suffix in ('.key', '.partial'):
            if base.endswith(suffix) and len(base) > len(suffix):
                base = base[:-len(suffix)]
        tid_up = title_id.upper()
        if base in ('extract', 'exefs', 'nsp') or (tid_up and base.upper() == tid_up):
            return 'extracted'
        if base in ('shader', 'pso', 'shaders', 'shader_cache', 'ios_shaders', 'mac_shaders'):
            return 'shaders'
        if base in ('xcode', 'xcode-derived-data', 'ipa', 'shell-framework', 'ios_xcode', 'app_build', 'build'):
            return 'xcode'
        if base in ('tools', 'tmp', 'aoc', 'font') or base.startswith('patched_') or base.startswith('nro_'):
            return 'caches'
        return None

    @classmethod
    def stale_shader_entries(cls, folder: str, chain: str | None = None) -> list[str]:
        by_ver: dict[str, list[str]] = {}
        sh = os.path.join(folder, 'shader')
        if os.path.isdir(sh):
            scans = (
                (os.path.join(sh, 'cache'), True, True),
                (os.path.join(sh, 'ios'), True, True),
                (sh, False, True),
            )
            for d, allow_dir, allow_file in scans:
                if not os.path.isdir(d):
                    continue
                try:
                    names = sorted(os.listdir(d))
                except OSError:
                    continue
                for n in names:
                    m = cls._CHAIN_VER_RE.match(n)
                    if not m:
                        continue
                    full = os.path.join(d, n)
                    is_d = os.path.isdir(full) and not os.path.islink(full)
                    is_f = os.path.isfile(full) and not os.path.islink(full)
                    if (is_d and allow_dir and n == m.group(1)) or (is_f and allow_file and n != m.group(1)):
                        by_ver.setdefault(m.group(1), []).append(full)

        if chain:
            keep = chain if chain.startswith('b-') else f'b-{chain}'
            out: list[str] = []
            for ver in sorted(by_ver):
                if ver != keep:
                    out.extend(by_ver[ver])
            return out

        if len(by_ver) > 1:
            def _ver_mtime(ver: str) -> float:
                mtimes = []
                for p in by_ver[ver]:
                    try:
                        mtimes.append(os.path.getmtime(p))
                    except OSError:
                        pass
                return max(mtimes) if mtimes else 0.0

            ordered = sorted(by_ver.keys(), key=lambda v: (_ver_mtime(v), v))
            out = []
            for ver in ordered[:-1]:
                out.extend(by_ver[ver])
            return out
        return []

    @classmethod
    def inspect(cls, folder: str, title_id: str, *, chain: str | None = None) -> BuildFolderReport:
        if not folder or not os.path.isdir(folder):
            return BuildFolderReport(folder=folder or '', items=[], kept_bytes=0)

        tid = title_id.upper()
        buckets: dict[str, list[str]] = {
            'extracted': [],
            'shaders': [],
            'xcode': [],
            'caches': [],
        }
        old_shader_paths: list[str] = cls.stale_shader_entries(folder, chain=chain)
        kept_paths: list[str] = []

        try:
            entries = sorted(os.listdir(folder))
        except OSError:
            entries = []

        for name in entries:
            full = os.path.join(folder, name)
            part = cls.part_of(name, tid)
            if part is None:
                kept_paths.append(full)
            else:
                buckets[part].append(full)
                # Legacy `shaders/b-*` fallback for older layouts
                if name in ('shaders', 'shader_cache', 'ios_shaders', 'mac_shaders') and os.path.isdir(full):
                    try:
                        chains = [
                            os.path.join(full, d)
                            for d in os.listdir(full)
                            if d.startswith('b-') and os.path.isdir(os.path.join(full, d))
                        ]
                        if len(chains) > 1:
                            chains.sort(key=lambda x: os.path.getmtime(x))
                            old_shader_paths.extend(chains[:-1])
                    except OSError:
                        pass

        seen_main: set[tuple[int, int]] = set()
        items: list[BuildFolderItem] = []
        for part in cls.PART_ORDER:
            if part == 'oldShaders':
                seen_old: set[tuple[int, int]] = set()
                b = sum(cls.size(p, seen_old) for p in old_shader_paths)
                if b > 0:
                    items.append(BuildFolderItem(part=part, bytes=b, paths=old_shader_paths))
                continue
            plist = buckets[part]
            b = sum(cls.size(p, seen_main) for p in plist)
            if b > 0:
                items.append(BuildFolderItem(part=part, bytes=b, paths=plist))

        kept_bytes = sum(cls.size(p, seen_main) for p in kept_paths)
        return BuildFolderReport(folder=folder, items=items, kept_bytes=kept_bytes)

    @staticmethod
    def remove(report: BuildFolderReport, selected_parts: set[str]) -> tuple[int, list[str]]:
        parts = set(selected_parts)
        if 'shaders' in parts:
            parts.discard('oldShaders')
        freed = 0
        failed: list[str] = []
        for item in report.items:
            if item.part not in parts:
                continue
            for p in item.paths:
                if not os.path.exists(p):
                    continue
                sz = BuildFolder.size(p)
                try:
                    if os.path.isdir(p) and not os.path.islink(p):
                        shutil.rmtree(p)
                    else:
                        os.remove(p)
                    freed += sz
                except OSError:
                    failed.append(p)
        return freed, failed


# ---------------------------------------------------------------------------
# GameDeletion (mirrors GameDeletion.swift)
# ---------------------------------------------------------------------------

@dataclass
class GameDeletionItem:
    kind: str  # 'macApp', 'ipa', 'iosApp', 'archive', 'shellFramework', 'buildFolder', 'log', 'saves'
    paths: list[str]
    bytes: int = 0


@dataclass
class GameDeletionPlan:
    title_id: str
    items: list[GameDeletionItem]
    saves: GameDeletionItem | None = None

    @staticmethod
    def plan(game: LibraryGame, measure: bool = True) -> GameDeletionPlan:
        items: list[GameDeletionItem] = []
        if game.has_app:
            items.append(GameDeletionItem('macApp', [game.app_path]))
        if game.has_ipa and os.path.basename(game.ipa_path).lower() != 'nx2apple.ipa':
            items.append(GameDeletionItem('ipa', [game.ipa_path]))
        if game.has_archive and os.path.basename(game.archive_path.rstrip('/\\')).upper() == game.title_id.upper():
            items.append(GameDeletionItem('archive', [game.archive_path]))

        bf = BuildFolder.location(game)
        if bf:
            try:
                sub_paths = [
                    os.path.join(bf, name)
                    for name in sorted(os.listdir(bf))
                    if name != 'run'
                ]
            except OSError:
                sub_paths = []
            if sub_paths:
                items.append(GameDeletionItem('buildFolder', sub_paths))

        saves_paths: list[str] = []
        if bf and os.path.exists(os.path.join(bf, 'run')):
            saves_paths.append(os.path.join(bf, 'run'))

        saves_item = GameDeletionItem('saves', saves_paths) if saves_paths else None
        if measure:
            for it in items:
                it.bytes = sum(BuildFolder.size(p) for p in it.paths)
            if saves_item:
                saves_item.bytes = sum(BuildFolder.size(p) for p in saves_item.paths)

        return GameDeletionPlan(title_id=game.title_id, items=items, saves=saves_item)

    def run(self, delete_saves: bool = False) -> list[str]:
        failed: list[str] = []
        all_items = list(self.items)
        if delete_saves and self.saves:
            all_items.append(self.saves)
        for it in all_items:
            for p in it.paths:
                if not os.path.exists(p):
                    continue
                try:
                    if os.path.isdir(p) and not os.path.islink(p):
                        shutil.rmtree(p)
                    else:
                        os.remove(p)
                except OSError:
                    failed.append(p)
        return failed


# ---------------------------------------------------------------------------
# DriveCopy (mirrors DriveCopy.swift)
# ---------------------------------------------------------------------------

class DriveCopy:
    FAT32_LIMIT = 4_294_967_295
    _FAT32_FS_NAMES = frozenset({'fat32', 'vfat', 'msdos', 'fat', 'fat16', 'fat12'})

    @staticmethod
    def collect_archive_files(archive_dir: str) -> dict[str, int]:
        out: dict[str, int] = {}
        if not archive_dir or not os.path.isdir(archive_dir):
            return out
        for root, _, files in os.walk(archive_dir):
            for f in files:
                if f.startswith('.'):
                    continue
                full = os.path.join(root, f)
                rel = os.path.relpath(full, archive_dir).replace('\\', '/')
                try:
                    out[rel] = os.path.getsize(full)
                except OSError:
                    pass
        return out

    @staticmethod
    def _existing_probe(folder: str) -> str:
        probe = os.path.abspath(folder) if folder else '.'
        while probe and not os.path.exists(probe):
            parent = os.path.dirname(probe)
            if parent == probe:
                break
            probe = parent
        return probe or '.'

    @staticmethod
    def free_space(folder: str) -> int:
        try:
            return shutil.disk_usage(DriveCopy._existing_probe(folder)).free
        except OSError:
            return 0

    @staticmethod
    def filesystem_type(folder: str) -> str:
        probe = DriveCopy._existing_probe(folder)
        if os.name == 'nt':
            try:
                import ctypes
                drive, _ = os.path.splitdrive(os.path.abspath(probe))
                root_path = (drive + '\\') if drive else (os.path.abspath(probe).rstrip('\\/') + '\\')
                fs_buf = ctypes.create_unicode_buffer(64)
                ok = ctypes.windll.kernel32.GetVolumeInformationW(
                    ctypes.c_wchar_p(root_path),
                    None,
                    0,
                    None,
                    None,
                    None,
                    fs_buf,
                    len(fs_buf),
                )
                if ok:
                    return fs_buf.value.strip().lower()
            except Exception:
                return ''
            return ''

        try:
            real_probe = os.path.realpath(probe)
        except OSError:
            real_probe = probe

        if os.path.isfile('/proc/mounts'):
            best_mp = ''
            best_fs = ''
            try:
                with open('/proc/mounts', encoding='utf-8', errors='replace') as f:
                    for line in f:
                        parts = line.split()
                        if len(parts) < 3:
                            continue
                        mp = parts[1].replace('\\040', ' ')
                        if real_probe == mp or real_probe.startswith(mp.rstrip('/') + '/'):
                            if len(mp) >= len(best_mp):
                                best_mp = mp
                                best_fs = parts[2].lower()
                if best_fs:
                    return best_fs
            except OSError:
                pass

        try:
            import subprocess
            proc = subprocess.run(
                ['/sbin/mount'] if os.path.isfile('/sbin/mount') else ['mount'],
                capture_output=True,
                text=True,
                timeout=2,
            )
            if proc.returncode == 0:
                best_mp = ''
                best_fs = ''
                for line in proc.stdout.splitlines():
                    # macOS / BSD: "/dev/disk4s1 on /Volumes/USB (msdos, local, ...)"
                    m = re.match(r'^.+?\s+on\s+(.+?)\s+\(([^,)\s]+)', line)
                    if not m:
                        continue
                    mp, fstype = m.group(1), m.group(2).lower()
                    if real_probe == mp or real_probe.startswith(mp.rstrip('/') + '/'):
                        if len(mp) >= len(best_mp):
                            best_mp = mp
                            best_fs = fstype
                return best_fs
        except Exception:
            pass
        return ''

    @staticmethod
    def is_fat32_filesystem(folder: str) -> bool:
        return DriveCopy.filesystem_type(folder).lower() in DriveCopy._FAT32_FS_NAMES

    @staticmethod
    def net_space_needed(
        files: dict[str, int],
        dest_dir: str,
        *,
        reusable: set[str] | None = None,
    ) -> int:
        skip = reusable or set()
        needed = 0
        for rel, sz in files.items():
            if rel in skip:
                continue
            parts = rel.replace('\\', '/').split('/')
            dst = os.path.join(dest_dir, *parts)
            old_sz = 0
            try:
                if os.path.isfile(dst) and not os.path.islink(dst):
                    old_sz = os.path.getsize(dst)
            except OSError:
                old_sz = 0
            if sz > old_sz:
                needed += sz - old_sz
        return needed

    @staticmethod
    def preflight_copy(
        files: dict[str, int],
        dest_root: str,
        title_id: str,
        *,
        reusable: set[str] | None = None,
        t_func: Callable[..., str] | None = None,
    ) -> str | None:
        skip = reusable or set()
        over_fat32 = [rel for rel, sz in files.items() if rel not in skip and sz > DriveCopy.FAT32_LIMIT]
        if over_fat32 and DriveCopy.is_fat32_filesystem(dest_root):
            if t_func is not None:
                return t_func('shell.driveFat32')
            return 'This drive is FAT32 and cannot hold files over 4 GB. Format it as exFAT or APFS, or choose another drive.'

        dest_dir = os.path.join(dest_root, title_id.upper())
        needed = DriveCopy.net_space_needed(files, dest_dir, reusable=skip)
        free = DriveCopy.free_space(dest_root)
        if free > 0 and needed > free:
            if t_func is not None:
                return t_func('shell.driveNoSpace', format_bytes(needed), format_bytes(free))
            return f'Not enough space ({format_bytes(needed)} needed, {format_bytes(free)} free)'
        return None

    @staticmethod
    def copy_to_folder(
        archive_dir: str,
        dest_root: str,
        title_id: str,
        progress_cb: Callable[[int, int], None] | None = None,
    ) -> tuple[bool, str]:
        files = DriveCopy.collect_archive_files(archive_dir)
        if not files:
            return False, 'No game data files found'
        dest_dir = os.path.join(dest_root, title_id.upper())
        total = sum(files.values())
        reusable: set[str] = set()
        for rel, sz in sorted(files.items()):
            src = os.path.join(archive_dir, rel)
            dst = os.path.join(dest_dir, rel)
            if os.path.isfile(dst):
                try:
                    same = os.path.getsize(dst) == sz and abs(os.path.getmtime(src) - os.path.getmtime(dst)) < 0.001
                    if same and sz <= 1024 * 1024:
                        same = Path(src).read_bytes() == Path(dst).read_bytes()
                    if same:
                        reusable.add(rel)
                except OSError:
                    pass
        err = DriveCopy.preflight_copy(files, dest_root, title_id, reusable=reusable)
        if err is not None:
            return False, err
        done = 0
        if progress_cb:
            progress_cb(0, total)
        partial = ''
        try:
            for rel, sz in sorted(files.items()):
                src = os.path.join(archive_dir, rel)
                dst = os.path.join(dest_dir, rel)
                if rel in reusable:
                    done += sz
                    if progress_cb:
                        progress_cb(done, total)
                    continue
                os.makedirs(os.path.dirname(dst), exist_ok=True)
                partial = dst + '.partial'
                with open(src, 'rb') as fin, open(partial, 'wb') as fout:
                    while True:
                        buf = fin.read(4 * 1024 * 1024)
                        if not buf:
                            break
                        fout.write(buf)
                        done += len(buf)
                        if progress_cb:
                            progress_cb(done, total)
                if os.path.exists(dst):
                    os.remove(dst)
                os.replace(partial, dst)
                partial = ''
                try:
                    shutil.copystat(src, dst)
                except OSError:
                    pass
            return True, dest_dir
        except OSError as e:
            if partial and os.path.exists(partial):
                try:
                    os.remove(partial)
                except OSError:
                    pass
            return False, str(e)
