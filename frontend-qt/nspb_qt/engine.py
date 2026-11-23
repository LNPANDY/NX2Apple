"""Where the engine of a checkout is, and whether it needs `tools/engine.py sync` (LNPANDY/NX2Apple#214).

The engine is not committed: it is built into `<checkout>/engine/` (seedds/nxnative at `.upstream-ref` plus `patches/`) by
`tools/engine.py sync`. The rule, the same as the Mac launcher's (frontend/Sources/NXCore/EngineLayout.swift). The sync is for
checkouts (a release carries the engine tree instead, #227): it downloads the pinned commit from GitHub, and a failed one becomes a
failure row (`failure_kind`):

- a checkout of this repository (it has tools/engine.py and .upstream-ref): engine/, which the caller syncs first when it is stale
  or missing,
- else a folder that is an engine tree itself (dm/ at its root: the engine a release carries or installs, or a seedds/nxnative
  clone): that folder,
- else engine/ as it is.

`stamp_key` is tools/engine.py's: a digest of the pin and the series, compared with the stamp sync wrote into engine/.git, so
the launcher can tell a stale engine without starting Python. Pure stdlib, no Qt.
"""
from __future__ import annotations

import hashlib
import os
import stat
import subprocess
import sys
import threading
from pathlib import Path
from typing import Callable

from . import archive_guard as ag

MARKER = ('dm', 'tools', 'nx_extract', 'Program.cs')   # the file that tells an engine tree (as BuildModel.is_repo always did)
UPSTREAM_MARKERS: dict[str, tuple[tuple[str, ...], ...]] = {
    'nxnative': (('dm', 'tools', 'nx_extract', 'Program.cs'),),
    's2arm': (('pack', 'jobs', 'main.py'), ('runtime', 'rewriter', 'rewriter.c')),
    'macnativegames': (('build_app.py',), ('games', 'totk')),
}
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
        data = (root / 'patches' / name).read_bytes().replace(b'\r\n', b'\n')
        h.update(b'patch ' + name.encode() + b'\n' + hashlib.sha256(data).hexdigest().encode() + b'\n')
    sw = root / 'patches' / 'fork_env_switches.tsv'
    if sw.is_file():
        h.update(b'switches ' + hashlib.sha256(sw.read_bytes().replace(b'\r\n', b'\n')).hexdigest().encode() + b'\n')
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
    if bundled_engine():
        return False   # a bundled engine never needs a sync
    if not has_engine_tool(repo):
        return False
    eng = Path(repo, 'engine')
    try:
        stamp = dict(l.split(' ', 1) for l in (eng / STAMP).read_text(encoding='utf-8').splitlines() if ' ' in l)
        return stamp.get('key') != stamp_key(repo) or stamp.get('head') != _head(eng)
    except (OSError, ValueError):
        return True


ENGINE_FILES_FILE = '.engine-files'
_RUNTIME_GAME_TABLES = frozenset({'c1_full.tsv', 'cb_extent.tsv'})
_PRUNE_LOCK = threading.Lock()
_PRUNED_BUNDLED: dict[str, tuple[int, int]] = {}


def _is_link_or_junction(p: Path) -> bool:
    """True for POSIX/Windows symlinks and Windows NTFS directory junctions / reparse points."""
    try:
        if p.is_symlink():
            return True
        is_junc = getattr(p, 'is_junction', None)
        if callable(is_junc) and is_junc():
            return True
        st = os.lstat(p)
        if getattr(st, 'st_reparse_tag', 0):
            return True
    except OSError:
        return False
    return False


def _unlink_file(p: Path) -> bool:
    """Remove a file or link, clearing read-only bits on Windows when needed."""
    try:
        os.unlink(p)
        return True
    except PermissionError:
        try:
            os.chmod(p, stat.S_IWRITE | stat.S_IREAD)
            os.unlink(p)
            return True
        except OSError:
            return False
    except OSError:
        return False


def _remove_dir_link(p: Path) -> bool:
    """Remove a directory symlink or Windows NTFS junction without descending into its target."""
    try:
        os.unlink(p)
        return True
    except OSError:
        try:
            os.rmdir(p)
            return True
        except OSError:
            return False


def _parse_engine_files_manifest(manifest: Path) -> list[str] | None:
    """Read and validate `.engine-files`. Returns None when missing, truncated, or malformed."""
    try:
        if _is_link_or_junction(manifest) or not manifest.is_file():
            return None
        raw = manifest.read_bytes().decode('utf-8', errors='strict')
    except (OSError, UnicodeDecodeError):
        return None
    entries: list[str] = []
    for line in raw.replace('\r\n', '\n').splitlines():
        item = line.strip()
        if not item:
            continue
        if (
            '\x00' in item
            or ':' in item
            or '\\' in item
            or item.startswith('/')
            or item.endswith('/')
            or any(ord(ch) < 32 for ch in item)
        ):
            return None
        parts = item.split('/')
        if any(not seg or seg in ('.', '..') for seg in parts):
            return None
        entries.append(item)
    if not entries:
        return None
    entry_set = set(entries)
    if (
        '.engine-id' not in entry_set
        or 'scripts/build_ipa_from_nsp.py' not in entry_set
        or not any(p.startswith('dm/') for p in entry_set)
    ):
        return None
    return entries


def _is_managed_runtime_file(rel_posix: str, keep_keys: set[str], norm) -> bool:
    """Keep runtime-generated game shader tables and live Python bytecode belonging to managed files."""
    parts = rel_posix.split('/')
    if (
        len(parts) == 4
        and parts[0].lower() == 'dm'
        and parts[1].lower() == 'games'
        and parts[3].lower() in _RUNTIME_GAME_TABLES
    ):
        return norm(f'{parts[0]}/{parts[1]}/{parts[2]}/game.tsv') in keep_keys

    if rel_posix.lower().endswith(('.pyc', '.pyo')):
        fname = parts[-1]
        parent_parts = parts[:-2] if len(parts) >= 2 and parts[-2] == '__pycache__' else parts[:-1]
        parent_prefix = '/'.join(parent_parts)
        for stem in {fname.split('.', 1)[0], fname.rsplit('.', 1)[0]}:
            if not stem:
                continue
            py_rel = f'{parent_prefix}/{stem}.py' if parent_prefix else f'{stem}.py'
            if norm(py_rel) in keep_keys:
                return True
    return False


def _prune_stale_bundled_engine_files_checked(engine_dir: str | Path) -> tuple[list[str], bool]:
    """Prune obsolete upgrade files inside managed subtrees and report `(removed, clean_ok)`.

    `clean_ok` is True only when a valid manifest was parsed and every stale removal succeeded.
    """
    if not engine_dir:
        return [], False
    eng = Path(engine_dir)
    try:
        if _is_link_or_junction(eng) or not eng.is_dir():
            return [], False
        git_entry = eng / '.git'
        if git_entry.exists() or _is_link_or_junction(git_entry):
            return [], False
        if not (eng / 'scripts' / 'build_ipa_from_nsp.py').is_file():
            return [], False
    except OSError:
        return [], False

    entries = _parse_engine_files_manifest(eng / ENGINE_FILES_FILE)
    if not entries:
        return [], False

    def _norm(rel: str) -> str:
        return rel.lower() if os.name == 'nt' else rel

    keep_keys = {_norm(item) for item in entries}
    managed_roots = sorted({item.split('/', 1)[0] for item in entries if '/' in item})
    real_eng = os.path.realpath(os.path.abspath(os.fspath(eng)))
    removed: list[str] = []
    had_error = False

    for top in managed_roots:
        if top == '.git':
            continue
        top_dir = eng / top
        try:
            if _is_link_or_junction(top_dir) or not top_dir.is_dir():
                continue
            if not ag.is_within(os.path.realpath(top_dir), real_eng):
                had_error = True
                continue
        except OSError:
            had_error = True
            continue

        visited_dirs: list[Path] = []
        for dirpath, dirnames, files in os.walk(top_dir, topdown=True, followlinks=False):
            next_dirs: list[str] = []
            for d in sorted(dirnames):
                if d == '.git':
                    continue
                full_d = Path(dirpath, d)
                if _is_link_or_junction(full_d):
                    rel_d = full_d.relative_to(eng).as_posix()
                    if _norm(rel_d) not in keep_keys:
                        if _remove_dir_link(full_d):
                            removed.append(rel_d)
                        else:
                            had_error = True
                    continue
                if not ag.is_within(os.path.realpath(full_d), real_eng):
                    had_error = True
                    continue
                next_dirs.append(d)
                visited_dirs.append(full_d)
            dirnames[:] = next_dirs

            for fname in sorted(files):
                if fname == '.git':
                    continue
                full_f = Path(dirpath, fname)
                rel_f = full_f.relative_to(eng).as_posix()
                if _norm(rel_f) in keep_keys or _is_managed_runtime_file(rel_f, keep_keys, _norm):
                    continue
                if _unlink_file(full_f):
                    removed.append(rel_f)
                else:
                    had_error = True

        for dpath in reversed(visited_dirs):
            try:
                if not _is_link_or_junction(dpath) and dpath.is_dir() and not any(dpath.iterdir()):
                    try:
                        dpath.rmdir()
                    except PermissionError:
                        os.chmod(dpath, stat.S_IWRITE | stat.S_IREAD | stat.S_IEXEC)
                        dpath.rmdir()
            except OSError:
                pass

    return removed, (not had_error)


def prune_stale_bundled_engine_files(engine_dir: str | Path) -> list[str]:
    """Remove obsolete upgrade files inside managed subtrees of a bundled engine tree.

    Safety invariants:
    - Never touches an engine directory containing `.git` (file, dir, or symlink/junction).
    - Requires a regular (non-symlink/junction), non-empty, valid `.engine-files` with core anchors.
    - Only scans top-level subtrees named in the manifest (`dm/`, `scripts/`, `docs/`, `ref/`, etc.).
    - Never follows symlinks or NTFS junctions out of `engine_dir`, keeps runtime derived tables
      (`c1_full.tsv`, `cb_extent.tsv`) for still-managed games, and prunes orphan `.pyc`/`.pyo` files.
    """
    removed, _ = _prune_stale_bundled_engine_files_checked(engine_dir)
    return removed


def ensure_bundled_engine_pruned(engine_dir: str | Path | None = None) -> list[str]:
    """Idempotently prune stale files once per process per valid `.engine-files` signature.

    Never called from `bundled_engine()` or the Qt UI main thread; invoke from background worker
    threads or CLI/driver startup. Failures never poison the cache.
    """
    target = str(engine_dir) if engine_dir else bundled_engine()
    if not target:
        return []
    cand = Path(target)
    try:
        if _is_link_or_junction(cand) or not cand.is_dir():
            return []
        git_entry = cand / '.git'
        if git_entry.exists() or _is_link_or_junction(git_entry):
            return []
    except OSError:
        return []
    manifest = cand / ENGINE_FILES_FILE
    try:
        if _is_link_or_junction(manifest) or not manifest.is_file():
            return []
        st = manifest.lstat()
    except OSError:
        return []
    key = os.path.realpath(cand)
    sig = (st.st_mtime_ns, st.st_size)
    with _PRUNE_LOCK:
        if _PRUNED_BUNDLED.get(key) == sig:
            return []
        removed, clean_ok = _prune_stale_bundled_engine_files_checked(cand)
        if clean_ok:
            _PRUNED_BUNDLED[key] = sig
        return removed


def bundled_engine() -> str:
    """The engine tree the Actions zip puts beside the app folder (`<exe_dir>/../engine/`).
    Empty string when it is not there or does not look like an engine tree.

    Also resolves when imported from an external Python (the build's venv) inside a PyInstaller
    on-dir layout (`<root>/NX2Apple/_internal/nspb_qt/engine.py`), where `sys.frozen` is
    False in the child interpreter.
    """
    bases: list[Path] = []
    if getattr(sys, 'frozen', False):
        exe = Path(sys.executable).resolve()
        bases.extend((exe.parent, exe.parent.parent))
    here = Path(__file__).resolve()
    if len(here.parents) >= 4 and here.parents[1].name == '_internal':
        bases.extend((here.parents[2], here.parents[3]))
    for base in bases:
        cand = base / 'engine'
        if cand.joinpath('dm', 'games').is_dir() and cand.joinpath('scripts', 'build_ipa_from_nsp.py').is_file():
            return str(cand)
    return ''


def engine_root(repo: str) -> str:
    """The folder holding dm/ and scripts/ for this checkout (see the module's rule)."""
    bundled = bundled_engine()
    if bundled:
        return bundled
    if not repo:
        return repo
    eng = Path(repo, 'engine')
    if has_engine_tool(repo):
        return str(eng)
    if Path(repo, *MARKER).is_file():
        return repo
    return str(eng) if eng.joinpath(*MARKER).is_file() else repo


def is_checkout(d: str) -> bool:
    """A folder the launcher can build from: a checkout with tools/engine.py to make engine/, a synced engine/, an engine tree, or a bundled engine beside the app."""
    return bool(bundled_engine()) or (bool(d) and (Path(d, *MARKER).is_file() or Path(d, 'engine', *MARKER).is_file() or has_engine_tool(d)))


def is_upstream_tree(d: str, kind: str) -> bool:
    if not d:
        return False
    markers = UPSTREAM_MARKERS.get(kind)
    if not markers:
        return False
    p = Path(d)
    return all(p.joinpath(*parts).exists() for parts in markers)


def detect_upstream(d: str) -> str | None:
    if not d:
        return None
    if has_engine_tool(d) or is_upstream_tree(d, 'nxnative') or is_upstream_tree(str(Path(d, 'engine')), 'nxnative'):
        return 'nxnative'
    if is_upstream_tree(d, 's2arm'):
        return 's2arm'
    if is_upstream_tree(d, 'macnativegames'):
        return 'macnativegames'
    return None


def needs_sync_before_build(repo: str) -> bool:
    """engine/ is the only engine and it is stale or missing: the build syncs it first."""
    return has_engine_tool(repo) and is_stale(repo)


def sync_command(repo: str, python: str) -> list[str]:
    return [python, str(Path(repo, 'tools', 'engine.py')), 'sync']


ENGINE_OFFLINE = 'engineOffline'   # the fetch of the pinned commit failed: no network, GitHub unreachable, a proxy
ENGINE_SYNC = 'engineSync'         # any other stop of the sync


def failure_kind(log: str) -> str:
    """What a failed sync was, from its output: tools/engine.py says "cannot fetch" when the pinned commit cannot be fetched."""
    return ENGINE_OFFLINE if 'cannot fetch ' in log else ENGINE_SYNC


def run_sync(cmd: list[str], cwd: str, line: Callable[[str], None], **popen) -> tuple[bool, str | None]:
    """Run the sync command, pass its lines on, and return (ok, failure kind or None). Blocking: call it off the UI thread."""
    tail = ''
    try:
        p = subprocess.Popen(cmd, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, encoding='utf-8', errors='replace', **popen)
        assert p.stdout is not None
        with p.stdout as output:
            for out in output:
                line(out)
                tail = (tail + out)[-4000:]
        ok = p.wait() == 0
    except OSError as e:
        line(f'{e}\n')
        return False, ENGINE_SYNC
    return ok, None if ok else failure_kind(tail)
