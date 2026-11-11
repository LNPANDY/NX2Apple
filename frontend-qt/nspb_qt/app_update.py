"""Self-update for the Windows Qt launcher: release check, zip verification, staging, and relaunch.

Mirrors the rules of `frontend/Sources/NXCore/AppUpdate.swift` so both desktop launchers
compare versions, match release assets, and verify SHA-256 digests identically.
"""
from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
import zipfile

from . import archive_guard as ag

#: Bump together with each release tag and `AppUpdateStore.appVersion` in Swift.
APP_VERSION = '1.4.0'

MAX_UPDATE_ENTRIES = 40_000
MAX_UPDATE_BYTES = 2 * 1024 * 1024 * 1024

LATEST_RELEASE_URL = 'https://api.github.com/repos/LNPANDY/NX2Apple/releases/latest'
RELEASES_PAGE_URL = 'https://github.com/LNPANDY/NX2Apple/releases/latest'

#: Accepted Windows release zip names, newest first.
ASSET_NAMES = (
    'NX2Apple-windows-x64.zip',
    'NS-Port-Builder-qt-windows-x64.zip',
)

#: Accepted executable names inside the unpacked Windows bundle, newest first.
EXE_NAMES = (
    'NX2Apple.exe',
    'NS Port Builder.exe',
)


@dataclass(frozen=True)
class Release:
    tag: str
    url: str
    digest: str | None = None
    notes: str = ''
    html_url: str = RELEASES_PAGE_URL


@dataclass(frozen=True)
class CheckResult:
    kind: str   # 'unreachable' | 'up_to_date' | 'found' | 'no_asset'
    release: Release | None = None
    tag: str = ''


@dataclass(frozen=True)
class StagedUpdate:
    release: Release
    app_dir: Path
    exe_name: str
    staging_root: Path


class StageError(Exception):
    """Raised when downloading, verifying, or unpacking an update fails.

    `key` is the localization key in `frontend/l10n/*.json` taking the release tag.
    """

    def __init__(self, key: str) -> None:
        super().__init__(key)
        self.key = key


def _parse_version(s: str) -> tuple[list[int], int | None]:
    v = s.strip().lstrip('vV')
    rc: int | None = None
    m = re.match(r'^(.+?)-rc([1-9]\d*)$', v, re.I)
    if m:
        v, rc = m.group(1), int(m.group(2))
    nums: list[int] = []
    for part in v.split('.'):
        digits = ''.join(ch for ch in part if ch.isdigit())
        nums.append(int(digits) if digits else 0)
    return nums, rc


def is_newer(tag: str, current: str) -> bool:
    """True when `tag` ('v1.2.2') is a newer version than `current` ('1.2.0' or '1.2.2-rc3')."""
    if not tag or not current:
        return False
    a_nums, a_rc = _parse_version(tag)
    b_nums, b_rc = _parse_version(current)
    length = max(len(a_nums), len(b_nums))
    for i in range(length):
        x = a_nums[i] if i < len(a_nums) else 0
        y = b_nums[i] if i < len(b_nums) else 0
        if x != y:
            return x > y
    if a_rc is None and b_rc is not None:
        return True
    if a_rc is not None and b_rc is not None:
        return a_rc > b_rc
    return False


def release_from_json(obj: dict) -> Release | None:
    """Extract the Windows release asset and its SHA-256 digest from a GitHub release object."""
    if not isinstance(obj, dict) or obj.get('draft') or obj.get('prerelease'):
        return None
    tag = str(obj.get('tag_name') or '').strip()
    assets = obj.get('assets')
    if not tag or not isinstance(assets, list):
        return None
    html_url = str(obj.get('html_url') or RELEASES_PAGE_URL).strip() or RELEASES_PAGE_URL
    notes = str(obj.get('body') or '')
    for wanted in ASSET_NAMES:
        for a in assets:
            if isinstance(a, dict) and a.get('name') == wanted:
                u = a.get('browser_download_url')
                if isinstance(u, str) and u.strip():
                    digest = a.get('digest')
                    return Release(
                        tag=tag,
                        url=u.strip(),
                        digest=digest.strip() if isinstance(digest, str) and digest.strip() else None,
                        notes=notes,
                        html_url=html_url,
                    )
    return None


def check_release(data: bytes | str | None, current: str = APP_VERSION) -> CheckResult:
    """Compare GitHub's `releases/latest` response against `current`."""
    if not data:
        return CheckResult('unreachable')
    try:
        text = data.decode('utf-8', errors='replace') if isinstance(data, (bytes, bytearray)) else str(data)
        obj = json.loads(text)
    except (ValueError, TypeError):
        return CheckResult('up_to_date')
    if not isinstance(obj, dict) or obj.get('draft') or obj.get('prerelease'):
        return CheckResult('up_to_date')
    tag = str(obj.get('tag_name') or '').strip()
    if not is_newer(tag, current):
        return CheckResult('up_to_date')
    rel = release_from_json(obj)
    if rel is None:
        return CheckResult('no_asset', tag=tag)
    return CheckResult('found', release=rel, tag=tag)


def fetch_latest_json(url: str = LATEST_RELEASE_URL, timeout: float = 15.0) -> bytes | None:
    """Fetch the latest release metadata from GitHub."""
    req = urllib.request.Request(
        url,
        headers={
            'Accept': 'application/vnd.github+json',
            'User-Agent': f'NX2Apple/{APP_VERSION}',
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.read()
    except (urllib.error.URLError, OSError, ValueError):
        return None


def sha256_file(path: Path) -> str | None:
    """Return the lowercase hex SHA-256 of `path`, or None on I/O error."""
    h = hashlib.sha256()
    try:
        with open(path, 'rb') as f:
            while True:
                chunk = f.read(1 << 20)
                if not chunk:
                    break
                h.update(chunk)
        return h.hexdigest().lower()
    except OSError:
        return None


def check_digest(path: Path, expected: str | None) -> str:
    """Compare `path` against `expected` ('sha256:<hex>'). Returns 'match' | 'mismatch' | 'missing'."""
    if not expected or not expected.lower().startswith('sha256:'):
        return 'missing'
    want = expected[len('sha256:'):].strip().lower()
    if not want:
        return 'missing'
    if len(want) != 64 or any(c not in '0123456789abcdef' for c in want):
        return 'mismatch'
    have = sha256_file(path)
    if have is None:
        return 'mismatch'
    return 'match' if have == want else 'mismatch'


def fresh_staging_root(base_temp: Path | None = None) -> Path:
    """Return an empty staging directory for unpacking an update."""
    root = (base_temp or Path(tempfile.gettempdir())) / 'nx2apple-update'
    shutil.rmtree(root, ignore_errors=True)
    root.mkdir(parents=True, exist_ok=True)
    return root


def _safe_extract_zip(
    zip_path: Path,
    dest_dir: Path,
    *,
    quota: ag.ArchiveQuota | None = None,
) -> ag.ArchiveQuota:
    """Extract `zip_path` into `dest_dir` with unified path, symlink, and quota enforcement."""
    ledger = quota or ag.ArchiveQuota(
        max_entries=MAX_UPDATE_ENTRIES,
        max_bytes=MAX_UPDATE_BYTES,
    )
    return ag.extract_zip_safely(
        zip_path,
        dest_dir,
        quota=ledger,
        error_cls=ag.ArchiveSafetyError,
    )


def _find_bundled_app_dir(unpacked_dir: Path) -> tuple[Path, str] | None:
    """Locate the unpacked PyInstaller app directory containing `NX2Apple.exe` and `_internal/`."""
    candidates = [unpacked_dir]
    try:
        candidates.extend(sorted(p for p in unpacked_dir.iterdir() if p.is_dir()))
    except OSError:
        return None
    for cand in candidates:
        if not (cand / '_internal').is_dir():
            continue
        for exe_name in EXE_NAMES:
            if (cand / exe_name).is_file():
                return cand, exe_name
    return None


def stage_zip(
    zip_path: Path,
    release: Release,
    staging_root: Path,
    require_digest: bool = False,
) -> StagedUpdate:
    """Verify `zip_path`, unpack it inside `staging_root`, and validate the bundle layout."""
    verdict = check_digest(zip_path, release.digest)
    if verdict == 'mismatch':
        zip_path.unlink(missing_ok=True)
        raise StageError('app.digestMismatch')
    if verdict == 'missing' and require_digest:
        zip_path.unlink(missing_ok=True)
        raise StageError('app.noDigest')

    unpacked = staging_root / 'unpacked'
    ag.rmtree_force(unpacked)
    unpacked.mkdir(parents=True, exist_ok=True)
    try:
        _safe_extract_zip(zip_path, unpacked)
    except (zipfile.BadZipFile, OSError, ag.ArchiveSafetyError) as exc:
        zip_path.unlink(missing_ok=True)
        ag.rmtree_force(unpacked)
        raise StageError('app.unpackFail') from exc
    zip_path.unlink(missing_ok=True)

    found = _find_bundled_app_dir(unpacked)
    if found is None:
        ag.rmtree_force(unpacked)
        raise StageError('app.notOurApp')
    app_dir, exe_name = found
    return StagedUpdate(release=release, app_dir=app_dir, exe_name=exe_name, staging_root=staging_root)


def apply_staged_update(
    staged: StagedUpdate | Path,
    target_dir: Path,
    *,
    move_fn=None,
) -> Path:
    """Install a staged app bundle into `target_dir` with `.old` backup and failure cleanup."""
    staged_dir = staged.app_dir if isinstance(staged, StagedUpdate) else Path(staged)
    return ag.install_staged_tree(
        staged_dir,
        target_dir,
        validator=lambda d: _find_bundled_app_dir(d) is not None,
        move_fn=move_fn,
        error_cls=StageError,
    )


def _sanitize_relaunch_env(base_env: dict[str, str], target_dir: Path) -> dict[str, str]:
    """Strip only PyInstaller freeze pollution while preserving user PYTHONPATH in normal runs."""
    env = dict(base_env)
    meipass = getattr(sys, '_MEIPASS', None) or env.get('_MEIPASS') or env.get('_MEIPASS2')
    is_frozen = bool(getattr(sys, 'frozen', False))
    env.pop('_MEIPASS', None)
    env.pop('_MEIPASS2', None)
    if is_frozen:
        env.pop('PYTHONHOME', None)
        env.pop('QT_PLUGIN_PATH', None)
        env.pop('QML2_IMPORT_PATH', None)
    if (is_frozen or meipass) and 'PYTHONPATH' in env:
        polluted_roots: list[str] = []
        if meipass:
            polluted_roots.append(os.path.abspath(os.fspath(meipass)))
        if is_frozen:
            polluted_roots.append(os.path.abspath(os.fspath(target_dir / '_internal')))
            exe_internal = Path(sys.executable).resolve().parent / '_internal'
            polluted_roots.append(os.path.abspath(os.fspath(exe_internal)))

        def _is_polluted(entry: str) -> bool:
            entry_abs = os.path.abspath(entry)
            return any(ag.is_same_or_within(entry_abs, root) for root in polluted_roots)

        win_sep = ';'
        sep = win_sep if (os.name == 'nt' or win_sep in env['PYTHONPATH']) else os.pathsep
        kept = [item for item in env['PYTHONPATH'].split(sep) if item and not _is_polluted(item)]
        if kept:
            env['PYTHONPATH'] = sep.join(kept)
        else:
            env.pop('PYTHONPATH', None)
    return env


#: Pure-ASCII PowerShell script that waits for the running process to exit, backs up any existing
#: bundle to `.<name>.old`, copies the staged update into place, rolls back on failure, and launches.
WINDOWS_RELAUNCH_PS1 = "\n".join([
    "$pidToWait = [int]$env:NX_PID",
    "for ($i = 0; $i -lt 150; $i++) {",
    "  if (-not (Get-Process -Id $pidToWait -ErrorAction SilentlyContinue)) { break }",
    "  Start-Sleep -Milliseconds 200",
    "}",
    "Start-Sleep -Milliseconds 400",
    "$target = $env:NX_TARGET",
    "$parent = Split-Path -Parent $target",
    "$leaf = Split-Path -Leaf $target",
    "$backup = Join-Path $parent (\".\" + $leaf + \".old\")",
    "$hadExisting = Test-Path -LiteralPath $target",
    "if ($hadExisting) {",
    "  if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Recurse -Force -ErrorAction SilentlyContinue }",
    "  Copy-Item -LiteralPath $target -Destination $backup -Recurse -Force -ErrorAction SilentlyContinue",
    "}",
    "& robocopy $env:NX_STAGED $target /E /IS /IT /IM /NFL /NDL /NJH /NJS /R:10 /W:1 | Out-Null",
    "$rc = $LASTEXITCODE",
    "$newExe = Join-Path $target $env:NX_NEW_EXE",
    "if (($rc -ge 8) -or (-not (Test-Path -LiteralPath $newExe))) {",
    "  if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue }",
    "  if ($hadExisting -and (Test-Path -LiteralPath $backup)) {",
    "    Move-Item -LiteralPath $backup -Destination $target -Force -ErrorAction SilentlyContinue",
    "  }",
    "} else {",
    "  if (($env:NX_OLD_EXE -ne $env:NX_NEW_EXE) -and (Test-Path -LiteralPath $newExe)) {",
    "    $oldExe = Join-Path $target $env:NX_OLD_EXE",
    "    Remove-Item -LiteralPath $oldExe -Force -ErrorAction SilentlyContinue",
    "  }",
    "  if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Recurse -Force -ErrorAction SilentlyContinue }",
    "}",
    "Remove-Item Env:_MEIPASS,Env:_MEIPASS2 -ErrorAction SilentlyContinue",
    "$launchExe = if (Test-Path -LiteralPath $newExe) { $newExe } else { Join-Path $target $env:NX_OLD_EXE }",
    "if (Test-Path -LiteralPath $launchExe) {",
    "  Start-Process -FilePath $launchExe -WorkingDirectory $target",
    "}",
    "if ($env:NX_STAGE_ROOT -and (Test-Path -LiteralPath $env:NX_STAGE_ROOT)) {",
    "  Remove-Item -LiteralPath $env:NX_STAGE_ROOT -Recurse -Force -ErrorAction SilentlyContinue",
    "}",
])


def relaunch_windows_update(
    staged: StagedUpdate,
    current_exe: Path | None = None,
    pid: int | None = None,
    popen=subprocess.Popen,
) -> bool:
    """Spawn a detached background process on Windows to swap `staged` in after `pid` exits."""
    exe_path = (current_exe or Path(sys.executable)).resolve()
    target_dir = exe_path.parent
    env = _sanitize_relaunch_env(os.environ, target_dir)
    env['NX_PID'] = str(os.getpid() if pid is None else pid)
    env['NX_STAGED'] = str(staged.app_dir)
    env['NX_TARGET'] = str(target_dir)
    env['NX_OLD_EXE'] = exe_path.name
    env['NX_NEW_EXE'] = staged.exe_name
    env['NX_STAGE_ROOT'] = str(staged.staging_root)

    kwargs: dict = {
        'stdin': subprocess.DEVNULL,
        'stdout': subprocess.DEVNULL,
        'stderr': subprocess.DEVNULL,
        'close_fds': True,
        'env': env,
    }
    if os.name == 'nt':
        flags = getattr(subprocess, 'CREATE_NO_WINDOW', 0x08000000) | getattr(subprocess, 'DETACHED_PROCESS', 0x00000008)
        kwargs['creationflags'] = flags
    try:
        popen(
            ['powershell', '-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden', '-Command', WINDOWS_RELAUNCH_PS1],
            **kwargs,
        )
        return True
    except OSError:
        return False
