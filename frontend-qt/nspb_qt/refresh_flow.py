"""Game refresh catalog, RomFS identity verification, refresh queue, and refresh dialogs.

Mirrors the Mac Swift launcher's GameUpdateCatalog, RomfsImageIdentity, BuildQueueStore,
DeviceImgPuller, BatchRefreshSheet, and MissingImgGuideSheet for the Qt front end.
Core logic at module top level does not require PySide6 so headless CI can import and test it.
"""
from __future__ import annotations

from collections import OrderedDict
from dataclasses import dataclass, field
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import struct
import subprocess
import sys
import tempfile
import threading
from typing import Callable, NamedTuple
import uuid
import weakref

from . import build_seed_cache
from . import inputs as _inputs
from . import library as lib
from . import platform_util as pu
from . import post_build_cleanup as pbc
from .app_update import APP_VERSION

try:
    from PySide6.QtCore import QObject, Qt, QTimer, Signal
    from PySide6.QtGui import QColor, QFont, QPalette
    from PySide6.QtWidgets import (
        QCheckBox,
        QDialog,
        QFileDialog,
        QFrame,
        QHBoxLayout,
        QLabel,
        QPushButton,
        QScrollArea,
        QSizePolicy,
        QVBoxLayout,
        QWidget,
    )
    HAS_QT = True
except ImportError:
    HAS_QT = False


# ---------------------------------------------------------------------------
# 1. Game Update Catalog (48 TitleIDs synced with CHANGELOG.md & Swift)
# ---------------------------------------------------------------------------

DEFAULT_CATALOG_VERSION = '1.2.0'

GAME_UPDATED_VERSIONS: dict[str, str] = {
    # 1.5.0 (18 games)
    '0100152000022000': '1.5.0',
    '01001B300B9BE000': '1.5.0',
    '010049900F546000': '1.5.0',
    '010051701FB46000': '1.5.0',
    '01005CA01580E000': '1.5.0',
    '01006F8002326000': '1.5.0',
    '0100726014352000': '1.5.0',
    '01007820196A6000': '1.5.0',
    '0100A00019DE0000': '1.5.0',
    '0100A5C00D162000': '1.5.0',
    '0100B99019412000': '1.5.0',
    '0100F2C0115B6000': '1.5.0',
    '0400380020056000': '1.5.0',
    '0400486024DEC000': '1.5.0',
    '040074A01BF12000': '1.5.0',
    '04008E001F098000': '1.5.0',
    '0400C3F00006E000': '1.5.0',
    '0400D4201C6EA000': '1.5.0',
    # 1.4.0 (19 games)
    '010012101468C000': '1.4.0',
    '010014C011146000': '1.4.0',
    '010019A01E2F2000': '1.4.0',
    '01002B00111A2000': '1.4.0',
    '0100429011144000': '1.4.0',
    '010055D009F78000': '1.4.0',
    '010056B015FE8000': '1.4.0',
    '010057D006492000': '1.4.0',
    '010061D00DB74000': '1.4.0',
    '01007300020FA000': '1.4.0',
    '01007EF00011E000': '1.4.0',
    '01008DD013200000': '1.4.0',
    '01009BC00C38A000': '1.4.0',
    '0100A6301214E000': '1.4.0',
    '0100A7C01B792000': '1.4.0',
    '0100B8E016F76000': '1.4.0',
    '0100CE4010AAC000': '1.4.0',
    '0100DA801624E000': '1.4.0',
    '0400C76024710000': '1.4.0',
    # 1.3.0 (8 games)
    '0100276009872000': '1.3.0',
    '010035F022078000': '1.3.0',
    '01006A800016E000': '1.3.0',
    '01008D9022462000': '1.3.0',
    '01008F701C074000': '1.3.0',
    '0100B7C00933A000': '1.3.0',
    '0100ECD018EBE000': '1.3.0',
    '0100ED7012DB2000': '1.3.0',
    # 1.2.2 (3 games)
    '01001F5010DFA000': '1.2.2',
    '040077201BE50000': '1.2.2',
    '04007EF01F8AE000': '1.2.2',
}


def catalog_version_for(title_id: str) -> str:
    """Return the last release version with game-specific changes for `title_id`."""
    tid = (title_id or '').strip().upper()
    return GAME_UPDATED_VERSIONS.get(tid, DEFAULT_CATALOG_VERSION)


def release_base_version(app_version: str = APP_VERSION) -> str:
    """Strip pre-release or local suffixes such as `-local` or `-rc1`."""
    raw = (app_version or APP_VERSION).strip()
    if '-' in raw:
        raw = raw.split('-', 1)[0].strip()
    return raw or DEFAULT_CATALOG_VERSION


# ---------------------------------------------------------------------------
# 2. RomFS Identity (`DMROMFS1` + `DMMSLTR1` + FNV-1a 64)
#    Exact match with `engine/dm/host/romfs_identity.h` & `romfs_image.h`
# ---------------------------------------------------------------------------

DMROMFS_MAGIC = b'DMROMFS1'
DMMSLTR_MAGIC = b'DMMSLTR1'
ROMFS_ID_MAGIC = 'DMROMFSID1'

FNV1A_64_OFFSET = 0xCBF29CE484222325
FNV1A_64_PRIME = 0x100000001B3
UINT64_MAX = 0xFFFFFFFFFFFFFFFF
INT64_MAX = 0x7FFFFFFFFFFFFFFF

DM_MSL_ALIGN = 16384
DM_MSL_FOOTER_SIZE = 64
DM_MSL_FOOTER_ALIGN = 8
DM_MSL_MIN_BLOB_SIZE = 32
_HASH_CHUNK_BYTES = 1 << 20


class RomfsImageDigest(NamedTuple):
    """`(size, index)` digest of a `DMROMFS1` base image."""

    size: int
    index: int

    def format_line(self, *, title: str = '', version: str = '', build: str = '') -> str:
        parts = [ROMFS_ID_MAGIC]
        if title:
            parts.append(f'title={title}')
        if version:
            parts.append(f'version={version}')
        if build:
            parts.append(f'build={build}')
        parts.append(f'size={self.size}')
        parts.append(f'index={self.index:016x}')
        return ' '.join(parts)


@dataclass(frozen=True)
class ParsedRomfsIdentity:
    size: int
    index: int
    title: str = ''
    version: str = ''
    build: str = ''


_IDENTITY_CACHE_MAX = 4096
_IDENTITY_CACHE_LOCK = threading.Lock()
_IDENTITY_CACHE: OrderedDict[tuple[str, int, int], RomfsImageDigest] = OrderedDict()


def clear_romfs_identity_cache() -> None:
    with _IDENTITY_CACHE_LOCK:
        _IDENTITY_CACHE.clear()


def _cache_get_identity(key: tuple[str, int, int]) -> RomfsImageDigest | None:
    with _IDENTITY_CACHE_LOCK:
        val = _IDENTITY_CACHE.get(key)
        if val is not None:
            _IDENTITY_CACHE.move_to_end(key)
        return val


def _cache_put_identity(key: tuple[str, int, int], digest: RomfsImageDigest) -> None:
    with _IDENTITY_CACHE_LOCK:
        _IDENTITY_CACHE[key] = digest
        _IDENTITY_CACHE.move_to_end(key)
        while len(_IDENTITY_CACHE) > _IDENTITY_CACHE_MAX:
            _IDENTITY_CACHE.popitem(last=False)


def parse_romfs_identity(line: str | None) -> ParsedRomfsIdentity | None:
    """Parse a `DMROMFSID1 ... size=<dec> index=<hex>` line exactly as `romfs_id_parse` does."""
    if not line or not isinstance(line, str):
        return None
    target_line = ''
    for raw_ln in line.splitlines():
        s = raw_ln.strip()
        if s.startswith(ROMFS_ID_MAGIC):
            target_line = raw_ln
            break
    if not target_line:
        return None

    idx = target_line.find(ROMFS_ID_MAGIC)
    if idx < 0:
        return None
    rest = target_line[idx + len(ROMFS_ID_MAGIC):]
    if rest and rest[0] not in (' ', '\t', '\r', '\n'):
        return None

    title = ''
    version = ''
    build = ''
    got_size: int | None = None
    got_index: int | None = None

    for tok in rest.strip().split():
        if '=' not in tok:
            continue
        k, v = tok.split('=', 1)
        if not k or not v:
            return None
        if k == 'title':
            if len(v) >= 20:
                return None
            title = v
        elif k == 'version':
            if len(v) >= 24:
                return None
            version = v
        elif k == 'build':
            if len(v) >= 72:
                return None
            build = v
        elif k == 'size':
            if not v.isascii() or not v.isdigit():
                return None
            val = int(v, 10)
            if val < 0 or val > UINT64_MAX:
                return None
            got_size = val
        elif k == 'index':
            if not v.isascii() or not all(c in '0123456789abcdefABCDEF' for c in v):
                return None
            val = int(v, 16)
            if val < 0 or val > UINT64_MAX:
                return None
            got_index = val

    if got_size is None or got_index is None:
        return None
    return ParsedRomfsIdentity(
        size=got_size,
        index=got_index,
        title=title,
        version=version,
        build=build,
    )


def _read_exact(fd: int, length: int) -> bytes | None:
    if length == 0:
        return b''
    chunks: list[bytes] = []
    remaining = length
    while remaining > 0:
        try:
            piece = os.read(fd, remaining)
        except OSError:
            return None
        if not piece:
            return None
        chunks.append(piece)
        remaining -= len(piece)
    return b''.join(chunks) if len(chunks) > 1 else chunks[0]


def _validate_msl_footer(ftr: bytes, base_size: int, file_size: int) -> bool:
    if len(ftr) != DM_MSL_FOOTER_SIZE:
        return False
    f_magic, f_ver, f_api, _f_flags, f_clen, f_base, f_moff, f_msize, f_chain = struct.unpack(
        '<8sIBBHQQQ24s', ftr
    )
    if f_magic != DMMSLTR_MAGIC or f_ver != 1:
        return False
    if f_api < 1 or f_api > 3:
        return False
    if f_clen > 24:
        return False
    if f_base != base_size:
        return False
    if base_size > UINT64_MAX - (DM_MSL_ALIGN - 1):
        return False
    expected_moff = (base_size + (DM_MSL_ALIGN - 1)) & ~(DM_MSL_ALIGN - 1)
    if f_moff != expected_moff:
        return False
    if f_msize < DM_MSL_MIN_BLOB_SIZE:
        return False
    footer_off = file_size - DM_MSL_FOOTER_SIZE
    if f_moff > footer_off or f_msize > footer_off - f_moff:
        return False
    raw_end = f_moff + f_msize
    if raw_end > UINT64_MAX - (DM_MSL_FOOTER_ALIGN - 1):
        return False
    expected_footer = (raw_end + (DM_MSL_FOOTER_ALIGN - 1)) & ~(DM_MSL_FOOTER_ALIGN - 1)
    if expected_footer != footer_off:
        return False
    chain_head = f_chain[:f_clen]
    if any(b == 0 or b >= 0x80 for b in chain_head):
        return False
    if f_chain[f_clen:24] != b'\x00' * (24 - f_clen):
        return False
    return True


def _open_and_check_romfs_header(
    path: str | os.PathLike,
) -> tuple[int, os.stat_result, bytes, int, int, int] | None:
    p_str = os.fspath(path)
    try:
        lst = os.lstat(p_str)
    except OSError:
        return None
    if stat.S_ISLNK(lst.st_mode) or not stat.S_ISREG(lst.st_mode):
        return None

    flags = os.O_RDONLY | getattr(os, 'O_BINARY', 0) | getattr(os, 'O_NOFOLLOW', 0)
    try:
        fd = os.open(p_str, flags)
    except OSError:
        return None

    ok_hdr = False
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            return None
        file_size = st.st_size
        if file_size < 32 or file_size > INT64_MAX:
            return None
        hdr = _read_exact(fd, 32)
        if hdr is None or hdr[:8] != DMROMFS_MAGIC:
            return None
        ioff, isz, _n = struct.unpack('<QQQ', hdr[8:32])
        if not (ioff >= 32 and ioff <= file_size and isz <= file_size - ioff):
            return None
        base_size = ioff + isz
        if file_size > base_size:
            if file_size - base_size < DM_MSL_FOOTER_SIZE:
                return None
            footer_off = file_size - DM_MSL_FOOTER_SIZE
            if os.lseek(fd, footer_off, os.SEEK_SET) != footer_off:
                return None
            ftr = _read_exact(fd, DM_MSL_FOOTER_SIZE)
            if ftr is None or not _validate_msl_footer(ftr, base_size, file_size):
                return None
        ok_hdr = True
        return (fd, st, hdr, ioff, isz, base_size)
    except OSError:
        return None
    finally:
        if not ok_hdr:
            try:
                os.close(fd)
            except OSError:
                pass


def _hash_open_romfs(fd: int, hdr: bytes, ioff: int, isz: int) -> int | None:
    h = FNV1A_64_OFFSET
    for w in struct.unpack('<4Q', hdr):
        h = ((h ^ w) * FNV1A_64_PRIME) & UINT64_MAX

    try:
        if os.lseek(fd, ioff, os.SEEK_SET) != ioff:
            return None
    except OSError:
        return None

    rem = isz
    while rem > 0:
        want = _HASH_CHUNK_BYTES if rem > _HASH_CHUNK_BYTES else rem
        buf = _read_exact(fd, want)
        if buf is None or len(buf) != want:
            return None
        tail_rem = len(buf) & 7
        if tail_rem:
            buf = buf + (b'\x00' * (8 - tail_rem))
        for (w,) in struct.iter_unpack('<Q', buf):
            h = ((h ^ w) * FNV1A_64_PRIME) & UINT64_MAX
        rem -= want
    return h


def compute_romfs_identity(path: str | os.PathLike) -> RomfsImageDigest | None:
    """Compute `(base_size, index_fnv1a64)` for a valid `DMROMFS1` image, or `None` if invalid."""
    p_str = os.fspath(path)
    opened = _open_and_check_romfs_header(p_str)
    if opened is None:
        return None
    fd, st, hdr, ioff, isz, base_size = opened
    try:
        cache_key = (p_str, st.st_size, st.st_mtime_ns)
        cached = _cache_get_identity(cache_key)
        if cached is not None:
            return cached

        index_hash = _hash_open_romfs(fd, hdr, ioff, isz)
        if index_hash is None:
            return None

        digest = RomfsImageDigest(size=base_size, index=index_hash)
        try:
            st_after = os.fstat(fd)
        except OSError:
            return None
        if st_after.st_size == st.st_size and st_after.st_mtime_ns == st.st_mtime_ns:
            _cache_put_identity(cache_key, digest)
        return digest
    finally:
        try:
            os.close(fd)
        except OSError:
            pass


def matches_romfs_identity(
    path: str | os.PathLike,
    expected_line: str | ParsedRomfsIdentity | RomfsImageDigest,
) -> bool:
    """Return True iff `path` is a valid `DMROMFS1` regular file matching `expected_line`."""
    if isinstance(expected_line, ParsedRomfsIdentity):
        exp_size, exp_index = expected_line.size, expected_line.index
    elif isinstance(expected_line, RomfsImageDigest):
        exp_size, exp_index = expected_line.size, expected_line.index
    else:
        parsed = parse_romfs_identity(expected_line)
        if parsed is None:
            return False
        exp_size, exp_index = parsed.size, parsed.index

    p_str = os.fspath(path)
    opened = _open_and_check_romfs_header(p_str)
    if opened is None:
        return False
    fd, st, hdr, ioff, isz, base_size = opened
    try:
        if base_size != exp_size:
            return False
        cache_key = (p_str, st.st_size, st.st_mtime_ns)
        cached = _cache_get_identity(cache_key)
        if cached is not None:
            return cached.size == exp_size and cached.index == exp_index

        index_hash = _hash_open_romfs(fd, hdr, ioff, isz)
        if index_hash is None:
            return False
        digest = RomfsImageDigest(size=base_size, index=index_hash)
        try:
            st_after = os.fstat(fd)
            if st_after.st_size == st.st_size and st_after.st_mtime_ns == st.st_mtime_ns:
                _cache_put_identity(cache_key, digest)
        except OSError:
            return False
        return digest.size == exp_size and digest.index == exp_index
    finally:
        try:
            os.close(fd)
        except OSError:
            pass


# ---------------------------------------------------------------------------
# 3. External Drive Scanner (Depth 0 & Depth 1 without early return)
# ---------------------------------------------------------------------------

def _is_valid_img_filename(name: str) -> bool:
    if not name or name.startswith('.'):
        return False
    low = name.lower()
    if not low.endswith('.img'):
        return False
    if '.nxpart' in low:
        return False
    return True


def _collect_drive_img_candidates(root_dir: str) -> list[tuple[int, str]]:
    """Collect all regular `.img` candidates at depth 0 and depth 1 (plus `games/<sub_dir>`) without early exit."""
    level0: list[str] = []
    level1: list[str] = []
    games_subdirs: list[str] = []

    try:
        with os.scandir(root_dir) as it0:
            entries0 = sorted(it0, key=lambda e: e.name)
    except OSError:
        return []

    subdirs: list[str] = []
    for entry in entries0:
        name = entry.name
        if name.startswith('.'):
            continue
        try:
            if entry.is_symlink():
                continue
            if entry.is_file(follow_symlinks=False) and _is_valid_img_filename(name):
                level0.append(entry.path)
            elif entry.is_dir(follow_symlinks=False):
                subdirs.append(entry.path)
                if name.lower() == 'games':
                    games_subdirs.append(entry.path)
        except OSError:
            continue

    for sub in subdirs:
        try:
            with os.scandir(sub) as it1:
                entries1 = sorted(it1, key=lambda e: e.name)
        except OSError:
            continue
        is_games_container = sub in games_subdirs
        for child in entries1:
            cname = child.name
            if cname.startswith('.'):
                continue
            try:
                if child.is_symlink():
                    continue
                if child.is_file(follow_symlinks=False) and _is_valid_img_filename(cname):
                    level1.append(child.path)
                elif is_games_container and child.is_dir(follow_symlinks=False):
                    try:
                        with os.scandir(child.path) as it2:
                            entries2 = sorted(it2, key=lambda e: e.name)
                    except OSError:
                        continue
                    for gchild in entries2:
                        gname = gchild.name
                        if gname.startswith('.'):
                            continue
                        try:
                            if not gchild.is_symlink() and gchild.is_file(follow_symlinks=False):
                                if _is_valid_img_filename(gname):
                                    level1.append(gchild.path)
                        except OSError:
                            continue
            except OSError:
                continue

    results: list[tuple[int, str]] = [(0, p) for p in level0]
    results.extend((1, p) for p in level1)
    return results


def _candidate_claims_title(img_path: str, tid: str) -> bool:
    parent = os.path.dirname(img_path)
    claimed = pbc.folder_claimed_title_id(parent)
    if claimed and claimed.upper() == tid:
        return True
    sidecar = f'{img_path}.id'
    if os.path.isfile(sidecar) and not os.path.islink(sidecar):
        try:
            with open(sidecar, encoding='utf-8', errors='replace') as f:
                parsed = parse_romfs_identity(f.read(4096))
            if parsed and parsed.title.upper() == tid:
                return True
        except OSError:
            pass
    stem = Path(img_path).stem.upper()
    if stem == tid or Path(parent).name.upper() == tid:
        return True
    return False


def _drive_candidate_rank(item: tuple[int, str]) -> tuple[int, int, str]:
    depth, path = item
    try:
        mtime_ns = os.stat(path).st_mtime_ns
    except OSError:
        mtime_ns = 0
    return (-depth, mtime_ns, path)


def scan_drive_for_matching_img(
    drive_folder: str | os.PathLike,
    title_id: str,
    expected_identity: str | None = None,
) -> str | None:
    """Scan depth 0 and depth 1 of `drive_folder` for a regular `.img` matching `title_id`."""
    if not drive_folder:
        return None
    root = os.fspath(drive_folder)
    tid = (title_id or '').strip().upper()
    if not root or not tid:
        return None
    try:
        lst = os.lstat(root)
    except OSError:
        return None
    if stat.S_ISLNK(lst.st_mode) or not stat.S_ISDIR(lst.st_mode):
        return None

    all_candidates = _collect_drive_img_candidates(root)
    if not all_candidates:
        return None

    exp = (expected_identity or '').strip()
    if exp:
        if parse_romfs_identity(exp) is None:
            return None
        matched: list[tuple[int, str]] = []
        claimed_matched: list[tuple[int, str]] = []
        for depth, cand in all_candidates:
            if matches_romfs_identity(cand, exp):
                matched.append((depth, cand))
                if _candidate_claims_title(cand, tid):
                    claimed_matched.append((depth, cand))
        if claimed_matched:
            return max(claimed_matched, key=_drive_candidate_rank)[1]
        if matched:
            return max(matched, key=_drive_candidate_rank)[1]
        return None

    claimed_valid: list[tuple[int, str]] = []
    for depth, cand in all_candidates:
        if _candidate_claims_title(cand, tid) and compute_romfs_identity(cand) is not None:
            claimed_valid.append((depth, cand))
    if claimed_valid:
        return max(claimed_valid, key=_drive_candidate_rank)[1]
    return None


# ---------------------------------------------------------------------------
# 4. Refresh Assessment (4-State Classifier & Older-Build Detector)
# ---------------------------------------------------------------------------

@dataclass(frozen=True)
class GameRefreshAssessment:
    state: str
    has_specific_update: bool
    version_label: str
    can_fast_mac: bool
    can_fast_ios: bool
    needs_img_guide_ios: bool
    missing_original_package: bool
    expected_romfs_identity: str | None = None

    @property
    def hero_state(self) -> str:
        return self.state

    @property
    def is_up_to_date(self) -> bool:
        return self.state == 'up_to_date'

    @property
    def can_fast_any(self) -> bool:
        return self.can_fast_mac or self.can_fast_ios


def _read_dmsh_chain(engine_path: str) -> str:
    if not engine_path:
        return ''
    hdr = Path(engine_path, 'dm', 'gfx', 'nvn', 'dmsh_chain.h')
    if not hdr.is_file():
        return ''
    try:
        text = hdr.read_text(encoding='utf-8', errors='replace')
    except OSError:
        return ''
    m = re.search(r'^#define\s+DMSH_CHAIN\s+"([^"]+)"', text, re.M)
    return m.group(1) if m else ''


def _read_fork_patches(engine_path: str) -> str:
    if not engine_path:
        return ''
    fp = Path(engine_path, 'dm', 'fork_patches.txt')
    if not fp.is_file():
        return ''
    try:
        lines = [ln.strip() for ln in fp.read_text(encoding='utf-8', errors='replace').splitlines() if ln.strip()]
        return ','.join(lines)
    except OSError:
        return ''


def _read_engine_commit(engine_path: str) -> str:
    if not engine_path or not os.path.isdir(engine_path):
        return ''
    try:
        r = subprocess.run(
            ['git', '-C', engine_path, 'rev-parse', '--short=12', 'HEAD'],
            capture_output=True,
            text=True,
            timeout=3,
            **pu.no_window_kwargs(),
        )
        if r.returncode == 0 and r.stdout.strip():
            commit = r.stdout.strip()
            s = subprocess.run(
                ['git', '-C', engine_path, 'status', '--porcelain', '--untracked-files=no'],
                capture_output=True,
                text=True,
                timeout=3,
                **pu.no_window_kwargs(),
            )
            if s.returncode == 0 and s.stdout.strip():
                commit += '+dirty'
            return commit
    except Exception:
        pass
    return ''


def check_git_specific_changed(
    engine_path: str,
    title_id: str,
    built_commit: str,
) -> bool | None:
    """Check whether `dm/games/<TID>/` changed between `built_commit` and `HEAD` in `engine_path`."""
    tid = (title_id or '').strip().upper()
    clean_commit = (built_commit or '').split('+', 1)[0].strip()
    if not engine_path or not tid or not clean_commit:
        return None
    if not re.fullmatch(r'[0-9a-fA-F]{7,40}', clean_commit):
        return None
    rel_dir = f'dm/games/{tid}'
    try:
        ver = subprocess.run(
            ['git', '-C', engine_path, 'cat-file', '-e', f'{clean_commit}^{{commit}}'],
            capture_output=True,
            text=True,
            timeout=3,
            **pu.no_window_kwargs(),
        )
        if ver.returncode != 0:
            return None
        diff = subprocess.run(
            ['git', '-C', engine_path, 'diff', '--quiet', clean_commit, 'HEAD', '--', rel_dir],
            capture_output=True,
            text=True,
            timeout=3,
            **pu.no_window_kwargs(),
        )
        if diff.returncode == 0:
            return False
        if diff.returncode == 1:
            return True
    except Exception:
        pass
    return None


def detect_built_game_older(
    game: lib.LibraryGame,
    engine_path: str,
    shell_cache_path: str = '',
) -> tuple[bool, str]:
    """Return `(is_older, built_commit)` for `game` relative to `engine_path`."""
    if not game.has_any_build or not engine_path or not os.path.isdir(engine_path):
        return False, ''

    cur_chain = _read_dmsh_chain(engine_path)
    cur_commit = _read_engine_commit(engine_path)
    cur_patches = _read_fork_patches(engine_path)
    built_commit = ''

    if game.built_chain_tag:
        tag = game.built_chain_tag.strip()
        if cur_chain and tag.startswith('b-') and tag != cur_chain:
            return True, ''
        if cur_commit and not tag.startswith('b-'):
            expected_tag = f'{cur_commit}+{cur_patches}' if cur_patches else cur_commit
            if tag != expected_tag:
                built_commit = tag.split('+', 1)[0]
                return True, built_commit

    if game.has_app:
        plist_p = Path(game.app_path, 'Contents', 'Info.plist')
        if plist_p.is_file():
            try:
                with open(plist_p, 'rb') as f:
                    pl = plistlib.load(f)
                if isinstance(pl, dict):
                    c = str(pl.get('NXNativeCommit') or '').strip()
                    p = str(pl.get('NXNativeForkPatches') or '').strip()
                    built_commit = c or built_commit
                    if cur_commit:
                        if not c or '+dirty' in c or '+dirty' in cur_commit:
                            return True, built_commit
                        if not (cur_commit.startswith(c) or c.startswith(cur_commit)) or p != cur_patches:
                            return True, built_commit
            except Exception:
                pass

    tid = (game.title_id or '').strip().upper()
    if game.is_ready_for_ios and shell_cache_path:
        fw_cands = [
            Path(shell_cache_path, 'frameworks', f'DmGame{tid}.framework', 'game.manifest.json'),
        ]
        for mp in fw_cands:
            if not mp.is_file():
                continue
            try:
                mdata = json.loads(mp.read_text(encoding='utf-8'))
            except Exception:
                continue
            if not isinstance(mdata, dict):
                continue
            fw_chain = str(mdata.get('chain') or '').strip()
            fw_commit = str(mdata.get('commit') or mdata.get('nxnative_commit') or '').strip()
            fw_patches = str(mdata.get('fork_patches') or '').strip()
            if fw_commit:
                built_commit = fw_commit
            if cur_chain and fw_chain and fw_chain != cur_chain:
                return True, built_commit
            if cur_commit and fw_commit:
                if '+dirty' in fw_commit or '+dirty' in cur_commit:
                    return True, built_commit
                if not (cur_commit.startswith(fw_commit) or fw_commit.startswith(cur_commit)):
                    return True, built_commit
                if fw_patches and fw_patches != cur_patches:
                    return True, built_commit

    return False, built_commit


def _find_expected_romfs_identity(
    seed_root: Path,
    tid: str,
    out_dir: str,
    game_name: str,
    work_dir: str,
) -> str | None:
    cands: list[Path] = [seed_root / tid / 'romfs.img.id']
    if work_dir:
        ext = Path(work_dir, 'extract')
        if ext.is_dir():
            try:
                vers = sorted(
                    d for d in ext.iterdir()
                    if d.is_dir() and d.name.startswith('v') and d.name[1:].isdigit()
                )
            except OSError:
                vers = []
            for vd in reversed(vers):
                cands.append(vd / 'RomFS.img.id')
    if out_dir:
        arch = lib.find_game_archive_dir(out_dir, tid, game_name)
        if arch:
            p_img = pbc.primary_romfs_image(arch)
            if p_img is not None:
                cands.append(Path(f'{p_img}.id'))
            cands.append(Path(arch, 'romfs.img.id'))

    for cp in cands:
        if cp.is_file() and not cp.is_symlink():
            try:
                txt = cp.read_text(encoding='utf-8', errors='replace')
            except OSError:
                continue
            for ln in txt.splitlines():
                s = ln.strip()
                if s.startswith(ROMFS_ID_MAGIC) and parse_romfs_identity(s) is not None:
                    return s
    return None


def _can_adopt_legacy_work_dir(work_dir: str) -> tuple[bool, str, bool | None]:
    """Inspect `<TID>_build` to see if legacy artifacts can be adopted into a build seed."""
    if not work_dir or not os.path.isdir(work_dir):
        return False, 'nvn', None
    wp = Path(work_dir)
    has_exefs = False
    for cand_dir in (wp / 'ExeFS', wp / 'exefs'):
        if (cand_dir / 'main').is_file() or (cand_dir / 'main.npdm').is_file():
            has_exefs = True
            break
    if not has_exefs:
        ext = wp / 'extract'
        if ext.is_dir():
            try:
                for sub in ext.iterdir():
                    if sub.is_dir() and ((sub / 'ExeFS' / 'main').is_file() or (sub / 'ExeFS' / 'main.npdm').is_file()):
                        has_exefs = True
                        break
            except OSError:
                pass
    if not has_exefs:
        return False, 'nvn', None

    gfx_api = 'nvn'
    shader_ios = wp / 'shader' / 'ios'
    if (shader_ios / 'vk').exists():
        gfx_api = 'vulkan'
    elif (shader_ios / 'gl').exists():
        gfx_api = 'gl'
    return True, gfx_api, None


def _resolve_game_out_dir(game: lib.LibraryGame, default_out_dir: str = '') -> str:
    if game.output_dir:
        return game.output_dir
    if game.app_path and os.path.exists(game.app_path):
        return os.path.dirname(game.app_path)
    if game.archive_path and Path(game.archive_path).parent.name == 'games':
        return str(Path(game.archive_path).parent.parent)
    base = (game.inputs.get('base') or [''])[0]
    if base:
        return os.path.dirname(base)
    return default_out_dir


def has_readable_game_inputs(game: lib.LibraryGame, default_keys_path: str = '') -> bool:
    base = (game.inputs.get('base') or [''])[0]
    if not base or not os.path.exists(base):
        return False
    if lib.GameFolder.is_candidate(base):
        return os.access(base, os.R_OK)
    if not os.path.isfile(base) or not os.access(base, os.R_OK):
        return False
    keys = (game.inputs.get('keys') or [''])[0] or default_keys_path
    return bool(keys and os.path.isfile(keys) and os.access(keys, os.R_OK))


def assess_game_refresh(
    title_id: str,
    *,
    is_marked_older: bool = True,
    has_mac_build: bool = False,
    has_ios_build: bool = False,
    out_dir: str = '',
    game_name: str = '',
    mac_app_path: str = '',
    work_dir: str = '',
    has_readable_source_inputs: bool = False,
    engine_path: str = '',
    seed_root: str | os.PathLike | None = None,
    app_version: str = APP_VERSION,
    git_specific_changed: bool | None = None,
) -> GameRefreshAssessment:
    """Classify a game's refresh state into `up_to_date`, `specific_fast`, `specific_full`, or `general_sync`."""
    tid = (title_id or '').strip().upper()
    base_ver = release_base_version(app_version)
    cat_ver = catalog_version_for(tid)
    missing_pkg = not bool(has_readable_source_inputs)

    if not tid or not is_marked_older or (not has_mac_build and not has_ios_build):
        return GameRefreshAssessment(
            state='up_to_date',
            has_specific_update=False,
            version_label=base_ver,
            can_fast_mac=False,
            can_fast_ios=False,
            needs_img_guide_ios=False,
            missing_original_package=missing_pkg,
            expected_romfs_identity=None,
        )

    if git_specific_changed is True:
        has_specific = True
        ver_label = base_ver if cat_ver == DEFAULT_CATALOG_VERSION else cat_ver
    elif git_specific_changed is False:
        has_specific = False
        ver_label = base_ver
    else:
        if cat_ver == base_ver:
            has_specific = True
            ver_label = cat_ver
        else:
            has_specific = False
            ver_label = base_ver

    eff_seed_root = Path(seed_root) if seed_root is not None else build_seed_cache.default_seed_root()
    supports_seed = build_seed_cache.supports_build_seed(engine_path) if engine_path else True
    seed_status = build_seed_cache.inspect_seed(
        eff_seed_root,
        tid,
        engine_path=engine_path or None,
    )
    eff_work_dir = work_dir or (os.path.join(out_dir, f'{tid}_build') if out_dir else '')

    seed_valid = bool(seed_status.get('valid'))
    gfx_api = str(seed_status.get('gfx_api') or 'nvn').lower()
    chain_match = seed_status.get('chain_match')

    can_adopt = False
    if not seed_valid and eff_work_dir:
        can_adopt, adopt_api, adopt_chain_match = _can_adopt_legacy_work_dir(eff_work_dir)
        if can_adopt:
            gfx_api = adopt_api
            if chain_match is None:
                chain_match = adopt_chain_match

    seed_usable = supports_seed and (seed_valid or can_adopt)

    prefill_cands: list[Path] = []
    if out_dir or eff_work_dir:
        prefill_cands = list(
            build_seed_cache.prefill_candidates(
                tid,
                out_dir or os.path.dirname(eff_work_dir),
                game_name=game_name,
                work_dir=eff_work_dir or None,
            )
        )
    if mac_app_path and os.path.isdir(mac_app_path):
        mp = Path(mac_app_path)
        if mp not in prefill_cands:
            prefill_cands.append(mp)

    romfs_cands: list[Path] = []
    if out_dir or eff_work_dir:
        romfs_cands = list(
            build_seed_cache.find_romfs_candidates(
                tid,
                out_dir or os.path.dirname(eff_work_dir),
                game_name=game_name,
                work_dir=eff_work_dir or None,
            )
        )
    has_mac_romfs = bool(romfs_cands) or (
        bool(mac_app_path) and os.path.isfile(os.path.join(mac_app_path, 'Contents', 'Resources', 'romfs.img'))
    )

    is_path_a = (gfx_api in ('vulkan', 'gl')) or (chain_match is True)
    has_local_ios_img = any(
        str(p).lower().endswith('.img') and '.app' not in str(p).lower()
        for p in prefill_cands
    )
    if not has_local_ios_img and eff_work_dir:
        ext_dir = Path(eff_work_dir, 'extract')
        if ext_dir.is_dir():
            try:
                has_local_ios_img = any(
                    d.is_dir() and d.name.startswith('v') and ((d / 'RomFS').is_dir() or (d / 'RomFS.img').is_file())
                    for d in ext_dir.iterdir()
                )
            except OSError:
                pass

    can_fast_mac = bool(has_mac_build and seed_usable and has_mac_romfs)
    can_fast_ios = bool(has_ios_build and seed_usable and (is_path_a or has_local_ios_img))
    needs_img_guide_ios = bool(has_ios_build and seed_usable and not is_path_a and not has_local_ios_img)

    exp_identity = _find_expected_romfs_identity(
        eff_seed_root,
        tid,
        out_dir,
        game_name,
        eff_work_dir,
    )

    can_fast_any = can_fast_mac or can_fast_ios
    if has_specific:
        state = 'specific_fast' if can_fast_any else 'specific_full'
    else:
        state = 'general_sync'

    return GameRefreshAssessment(
        state=state,
        has_specific_update=has_specific,
        version_label=ver_label,
        can_fast_mac=can_fast_mac,
        can_fast_ios=can_fast_ios,
        needs_img_guide_ios=needs_img_guide_ios,
        missing_original_package=missing_pkg,
        expected_romfs_identity=exp_identity,
    )


def assess_library_game(
    game: lib.LibraryGame,
    *,
    engine_path: str,
    shell_cache_path: str = '',
    default_out_dir: str = '',
    default_keys_path: str = '',
    seed_root: str | os.PathLike | None = None,
    app_version: str = APP_VERSION,
) -> GameRefreshAssessment:
    """Assess a `LibraryGame` on a worker thread (runs older-build & git diff checks)."""
    is_older, built_commit = detect_built_game_older(game, engine_path, shell_cache_path)
    git_changed = check_git_specific_changed(engine_path, game.title_id, built_commit) if is_older else None
    out_d = _resolve_game_out_dir(game, default_out_dir)
    readable_inputs = has_readable_game_inputs(game, default_keys_path)
    return assess_game_refresh(
        game.title_id,
        is_marked_older=is_older,
        has_mac_build=game.has_app,
        has_ios_build=game.is_ready_for_ios,
        out_dir=out_d,
        game_name=game.name,
        mac_app_path=game.app_path if game.has_app else '',
        work_dir=game.work_dir or '',
        has_readable_source_inputs=readable_inputs,
        engine_path=engine_path,
        seed_root=seed_root,
        app_version=app_version,
        git_specific_changed=git_changed,
    )


# ---------------------------------------------------------------------------
# 5. RefreshQueueManager (Deduplicate, Fast-First Ordering, Shared-Shell Batch)
# ---------------------------------------------------------------------------

def normalize_refresh_target(target: str) -> str:
    raw = (target or '').strip().lower()
    if raw in ('mac', 'mac-app', 'macos'):
        return 'mac-app'
    return 'ios'


@dataclass
class RefreshQueueItem:
    title_id: str
    target: str = 'ios'
    fast_refresh: bool = True
    game_name: str = ''
    out_dir: str = ''
    existing_app_path: str | None = None
    external_img_path: str | None = None
    base_path: str = ''
    update_path: str = ''
    dlc_paths: tuple[str, ...] = ()
    keys_path: str = ''

    def __post_init__(self) -> None:
        self.title_id = (self.title_id or '').strip().upper()
        self.target = normalize_refresh_target(self.target)
        if isinstance(self.dlc_paths, list):
            self.dlc_paths = tuple(self.dlc_paths)

    @property
    def dedup_key(self) -> tuple[str, str]:
        return (self.title_id, self.target)


class RefreshQueueManager:
    """Manages queued refresh/rebuild jobs with `(TID, target)` deduplication, fast-first ordering,
    and single shared-shell IPA signing/export at the end of queued iOS shared-shell items."""

    def __init__(
        self,
        model: object | None = None,
        *,
        on_state_changed: Callable[[], None] | None = None,
    ) -> None:
        self._model = model
        self._on_state_changed = on_state_changed
        self._items: list[RefreshQueueItem] = []
        self._active_item: RefreshQueueItem | None = None
        self._dirty_shared_shell = False
        self._finalizing_shell = False
        self._lock = threading.Lock()
        if model is not None:
            self.bind_model(model)

    def bind_model(self, model: object) -> None:
        self._model = model
        fin = getattr(model, 'finished', None)
        if fin is not None and hasattr(fin, 'connect'):
            fin.connect(self._on_model_finished)

    def unbind(self) -> None:
        m = self._model
        self._on_state_changed = None
        self._model = None
        if m is not None:
            fin = getattr(m, 'finished', None)
            if fin is not None and hasattr(fin, 'disconnect'):
                try:
                    fin.disconnect(self._on_model_finished)
                except (RuntimeError, TypeError):
                    pass

    def _notify_state_changed(self) -> None:
        cb = self._on_state_changed
        if cb is not None:
            try:
                cb()
            except RuntimeError:
                self._on_state_changed = None

    @property
    def items(self) -> list[RefreshQueueItem]:
        with self._lock:
            return list(self._items)

    @property
    def active_item(self) -> RefreshQueueItem | None:
        with self._lock:
            return self._active_item

    @property
    def has_pending(self) -> bool:
        with self._lock:
            return bool(self._items)

    def _insert_ordered_unlocked(self, item: RefreshQueueItem) -> bool:
        key = item.dedup_key
        if self._active_item is not None and self._active_item.dedup_key == key:
            return False
        for existing in self._items:
            if existing.dedup_key == key:
                if item.external_img_path and not existing.external_img_path:
                    existing.external_img_path = item.external_img_path
                return False

        if item.fast_refresh:
            insert_at = len(self._items)
            for idx, cur in enumerate(self._items):
                if not cur.fast_refresh:
                    insert_at = idx
                    break
            self._items.insert(insert_at, item)
        else:
            self._items.append(item)
        return True

    def enqueue(self, item: RefreshQueueItem) -> bool:
        with self._lock:
            added = self._insert_ordered_unlocked(item)
        if added:
            self._notify_state_changed()
        return added

    def enqueue_many(self, new_items: list[RefreshQueueItem]) -> int:
        added_count = 0
        with self._lock:
            for it in new_items:
                if self._insert_ordered_unlocked(it):
                    added_count += 1
        if added_count:
            self._notify_state_changed()
        return added_count

    def clear(self) -> None:
        with self._lock:
            self._items.clear()
        self._notify_state_changed()

    def cancel_all(self) -> None:
        with self._lock:
            self._items.clear()
            self._dirty_shared_shell = False
            self._active_item = None
        if self._model is not None and getattr(self._model, 'running', False):
            cancel_fn = getattr(self._model, 'cancel_build', None)
            if callable(cancel_fn):
                cancel_fn()
        self._notify_state_changed()

    def should_export_shared_shell_for_current(self, item: RefreshQueueItem, *, ipa_kind: str = 'shared') -> bool:
        """Return True only when `item` is an iOS shared-shell build with no later iOS items in the queue."""
        if item.target != 'ios' or ipa_kind == 'oneGame':
            return False
        with self._lock:
            has_later_ios = any(later.target == 'ios' for later in self._items)
        return not has_later_ios

    def pop_next_with_export_plan(self, *, ipa_kind: str = 'shared') -> tuple[RefreshQueueItem | None, bool]:
        """Pop the next item (fast items first) and compute whether shared-shell export should run on it."""
        with self._lock:
            if not self._items:
                self._active_item = None
                return None, False
            nxt = self._items.pop(0)
            self._active_item = nxt
            has_later_ios = any(later.target == 'ios' for later in self._items)
        export_now = (nxt.target == 'ios' and ipa_kind != 'oneGame' and not has_later_ios)
        return nxt, export_now

    def start_if_idle(self) -> bool:
        m = self._model
        if m is None or getattr(m, 'running', False):
            return False
        ipa_kind = getattr(m, 'ipa_kind', 'shared')
        nxt, export_now = self.pop_next_with_export_plan(ipa_kind=ipa_kind)
        if nxt is None:
            if self._dirty_shared_shell and not self._finalizing_shell:
                self._dirty_shared_shell = False
                repack_fn = getattr(m, 'start_repack_shell_ipa', None)
                if callable(repack_fn):
                    self._finalizing_shell = True
                    if repack_fn():
                        return True
                    self._finalizing_shell = False
            return False

        self._notify_state_changed()

        if nxt.fast_refresh:
            if hasattr(m, 'log') and hasattr(m, 't'):
                m.log(m.t('queue.fastRefreshSummary') + '\n')
            m.start_fast_refresh(
                nxt.title_id,
                out_dir=nxt.out_dir or None,
                game_name=nxt.game_name,
                target=nxt.target,
                external_img_path=nxt.external_img_path,
                export_shell_at_end=export_now,
            )
            return True

        m.target = nxt.target
        g = next((x for x in m.library.games if x.title_id.upper() == nxt.title_id), None)
        if g is not None:
            m.load_game_from_library(g)
        if nxt.base_path:
            if lib.GameFolder.is_candidate(nxt.base_path):
                m.take_game_folder(nxt.base_path)
            else:
                m.leave_game_folder()
                m.base_path = nxt.base_path
                m.update_path = nxt.update_path
                m.dlc_paths = list(nxt.dlc_paths)
        if nxt.keys_path:
            m.keys_path = nxt.keys_path
        if nxt.out_dir:
            m.out_dir = nxt.out_dir
        m.target = nxt.target
        m._defer_shell_export = (nxt.target == 'ios' and ipa_kind != 'oneGame' and not export_now)
        m._queued_external_img_path = nxt.external_img_path or ''
        m.start_build(title_id=nxt.title_id)
        return True

    def _on_model_finished(self, ok: bool, _note: str) -> None:
        if self._finalizing_shell:
            self._finalizing_shell = False
            self._notify_state_changed()
            return

        with self._lock:
            finished_item = self._active_item
            self._active_item = None

        if finished_item is None:
            return

        m = self._model
        ipa_kind = getattr(m, 'ipa_kind', 'shared') if m is not None else 'shared'
        if finished_item.target == 'ios' and ipa_kind != 'oneGame':
            with self._lock:
                still_has_ios = any(it.target == 'ios' for it in self._items)
            if ok and still_has_ios:
                self._dirty_shared_shell = True
            elif ok and not still_has_ios:
                self._dirty_shared_shell = False

        self._notify_state_changed()
        self.start_if_idle()


# ---------------------------------------------------------------------------
# 6. macOS Connected iPhone `.img` Helper (`xcrun devicectl`)
# ---------------------------------------------------------------------------

@dataclass(frozen=True)
class ConnectedIOSDevice:
    identifier: str
    name: str


def list_connected_ios_devices(xcrun_path: str = '/usr/bin/xcrun') -> list[ConnectedIOSDevice]:
    """List paired & connected iPhones/iPads via `xcrun devicectl list devices` on macOS."""
    if sys.platform != 'darwin' or not os.path.isfile(xcrun_path):
        return []
    fd, tmp_json = tempfile.mkstemp(prefix='nspb-devices-', suffix='.json')
    os.close(fd)
    try:
        res = subprocess.run(
            [xcrun_path, 'devicectl', 'list', 'devices', '--json-output', tmp_json],
            capture_output=True,
            text=True,
            timeout=10,
        )
        if res.returncode != 0 or not os.path.isfile(tmp_json):
            return []
        data = json.loads(Path(tmp_json).read_text(encoding='utf-8', errors='replace'))
        raw_devs = ((data.get('result') or {}).get('devices') or []) if isinstance(data, dict) else []
        found: list[ConnectedIOSDevice] = []
        for d in raw_devs:
            if not isinstance(d, dict):
                continue
            conn = d.get('connectionProperties') or {}
            dev_props = d.get('deviceProperties') or {}
            hw_props = d.get('hardwareProperties') or {}
            pairing = str(conn.get('pairingState') or '')
            tunnel = str(conn.get('tunnelState') or '')
            transport = str(conn.get('transportType') or '')
            platform_str = str(hw_props.get('platform') or '')
            if platform_str and 'iOS' not in platform_str and 'iPadOS' not in platform_str:
                continue
            if pairing != 'paired':
                continue
            if tunnel in ('disconnected', 'unavailable', '') and not transport:
                continue
            ident = str(d.get('identifier') or hw_props.get('udid') or '').strip()
            name = str(dev_props.get('name') or ident).strip()
            if ident:
                found.append(ConnectedIOSDevice(identifier=ident, name=name))
        return found
    except Exception:
        return []
    finally:
        try:
            os.unlink(tmp_json)
        except OSError:
            pass


def _locate_pulled_img_file(tmp_path: Path, remote_src: str) -> Path | None:
    if tmp_path.is_symlink():
        return None
    if tmp_path.is_file():
        return tmp_path
    if tmp_path.is_dir():
        direct = tmp_path / os.path.basename(remote_src)
        if direct.is_file() and not direct.is_symlink():
            return direct
        try:
            found = [
                c for c in sorted(tmp_path.iterdir(), key=lambda p: p.name)
                if not c.is_symlink() and c.is_file() and _is_valid_img_filename(c.name)
            ]
        except OSError:
            return None
        if len(found) == 1:
            return found[0]
    return None


def pull_img_from_ios_device(
    *,
    device_id: str,
    bundle_id: str,
    title_id: str,
    dest_dir: str | os.PathLike,
    dest_filename: str,
    expected_identity: str | None = None,
    cancel_event: threading.Event | None = None,
    on_proc: Callable[[subprocess.Popen | None], None] | None = None,
    xcrun_path: str = '/usr/bin/xcrun',
) -> tuple[bool, str]:
    """Pull `Documents/games/<TID>/*.img` from `device_id` into `dest_dir/dest_filename` atomically.

    Cleans up any partial temporary file unconditionally on cancellation or failure.
    Returns `(True, final_img_path)` or `(False, error_reason)`.
    """
    tid = (title_id or '').strip().upper()
    if sys.platform != 'darwin' or not os.path.isfile(xcrun_path):
        return False, 'devicectl unavailable'
    if cancel_event is not None and cancel_event.is_set():
        return False, 'cancelled'

    fd_list, list_json = tempfile.mkstemp(prefix='nspb-devfiles-', suffix='.json')
    os.close(fd_list)
    remote_imgs: list[str] = []
    subdir = f'Documents/games/{tid}'
    try:
        if cancel_event is not None and cancel_event.is_set():
            return False, 'cancelled'
        r = subprocess.run(
            [
                xcrun_path, 'devicectl', 'device', 'info', 'files',
                '--device', device_id,
                '--domain-type', 'appDataContainer',
                '--domain-identifier', bundle_id,
                '--subdirectory', subdir,
                '--json-output', list_json,
            ],
            capture_output=True,
            text=True,
            timeout=20,
        )
        if r.returncode == 0 and os.path.isfile(list_json):
            payload = json.loads(Path(list_json).read_text(encoding='utf-8', errors='replace'))
            files = ((payload.get('result') or {}).get('files') or []) if isinstance(payload, dict) else []
            for entry in files:
                if not isinstance(entry, dict):
                    continue
                fname = str(entry.get('name') or '').strip()
                if _is_valid_img_filename(fname):
                    remote_imgs.append(f'{subdir}/{fname}')
    except Exception as exc:
        return False, str(exc)
    finally:
        try:
            os.unlink(list_json)
        except OSError:
            pass

    if not remote_imgs:
        return False, f'no .img found in Documents/games/{tid}'

    dest_p = Path(dest_dir)
    dest_p.mkdir(parents=True, exist_ok=True)
    final_path = dest_p / dest_filename
    tmp_path = dest_p / f'.{dest_filename}.{uuid.uuid4().hex[:8]}.pull.tmp'

    proc: subprocess.Popen | None = None
    try:
        remote_src = remote_imgs[0]
        cmd = [
            xcrun_path, 'devicectl', 'device', 'copy', 'from',
            '--device', device_id,
            '--domain-type', 'appDataContainer',
            '--domain-identifier', bundle_id,
            '--source', remote_src,
            '--destination', str(tmp_path),
        ]
        proc = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            encoding='utf-8',
            errors='replace',
            **pu.process_group_kwargs(),
        )
        if on_proc is not None:
            on_proc(proc)
        out_text, _ = proc.communicate()
        if cancel_event is not None and cancel_event.is_set():
            return False, 'cancelled'
        pulled_file = _locate_pulled_img_file(tmp_path, remote_src) if proc.returncode == 0 else None
        if proc.returncode != 0 or pulled_file is None:
            reason = (out_text or f'exit {proc.returncode}').strip().splitlines()[-1]
            return False, reason

        digest = compute_romfs_identity(pulled_file)
        if digest is None:
            return False, 'invalid DMROMFS1 file'
        if expected_identity:
            if not matches_romfs_identity(pulled_file, expected_identity):
                return False, 'identity mismatch'

        pbc.write_title_id_marker(dest_p, tid)
        os.replace(pulled_file, final_path)
        sidecar_line = ''
        if expected_identity:
            parsed_exp = parse_romfs_identity(expected_identity)
            if parsed_exp is not None:
                sidecar_line = RomfsImageDigest(
                    size=parsed_exp.size,
                    index=parsed_exp.index,
                ).format_line(
                    title=parsed_exp.title or tid,
                    version=parsed_exp.version,
                    build=parsed_exp.build,
                )
        if not sidecar_line:
            sidecar_line = digest.format_line(title=tid)
        try:
            Path(f'{final_path}.id').write_text(sidecar_line + '\n', encoding='utf-8')
        except OSError:
            pass
        return True, str(final_path)
    except BaseException as exc:
        return False, str(exc)
    finally:
        if on_proc is not None:
            on_proc(None)
        if proc is not None and proc.poll() is None:
            pu.kill_process_tree(proc)
        if tmp_path.exists():
            if tmp_path.is_dir() and not tmp_path.is_symlink():
                shutil.rmtree(tmp_path, ignore_errors=True)
            else:
                try:
                    tmp_path.unlink()
                except OSError:
                    pass


# ---------------------------------------------------------------------------
# 7. Qt Dialogs (`BatchRefreshDialog` & `MissingImgGuideDialog`)
#    Defined conditionally so non-PySide6 environments import cleanly.
# ---------------------------------------------------------------------------

if HAS_QT:

    @dataclass
    class BatchRefreshEntry:
        game: lib.LibraryGame
        assessment: GameRefreshAssessment
        out_dir: str = ''

    def _apply_font(widget: QWidget, size_pt: int, weight: QFont.Weight = QFont.Weight.Normal) -> None:
        f = widget.font()
        f.setPixelSize(size_pt)
        f.setWeight(weight)
        widget.setFont(f)

    def _apply_text_color(widget: QWidget, hex_color: str) -> None:
        pal = widget.palette()
        pal.setColor(QPalette.ColorRole.WindowText, QColor(hex_color))
        widget.setPalette(pal)

    def _mark_bridge_ref_dead(ref: weakref.ReferenceType[_MainThreadBridge]) -> None:
        bridge = ref()
        if bridge is not None:
            bridge.mark_dead()

    class _MainThreadBridge(QObject):
        call = Signal(object)

        def __init__(self, parent: QObject | None = None) -> None:
            super().__init__(parent)
            self._dead = False
            self.call.connect(self._run)
            if parent is not None:
                self_ref = weakref.ref(self)
                parent.destroyed.connect(lambda *_args: _mark_bridge_ref_dead(self_ref))

        @property
        def is_dead(self) -> bool:
            return self._dead

        def mark_dead(self) -> None:
            self._dead = True

        def safe_emit(self, fn: object) -> None:
            if self._dead:
                return
            try:
                self.call.emit(fn)
            except RuntimeError:
                self._dead = True

        def _run(self, fn: object) -> None:
            if self._dead:
                return
            if callable(fn):
                try:
                    fn()
                except RuntimeError:
                    self._dead = True

    class BatchRefreshDialog(QDialog):
        """Modal dialog listing all outdated built games grouped into Fast Refresh vs Full Rebuild."""

        def __init__(
            self,
            model: object,
            entries: list[BatchRefreshEntry],
            parent: QWidget | None = None,
        ) -> None:
            super().__init__(parent)
            self.m = model
            self._entries = list(entries)
            self._chosen_items: list[RefreshQueueItem] = []
            self._checkboxes: list[tuple[QCheckBox, RefreshQueueItem, bool]] = []

            self.setWindowTitle(self.m.t('batchRefresh.title'))
            self.setModal(True)
            self.setFixedWidth(680)

            root_lay = QVBoxLayout(self)
            root_lay.setContentsMargins(24, 22, 24, 20)
            root_lay.setSpacing(14)

            # Header row: title + version badge
            head_row = QHBoxLayout()
            head_row.setSpacing(10)
            self.title_lbl = QLabel(self.m.t('batchRefresh.title'))
            _apply_font(self.title_lbl, 20, QFont.Weight.Bold)
            head_row.addWidget(self.title_lbl)

            self.ver_badge = QLabel(self.m.t('batchRefresh.versionBadge', release_base_version(APP_VERSION)))
            self.ver_badge.setObjectName('mono')
            head_row.addWidget(self.ver_badge)
            head_row.addStretch(1)
            root_lay.addLayout(head_row)

            self.sub_lbl = QLabel(self.m.t('batchRefresh.subtitle'))
            self.sub_lbl.setObjectName('muted')
            self.sub_lbl.setWordWrap(True)
            root_lay.addWidget(self.sub_lbl)

            # Scrollable list of grouped games
            scroll = QScrollArea(self)
            scroll.setWidgetResizable(True)
            scroll.setHorizontalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
            scroll.setMinimumHeight(260)
            scroll.setMaximumHeight(420)

            body = QWidget()
            body_lay = QVBoxLayout(body)
            body_lay.setContentsMargins(0, 4, 4, 4)
            body_lay.setSpacing(12)

            fast_rows: list[tuple[BatchRefreshEntry, list[tuple[str, bool]]]] = []
            full_rows: list[tuple[BatchRefreshEntry, list[tuple[str, bool]]]] = []

            for entry in self._entries:
                g = entry.game
                a = entry.assessment
                if a.is_up_to_date:
                    continue
                fast_plats: list[tuple[str, bool]] = []
                full_plats: list[tuple[str, bool]] = []
                if g.has_app:
                    if a.can_fast_mac:
                        fast_plats.append(('mac-app', True))
                    else:
                        full_plats.append(('mac-app', False))
                if g.is_ready_for_ios:
                    if a.can_fast_ios:
                        fast_plats.append(('ios', True))
                    else:
                        full_plats.append(('ios', False))
                if fast_plats:
                    fast_rows.append((entry, fast_plats))
                if full_plats:
                    full_rows.append((entry, full_plats))

            self.empty_lbl = QLabel(self.m.t('batchRefresh.empty'))
            self.empty_lbl.setObjectName('muted')
            self.empty_lbl.setAlignment(Qt.AlignmentFlag.AlignCenter)

            if not fast_rows and not full_rows:
                body_lay.addWidget(self.empty_lbl)
            else:
                self.empty_lbl.hide()
                if fast_rows:
                    grp_fast_lbl = QLabel(self.m.t('batchRefresh.groupFast'))
                    grp_fast_lbl.setObjectName('sectionTitle')
                    body_lay.addWidget(grp_fast_lbl)
                    for entry, plats in fast_rows:
                        body_lay.addWidget(self._build_entry_card(entry, plats, is_fast_group=True))
                if full_rows:
                    grp_full_lbl = QLabel(self.m.t('batchRefresh.groupFull'))
                    grp_full_lbl.setObjectName('sectionTitle')
                    body_lay.addWidget(grp_full_lbl)
                    for entry, plats in full_rows:
                        body_lay.addWidget(self._build_entry_card(entry, plats, is_fast_group=False))

            body_lay.addStretch(1)
            scroll.setWidget(body)
            root_lay.addWidget(scroll, 1)

            # Bottom summary + 3 buttons
            foot_col = QVBoxLayout()
            foot_col.setSpacing(10)
            self.summary_lbl = QLabel('')
            self.summary_lbl.setObjectName('muted')
            foot_col.addWidget(self.summary_lbl)

            btn_row = QHBoxLayout()
            btn_row.setSpacing(10)
            self.cancel_btn = QPushButton(self.m.t('batchRefresh.cancel'))
            self.cancel_btn.setObjectName('ghost')
            self.cancel_btn.clicked.connect(self.reject)
            btn_row.addWidget(self.cancel_btn)

            btn_row.addStretch(1)

            self.only_fast_btn = QPushButton('')
            self.only_fast_btn.clicked.connect(self._accept_only_fast)
            btn_row.addWidget(self.only_fast_btn)

            self.all_selected_btn = QPushButton('')
            self.all_selected_btn.setObjectName('creamPill')
            self.all_selected_btn.clicked.connect(self._accept_all_selected)
            btn_row.addWidget(self.all_selected_btn)

            foot_col.addLayout(btn_row)
            root_lay.addLayout(foot_col)

            self._update_summary()

        def _build_entry_card(
            self,
            entry: BatchRefreshEntry,
            plats: list[tuple[str, bool]],
            *,
            is_fast_group: bool,
        ) -> QFrame:
            g = entry.game
            a = entry.assessment
            out_d = entry.out_dir or _resolve_game_out_dir(g, getattr(self.m, 'out_dir', ''))

            card = QFrame()
            card.setObjectName('subcard')
            lay = QVBoxLayout(card)
            lay.setContentsMargins(14, 10, 14, 10)
            lay.setSpacing(6)

            top = QHBoxLayout()
            top.setSpacing(10)
            name_lbl = QLabel(g.name or g.title_id)
            name_lbl.setObjectName('rowTitle')
            top.addWidget(name_lbl, 1)

            if a.has_specific_update:
                badge_txt = self.m.t('library.refresh.badgeVersion', a.version_label)
            else:
                badge_txt = self.m.t('library.refresh.badgeGeneral')
            badge_lbl = QLabel(badge_txt)
            badge_lbl.setObjectName('mono')
            top.addWidget(badge_lbl)
            lay.addLayout(top)

            plat_row = QHBoxLayout()
            plat_row.setSpacing(14)

            base_in = (g.inputs.get('base') or [''])[0]
            upd_in = (g.inputs.get('update') or [''])[0]
            dlc_in = tuple(g.inputs.get('dlc') or ())
            keys_in = (g.inputs.get('keys') or [''])[0] or getattr(self.m, 'keys_path', '')

            show_missing_note = False
            for target, can_fast in plats:
                plat_name = (
                    self.m.t('batchRefresh.platformMac')
                    if target == 'mac-app'
                    else self.m.t('batchRefresh.platformIOS')
                )
                cb = QCheckBox(f'[{plat_name}]')
                disabled_missing = (not can_fast) and a.missing_original_package
                if disabled_missing:
                    cb.setChecked(False)
                    cb.setEnabled(False)
                    show_missing_note = True
                else:
                    default_checked = can_fast or a.has_specific_update
                    cb.setChecked(default_checked)
                cb.toggled.connect(self._update_summary)

                q_item = RefreshQueueItem(
                    title_id=g.title_id,
                    target=target,
                    fast_refresh=can_fast,
                    game_name=g.name,
                    out_dir=out_d,
                    existing_app_path=g.app_path if g.has_app else None,
                    base_path=base_in,
                    update_path=upd_in,
                    dlc_paths=dlc_in,
                    keys_path=keys_in,
                )
                self._checkboxes.append((cb, q_item, is_fast_group))
                plat_row.addWidget(cb)

            if show_missing_note:
                miss_lbl = QLabel(self.m.t('batchRefresh.missingPackage'))
                miss_lbl.setObjectName('muted')
                _apply_text_color(miss_lbl, '#ffbd38')
                plat_row.addWidget(miss_lbl)

            plat_row.addStretch(1)
            lay.addLayout(plat_row)
            return card

        def _update_summary(self) -> None:
            fast_cnt = sum(1 for cb, it, _ in self._checkboxes if cb.isEnabled() and cb.isChecked() and it.fast_refresh)
            full_cnt = sum(1 for cb, it, _ in self._checkboxes if cb.isEnabled() and cb.isChecked() and not it.fast_refresh)
            total_cnt = fast_cnt + full_cnt
            self.summary_lbl.setText(self.m.t('batchRefresh.summary', fast_cnt, full_cnt))
            self.only_fast_btn.setText(self.m.t('batchRefresh.onlyFast', fast_cnt))
            self.only_fast_btn.setEnabled(fast_cnt > 0)
            self.all_selected_btn.setText(self.m.t('batchRefresh.allSelected', total_cnt))
            self.all_selected_btn.setEnabled(total_cnt > 0)

        def _accept_only_fast(self) -> None:
            self._chosen_items = [
                it for cb, it, _ in self._checkboxes
                if cb.isEnabled() and cb.isChecked() and it.fast_refresh
            ]
            self.accept()

        def _accept_all_selected(self) -> None:
            fast_part = [
                it for cb, it, _ in self._checkboxes
                if cb.isEnabled() and cb.isChecked() and it.fast_refresh
            ]
            full_part = [
                it for cb, it, _ in self._checkboxes
                if cb.isEnabled() and cb.isChecked() and not it.fast_refresh
            ]
            self._chosen_items = fast_part + full_part
            self.accept()

        def chosen_items(self) -> list[RefreshQueueItem]:
            return list(self._chosen_items)

    class MissingImgGuideDialog(QDialog):
        """Modal guide when an iOS NVN shader-chain update needs an external or pulled `.img`."""

        def __init__(
            self,
            model: object,
            game: lib.LibraryGame,
            assessment: GameRefreshAssessment,
            *,
            drive_folder: str = '',
            parent: QWidget | None = None,
        ) -> None:
            super().__init__(parent)
            self.m = model
            self.game = game
            self.assessment = assessment
            self._drive_folder = drive_folder
            self._out_dir = _resolve_game_out_dir(game, getattr(model, 'out_dir', ''))
            self._default_games_dir = os.path.join(self._out_dir or str(Path.home()), 'games')
            self._gen = 0
            self._pull_cancel = threading.Event()
            self._pull_proc: subprocess.Popen | None = None
            self._pulling = False
            self._devices: list[ConnectedIOSDevice] = []
            self._bridge = _MainThreadBridge(self)

            self.chosen_action: str = ''
            self.selected_img_path: str = ''
            self.selected_nsp_path: str = ''

            self.setWindowTitle(self.m.t('imgGuide.title'))
            self.setModal(True)
            self.setFixedWidth(680)

            root_lay = QVBoxLayout(self)
            root_lay.setContentsMargins(24, 22, 24, 20)
            root_lay.setSpacing(14)

            self.title_lbl = QLabel(self.m.t('imgGuide.title'))
            _apply_font(self.title_lbl, 20, QFont.Weight.Bold)
            self.title_lbl.setWordWrap(True)
            root_lay.addWidget(self.title_lbl)

            gname = game.name or game.title_id
            self.sub_lbl = QLabel(self.m.t('imgGuide.subtitle', gname))
            self.sub_lbl.setObjectName('muted')
            self.sub_lbl.setWordWrap(True)
            root_lay.addWidget(self.sub_lbl)

            # Option 1 card: select `.img` on external drive (in-place update, no copy back)
            card1 = QFrame()
            card1.setObjectName('card')
            c1_lay = QVBoxLayout(card1)
            c1_lay.setContentsMargins(16, 14, 16, 14)
            c1_lay.setSpacing(8)

            self.opt1_title = QLabel(self.m.t('imgGuide.opt1Title'))
            self.opt1_title.setObjectName('rowTitle')
            c1_lay.addWidget(self.opt1_title)

            self.opt1_note = QLabel(self.m.t('imgGuide.opt1Note'))
            self.opt1_note.setObjectName('muted')
            self.opt1_note.setWordWrap(True)
            c1_lay.addWidget(self.opt1_note)

            c1_btn_row = QHBoxLayout()
            self.choose_img_btn = QPushButton(self.m.t('imgGuide.chooseImgBtn'))
            self.choose_img_btn.setObjectName('creamPill')
            self.choose_img_btn.clicked.connect(self._on_choose_img_clicked)
            c1_btn_row.addWidget(self.choose_img_btn)
            c1_btn_row.addStretch(1)
            c1_lay.addLayout(c1_btn_row)

            self.opt1_status_lbl = QLabel('')
            self.opt1_status_lbl.setWordWrap(True)
            self.opt1_status_lbl.hide()
            c1_lay.addWidget(self.opt1_status_lbl)

            root_lay.addWidget(card1)

            # Option 2 card: copy from iPhone / open default games folder
            card2 = QFrame()
            card2.setObjectName('card')
            c2_lay = QVBoxLayout(card2)
            c2_lay.setContentsMargins(16, 14, 16, 14)
            c2_lay.setSpacing(8)

            self.opt2_title = QLabel(self.m.t('imgGuide.opt2Title'))
            self.opt2_title.setObjectName('rowTitle')
            c2_lay.addWidget(self.opt2_title)

            self.opt2_note = QLabel(self.m.t('imgGuide.opt2Note', self._default_games_dir))
            self.opt2_note.setObjectName('mono')
            self.opt2_note.setWordWrap(True)
            c2_lay.addWidget(self.opt2_note)

            c2_btn_row = QHBoxLayout()
            c2_btn_row.setSpacing(10)
            self.open_folder_btn = QPushButton(self.m.t('imgGuide.openFolderBtn'))
            self.open_folder_btn.clicked.connect(self._on_open_folder_clicked)
            c2_btn_row.addWidget(self.open_folder_btn)

            self.pull_iphone_btn = QPushButton(self.m.t('imgGuide.pullIPhoneBtn'))
            self.pull_iphone_btn.clicked.connect(self._on_pull_iphone_clicked)
            if sys.platform != 'darwin':
                self.pull_iphone_btn.hide()
            c2_btn_row.addWidget(self.pull_iphone_btn)
            c2_btn_row.addStretch(1)
            c2_lay.addLayout(c2_btn_row)

            self.pull_status_lbl = QLabel(self.m.t('imgGuide.pullNoDevice'))
            self.pull_status_lbl.setObjectName('muted')
            self.pull_status_lbl.setWordWrap(True)
            if sys.platform != 'darwin':
                self.pull_status_lbl.hide()
            c2_lay.addWidget(self.pull_status_lbl)

            root_lay.addWidget(card2)

            # Footer: fallback full rebuild from `.nsp`/`.xci` + Cancel
            foot_col = QVBoxLayout()
            foot_col.setSpacing(6)

            self.no_nsp_lbl = QLabel(self.m.t('imgGuide.noNspHint'))
            self.no_nsp_lbl.setObjectName('muted')
            self.no_nsp_lbl.setWordWrap(True)
            self.no_nsp_lbl.setVisible(assessment.missing_original_package)
            foot_col.addWidget(self.no_nsp_lbl)

            foot_btns = QHBoxLayout()
            foot_btns.setSpacing(10)
            self.full_nsp_btn = QPushButton(self.m.t('imgGuide.fullNspBtn'))
            self.full_nsp_btn.setEnabled(not assessment.missing_original_package)
            self.full_nsp_btn.clicked.connect(self._on_full_rebuild_clicked)
            foot_btns.addWidget(self.full_nsp_btn)

            foot_btns.addStretch(1)

            self.cancel_btn = QPushButton(self.m.t('batchRefresh.cancel'))
            self.cancel_btn.setObjectName('ghost')
            self.cancel_btn.clicked.connect(self._on_cancel_clicked)
            foot_btns.addWidget(self.cancel_btn)
            foot_col.addLayout(foot_btns)

            root_lay.addLayout(foot_col)

            if sys.platform == 'darwin':
                self._probe_ios_devices_async()

        def _next_gen(self) -> int:
            self._gen += 1
            return self._gen

        def _probe_ios_devices_async(self) -> None:
            gen = self._gen

            def worker() -> None:
                devs = list_connected_ios_devices()

                def apply() -> None:
                    if gen != self._gen or not self.isVisible():
                        return
                    self._devices = devs
                    if devs:
                        self.pull_iphone_btn.setEnabled(not self._pulling)
                        self.pull_status_lbl.setText(devs[0].name)
                    else:
                        self.pull_iphone_btn.setEnabled(False)
                        self.pull_status_lbl.setText(self.m.t('imgGuide.pullNoDevice'))

                self._bridge.safe_emit(apply)

            threading.Thread(target=worker, daemon=True).start()

        def _on_choose_img_clicked(self) -> None:
            start_dir = self._drive_folder or self._default_games_dir
            if not os.path.isdir(start_dir):
                start_dir = str(Path.home())

            dlg = QFileDialog(self, self.m.t('imgGuide.chooseImgBtn'), start_dir)
            dlg.setOption(QFileDialog.Option.DontUseNativeDialog, True)
            dlg.setFileMode(QFileDialog.FileMode.ExistingFile)
            dlg.setNameFilters(['RomFS Image (*.img)', 'All files (*)'])
            if dlg.exec() != QDialog.DialogCode.Accepted:
                return
            files = dlg.selectedFiles()
            if not files:
                return
            picked = files[0]
            self.verify_selected_img_async(picked)

        def verify_selected_img_async(self, picked: str) -> None:
            gen = self._next_gen()
            self.choose_img_btn.setEnabled(False)
            self.opt1_status_lbl.hide()
            exp = self.assessment.expected_romfs_identity
            gname = self.game.name or self.game.title_id

            def worker() -> None:
                if exp:
                    valid = matches_romfs_identity(picked, exp)
                else:
                    valid = compute_romfs_identity(picked) is not None

                def apply() -> None:
                    if gen != self._gen:
                        return
                    self.choose_img_btn.setEnabled(True)
                    if not valid:
                        _apply_text_color(self.opt1_status_lbl, '#ff6161')
                        self.opt1_status_lbl.setText(self.m.t('imgGuide.invalidImg', gname))
                        self.opt1_status_lbl.show()
                        return
                    reused_msg = self.m.t('imgGuide.driveReused', os.path.basename(picked))
                    _apply_text_color(self.opt1_status_lbl, '#52d97a')
                    self.opt1_status_lbl.setText(reused_msg)
                    self.opt1_status_lbl.show()
                    self.selected_img_path = picked
                    self.chosen_action = 'fast_with_img'
                    self.accept()

                self._bridge.safe_emit(apply)

            threading.Thread(target=worker, daemon=True).start()

        def _on_open_folder_clicked(self) -> None:
            Path(self._default_games_dir).mkdir(parents=True, exist_ok=True)
            pu.reveal(self._default_games_dir)

        def _on_pull_iphone_clicked(self) -> None:
            if self._pulling or not self._devices:
                return
            dev = self._devices[0]
            gen = self._next_gen()
            self._pull_cancel.clear()
            self._pulling = True
            self.pull_iphone_btn.setEnabled(False)
            self.choose_img_btn.setEnabled(False)
            self.pull_status_lbl.setText(self.m.t('imgGuide.pulling', dev.name))

            shell_cache = getattr(self.m, 'shell_cache_path', '')
            bundle_id = 'org.nxnative.shell'
            shell_json = os.path.join(shell_cache, 'shell.json') if shell_cache else ''
            if shell_json and os.path.isfile(shell_json):
                try:
                    sdata = json.loads(Path(shell_json).read_text(encoding='utf-8'))
                    if isinstance(sdata, dict) and sdata.get('bundleID'):
                        bundle_id = str(sdata['bundleID']).strip() or bundle_id
                except Exception:
                    pass

            tid = self.game.title_id.upper()
            folder_name = pbc.archive_directory_name(self.game.name, tid, Path(self._default_games_dir))
            dest_dir = Path(self._default_games_dir, folder_name)
            dest_filename = f'{folder_name}.img'
            exp = self.assessment.expected_romfs_identity

            def set_proc(p: subprocess.Popen | None) -> None:
                self._pull_proc = p

            def worker() -> None:
                ok, info = pull_img_from_ios_device(
                    device_id=dev.identifier,
                    bundle_id=bundle_id,
                    title_id=tid,
                    dest_dir=dest_dir,
                    dest_filename=dest_filename,
                    expected_identity=exp,
                    cancel_event=self._pull_cancel,
                    on_proc=set_proc,
                )

                def apply() -> None:
                    self._pulling = False
                    if gen != self._gen:
                        return
                    self.choose_img_btn.setEnabled(True)
                    self.pull_iphone_btn.setEnabled(bool(self._devices))
                    if ok:
                        self.selected_img_path = info
                        self.chosen_action = 'fast_with_img'
                        self.accept()
                    elif info != 'cancelled':
                        _apply_text_color(self.pull_status_lbl, '#ff6161')
                        self.pull_status_lbl.setText(self.m.t('imgGuide.pullFailed', info))

                self._bridge.safe_emit(apply)

            threading.Thread(target=worker, daemon=True).start()

        def _on_full_rebuild_clicked(self) -> None:
            if self.assessment.missing_original_package:
                return
            self.chosen_action = 'full_rebuild'
            self.accept()

        def _cancel_active_pull(self) -> None:
            self._next_gen()
            self._pull_cancel.set()
            proc = self._pull_proc
            if proc is not None and proc.poll() is None:
                pu.kill_process_tree(proc)

        def _on_cancel_clicked(self) -> None:
            self._cancel_active_pull()
            self.reject()

        def closeEvent(self, event) -> None:
            self._cancel_active_pull()
            self._bridge.mark_dead()
            super().closeEvent(event)

        def reject(self) -> None:
            self._cancel_active_pull()
            self._bridge.mark_dead()
            super().reject()
