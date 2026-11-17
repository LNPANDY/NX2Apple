"""Managed storage, download, and safe extraction for optional external build engines.

Pure Python stdlib + `archive_guard` (no PySide6 dependency) so Ubuntu CI runs its unit tests directly.
"""
from __future__ import annotations

import inspect
import os
from pathlib import Path
import stat
import sys
import threading
import urllib.error
import urllib.request
import uuid
import zipfile
from typing import Callable

from . import archive_guard as ag
from . import engine
from . import s2arm_builder

ARCHIVE_URLS: dict[str, str] = {
    's2arm': 'https://codeload.github.com/jhaizhou-ops/S2Arm/zip/refs/heads/main',
    'macnativegames': 'https://codeload.github.com/ly05010419/MacNativeGames/zip/refs/heads/main',
}

UPSTREAM_META: dict[str, dict[str, object]] = {
    'nxnative': {
        'display_name': 'nxnative',
        'note_key': 'upstream.nxnativeCardNote',
        'builtin': True,
    },
    'macnativegames': {
        'display_name': 'MacNativeGames',
        'note_key': 'upstream.mngCardNote',
        'builtin': False,
    },
    's2arm': {
        'display_name': 'S2Arm',
        'note_key': 'upstream.s2armCardNote',
        'builtin': False,
    },
}

MAX_UPSTREAM_ENTRIES = 80_000
MAX_UPSTREAM_BYTES = 2 * 1024 * 1024 * 1024  # 2 GiB


class UpstreamInstallError(RuntimeError):
    """Raised when downloading or extracting an external upstream archive fails."""

    def __init__(self, kind: str, message: str = '') -> None:
        super().__init__(message or kind)
        self.kind = kind  # 'download' | 'extract' | 'cancelled' | 'unsupported'


def upstream_display_name(kind: str) -> str:
    meta = UPSTREAM_META.get(kind)
    return str(meta['display_name']) if meta and 'display_name' in meta else kind


def upstream_note_key(kind: str) -> str:
    meta = UPSTREAM_META.get(kind)
    return str(meta['note_key']) if meta and 'note_key' in meta else 'upstream.nxnativeCardNote'


def upstream_is_builtin(kind: str) -> bool:
    meta = UPSTREAM_META.get(kind)
    return bool(meta.get('builtin', False)) if meta else (kind == 'nxnative')


def default_upstreams_root() -> Path:
    """Return the managed directory holding downloaded external upstream trees."""
    if env_dir := os.environ.get('NX2APPLE_UPSTREAMS_DIR'):
        return Path(env_dir)
    if sys.platform == 'win32' or os.name == 'nt':
        base = Path(os.environ.get('LOCALAPPDATA') or os.environ.get('APPDATA') or Path.home() / 'AppData' / 'Local')
    elif sys.platform == 'darwin':
        base = Path.home() / 'Library' / 'Application Support'
    else:
        base = Path(os.environ.get('XDG_DATA_HOME') or Path.home() / '.local' / 'share')
    return base / 'NX2Apple' / 'upstreams'


def available_upstreams(*, is_windows: bool | None = None) -> tuple[str, ...]:
    """Upstreams offered in the Qt launcher Builder switcher."""
    _ = sys.platform == 'win32' if is_windows is None else is_windows
    if not s2arm_builder.feature_enabled():
        return ('nxnative',)
    return ('nxnative', 's2arm')


def is_usable_upstream(path: str, kind: str, *, is_windows: bool | None = None) -> bool:
    """Check whether `path` holds a complete, usable tree for `kind`."""
    if kind == 'nxnative':
        return True
    if kind == 's2arm':
        return s2arm_builder.is_usable_tree(path, is_windows=is_windows)
    if kind == 'macnativegames':
        return engine.is_upstream_tree(path, 'macnativegames')
    return False


def usable_managed_path(
    kind: str,
    root: Path | str | None = None,
    *,
    is_windows: bool | None = None,
) -> str:
    """Return `<root>/<kind>` if present and valid, else `''`."""
    if kind == 'nxnative':
        return ''
    base = Path(root) if root is not None else default_upstreams_root()
    cand = base / kind
    return str(cand) if is_usable_upstream(str(cand), kind, is_windows=is_windows) else ''


def format_download_progress(written: int, expected: int | None) -> tuple[float | None, str]:
    """Format byte counts into `(fraction, '12.3 / 92.0 MB (13%)')` or `(None, '12.3 MB')`."""
    safe_written = max(0, int(written))
    mb_written = safe_written / 1_048_576.0
    if expected is not None and expected > 0:
        frac = min(max(safe_written / float(expected), 0.0), 1.0)
        mb_expected = expected / 1_048_576.0
        pct = int(round(frac * 100))
        return frac, f'{mb_written:.1f} / {mb_expected:.1f} MB ({pct}%)'
    return None, f'{mb_written:.1f} MB'


def install_upstream_zip(
    zip_path: Path | str,
    kind: str,
    root: Path | str | None = None,
    *,
    is_windows: bool | None = None,
    cancel_event: threading.Event | None = None,
) -> Path:
    """Safely unpack `zip_path`, unwrap single-folder GitHub archive roots, and atomically install `<root>/<kind>`."""
    if kind not in ARCHIVE_URLS:
        raise UpstreamInstallError('unsupported', f'unsupported upstream kind: {kind}')
    if cancel_event is not None and cancel_event.is_set():
        raise UpstreamInstallError('cancelled', 'installation cancelled')
    base = Path(root) if root is not None else default_upstreams_root()
    base.mkdir(parents=True, exist_ok=True)
    tmp = base / f'.tmp-{uuid.uuid4().hex}'
    try:
        quota = ag.ArchiveQuota(max_entries=MAX_UPSTREAM_ENTRIES, max_bytes=MAX_UPSTREAM_BYTES)
        ag.extract_zip_safely(zip_path, tmp, quota=quota, allow_symlinks=True)
        if cancel_event is not None and cancel_event.is_set():
            raise UpstreamInstallError('cancelled', 'installation cancelled')

        source = tmp
        for _ in range(2):
            if is_usable_upstream(str(source), kind, is_windows=is_windows):
                break
            kids = [
                p for p in source.iterdir()
                if p.is_dir() and p.name != '__MACOSX' and not p.name.startswith('.')
            ]
            if len(kids) != 1:
                break
            source = kids[0]

        if not is_usable_upstream(str(source), kind, is_windows=is_windows):
            raise UpstreamInstallError('extract', f'incomplete {kind} archive')

        if os.name != 'nt':
            for rel in (('pack', 'oneclick', 'oneclick.sh'), ('pack', 'jobs', 'main.py'), ('build_app.py',)):
                script = source.joinpath(*rel)
                if script.is_file():
                    try:
                        mode = script.stat().st_mode
                        script.chmod(mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
                    except OSError:
                        pass

        if cancel_event is not None and cancel_event.is_set():
            raise UpstreamInstallError('cancelled', 'installation cancelled')

        dest = base / kind
        return ag.install_staged_tree(
            source,
            dest,
            validator=lambda d: is_usable_upstream(str(d), kind, is_windows=is_windows),
        )
    except UpstreamInstallError:
        raise
    except (zipfile.BadZipFile, OSError, ag.ArchiveSafetyError) as exc:
        raise UpstreamInstallError('extract', str(exc)) from exc
    finally:
        ag.rmtree_force(tmp)


def _stream_download(
    url: str,
    dest_zip: Path,
    on_progress: Callable[[int, int | None], None] | None,
    timeout: float = 60.0,
    cancel_event: threading.Event | None = None,
) -> None:
    if cancel_event is not None and cancel_event.is_set():
        raise UpstreamInstallError('cancelled', 'download cancelled')
    req = urllib.request.Request(url, headers={'User-Agent': 'NX2Apple/1.5'})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            if cancel_event is not None and cancel_event.is_set():
                raise UpstreamInstallError('cancelled', 'download cancelled')
            status = getattr(resp, 'status', 200)
            if status != 200:
                raise UpstreamInstallError('download', f'HTTP {status}')
            raw_len = resp.headers.get('Content-Length') if hasattr(resp, 'headers') and resp.headers else None
            expected = int(raw_len) if raw_len and raw_len.isdigit() and int(raw_len) > 0 else None
            written = 0
            if on_progress is not None:
                on_progress(0, expected)
            with open(ag.win_path(dest_zip), 'wb') as out:
                while True:
                    if cancel_event is not None and cancel_event.is_set():
                        raise UpstreamInstallError('cancelled', 'download cancelled')
                    chunk = resp.read(65536)
                    if not chunk:
                        break
                    if cancel_event is not None and cancel_event.is_set():
                        raise UpstreamInstallError('cancelled', 'download cancelled')
                    out.write(chunk)
                    written += len(chunk)
                    if on_progress is not None:
                        on_progress(written, expected)
    except UpstreamInstallError:
        raise
    except (urllib.error.URLError, OSError, ValueError) as exc:
        raise UpstreamInstallError('download', str(exc)) from exc


def download_and_install_upstream(
    kind: str,
    root: Path | str | None = None,
    *,
    downloader: Callable[..., None] | None = None,
    on_progress: Callable[[int, int | None], None] | None = None,
    on_extracting: Callable[[], None] | None = None,
    is_windows: bool | None = None,
    cancel_event: threading.Event | None = None,
) -> Path:
    """Download `kind` archive, extract it atomically into `<root>/<kind>`, and return its path."""
    url = ARCHIVE_URLS.get(kind)
    if not url:
        raise UpstreamInstallError('unsupported', f'unsupported upstream kind: {kind}')
    if cancel_event is not None and cancel_event.is_set():
        raise UpstreamInstallError('cancelled', 'download cancelled')
    base = Path(root) if root is not None else default_upstreams_root()
    base.mkdir(parents=True, exist_ok=True)
    zip_file = base / f'.download-{uuid.uuid4().hex}.zip'

    def _checked_progress(written: int, expected: int | None) -> None:
        if cancel_event is not None and cancel_event.is_set():
            raise UpstreamInstallError('cancelled', 'download cancelled')
        if on_progress is not None:
            on_progress(written, expected)

    try:
        if downloader is None:
            _stream_download(url, zip_file, _checked_progress, cancel_event=cancel_event)
        else:
            params = inspect.signature(downloader).parameters
            if 'cancel_event' in params:
                downloader(url, zip_file, _checked_progress, cancel_event=cancel_event)
            else:
                downloader(url, zip_file, _checked_progress)
        if cancel_event is not None and cancel_event.is_set():
            raise UpstreamInstallError('cancelled', 'download cancelled')
        if on_extracting is not None:
            on_extracting()
        return install_upstream_zip(
            zip_file,
            kind,
            base,
            is_windows=is_windows,
            cancel_event=cancel_event,
        )
    finally:
        ag.rmtree_force(zip_file)


class UpstreamDownloadCoordinator:
    """Thread-safe download/cancel/generation state machine without PySide6 dependency."""

    def __init__(
        self,
        *,
        root: Path | str | None = None,
        is_running: Callable[[], bool] | None = None,
        on_installed: Callable[[str, Path], None] | None = None,
        on_changed: Callable[[], None] | None = None,
    ) -> None:
        self.root = Path(root) if root is not None else None
        self._is_running = is_running or (lambda: False)
        self._on_installed = on_installed
        self._on_changed = on_changed
        self._lock = threading.RLock()
        self.states: dict[str, tuple[str, float | None, str]] = {}
        self._generations: dict[str, int] = {}
        self._cancel_events: dict[str, threading.Event] = {}
        self._threads: dict[str, threading.Thread] = {}

    def _notify(self) -> None:
        if self._on_changed is not None:
            self._on_changed()

    def state(self, kind: str, *, installed: bool = False) -> tuple[str, float | None, str]:
        if kind == 'nxnative':
            return ('builtin', None, '')
        with self._lock:
            active = self.states.get(kind)
        if active is not None:
            if active[0] == 'failed' and installed:
                return ('installed', None, '')
            return active
        return ('installed', None, '') if installed else ('not_installed', None, '')

    def is_busy(self, kind: str) -> bool:
        with self._lock:
            cur = self.states.get(kind)
        return bool(cur is not None and cur[0] in ('downloading', 'extracting'))

    def cancel(self, kind: str) -> bool:
        with self._lock:
            ev = self._cancel_events.pop(kind, None)
            had_active = kind in self.states
            self._generations[kind] = self._generations.get(kind, 0) + 1
            self.states.pop(kind, None)
            self._threads.pop(kind, None)
        if ev is not None:
            ev.set()
        if had_active or ev is not None:
            self._notify()
            return True
        return False

    def start_download(
        self,
        kind: str,
        *,
        downloader: Callable[..., None] | None = None,
        is_windows: bool | None = None,
    ) -> threading.Thread | None:
        if kind == 'nxnative' or self._is_running():
            return None
        with self._lock:
            cur = self.states.get(kind)
            if cur is not None and cur[0] in ('downloading', 'extracting'):
                return self._threads.get(kind)
            gen = self._generations.get(kind, 0) + 1
            self._generations[kind] = gen
            cancel_ev = threading.Event()
            self._cancel_events[kind] = cancel_ev
            self.states[kind] = ('downloading', None, '')
        self._notify()

        def _worker() -> None:
            def _on_prog(written: int, expected: int | None) -> None:
                frac, txt = format_download_progress(written, expected)
                with self._lock:
                    if self._generations.get(kind) != gen or cancel_ev.is_set():
                        return
                    cur_s = self.states.get(kind)
                    if cur_s is None or cur_s[0] != 'downloading':
                        return
                    self.states[kind] = ('downloading', frac, txt)
                self._notify()

            def _on_ext() -> None:
                with self._lock:
                    if self._generations.get(kind) != gen or cancel_ev.is_set():
                        return
                    self.states[kind] = ('extracting', None, '')
                self._notify()

            try:
                installed_dir = download_and_install_upstream(
                    kind,
                    self.root,
                    downloader=downloader,
                    on_progress=_on_prog,
                    on_extracting=_on_ext,
                    is_windows=is_windows,
                    cancel_event=cancel_ev,
                )
            except UpstreamInstallError as exc:
                if exc.kind == 'cancelled':
                    with self._lock:
                        if self._generations.get(kind) == gen:
                            self.states.pop(kind, None)
                            self._cancel_events.pop(kind, None)
                            self._threads.pop(kind, None)
                    self._notify()
                    return
                err_kind = 'download' if exc.kind == 'download' else 'extract'
                with self._lock:
                    if self._generations.get(kind) != gen or cancel_ev.is_set():
                        return
                    self.states[kind] = ('failed', None, err_kind)
                    self._cancel_events.pop(kind, None)
                    self._threads.pop(kind, None)
                self._notify()
                return
            except Exception:
                with self._lock:
                    if self._generations.get(kind) != gen or cancel_ev.is_set():
                        return
                    self.states[kind] = ('failed', None, 'extract')
                    self._cancel_events.pop(kind, None)
                    self._threads.pop(kind, None)
                self._notify()
                return

            with self._lock:
                if self._generations.get(kind) != gen or cancel_ev.is_set():
                    return
                self.states.pop(kind, None)
                self._cancel_events.pop(kind, None)
                self._threads.pop(kind, None)
                if self._on_installed is not None:
                    self._on_installed(kind, installed_dir)
            self._notify()

        thread = threading.Thread(target=_worker, daemon=True)
        with self._lock:
            self._threads[kind] = thread
        thread.start()
        return thread
