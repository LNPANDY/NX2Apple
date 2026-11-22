"""Managed storage, download, and safe extraction for optional external build engines.

Pure Python stdlib + `archive_guard` (no PySide6 dependency) so Ubuntu CI runs its unit tests directly.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
import inspect
import json
import os
from pathlib import Path
import re
import stat
import sys
import threading
import time
import urllib.error
import urllib.request
import uuid
import zipfile
from typing import Any, Callable

from . import archive_guard as ag
from . import engine
from . import s2arm_builder

ARCHIVE_URLS: dict[str, str] = {
    's2arm': 'https://codeload.github.com/jhaizhou-ops/S2Arm/zip/refs/heads/main',
    'macnativegames': 'https://codeload.github.com/ly05010419/MacNativeGames/zip/refs/heads/main',
}

INFO_REFS_URLS: dict[str, str] = {
    's2arm': 'https://github.com/jhaizhou-ops/S2Arm/info/refs?service=git-upload-pack',
    'macnativegames': 'https://github.com/ly05010419/MacNativeGames/info/refs?service=git-upload-pack',
}

RECEIPT_FILENAME = '.upstream-version.json'
REMOTE_CACHE_TTL_SECONDS = 600.0
QUICK_FETCH_TIMEOUT_SECONDS = 8.0
_HEX40_RE = re.compile(r'^[0-9a-f]{40}$')
_HEX7_PLUS_RE = re.compile(r'^[0-9a-f]{7,}$')
_SEMVER_TAG_RE = re.compile(r'^v(\d+)\.(\d+)(?:\.(\d+))?$')
_MNG_SOURCE_TAG_RE = re.compile(r'^source-(\d{4})(\d{2})(\d{2})-([0-9a-f]{7,40})$', re.IGNORECASE)


@dataclass(frozen=True)
class UpstreamVersionReceipt:
    commit: str | None
    version: str
    installed_at: str

    @property
    def short_commit(self) -> str | None:
        return self.commit[:7] if self.commit and len(self.commit) >= 7 else None


@dataclass(frozen=True)
class UpstreamRemoteInfo:
    kind: str
    commit: str
    version: str
    date: str

    @property
    def short_commit(self) -> str:
        return self.commit[:7]

    @property
    def tooltip_detail(self) -> str:
        short = self.short_commit
        if short and self.version != short:
            return f'{self.version} ({short})'
        return self.version


def normalized_commit(raw: str | None) -> str | None:
    if not raw or not isinstance(raw, str):
        return None
    cleaned = raw.strip().lower()
    return cleaned if _HEX40_RE.match(cleaned) else None


def _format_utc_date(ts: float | None = None) -> str:
    dt = datetime.fromtimestamp(time.time() if ts is None else ts, tz=timezone.utc)
    return dt.strftime('%Y.%m.%d')


def _format_iso_date(raw: str | None) -> str:
    if not raw or not isinstance(raw, str):
        return ''
    s = raw.strip()
    if len(s) < 10:
        return ''
    parts = s[:10].split('-')
    if len(parts) == 3 and len(parts[0]) == 4 and len(parts[1]) == 2 and len(parts[2]) == 2 and all(p.isdigit() for p in parts):
        return f'{parts[0]}.{parts[1]}.{parts[2]}'
    return ''


def extract_git_commit_from_zip(zip_path: Path | str) -> str | None:
    """Extract the 40-hex Git commit SHA stored in GitHub codeload ZIP EOCD comment."""
    try:
        with zipfile.ZipFile(ag.win_path(zip_path), 'r') as zf:
            raw = zf.comment.decode('utf-8', 'ignore')
            return normalized_commit(raw)
    except (zipfile.BadZipFile, OSError, ValueError):
        return None


def _is_semver_prefix(text: str) -> bool:
    base = text[:-1] if text.endswith('+') else text
    return bool(_SEMVER_TAG_RE.match(base))


def receipt_for_install(
    kind: str,
    zip_path: Path | str,
    remote_info: UpstreamRemoteInfo | None = None,
    *,
    now: float | None = None,
) -> UpstreamVersionReceipt:
    installed_at = _format_utc_date(now)
    zip_commit = extract_git_commit_from_zip(zip_path)
    remote_commit = normalized_commit(remote_info.commit) if remote_info is not None else None
    commit = zip_commit or remote_commit

    if remote_info is not None and commit and remote_commit == commit and remote_info.version:
        version = remote_info.version
    elif commit:
        if kind == 'macnativegames':
            version = installed_at
        elif kind == 's2arm':
            if remote_info is not None and remote_info.version and _is_semver_prefix(remote_info.version):
                version = remote_info.version if remote_info.version.endswith('+') else remote_info.version + '+'
            else:
                version = commit[:7]
        else:
            version = commit[:7]
    elif remote_info is not None and remote_info.version:
        version = remote_info.version
    else:
        version = installed_at

    return UpstreamVersionReceipt(commit=commit, version=version, installed_at=installed_at)


def write_version_receipt(directory: Path | str, receipt: UpstreamVersionReceipt) -> None:
    payload: dict[str, Any] = {
        'installedAt': receipt.installed_at,
        'version': receipt.version,
    }
    if receipt.commit:
        payload['commit'] = receipt.commit
    target = Path(directory) / RECEIPT_FILENAME
    target.write_text(json.dumps(payload, sort_keys=True), encoding='utf-8')


def read_version_receipt(directory: Path | str) -> UpstreamVersionReceipt | None:
    target = Path(directory) / RECEIPT_FILENAME
    try:
        if not target.is_file():
            return None
        data = json.loads(target.read_text(encoding='utf-8'))
    except (OSError, ValueError, TypeError):
        return None
    if not isinstance(data, dict):
        return None
    ver = str(data.get('version') or '').strip()
    if not ver:
        return None
    commit = normalized_commit(data.get('commit') if isinstance(data.get('commit'), str) else None)
    installed_at = str(data.get('installedAt') or '').strip()
    return UpstreamVersionReceipt(commit=commit, version=ver, installed_at=installed_at)


def read_builtin_receipt(repo_path: str = '') -> UpstreamVersionReceipt | None:
    candidates: list[Path] = []
    if repo_path:
        candidates.append(Path(repo_path) / '.upstream-ref')
        eng = engine.engine_root(repo_path)
        if eng:
            candidates.append(Path(eng) / '.upstream-ref')
    bundled = engine.bundled_engine()
    if bundled:
        candidates.append(Path(bundled) / '.upstream-ref')
    for path in candidates:
        try:
            if not path.is_file():
                continue
            raw = path.read_text(encoding='utf-8').strip().lower()
        except OSError:
            continue
        if _HEX7_PLUS_RE.match(raw):
            return UpstreamVersionReceipt(
                commit=raw if len(raw) == 40 else None,
                version=raw[:7],
                installed_at='',
            )
    return None


def read_local_receipt(
    kind: str,
    tree_path: str = '',
    *,
    repo_path: str = '',
    is_windows: bool | None = None,
) -> UpstreamVersionReceipt | None:
    if kind == 'nxnative':
        return read_builtin_receipt(repo_path)
    if not tree_path or not is_usable_upstream(tree_path, kind, is_windows=is_windows):
        return None
    receipt = read_version_receipt(tree_path)
    if receipt is not None:
        return receipt
    entry = Path(tree_path, 'build_app.py') if kind == 'macnativegames' else Path(tree_path, 'pack', 'jobs', 'main.py')
    try:
        mtime = entry.stat().st_mtime
    except OSError:
        return None
    date_str = _format_utc_date(mtime)
    return UpstreamVersionReceipt(commit=None, version=date_str, installed_at=date_str)


def _resolve_s2arm_version(main_sha: str, tag_commits: dict[str, str]) -> str | None:
    best: tuple[tuple[int, int, int], str, str] | None = None
    for name, sha in tag_commits.items():
        m = _SEMVER_TAG_RE.match(name)
        if not m:
            continue
        ver_tuple = (int(m.group(1)), int(m.group(2)), int(m.group(3) or 0))
        if best is None or ver_tuple > best[0] or (ver_tuple == best[0] and sha == main_sha):
            best = (ver_tuple, name, sha)
    if best is None:
        return None
    _, tag_name, tag_sha = best
    return tag_name if tag_sha == main_sha else f'{tag_name}+'


def _resolve_mng_version(
    main_sha: str,
    tag_commits: dict[str, str],
    *,
    now: float | None = None,
) -> tuple[str, str]:
    best_key = ''
    best_fmt = ''
    best_matched = False
    for name, sha in tag_commits.items():
        m = _MNG_SOURCE_TAG_RE.match(name)
        if not m:
            continue
        yyyy, mm, dd, prefix = m.group(1), m.group(2), m.group(3), m.group(4).lower()
        key = f'{yyyy}{mm}{dd}'
        fmt = f'{yyyy}.{mm}.{dd}'
        matched = (sha == main_sha) or main_sha.startswith(prefix)
        if key > best_key:
            best_key = key
            best_fmt = fmt
            best_matched = matched
        elif key == best_key and matched:
            best_matched = True
    if best_fmt:
        return (best_fmt if best_matched else f'{best_fmt}+'), best_fmt
    today = _format_utc_date(now)
    return today, today


def parse_info_refs(
    kind: str,
    payload: str | bytes,
    *,
    now: float | None = None,
) -> UpstreamRemoteInfo | None:
    """Parse Git Smart HTTP `info/refs?service=git-upload-pack` output without REST API rate limits."""
    if kind == 'nxnative':
        return None
    if isinstance(payload, bytes):
        text = payload.decode('utf-8', 'replace')
    elif isinstance(payload, str):
        text = payload
    else:
        return None

    main_sha: str | None = None
    head_sha: str | None = None
    tag_commits: dict[str, str] = {}
    deref_tags: set[str] = set()

    for raw_line in text.splitlines():
        line = raw_line.split('\x00', 1)[0].strip()
        if not line or '# service=' in line:
            continue
        while line.startswith('0000') and len(line) > 4:
            line = line[4:]
        if len(line) >= 45 and line[44] == ' ' and all(c in '0123456789abcdefABCDEF' for c in line[:4]):
            line = line[4:]
        parts = line.split(None, 1)
        if len(parts) != 2:
            continue
        sha = normalized_commit(parts[0])
        if not sha:
            continue
        ref = parts[1].strip()
        if ref == 'refs/heads/main':
            main_sha = sha
        elif ref == 'HEAD':
            head_sha = sha
        elif ref.startswith('refs/tags/'):
            raw_tag = ref[len('refs/tags/'):]
            if raw_tag.endswith('^{}'):
                base = raw_tag[:-3]
                tag_commits[base] = sha
                deref_tags.add(base)
            elif raw_tag not in deref_tags:
                tag_commits[raw_tag] = sha

    resolved_main = main_sha or head_sha
    if not resolved_main:
        return None
    if kind == 's2arm':
        ver = _resolve_s2arm_version(resolved_main, tag_commits) or resolved_main[:7]
        return UpstreamRemoteInfo(kind=kind, commit=resolved_main, version=ver, date='')
    if kind == 'macnativegames':
        ver, date_str = _resolve_mng_version(resolved_main, tag_commits, now=now)
        return UpstreamRemoteInfo(kind=kind, commit=resolved_main, version=ver, date=date_str)
    return None


def _default_fetch_text(url: str, timeout: float = 15.0) -> str | None:
    req = urllib.request.Request(
        url,
        headers={'User-Agent': 'NX2Apple/1.5'},
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        if getattr(resp, 'status', 200) != 200:
            return None
        return resp.read().decode('utf-8', 'replace')


def fetch_remote_info(
    kind: str,
    *,
    fetch_text: Callable[[str], str | bytes | None] | None = None,
    timeout: float = 15.0,
    now: float | None = None,
) -> UpstreamRemoteInfo | None:
    refs_url = INFO_REFS_URLS.get(kind)
    if not refs_url:
        return None
    loader = fetch_text or (lambda u: _default_fetch_text(u, timeout=timeout))
    try:
        payload = loader(refs_url)
    except Exception:
        return None
    if not payload:
        return None
    return parse_info_refs(kind, payload, now=now)


def has_update(
    local: UpstreamVersionReceipt | None,
    remote: UpstreamRemoteInfo | None,
) -> bool:
    if remote is None or not normalized_commit(remote.commit):
        return False
    if local is None:
        return False
    local_commit = normalized_commit(local.commit)
    if local_commit is None:
        return True
    return local_commit != normalized_commit(remote.commit)


def compact_badge_text(
    kind: str,
    local: UpstreamVersionReceipt | None,
    *,
    update_available: bool,
    builtin_fallback: str,
    installed_fallback: str,
) -> str:
    if upstream_is_builtin(kind):
        return local.version if (local is not None and local.version) else builtin_fallback
    base = local.version if (local is not None and local.version) else installed_fallback
    return f'{base} ↑' if update_available else base

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
    remote_info: UpstreamRemoteInfo | None = None,
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

        receipt = receipt_for_install(kind, zip_path, remote_info=remote_info)
        try:
            write_version_receipt(source, receipt)
        except OSError:
            pass

        if kind == 's2arm':
            from . import s2arm_bootstrap
            s2arm_bootstrap.ensure_git_repo(source)

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
    remote_info: UpstreamRemoteInfo | None = None,
    downloader: Callable[..., None] | None = None,
    fetch_text: Callable[[str], str | bytes | None] | None = None,
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
        resolved_remote = remote_info
        if resolved_remote is None and (fetch_text is not None or downloader is None):
            resolved_remote = fetch_remote_info(
                kind,
                fetch_text=fetch_text,
                timeout=QUICK_FETCH_TIMEOUT_SECONDS,
            )
            if cancel_event is not None and cancel_event.is_set():
                raise UpstreamInstallError('cancelled', 'download cancelled')
        if on_extracting is not None:
            on_extracting()
        return install_upstream_zip(
            zip_file,
            kind,
            base,
            remote_info=resolved_remote,
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
        remote_info: UpstreamRemoteInfo | None = None,
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
                    remote_info=remote_info,
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


class UpstreamVersionChecker:
    """Thread-safe async remote version checker with 10-minute non-failure cache (no PySide6 dependency)."""

    def __init__(
        self,
        *,
        on_changed: Callable[[], None] | None = None,
        ttl_seconds: float = REMOTE_CACHE_TTL_SECONDS,
        now_fn: Callable[[], float] | None = None,
    ) -> None:
        self._on_changed = on_changed
        self._ttl = float(ttl_seconds)
        self._now = now_fn or time.monotonic
        self._lock = threading.RLock()
        self._remote: dict[str, UpstreamRemoteInfo] = {}
        self._checked_at: dict[str, float] = {}
        self._generations: dict[str, int] = {}
        self._threads: dict[str, threading.Thread] = {}

    def _notify(self) -> None:
        if self._on_changed is not None:
            self._on_changed()

    def remote_info(self, kind: str) -> UpstreamRemoteInfo | None:
        with self._lock:
            return self._remote.get(kind)

    def set_remote_info(self, kind: str, info: UpstreamRemoteInfo | None, *, checked_at: float | None = None) -> None:
        with self._lock:
            if info is None:
                self._remote.pop(kind, None)
                self._checked_at.pop(kind, None)
            else:
                self._remote[kind] = info
                self._checked_at[kind] = self._now() if checked_at is None else checked_at
        self._notify()

    def clear_if_stale_after_install(self, kind: str, installed_commit: str | None) -> None:
        norm = normalized_commit(installed_commit)
        if not norm:
            return
        changed = False
        with self._lock:
            cached = self._remote.get(kind)
            if cached is not None and normalized_commit(cached.commit) != norm:
                self._remote.pop(kind, None)
                self._checked_at.pop(kind, None)
                changed = True
        if changed:
            self._notify()

    def check_async(
        self,
        kinds: tuple[str, ...] | list[str],
        *,
        is_installed: Callable[[str], bool],
        is_busy: Callable[[str], bool] | None = None,
        force: bool = False,
        fetch_text: Callable[[str], str | bytes | None] | None = None,
    ) -> list[threading.Thread]:
        spawned: list[threading.Thread] = []
        now = self._now()
        for kind in kinds:
            if upstream_is_builtin(kind) or not is_installed(kind):
                continue
            if is_busy is not None and is_busy(kind):
                continue
            with self._lock:
                if (
                    not force
                    and kind in self._remote
                    and kind in self._checked_at
                    and (now - self._checked_at[kind]) < self._ttl
                ):
                    continue
                gen = self._generations.get(kind, 0) + 1
                self._generations[kind] = gen

            def _worker(k: str = kind, g: int = gen) -> None:
                info = fetch_remote_info(k, fetch_text=fetch_text)
                if info is None:
                    # Never cache failed or empty lookups.
                    return
                with self._lock:
                    if self._generations.get(k) != g:
                        return
                    if not is_installed(k):
                        return
                    self._remote[k] = info
                    self._checked_at[k] = self._now()
                self._notify()

            t = threading.Thread(target=_worker, daemon=True)
            with self._lock:
                self._threads[kind] = t
            t.start()
            spawned.append(t)
        return spawned
