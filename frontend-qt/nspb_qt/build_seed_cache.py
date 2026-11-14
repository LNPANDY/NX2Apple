"""Build seed cache discovery, validation, and trailer reuse logic.

Pure Python module (NO PySide6 dependency). Mirrors the Swift BuildSeedCache implementation.
"""
from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path
from typing import Any

TRAILER_MAGIC = b'DMMSLTR1'
FOOTER_SIZE = 64


def default_seed_root() -> Path:
    """Return the folder holding persistent build seeds.

    Respects DM_SEED_CACHE_DIR if set, otherwise defaulting to the platform-specific
    application support directory under 'nxnative/build-seeds'.
    """
    if env_dir := os.environ.get('DM_SEED_CACHE_DIR'):
        return Path(env_dir)

    if sys.platform == 'win32' or os.name == 'nt':
        base = Path(os.environ.get('LOCALAPPDATA') or os.environ.get('APPDATA') or Path.home() / 'AppData' / 'Local')
    elif sys.platform == 'darwin':
        base = Path.home() / 'Library' / 'Application Support'
    else:
        base = Path(os.environ.get('XDG_DATA_HOME') or Path.home() / '.local' / 'share')

    return base / 'nxnative' / 'build-seeds'


def supports_build_seed(repo_path: str | Path | None) -> bool:
    """Check whether the engine checkout supports building from a seed cache (--from-seed)."""
    if not repo_path:
        return False
    script = Path(repo_path) / 'scripts' / 'build_ipa_from_nsp.py'
    if not script.is_file():
        return False
    try:
        text = script.read_text(encoding='utf-8', errors='replace')
        return '--from-seed' in text
    except OSError:
        return False


def supports_extract_msl(repo_path: str | Path | None) -> bool:
    """Check whether romfs_image.py supports the --extract-msl operation."""
    if not repo_path:
        return False
    script = Path(repo_path) / 'dm' / 'tools' / 'romfs_image.py'
    if not script.is_file():
        return False
    try:
        text = script.read_text(encoding='utf-8', errors='replace')
        return '--extract-msl' in text
    except OSError:
        return False


def normalize_chain(chain: str | None) -> str:
    """Normalize a shader chain identifier to bare lowercase hex without 'b-' prefix."""
    s = (chain or '').strip().lower()
    if s.startswith('b-'):
        return s[2:]
    return s


def current_engine_chain(engine_path: str | Path | None) -> str | None:
    """Read the current shader chain identifier from dmsh_chain.h if available."""
    if not engine_path:
        return None
    hdr = Path(engine_path) / 'dm' / 'gfx' / 'nvn' / 'dmsh_chain.h'
    if not hdr.is_file():
        return None
    try:
        text = hdr.read_text(encoding='utf-8', errors='replace')
        m = re.search(r'#define\s+DMSH_CHAIN\s+"([^"]+)"', text)
        return normalize_chain(m.group(1)) if m else None
    except OSError:
        return None


def inspect_seed(
    seed_root: str | Path,
    title_id: str,
    engine_path: str | Path | None = None,
) -> dict[str, Any]:
    """Inspect and validate a persistent build seed for a title ID.

    Returns a dict describing whether the seed is valid, its path type ('A' when the shader
    chain matches the current engine, 'B' when it differs and requires prefill recompile),
    extracted metadata, and reasons if invalid.
    """
    tid_clean = title_id.strip()
    tid_up = tid_clean.upper()
    root = Path(seed_root)
    seed_dir = root / tid_up
    if not seed_dir.is_dir() and (root / tid_clean).is_dir():
        seed_dir = root / tid_clean

    engine_chain = current_engine_chain(engine_path)

    result: dict[str, Any] = {
        'valid': False,
        'seed_dir': seed_dir,
        'path_type': 'B',
        'chain_match': False,
        'chain': '',
        'engine_chain': engine_chain,
        'gfx_api': '',
        'seed_data': {},
        'romfs_identity': None,
        'reason': None,
    }

    if not seed_dir.is_dir():
        result['reason'] = f'seed directory not found: {seed_dir}'
        return result

    seed_json_path = seed_dir / 'seed.json'
    if not seed_json_path.is_file():
        result['reason'] = f'seed.json missing in {seed_dir}'
        return result

    try:
        data = json.loads(seed_json_path.read_text(encoding='utf-8'))
        if not isinstance(data, dict):
            result['reason'] = 'seed.json root is not an object'
            return result
    except (json.JSONDecodeError, OSError) as e:
        result['reason'] = f'corrupt seed.json: {e}'
        return result

    result['seed_data'] = data
    seed_chain = normalize_chain(data.get('chain'))
    gfx_api = str(data.get('gfx_api') or '').strip().lower()
    result['chain'] = seed_chain
    result['gfx_api'] = gfx_api
    result['romfs_identity'] = data.get('romfs_identity')

    # Structural verification: ExeFS, shader/pkg, shader/ios
    exefs_dir = seed_dir / 'ExeFS'
    if not exefs_dir.is_dir() or not any(exefs_dir.iterdir()):
        result['reason'] = f'ExeFS missing or empty in {seed_dir}'
        return result

    shader_pkg = seed_dir / 'shader' / 'pkg'
    if not shader_pkg.is_dir():
        result['reason'] = f'shader/pkg directory missing in {seed_dir}'
        return result

    shader_ios = seed_dir / 'shader' / 'ios'
    if not shader_ios.is_dir():
        result['reason'] = f'shader/ios directory missing in {seed_dir}'
        return result

    if gfx_api == 'nvn':
        tables_dir = seed_dir / 'shader' / 'tables'
        c1 = tables_dir / 'c1_full.tsv'
        cb = tables_dir / 'cb_extent.tsv'
        if not tables_dir.is_dir() or not c1.is_file() or not cb.is_file():
            result['reason'] = f'shader/tables (c1_full.tsv/cb_extent.tsv) missing in {seed_dir}'
            return result

    # Path A vs Path B determination
    if engine_chain:
        chain_match = (seed_chain == engine_chain)
    else:
        chain_match = bool(seed_chain)

    result['valid'] = True
    result['chain_match'] = chain_match
    result['path_type'] = 'A' if chain_match else 'B'
    return result


def _image_has_trailer(path: Path) -> bool:
    """Quickly check if a file ends with the 8-byte trailer magic without full parsing."""
    try:
        size = path.stat().st_size
        if size < FOOTER_SIZE:
            return False
        with open(path, 'rb') as f:
            f.seek(size - 8)
            return f.read(8) == TRAILER_MAGIC
    except OSError:
        return False


def prefill_candidates(
    title_id: str,
    out_dir: str | Path | None,
    game_name: str = '',
    work_dir: str | Path | None = '',
) -> list[Path]:
    """Discover existing `.img` files with `DMMSLTR1` trailers, `.app` bundles, or shader caches for `--prefill-msl`."""
    tid = title_id.strip()
    tid_up = tid.upper()
    tid_low = tid.lower()

    candidates: list[Path] = []
    seen: set[str] = set()

    def add(p: Path | None, verify_img: bool = True) -> None:
        if p is None:
            return
        rp = p.resolve() if p.exists() else p
        s = str(rp)
        if s in seen:
            return
        if p.is_file():
            if not verify_img or _image_has_trailer(p):
                candidates.append(p)
                seen.add(s)
        elif p.is_dir():
            if p.suffix == '.app':
                res_img = p / 'Contents' / 'Resources' / 'romfs.img'
                msl_dir = p / 'Contents' / 'Resources' / 'msl'
                if msl_dir.is_dir() or (res_img.is_file() and _image_has_trailer(res_img)):
                    candidates.append(p)
                    seen.add(s)
            else:
                has_sub = (
                    any(p.glob('*.metallib'))
                    or any(p.glob('*.metal'))
                    or any(p.glob('b-*.img'))
                    or any(p.glob('*/b-*.img'))
                    or (p / 'inputs.tsv').is_file()
                )
                if not has_sub:
                    for sub in ('vk', 'gl'):
                        sp = p / sub
                        if sp.is_dir() and (any(sp.glob('*.metallib')) or any(sp.glob('*.metal'))):
                            has_sub = True
                            break
                if not has_sub:
                    for sub in p.glob('p*'):
                        if sub.is_dir() and (any(sub.glob('*.metallib')) or any(sub.glob('*.metal'))):
                            has_sub = True
                            break
                if has_sub:
                    candidates.append(p)
                    seen.add(s)

    out_p = Path(out_dir) if out_dir else None
    if out_p:
        games_dir = out_p / 'games'
        if game_name:
            add(games_dir / game_name / f'{game_name}.img')
            add(games_dir / game_name / 'romfs.img')
            add(games_dir / game_name / f'{game_name}.app', verify_img=False)
            add(out_p / f'{game_name}.app', verify_img=False)

        add(games_dir / tid_up / f'{tid_up}.img')
        add(games_dir / tid_up / 'romfs.img')
        add(games_dir / tid_low / f'{tid_low}.img')
        add(games_dir / tid_low / 'romfs.img')
        add(out_p / tid_up / 'romfs.img')
        add(out_p / f'{tid_up}.app', verify_img=False)
        add(out_p / 'romfs' / 'romfs.img')

    work_p = Path(work_dir) if work_dir else None
    if work_p:
        add(work_p / 'build' / 'ios' / 'dmsh_b', verify_img=False)
        add(work_p / 'shader' / 'cache', verify_img=False)
        add(work_p / 'shader' / 'ios', verify_img=False)
        add(work_p / 'msl', verify_img=False)
        if (work_p / 'extract').is_dir():
            for vdir in (work_p / 'extract').glob('v*'):
                if vdir.is_dir():
                    add(vdir / 'RomFS.img')
        if (work_p / 'data').is_dir():
            for pdir in (work_p / 'data').iterdir():
                if pdir.is_dir():
                    add(pdir / 'RomFS.img')
        add(work_p / 'data' / 'romfs.img')
        add(work_p / 'romfs.img')

    return candidates


def find_romfs_candidates(
    title_id: str,
    out_dir: str | Path | None,
    game_name: str = '',
    work_dir: str | Path | None = '',
) -> list[Path]:
    """Find any existing RomFS .img files (with or without trailer) or .app bundles for adopt and mac-app."""
    tid = title_id.strip()
    tid_up = tid.upper()
    tid_low = tid.lower()

    candidates: list[Path] = []
    seen: set[str] = set()

    def add(p: Path | None) -> None:
        if p is None or not p.exists():
            return
        rp = p.resolve()
        s = str(rp)
        if s in seen:
            return
        if p.is_file() and p.suffix.lower() == '.img':
            candidates.append(p)
            seen.add(s)
        elif p.is_dir() and p.suffix.lower() == '.app':
            candidates.append(p)
            seen.add(s)

    out_p = Path(out_dir) if out_dir else None
    if out_p:
        games_dir = out_p / 'games'
        if game_name:
            add(games_dir / game_name / f'{game_name}.img')
            add(games_dir / game_name / 'romfs.img')
            add(games_dir / game_name / f'{game_name}.app')
            add(out_p / f'{game_name}.app')

        add(games_dir / tid_up / f'{tid_up}.img')
        add(games_dir / tid_up / 'romfs.img')
        add(games_dir / tid_low / f'{tid_low}.img')
        add(games_dir / tid_low / 'romfs.img')
        add(out_p / tid_up / 'romfs.img')
        add(out_p / f'{tid_up}.app')
        add(out_p / 'romfs' / 'romfs.img')

    work_p = Path(work_dir) if work_dir else None
    if work_p:
        if (work_p / 'extract').is_dir():
            for vdir in (work_p / 'extract').glob('v*'):
                if vdir.is_dir():
                    add(vdir / 'RomFS.img')
        if (work_p / 'data').is_dir():
            for pdir in (work_p / 'data').iterdir():
                if pdir.is_dir():
                    add(pdir / 'RomFS.img')
        add(work_p / 'data' / 'romfs.img')
        add(work_p / 'romfs.img')

    return candidates


def trailer_action(
    inspect_info: dict[str, Any] | None,
    gfx_api: str,
    chain: str,
    multi_program: bool = False,
) -> str:
    """Determine the trailer modification action for a RomFS image.

    Returns:
    - 'skip': trailer exists and all metadata (gfx_api, chain, multi_program) matches exactly (0 disk I/O).
    - 'append': image has no trailer yet.
    - 'replace': trailer exists but chain or graphics settings differ.
    """
    if not inspect_info or not inspect_info.get('has_trailer'):
        return 'append'

    existing_api = str(inspect_info.get('gfx_api') or '').strip().lower() or 'nvn'
    target_api = str(gfx_api or '').strip().lower() or 'nvn'

    existing_chain = normalize_chain(inspect_info.get('chain'))
    target_chain = normalize_chain(chain)

    existing_mp = bool(inspect_info.get('multi_program'))
    target_mp = bool(multi_program)

    if existing_api != target_api or existing_mp != target_mp:
        return 'replace'

    if target_api == 'nvn':
        if not target_chain or not existing_chain or existing_chain != target_chain:
            return 'replace'
        return 'skip'

    # Non-NVN (vk / gl)
    if existing_chain == target_chain:
        return 'skip'
    return 'replace'
