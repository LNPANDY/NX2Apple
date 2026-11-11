"""Sorting a folder's game files into base, update and DLC by the title ID in their names.
The same rules as the Mac launcher's GameInputs.classify, so both front ends agree."""
from __future__ import annotations

import hashlib
import os
import re
import struct
from dataclasses import dataclass, field
from pathlib import Path

GAME_SUFFIXES = ('.nsp', '.xci', '.nsz', '.xcz')

_BRACKET_ID = re.compile(r'\[([0-9A-Fa-f]{16})\]')
# a bare ID that starts with 01 (Switch) or 04 (Switch 2), as a token: start of the name or after _ space - . ( [
_BARE_ID = re.compile(r'(?:^|[_ \-.(\[])(0[14][0-9A-Fa-f]{14})(?![0-9A-Fa-f])')
_BRACKET_VERSION = re.compile(r'\[v(\d+)\]')
_TOKEN_VERSION = re.compile(r'(?:^|[_ ])v(\d+)(?=$|[_ .\-)\]])')

_PKG_TID_CACHE: dict[tuple[str, int, int, str], int | None] = {}


def title_id(name: str) -> int | None:
    """The title ID in a file name: [0100F2C0115B6000] first, else a bare 16-digit ID like
    01007EF00011E000_v0_420d1c5034ab.nsp or 0400000000010000_v0.nsp."""
    m = _BRACKET_ID.search(name) or _BARE_ID.search(name)
    return int(m.group(1), 16) if m else None


def _load_header_key_bytes(keys_path: str | Path) -> bytes | None:
    if not keys_path:
        return None
    p = str(keys_path)
    if not os.path.isfile(p):
        return None
    try:
        from . import features as _feat
        keys = _feat.KeyCheck.load_keys(p)
    except Exception:
        return None
    if not keys:
        return None
    hk_hex = keys.get('header_key', '')
    if len(hk_hex) != 64:
        return None
    try:
        return bytes.fromhex(hk_hex)
    except ValueError:
        return None


def _read_fs_entries(
    f,
    file_size: int,
    base_off: int,
    magic: bytes,
    entry_size: int,
) -> tuple[int, list[tuple[str, int, int]]] | None:
    """Read a PFS0 (entry_size=24) or HFS0 (entry_size=64) table safely without integer overflow."""
    if base_off < 0 or base_off > file_size or file_size - base_off < 16:
        return None
    f.seek(base_off)
    head = f.read(16)
    if len(head) != 16 or head[:4] != magic:
        return None
    count, str_size, _ = struct.unpack_from('<III', head, 4)
    if count <= 0 or count > 4096 or str_size <= 0 or str_size > 1_048_576:
        return None
    table_bytes = count * entry_size
    header_total = 16 + table_bytes + str_size
    if header_total > file_size - base_off:
        return None
    entries_raw = f.read(table_bytes)
    str_tab = f.read(str_size)
    if len(entries_raw) != table_bytes or len(str_tab) != str_size:
        return None
    data_base = base_off + header_total
    rem_after_base = file_size - data_base
    out: list[tuple[str, int, int]] = []
    for i in range(count):
        off, sz, soff = struct.unpack_from('<QQI', entries_raw, i * entry_size)
        if soff >= str_size or off > rem_after_base or sz > rem_after_base - off:
            continue
        end = str_tab.find(b'\x00', soff)
        raw_name = str_tab[soff:end if end != -1 else str_size]
        name = raw_name.decode('utf-8', errors='replace')
        out.append((name, data_base + off, sz))
    return data_base, out


def _plausible_switch_tid(tid: int) -> bool:
    hi = (tid >> 56) & 0xFF
    return tid != 0 and hi in (0x01, 0x04)


def package_title_id(path: str | Path, keys_path: str | Path = '') -> int | None:
    """Read a renamed package's own title ID from its PFS0/HFS0 container (NCA header or ticket).

    Follows PackageTitleID.swift for encrypted NCA headers (preferring the content-meta NCA at
    content_type == 1 so base, update, and DLC packages keep their own IDs) and falls back to
    XCI secure HFS0 partitions and common tickets when present. Cached by `(abspath, size, mtime_ns, hk_tag)`.
    """
    if not path:
        return None
    p = os.fspath(path)
    ext = os.path.splitext(p)[1].lower()
    if ext not in GAME_SUFFIXES:
        return None
    try:
        ap = os.path.abspath(p)
        st = os.stat(ap)
    except OSError:
        return None
    if not os.path.isfile(ap) or st.st_size < 64:
        return None

    hk = _load_header_key_bytes(keys_path)
    if hk is None:
        # Check sibling prod.keys if the caller did not supply one yet
        sib = os.path.join(os.path.dirname(ap), 'prod.keys')
        if os.path.isfile(sib):
            hk = _load_header_key_bytes(sib)
    hk_tag = hashlib.sha256(hk).hexdigest()[:16] if hk else ''
    cache_key = (ap, st.st_size, st.st_mtime_ns, hk_tag)
    if cache_key in _PKG_TID_CACHE:
        return _PKG_TID_CACHE[cache_key]

    result: int | None = None
    try:
        with open(ap, 'rb') as f:
            entries: list[tuple[str, int, int]] | None = None
            if ext in ('.nsp', '.nsz'):
                parsed = _read_fs_entries(f, st.st_size, 0, b'PFS0', 24)
                if parsed is not None:
                    entries = parsed[1]
            elif ext in ('.xci', '.xcz') and st.st_size >= 0x200:
                f.seek(0x100)
                xci_head = f.read(0x40)
                if len(xci_head) == 0x40 and xci_head[:4] == b'HEAD':
                    hfs0_off = struct.unpack_from('<Q', xci_head, 0x30)[0]
                    root_hfs = _read_fs_entries(f, st.st_size, hfs0_off, b'HFS0', 64)
                    if root_hfs is not None:
                        sec = next((e for e in root_hfs[1] if e[0].lower() == 'secure'), None)
                        if sec is not None:
                            sec_hfs = _read_fs_entries(f, st.st_size, sec[1], b'HFS0', 64)
                            if sec_hfs is not None:
                                entries = sec_hfs[1]

            if entries:
                if hk is not None:
                    from . import features as _feat
                    prog_fallback: int | None = None
                    # Check .cnmt.nca entries first so a multi-NCA package resolves in one sector decrypt
                    ordered = sorted(entries, key=lambda it: (0 if it[0].lower().endswith('.cnmt.nca') else 1, it[0]))
                    for name, abs_off, sz in ordered:
                        low = name.lower()
                        if not low.endswith(('.nca', '.ncz')) or sz < 0x400:
                            continue
                        f.seek(abs_off + 0x200)
                        sec1 = f.read(0x200)
                        if len(sec1) != 0x200:
                            continue
                        plain1 = _feat.decrypt_nca_sector(sec1, 1, hk[:16], hk[16:32])
                        if plain1[:4] not in (b'NCA3', b'NCA2'):
                            continue
                        tid_val = struct.unpack_from('<Q', plain1, 0x10)[0]
                        if tid_val == 0:
                            continue
                        ctype = plain1[0x05]
                        if ctype == 1:  # Meta NCA holds the package's exact Title ID
                            result = tid_val
                            break
                        if ctype == 0 and prog_fallback is None:
                            prog_fallback = tid_val
                    if result is None:
                        result = prog_fallback

                if result is None:
                    for name, abs_off, sz in entries:
                        low = name.lower()
                        if not low.endswith('.tik'):
                            continue
                        if sz >= 0x2B0:
                            f.seek(abs_off + 0x280)
                            tbuf = f.read(0x30)
                            if len(tbuf) == 0x30:
                                rid_tid = struct.unpack_from('>Q', tbuf, 0x20)[0]
                                if _plausible_switch_tid(rid_tid):
                                    result = rid_tid
                                    break
                        stem = os.path.splitext(os.path.basename(low))[0]
                        if len(stem) >= 16 and all(c in '0123456789abcdef' for c in stem[:16]):
                            cand_tid = int(stem[:16], 16)
                            if _plausible_switch_tid(cand_tid):
                                result = cand_tid
                                break
    except OSError:
        result = None

    if len(_PKG_TID_CACHE) >= 512:
        _PKG_TID_CACHE.clear()
    _PKG_TID_CACHE[cache_key] = result
    return result


def build_key(path: str, keys_path: str = '') -> str:
    """The name of a game's work folder and output (<key>_build, <key>.app), the same rule as the Mac launcher's
    buildKey: the title ID in the file name (or container header), else the cleaned file name stem plus a short FNV-1a hash.
    Two games never share a folder (and its shader cache), the same file name always gets the same one (#382)."""
    name = Path(path).name
    tid = title_id(name)
    if tid is None and path and Path(path).suffix.lower() in GAME_SUFFIXES:
        tid = package_title_id(path, keys_path)
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


def classify(files: list[Path], keys_path: str = '') -> dict:
    """{'base', 'update', 'dlc', 'update_count'} for a list of files. Names without a title ID inspect the
    package header first and fall back to the older [upd] / [dlc] / 'update' / 'addon' markers, counting as a
    base game only when no file with a title ID is one. Update and DLC files of another game are left out."""
    eff_keys = keys_path
    if not eff_keys:
        for cand in files:
            clow = cand.name.lower()
            if (clow in ('prod.keys', 'keys.txt') or clow.endswith('.keys')) and cand.is_file():
                eff_keys = str(cand)
                break

    resolved_tids: dict[Path, int | None] = {}

    def _tid_of(f: Path) -> int | None:
        if f not in resolved_tids:
            resolved_tids[f] = title_id(f.name) or package_title_id(f, eff_keys)
        return resolved_tids[f]

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
        tid = _tid_of(f)
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
    base_tid = _tid_of(base) if base else None
    if base_tid is not None:
        app = base_tid & ~0xFFF
        updates = [u for u in updates if u[0] == 0 or owner(u[0]) == app]
        dlcs = [d for d in dlcs if (_tid_of(d) is None or owner(_tid_of(d)) == app)]  # type: ignore[arg-type]
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
    kind: str    # missing noBaseFolder unreadableNPDM notBaseTitle packageBeside dlcName notDLC dlcRomFS notNUP nupPartial nupDamaged severalNUPs
    args: tuple = ()

    @property
    def l10n_key(self) -> str:
        return 'folder.problem.' + {
            'missing': 'missing', 'noBaseFolder': 'noBase', 'unreadableNPDM': 'npdm', 'notBaseTitle': 'notBase',
            'packageBeside': 'package', 'dlcName': 'dlcName', 'notDLC': 'notDLC', 'dlcRomFS': 'dlcRomFS',
            'notNUP': 'notNUP', 'nupPartial': 'nupPartial', 'nupDamaged': 'nupDamaged', 'severalNUPs': 'severalNUPs'}[self.kind]


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
    package's, else an update's with the low 12 bits cleared, else 0. Checks the magic, the version, the file size and the
    TOC SHA-256 when present."""
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
            toc_size = struct.unpack_from('<Q', head, 0x10)[0]
            toc_sha = head[0x18:0x38]
            count = struct.unpack_from('<I', head, 0x48)[0]
            min_table = 0x30 + count * 0x40
            if not 0 < count < 100_000 or toc + min_table > size:
                return GameFolderProblem('notNUP', (name,))
            f.seek(toc)
            if any(toc_sha):
                if not min_table <= toc_size <= (256 << 20) or toc + toc_size > size:
                    return GameFolderProblem('nupDamaged', (name,))
                toc_bytes = f.read(toc_size)
                if len(toc_bytes) != toc_size or hashlib.sha256(toc_bytes).digest() != toc_sha:
                    return GameFolderProblem('nupDamaged', (name,))
                table = toc_bytes[:min_table]
            else:
                table = f.read(min_table)
    except OSError:
        return GameFolderProblem('notNUP', (name,))
    if len(table) != min_table or table[:4] != b'TOC\x01':
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
