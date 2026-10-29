"""Where the engine of a checkout is, and whether it needs `tools/engine.py sync` (LNPANDY/NX2Apple#214).

Since #214 the engine is built into `<checkout>/engine/` (seedds/nxnative at `.upstream-ref` plus `patches/`). Until the
committed copy goes (step 2), a checkout has both, and one from before the switch has only the committed copy. The rule, the
same as the Mac launcher's (frontend/Sources/NSPortBuilder/Engine.swift):

- engine/ when it is synced and current,
- else the committed tree (dm/, scripts/ at the checkout's root) when the checkout has one,
- else engine/ as it is (stale or missing: the caller syncs first).

`stamp_key` is tools/engine.py's: a digest of the pin and the series, compared with the stamp sync wrote into engine/.git, so
the launcher can tell a stale engine without starting Python. Pure stdlib, no Qt.
"""
from __future__ import annotations

import hashlib
from pathlib import Path

MARKER = ('dm', 'tools', 'nx_extract', 'Program.cs')   # the file that tells an engine tree (as BuildModel.is_repo always did)
STAMP = Path('.git', 'nx2apple-stamp')


def _series(root: Path) -> list[str]:
    out = []
    for line in (root / 'patches' / 'series').read_text(encoding='utf-8').splitlines():
        line = line.split('#', 1)[0].strip()
        if line:
            out.append(line)
    return out


def stamp_key(root: str | Path) -> str:
    root = Path(root)
    h = hashlib.sha256()
    h.update(b'pin ' + (root / '.upstream-ref').read_text(encoding='utf-8').strip().encode() + b'\n')
    for name in _series(root):
        data = (root / 'patches' / name).read_bytes()
        h.update(b'patch ' + name.encode() + b'\n' + hashlib.sha256(data).hexdigest().encode() + b'\n')
    return h.hexdigest()


def has_engine_tool(repo: str) -> bool:
    """A checkout with tools/engine.py: it can make its engine/ (the layout of #214)."""
    return bool(repo) and Path(repo, 'tools', 'engine.py').is_file() and Path(repo, '.upstream-ref').is_file()


def _head(eng: Path) -> str:
    """HEAD of engine/ read from its files (no git process): the detached id, or the id its branch points to."""
    git = eng / '.git'
    try:
        head = (git / 'HEAD').read_text(encoding='utf-8').strip()
    except OSError:
        return ''
    if not head.startswith('ref: '):
        return head
    ref = head[5:]
    try:
        return (git / ref).read_text(encoding='utf-8').strip()
    except OSError:
        pass
    try:
        for line in (git / 'packed-refs').read_text(encoding='utf-8').splitlines():
            if line.endswith(' ' + ref):
                return line.split(' ', 1)[0]
    except OSError:
        pass
    return ''


def is_stale(repo: str) -> bool:
    """True when the checkout can make engine/ and engine/ is missing or not built from the current pin and series."""
    if not has_engine_tool(repo):
        return False
    eng = Path(repo, 'engine')
    try:
        stamp = dict(l.split(' ', 1) for l in (eng / STAMP).read_text(encoding='utf-8').splitlines() if ' ' in l)
        return stamp.get('key') != stamp_key(repo) or stamp.get('head') != _head(eng)
    except (OSError, ValueError):
        return True


def engine_root(repo: str) -> str:
    """The folder holding dm/ and scripts/ for this checkout (see the module's rule)."""
    if not repo:
        return repo
    eng = Path(repo, 'engine')
    if eng.joinpath(*MARKER).is_file() and not is_stale(repo):
        return str(eng)
    if Path(repo, *MARKER).is_file():
        return repo
    return str(eng) if has_engine_tool(repo) else repo


def is_checkout(d: str) -> bool:
    """A checkout the launcher can build from: the committed tree, a synced engine/, or tools/engine.py to make one."""
    return bool(d) and (Path(d, *MARKER).is_file() or Path(d, 'engine', *MARKER).is_file() or has_engine_tool(d))


def needs_sync_before_build(repo: str) -> bool:
    """engine/ is the only engine and it is stale or missing (after step 2, or a checkout whose committed tree is gone)."""
    return has_engine_tool(repo) and is_stale(repo) and not Path(repo, *MARKER).is_file()


def sync_command(repo: str, python: str) -> list[str]:
    return [python, str(Path(repo, 'tools', 'engine.py')), 'sync']
