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
_FORBIDDEN_NAME_CHARS = frozenset('/\\:*?"<>|')
_WIN_RESERVED_NAMES = frozenset({
    'CON', 'PRN', 'AUX', 'NUL',
    *(f'COM{i}' for i in range(1, 10)),
    *(f'LPT{i}' for i in range(1, 10)),
})


def _same_path(a: Path, b: Path) -> bool:
    try:
        return os.path.samefile(a, b)
    except OSError:
        return os.path.normcase(os.path.abspath(a)) == os.path.normcase(os.path.abspath(b))


def _same_location(a: Path, b: Path) -> bool:
    try:
        return a.resolve() == b.resolve()
    except OSError:
        return os.path.normcase(os.path.abspath(a)) == os.path.normcase(os.path.abspath(b))


def sanitize_game_name(name: str, fallback: str = '') -> str:
    """Return a cross-platform safe folder/image stem for `name`, or `fallback` if unusable."""
    cleaned_chars = [
        ch for ch in (name or '')
        if ch not in _FORBIDDEN_NAME_CHARS and ord(ch) >= 0x20 and ord(ch) != 0x7F
    ]
    collapsed = re.sub(r'\s+', ' ', ''.join(cleaned_chars))
    trimmed = collapsed.lstrip(' ').rstrip(' .')
    if not trimmed:
        return fallback
    stem = trimmed.split('.', 1)[0].rstrip(' ').upper()
    if trimmed.upper() in _WIN_RESERVED_NAMES or stem in _WIN_RESERVED_NAMES:
        return fallback
    return trimmed


def read_title_id_marker(folder: str | os.PathLike) -> str:
    """Read the uppercased TitleID from `<folder>/.titleid`, or `''` when absent/unreadable."""
    if not folder:
        return ''
    marker = Path(folder) / '.titleid'
    if not marker.is_file():
        return ''
    try:
        for line in marker.read_text(encoding='utf-8', errors='replace').splitlines():
            val = line.strip().upper()
            if val:
                return val
    except OSError:
        pass
    return ''


def write_title_id_marker(folder: str | os.PathLike, title_id: str) -> None:
    """Atomically write `<folder>/.titleid` containing the uppercased `title_id`."""
    tid = (title_id or '').strip().upper()
    if not folder or not tid:
        return
    folder_p = Path(folder)
    folder_p.mkdir(parents=True, exist_ok=True)
    dest = folder_p / '.titleid'
    tmp = folder_p / f'.titleid.partial-{uuid.uuid4().hex[:8]}'
    try:
        tmp.write_text(f'{tid}\n', encoding='utf-8')
        os.replace(tmp, dest)
    finally:
        tmp.unlink(missing_ok=True)


def _is_candidate_top_img(entry: Path) -> bool:
    name = entry.name
    if name.startswith('.'):
        return False
    low = name.lower()
    if not low.endswith('.img') or low.endswith('.id') or '.nxpart' in low:
        return False
    try:
        return entry.is_file()
    except OSError:
        return False


def primary_romfs_image(archive_dir: str | os.PathLike) -> Path | None:
    """Return the primary RomFS `.img` inside `archive_dir`, or `None` when absent.

    Prefers `<dir.name>.img`, then `romfs.img`, then the sole top-level non-hidden `*.img`
    file (ignoring `.*`, `*.id`, `*.nxpart*`, and subdirectories such as `aoc/`).
    """
    if not archive_dir:
        return None
    d = Path(archive_dir)
    if not d.is_dir():
        return None

    exact_named = d / f'{d.name}.img'
    if _is_candidate_top_img(exact_named):
        return exact_named

    exact_legacy = d / 'romfs.img'
    if _is_candidate_top_img(exact_legacy):
        return exact_legacy

    try:
        entries = sorted(d.iterdir(), key=lambda p: p.name)
    except OSError:
        return None

    top_imgs = [e for e in entries if _is_candidate_top_img(e)]
    if not top_imgs:
        return None

    want_named_low = f'{d.name}.img'.lower()
    for e in top_imgs:
        if e.name.lower() == want_named_low:
            return e
    for e in top_imgs:
        if e.name.lower() == 'romfs.img':
            return e
    if len(top_imgs) == 1:
        return top_imgs[0]
    return None


def _id_sidecar_title(id_file: Path) -> str:
    try:
        raw = id_file.read_text(encoding='utf-8', errors='replace').strip()
    except OSError:
        return ''
    if not raw:
        return ''
    first_line = raw.splitlines()[0].strip()
    parts = first_line.split()
    if parts and parts[0] == 'DMROMFSID1':
        for tok in parts[1:]:
            if tok.startswith('title='):
                val = tok.split('=', 1)[1].strip().upper()
                if val and val != '-':
                    return val
    try:
        data = json.loads(raw)
        if isinstance(data, dict):
            val = str(data.get('title') or '').strip().upper()
            if val and val != '-':
                return val
    except (ValueError, TypeError):
        pass
    return ''


_PAREN_HEX16_RE = re.compile(r'\(([0-9A-Fa-f]{16})\)\s*$')


def folder_claimed_title_id(folder: str | os.PathLike) -> str:
    """Return the uppercased TitleID recorded for `folder` via `.titleid`, hex name, or `.img.id`."""
    if not folder:
        return ''
    d = Path(folder)
    marker = read_title_id_marker(d)
    if marker:
        return marker
    if _HEX16_RE.match(d.name):
        return d.name.upper()
    img = primary_romfs_image(d)
    if img is not None:
        for id_cand in (Path(f'{img}.id'), d / 'romfs.img.id'):
            if id_cand.is_file():
                tid = _id_sidecar_title(id_cand)
                if tid:
                    return tid
    m = _PAREN_HEX16_RE.search(d.name)
    if m:
        return m.group(1).upper()
    return ''


def archive_directory_name(
    game_name: str,
    title_id: str,
    games_root: str | os.PathLike | None = None,
) -> str:
    """Choose the archive folder name for `(game_name, title_id)` under `games_root`.

    Uses `sanitize_game_name(game_name, fallback=tid)`, disambiguating to `f"{safe} ({tid})"`
    when `<games_root>/<safe>` already exists and belongs to a different TitleID.
    """
    tid = (title_id or '').strip().upper()
    safe = sanitize_game_name(game_name or '', fallback=tid)
    if not safe:
        return tid
    if not tid or not games_root:
        return safe

    root_p = Path(games_root)
    cand = root_p / safe
    if not cand.exists() and not cand.is_symlink():
        return safe
    if not cand.is_dir():
        return sanitize_game_name(f'{safe} ({tid})', fallback=tid)

    owner = folder_claimed_title_id(cand)
    if owner and owner != tid:
        return sanitize_game_name(f'{safe} ({tid})', fallback=tid)
    return safe


def _app_matches_title_id(app_dir: Path, id_file: Path, expected_upper: str) -> bool:
    tid = _id_sidecar_title(id_file)
    if tid:
        return tid == expected_upper
    plist_p = app_dir / 'Contents' / 'Info.plist'
    if plist_p.is_file():
        try:
            with open(plist_p, 'rb') as f:
                info = plistlib.load(f)
            if isinstance(info, dict):
                raw_tid = str(info.get('DMTitleID') or '').strip()
                if raw_tid:
                    return raw_tid.upper() == expected_upper
        except Exception:
            pass
    return False


def reusable_romfs_images(root: str | os.PathLike, key: str) -> list[str]:
    """Return existing RomFS `.img` paths in `root` that carry a `.id` sidecar for `key`.

    Checks `<SafeName>/<SafeName>.img` (via `.titleid` or `.img.id`), legacy `games/<KEY>/romfs.img`,
    `<key>.app/Contents/Resources/romfs.img`, and any renamed non-symlink `<DisplayName>.app` bundle
    in `root` whose `.id` `"title"` or `Info.plist` `"DMTitleID"` matches `key`.
    """
    if not root or not key:
        return []
    root_p = Path(root)
    key_up = key.strip().upper()
    is_hex_tid = bool(_HEX16_RE.match(key_up))
    found: list[str] = []
    seen_norm: set[str] = set()

    def _add(img: Path | None) -> None:
        if img is None:
            return
        norm = os.path.normcase(os.path.abspath(img))
        if norm in seen_norm:
            return
        if img.is_file() and Path(f'{img}.id').is_file():
            seen_norm.add(norm)
            found.append(str(img))

    games_dir = root_p / 'games'
    if games_dir.is_dir():
        if is_hex_tid:
            try:
                sub_dirs = sorted(games_dir.iterdir(), key=lambda p: p.name)
            except OSError:
                sub_dirs = []
            for sub in sub_dirs:
                if sub.name.startswith('.') or sub.is_symlink() or not sub.is_dir():
                    continue
                if sub.name.upper() == key_up:
                    continue
                claimed = folder_claimed_title_id(sub)
                if claimed == key_up:
                    _add(primary_romfs_image(sub))
            legacy_dir = games_dir / key_up
            if legacy_dir.is_dir():
                _add(primary_romfs_image(legacy_dir))
                _add(legacy_dir / 'romfs.img')
        else:
            try:
                sub_dirs = sorted(games_dir.iterdir(), key=lambda p: p.name)
            except OSError:
                sub_dirs = []
            for sub in sub_dirs:
                if sub.name.startswith('.') or sub.is_symlink() or not sub.is_dir():
                    continue
                _add(primary_romfs_image(sub))

    _add(root_p / f'{key}.app' / 'Contents' / 'Resources' / 'romfs.img')

    if root_p.is_dir():
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
            if img.is_file() and id_file.is_file():
                if not is_hex_tid or _app_matches_title_id(entry, id_file, key_up):
                    _add(img)

    return found


def ensure_unshared_file(path: str | os.PathLike) -> None:
    """Break any shared hardlink (`st_nlink > 1`) on `path` so in-place trailer edits never mutate peers."""
    p = Path(path)
    if not p.is_file():
        return
    try:
        st = p.stat()
    except OSError:
        return
    if getattr(st, 'st_nlink', 1) <= 1:
        return
    tmp = p.parent / f'.{p.name}.unshare-{uuid.uuid4().hex[:8]}'
    try:
        shutil.copy2(p, tmp)
        os.replace(tmp, p)
    finally:
        tmp.unlink(missing_ok=True)


def _sync_id_sidecar(src_img: Path, dst_img: Path, *, preserve_existing: bool = False) -> None:
    id_src = Path(f'{src_img}.id')
    id_dst = Path(f'{dst_img}.id')
    if id_src.is_file():
        if _same_location(id_src, id_dst):
            ensure_unshared_file(id_dst)
            return
        tmp_id = id_dst.parent / f'.{id_dst.name}.partial-{uuid.uuid4().hex[:8]}'
        try:
            shutil.copy2(id_src, tmp_id)
            os.replace(tmp_id, id_dst)
        finally:
            tmp_id.unlink(missing_ok=True)
    elif not preserve_existing:
        id_dst.unlink(missing_ok=True)


def _clean_stale_legacy_images(dst_img: Path) -> None:
    """Remove split archive remnants and stale `romfs.img`/`.id` siblings when `dst_img` uses `<SafeName>.img`."""
    parent = dst_img.parent
    try:
        children = list(parent.iterdir())
    except OSError:
        return
    id_dst = Path(f'{dst_img}.id')
    is_named_non_legacy = dst_img.name.lower() != 'romfs.img'
    stale_legacy_names = frozenset({
        'romfs.img',
        'romfs.img.id',
        'romfs.img.formats',
        'romfs.img.inputs.json',
    })
    for child in children:
        cname = child.name
        clow = cname.lower()
        if cname == 'romfs.idx' or (cname.startswith('romfs.') and cname[6:].isdigit()):
            child.unlink(missing_ok=True)
            continue
        if is_named_non_legacy and clow in stale_legacy_names:
            if not _same_path(child, dst_img) and not _same_path(child, id_dst):
                child.unlink(missing_ok=True)


def _remove_source_image_sidecars(src_img: Path) -> None:
    for p in (src_img, Path(f'{src_img}.id'), Path(f'{src_img}.formats')):
        try:
            p.unlink(missing_ok=True)
        except OSError:
            pass


def place_image(
    src: str | os.PathLike,
    dst: str | os.PathLike,
    *,
    unshare_hardlink: bool = True,
) -> str:
    """Place `src` (`RomFS.img`) at `dst` (`<FolderName>.img` or `romfs.img`), syncing `.id` and removing `src`.

    Returns `'reused'`, `'moved'`, or `'copied'`. An existing `dst` stays untouched if an
    error occurs before the final atomic `os.replace`. When `unshare_hardlink` is True, ensures
    `dst` does not remain hardlinked (`st_nlink > 1`) to another file so subsequent in-place
    trailer updates cannot corrupt a shared source.
    """
    src_p = Path(src)
    dst_p = Path(dst)
    dst_p.parent.mkdir(parents=True, exist_ok=True)

    if _same_location(src_p, dst_p):
        if unshare_hardlink:
            ensure_unshared_file(dst_p)
        _clean_stale_legacy_images(dst_p)
        return 'reused'

    if dst_p.is_file() and _same_path(src_p, dst_p):
        _sync_id_sidecar(src_p, dst_p, preserve_existing=True)
        _remove_source_image_sidecars(src_p)
        if unshare_hardlink:
            ensure_unshared_file(dst_p)
        _clean_stale_legacy_images(dst_p)
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
            id_src = Path(f'{src_p}.id')
            id_dst = Path(f'{dst_p}.id')
            preserve_legacy_id = (
                not id_src.is_file()
                and not id_dst.is_file()
                and dst_p.name.lower() != 'romfs.img'
                and (dst_p.parent / 'romfs.img.id').is_file()
            )
            if preserve_legacy_id:
                _sync_id_sidecar(dst_p.parent / 'romfs.img', dst_p, preserve_existing=True)
            else:
                _sync_id_sidecar(src_p, dst_p, preserve_existing=False)
            _remove_source_image_sidecars(src_p)
            if unshare_hardlink:
                ensure_unshared_file(dst_p)
            _clean_stale_legacy_images(dst_p)
            return 'reused'

    partial = dst_p.parent / f'.{dst_p.name}.partial-{uuid.uuid4().hex[:8]}'
    id_src = Path(f'{src_p}.id')
    id_dst = Path(f'{dst_p}.id')
    id_partial = id_dst.parent / f'.{id_dst.name}.partial-{uuid.uuid4().hex[:8]}'
    has_id = id_src.is_file()
    preserve_legacy_id = (
        not has_id
        and not id_dst.is_file()
        and dst_p.name.lower() != 'romfs.img'
        and (dst_p.parent / 'romfs.img.id').is_file()
    )
    if preserve_legacy_id:
        id_src = dst_p.parent / 'romfs.img.id'
        has_id = True
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
    if unshare_hardlink:
        ensure_unshared_file(dst_p)
    _clean_stale_legacy_images(dst_p)
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
