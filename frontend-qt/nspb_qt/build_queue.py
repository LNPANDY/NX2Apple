"""General batch build queue for new and existing games in the Qt launcher.

Mirrors the Mac launcher's BuildQueue.swift / BuildQueueStore.swift / BuildQueueCard.swift:
- Pure Python state machine, multi-game discovery/grouping, and atomic JSON persistence
  at module top level (zero PySide6 imports required so headless CI runs it cleanly).
- Crash/restart recovery resets any lingering `building` entry back to `queued` and raises
  `awaiting_resume` instead of ever marking an unverified entry `done`.
- Explicit `stopping` window prevents a stopped build from racing to start the next item.
"""
from __future__ import annotations

from dataclasses import dataclass, field
import json
import os
from pathlib import Path
import threading
import time
from typing import Any, Callable
import uuid

from . import inputs as _inputs
from . import library as lib
from . import platform_util as pu

try:
    from PySide6.QtCore import Qt, Signal
    from PySide6.QtWidgets import (
        QCheckBox,
        QDialog,
        QFileDialog,
        QFrame,
        QHBoxLayout,
        QLabel,
        QMessageBox,
        QPushButton,
        QScrollArea,
        QSizePolicy,
        QVBoxLayout,
        QWidget,
    )
    from . import style
    from .widgets import CardGroup, StatusDot, make_divider
    HAS_QT = True
except ImportError:
    HAS_QT = False


QUEUE_VERSION = 1
QUEUE_FILENAME = 'build-queue.json'

STATUS_QUEUED = 'queued'
STATUS_BUILDING = 'building'
STATUS_DONE = 'done'
STATUS_FAILED = 'failed'
STATUS_SKIPPED = 'skipped'
STATUS_STOPPED = 'stopped'

_FINISHED_STATUSES = frozenset({STATUS_DONE, STATUS_FAILED, STATUS_SKIPPED, STATUS_STOPPED})
_RETRYABLE_STATUSES = frozenset({STATUS_FAILED, STATUS_SKIPPED, STATUS_STOPPED})
_VALID_STATUSES = frozenset({
    STATUS_QUEUED,
    STATUS_BUILDING,
    STATUS_DONE,
    STATUS_FAILED,
    STATUS_SKIPPED,
    STATUS_STOPPED,
})

_SKIP_DISCOVERY_DIRS = frozenset({
    'base', 'updates', 'dlc', 'romfs', 'exefs', 'extract', 'tools',
    'venv', 'archive', 'harness', 'runs', 'shader', 'node_modules', 'xcode',
    'shell-framework', '__pycache__',
})


def normalize_target(target: str) -> str:
    raw = (target or '').strip().lower()
    if raw in ('mac', 'mac-app', 'macos'):
        return 'mac-app'
    return 'ios'


def normalize_ipa_kind(kind: str) -> str:
    raw = (kind or '').strip()
    if raw in ('shared', 'oneGame', 'framework'):
        return raw
    return 'shared'


def normalize_upstream(upstream: str) -> str:
    raw = (upstream or '').strip().lower()
    if raw == 's2arm':
        return 's2arm'
    return 'nxnative'


def default_queue_file() -> Path:
    return lib.default_state_dir() / QUEUE_FILENAME


# ---------------------------------------------------------------------------
# Data Models
# ---------------------------------------------------------------------------

@dataclass
class QueueEntry:
    """Snapshot of a single game build job in the queue."""

    id: str = field(default_factory=lambda: uuid.uuid4().hex)
    title_id: str = ''
    name: str = ''
    base_path: str = ''
    update_path: str = ''
    dlc_paths: list[str] = field(default_factory=list)
    keys_path: str = ''
    game_dir: str = ''
    is_game_folder: bool = False
    out_dir: str = ''
    target: str = 'ios'
    ipa_kind: str = 'shared'
    upstream: str = 'nxnative'
    bc_on_cpu: bool = False
    batch_id: str = field(default_factory=lambda: uuid.uuid4().hex)
    status: str = STATUS_QUEUED
    reason: str = ''
    created_at: float = field(default_factory=time.time)

    def __post_init__(self) -> None:
        self.id = str(self.id or uuid.uuid4().hex).strip() or uuid.uuid4().hex
        self.title_id = (self.title_id or '').strip().upper()
        self.name = (self.name or '').strip()
        self.base_path = str(self.base_path or '').strip()
        self.update_path = str(self.update_path or '').strip()
        self.dlc_paths = [str(p).strip() for p in (self.dlc_paths or []) if str(p).strip()]
        self.keys_path = str(self.keys_path or '').strip()
        self.game_dir = str(self.game_dir or '').strip()
        self.is_game_folder = bool(self.is_game_folder)
        self.out_dir = str(self.out_dir or '').strip()
        self.target = normalize_target(self.target)
        self.ipa_kind = normalize_ipa_kind(self.ipa_kind)
        self.upstream = normalize_upstream(self.upstream)
        self.bc_on_cpu = bool(self.bc_on_cpu)
        self.batch_id = str(self.batch_id or uuid.uuid4().hex).strip() or uuid.uuid4().hex
        raw_status = str(self.status or STATUS_QUEUED).strip().lower()
        if raw_status == 'running':
            raw_status = STATUS_BUILDING
        self.status = raw_status if raw_status in _VALID_STATUSES else STATUS_QUEUED
        self.reason = str(self.reason or '').strip()
        try:
            self.created_at = float(self.created_at or 0.0)
        except (TypeError, ValueError):
            self.created_at = 0.0
        if not self.name:
            self.name = self.title_id or (Path(self.base_path or self.game_dir).stem if (self.base_path or self.game_dir) else 'Game')

    @property
    def is_finished(self) -> bool:
        return self.status in _FINISHED_STATUSES

    @property
    def is_retryable(self) -> bool:
        return self.status in _RETRYABLE_STATUSES

    @property
    def identity_key(self) -> str:
        if self.title_id:
            return self.title_id.upper()
        src = self.game_dir if self.is_game_folder else self.base_path
        return os.path.normcase(os.path.abspath(src)) if src else self.id

    @property
    def dedup_key(self) -> tuple[str, str, str, str]:
        return (self.identity_key, self.target, self.ipa_kind if self.target == 'ios' else '', self.upstream)

    def status_l10n_key(self) -> str:
        if self.status == STATUS_BUILDING:
            return 'queue.status.running'
        return f'queue.status.{self.status}'

    def input_summary(self, t_func: Callable[..., str]) -> str:
        if self.is_game_folder:
            return t_func('queue.inputFolder')
        parts: list[str] = []
        if self.base_path:
            parts.append(t_func('data.base'))
        if self.update_path:
            parts.append(t_func('data.update'))
        if self.dlc_paths:
            dlc_txt = t_func('data.dlc')
            parts.append(f'{len(self.dlc_paths)} × {dlc_txt}' if len(self.dlc_paths) > 1 else dlc_txt)
        return ', '.join(parts)

    def target_badge(self, t_func: Callable[..., str]) -> str:
        if self.target == 'mac-app':
            label = t_func('library.section.mac')
        else:
            kind_key = {
                'shared': 'shell.ipaShared',
                'oneGame': 'shell.ipaOneGame',
                'framework': 'shell.ipaFramework',
            }.get(self.ipa_kind, 'shell.ipaShared')
            label = f"{t_func('build.ios')} · {t_func(kind_key)}"
        if self.upstream == 's2arm':
            label += ' · S2Arm'
        return label

    def to_dict(self) -> dict[str, Any]:
        return {
            'id': self.id,
            'title_id': self.title_id,
            'name': self.name,
            'base_path': self.base_path,
            'update_path': self.update_path,
            'dlc_paths': list(self.dlc_paths),
            'keys_path': self.keys_path,
            'game_dir': self.game_dir,
            'is_game_folder': self.is_game_folder,
            'out_dir': self.out_dir,
            'target': self.target,
            'ipa_kind': self.ipa_kind,
            'upstream': self.upstream,
            'bc_on_cpu': self.bc_on_cpu,
            'batch_id': self.batch_id,
            'status': self.status,
            'reason': self.reason,
            'created_at': self.created_at,
        }

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> QueueEntry | None:
        if not isinstance(data, dict):
            return None
        raw_dlc = data.get('dlc_paths')
        if not isinstance(raw_dlc, list):
            raw_dlc = []
        base_path = str(data.get('base_path') or '').strip()
        game_dir = str(data.get('game_dir') or '').strip()
        if not base_path and not game_dir:
            return None
        return cls(
            id=str(data.get('id') or uuid.uuid4().hex),
            title_id=str(data.get('title_id') or ''),
            name=str(data.get('name') or ''),
            base_path=base_path,
            update_path=str(data.get('update_path') or ''),
            dlc_paths=[str(p) for p in raw_dlc if isinstance(p, str) and p.strip()],
            keys_path=str(data.get('keys_path') or ''),
            game_dir=game_dir,
            is_game_folder=bool(data.get('is_game_folder', False)),
            out_dir=str(data.get('out_dir') or ''),
            target=str(data.get('target') or 'ios'),
            ipa_kind=str(data.get('ipa_kind') or 'shared'),
            upstream=str(data.get('upstream') or 'nxnative'),
            bc_on_cpu=bool(data.get('bc_on_cpu', False)),
            batch_id=str(data.get('batch_id') or uuid.uuid4().hex),
            status=str(data.get('status') or STATUS_QUEUED),
            reason=str(data.get('reason') or ''),
            created_at=float(data.get('created_at') or 0.0),
        )


# ---------------------------------------------------------------------------
# Multi-Game Discovery & Title ID Grouping
# ---------------------------------------------------------------------------

@dataclass
class DiscoveredGame:
    """One game discovered from dropped/picked packages, NUPs, or game folders."""

    title_id: str
    name: str
    base_path: str = ''
    update_path: str = ''
    dlc_paths: list[str] = field(default_factory=list)
    keys_path: str = ''
    game_dir: str = ''
    is_game_folder: bool = False

    def input_summary(self, t_func: Callable[..., str]) -> str:
        if self.is_game_folder:
            return t_func('queue.inputFolder')
        parts: list[str] = []
        if self.base_path:
            parts.append(t_func('data.base'))
        if self.update_path:
            parts.append(t_func('data.update'))
        if self.dlc_paths:
            dlc_txt = t_func('data.dlc')
            parts.append(f'{len(self.dlc_paths)} × {dlc_txt}' if len(self.dlc_paths) > 1 else dlc_txt)
        return ', '.join(parts)

    def to_queue_entry(
        self,
        *,
        out_dir: str = '',
        target: str = 'ios',
        ipa_kind: str = 'shared',
        upstream: str = 'nxnative',
        bc_on_cpu: bool = False,
        keys_path: str = '',
        batch_id: str = '',
    ) -> QueueEntry:
        return QueueEntry(
            title_id=self.title_id,
            name=self.name,
            base_path=self.base_path,
            update_path=self.update_path,
            dlc_paths=list(self.dlc_paths),
            keys_path=self.keys_path or keys_path,
            game_dir=self.game_dir,
            is_game_folder=self.is_game_folder,
            out_dir=out_dir,
            target=target,
            ipa_kind=ipa_kind,
            upstream=upstream,
            bc_on_cpu=bc_on_cpu,
            batch_id=batch_id or uuid.uuid4().hex,
        )


@dataclass
class DiscoveryResult:
    games: list[DiscoveredGame] = field(default_factory=list)
    keys_path: str = ''


def _resolve_display_name(
    tid: str,
    fallback_path: str,
    *,
    engine_path: str = '',
    library: lib.GameLibrary | None = None,
) -> str:
    tid_up = (tid or '').strip().upper()
    if library is not None and tid_up:
        for g in library.games:
            if (g.title_id or '').strip().upper() == tid_up and g.name and g.name.upper() != tid_up:
                return g.name
    if tid_up and engine_path:
        prof = lib.GameFolder.profile_name(tid_up, engine_path)
        if prof:
            return prof
    if fallback_path:
        cleaned = lib.clean_game_name(fallback_path)
        if cleaned:
            return cleaned
    return tid_up or Path(fallback_path).stem or 'Game'


def _should_skip_subdir(name: str) -> bool:
    if not name or name.startswith('.'):
        return True
    low = name.lower()
    if low in _SKIP_DISCOVERY_DIRS:
        return True
    if low.endswith(('.app', '_build', '_survey', '.framework')):
        return True
    return False


def discover_game_groups(
    paths: list[str | os.PathLike],
    *,
    keys_path: str = '',
    engine_path: str = '',
    library: lib.GameLibrary | None = None,
    max_depth: int = 2,
) -> DiscoveryResult:
    """Scan picked/dropped files or parent folders and group packages into games by Title ID.

    Handles:
    - Multiple `.nsp`/`.xci`/`.nsz`/`.xcz` packages belonging to different games (groups each
      game's largest Base + newest Update + all DLCs by owner Title ID).
    - `.nup` files (each valid `.nup` becomes its own game entry).
    - Unpacked dump folders (`base/exefs/main.npdm` or `updates/<v>/exefs/main.npdm`).
    - Parent folders containing mixed packages, `.nup` files, and/or game subfolders.
    """
    pkg_files: list[Path] = []
    nup_paths: list[Path] = []
    dump_dirs: list[Path] = []
    found_keys = (keys_path or '').strip()
    seen_dirs: set[str] = set()
    seen_files: set[str] = set()

    def _note_file(p: Path) -> None:
        nonlocal found_keys
        try:
            if p.is_symlink() or not p.is_file():
                return
            ap = os.path.normcase(os.path.abspath(str(p)))
        except OSError:
            return
        if ap in seen_files:
            return
        seen_files.add(ap)
        name = p.name
        if name.startswith('._'):
            return
        low = name.lower()
        if low in ('prod.keys', 'keys.txt') or low.endswith('.keys'):
            if not found_keys:
                found_keys = str(p)
            return
        if low.endswith('.nup'):
            nup_paths.append(p)
            return
        if p.suffix.lower() in _inputs.GAME_SUFFIXES:
            try:
                if p.stat().st_size > 0:
                    pkg_files.append(p)
            except OSError:
                return

    def _scan_dir(d: Path, depth: int) -> None:
        try:
            if d.is_symlink() or not d.is_dir():
                return
            ad = os.path.normcase(os.path.abspath(str(d)))
        except OSError:
            return
        if ad in seen_dirs:
            return
        seen_dirs.add(ad)
        if _inputs.is_dump_directory(d):
            dump_dirs.append(d)
            return
        try:
            entries = sorted(d.iterdir(), key=lambda x: x.name)
        except OSError:
            return
        subdirs: list[Path] = []
        for entry in entries:
            if entry.name.startswith('.'):
                continue
            try:
                if entry.is_symlink():
                    continue
                if entry.is_file():
                    _note_file(entry)
                elif entry.is_dir() and depth < max_depth and not _should_skip_subdir(entry.name):
                    subdirs.append(entry)
            except OSError:
                continue
        for sub in subdirs:
            _scan_dir(sub, depth + 1)

    for raw in paths:
        if not raw:
            continue
        p = Path(os.fspath(raw))
        try:
            if p.is_symlink() or not p.exists():
                continue
        except OSError:
            continue
        if p.is_dir():
            _scan_dir(p, 0)
        elif p.is_file():
            _note_file(p)

    games: list[DiscoveredGame] = []
    seen_identities: set[str] = set()

    # 1. Unpacked dump folders
    for d in sorted(dump_dirs, key=lambda x: str(x)):
        scanned = _inputs.scan_game_folder(str(d))
        if isinstance(scanned, _inputs.GameFolderProblem):
            continue
        tid_hex = scanned.title_id_hex if scanned.has_title_id else _inputs.build_key(str(d), found_keys)
        ident = tid_hex.upper()
        if ident in seen_identities:
            continue
        seen_identities.add(ident)
        newest = scanned.newest_update
        games.append(DiscoveredGame(
            title_id=tid_hex.upper(),
            name=_resolve_display_name(tid_hex, str(d), engine_path=engine_path, library=library),
            base_path=scanned.base_path,
            update_path=newest[1] if newest else '',
            dlc_paths=[p for _, p in scanned.dlc],
            keys_path='',
            game_dir=str(d),
            is_game_folder=True,
        ))

    # 2. Standalone .nup files
    for nup in sorted(nup_paths, key=lambda x: str(x)):
        scanned = _inputs.read_nup(str(nup))
        if isinstance(scanned, _inputs.GameFolderProblem):
            continue
        tid_hex = scanned.title_id_hex if scanned.has_title_id else _inputs.build_key(str(nup), found_keys)
        ident = tid_hex.upper()
        if ident in seen_identities:
            continue
        seen_identities.add(ident)
        newest = scanned.newest_update
        games.append(DiscoveredGame(
            title_id=tid_hex.upper(),
            name=_resolve_display_name(tid_hex, str(nup), engine_path=engine_path, library=library),
            base_path=str(nup),
            update_path=newest[1] if newest else '',
            dlc_paths=[p for _, p in scanned.dlc],
            keys_path='',
            game_dir=str(nup),
            is_game_folder=True,
        ))

    # 3. Package files (.nsp / .xci / .nsz / .xcz) grouped by owner Title ID
    tid_cache: dict[Path, int | None] = {}

    def _tid_of(f: Path) -> int | None:
        if f not in tid_cache:
            tid_cache[f] = _inputs.title_id(f.name) or _inputs.package_title_id(f, found_keys)
        return tid_cache[f]

    # app_tid -> {'bases': [(size, Path)], 'updates': [(ver, name, Path)], 'dlcs': [Path]}
    grouped: dict[int, dict[str, list]] = {}
    unnamed_bases: list[Path] = []
    unnamed_updates: list[tuple[int, str, Path]] = []
    unnamed_dlcs: list[Path] = []

    for f in sorted(pkg_files, key=lambda x: str(x)):
        try:
            size = f.stat().st_size
        except OSError:
            continue
        if size <= 0:
            continue
        tid = _tid_of(f)
        if tid is None:
            low = f.name.lower()
            if '[upd]' in low or 'update' in low:
                unnamed_updates.append((_inputs.update_version(f.name), f.name, f))
            elif '[dlc]' in low or 'addon' in low:
                unnamed_dlcs.append(f)
            else:
                unnamed_bases.append(f)
            continue
        app = _inputs.owner(tid)
        bucket = grouped.setdefault(app, {'bases': [], 'updates': [], 'dlcs': []})
        kind = tid & 0xFFF
        if kind == 0:
            bucket['bases'].append((size, f))
        elif kind == 0x800:
            bucket['updates'].append((_inputs.update_version(f.name), f.name, f))
        else:
            bucket['dlcs'].append(f)

    for app_tid in sorted(grouped.keys()):
        bucket = grouped[app_tid]
        if not bucket['bases']:
            continue
        tid_hex = f'{app_tid:016X}'
        if tid_hex in seen_identities:
            continue
        seen_identities.add(tid_hex)
        best_base: Path = max(bucket['bases'], key=lambda b: (b[0], str(b[1])))[1]
        best_upd: Path | None = (
            max(bucket['updates'], key=lambda u: (u[0], u[1]))[2]
            if bucket['updates']
            else None
        )
        dlcs = sorted((str(d) for d in bucket['dlcs']))
        games.append(DiscoveredGame(
            title_id=tid_hex,
            name=_resolve_display_name(tid_hex, str(best_base), engine_path=engine_path, library=library),
            base_path=str(best_base),
            update_path=str(best_upd) if best_upd is not None else '',
            dlc_paths=dlcs,
            keys_path=found_keys,
            game_dir=str(best_base.parent),
            is_game_folder=False,
        ))

    # Unnamed package bases (no readable title ID in name or container)
    for idx, ub in enumerate(unnamed_bases):
        bkey = _inputs.build_key(str(ub), found_keys)
        ident = bkey.upper()
        if ident in seen_identities:
            continue
        seen_identities.add(ident)
        # Attach unnamed updates/DLCs only when there is a single unnamed base and no TID-grouped games
        attach_unnamed = (len(unnamed_bases) == 1 and not grouped and idx == 0)
        best_upd_path = ''
        dlc_list: list[str] = []
        if attach_unnamed:
            if unnamed_updates:
                best_upd_path = str(max(unnamed_updates, key=lambda u: (u[0], u[1]))[2])
            dlc_list = sorted(str(d) for d in unnamed_dlcs)
        games.append(DiscoveredGame(
            title_id=bkey.upper(),
            name=_resolve_display_name('', str(ub), engine_path=engine_path, library=library),
            base_path=str(ub),
            update_path=best_upd_path,
            dlc_paths=dlc_list,
            keys_path=found_keys,
            game_dir=str(ub.parent),
            is_game_folder=False,
        ))

    return DiscoveryResult(games=games, keys_path=found_keys)


# ---------------------------------------------------------------------------
# Atomic Persistence
# ---------------------------------------------------------------------------

class BuildQueueFile:
    """Atomic JSON storage for `<config_dir>/build-queue.json`."""

    @staticmethod
    def load(path: str | os.PathLike) -> tuple[list[QueueEntry], bool]:
        p = Path(path)
        if p.is_symlink() or not p.is_file():
            return [], False
        try:
            raw = json.loads(p.read_text(encoding='utf-8'))
        except (OSError, ValueError, UnicodeDecodeError):
            return [], False
        if not isinstance(raw, dict):
            return [], False
        paused = bool(raw.get('paused', False))
        raw_entries = raw.get('entries')
        if not isinstance(raw_entries, list):
            return [], False
        entries: list[QueueEntry] = []
        for item in raw_entries:
            ent = QueueEntry.from_dict(item)
            if ent is not None:
                entries.append(ent)
        return entries, paused

    @staticmethod
    def save(entries: list[QueueEntry], *, paused: bool = False, path: str | os.PathLike) -> bool:
        p = Path(path)
        payload = {
            'version': QUEUE_VERSION,
            'paused': bool(paused),
            'entries': [e.to_dict() for e in entries],
        }
        tmp = p.parent / f'.{p.name}.{os.getpid()}.{threading.get_ident()}.tmp'
        try:
            p.parent.mkdir(parents=True, exist_ok=True)
            tmp.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')
            os.replace(tmp, p)
            return True
        except OSError:
            try:
                tmp.unlink(missing_ok=True)
            except OSError:
                pass
            return False


# ---------------------------------------------------------------------------
# BuildQueueStore (State Machine + Race Protection)
# ---------------------------------------------------------------------------

class BuildQueueStore:
    """Thread-safe sequential build queue with persistence, crash recovery, and stop-window protection."""

    def __init__(
        self,
        *,
        file_path: str | os.PathLike | None = None,
        busy: Callable[[], bool] | None = None,
        start_entry: Callable[[QueueEntry, bool], str | None] | None = None,
        cancel_running: Callable[[], None] | None = None,
        repack_shared_shell: Callable[[], bool] | None = None,
        on_changed: Callable[[], None] | None = None,
        on_batch_completed: Callable[[int, int, int], None] | None = None,
        schedule_next: Callable[[Callable[[], None]], None] | None = None,
    ) -> None:
        self._file = Path(file_path) if file_path is not None else None
        self._busy = busy or (lambda: False)
        self._start_entry = start_entry or (lambda _e, _defer: 'build runner unavailable')
        self._cancel_running = cancel_running or (lambda: None)
        self._repack_shared_shell = repack_shared_shell
        self._on_changed = on_changed
        self._on_batch_completed = on_batch_completed
        self._schedule_next = schedule_next

        self._lock = threading.RLock()
        self._entries: list[QueueEntry] = []
        self._active = False
        self._paused = False
        self._awaiting_resume = False
        self._stopping = False
        self._finalizing_shell = False
        self._dirty_shared_shell = False
        self._running_deferred_shell = False
        self._running_entry_id: str | None = None
        self._generation = 0

        self._load_from_disk()

    def _load_from_disk(self) -> None:
        if self._file is None:
            return
        loaded, stored_paused = BuildQueueFile.load(self._file)
        was_interrupted = False
        for ent in loaded:
            if ent.status == STATUS_BUILDING:
                # Never treat an interrupted build as done without a verified completion receipt.
                ent.status = STATUS_QUEUED
                ent.reason = ''
                was_interrupted = True
        has_waiting = any(e.status == STATUS_QUEUED for e in loaded)
        self._entries = loaded
        self._paused = bool(stored_paused and has_waiting)
        self._awaiting_resume = bool((not stored_paused) and was_interrupted and has_waiting)
        self._active = False
        self._stopping = False
        if was_interrupted:
            self._persist_unlocked()

    def _persist_unlocked(self) -> None:
        if self._file is not None:
            BuildQueueFile.save(self._entries, paused=self._paused, path=self._file)

    def _notify_changed(self) -> None:
        cb = self._on_changed
        if cb is not None:
            try:
                cb()
            except RuntimeError:
                pass

    # ---- read-only views

    @property
    def entries(self) -> list[QueueEntry]:
        with self._lock:
            return list(self._entries)

    @property
    def is_empty(self) -> bool:
        with self._lock:
            return not self._entries

    @property
    def active(self) -> bool:
        with self._lock:
            return self._active

    @property
    def paused(self) -> bool:
        with self._lock:
            return self._paused

    @property
    def awaiting_resume(self) -> bool:
        with self._lock:
            return self._awaiting_resume

    @property
    def stopping(self) -> bool:
        with self._lock:
            return self._stopping

    @property
    def finalizing_shell(self) -> bool:
        with self._lock:
            return self._finalizing_shell

    @property
    def running_entry(self) -> QueueEntry | None:
        with self._lock:
            if self._running_entry_id is None:
                return None
            return next((e for e in self._entries if e.id == self._running_entry_id and e.status == STATUS_BUILDING), None)

    @property
    def queued_entries(self) -> list[QueueEntry]:
        with self._lock:
            return [e for e in self._entries if e.status == STATUS_QUEUED]

    @property
    def has_waiting(self) -> bool:
        with self._lock:
            return any(e.status == STATUS_QUEUED for e in self._entries)

    @property
    def has_finished(self) -> bool:
        with self._lock:
            return any(e.is_finished for e in self._entries)

    @property
    def current_generation(self) -> int:
        with self._lock:
            return self._generation

    def progress_counts(self) -> tuple[int, int]:
        """Return `(current_or_completed, total)` for display like `1 / 4`."""
        with self._lock:
            total = len(self._entries)
            if total == 0:
                return 0, 0
            finished = sum(1 for e in self._entries if e.is_finished)
            if self._running_entry_id is not None and any(
                e.id == self._running_entry_id and e.status == STATUS_BUILDING for e in self._entries
            ):
                return min(total, finished + 1), total
            return finished, total

    def can_enqueue(self, entry_or_key: QueueEntry | tuple[str, str, str, str]) -> bool:
        key = entry_or_key.dedup_key if isinstance(entry_or_key, QueueEntry) else entry_or_key
        with self._lock:
            for existing in self._entries:
                if existing.dedup_key == key:
                    return existing.is_finished
            return True

    # ---- mutations

    def enqueue(self, new_entries: list[QueueEntry], *, auto_start: bool = False) -> int:
        """Append or refresh entries without disrupting any currently running build."""
        if not new_entries:
            return 0
        added = 0
        should_advance = False
        with self._lock:
            for item in new_entries:
                item.status = STATUS_QUEUED
                item.reason = ''
                key = item.dedup_key
                existing_idx = next((i for i, e in enumerate(self._entries) if e.dedup_key == key), None)
                if existing_idx is not None:
                    existing = self._entries[existing_idx]
                    if not existing.is_finished:
                        # Already queued or currently building: do not duplicate or interrupt.
                        continue
                    item.id = existing.id
                    self._entries[existing_idx] = item
                    added += 1
                else:
                    self._entries.append(item)
                    added += 1
            if added:
                self._persist_unlocked()
                if auto_start and not self._active and not self._stopping and not self._busy():
                    self._active = True
                    self._paused = False
                    self._awaiting_resume = False
                    self._persist_unlocked()
                    should_advance = True
                elif self._active and not self._paused and not self._awaiting_resume and not self._stopping:
                    if self._running_entry_id is None and not self._finalizing_shell:
                        should_advance = True
        if added:
            self._notify_changed()
        if should_advance:
            self._trigger_process_next()
        return added

    def can_move_up(self, entry_id: str) -> bool:
        with self._lock:
            movable = [e.id for e in self._entries if e.status == STATUS_QUEUED]
            try:
                return movable.index(entry_id) > 0
            except ValueError:
                return False

    def can_move_down(self, entry_id: str) -> bool:
        with self._lock:
            movable = [e.id for e in self._entries if e.status == STATUS_QUEUED]
            try:
                idx = movable.index(entry_id)
                return 0 <= idx < len(movable) - 1
            except ValueError:
                return False

    def move_up(self, entry_id: str) -> bool:
        return self._move(entry_id, -1)

    def move_down(self, entry_id: str) -> bool:
        return self._move(entry_id, 1)

    def _move(self, entry_id: str, step: int) -> bool:
        with self._lock:
            movable_indices = [i for i, e in enumerate(self._entries) if e.status == STATUS_QUEUED]
            try:
                pos = next(idx for idx, real_i in enumerate(movable_indices) if self._entries[real_i].id == entry_id)
            except StopIteration:
                return False
            target_pos = pos + step
            if not (0 <= target_pos < len(movable_indices)):
                return False
            a = movable_indices[pos]
            b = movable_indices[target_pos]
            self._entries[a], self._entries[b] = self._entries[b], self._entries[a]
            self._persist_unlocked()
        self._notify_changed()
        return True

    def remove(self, entry_id: str) -> bool:
        with self._lock:
            idx = next((i for i, e in enumerate(self._entries) if e.id == entry_id), None)
            if idx is None:
                return False
            if self._entries[idx].status == STATUS_BUILDING:
                return False
            self._entries.pop(idx)
            if not any(e.status == STATUS_QUEUED for e in self._entries):
                self._awaiting_resume = False
                self._paused = False
                if self._running_entry_id is None and not self._finalizing_shell:
                    self._active = False
            self._persist_unlocked()
        self._notify_changed()
        return True

    def retry(self, entry_id: str, *, auto_resume: bool = False) -> bool:
        should_advance = False
        with self._lock:
            ent = next((e for e in self._entries if e.id == entry_id), None)
            if ent is None or not ent.is_retryable:
                return False
            ent.status = STATUS_QUEUED
            ent.reason = ''
            if auto_resume and not self._stopping:
                self._active = True
                self._paused = False
                self._awaiting_resume = False
                if self._running_entry_id is None and not self._finalizing_shell:
                    should_advance = True
            elif self._active and not self._paused and not self._awaiting_resume and not self._stopping:
                if self._running_entry_id is None and not self._finalizing_shell:
                    should_advance = True
            self._persist_unlocked()
        self._notify_changed()
        if should_advance:
            self._trigger_process_next()
        return True

    def clear_finished(self) -> int:
        with self._lock:
            before = len(self._entries)
            self._entries = [e for e in self._entries if not e.is_finished]
            removed = before - len(self._entries)
            if removed == 0:
                return 0
            if not any(e.status == STATUS_QUEUED for e in self._entries):
                self._awaiting_resume = False
                self._paused = False
                if self._running_entry_id is None and not self._finalizing_shell:
                    self._active = False
            self._persist_unlocked()
        self._notify_changed()
        return removed

    def cancel_queued(self) -> int:
        """Remove all waiting items while leaving the running build and settled results intact."""
        should_repack = False
        with self._lock:
            before = len(self._entries)
            self._entries = [e for e in self._entries if e.status != STATUS_QUEUED]
            removed = before - len(self._entries)
            self._awaiting_resume = False
            self._paused = False
            if self._running_entry_id is None and not self._finalizing_shell:
                self._active = False
                if self._dirty_shared_shell and self._repack_shared_shell is not None:
                    should_repack = True
            self._persist_unlocked()
        self._notify_changed()
        if should_repack:
            self._maybe_finalize_shared_shell()
        return removed

    # ---- execution control

    def start(self) -> bool:
        with self._lock:
            if self._stopping or not any(e.status == STATUS_QUEUED for e in self._entries):
                return False
            self._active = True
            self._paused = False
            self._awaiting_resume = False
            self._persist_unlocked()
        self._notify_changed()
        self.process_next()
        return True

    def resume(self) -> bool:
        return self.start()

    def stop_queue(self) -> None:
        """Stop the active queue cleanly and enter the `stopping` window until the running build exits."""
        need_cancel = False
        with self._lock:
            self._active = False
            self._awaiting_resume = False
            has_running = self._running_entry_id is not None or self._finalizing_shell
            self._paused = has_running or any(e.status == STATUS_QUEUED for e in self._entries)
            if has_running:
                self._stopping = True
                need_cancel = True
            else:
                self._stopping = False
            self._persist_unlocked()
        self._notify_changed()
        if need_cancel:
            try:
                self._cancel_running()
            except Exception:
                pass

    def _trigger_process_next(self) -> None:
        if self._schedule_next is not None:
            self._schedule_next(self.process_next)
        else:
            self.process_next()

    def process_next(self) -> bool:
        """Start the next waiting entry when idle. Synchronous preflight failures advance automatically."""
        while True:
            with self._lock:
                if (
                    not self._active
                    or self._paused
                    or self._awaiting_resume
                    or self._stopping
                    or self._running_entry_id is not None
                    or self._finalizing_shell
                ):
                    return False
                if self._busy():
                    return False
                nxt_idx = next((i for i, e in enumerate(self._entries) if e.status == STATUS_QUEUED), None)
                if nxt_idx is None:
                    need_repack = self._dirty_shared_shell and self._repack_shared_shell is not None
                    if not need_repack:
                        self._active = False
                        done_c, fail_c, skip_c = self._batch_counts_unlocked()
                        self._persist_unlocked()
                        emit_batch = (done_c, fail_c, skip_c)
                    else:
                        emit_batch = None
                else:
                    entry = self._entries[nxt_idx]
                    has_later_shared_ios = any(
                        e.status == STATUS_QUEUED
                        and e.target == 'ios'
                        and e.ipa_kind == 'shared'
                        for e in self._entries[nxt_idx + 1:]
                    )
                    defer_shell = (entry.target == 'ios' and entry.ipa_kind == 'shared' and has_later_shared_ios)
                    self._running_deferred_shell = bool(defer_shell)
                    self._generation += 1
                    gen = self._generation
                    entry.status = STATUS_BUILDING
                    entry.reason = ''
                    self._running_entry_id = entry.id
                    self._persist_unlocked()
                    emit_batch = None
                    need_repack = False

            if nxt_idx is None:
                self._notify_changed()
                if need_repack:
                    if self._maybe_finalize_shared_shell():
                        return True
                    # Repack declined/unavailable: finish batch cleanly
                    with self._lock:
                        self._active = False
                        self._dirty_shared_shell = False
                        done_c, fail_c, skip_c = self._batch_counts_unlocked()
                        self._persist_unlocked()
                    self._notify_changed()
                    self._emit_batch_completed(done_c, fail_c, skip_c)
                    return False
                if emit_batch is not None:
                    self._emit_batch_completed(*emit_batch)
                return False

            self._notify_changed()
            problem = self._start_entry(entry, defer_shell)
            if problem is None:
                return True

            # Synchronous failure before worker launch: mark failed only if still bound to this generation
            with self._lock:
                if self._generation == gen and self._running_entry_id == entry.id:
                    if self._stopping:
                        entry.status = STATUS_QUEUED
                        entry.reason = ''
                        self._stopping = False
                        self._active = False
                        self._paused = True
                    else:
                        entry.status = STATUS_FAILED
                        entry.reason = problem
                    self._running_entry_id = None
                    self._running_deferred_shell = False
                    self._persist_unlocked()
                    still_going = self._active and not self._paused and not self._stopping
                else:
                    still_going = False
            self._notify_changed()
            if not still_going:
                return False

    def _maybe_finalize_shared_shell(self) -> bool:
        repack = self._repack_shared_shell
        if repack is None:
            return False
        with self._lock:
            if not self._dirty_shared_shell or self._finalizing_shell or self._stopping or self._busy():
                return False
            self._dirty_shared_shell = False
            self._finalizing_shell = True
            self._generation += 1
            gen = self._generation
        self._notify_changed()
        started = False
        try:
            started = bool(repack())
        except Exception:
            started = False
        if not started:
            with self._lock:
                if self._generation == gen:
                    self._finalizing_shell = False
            self._notify_changed()
        return started

    def _batch_counts_unlocked(self) -> tuple[int, int, int]:
        done_c = sum(1 for e in self._entries if e.status == STATUS_DONE)
        fail_c = sum(1 for e in self._entries if e.status == STATUS_FAILED)
        skip_c = sum(1 for e in self._entries if e.status in (STATUS_SKIPPED, STATUS_STOPPED))
        return done_c, fail_c, skip_c

    def _emit_batch_completed(self, done_c: int, fail_c: int, skip_c: int) -> None:
        cb = self._on_batch_completed
        if cb is not None:
            try:
                cb(done_c, fail_c, skip_c)
            except RuntimeError:
                pass

    def on_build_finished(
        self,
        ok: bool,
        note: str = '',
        *,
        stopped: bool = False,
        generation: int | None = None,
    ) -> bool:
        """Handle completion of the currently running queued build or final shared-shell repack.

        Returns True if the event belonged to the queue, False if it was an unrelated manual build.
        """
        should_advance = False
        batch_summary: tuple[int, int, int] | None = None
        with self._lock:
            if generation is not None and generation != self._generation:
                return False
            if self._finalizing_shell:
                self._finalizing_shell = False
                was_stopping = self._stopping or stopped
                self._stopping = False
                if was_stopping:
                    self._active = False
                    self._paused = any(e.status == STATUS_QUEUED for e in self._entries)
                else:
                    if not any(e.status == STATUS_QUEUED for e in self._entries):
                        self._active = False
                        batch_summary = self._batch_counts_unlocked()
                    else:
                        should_advance = self._active and not self._paused and not self._awaiting_resume
                self._persist_unlocked()
            else:
                if self._running_entry_id is None:
                    return False
                ent = next((e for e in self._entries if e.id == self._running_entry_id), None)
                was_deferred_shell = self._running_deferred_shell
                self._running_deferred_shell = False
                self._running_entry_id = None
                was_stopping = self._stopping or stopped
                self._stopping = False

                if ent is not None:
                    if was_stopping:
                        # Interrupted build returns to queued so it can resume without faking completion.
                        ent.status = STATUS_QUEUED
                        ent.reason = ''
                        self._active = False
                        self._paused = True
                    elif ok:
                        ent.status = STATUS_DONE
                        ent.reason = ''
                        if ent.target == 'ios' and ent.ipa_kind == 'shared':
                            if was_deferred_shell:
                                self._dirty_shared_shell = True
                            else:
                                self._dirty_shared_shell = False
                    else:
                        ent.status = STATUS_FAILED
                        ent.reason = (note or '').strip()

                has_more = any(e.status == STATUS_QUEUED for e in self._entries)
                if was_stopping:
                    self._active = False
                    self._paused = has_more
                elif self._active and not self._paused and not self._awaiting_resume:
                    if has_more or (self._dirty_shared_shell and self._repack_shared_shell is not None):
                        should_advance = True
                    else:
                        self._active = False
                        batch_summary = self._batch_counts_unlocked()
                else:
                    self._active = False
                self._persist_unlocked()

        self._notify_changed()
        if should_advance:
            self._trigger_process_next()
        elif batch_summary is not None:
            self._emit_batch_completed(*batch_summary)
        return True


# ---------------------------------------------------------------------------
# Qt UI Components (`BuildQueueCard` & `QueueSelectGamesDialog`)
# ---------------------------------------------------------------------------

if HAS_QT:

    def _pill_style(fg: str, bg: str, border: str) -> str:
        return (
            f'color: {fg}; background: {bg}; border: 1px solid {border}; '
            'border-radius: 9px; padding: 3px 10px; font-size: 11px; font-weight: 700;'
        )

    def _status_visual(status: str) -> tuple[str, str, str, str]:
        """Return `(dot_color, fg, bg, border)` for a queue entry status."""
        if status == STATUS_BUILDING:
            return (style.AMBER, style.AMBER, 'rgba(255, 189, 56, 0.14)', 'rgba(255, 189, 56, 0.35)')
        if status == STATUS_DONE:
            return (style.GREEN, style.GREEN, 'rgba(82, 217, 122, 0.14)', 'rgba(82, 217, 122, 0.35)')
        if status == STATUS_FAILED:
            return (style.RED, style.RED, 'rgba(255, 97, 97, 0.15)', 'rgba(255, 97, 97, 0.38)')
        if status in (STATUS_SKIPPED, STATUS_STOPPED):
            return (style.MUTED, style.MUTED, 'rgba(255, 255, 255, 0.06)', 'rgba(255, 255, 255, 0.14)')
        return (style.NEUTRAL_DOT, style.TEXT, 'rgba(255, 255, 255, 0.07)', 'rgba(255, 255, 255, 0.15)')

    class BuildQueueCard(CardGroup):
        """Builds-page card showing queue progress, restart-resume banner, and per-game controls."""

        selectGamesRequested = Signal()

        def __init__(self, model: Any, queue: BuildQueueStore, parent: QWidget | None = None) -> None:
            super().__init__(title=model.t('queue.title'), parent=parent)
            self.m = model
            self.q = queue
            self._row_widgets: list[QWidget] = []

            # Header badges & actions (right of section title)
            self.progress_pill = QLabel('')
            self.progress_pill.setSizePolicy(QSizePolicy.Policy.Fixed, QSizePolicy.Policy.Fixed)
            self.progress_pill.setStyleSheet(
                _pill_style(style.ACCENT, 'rgba(255, 240, 214, 0.11)', 'rgba(255, 240, 214, 0.25)')
            )
            self.progress_pill.hide()
            self.header_row.insertWidget(1, self.progress_pill, 0, Qt.AlignmentFlag.AlignVCenter)

            self.paused_lbl = QLabel('')
            self.paused_lbl.setStyleSheet(f'color: {style.AMBER}; font-size: 12px; font-weight: 700;')
            self.paused_lbl.hide()
            self.header_row.insertWidget(2, self.paused_lbl)

            self.clear_btn = QPushButton(self.m.t('queue.clear'))
            self.clear_btn.setObjectName('ghost')
            self.clear_btn.setCursor(Qt.PointingHandCursor)
            self.clear_btn.clicked.connect(self.q.clear_finished)
            self.header_row.addWidget(self.clear_btn)

            self.cancel_queue_btn = QPushButton(self.m.t('queue.cancel'))
            self.cancel_queue_btn.setObjectName('ghost')
            self.cancel_queue_btn.setCursor(Qt.PointingHandCursor)
            self.cancel_queue_btn.clicked.connect(self._on_cancel_queued)
            self.header_row.addWidget(self.cancel_queue_btn)

            self.select_btn = QPushButton(self.m.t('queue.select'))
            self.select_btn.setCursor(Qt.PointingHandCursor)
            self.select_btn.clicked.connect(self.selectGamesRequested.emit)
            self.header_row.addWidget(self.select_btn)

            self.start_btn = QPushButton(self.m.t('queue.start'))
            self.start_btn.setObjectName('creamPill')
            self.start_btn.setCursor(Qt.PointingHandCursor)
            self.start_btn.clicked.connect(self._on_start_or_resume)
            self.header_row.addWidget(self.start_btn)

            self.stop_btn = QPushButton(self.m.t('btn.stop'))
            self.stop_btn.setObjectName('danger')
            self.stop_btn.setCursor(Qt.PointingHandCursor)
            self.stop_btn.clicked.connect(self.q.stop_queue)
            self.header_row.addWidget(self.stop_btn)

            # Body container rebuilt cleanly on queue updates
            self.rows_host = QWidget()
            self.rows_layout = QVBoxLayout(self.rows_host)
            self.rows_layout.setContentsMargins(0, 0, 0, 0)
            self.rows_layout.setSpacing(0)
            self.add_row(self.rows_host)

            self.refresh()

        def _on_start_or_resume(self) -> None:
            if self.q.awaiting_resume or self.q.paused:
                self.q.resume()
            else:
                self.q.start()

        def _on_cancel_queued(self) -> None:
            waiting = len(self.q.queued_entries)
            if waiting <= 0:
                return
            ans = QMessageBox.question(
                self,
                self.m.t('queue.cancel'),
                self.m.t('queue.cancelConfirm', waiting),
                QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.Cancel,
                QMessageBox.StandardButton.Cancel,
            )
            if ans == QMessageBox.StandardButton.Yes:
                self.q.cancel_queued()

        def _clear_rows(self) -> None:
            self._row_widgets.clear()
            while self.rows_layout.count():
                item = self.rows_layout.takeAt(0)
                w = item.widget()
                if w is not None:
                    w.hide()
                    w.setParent(None)
                    w.deleteLater()

        def _make_icon_btn(self, symbol: str, tooltip: str, *, danger: bool = False, enabled: bool = True) -> QPushButton:
            btn = QPushButton(symbol)
            btn.setFixedSize(28, 28)
            btn.setCursor(Qt.PointingHandCursor if enabled else Qt.ArrowCursor)
            btn.setToolTip(tooltip)
            btn.setAccessibleName(tooltip)
            btn.setEnabled(enabled)
            if danger:
                btn.setStyleSheet(
                    'QPushButton {'
                    f' background: rgba(255, 97, 97, 0.10); color: {style.RED};'
                    ' border: 1px solid rgba(255, 97, 97, 0.28); border-radius: 14px;'
                    ' padding: 0px; min-height: 0px; font-size: 12px; font-weight: 700;'
                    '}'
                    'QPushButton:hover { background: rgba(255, 97, 97, 0.22); border-color: rgba(255, 97, 97, 0.65); }'
                    'QPushButton:disabled { opacity: 0.4; }'
                )
            else:
                btn.setStyleSheet(
                    'QPushButton {'
                    f' background: rgba(255, 255, 255, 0.07); color: {style.TEXT};'
                    ' border: 1px solid rgba(255, 255, 255, 0.14); border-radius: 14px;'
                    ' padding: 0px; min-height: 0px; font-size: 12px; font-weight: 700;'
                    '}'
                    'QPushButton:hover { background: rgba(255, 255, 255, 0.14); }'
                    'QPushButton:disabled { background: rgba(255, 255, 255, 0.03); color: #55555a; border-color: rgba(255, 255, 255, 0.05); }'
                )
            return btn

        def refresh(self) -> None:
            t = self.m.t
            entries = self.q.entries
            has_waiting = self.q.has_waiting
            has_finished = self.q.has_finished
            is_running = self.q.running_entry is not None or self.q.finalizing_shell
            is_paused = self.q.paused
            awaiting_resume = self.q.awaiting_resume
            is_stopping = self.q.stopping

            self.set_title(t('queue.title'))
            cur, total = self.q.progress_counts()
            if total > 0:
                waiting_cnt = len(self.q.queued_entries)
                if is_running or has_finished:
                    self.progress_pill.setText(f'{cur} / {total}')
                else:
                    self.progress_pill.setText(t('queue.count', waiting_cnt))
                self.progress_pill.show()
            else:
                self.progress_pill.hide()

            self.paused_lbl.setText(t('queue.paused'))
            self.paused_lbl.setVisible(is_paused and has_waiting and not is_running)

            self.clear_btn.setText(t('queue.clear'))
            self.clear_btn.setVisible(has_finished)

            self.cancel_queue_btn.setText(t('queue.cancel'))
            self.cancel_queue_btn.setVisible(has_waiting)
            self.cancel_queue_btn.setEnabled(not is_stopping)

            self.select_btn.setText(t('queue.select'))
            self.select_btn.setEnabled(True)

            show_start = has_waiting and not is_running and not is_stopping
            self.start_btn.setText(t('queue.resume' if (is_paused or awaiting_resume) else 'queue.start'))
            self.start_btn.setVisible(show_start)
            self.start_btn.setEnabled(show_start and not getattr(self.m, 'running', False))

            self.stop_btn.setText(t('btn.stop'))
            self.stop_btn.setVisible(is_running or is_stopping)
            self.stop_btn.setEnabled(is_running and not is_stopping)

            self._clear_rows()

            if awaiting_resume:
                banner = QWidget()
                b_lay = QHBoxLayout(banner)
                b_lay.setContentsMargins(18, 13, 18, 13)
                b_lay.setSpacing(12)
                b_col = QVBoxLayout()
                b_col.setSpacing(3)
                bt = QLabel(t('queue.resumeTitle'))
                bt.setObjectName('rowTitle')
                bn = QLabel(t('queue.resumeNote'))
                bn.setObjectName('muted')
                bn.setWordWrap(True)
                b_col.addWidget(bt)
                b_col.addWidget(bn)
                b_lay.addLayout(b_col, 1)
                rbtn = QPushButton(t('queue.resume'))
                rbtn.setObjectName('creamPill')
                rbtn.setCursor(Qt.PointingHandCursor)
                rbtn.clicked.connect(self.q.resume)
                b_lay.addWidget(rbtn)
                self.rows_layout.addWidget(banner)
                if entries:
                    self.rows_layout.addWidget(make_divider())

            if not entries:
                empty_row = QWidget()
                er = QHBoxLayout(empty_row)
                er.setContentsMargins(18, 13, 18, 13)
                er.setSpacing(10)
                er.addWidget(StatusDot(style.NEUTRAL_DOT))
                hint = QLabel(t('queue.selectNote'))
                hint.setObjectName('muted')
                hint.setWordWrap(True)
                er.addWidget(hint, 1)
                self.rows_layout.addWidget(empty_row)
                return

            for idx, entry in enumerate(entries):
                if idx > 0:
                    self.rows_layout.addWidget(make_divider())
                row = QWidget()
                row.setProperty('queueEntryId', entry.id)
                rl = QHBoxLayout(row)
                rl.setContentsMargins(18, 12, 18, 12)
                rl.setSpacing(12)

                dot_color, fg, bg, border = _status_visual(entry.status)
                rl.addWidget(StatusDot(dot_color))

                info_col = QVBoxLayout()
                info_col.setSpacing(3)

                top_line = QHBoxLayout()
                top_line.setSpacing(8)
                name_lbl = QLabel(entry.name)
                name_lbl.setObjectName('rowTitle')
                top_line.addWidget(name_lbl)

                target_badge = QLabel(entry.target_badge(t))
                target_badge.setStyleSheet(
                    _pill_style(style.MUTED, 'rgba(255, 255, 255, 0.06)', 'rgba(255, 255, 255, 0.13)')
                )
                top_line.addWidget(target_badge)
                top_line.addStretch(1)
                info_col.addLayout(top_line)

                sub_parts: list[str] = []
                if entry.title_id:
                    sub_parts.append(entry.title_id)
                inp_sum = entry.input_summary(t)
                if inp_sum:
                    sub_parts.append(inp_sum)
                sub_lbl = QLabel(' · '.join(sub_parts))
                sub_lbl.setObjectName('mono')
                info_col.addWidget(sub_lbl)

                if entry.reason and entry.status in (STATUS_FAILED, STATUS_SKIPPED):
                    err_lbl = QLabel(entry.reason)
                    err_lbl.setWordWrap(True)
                    err_lbl.setToolTip(entry.reason)
                    err_lbl.setStyleSheet(f'color: {style.RED if entry.status == STATUS_FAILED else style.AMBER}; font-size: 11.5px;')
                    info_col.addWidget(err_lbl)

                rl.addLayout(info_col, 1)

                status_pill = QLabel(t(entry.status_l10n_key()))
                status_pill.setSizePolicy(QSizePolicy.Policy.Fixed, QSizePolicy.Policy.Fixed)
                status_pill.setStyleSheet(_pill_style(fg, bg, border))
                rl.addWidget(status_pill, 0, Qt.AlignmentFlag.AlignVCenter)

                if entry.status == STATUS_QUEUED:
                    up_btn = self._make_icon_btn(
                        '↑',
                        t('queue.moveUpNamed', entry.name),
                        enabled=self.q.can_move_up(entry.id),
                    )
                    up_btn.clicked.connect(lambda _=False, eid=entry.id: self.q.move_up(eid))
                    rl.addWidget(up_btn)

                    down_btn = self._make_icon_btn(
                        '↓',
                        t('queue.moveDownNamed', entry.name),
                        enabled=self.q.can_move_down(entry.id),
                    )
                    down_btn.clicked.connect(lambda _=False, eid=entry.id: self.q.move_down(eid))
                    rl.addWidget(down_btn)

                    rm_btn = self._make_icon_btn('✕', t('queue.removeNamed', entry.name), danger=True)
                    rm_btn.clicked.connect(lambda _=False, eid=entry.id: self.q.remove(eid))
                    rl.addWidget(rm_btn)
                elif entry.is_retryable:
                    retry_btn = QPushButton(t('onboarding.retry'))
                    retry_btn.setCursor(Qt.PointingHandCursor)
                    retry_btn.clicked.connect(lambda _=False, eid=entry.id: self.q.retry(eid))
                    rl.addWidget(retry_btn)

                    rm_btn = self._make_icon_btn('✕', t('queue.removeNamed', entry.name), danger=True)
                    rm_btn.clicked.connect(lambda _=False, eid=entry.id: self.q.remove(eid))
                    rl.addWidget(rm_btn)
                elif entry.status == STATUS_DONE:
                    rm_btn = self._make_icon_btn('✕', t('queue.removeNamed', entry.name), danger=True)
                    rm_btn.clicked.connect(lambda _=False, eid=entry.id: self.q.remove(eid))
                    rl.addWidget(rm_btn)

                self._row_widgets.append(row)
                self.rows_layout.addWidget(row)

    class QueueSelectGamesDialog(QDialog):
        """Multi-select dialog to batch-enqueue discovered games and/or library games."""

        def __init__(
            self,
            model: Any,
            queue: BuildQueueStore,
            *,
            discovered: list[DiscoveredGame] | None = None,
            parent: QWidget | None = None,
        ) -> None:
            super().__init__(parent)
            self.m = model
            self.q = queue
            self._candidates: list[DiscoveredGame] = []
            self._checkboxes: list[tuple[QCheckBox, DiscoveredGame]] = []
            self._chosen: list[QueueEntry] = []

            self.setWindowTitle(self.m.t('queue.select').replace('…', ''))
            self.setModal(True)
            self.setMinimumSize(640, 460)
            self.resize(680, 540)
            self.setStyleSheet(style.STYLESHEET)

            root = QVBoxLayout(self)
            root.setContentsMargins(24, 22, 24, 20)
            root.setSpacing(14)

            title = QLabel(self.m.t('queue.select').replace('…', ''))
            title.setStyleSheet('font-size: 22px; font-weight: 800;')
            root.addWidget(title)

            note = QLabel(self.m.t('queue.selectNote'))
            note.setObjectName('muted')
            note.setWordWrap(True)
            root.addWidget(note)

            # Action bar to pick multiple files or a parent folder containing multiple games
            pick_bar = QHBoxLayout()
            pick_bar.setSpacing(10)
            self.pick_files_btn = QPushButton(self.m.t('data.choose'))
            self.pick_files_btn.setCursor(Qt.PointingHandCursor)
            self.pick_files_btn.clicked.connect(self._pick_files)
            pick_bar.addWidget(self.pick_files_btn)

            self.pick_folder_btn = QPushButton(self.m.t('data.pickFolder'))
            self.pick_folder_btn.setCursor(Qt.PointingHandCursor)
            self.pick_folder_btn.clicked.connect(self._pick_folder)
            pick_bar.addWidget(self.pick_folder_btn)
            pick_bar.addStretch(1)

            target_preview = QLabel(
                QueueEntry(
                    title_id='0100000000000000',
                    name='preview',
                    base_path='x',
                    target=getattr(self.m, 'target', 'ios'),
                    ipa_kind=getattr(self.m, 'ipa_kind', 'shared'),
                    upstream=getattr(self.m, 'build_upstream', 'nxnative'),
                ).target_badge(self.m.t)
            )
            target_preview.setStyleSheet(
                _pill_style(style.ACCENT, 'rgba(255, 240, 214, 0.11)', 'rgba(255, 240, 214, 0.25)')
            )
            pick_bar.addWidget(target_preview)
            root.addLayout(pick_bar)

            scroll = QScrollArea()
            scroll.setWidgetResizable(True)
            scroll.setHorizontalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
            self.list_host = QWidget()
            self.list_layout = QVBoxLayout(self.list_host)
            self.list_layout.setContentsMargins(0, 2, 4, 2)
            self.list_layout.setSpacing(8)
            scroll.setWidget(self.list_host)
            root.addWidget(scroll, 1)

            foot = QHBoxLayout()
            foot.setSpacing(10)
            self.count_lbl = QLabel('')
            self.count_lbl.setObjectName('muted')
            foot.addWidget(self.count_lbl)
            foot.addStretch(1)

            self.close_btn = QPushButton(self.m.t('queue.close'))
            self.close_btn.setObjectName('ghost')
            self.close_btn.clicked.connect(self.reject)
            foot.addWidget(self.close_btn)

            self.add_btn = QPushButton(self.m.t('queue.add'))
            self.add_btn.setObjectName('creamPill')
            self.add_btn.clicked.connect(self._accept_selected)
            foot.addWidget(self.add_btn)
            root.addLayout(foot)

            initial: list[DiscoveredGame] = []
            precheck_all = False
            if discovered is not None:
                initial.extend(discovered)
                precheck_all = True
            else:
                initial.extend(self._library_candidates())
            self._merge_candidates(initial, check_new=precheck_all)

        def _library_candidates(self) -> list[DiscoveredGame]:
            out: list[DiscoveredGame] = []
            for g in getattr(self.m.library, 'games', []):
                base = (g.inputs.get('base') or [''])[0]
                if not base:
                    continue
                is_folder = _inputs.is_game_folder_candidate(base)
                out.append(DiscoveredGame(
                    title_id=g.title_id,
                    name=g.name or g.title_id,
                    base_path=base,
                    update_path=(g.inputs.get('update') or [''])[0],
                    dlc_paths=list(g.inputs.get('dlc') or []),
                    keys_path=(g.inputs.get('keys') or [''])[0] or getattr(self.m, 'keys_path', ''),
                    game_dir=base if is_folder else str(Path(base).parent),
                    is_game_folder=is_folder,
                ))
            return out

        def _make_probe_entry(self, g: DiscoveredGame, batch_id: str = '') -> QueueEntry:
            return g.to_queue_entry(
                out_dir=getattr(self.m, 'out_dir', ''),
                target=getattr(self.m, 'target', 'ios'),
                ipa_kind=getattr(self.m, 'ipa_kind', 'shared'),
                upstream=getattr(self.m, 'build_upstream', 'nxnative'),
                bc_on_cpu=bool(getattr(self.m, 'bc_on_cpu', False)),
                keys_path=getattr(self.m, 'keys_path', ''),
                batch_id=batch_id,
            )

        def _merge_candidates(self, new_games: list[DiscoveredGame], *, check_new: bool = True) -> None:
            existing_ids = {
                (g.title_id.upper() if g.title_id else os.path.normcase(os.path.abspath(g.base_path or g.game_dir)))
                for g in self._candidates
            }
            checked_ids = {
                (g.title_id.upper() if g.title_id else os.path.normcase(os.path.abspath(g.base_path or g.game_dir)))
                for cb, g in self._checkboxes
                if cb.isChecked()
            }
            for g in new_games:
                key = g.title_id.upper() if g.title_id else os.path.normcase(os.path.abspath(g.base_path or g.game_dir))
                if key not in existing_ids:
                    self._candidates.append(g)
                    existing_ids.add(key)
                    if check_new:
                        checked_ids.add(key)
            self._rebuild_list(checked_ids)

        def _rebuild_list(self, checked_ids: set[str]) -> None:
            self._checkboxes.clear()
            while self.list_layout.count():
                it = self.list_layout.takeAt(0)
                w = it.widget()
                if w is not None:
                    w.hide()
                    w.setParent(None)
                    w.deleteLater()

            t = self.m.t
            if not self._candidates:
                lbl = QLabel(t('queue.selectEmpty'))
                lbl.setObjectName('muted')
                lbl.setWordWrap(True)
                self.list_layout.addWidget(lbl)
                self.list_layout.addStretch(1)
                self._update_footer()
                return

            grp = CardGroup()
            for idx, g in enumerate(self._candidates):
                if idx > 0:
                    grp.add_divider()
                probe = self._make_probe_entry(g)
                available = self.q.can_enqueue(probe)
                key = g.title_id.upper() if g.title_id else os.path.normcase(os.path.abspath(g.base_path or g.game_dir))

                row = QWidget()
                rl = QHBoxLayout(row)
                rl.setContentsMargins(16, 11, 16, 11)
                rl.setSpacing(12)

                cb = QCheckBox()
                cb.setEnabled(available)
                cb.setChecked(available and key in checked_ids)
                cb.toggled.connect(self._update_footer)
                rl.addWidget(cb)

                col = QVBoxLayout()
                col.setSpacing(2)
                name_lbl = QLabel(g.name)
                name_lbl.setObjectName('rowTitle')
                col.addWidget(name_lbl)
                sub_parts = [p for p in (g.title_id, g.input_summary(t)) if p]
                sub_lbl = QLabel(' · '.join(sub_parts))
                sub_lbl.setObjectName('mono')
                col.addWidget(sub_lbl)
                rl.addLayout(col, 1)

                if not available:
                    badge = QLabel(t('queue.alreadyQueued'))
                    badge.setStyleSheet(
                        _pill_style(style.AMBER, 'rgba(255, 189, 56, 0.14)', 'rgba(255, 189, 56, 0.35)')
                    )
                    rl.addWidget(badge)

                self._checkboxes.append((cb, g))
                grp.add_row(row)

            self.list_layout.addWidget(grp)
            self.list_layout.addStretch(1)
            self._update_footer()

        def _update_footer(self) -> None:
            selected = sum(1 for cb, _g in self._checkboxes if cb.isEnabled() and cb.isChecked())
            self.count_lbl.setText(self.m.t('queue.count', selected) if selected > 0 else '')
            self.add_btn.setEnabled(selected > 0)

        def _pick_files(self) -> None:
            start = getattr(self.m, 'game_dir', '') or str(Path.home())
            files, _ = QFileDialog.getOpenFileNames(
                self,
                self.m.t('queue.select'),
                start,
                'Switch games (*.nsp *.xci *.nsz *.xcz *.nup);;All files (*)',
            )
            if not files:
                return
            res = discover_game_groups(
                files,
                keys_path=getattr(self.m, 'keys_path', ''),
                engine_path=getattr(self.m, 'engine_path', ''),
                library=getattr(self.m, 'library', None),
            )
            if res.keys_path and not getattr(self.m, 'keys_path', ''):
                self.m.keys_path = res.keys_path
            if res.games:
                self._merge_candidates(res.games, check_new=True)

        def _pick_folder(self) -> None:
            start = getattr(self.m, 'game_dir', '') or getattr(self.m.library, 'games_folder', '') or str(Path.home())
            folder = QFileDialog.getExistingDirectory(self, self.m.t('data.pickFolder'), start)
            if not folder:
                return
            res = discover_game_groups(
                [folder],
                keys_path=getattr(self.m, 'keys_path', ''),
                engine_path=getattr(self.m, 'engine_path', ''),
                library=getattr(self.m, 'library', None),
            )
            if res.keys_path and not getattr(self.m, 'keys_path', ''):
                self.m.keys_path = res.keys_path
            if res.games:
                self._merge_candidates(res.games, check_new=True)

        def _accept_selected(self) -> None:
            batch_id = uuid.uuid4().hex
            self._chosen = [
                self._make_probe_entry(g, batch_id=batch_id)
                for cb, g in self._checkboxes
                if cb.isEnabled() and cb.isChecked()
            ]
            if not self._chosen:
                return
            self.accept()

        def chosen_entries(self) -> list[QueueEntry]:
            return list(self._chosen)
