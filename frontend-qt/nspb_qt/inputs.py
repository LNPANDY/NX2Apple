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
        if self.nup:
            return self.nup
        base = Path(self.folder, 'base')
        if (base / 'exefs' / 'main.npdm').is_file():
            return str(base)
        return self.updates[-1][1] if self.updates else str(base)

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


_SKIP_WRAPPER_DIRS = frozenset({
    'base', 'updates', 'dlc', 'romfs', 'exefs', 'extract', 'tools',
    'venv', 'archive', 'harness', 'runs', 'shader', 'node_modules', 'xcode',
})


def _subdirs(p: str | Path) -> list[str]:
    try:
        return sorted(n for n in os.listdir(p) if not n.startswith('.') and Path(p, n).is_dir())
    except OSError:
        return []


def _has_update_code(folder: str | Path) -> bool:
    u = Path(folder, 'updates')
    if not u.is_dir():
        return False
    return any(v.isascii() and v.isdigit() and _is_file(u / v / 'exefs' / 'main.npdm') for v in _subdirs(u))


def is_dump_directory(path: str | Path) -> bool:
    """Whether `path` itself is an unpacked dump directory (`base/exefs/main.npdm`, `updates/<v>/exefs/main.npdm`,
    or misplaced `exefs/main.npdm` without `base/`), as opposed to a `.nup` file or a folder holding `.nup` files."""
    if _is_file(Path(path, 'base', 'exefs', 'main.npdm')) or _has_update_code(path):
        return True
    return _is_file(Path(path, 'exefs', 'main.npdm')) and not Path(path, 'base').exists()


def _has_nested_game_folders_or_packages(folder: str | Path) -> bool:
    for sub in _wrapper_subdirs(folder):
        if is_dump_directory(sub) or nup_files(sub) or _has_packages(sub):
            return True
        for child in _wrapper_subdirs(sub):
            if is_dump_directory(child) or nup_files(child) or _has_packages(child):
                return True
    return False


def is_direct_game_folder_candidate(path: str) -> bool:
    """Whether `path` itself (without unwrapping parent/child folders) is a game folder or a `.nup` file.
    A folder holding a `.nup` alongside nested game folders or packages is a collection root, not a single-game folder."""
    if _is_nup_name(path):
        return True
    if is_dump_directory(path):
        return True
    return bool(nup_files(path)) and not _has_nested_game_folders_or_packages(path)


def _is_hex(s: str) -> bool:
    return bool(s) and len(s) <= 16 and all(c in '0123456789abcdefABCDEF' for c in s)


def _enclosing_game_folder(path: str) -> str | None:
    cur = Path(path)
    best: str | None = None
    for _ in range(4):
        name = cur.name.lower()
        is_inner = (
            name in ('base', 'exefs', 'romfs', 'updates', 'dlc')
            or (name.isascii() and name.isdigit())
            or _is_hex(name)
        )
        if not is_inner:
            break
        parent = cur.parent
        if not str(parent) or parent == cur:
            break
        if _is_file(parent / 'base' / 'exefs' / 'main.npdm') or _has_update_code(parent):
            best = str(parent)
        cur = parent
    if best is not None:
        return best
    leaf = Path(path).name.lower()
    if leaf in ('exefs', 'romfs'):
        parent = Path(path).parent
        if _is_file(parent / 'exefs' / 'main.npdm') and not (parent / 'base').exists():
            return str(parent)
    return None


def _has_packages(folder: str | Path) -> bool:
    try:
        names = os.listdir(folder)
    except OSError:
        return False
    return any(not n.startswith('._') and n.lower().endswith(_PACKAGES) and _is_file(Path(folder, n)) for n in names)


def _wrapper_subdirs(folder: str | Path) -> list[str]:
    out: list[str] = []
    for name in _subdirs(folder):
        low = name.lower()
        if low in _SKIP_WRAPPER_DIRS or low.endswith(('.app', '_build', '_survey')):
            continue
        out.append(str(Path(folder, name)))
    return out


def _unwrapped_game_folder(path: str) -> str | None:
    if not Path(path).is_dir() or _has_packages(path) or nup_files(path):
        return None
    level1 = _wrapper_subdirs(path)
    if any(_has_packages(sub) for sub in level1):
        return None
    direct1 = [sub for sub in level1 if is_direct_game_folder_candidate(sub)]
    if len(direct1) > 1:
        return None
    level2: list[str] = []
    for sub in level1:
        if is_direct_game_folder_candidate(sub):
            continue
        if nup_files(sub):
            return None
        children = _wrapper_subdirs(sub)
        if any(_has_packages(c) or (not is_direct_game_folder_candidate(c) and nup_files(c)) for c in children):
            return None
        level2.extend(children)
    candidates = direct1 + [sub for sub in level2 if is_direct_game_folder_candidate(sub)]
    return candidates[0] if len(candidates) == 1 else None


def resolve_game_folder(path: str) -> str:
    """Resolves a picked or dropped folder to the actual game folder when the user selected an outer wrapper folder
    (1-2 levels above a single game folder or `.nup`) or stepped inside `base/`, `updates/`, `dlc/`, `exefs/`, or `romfs/`."""
    if not path:
        return path
    if _is_nup_name(path):
        return path
    anc = _enclosing_game_folder(path)
    if anc is not None:
        return anc
    if is_direct_game_folder_candidate(path):
        return path
    inner = _unwrapped_game_folder(path)
    return inner if inner is not None else path


def is_game_folder_candidate(path: str) -> bool:
    """Whether the path is meant as a game folder or a NUP: a .nup file, a folder with a .nup at its top, a folder with
    base/exefs/main.npdm (or updates/<version>/exefs/main.npdm), exefs/main.npdm with no base/, or a 1-2 level wrapper
    folder / inner subfolder of one. Cheap."""
    return is_direct_game_folder_candidate(resolve_game_folder(path))


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


def scan_game_folder(raw_path: str) -> GameFolderContents | GameFolderProblem:
    """What the folder (or NUP file) holds, or the first reason it cannot be built, in the order the script finds them."""
    path = resolve_game_folder(raw_path)
    if _is_nup_name(path):
        return read_nup(path)
    root = Path(path)

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
    versions = [v for v in _subdirs(root / 'updates') if v.isascii() and v.isdigit()] if (root / 'updates').is_dir() else []
    updates = sorted((int(v), str(root / 'updates' / v)) for v in versions)
    base_npdm = root / 'base' / 'exefs' / 'main.npdm'
    if base_npdm.is_file():
        if not ((root / 'base' / 'romfs').is_dir() or any(( Path(u_path) / 'romfs').is_dir() for _, u_path in updates)):
            return GameFolderProblem('missing', ('base/romfs',))
        npdm = base_npdm
    else:
        code_updates = [(ver, u_path) for ver, u_path in updates if (Path(u_path) / 'exefs' / 'main.npdm').is_file()]
        if code_updates:
            full_updates = [(ver, u_path) for ver, u_path in code_updates if (Path(u_path) / 'romfs').is_dir()]
            if not full_updates:
                return GameFolderProblem('missing', (f'updates/{code_updates[-1][0]}/romfs',))
            npdm = Path(full_updates[-1][1]) / 'exefs' / 'main.npdm'
        else:
            if (root / 'exefs' / 'main.npdm').is_file() and not (root / 'base').exists():
                return GameFolderProblem('noBaseFolder')
            return GameFolderProblem('missing', ('base/exefs/main.npdm',))
    try:
        app = program_id(npdm.read_bytes())
    except OSError:
        app = None
    if app is None:
        return GameFolderProblem('unreadableNPDM')
    if app & 0xFFF:
        return GameFolderProblem('notBaseTitle', (f'{app:016X}',))
    dlc: list[tuple[int, str]] = []
    for name in _subdirs(root / 'dlc') if (root / 'dlc').is_dir() else []:
        d = root / 'dlc' / name
        try:
            tid = int(name, 16) if len(name) <= 16 else None
        except ValueError:
            tid = None
        if tid is None:
            return GameFolderProblem('dlcName', (name,))
        if not 0 < tid - app - 0x1000 <= 2000:
            return GameFolderProblem('notDLC', (name,))
        numbered = [n for n in _subdirs(d) if (d / n / 'romfs').is_dir()]
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
