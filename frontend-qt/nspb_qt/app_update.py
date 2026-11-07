"""Self-update for the Windows Qt launcher: release check, zip verification, staging, and relaunch.

Mirrors the rules of `frontend/Sources/NXCore/AppUpdate.swift` so both desktop launchers
compare versions, match release assets, and verify SHA-256 digests identically.
"""
from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
import zipfile

#: Bump together with each release tag and `AppUpdateStore.appVersion` in Swift.
APP_VERSION = '1.3.0'

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


def _safe_extract_zip(zip_path: Path, dest_dir: Path) -> None:
    """Extract `zip_path` into `dest_dir`, rejecting any path traversal entries."""
    dest_resolved = dest_dir.resolve()
    with zipfile.ZipFile(zip_path, 'r') as zf:
        for info in zf.infolist():
            norm = PurePosixPath(info.filename.replace('\\', '/'))
            if norm.is_absolute() or '..' in norm.parts:
                raise zipfile.BadZipFile(f'unsafe zip entry: {info.filename}')
            target = (dest_resolved / Path(*norm.parts)).resolve()
            if target != dest_resolved and dest_resolved not in target.parents:
                raise zipfile.BadZipFile(f'escaped zip entry: {info.filename}')
        zf.extractall(dest_resolved)


def _find_bundled_app_dir(unpacked_dir: Path) -> tuple[Path, str] | None:
    """Locate the unpacked PyInstaller app directory containing `NX2Apple.exe` and `_internal/`."""
    candidates = [unpacked_dir]
    try:
        candidates.extend( sorted(p for p in unpacked_dir.iterdir() if p.is_dir()) )
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
    shutil.rmtree(unpacked, ignore_errors=True)
    unpacked.mkdir(parents=True, exist_ok=True)
    try:
        _safe_extract_zip(zip_path, unpacked)
    except (zipfile.BadZipFile, OSError) as exc:
        zip_path.unlink(missing_ok=True)
        shutil.rmtree(unpacked, ignore_errors=True)
        raise StageError('app.unpackFail') from exc
    zip_path.unlink(missing_ok=True)

    found = _find_bundled_app_dir(unpacked)
    if found is None:
        shutil.rmtree(unpacked, ignore_errors=True)
        raise StageError('app.notOurApp')
    app_dir, exe_name = found
    return StagedUpdate(release=release, app_dir=app_dir, exe_name=exe_name, staging_root=staging_root)


#: Pure-ASCII PowerShell script that waits for the running process to exit, copies the staged
#: update into place with robocopy (retrying locked files), removes a legacy exe name when
#: transitioning from `NS Port Builder.exe` to `NX2Apple.exe`, and relaunches the new executable.
WINDOWS_RELAUNCH_PS1 = (
    "$pidToWait = [int]$env:NX_PID; "
    "for ($i = 0; $i -lt 150; $i++) { "
    "if (-not (Get-Process -Id $pidToWait -ErrorAction SilentlyContinue)) { break }; "
    "Start-Sleep -Milliseconds 200 "
    "}; "
    "Start-Sleep -Milliseconds 400; "
    "& robocopy $env:NX_STAGED $env:NX_TARGET /E /IS /IT /IM /NFL /NDL /NJH /NJS /R:10 /W:1 | Out-Null; "
    "$newExe = Join-Path $env:NX_TARGET $env:NX_NEW_EXE; "
    "if (($env:NX_OLD_EXE -ne $env:NX_NEW_EXE) -and (Test-Path -LiteralPath $newExe)) { "
    "$oldExe = Join-Path $env:NX_TARGET $env:NX_OLD_EXE; "
    "Remove-Item -LiteralPath $oldExe -Force -ErrorAction SilentlyContinue "
    "}; "
    "Remove-Item Env:_MEIPASS,Env:_MEIPASS2,Env:PYTHONHOME,Env:PYTHONPATH,Env:QT_PLUGIN_PATH,Env:QML2_IMPORT_PATH "
    "-ErrorAction SilentlyContinue; "
    "$launchExe = if (Test-Path -LiteralPath $newExe) { $newExe } else { Join-Path $env:NX_TARGET $env:NX_OLD_EXE }; "
    "if (Test-Path -LiteralPath $launchExe) { "
    "Start-Process -FilePath $launchExe -WorkingDirectory $env:NX_TARGET "
    "}; "
    "if ($env:NX_STAGE_ROOT -and (Test-Path -LiteralPath $env:NX_STAGE_ROOT)) { "
    "Remove-Item -LiteralPath $env:NX_STAGE_ROOT -Recurse -Force -ErrorAction SilentlyContinue "
    "}"
)


def relaunch_windows_update(
    staged: StagedUpdate,
    current_exe: Path | None = None,
    pid: int | None = None,
    popen=subprocess.Popen,
) -> bool:
    """Spawn a detached background process on Windows to swap `staged` in after `pid` exits."""
    exe_path = (current_exe or Path(sys.executable)).resolve()
    target_dir = exe_path.parent
    env = os.environ.copy()
    for k in ('_MEIPASS', '_MEIPASS2', 'PYTHONHOME', 'PYTHONPATH', 'QT_PLUGIN_PATH', 'QML2_IMPORT_PATH'):
        env.pop(k, None)
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
