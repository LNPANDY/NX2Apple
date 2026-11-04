"""Sorting a folder's game files into base, update and DLC by the title ID in their names.
The same rules as the Mac launcher's GameInputs.classify, so both front ends agree."""
from __future__ import annotations

import os
import re
import struct
from dataclasses import dataclass, field
from pathlib import Path

GAME_SUFFIXES = ('.nsp', '.xci', '.nsz', '.xcz')

_BRACKET_ID = re.compile(r'\[([0-9A-Fa-f]{16})\]')
# a bare ID that starts with 01, as a token: start of the name or after _ space - . ( [
_BARE_ID = re.compile(r'(?:^|[_ \-.(\[])(01[0-9A-Fa-f]{14})(?![0-9A-Fa-f])')
_BRACKET_VERSION = re.compile(r'\[v(\d+)\]')
_TOKEN_VERSION = re.compile(r'(?:^|[_ ])v(\d+)(?=$|[_ .\-)\]])')


def title_id(name: str) -> int | None:
    """The title ID in a file name: [0100F2C0115B6000] first, else a bare 16-digit ID like
    01007EF00011E000_v0_420d1c5034ab.nsp."""
    m = _BRACKET_ID.search(name) or _BARE_ID.search(name)
    return int(m.group(1), 16) if m else None


def build_key(path: str) -> str:
    """The name of a game's work folder and output (<key>_build, <key>.app), the same rule as the Mac launcher's
    buildKey: the title ID in the file name, else the cleaned file name stem plus a short FNV-1a hash of it. Two games
    never share a folder (and its shader cache), the same file name always gets the same one (#382)."""
    name = Path(path).name
    tid = title_id(name)
    if tid is not None:
        return f'{tid:016X}'
    stem = name.rsplit('.', 1)[0] if '.' in name else name
    h = 2166136261
    for byte in stem.encode('utf-8'):
        h = ((h ^ byte) * 16777619) & 0xFFFFFFFF
    clean = ''.join(c if (c.isascii() and (c.isalnum() or c in '-_')) else '_' for c in stem)[:40]
    return f'{clean or "game"}-{h:08x}'


def update_version(name: str) -> int:
    """The version in a file name ([v65536], else a _v65536 or ' v65536' token), 0 when absent."""
    m = _BRACKET_VERSION.search(name) or _TOKEN_VERSION.search(name)
    return int(m.group(1)) if m else 0


def owner(tid: int) -> int:
    """The base game's title ID a title ID belongs to: 0x000 base, 0x800 its update, else add-on content."""
    low = tid & 0xFFF
    if low == 0:
        return tid
    return tid & ~0xFFF if low == 0x800 else (tid & ~0xFFF) - 0x1000


def classify(files: list[Path]) -> dict:
    """{'base', 'update', 'dlc', 'update_count'} for a list of files. Names without a title ID fall back
    to the older [upd] / [dlc] / 'update' / 'addon' markers, and count as a base game only when no file
    with a title ID is one. Update and DLC files of another game than the chosen base are left out."""
    bases: list[tuple[int, Path]] = []
    updates: list[tuple[int, Path, int]] = []
    dlcs: list[Path] = []
    unnamed: list[Path] = []
    for f in files:
        name = f.name
        if name.startswith('._') or f.suffix.lower() not in GAME_SUFFIXES:
            continue
        try:
            size = f.stat().st_size
        except OSError:
            continue
        if size <= 0:     # an incomplete download leaves empty files
            continue
        tid = title_id(name)
        if tid is None:
            low = name.lower()
            if '[upd]' in low or 'update' in low:
                updates.append((0, f, update_version(name)))
            elif '[dlc]' in low or 'addon' in low:
                dlcs.append(f)
            else:
                unnamed.append(f)
            continue
        kind = tid & 0xFFF
        if kind == 0:
            bases.append((size, f))
        elif kind == 0x800:
            updates.append((tid, f, update_version(name)))
        else:
            dlcs.append(f)
    base = max(bases, key=lambda b: b[0])[1] if bases else (unnamed[0] if unnamed else None)
    base_tid = title_id(base.name) if base else None
    if base_tid is not None:
        app = base_tid & ~0xFFF
        updates = [u for u in updates if u[0] == 0 or owner(u[0]) == app]
        dlcs = [d for d in dlcs if (title_id(d.name) is None or owner(title_id(d.name)) == app)]
    newest = max(updates, key=lambda u: u[2]) if updates else None
    return {'base': base, 'update': newest[1] if newest else None,
            'dlc': sorted(dlcs), 'update_count': len(updates)}


# ---- a game as a folder of its files, or one NUP file (Switch 2 games). The same rules as the Mac launcher's GameFolder,
# which follow the engine's pack_dump.py (is_dump, scan, program_id), pack_nup.py and build_ipa_from_nsp.py (dump_folder,
# nup_file). Neither is encrypted, so the build needs no prod.keys. Reads names and the first bytes of main.npdm only.

_PACKAGES = ('.nsp', '.xci', '.nsz', '.xcz')


@dataclass
class GameFolderContents:
    """What a game folder or a NUP holds."""
    folder: str                    # the game folder, or the folder a NUP is in
    title_id: int                  # the program ID in base/exefs/main.npdm, or the NUP's (0: the script reads it from the code)
    updates: list[tuple[int, str]] = field(default_factory=list)   # (version, path), oldest first
    dlc: list[tuple[int, str]] = field(default_factory=list)       # (DLC title ID, path), sorted by title ID
    nup: str | None = None         # the NUP file the game is in, None for a folder of files

    @property
    def title_id_hex(self) -> str:
        return f'{self.title_id:016X}'

    @property
    def has_title_id(self) -> bool:
        return self.title_id != 0

    @property
    def base_path(self) -> str:
        return self.nup or str(Path(self.folder, 'base'))

    @property
    def script_input(self) -> str:
        """What the script is given: the NUP file, else the folder."""
        return self.nup or self.folder

    @property
    def newest_update(self) -> tuple[int, str] | None:
        return self.updates[-1] if self.updates else None


@dataclass(frozen=True)
class GameFolderProblem:
    """Why a game folder cannot be built. `kind` is the Mac launcher's Problem case, `args` fill its text
    (`folder.problem.<key>`, see `l10n_key`)."""
    kind: str    # missing noBaseFolder unreadableNPDM notBaseTitle packageBeside dlcName notDLC dlcRomFS notNUP nupPartial severalNUPs
    args: tuple = ()

    @property
    def l10n_key(self) -> str:
        return 'folder.problem.' + {
            'missing': 'missing', 'noBaseFolder': 'noBase', 'unreadableNPDM': 'npdm', 'notBaseTitle': 'notBase',
            'packageBeside': 'package', 'dlcName': 'dlcName', 'notDLC': 'notDLC', 'dlcRomFS': 'dlcRomFS',
            'notNUP': 'notNUP', 'nupPartial': 'nupPartial', 'severalNUPs': 'severalNUPs'}[self.kind]


def _is_file(p: str | Path) -> bool:
    return Path(p).is_file()


def _is_nup_name(path: str) -> bool:
    return str(path).lower().endswith('.nup') and _is_file(path)


def nup_files(folder: str) -> list[str]:
    """The NUP files at the top of a folder (the script looks there only), by name."""
    try:
        names = os.listdir(folder)
    except OSError:
        return []
    return sorted(n for n in names if not n.startswith('._') and n.lower().endswith('.nup') and _is_file(Path(folder, n)))


def is_game_folder_candidate(path: str) -> bool:
    """Whether the path is meant as a game folder or a NUP: a .nup file, a folder with a .nup at its top, a folder with
    base/exefs/main.npdm, or exefs/main.npdm with no base/ (the files one level too high). Cheap."""
    if _is_nup_name(path):
        return True
    if _is_file(Path(path, 'base', 'exefs', 'main.npdm')) or nup_files(path):
        return True
    return _is_file(Path(path, 'exefs', 'main.npdm')) and not Path(path, 'base').exists()


def program_id(npdm: bytes) -> int | None:
    """The ACI0 program ID of an NPDM (pack_dump.py program_id): the ACI0 offset and size at 0x70, the ID at ACI0 + 0x10."""
    if len(npdm) < 0x78 or npdm[:4] != b'META':
        return None
    off, size = struct.unpack_from('<II', npdm, 0x70)
    if size < 0x18 or off + 0x18 > len(npdm) or npdm[off:off + 4] != b'ACI0':
        return None
    return struct.unpack_from('<Q', npdm, off + 0x10)[0]


def read_nup(path: str) -> GameFolderContents | GameFolderProblem:
    """A NUP's title ID, updates and DLC from its header and package table (SPEC v1, pack_nup.py). The title ID is the base
    package's, else an update's with the low 12 bits cleared, else 0. Checks the magic, the version and the file size,
    not the SHA-256s (the script checks every file it reads)."""
    name = Path(path).name
    try:
        size = os.path.getsize(path)
        with open(path, 'rb') as f:
            head = f.read(0x80)
            if len(head) != 0x80 or head[:3] != b'NUP' or head[3] != 1:
                return GameFolderProblem('notNUP', (name,))
            if struct.unpack_from('<Q', head, 0x40)[0] != size:
                return GameFolderProblem('nupPartial', (name,))
            toc = struct.unpack_from('<Q', head, 0x08)[0]
            count = struct.unpack_from('<I', head, 0x48)[0]
            if not 0 < count < 100_000 or toc + 0x30 + count * 0x40 > size:
                return GameFolderProblem('notNUP', (name,))
            f.seek(toc)
            table = f.read(0x30 + count * 0x40)
    except OSError:
        return GameFolderProblem('notNUP', (name,))
    if len(table) != 0x30 + count * 0x40 or table[:4] != b'TOC\x01':
        return GameFolderProblem('notNUP', (name,))
    base = update_title = 0
    updates: list[tuple[int, str]] = []
    addons: list[int] = []
    for i in range(count):
        o = 0x30 + i * 0x40
        tid = struct.unpack_from('<Q', table, o)[0]
        version = struct.unpack_from('<I', table, o + 20)[0]
        kind = table[o + 24]
        if kind == 0:
            base = tid
        elif kind == 1:
            updates.append((version, path))
            if update_title == 0:
                update_title = tid & ~0xFFF
        elif kind == 2:
            addons.append(tid)
    app = base if base != 0 and base & 0xFFF == 0 else update_title
    return GameFolderContents(folder=str(Path(path).parent), title_id=app, updates=sorted(updates, key=lambda u: u[0]),
                              dlc=[(t, path) for t in sorted(addons)], nup=path)


def scan_game_folder(path: str) -> GameFolderContents | GameFolderProblem:
    """What the folder (or NUP file) holds, or the first reason it cannot be built, in the order the script finds them."""
    if _is_nup_name(path):
        return read_nup(path)
    root = Path(path)

    def dirs(p: Path) -> list[str]:
        try:
            return sorted(n for n in os.listdir(p) if not n.startswith('.') and Path(p, n).is_dir())
        except OSError:
            return []

    try:
        top = sorted(os.listdir(path))
    except OSError:
        top = []
    for n in top:
        if not n.startswith('._') and n.lower().endswith(_PACKAGES) and _is_file(root / n):
            return GameFolderProblem('packageBeside', (n,))
    nups = nup_files(path)
    if len(nups) > 1:
        return GameFolderProblem('severalNUPs', (len(nups),))
    if nups:
        return read_nup(str(root / nups[0]))
    npdm = root / 'base' / 'exefs' / 'main.npdm'
    if not npdm.is_file():
        if (root / 'exefs' / 'main.npdm').is_file() and not (root / 'base').exists():
            return GameFolderProblem('noBaseFolder')
        return GameFolderProblem('missing', ('base/exefs/main.npdm',))
    versions = [v for v in dirs(root / 'updates') if v.isascii() and v.isdigit()] if (root / 'updates').is_dir() else []
    if not ((root / 'base' / 'romfs').is_dir() or any((root / 'updates' / v / 'romfs').is_dir() for v in versions)):
        return GameFolderProblem('missing', ('base/romfs',))
    try:
        app = program_id(npdm.read_bytes())
    except OSError:
        app = None
    if app is None:
        return GameFolderProblem('unreadableNPDM')
    if app & 0xFFF:
        return GameFolderProblem('notBaseTitle', (f'{app:016X}',))
    updates = sorted((int(v), str(root / 'updates' / v)) for v in versions)
    dlc: list[tuple[int, str]] = []
    for name in dirs(root / 'dlc') if (root / 'dlc').is_dir() else []:
        d = root / 'dlc' / name
        try:
            tid = int(name, 16) if len(name) <= 16 else None
        except ValueError:
            tid = None
        if tid is None:
            return GameFolderProblem('dlcName', (name,))
        if not 0 < tid - app - 0x1000 <= 2000:
            return GameFolderProblem('notDLC', (name,))
        numbered = [n for n in dirs(d) if (d / n / 'romfs').is_dir()]
        count = len(numbered) if numbered else (1 if (d / 'romfs').is_dir() else 0)
        if count != 1:
            return GameFolderProblem('dlcRomFS', (name, count))
        dlc.append((tid, str(d)))
    return GameFolderContents(folder=path, title_id=app, updates=updates, dlc=sorted(dlc))


def engine_builds_folders(engine_root: str) -> bool:
    return bool(engine_root) and Path(engine_root, 'scripts', 'pack_dump.py').is_file()


def engine_builds_nups(engine_root: str) -> bool:
    return bool(engine_root) and Path(engine_root, 'scripts', 'pack_nup.py').is_file()


def engine_has_profile(title_id: int, engine_root: str) -> bool:
    """The script packs a game folder only for a game with a profile."""
    return bool(engine_root) and Path(engine_root, 'dm', 'games', f'{title_id:016X}', 'game.tsv').is_file()
