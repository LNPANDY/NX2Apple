"""Post-build staging cleanup and zero-copy placement helpers for the Qt front end.

Mirrors `frontend/Sources/NXCore/PostBuildCleanup.swift` and `RomFSArchive.reusableImages`:
- Moves `extract/v<N>/RomFS.img` and `<work>/aoc` into `games/<id>/` atomically on the same
  volume (falling back to copy + delete across volumes, with partial-target cleanup and backup
  rollback so an existing archive is never left half-written).
- Sweeps one-shot build outputs (`nsp/`, PSO `batches.*` shards, Xcode / Windows `Build/Products`
  or `Payload`, and consumed `extract/v*/RomFS*` / `shell-framework`) while preserving incremental
  caches (`ExeFS/`, `control.nacp`, shader libraries, `.mtl4a` + `key.*`, `.o` objects, `patched_*`,
  `logs/`, `profile/`, and `run/`).
"""
from __future__ import annotations

import json
import os
import plistlib
import re
import shutil
import uuid
from pathlib import Path

_HEX16_RE = re.compile(r'^[0-9A-Fa-f]{16}$')


def _same_path(a: Path, b: Path) -> bool:
    try:
        return os.path.samefile(a, b)
    except OSError:
        return os.path.normcase(os.path.abspath(a)) == os.path.normcase(os.path.abspath(b))


def _app_matches_title_id(app_dir: Path, id_file: Path, expected_upper: str) -> bool:
    try:
        data = json.loads(id_file.read_text(encoding='utf-8'))
        if isinstance(data, dict):
            title = str(data.get('title') or '').strip()
            if title:
                return title.upper() == expected_upper
    except (OSError, ValueError, UnicodeDecodeError):
        pass
    plist_p = app_dir / 'Contents' / 'Info.plist'
    if plist_p.is_file():
        try:
            with open(plist_p, 'rb') as f:
                info = plistlib.load(f)
            if isinstance(info, dict):
                tid = str(info.get('DMTitleID') or '').strip()
                if tid:
                    return tid.upper() == expected_upper
        except Exception:
            pass
    return False


def reusable_romfs_images(root: str | os.PathLike, key: str) -> list[str]:
    """Return existing `romfs.img` paths in `root` that carry a `.id` sidecar for `key`.

    Checks `games/<KEY>/romfs.img`, `<key>.app/Contents/Resources/romfs.img`, and any renamed
    non-symlink `<DisplayName>.app` bundle in `root` whose `.id` `"title"` or `Info.plist`
    `"DMTitleID"` matches `key`.
    """
    if not root or not key:
        return []
    root_p = Path(root)
    key_up = key.upper()
    candidates: list[Path] = [
        root_p / 'games' / key_up / 'romfs.img',
        root_p / f'{key}.app' / 'Contents' / 'Resources' / 'romfs.img',
    ]
    found: list[str] = []
    seen_norm: set[str] = set()

    def _add(img: Path) -> None:
        norm = os.path.normcase(os.path.abspath(img))
        if norm in seen_norm:
            return
        if img.is_file() and Path(f'{img}.id').is_file():
            seen_norm.add(norm)
            found.append(str(img))

    for cand in candidates:
        _add(cand)

    if _HEX16_RE.match(key_up) and root_p.is_dir():
        direct_app_low = f'{key}.app'.lower()
        try:
            entries = sorted(root_p.iterdir(), key=lambda p: p.name)
        except OSError:
            entries = []
        for entry in entries:
            if not entry.name.lower().endswith('.app') or entry.name.lower() == direct_app_low:
                continue
            if entry.is_symlink() or not entry.is_dir():
                continue
            img = entry / 'Contents' / 'Resources' / 'romfs.img'
            id_file = Path(f'{img}.id')
            if img.is_file() and id_file.is_file() and _app_matches_title_id(entry, id_file, key_up):
                _add(img)

    return found


def _sync_id_sidecar(src_img: Path, dst_img: Path) -> None:
    id_src = Path(f'{src_img}.id')
    id_dst = Path(f'{dst_img}.id')
    if id_src.is_file():
        tmp_id = id_dst.parent / f'.{id_dst.name}.partial-{uuid.uuid4().hex[:8]}'
        try:
            shutil.copy2(id_src, tmp_id)
            os.replace(tmp_id, id_dst)
        finally:
            tmp_id.unlink(missing_ok=True)
    else:
        id_dst.unlink(missing_ok=True)


def _remove_source_image_sidecars(src_img: Path) -> None:
    for p in (src_img, Path(f'{src_img}.id'), Path(f'{src_img}.formats')):
        try:
            p.unlink(missing_ok=True)
        except OSError:
            pass


def place_image(src: str | os.PathLike, dst: str | os.PathLike) -> str:
    """Place `src` (`RomFS.img`) at `dst` (`romfs.img`), syncing `.id` and removing `src`.

    Returns `'reused'`, `'moved'`, or `'copied'`. An existing `dst` stays untouched if an
    error occurs before the final atomic `os.replace`.
    """
    src_p = Path(src)
    dst_p = Path(dst)
    dst_p.parent.mkdir(parents=True, exist_ok=True)

    if _same_path(src_p, dst_p):
        return 'reused'

    src_st = src_p.stat()
    if dst_p.is_file():
        try:
            dst_st = dst_p.stat()
            reused = dst_st.st_size == src_st.st_size and abs(dst_st.st_mtime - src_st.st_mtime) < 1
            if reused and dst_st.st_size <= 1024 * 1024:
                reused = dst_p.read_bytes() == src_p.read_bytes()
        except OSError:
            reused = False
        if reused:
            _sync_id_sidecar(src_p, dst_p)
            _remove_source_image_sidecars(src_p)
            return 'reused'

    # Remove stale split archive parts before replacing with a single romfs.img
    try:
        for child in dst_p.parent.iterdir():
            if child.name == 'romfs.idx' or (
                child.name.startswith('romfs.') and child.name[6:].isdigit()
            ):
                child.unlink(missing_ok=True)
    except OSError:
        pass

    partial = dst_p.parent / f'.{dst_p.name}.partial-{uuid.uuid4().hex[:8]}'
    id_src = Path(f'{src_p}.id')
    id_dst = Path(f'{dst_p}.id')
    id_partial = id_dst.parent / f'.{id_dst.name}.partial-{uuid.uuid4().hex[:8]}'
    has_id = id_src.is_file()
    mode = 'moved'
    try:
        if has_id:
            shutil.copy2(id_src, id_partial)
        try:
            os.replace(src_p, partial)
        except OSError:
            mode = 'copied'
            shutil.copy2(src_p, partial)
        os.replace(partial, dst_p)
        if has_id:
            os.replace(id_partial, id_dst)
        else:
            id_dst.unlink(missing_ok=True)
    finally:
        if partial.exists():
            partial.unlink(missing_ok=True)
        if id_partial.exists():
            id_partial.unlink(missing_ok=True)

    _remove_source_image_sidecars(src_p)
    return mode


def place_aoc(src: str | os.PathLike, dst: str | os.PathLike) -> int:
    """Move or copy `<work>/aoc` to `<dest>/aoc` with rollback protection, then clean source.

    Returns the number of top-level add-on content entries placed (0 when `src` is absent or empty).
    """
    src_p = Path(src)
    dst_p = Path(dst)

    entries: list[Path] = []
    if src_p.is_dir():
        entries = [p for p in src_p.iterdir() if not p.name.startswith('.')]

    if not entries:
        shutil.rmtree(dst_p, ignore_errors=True)
        shutil.rmtree(src_p, ignore_errors=True)
        if src_p.parent.is_dir():
            (src_p.parent / 'aoc.key').unlink(missing_ok=True)
        return 0

    if _same_path(src_p, dst_p):
        return len(entries)

    dst_p.parent.mkdir(parents=True, exist_ok=True)
    partial = dst_p.parent / f'.{dst_p.name}.partial-{uuid.uuid4().hex[:8]}'
    backup = dst_p.parent / f'.{dst_p.name}.old-{uuid.uuid4().hex[:8]}'
    backed_up = False

    try:
        try:
            os.replace(src_p, partial)
        except OSError:
            shutil.copytree(src_p, partial, symlinks=True)

        if dst_p.exists() or dst_p.is_symlink():
            os.replace(dst_p, backup)
            backed_up = True

        try:
            os.replace(partial, dst_p)
        except BaseException:
            # Always clean any half-written target directory first, then restore `.old` if present
            shutil.rmtree(dst_p, ignore_errors=True)
            if dst_p.exists() or dst_p.is_symlink():
                dst_p.unlink(missing_ok=True)
            if backed_up and backup.exists():
                try:
                    os.replace(backup, dst_p)
                except OSError:
                    pass
            raise

        if backed_up and backup.exists():
            shutil.rmtree(backup, ignore_errors=True)
    finally:
        if partial.exists():
            shutil.rmtree(partial, ignore_errors=True)

    shutil.rmtree(src_p, ignore_errors=True)
    if src_p.parent.is_dir():
        (src_p.parent / 'aoc.key').unlink(missing_ok=True)
        shutil.rmtree(src_p.parent / 'aoc.partial', ignore_errors=True)
    return len(entries)


def link_or_copy_file(src: str | os.PathLike, dst: str | os.PathLike) -> None:
    """Hard-link `src` to `dst` when on the same volume, falling back to `shutil.copy2`."""
    src_p = Path(src)
    dst_p = Path(dst)
    if _same_path(src_p, dst_p):
        return
    dst_p.parent.mkdir(parents=True, exist_ok=True)
    dst_p.unlink(missing_ok=True)
    try:
        os.link(src_p, dst_p)
    except OSError:
        shutil.copy2(src_p, dst_p)


def link_or_copy_tree(src: str | os.PathLike, dst: str | os.PathLike) -> None:
    """Mirror directory `src` to `dst`, hard-linking regular files when supported."""
    src_p = Path(src)
    dst_p = Path(dst)
    shutil.rmtree(dst_p, ignore_errors=True)
    dst_p.mkdir(parents=True, exist_ok=True)
    for item in src_p.iterdir():
        target = dst_p / item.name
        if item.is_symlink():
            link_to = os.readlink(item)
            os.symlink(link_to, target)
        elif item.is_dir():
            link_or_copy_tree(item, target)
        else:
            link_or_copy_file(item, target)


def clean_pso_batches(pso_work_dir: str | os.PathLike) -> None:
    """Remove merged `batches.*` shard folders inside `pso_work_dir`, keeping `key.*` stamps."""
    work_p = Path(pso_work_dir)
    if not work_p.is_dir():
        return
    try:
        children = list(work_p.iterdir())
    except OSError:
        return
    for child in children:
        if child.name.startswith('batches.'):
            if child.is_dir() and not child.is_symlink():
                shutil.rmtree(child, ignore_errors=True)
            else:
                child.unlink(missing_ok=True)


def _remove_entry(p: Path) -> None:
    try:
        if p.is_symlink() or p.is_file():
            p.unlink(missing_ok=True)
        elif p.is_dir():
            shutil.rmtree(p, ignore_errors=True)
    except OSError:
        pass


def clean_work_dir(
    work_dir: str | os.PathLike,
    *,
    remove_extracted_romfs: bool = True,
    remove_shell_framework: bool = False,
) -> None:
    """Remove redundant staging files inside `<titleID>_build` after a build succeeds."""
    if not work_dir:
        return
    work_p = Path(work_dir)
    if not work_p.is_dir():
        return

    for rel in (
        'nsp',
        'nsp.partial',
        'ipa/build/ios/pkg/dd/Build/Products',
        'ipa/build/ios/win/Payload',
        'build/ios/win/Payload',
    ):
        _remove_entry(work_p / rel)

    for pso_rel in ('pso/mac-work', 'ipa/build/ios/pso/work', 'build/ios/pso/work'):
        clean_pso_batches(work_p / pso_rel)

    if remove_extracted_romfs:
        extract_dir = work_p / 'extract'
        if extract_dir.is_dir():
            try:
                ex_children = list(extract_dir.iterdir())
            except OSError:
                ex_children = []
            for child in ex_children:
                if child.name.endswith('.partial'):
                    _remove_entry(child)
                elif child.name.startswith('v') and child.is_dir() and not child.is_symlink():
                    for rom_name in ('RomFS.img', 'RomFS.img.id', 'RomFS.img.formats', 'RomFS'):
                        _remove_entry(child / rom_name)
        _remove_entry(work_p / 'aoc')
        _remove_entry(work_p / 'aoc.partial')
        _remove_entry(work_p / 'aoc.key')

    if remove_shell_framework:
        _remove_entry(work_p / 'shell-framework')


def clean_built_framework_container(framework_path: str | os.PathLike) -> None:
    """Remove `<work>/shell-framework` when `framework_path` lives inside it (never `<shell>/frameworks`)."""
    if not framework_path:
        return
    fw_p = Path(framework_path)
    container = fw_p.parent
    if container.name == 'shell-framework' and container.is_dir() and not container.is_symlink():
        shutil.rmtree(container, ignore_errors=True)
