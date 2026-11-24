"""Pure-Python build-seed zstd migration scanner, NDJSON runner, and state model.

CRITICAL: Zero PySide6 dependency so headless Linux CI can import and test all logic.
"""
from __future__ import annotations

from dataclasses import dataclass, field
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import threading
import time
from typing import Any, Callable, Mapping

from . import build_seed_cache
from . import library as lib
from . import platform_util as pu

SETTINGS_DISMISSED_KEY = 'seedCompressionPromptDismissed'
PREF_DISMISSED_JSON_KEY = 'seed_compression_prompt_dismissed'
DEFAULT_JSON_PREFS_FILENAME = 'seed_compression_prefs.json'

_TID_RE = re.compile(r'^[0-9A-F]{16}$')
_ZSTD_ESTIMATE_RATIO = 0.08
_REPARSE_ATTR = getattr(stat, 'FILE_ATTRIBUTE_REPARSE_POINT', 0x0400)


# ---------------------------------------------------------------------------
# Formatting & preferences (pure Python)
# ---------------------------------------------------------------------------

def format_bytes(size: int) -> str:
    """Format byte counts cleanly for UI metrics and progress bars."""
    return lib.format_bytes(max(0, int(size)))


def format_duration(seconds: float) -> str:
    """Format elapsed duration in seconds into a concise human-readable label."""
    sec = max(0.0, float(seconds))
    if sec < 60.0:
        return f'{sec:.1f}s'
    total = int(round(sec))
    mins, rem = divmod(total, 60)
    if mins < 60:
        return f'{mins}m {rem:02d}s'
    hours, mins = divmod(mins, 60)
    return f'{hours}h {mins:02d}m'


def default_prefs_path() -> Path:
    """Return the fallback JSON preferences path inside the launcher state dir."""
    return lib.default_state_dir() / DEFAULT_JSON_PREFS_FILENAME


def _read_json_dict(path: Path) -> dict[str, Any]:
    try:
        if not path.is_file() or path.is_symlink():
            return {}
        data = json.loads(path.read_text(encoding='utf-8'))
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def is_prompt_dismissed(settings_or_path: Any) -> bool:
    """Read the 'Don't ask again' preference from Model, QSettings, dict, or JSON path."""
    if settings_or_path is None:
        return False
    if isinstance(settings_or_path, (str, Path)):
        data = _read_json_dict(Path(settings_or_path))
        if PREF_DISMISSED_JSON_KEY in data:
            return bool(data[PREF_DISMISSED_JSON_KEY])
        return bool(data.get(SETTINGS_DISMISSED_KEY, False))
    if isinstance(settings_or_path, Mapping):
        if PREF_DISMISSED_JSON_KEY in settings_or_path:
            return bool(settings_or_path[PREF_DISMISSED_JSON_KEY])
        return bool(settings_or_path.get(SETTINGS_DISMISSED_KEY, False))
    if hasattr(settings_or_path, 'settings_value'):
        return bool(settings_or_path.settings_value(SETTINGS_DISMISSED_KEY, False))
    if hasattr(settings_or_path, 'value'):
        raw = settings_or_path.value(SETTINGS_DISMISSED_KEY, '', type=str)
        if raw == '':
            raw = settings_or_path.value(PREF_DISMISSED_JSON_KEY, '', type=str)
        if isinstance(raw, bool):
            return raw
        return str(raw).strip().lower() == 'true'
    return False


def set_prompt_dismissed(settings_or_path: Any, dismissed: bool) -> None:
    """Persist the 'Don't ask again' preference into Model, QSettings, dict, or JSON path."""
    val = bool(dismissed)
    if settings_or_path is None:
        return
    if isinstance(settings_or_path, (str, Path)):
        path = Path(settings_or_path)
        data = _read_json_dict(path)
        data[PREF_DISMISSED_JSON_KEY] = val
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_name(f'.{path.name}.tmp.{os.getpid()}')
        try:
            tmp.write_text(json.dumps(data, indent=2) + '\n', encoding='utf-8')
            os.replace(tmp, path)
        finally:
            if tmp.exists() and not tmp.is_symlink():
                try:
                    tmp.unlink()
                except OSError:
                    pass
        return
    if isinstance(settings_or_path, dict):
        settings_or_path[PREF_DISMISSED_JSON_KEY] = val
        return
    if hasattr(settings_or_path, 'settings_set'):
        settings_or_path.settings_set(SETTINGS_DISMISSED_KEY, val)
        return
    if hasattr(settings_or_path, 'setValue'):
        settings_or_path.setValue(SETTINGS_DISMISSED_KEY, 'true' if val else 'false')


# ---------------------------------------------------------------------------
# Cross-platform zstd & Python environment resolution
# ---------------------------------------------------------------------------

def find_zstd_bin() -> str | None:
    """Locate a cross-platform zstd CLI executable across bundled/toolchain/system paths."""
    if pu.IS_WIN:
        try:
            from .win import toolchain as wtc
            exe = wtc.find_exe('zstd')
            if exe and exe.is_file():
                return str(exe)
        except Exception:
            pass
    if meipass := getattr(sys, '_MEIPASS', None):
        exe_name = 'zstd.exe' if pu.IS_WIN else 'zstd'
        for cand in (Path(meipass) / exe_name, Path(meipass) / 'bin' / exe_name):
            if cand.is_file():
                return str(cand)
    return pu.find_tool('zstd')


def _has_python_zstd_module() -> bool:
    for mod_name in ('compression.zstd', 'backports.zstd', 'zstandard'):
        try:
            if importlib.util.find_spec(mod_name) is not None:
                return True
        except (ImportError, ValueError):
            continue
    return False


def _python_has_zstd(python_exe: str, env: Mapping[str, str] | None = None) -> bool:
    if not python_exe or not Path(python_exe).is_file():
        return False
    probe = (
        'import importlib.util, sys\n'
        'ok = any(importlib.util.find_spec(m) is not None for m in '
        '("compression.zstd", "backports.zstd", "zstandard"))\n'
        'sys.exit(0 if ok else 1)\n'
    )
    try:
        r = subprocess.run(
            [python_exe, '-c', probe],
            capture_output=True,
            text=True,
            timeout=10,
            env=dict(env) if env is not None else pu.child_env(),
            **pu.no_window_kwargs(),
        )
        return r.returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


def resolve_zstd_available(python_exe: str | None = None, env: Mapping[str, str] | None = None) -> bool:
    """Return True when zstd CLI or a Python zstd module is available."""
    if find_zstd_bin() is not None:
        return True
    if _has_python_zstd_module():
        return True
    if python_exe and not getattr(sys, 'frozen', False):
        try:
            if Path(python_exe).resolve() != Path(sys.executable).resolve():
                return _python_has_zstd(python_exe, env=env)
        except OSError:
            return _python_has_zstd(python_exe, env=env)
    elif python_exe:
        return _python_has_zstd(python_exe, env=env)
    return False


def resolve_python_exe(preferred: str | None = None) -> str:
    """Choose a real Python interpreter for running build_seed.py (safe in frozen builds)."""
    frozen = bool(getattr(sys, 'frozen', False) or getattr(sys, '_MEIPASS', None))
    if preferred:
        p = Path(preferred)
        if p.is_file() and (not pu.IS_WIN or p.name.lower() != 'pythonw.exe'):
            if not frozen:
                return str(p)
            try:
                if p.resolve() != Path(sys.executable).resolve():
                    return str(p)
            except OSError:
                return str(p)
    if not frozen and sys.executable and Path(sys.executable).is_file():
        if not pu.IS_WIN or Path(sys.executable).name.lower() != 'pythonw.exe':
            return sys.executable
    py, _ok, _ver = pu.find_python()
    return py


def build_subprocess_env(
    engine_path: str | Path | None = None,
    base_env: Mapping[str, str] | None = None,
) -> dict[str, str]:
    """Build sanitized child environment passing through engine tools and bundled/system zstd."""
    extra: dict[str, str] = {}
    if engine_path:
        tools_dir = str(Path(engine_path) / 'dm' / 'tools')
        extra['PYTHONPATH'] = tools_dir

    env = pu.child_env(extra or None)
    if base_env:
        for k, v in base_env.items():
            if k not in ('_MEIPASS', '_MEIPASS2', 'PYTHONHOME', 'QT_PLUGIN_PATH', 'QML2_IMPORT_PATH'):
                env[k] = v

    # Prepend bundled / toolchain zstd folder to PATH so build_seed.py finds zstd CLI reliably.
    zstd_bin = find_zstd_bin()
    if zstd_bin:
        z_dir = str(Path(zstd_bin).parent)
        parts = [p for p in env.get('PATH', '').split(os.pathsep) if p]
        norm_z = os.path.normcase(os.path.normpath(z_dir))
        if not any(os.path.normcase(os.path.normpath(p)) == norm_z for p in parts):
            env['PATH'] = os.pathsep.join([z_dir] + parts) if parts else z_dir
    return env


def build_seed_script_path(engine_path: str | Path | None) -> Path | None:
    """Return <engine_path>/dm/tools/build_seed.py when present as a regular file."""
    if not engine_path:
        return None
    p = Path(engine_path) / 'dm' / 'tools' / 'build_seed.py'
    return p if p.is_file() and not p.is_symlink() else None


# ---------------------------------------------------------------------------
# Data models & NDJSON state machine
# ---------------------------------------------------------------------------

@dataclass
class SeedGameScanItem:
    title_id: str
    app_name: str
    files: list[str]
    uncompressed_bytes: int
    estimated_compressed_bytes: int
    display_name: str = ''

    @property
    def label(self) -> str:
        return self.display_name or self.app_name or self.title_id


@dataclass
class SeedScanSummary:
    seed_root: str
    zstd_available: bool
    total_games: int
    total_files: int
    uncompressed_bytes: int
    estimated_compressed_bytes: int
    estimated_saved_bytes: int
    games: list[SeedGameScanItem] = field(default_factory=list)
    total_seed_games: int = 0
    used_fallback: bool = False

    @property
    def estimated_saved_pct(self) -> int:
        if self.uncompressed_bytes <= 0:
            return 0
        return max(0, min(99, int(round(self.estimated_saved_bytes * 100.0 / self.uncompressed_bytes))))


@dataclass
class SeedCompressionItemState:
    title_id: str
    display_name: str
    status: str = 'waiting'   # 'waiting' | 'compressing' | 'done' | 'failed'
    before_bytes: int = 0
    after_bytes: int = 0
    saved_bytes: int = 0
    files_compressed: int = 0
    error: str = ''


@dataclass
class SeedCompressionResult:
    status: str   # 'completed' | 'partial' | 'stopped' | 'error'
    completed_games: int
    failed_games: int
    before_bytes: int
    after_bytes: int
    saved_bytes: int
    elapsed_sec: float
    results: list[SeedCompressionItemState] = field(default_factory=list)
    error: str = ''

    @property
    def saved_pct(self) -> int:
        if self.before_bytes <= 0:
            return 0
        return max(0, min(99, int(round(self.saved_bytes * 100.0 / self.before_bytes))))

    @property
    def ratio_pct(self) -> int:
        if self.before_bytes <= 0:
            return 100
        return max(1, min(100, int(round(self.after_bytes * 100.0 / self.before_bytes))))


class SeedCompressionState:
    """Pure-Python three-stage state tracker driven by NDJSON events."""

    def __init__(self, summary: SeedScanSummary) -> None:
        self.summary = summary
        self.stage: str = 'prompt'   # 'prompt' | 'running' | 'done'
        self.stopping: bool = False
        self.total_games: int = summary.total_games
        self.total_bytes: int = summary.uncompressed_bytes
        self.current_index: int = 0
        self.current_title_id: str = ''
        self.processed_bytes: int = 0
        self.freed_bytes: int = 0
        self.items: list[SeedCompressionItemState] = [
            SeedCompressionItemState(
                title_id=g.title_id,
                display_name=g.label,
                status='waiting',
                before_bytes=g.uncompressed_bytes,
            )
            for g in summary.games
        ]
        self._by_tid: dict[str, SeedCompressionItemState] = {it.title_id: it for it in self.items}
        self.done_result: SeedCompressionResult | None = None
        self.error_message: str = ''

    def begin_running(self) -> None:
        self.stage = 'running'
        self.stopping = False
        self.done_result = None
        self.error_message = ''

    def mark_stopping(self) -> None:
        if self.stage == 'running':
            self.stopping = True

    def item_for(self, tid: str) -> SeedCompressionItemState:
        tid_u = tid.strip().upper()
        if tid_u not in self._by_tid:
            item = SeedCompressionItemState(title_id=tid_u, display_name=tid_u, status='waiting')
            self.items.append(item)
            self._by_tid[tid_u] = item
        return self._by_tid[tid_u]

    def apply_event(self, ev: Mapping[str, Any]) -> None:
        kind = str(ev.get('event') or '').strip()
        if kind == 'start':
            self.stage = 'running'
            self.total_games = int(ev.get('total_games', self.total_games) or 0)
            self.total_bytes = int(ev.get('total_bytes', self.total_bytes) or 0)
            return

        if kind == 'item_start':
            self.stage = 'running'
            tid = str(ev.get('title_id') or '').strip().upper()
            self.current_index = int(ev.get('index', self.current_index) or 0)
            if 'total_games' in ev:
                self.total_games = int(ev.get('total_games') or self.total_games)
            self.current_title_id = tid
            if tid:
                item = self.item_for(tid)
                item.status = 'compressing'
                if 'before_bytes' in ev:
                    item.before_bytes = int(ev.get('before_bytes') or item.before_bytes)
            return

        if kind == 'item_done':
            tid = str(ev.get('title_id') or '').strip().upper()
            before_b = int(ev.get('before_bytes', 0) or 0)
            after_b = int(ev.get('after_bytes', 0) or 0)
            saved_b = int(ev.get('saved_bytes', max(0, before_b - after_b)) or 0)
            files_k = int(ev.get('files_compressed', 0) or 0)
            if tid:
                item = self.item_for(tid)
                item.status = 'done'
                item.before_bytes = before_b
                item.after_bytes = after_b
                item.saved_bytes = saved_b
                item.files_compressed = files_k
            self.processed_bytes += before_b
            self.freed_bytes += saved_b
            return

        if kind == 'item_error':
            tid = str(ev.get('title_id') or '').strip().upper()
            before_b = int(ev.get('before_bytes', 0) or 0)
            err = str(ev.get('error') or 'compression failed')
            if tid:
                item = self.item_for(tid)
                item.status = 'failed'
                item.before_bytes = before_b
                item.after_bytes = before_b
                item.saved_bytes = 0
                item.error = err
            self.processed_bytes += before_b
            return

        if kind == 'done':
            self.stage = 'done'
            self.stopping = False
            status = str(ev.get('status') or 'completed')
            raw_results = ev.get('results') or []
            for r in raw_results:
                if not isinstance(r, Mapping):
                    continue
                tid = str(r.get('title_id') or '').strip().upper()
                if not tid:
                    continue
                item = self.item_for(tid)
                r_status = str(r.get('status') or '')
                item.before_bytes = int(r.get('before_bytes', item.before_bytes) or 0)
                item.after_bytes = int(r.get('after_bytes', item.after_bytes) or 0)
                item.saved_bytes = int(r.get('saved_bytes', item.saved_bytes) or 0)
                item.files_compressed = int(r.get('files_compressed', item.files_compressed) or 0)
                if r_status == 'completed':
                    item.status = 'done'
                elif r_status == 'error':
                    item.status = 'failed'
                    item.error = str(r.get('error') or item.error)
            self.done_result = SeedCompressionResult(
                status=status,
                completed_games=int(ev.get('completed_games', 0) or 0),
                failed_games=int(ev.get('failed_games', 0) or 0),
                before_bytes=int(ev.get('before_bytes', 0) or 0),
                after_bytes=int(ev.get('after_bytes', 0) or 0),
                saved_bytes=int(ev.get('saved_bytes', 0) or 0),
                elapsed_sec=float(ev.get('elapsed_sec', 0.0) or 0.0),
                results=list(self.items),
                error=str(ev.get('error') or ''),
            )
            return

        if kind == 'error':
            self.stage = 'done'
            self.stopping = False
            err = str(ev.get('error') or 'compression failed')
            self.error_message = err
            completed_items = [it for it in self.items if it.status == 'done']
            failed_items = [it for it in self.items if it.status == 'failed']
            before_b = sum(it.before_bytes for it in completed_items + failed_items)
            after_b = sum(it.after_bytes for it in completed_items + failed_items)
            self.done_result = SeedCompressionResult(
                status='partial' if completed_items else 'error',
                completed_games=len(completed_items),
                failed_games=max(1, len(failed_items)),
                before_bytes=before_b,
                after_bytes=after_b,
                saved_bytes=max(0, before_b - after_b),
                elapsed_sec=0.0,
                results=list(self.items),
                error=err,
            )


def parse_ndjson_line(line: str) -> dict[str, Any] | None:
    """Strictly parse a single NDJSON progress event line, returning None on blank/non-event lines."""
    s = (line or '').strip()
    if not s:
        return None
    try:
        obj = json.loads(s)
    except ValueError:
        return None
    if not isinstance(obj, dict) or not isinstance(obj.get('event'), str):
        return None
    return obj


# ---------------------------------------------------------------------------
# Safe scanning (CLI + pure-local fallback)
# ---------------------------------------------------------------------------

def _is_symlink_or_reparse_path(path: Path) -> bool:
    try:
        if path.is_symlink():
            return True
        st = os.lstat(path)
        if stat.S_ISLNK(st.st_mode):
            return True
        if stat.S_ISDIR(st.st_mode) and bool(int(getattr(st, 'st_file_attributes', 0) or 0) & _REPARSE_ATTR):
            return True
    except OSError:
        return False
    return False


def _dir_loop_key(path: Path, st: os.stat_result) -> tuple[Any, ...]:
    if getattr(st, 'st_ino', 0):
        return ('ino', getattr(st, 'st_dev', 0), st.st_ino)
    return ('path', os.path.normcase(os.path.realpath(path)))


def count_seed_games(seed_root: str | Path | None = None) -> int:
    """Count existing seed game directories safely (without following symlinks)."""
    root = Path(seed_root) if seed_root else build_seed_cache.default_seed_root()
    if not root.exists() or _is_symlink_or_reparse_path(root) or not root.is_dir():
        return 0
    try:
        root_real = os.path.realpath(root)
    except OSError:
        return 0
    count = 0
    try:
        with os.scandir(root) as it:
            for entry in it:
                if entry.name.startswith('.'):
                    continue
                ep = Path(entry.path)
                if _is_symlink_or_reparse_path(ep) or not entry.is_dir(follow_symlinks=False):
                    continue
                if not _TID_RE.fullmatch(entry.name.upper()):
                    continue
                try:
                    if os.path.commonpath([root_real, os.path.realpath(ep)]) != root_real:
                        continue
                except ValueError:
                    continue
                if (ep / 'seed.json').is_file() or (ep / 'ExeFS').is_dir() or (ep / 'metal-sources').is_dir():
                    count += 1
    except OSError:
        return count
    return count


def _read_seed_app_name(seed_dir: Path) -> str:
    sj = seed_dir / 'seed.json'
    if not sj.is_file() or _is_symlink_or_reparse_path(sj):
        return ''
    try:
        data = json.loads(sj.read_text(encoding='utf-8'))
        if isinstance(data, dict):
            return str(data.get('app_name') or '').strip()
    except (OSError, ValueError):
        pass
    return ''


def _local_scan_metal_sources_tree(metal_dir: Path) -> list[tuple[str, int]]:
    """Safely walk <seed>/metal-sources/**/b-*.img without following symlinks."""
    if not metal_dir.exists() or _is_symlink_or_reparse_path(metal_dir) or not metal_dir.is_dir():
        return []
    try:
        metal_real = os.path.realpath(metal_dir)
        mst = os.lstat(metal_dir)
    except OSError:
        return []

    found: list[tuple[str, int]] = []
    stack: list[tuple[Path, str]] = [(metal_dir, '')]
    visited: set[tuple[Any, ...]] = {_dir_loop_key(metal_dir, mst)}
    entries_seen = 0

    while stack:
        cur_dir, cur_rel = stack.pop()
        try:
            with os.scandir(cur_dir) as it:
                entries = sorted(it, key=lambda e: e.name)
        except OSError:
            continue
        for entry in entries:
            entries_seen += 1
            if entries_seen > 500_000:
                return sorted(found, key=lambda x: x[0])
            name = entry.name
            if name.startswith('.') or '.tmp' in name or name.endswith('.part'):
                continue
            if '\\' in name or ':' in name or name in ('', '.', '..'):
                continue
            ep = Path(entry.path)
            if _is_symlink_or_reparse_path(ep):
                continue
            rel = f'{cur_rel}/{name}' if cur_rel else name
            try:
                est = entry.stat(follow_symlinks=False)
            except OSError:
                continue
            if stat.S_ISDIR(est.st_mode):
                try:
                    lst = os.lstat(ep)
                except OSError:
                    continue
                if _is_symlink_or_reparse_path(ep) or not stat.S_ISDIR(lst.st_mode):
                    continue
                key = _dir_loop_key(ep, lst)
                if key in visited:
                    continue
                visited.add(key)
                stack.append((ep, rel))
            elif stat.S_ISREG(est.st_mode) and name.startswith('b-') and name.endswith('.img'):
                try:
                    if os.path.commonpath([metal_real, os.path.realpath(ep)]) != metal_real:
                        continue
                except ValueError:
                    continue
                found.append((rel, est.st_size))

    found.sort(key=lambda item: item[0])
    return found


def local_scan_uncompressed(
    seed_root: str | Path | None = None,
    *,
    zstd_ok: bool | None = None,
    game_names: Mapping[str, str] | None = None,
) -> SeedScanSummary:
    """Pure-local safe fallback scan when engine build_seed.py is unavailable."""
    root = Path(seed_root) if seed_root else build_seed_cache.default_seed_root()
    root_abs = os.path.abspath(str(root))
    z_ok = resolve_zstd_available() if zstd_ok is None else bool(zstd_ok)
    total_seed_games = count_seed_games(root)

    if not root.exists() or _is_symlink_or_reparse_path(root) or not root.is_dir():
        return SeedScanSummary(
            seed_root=root_abs,
            zstd_available=z_ok,
            total_games=0,
            total_files=0,
            uncompressed_bytes=0,
            estimated_compressed_bytes=0,
            estimated_saved_bytes=0,
            games=[],
            total_seed_games=total_seed_games,
            used_fallback=True,
        )

    root_real = os.path.realpath(root)
    names_map = {k.upper(): v for k, v in (game_names or {}).items() if v}
    games: list[SeedGameScanItem] = []

    try:
        with os.scandir(root) as it:
            entries = sorted(it, key=lambda e: e.name)
    except OSError:
        entries = []

    for entry in entries:
        if entry.name.startswith('.'):
            continue
        ep = Path(entry.path)
        if _is_symlink_or_reparse_path(ep) or not entry.is_dir(follow_symlinks=False):
            continue
        tid = entry.name.upper()
        if not _TID_RE.fullmatch(tid):
            continue
        try:
            if os.path.commonpath([root_real, os.path.realpath(ep)]) != root_real:
                continue
        except ValueError:
            continue

        found = _local_scan_metal_sources_tree(ep / 'metal-sources')
        if not found:
            continue
        uncomp_b = sum(sz for _rel, sz in found)
        est_comp = int(round(uncomp_b * _ZSTD_ESTIMATE_RATIO)) if uncomp_b > 0 else 0
        app_name = _read_seed_app_name(ep)
        games.append(SeedGameScanItem(
            title_id=tid,
            app_name=app_name,
            files=[rel for rel, _sz in found],
            uncompressed_bytes=uncomp_b,
            estimated_compressed_bytes=est_comp,
            display_name=names_map.get(tid) or app_name or tid,
        ))

    games.sort(key=lambda g: (-g.uncompressed_bytes, g.title_id))
    total_files = sum(len(g.files) for g in games)
    total_uncomp = sum(g.uncompressed_bytes for g in games)
    total_est = sum(g.estimated_compressed_bytes for g in games)
    return SeedScanSummary(
        seed_root=root_abs,
        zstd_available=z_ok,
        total_games=len(games),
        total_files=total_files,
        uncompressed_bytes=total_uncomp,
        estimated_compressed_bytes=total_est,
        estimated_saved_bytes=max(0, total_uncomp - total_est),
        games=games,
        total_seed_games=total_seed_games,
        used_fallback=True,
    )


def parse_scan_json(
    payload: Mapping[str, Any],
    *,
    game_names: Mapping[str, str] | None = None,
    total_seed_games: int = 0,
    zstd_override: bool | None = None,
) -> SeedScanSummary:
    """Parse JSON emitted by `build_seed.py scan-uncompressed --json`."""
    names_map = {k.upper(): v for k, v in (game_names or {}).items() if v}
    raw_games = payload.get('games') or []
    games: list[SeedGameScanItem] = []
    for g in raw_games:
        if not isinstance(g, Mapping):
            continue
        tid = str(g.get('title_id') or '').strip().upper()
        if not tid:
            continue
        app_name = str(g.get('app_name') or '').strip()
        files = [str(f) for f in (g.get('files') or [])]
        uncomp = int(g.get('uncompressed_bytes', 0) or 0)
        est = int(g.get('estimated_compressed_bytes', 0) or 0)
        games.append(SeedGameScanItem(
            title_id=tid,
            app_name=app_name,
            files=files,
            uncompressed_bytes=uncomp,
            estimated_compressed_bytes=est,
            display_name=names_map.get(tid) or app_name or tid,
        ))
    z_ok = bool(payload.get('zstd_available', False))
    if zstd_override:
        z_ok = True
    return SeedScanSummary(
        seed_root=str(payload.get('seed_root') or ''),
        zstd_available=z_ok,
        total_games=int(payload.get('total_games', len(games)) or 0),
        total_files=int(payload.get('total_files', sum(len(g.files) for g in games)) or 0),
        uncompressed_bytes=int(payload.get('uncompressed_bytes', sum(g.uncompressed_bytes for g in games)) or 0),
        estimated_compressed_bytes=int(payload.get('estimated_compressed_bytes', sum(g.estimated_compressed_bytes for g in games)) or 0),
        estimated_saved_bytes=int(payload.get('estimated_saved_bytes', 0) or 0),
        games=games,
        total_seed_games=max(total_seed_games, len(games)),
        used_fallback=False,
    )


def scan_uncompressed(
    *,
    seed_root: str | Path | None = None,
    engine_path: str | Path | None = None,
    python_exe: str | None = None,
    game_names: Mapping[str, str] | None = None,
    runner: Callable[..., subprocess.CompletedProcess[str]] | None = None,
) -> SeedScanSummary:
    """Scan for uncompressed legacy metal-sources .img archives via engine CLI with local fallback."""
    root = Path(seed_root) if seed_root else build_seed_cache.default_seed_root()
    total_seeds = count_seed_games(root)
    script = build_seed_script_path(engine_path)
    py = resolve_python_exe(python_exe)
    env = build_subprocess_env(engine_path)
    local_zstd = resolve_zstd_available(py, env=env)

    if script is not None and py:
        cmd = [py, str(script), 'scan-uncompressed', '--seed-root', str(root), '--json']
        try:
            proc_fn = runner or subprocess.run
            res = proc_fn(
                cmd,
                capture_output=True,
                text=True,
                errors='replace',
                timeout=30,
                env=env,
                **pu.no_window_kwargs(),
            )
            if res.returncode == 0 and (res.stdout or '').strip():
                obj = json.loads(res.stdout)
                if isinstance(obj, dict) and 'games' in obj:
                    return parse_scan_json(
                        obj,
                        game_names=game_names,
                        total_seed_games=total_seeds,
                        zstd_override=local_zstd,
                    )
        except (OSError, subprocess.SubprocessError, ValueError):
            pass

    return local_scan_uncompressed(
        root,
        zstd_ok=local_zstd,
        game_names=game_names,
    )


# ---------------------------------------------------------------------------
# Subprocess NDJSON compression runner
# ---------------------------------------------------------------------------

def _cleanup_residual_zst_tmps(seed_root: Path) -> None:
    """Best-effort cleanup of interrupted *.img.zst.tmp files without touching .img or .img.zst."""
    if not seed_root.is_dir() or _is_symlink_or_reparse_path(seed_root):
        return
    try:
        for game_dir in seed_root.iterdir():
            if game_dir.name.startswith('.') or _is_symlink_or_reparse_path(game_dir) or not game_dir.is_dir():
                continue
            ms_dir = game_dir / 'metal-sources'
            if not ms_dir.is_dir() or _is_symlink_or_reparse_path(ms_dir):
                continue
            for root_dir, _dirs, files in os.walk(ms_dir, followlinks=False):
                for fname in files:
                    if fname.endswith('.img.zst.tmp'):
                        cand = Path(root_dir) / fname
                        if not _is_symlink_or_reparse_path(cand):
                            try:
                                cand.unlink()
                            except OSError:
                                pass
    except OSError:
        pass


class SeedCompressionRunner:
    """Executes `build_seed.py compress-seeds --progress json` with safe cross-platform stop."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._proc: subprocess.Popen[str] | None = None
        self._stop_requested = False

    @property
    def stop_requested(self) -> bool:
        with self._lock:
            return self._stop_requested

    def request_stop(self) -> None:
        with self._lock:
            self._stop_requested = True
            proc = self._proc
        if proc is not None and proc.poll() is None:
            if pu.IS_WIN:
                pu.kill_process_tree(proc)
            else:
                try:
                    proc.terminate()
                except OSError:
                    pass

    def force_kill(self) -> None:
        with self._lock:
            proc = self._proc
        if proc is not None and proc.poll() is None:
            pu.kill_process_tree(proc)

    def run(
        self,
        summary: SeedScanSummary,
        *,
        engine_path: str | Path | None,
        python_exe: str | None = None,
        title_ids: list[str] | None = None,
        level: int = 3,
        on_event: Callable[[dict[str, Any]], None] | None = None,
        popen_factory: Callable[..., subprocess.Popen[str]] | None = None,
    ) -> SeedCompressionResult:
        state = SeedCompressionState(summary)
        state.begin_running()
        t0 = time.monotonic()

        def _dispatch(ev: dict[str, Any]) -> None:
            state.apply_event(ev)
            if on_event is not None:
                on_event(ev)

        if self.stop_requested:
            stopped_ev = {
                'event': 'done',
                'status': 'stopped',
                'completed_games': 0,
                'failed_games': 0,
                'before_bytes': 0,
                'after_bytes': 0,
                'saved_bytes': 0,
                'elapsed_sec': 0.0,
                'results': [],
            }
            _dispatch(stopped_ev)
            assert state.done_result is not None
            return state.done_result

        script = build_seed_script_path(engine_path)
        if script is None:
            err_ev = {'event': 'error', 'error': 'build_seed.py not found in engine directory'}
            _dispatch(err_ev)
            assert state.done_result is not None
            return state.done_result

        py = resolve_python_exe(python_exe)
        env = build_subprocess_env(engine_path)
        seed_root = Path(summary.seed_root) if summary.seed_root else build_seed_cache.default_seed_root()
        cmd = [
            py,
            str(script),
            'compress-seeds',
            '--seed-root', str(seed_root),
            '--progress', 'json',
            '--level', str(int(level)),
        ]
        for tid in (title_ids or []):
            cmd += ['--title-id', tid]

        popen_fn = popen_factory or subprocess.Popen
        proc: subprocess.Popen[str] | None = None
        stderr_chunks: list[str] = []
        stderr_thread: threading.Thread | None = None
        rc = -1
        try:
            proc = popen_fn(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                encoding='utf-8',
                errors='replace',
                bufsize=1,
                env=env,
                **pu.process_group_kwargs(),
            )
            with self._lock:
                self._proc = proc
                already_stopped = self._stop_requested
            if already_stopped and proc.poll() is None:
                if pu.IS_WIN:
                    pu.kill_process_tree(proc)
                else:
                    try:
                        proc.terminate()
                    except OSError:
                        pass

            if proc.stderr is not None:
                def _drain_err() -> None:
                    try:
                        assert proc.stderr is not None
                        stderr_chunks.append(proc.stderr.read())
                    except OSError:
                        pass
                stderr_thread = threading.Thread(target=_drain_err, daemon=True)
                stderr_thread.start()

            if proc.stdout is not None:
                for raw_line in proc.stdout:
                    ev = parse_ndjson_line(raw_line)
                    if ev is not None:
                        _dispatch(ev)

            if self.stop_requested:
                try:
                    rc = proc.wait(timeout=5.0)
                except subprocess.TimeoutExpired:
                    self.force_kill()
                    rc = proc.wait(timeout=2.0)
            else:
                rc = proc.wait()
        except Exception as exc:
            _dispatch({'event': 'error', 'error': str(exc)})
            assert state.done_result is not None
            return state.done_result
        finally:
            if stderr_thread is not None:
                stderr_thread.join(timeout=1.0)
            if proc is not None:
                for pipe in (proc.stdout, proc.stderr):
                    if pipe is not None:
                        try:
                            pipe.close()
                        except OSError:
                            pass
            with self._lock:
                self._proc = None

        if state.done_result is None:
            if self.stop_requested:
                _cleanup_residual_zst_tmps(seed_root)
            completed_items = [it for it in state.items if it.status == 'done']
            failed_items = [it for it in state.items if it.status == 'failed']
            before_b = sum(it.before_bytes for it in completed_items + failed_items)
            after_b = sum(it.after_bytes for it in completed_items + failed_items)
            saved_b = max(0, before_b - after_b)
            elapsed = round(time.monotonic() - t0, 3)

            if self.stop_requested:
                synth_status = 'stopped'
                synth_err = ''
            else:
                err_txt = ''.join(stderr_chunks).strip()
                synth_status = 'partial' if completed_items else 'error'
                synth_err = err_txt or f'compress-seeds exited with code {rc}'

            if synth_status == 'error':
                _dispatch({'event': 'error', 'error': synth_err})
            else:
                results_payload = [
                    {
                        'title_id': it.title_id,
                        'status': 'completed' if it.status == 'done' else 'error',
                        'before_bytes': it.before_bytes,
                        'after_bytes': it.after_bytes,
                        'saved_bytes': it.saved_bytes,
                        'files_compressed': it.files_compressed,
                        **({'error': it.error} if it.error else {}),
                    }
                    for it in completed_items + failed_items
                ]
                _dispatch({
                    'event': 'done',
                    'status': synth_status,
                    'completed_games': len(completed_items),
                    'failed_games': len(failed_items),
                    'before_bytes': before_b,
                    'after_bytes': after_b,
                    'saved_bytes': saved_b,
                    'elapsed_sec': elapsed,
                    'results': results_payload,
                    **({'error': synth_err} if synth_err else {}),
                })

        assert state.done_result is not None
        return state.done_result
