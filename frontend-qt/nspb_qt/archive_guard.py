"""Unified archive extraction guard, shared quota ledger, and atomic staged-tree installer.

Protects all external archive unpackers (`win/fetch.py`, `win/sdk_fetch.py`, `app_update.py`)
against Zip-Slip prefix escapes, drive-letter or NTFS alternate-data-stream paths, out-of-tree
or recursive directory symlinks, decompression bombs across regular files + Unix symlinks + text
symlink stubs, and half-written target directories on failed first-time or overwrite installs.
"""
from __future__ import annotations

from dataclasses import dataclass
import os
from pathlib import Path
import shutil
import stat
from typing import Callable
import zipfile


class ArchiveSafetyError(RuntimeError):
    """Raised when an archive violates path, symlink, quota, or staging safety invariants."""


DEFAULT_MAX_ENTRIES = 100_000
DEFAULT_MAX_BYTES = 4 * 1024 * 1024 * 1024  # 4 GiB


@dataclass
class ArchiveQuota:
    """Shared budget ledger across regular members, Unix symlinks, and text-stub expansions."""

    max_entries: int = DEFAULT_MAX_ENTRIES
    max_bytes: int = DEFAULT_MAX_BYTES
    entries_used: int = 0
    bytes_used: int = 0

    def charge(
        self,
        added_entries: int = 0,
        added_bytes: int = 0,
        *,
        label: str = 'archive unpack',
        error_cls: type[Exception] = ArchiveSafetyError,
    ) -> None:
        if added_entries < 0 or added_bytes < 0:
            raise error_cls(f'{label}: negative quota delta is invalid')
        if self.entries_used > self.max_entries - added_entries:
            self.entries_used += added_entries
            raise error_cls(
                f'{label} exceeds entry limit ({self.entries_used} > {self.max_entries})'
            )
        if self.bytes_used > self.max_bytes - added_bytes:
            self.bytes_used += added_bytes
            raise error_cls(
                f'{label} exceeds unpacked size limit ({self.bytes_used} > {self.max_bytes} bytes)'
            )
        self.entries_used += added_entries
        self.bytes_used += added_bytes


def win_path(p: Path | str) -> str:
    """Return an extended-length path on Windows so deep trees past MAX_PATH succeed."""
    s = os.path.abspath(os.fspath(p))
    if os.name == 'nt' and not s.startswith('\\\\?\\'):
        if s.startswith('\\\\'):
            return '\\\\?\\UNC\\' + s[2:]
        return '\\\\?\\' + s
    return s


def rmtree_force(path: Path | str) -> None:
    """Remove a file, symlink, or directory tree, clearing read-only bits on Windows."""
    p = Path(path)
    wp = Path(win_path(p))
    try:
        st = os.lstat(str(wp))
    except OSError:
        try:
            st = os.lstat(os.fspath(p))
        except OSError:
            return
    if not stat.S_ISDIR(st.st_mode) or stat.S_ISLNK(st.st_mode):
        for cand in (str(wp), os.fspath(p)):
            try:
                os.chmod(cand, stat.S_IWRITE | stat.S_IREAD)
            except OSError:
                pass
            try:
                os.unlink(cand)
                return
            except OSError:
                pass
        return

    def _clear_ro(func, failed_path, _exc) -> None:
        try:
            os.chmod(win_path(failed_path), stat.S_IWRITE | stat.S_IREAD)
            func(win_path(failed_path))
        except OSError:
            pass

    shutil.rmtree(str(wp), onerror=_clear_ro)
    if wp.exists() or p.exists():
        shutil.rmtree(str(wp), ignore_errors=True)


def clean_archive_relpath(raw: str) -> str | None:
    """Validate and normalize an archive member path under POSIX and Windows rules.

    Rejects empty paths, NUL or control characters, leading `/` or `\\`, Windows drive letters
    or NTFS alternate-data-stream colons (`:`), and `.` or `..` traversal segments.
    """
    if not raw or '\x00' in raw or ':' in raw or raw.startswith(('/', '\\')):
        return None
    if any(ord(ch) < 32 for ch in raw):
        return None
    norm = raw.replace('\\', '/').strip('/')
    if not norm:
        return None
    parts = [seg for seg in norm.split('/') if seg]
    if not parts or any(seg in ('.', '..') or ':' in seg for seg in parts):
        return None
    return '/'.join(parts)


def _commonpath_is_root(root_str: str, child_str: str, *, allow_equal: bool) -> bool:
    root_norm = os.path.normcase(os.path.normpath(root_str))
    child_norm = os.path.normcase(os.path.normpath(child_str))
    if child_norm == root_norm:
        return allow_equal
    try:
        return os.path.commonpath([root_norm, child_norm]) == root_norm
    except ValueError:
        return False


def is_within(child: Path | str, root: Path | str) -> bool:
    """True when `child` (both lexical abspath and resolved realpath) stays strictly inside `root`."""
    try:
        root_abs = os.path.abspath(os.fspath(root))
        child_abs = os.path.abspath(os.fspath(child))
        if not _commonpath_is_root(root_abs, child_abs, allow_equal=False):
            return False
        root_real = os.path.realpath(root_abs)
        child_real = os.path.realpath(child_abs)
        return _commonpath_is_root(root_real, child_real, allow_equal=False)
    except (OSError, ValueError):
        return False


def is_same_or_within(child: Path | str, root: Path | str) -> bool:
    """True when `child` is `root` itself or stays strictly inside `root` (flat archive safe)."""
    try:
        root_abs = os.path.abspath(os.fspath(root))
        child_abs = os.path.abspath(os.fspath(child))
        if not _commonpath_is_root(root_abs, child_abs, allow_equal=True):
            return False
        root_real = os.path.realpath(root_abs)
        child_real = os.path.realpath(child_abs)
        return _commonpath_is_root(root_real, child_real, allow_equal=True)
    except (OSError, ValueError):
        return False


def materialize_unix_symlinks(
    out_root: Path,
    links: list[tuple[str, str]],
    *,
    quota: ArchiveQuota,
    log: Callable[[str], None] | None = None,
    strict: bool = True,
    error_cls: type[Exception] = ArchiveSafetyError,
) -> None:
    """Materialize deferred Unix symlinks inside `out_root`, charging `quota` and rejecting loops."""
    log = log or (lambda _s: None)
    todo = list(links) if strict else [(rel, t) for rel, t in links if '/' in rel.rstrip('/')]

    while todo:
        left: list[tuple[str, str]] = []
        for rel, target in todo:
            clean_rel = clean_archive_relpath(rel)
            if clean_rel is None:
                if strict:
                    raise error_cls(f'unsafe symlink path: {rel!r}')
                log(f'  link {rel} -> {target}: unsafe path, skipped')
                continue
            dst = out_root / clean_rel
            if (
                not target
                or '\x00' in target
                or ':' in target
                or target.startswith(('/', '\\'))
            ):
                if strict:
                    raise error_cls(f'unsafe symlink target: {rel} -> {target!r}')
                log(f'  link {rel} -> {target}: absolute or drive-qualified, skipped')
                continue
            src = dst.parent / target.replace('\\', '/')
            if not is_within(dst, out_root) or not is_within(src, out_root):
                if strict:
                    raise error_cls(f'symlink target escapes archive root: {rel} -> {target!r}')
                log(f'  link {rel} -> {target}: escapes archive root, skipped')
                continue
            wdst = Path(win_path(dst))
            wsrc = Path(win_path(src))
            if wdst.exists():
                continue
            if not wsrc.exists():
                left.append((rel, target))
                continue
            try:
                if wsrc.is_dir():
                    src_abs = Path(os.path.abspath(os.fspath(src)))
                    dst_abs = Path(os.path.abspath(os.fspath(dst)))
                    src_real = src_abs.resolve()
                    dst_real = dst_abs.parent.resolve() / dst_abs.name
                    if (
                        _commonpath_is_root(str(src_abs), str(dst_abs), allow_equal=True)
                        or _commonpath_is_root(str(dst_abs), str(src_abs), allow_equal=True)
                        or _commonpath_is_root(str(src_real), str(dst_real), allow_equal=True)
                        or _commonpath_is_root(str(dst_real), str(src_real), allow_equal=True)
                    ):
                        if strict:
                            raise error_cls(f'recursive directory symlink: {rel} -> {target!r}')
                        log(f'  link {rel} -> {target}: recursive directory symlink, skipped')
                        continue
                    items = sorted(wsrc.rglob('*'))
                    quota.charge(1, 0, label='symlink materialization', error_cls=error_cls)
                    wdst.mkdir(parents=True, exist_ok=True)
                    for item in items:
                        rel_item = item.relative_to(wsrc)
                        target_item = wdst / rel_item
                        if item.is_dir():
                            quota.charge(1, 0, label='symlink materialization', error_cls=error_cls)
                            target_item.mkdir(parents=True, exist_ok=True)
                        elif item.is_file():
                            fsize = max(0, item.stat().st_size)
                            quota.charge(
                                1, fsize, label='symlink materialization', error_cls=error_cls
                            )
                            target_item.parent.mkdir(parents=True, exist_ok=True)
                            shutil.copyfile(str(item), str(target_item))
                else:
                    fsize = max(0, wsrc.stat().st_size)
                    quota.charge(1, fsize, label='symlink materialization', error_cls=error_cls)
                    wdst.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(str(wsrc), str(wdst))
            except (OSError, shutil.Error) as exc:
                if strict:
                    raise error_cls(
                        f'failed to materialize symlink {rel} -> {target}: {exc}'
                    ) from exc
                log(f'  link {rel} -> {target}: copy warning ({exc}), skipped')
        if len(left) == len(todo):
            for rel, target in left:
                log(f'  link {rel} -> {target}: target missing, skipped')
            return
        todo = left


def extract_zip_safely(
    zip_path: Path | str,
    dest_dir: Path | str,
    *,
    quota: ArchiveQuota | None = None,
    allow_symlinks: bool = True,
    map_relpath: Callable[[str], str | None] | None = None,
    unpack_progress: Callable[[int, int], None] | None = None,
    verify_crc: bool = False,
    log: Callable[[str], None] | None = None,
    error_cls: type[Exception] = ArchiveSafetyError,
) -> ArchiveQuota:
    """Stream-extract `zip_path` into `dest_dir` with strict path and quota enforcement.

    Every archive entry is validated before extraction begins. Regular files stream in bounded
    chunks and charge `quota` per chunk, while Unix symlinks are validated against `dest_dir` and
    materialized with the same `quota` ledger (or rejected when `allow_symlinks=False`).
    """
    src_zip = Path(zip_path)
    out_root = Path(dest_dir)
    out_root.mkdir(parents=True, exist_ok=True)
    ledger = quota if quota is not None else ArchiveQuota()
    links: list[tuple[str, str]] = []

    with zipfile.ZipFile(src_zip, 'r') as zf:
        if verify_crc:
            bad_crc = zf.testzip()
            if bad_crc:
                raise error_cls(f'{src_zip.name} is corrupt (first bad member: {bad_crc})')
        infos = zf.infolist()
        ledger.charge(len(infos), 0, label=src_zip.name, error_cls=error_cls)

        bad_paths: list[str] = []
        selected: list[tuple[zipfile.ZipInfo, str]] = []
        for info in infos:
            raw_trimmed = info.filename.rstrip('/\\') if info.is_dir() else info.filename
            if not raw_trimmed and info.is_dir():
                continue
            clean = clean_archive_relpath(raw_trimmed)
            if clean is None or not is_within(out_root / clean, out_root):
                bad_paths.append(info.filename)
                continue
            if map_relpath is not None:
                mapped = map_relpath(clean)
                if mapped is None:
                    continue
                clean = clean_archive_relpath(mapped)
                if clean is None or not is_within(out_root / clean, out_root):
                    bad_paths.append(info.filename)
                    continue
            if info.is_dir():
                Path(win_path(out_root / clean)).mkdir(parents=True, exist_ok=True)
                continue
            selected.append((info, clean))

        if bad_paths:
            raise error_cls(f'unsafe paths inside {src_zip.name}: {bad_paths[:3]}')

        declared_bytes = sum(max(0, info.file_size) for info, _ in selected)
        if ledger.bytes_used > ledger.max_bytes - declared_bytes:
            raise error_cls(
                f'{src_zip.name} exceeds unpacked size limit '
                f'({ledger.bytes_used + declared_bytes} > {ledger.max_bytes} bytes)'
            )

        grand = declared_bytes or 1
        if unpack_progress:
            unpack_progress(0, grand)
        done = 0

        for info, rel in selected:
            is_sym = ((info.external_attr >> 16) & 0o170000) == 0o120000
            if is_sym:
                if not allow_symlinks:
                    raise error_cls(f'unexpected symlink entry in {src_zip.name}: {info.filename!r}')
                if info.file_size > 4096:
                    raise error_cls(f'symlink entry too large in {src_zip.name}: {rel}')
                raw_target = zf.read(info)
                ledger.charge(0, len(raw_target), label=src_zip.name, error_cls=error_cls)
                target_rel = raw_target.decode('utf-8', 'surrogateescape').strip()
                if target_rel:
                    if (
                        '\x00' in target_rel
                        or ':' in target_rel
                        or target_rel.startswith(('/', '\\'))
                        or not is_within(
                            (out_root / rel).parent / target_rel.replace('\\', '/'),
                            out_root,
                        )
                    ):
                        raise error_cls(
                            f'unsafe symlink target inside {src_zip.name}: {rel} -> {target_rel!r}'
                        )
                    links.append((rel, target_rel))
                done += max(0, info.file_size)
                if unpack_progress:
                    unpack_progress(done, grand)
                continue

            out_file = out_root / rel
            if not is_within(out_file, out_root):
                raise error_cls(f'unsafe path inside {src_zip.name}: {info.filename}')
            Path(win_path(out_file.parent)).mkdir(parents=True, exist_ok=True)
            with zf.open(info) as zsrc, open(win_path(out_file), 'wb') as zdst:
                while True:
                    chunk = zsrc.read(1 << 20)
                    if not chunk:
                        break
                    ledger.charge(0, len(chunk), label=src_zip.name, error_cls=error_cls)
                    zdst.write(chunk)
            done += max(0, info.file_size)
            if unpack_progress:
                unpack_progress(done, grand)

    if links:
        materialize_unix_symlinks(
            out_root,
            links,
            quota=ledger,
            log=log,
            strict=True,
            error_cls=error_cls,
        )
    return ledger


def install_staged_tree(
    staged_src: Path | str,
    target: Path | str,
    *,
    validator: Callable[[Path], bool | None] | None = None,
    move_fn: Callable[[str, str], object] | None = None,
    error_cls: type[Exception] = ArchiveSafetyError,
) -> Path:
    """Atomically install `staged_src` at `target` with `.old` backup and unconditional cleanup.

    Invariant: whether this is a first-time install (no prior `target`) or an overwrite install
    (prior `target` moved to `.<name>.old`), any failure while moving `staged_src` into `target`
    or validating `target` ALWAYS calls `rmtree_force(target)` first so no half-written `target`
    can survive on disk, and then restores `.<name>.old` back to `target` if a backup existed.
    """
    src = Path(staged_src)
    dst = Path(target)
    dst.parent.mkdir(parents=True, exist_ok=True)
    backup = dst.parent / f'.{dst.name}.old'

    def _do_move(s: str, d: str) -> None:
        if move_fn is not None:
            move_fn(s, d)
        else:
            shutil.move(s, d)

    def _is_valid(candidate: Path) -> bool:
        if not candidate.exists():
            return False
        if validator is None:
            return True
        res = validator(candidate)
        return True if res is None else bool(res)

    # Recover from an interrupted prior overwrite if a `.old` backup was left behind.
    if backup.exists():
        if not _is_valid(dst):
            rmtree_force(dst)
            try:
                shutil.move(win_path(backup), win_path(dst))
            except OSError:
                pass
        else:
            rmtree_force(backup)

    had_existing = dst.exists()
    if had_existing:
        rmtree_force(backup)
        shutil.move(win_path(dst), win_path(backup))

    try:
        _do_move(win_path(src), win_path(dst))
        if not _is_valid(dst):
            raise error_cls(f'installed tree at {dst} failed validation')
    except BaseException as exc:
        rmtree_force(dst)
        if had_existing and backup.exists():
            try:
                shutil.move(win_path(backup), win_path(dst))
            except OSError:
                pass
        if isinstance(exc, Exception) and not isinstance(exc, error_cls):
            raise error_cls(f'failed to install into {dst}: {exc}') from exc
        raise

    if backup.exists():
        rmtree_force(backup)
    return dst
