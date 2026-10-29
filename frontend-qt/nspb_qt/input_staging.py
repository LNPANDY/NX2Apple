"""The folder the build script reads when the picked game files live in more than one folder (#132).

The script keys a provisional profile's shader split and shader build on the files' size and
modification time and on the profile's path (<input folder>/<title ID>_build/profile), so the folder
must be the same one on every build of a game: it sits in the game's build folder, is never deleted
after a build, and holds exactly the current selection. The build's own folders beside the files
(<title ID>_build, <title ID>_survey) are left alone.
"""
from __future__ import annotations

import os
import shutil
from pathlib import Path

FOLDER_NAME = 'staging'
GAME_SUFFIXES = {'.nsp', '.xci', '.nsz', '.xcz'}


def folder(work_dir: str) -> str:
    return str(Path(work_dir, FOLDER_NAME))


def _same(src: str, dst: Path) -> bool:
    """dst is already src: the same file, or a copy with its size and date."""
    try:
        if os.path.samefile(src, dst):
            return True
        a, b = os.stat(src), os.stat(dst)
        return a.st_size == b.st_size and a.st_mtime_ns == b.st_mtime_ns
    except OSError:
        return False


def sync(files: list[str], into: str, *, hard_links: bool = True) -> int:
    """Make `into` hold exactly `files` (by file name), with their dates. Returns how many were linked."""
    root = Path(into)
    root.mkdir(parents=True, exist_ok=True)
    wanted = {Path(f).name: f for f in files if f}
    for entry in root.iterdir():   # a stale entry from an earlier selection goes: only game files and links
        if entry.is_symlink() or (entry.is_file() and entry.suffix.lower() in GAME_SUFFIXES):
            src = wanted.get(entry.name)
            if src and entry.exists() and _same(src, entry):
                continue
            entry.unlink(missing_ok=True)
    linked = 0
    for name, src in wanted.items():
        dst = root / name
        if dst.exists() and _same(src, dst):
            linked += 1
            continue
        try:
            if hard_links:
                os.link(src, dst)
            else:
                raise OSError
        except OSError:
            try:
                shutil.copy2(src, dst)   # copy2 keeps the modification date
            except OSError:
                continue
        linked += 1
    return linked
