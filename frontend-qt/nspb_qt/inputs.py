"""Sorting a folder's game files into base, update and DLC by the title ID in their names.
The same rules as the Mac launcher's BuildModel.classify, so both front ends agree."""
from __future__ import annotations

import re
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
