"""Windows Defender exclusion helper for NX2Apple / NS Port Builder.

Real-time scanning (`WdFilter.sys` / `MsMpEng.exe`) intercepts every short-lived shader
compiler subprocess (`dmsh_xlate.exe`, `spirv-cross.exe`, `metal.exe`, `air-lld.exe`,
`metallib.exe`) and every multi-gigabyte SQLite / RomFS image write (`sh/cache/cas-*.db`,
`b-<chain>.img.part`) during the 99% shader packaging step, throttling disk I/O to a few
MB/s and stalling at 99% for minutes.

This module collects the exact build directories and compiler processes and submits them
in a single elevated PowerShell call (`Add-MpPreference`) after the user confirms the
native Windows UAC prompt.
"""
from __future__ import annotations

import base64
import ctypes
import html
import json
import locale
import ntpath
import os
import re
import subprocess
import sys
import tempfile
import time
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable

from . import toolchain as tc

#: Compiler and build tool executables spawned thousands of times during a build.
#: Excluding these processes lets Defender skip scanning temporary `.spv`, `.air`,
#: `.metallib`, and `.o` files they create under `%TEMP%` without excluding `%TEMP%` itself.
COMPILER_PROCESS_NAMES: tuple[str, ...] = (
    'dmsh_xlate.exe',
    'spirv-cross.exe',
    'glslangValidator.exe',
    'metal.exe',
    'metal-nt.exe',
    'air-lld.exe',
    'metallib.exe',
    'clang.exe',
    'clang++.exe',
    'ld64.lld.exe',
    'ld.lld.exe',
    'llvm-ar.exe',
    'llvm-objcopy.exe',
    'zstd.exe',
)

#: Windows error codes and process constants.
ERROR_CANCELLED = 1223
ERROR_ACCESS_DENIED = 5
STILL_ACTIVE = 259
PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
SEE_MASK_NOCLOSEPROCESS = 0x00000040
SW_HIDE = 0
WAIT_TIMEOUT = 0x00000102

#: Safety quotas and WMI batching limits to prevent state bloat, WMI buffer overflow, or UI hangs.
MAX_RECORDED_PATHS = 256
MAX_RECORDED_PROCESSES = 64
MAX_STATE_FILE_BYTES = 256 * 1024
WMI_BATCH_SIZE = 20
POWERSHELL_TIMEOUT_SEC = 120


@dataclass
class DefenderResult:
    ok: bool
    cancelled: bool = False
    added_paths: list[str] = field(default_factory=list)
    added_processes: list[str] = field(default_factory=list)
    remaining_paths: list[str] = field(default_factory=list)
    remaining_processes: list[str] = field(default_factory=list)
    error: str = ''
    error_code: str = ''


def app_data_root() -> Path:
    """`%LOCALAPPDATA%\\NS Port Builder` — holds `tools/`, `git/`, `logs/`, and `shell/`."""
    return tc.tools_dir().parent


def state_file_path() -> Path:
    """Where confirmed Defender exclusions are recorded locally."""
    return app_data_root() / 'defender_exclusions.json'


def _is_win_abs(s: str) -> bool:
    """True when `s` is a Windows drive-letter path (`C:\\...`, `D:/...`) or UNC path (`\\\\server\\share`)."""
    if len(s) >= 2 and s[0].isalpha() and s[1] == ':':
        return True
    return s.startswith('\\\\')


def _norm_win_path(p: str | Path) -> str:
    """Normalize a path for stable comparison while preserving readable casing across OSes."""
    s = os.fspath(p).strip()
    if not s:
        return ''
    if _is_win_abs(s):
        if len(s) == 2 and s[1] == ':':
            s += '\\'
        return ntpath.normpath(s)
    return os.path.normpath(os.path.abspath(s))


def _norm_key(p: str | Path) -> str:
    """Case-insensitive normalized key for Windows path deduplication and prefix checks."""
    norm = _norm_win_path(p)
    return norm.replace('/', '\\').rstrip('\\').lower() if norm else ''


def is_safe_exclusion_dir(path: str | Path) -> bool:
    """Refuse drive roots, system directories, and broad user profile folders (`Downloads`, `Desktop`).

    Excluding `C:\\`, `C:\\Users\\Alice`, or `C:\\Users\\Alice\\Downloads` would weaken
    protection for unrelated files downloaded from a browser. Specific build folders
    such as `C:\\Users\\Alice\\Downloads\\01007ef00011e000_build` or a dedicated
    `D:\\SwitchGames` folder are allowed.
    """
    norm = _norm_win_path(path)
    if not norm:
        return False
    clean = norm.replace('/', '\\').rstrip('\\')
    if not clean:
        return False
    if _is_win_abs(norm):
        _drive, tail = ntpath.splitdrive(clean)
    else:
        _drive, tail = os.path.splitdrive(clean)
    if not tail or tail in ('\\', '/'):
        return False
    parts = [seg.lower() for seg in tail.strip('\\/').split('\\') if seg]
    if not parts:
        return False

    # Reject Windows / POSIX system or program directories and generic Users profile folders
    if parts[0] in (
        'windows',
        'program files',
        'program files (x86)',
        'programdata',
        '$recycle.bin',
        'system volume information',
        'usr',
        'bin',
        'sbin',
        'etc',
        'lib',
        'System',
        'Library',
    ):
        return False
    if parts == ['users'] or parts == ['users', 'public']:
        return False
    if len(parts) == 2 and parts[0] == 'users':
        return False
    if len(parts) == 3 and parts[0] == 'users' and parts[2] in ('desktop', 'downloads', 'documents', 'appdata'):
        return False
    if len(parts) == 4 and parts[0] == 'users' and parts[2] == 'appdata' and parts[3] in ('local', 'roaming', 'locallow'):
        return False
    if len(parts) == 5 and parts[0] == 'users' and parts[2] == 'appdata' and parts[3] == 'local' and parts[4] == 'temp':
        return False

    low_clean = clean.lower()
    home = _norm_win_path(Path.home()).replace('/', '\\').rstrip('\\').lower()
    unsafe_exact = {
        home,
        f'{home}\\desktop',
        f'{home}\\downloads',
        f'{home}\\documents',
        f'{home}\\appdata',
        f'{home}\\appdata\\local',
        f'{home}\\appdata\\roaming',
        f'{home}\\appdata\\locallow',
        f'{home}\\appdata\\local\\temp',
    }
    for env_key in ('SYSTEMROOT', 'WINDIR', 'USERPROFILE', 'PUBLIC', 'TEMP', 'TMP', 'APPDATA', 'LOCALAPPDATA'):
        val = os.environ.get(env_key, '').strip()
        if val:
            unsafe_exact.add(_norm_win_path(val).replace('/', '\\').rstrip('\\').lower())
    if low_clean in unsafe_exact:
        return False
    return True


def is_safe_exclusion_process(proc: str | Path) -> bool:
    """Refuse bare process names (e.g. `clang.exe`) and executables in broad/system folders.

    Excluding a bare executable name in Microsoft Defender (`Add-MpPreference -ExclusionProcess
    "clang.exe"`) tells `WdFilter.sys` to trust ANY binary named `clang.exe` anywhere on the
    machine. Requiring an explicit, full path inside a safe directory (`is_safe_exclusion_dir`)
    scopes the process exclusion strictly to the toolchain binaries managed by this app.
    """
    s = os.fspath(proc).strip() if proc else ''
    if not s:
        return False
    if '\\' not in s and '/' not in s:
        return False
    norm = _norm_win_path(s)
    if not norm or not norm.lower().endswith('.exe'):
        return False
    if not (_is_win_abs(norm) or os.path.isabs(norm)):
        return False
    parent = ntpath.dirname(norm) if _is_win_abs(norm) else os.path.dirname(norm)
    return is_safe_exclusion_dir(parent)


def is_path_covered(target: str | Path, excluded_paths: Iterable[str | Path]) -> bool:
    """True when `target` itself or one of its parent directories is in `excluded_paths`.

    Microsoft Defender folder exclusions apply recursively to all subfolders, so an
    exclusion on `D:\\SwitchGames` already covers `D:\\SwitchGames\\01007ef00011e000_build`.
    """
    target_key = _norm_key(target)
    if not target_key:
        return True
    for raw in excluded_paths:
        ex_key = _norm_key(raw)
        if not ex_key:
            continue
        if target_key == ex_key or target_key.startswith(ex_key + '\\'):
            return True
    return False


_STATE_CACHE: tuple[tuple[str, int, float], tuple[list[str], list[str]]] | None = None


def load_recorded_state() -> tuple[list[str], list[str]]:
    """Return `(paths, processes)` previously confirmed and saved in `defender_exclusions.json`."""
    global _STATE_CACHE
    p = state_file_path()
    try:
        st = p.stat()
        sig = (str(p), st.st_size, st.st_mtime)
    except OSError:
        sig = (str(p), -1, -1.0)
        if _STATE_CACHE is not None and _STATE_CACHE[0] == sig:
            return list(_STATE_CACHE[1][0]), list(_STATE_CACHE[1][1])
        _STATE_CACHE = (sig, ([], []))
        return [], []

    if _STATE_CACHE is not None and _STATE_CACHE[0] == sig:
        return list(_STATE_CACHE[1][0]), list(_STATE_CACHE[1][1])

    if st.st_size > MAX_STATE_FILE_BYTES:
        return [], []
    try:
        data = json.loads(p.read_text(encoding='utf-8'))
    except (OSError, ValueError):
        return [], []
    if not isinstance(data, dict):
        return [], []
    paths = [str(x) for x in data.get('paths', ()) if isinstance(x, str) and x.strip()]
    procs = [str(x) for x in data.get('processes', ()) if isinstance(x, str) and x.strip()]
    _STATE_CACHE = (sig, (paths, procs))
    return list(paths), list(procs)


def _write_state_lists(paths: list[str], procs: list[str]) -> None:
    global _STATE_CACHE
    st_file = state_file_path()
    try:
        st_file.parent.mkdir(parents=True, exist_ok=True)
        tmp = st_file.with_suffix(f'.tmp-{os.getpid()}')
        tmp.write_text(
            json.dumps({'paths': paths, 'processes': procs}, indent=2, ensure_ascii=False),
            encoding='utf-8',
        )
        os.replace(tmp, st_file)
        st = st_file.stat()
        _STATE_CACHE = ((str(st_file), st.st_size, st.st_mtime), (list(paths), list(procs)))
    except OSError:
        _STATE_CACHE = None


def save_recorded_state(paths: Iterable[str], processes: Iterable[str]) -> None:
    """Silently merge and persist all confirmed exclusions to `defender_exclusions.json`."""
    old_paths, old_procs = load_recorded_state()
    merged_paths: list[str] = []
    seen_p: set[str] = set()
    for item in [*old_paths, *paths]:
        norm = _norm_win_path(item)
        k = _norm_key(norm)
        if norm and k and k not in seen_p:
            seen_p.add(k)
            merged_paths.append(norm)
    if len(merged_paths) > MAX_RECORDED_PATHS:
        merged_paths = merged_paths[-MAX_RECORDED_PATHS:]

    merged_procs: list[str] = []
    seen_proc: set[str] = set()
    for proc in [*old_procs, *processes]:
        s = str(proc).strip()
        k = s.replace('/', '\\').lower()
        if s and k not in seen_proc:
            seen_proc.add(k)
            merged_procs.append(s)
    if len(merged_procs) > MAX_RECORDED_PROCESSES:
        merged_procs = merged_procs[-MAX_RECORDED_PROCESSES:]

    _write_state_lists(merged_paths, merged_procs)


def replace_recorded_state(paths: Iterable[str], processes: Iterable[str]) -> None:
    """Overwrite `defender_exclusions.json` with any remaining items after a partial removal."""
    clean_p = [_norm_win_path(x) for x in paths if x and str(x).strip()]
    clean_pr = [str(x).strip() for x in processes if x and str(x).strip()]
    if not clean_p and not clean_pr:
        clear_recorded_state()
        return
    _write_state_lists(clean_p[:MAX_RECORDED_PATHS], clean_pr[:MAX_RECORDED_PROCESSES])


def clear_recorded_state() -> None:
    """Delete `defender_exclusions.json` after the user removes the exclusions."""
    global _STATE_CACHE
    st_file = state_file_path()
    try:
        if st_file.exists():
            st_file.unlink()
    except OSError:
        pass
    _STATE_CACHE = ((str(st_file), -1, -1.0), ([], []))


def resolve_compiler_processes(*, repo_dir: str = '') -> list[str]:
    """Return full executable paths for the app-managed toolchain and compiler binaries.

    Never returns bare process names: every entry is an explicit path under `%LOCALAPPDATA%\\NS
    Port Builder`, the user-selected Metal toolchain folder, or the checkout/engine directory.
    """
    t_dir = tc.tools_dir()
    app_root = app_data_root()

    def _join(base: str | Path, *parts: str) -> str:
        s = _norm_win_path(base)
        sep = '\\' if _is_win_abs(s) else os.sep
        for p in parts:
            s = s.rstrip('\\/') + sep + p.strip('\\/')
        return s

    def _ensure_bin(folder: str) -> str:
        clean = folder.replace('/', '\\').rstrip('\\')
        if clean.lower().endswith('\\bin'):
            return _norm_win_path(folder)
        return _join(folder, 'bin')

    py_cfg = tc.setting('python_dir')
    if py_cfg and is_safe_exclusion_dir(py_cfg):
        p_cfg = Path(py_cfg)
        py_dir = _norm_win_path(p_cfg.parent if p_cfg.name.lower() == 'python.exe' else p_cfg)
    else:
        py_dir = _join(t_dir, f'python-{tc.PYTHON_VERSION}')

    dn_cfg = tc.setting('dotnet_dir')
    dn_dir = (
        _norm_win_path(dn_cfg)
        if (dn_cfg and is_safe_exclusion_dir(dn_cfg))
        else _join(t_dir, f'dotnet-{tc.DOTNET_VERSION}')
    )

    llvm_cfg = tc.setting('llvm_dir') or os.environ.get(tc.ENV_LLVM)
    if llvm_cfg and is_safe_exclusion_dir(llvm_cfg):
        llvm_bin = _ensure_bin(llvm_cfg)
    else:
        llvm_bin = _join(t_dir, f'llvm-mingw-{tc.LLVM_MINGW_VERSION}', 'bin')

    metal_cfg = tc.setting('metal_dir') or os.environ.get(tc.ENV_METAL)
    metal_root = (
        _norm_win_path(metal_cfg)
        if (metal_cfg and is_safe_exclusion_dir(metal_cfg))
        else _join(t_dir, 'metal-developer-tools')
    )
    if (Path(metal_root) / 'ios' / 'bin' / 'metal.exe').is_file():
        metal_bin = _join(metal_root, 'ios', 'bin')
    else:
        metal_bin = _ensure_bin(metal_root)

    zstd_cfg = tc.setting('zstd_dir')
    if zstd_cfg and is_safe_exclusion_dir(zstd_cfg):
        zstd_bin = (
            _norm_win_path(zstd_cfg)
            if str(zstd_cfg).lower().endswith('.exe')
            else _join(zstd_cfg, 'zstd.exe')
        )
    else:
        zstd_bin = _join(t_dir, f'zstd-{tc.ZSTD_VERSION}', 'zstd.exe')

    raw_candidates: list[str | Path] = [
        _join(py_dir, 'python.exe'),
        _join(app_root, 'venv', 'Scripts', 'python.exe'),
        _join(dn_dir, 'dotnet.exe'),
        _join(llvm_bin, 'clang.exe'),
        _join(llvm_bin, 'clang++.exe'),
        _join(llvm_bin, 'ld64.lld.exe'),
        _join(llvm_bin, 'ld.lld.exe'),
        _join(llvm_bin, 'llvm-ar.exe'),
        _join(llvm_bin, 'llvm-objcopy.exe'),
        zstd_bin,
        _join(metal_bin, 'metal.exe'),
        _join(metal_bin, 'metal-nt.exe'),
        _join(metal_bin, 'air-lld.exe'),
        _join(metal_bin, 'metallib.exe'),
    ]

    # Shader translator and optional SPIR-V helpers inside the engine or managed tools folder
    eng_candidates: list[Path] = []
    if repo_dir and str(repo_dir).strip():
        rp = Path(str(repo_dir).strip())
        eng_candidates.extend([
            rp / 'engine' / 'dm' / 'gfx' / 'tools' / 'dmsh_xlate_bin',
            rp / 'dm' / 'gfx' / 'tools' / 'dmsh_xlate_bin',
            rp / 'engine' / 'dm' / 'gfx' / 'tools' / 'spirv_cross_bin',
            rp / 'dm' / 'gfx' / 'tools' / 'spirv_cross_bin',
            rp / 'engine' / 'dm' / 'tools',
            rp / 'dm' / 'tools',
            rp / 'bin',
        ])
    for exe_name in ('dmsh_xlate.exe', 'spirv-cross.exe', 'glslangValidator.exe'):
        matched = next((d / exe_name for d in eng_candidates if (d / exe_name).is_file()), None)
        if matched is not None:
            raw_candidates.append(matched)
        else:
            raw_candidates.append(_join(t_dir, 'bin', exe_name))

    processes: list[str] = []
    seen_procs: set[str] = set()
    for cand in raw_candidates:
        norm = _norm_win_path(cand)
        if not norm or not is_safe_exclusion_process(norm):
            continue
        k = norm.replace('/', '\\').lower()
        if k not in seen_procs:
            seen_procs.add(k)
            processes.append(norm)
    return processes


def collect_exclusions(
    *,
    games_folder: str = '',
    work_dir: str = '',
    out_dir: str = '',
    base_dir: str = '',
    shell_cache_dir: str = '',
    repo_dir: str = '',
    app_dir: str = '',
) -> tuple[list[str], list[str]]:
    """Build the deduplicated `(folder_paths, compiler_processes)` list to exclude.

    - Always includes `%LOCALAPPDATA%\\NS Port Builder` (holds the app-managed Python,
      LLVM-MinGW, .NET, iPhoneOS SDK, and shell cache).
    - Includes the app installation / checkout directory, custom shell cache, library
      games folder, output folder, and active `<tid>_build` work folder when safe.
    - When `base_dir` is a broad directory like `Downloads` or `Desktop`, `is_safe_exclusion_dir`
      skips `base_dir` while still allowing the specific `<tid>_build` `work_dir` inside it.
    - Every entry in `compiler_processes` is a full path inside a safe folder (never a bare exe name).
    """
    candidates: list[str] = [str(app_data_root())]

    if app_dir:
        candidates.append(app_dir)
    elif getattr(sys, 'frozen', False):
        candidates.append(str(Path(sys.executable).resolve().parent))

    if repo_dir:
        candidates.append(repo_dir)
    if shell_cache_dir:
        candidates.append(shell_cache_dir)
    if games_folder:
        candidates.append(games_folder)
    if out_dir:
        candidates.append(out_dir)
    if base_dir:
        candidates.append(base_dir)
    if work_dir:
        candidates.append(work_dir)

    folders: list[str] = []
    seen_keys: set[str] = set()
    for raw in candidates:
        if not raw or not str(raw).strip():
            continue
        norm = _norm_win_path(raw)
        if not is_safe_exclusion_dir(norm):
            continue
        k = _norm_key(norm)
        if not k or k in seen_keys:
            continue
        if is_path_covered(norm, folders):
            continue
        # Remove any narrower child folders already in `folders` if `norm` is their parent
        folders = [existing for existing in folders if not is_path_covered(existing, [norm])]
        seen_keys = {_norm_key(x) for x in folders}
        seen_keys.add(k)
        folders.append(norm)

    processes = resolve_compiler_processes(repo_dir=repo_dir)
    return folders, processes


def exclusions_status(
    *,
    games_folder: str = '',
    work_dir: str = '',
    out_dir: str = '',
    base_dir: str = '',
    shell_cache_dir: str = '',
    repo_dir: str = '',
    app_dir: str = '',
) -> tuple[str, list[str], list[str]]:
    """Return `(status, target_folders, target_processes)` where `status` is:

    - `'ready'`: every target folder and compiler process is already covered
    - `'partial'`: some exclusions were added before, but a newly chosen folder (e.g. a new
      games folder or build work_dir) is not covered yet
    - `'needed'`: no exclusions have been recorded yet
    """
    folders, procs = collect_exclusions(
        games_folder=games_folder,
        work_dir=work_dir,
        out_dir=out_dir,
        base_dir=base_dir,
        shell_cache_dir=shell_cache_dir,
        repo_dir=repo_dir,
        app_dir=app_dir,
    )
    rec_paths, rec_procs = load_recorded_state()
    if not rec_paths and not rec_procs:
        return 'needed', folders, procs

    rec_proc_keys = {p.replace('/', '\\').lower() for p in rec_procs}
    all_procs_ok = all(p.replace('/', '\\').lower() in rec_proc_keys for p in procs)
    all_paths_ok = all(is_path_covered(f, rec_paths) for f in folders)
    if all_paths_ok and all_procs_ok:
        return 'ready', folders, procs
    return 'partial', folders, procs


_CLIXML_ERROR_RE = re.compile(r'<S\s+S=["\'][Ee]rror["\']>(.*?)</S>', re.DOTALL)
_CLIXML_HEX_ESCAPE_RE = re.compile(r'_x([0-9A-Fa-f]{4})_')
_CLIXML_OBJS_RE = re.compile(r'<Objs\b.*?(?:</Objs>|$)', re.DOTALL)


def _decode_console_bytes(data: bytes | str | None) -> str:
    """Decode PowerShell console bytes while tolerating localized ANSI/OEM codepages on Windows."""
    if data is None:
        return ''
    if isinstance(data, str):
        return data
    if not data:
        return ''
    candidates: list[str] = ['utf-8']
    pref = locale.getpreferredencoding(False)
    if pref:
        candidates.append(pref)
    if os.name == 'nt':
        candidates.append('mbcs')
    candidates.append('gbk')
    seen: set[str] = set()
    for enc in candidates:
        key = enc.lower()
        if key in seen:
            continue
        seen.add(key)
        try:
            return data.decode(enc)
        except (UnicodeDecodeError, LookupError):
            continue
    return data.decode('utf-8', errors='replace')


def _decode_clixml_escapes(text: str) -> str:
    unescaped = html.unescape(text)
    return _CLIXML_HEX_ESCAPE_RE.sub(
        lambda m: '' if int(m.group(1), 16) == 0 else chr(int(m.group(1), 16)),
        unescaped,
    )


def sanitize_powershell_output(raw: str) -> str:
    """Strip PowerShell `#< CLIXML` progress telemetry and extract real error lines if present."""
    if not raw:
        return ''
    if '#< CLIXML' not in raw and '<Objs' not in raw:
        return raw.strip()

    lines: list[str] = []
    seen: set[str] = set()

    plain = _CLIXML_OBJS_RE.sub('', raw).replace('#< CLIXML', '')
    for line in plain.replace('\r\n', '\n').replace('\r', '\n').splitlines():
        s = line.strip()
        if s and s not in seen:
            seen.add(s)
            lines.append(s)

    for m in _CLIXML_ERROR_RE.finditer(raw):
        err_text = _decode_clixml_escapes(m.group(1)).replace('\r\n', '\n').replace('\r', '\n')
        for line in err_text.splitlines():
            s = line.strip()
            if s and s not in seen:
                seen.add(s)
                lines.append(s)

    return '\n'.join(lines).strip()


def encode_powershell_command(script: str) -> str:
    """Encode a PowerShell script as UTF-16LE Base64 for `-EncodedCommand`."""
    return base64.b64encode(script.encode('utf-16-le')).decode('ascii')


def _build_inner_ps_preamble(payload_json_path: str) -> str:
    """Return shared PowerShell helpers so elevation and removal write results atomically."""
    escaped_payload = str(payload_json_path).replace("'", "''")
    return (
        "$ProgressPreference = 'SilentlyContinue'\n"
        "$ErrorActionPreference = 'Stop'\n"
        f"$payloadPath = '{escaped_payload}'\n"
        "$workDir = [System.IO.Path]::GetDirectoryName($payloadPath)\n"
        "$resultPath = [System.IO.Path]::Combine($workDir, 'result.json')\n"
        "$startedPath = [System.IO.Path]::Combine($workDir, 'started.json')\n"
        f"$batchSize = {WMI_BATCH_SIZE}\n"
        "function Write-AtomicJson([string]$targetPath, [hashtable]$obj) {\n"
        "    $json = $obj | ConvertTo-Json -Compress\n"
        "    $tmpPath = \"$targetPath.tmp-$PID\"\n"
        "    $enc = New-Object System.Text.UTF8Encoding($false)\n"
        "    [System.IO.File]::WriteAllText($tmpPath, $json, $enc)\n"
        "    try {\n"
        "        if (Test-Path -LiteralPath $payloadPath) {\n"
        "            $ownerSid = [System.IO.File]::GetAccessControl($payloadPath).GetOwner([System.Security.Principal.SecurityIdentifier])\n"
        "            if ($null -ne $ownerSid) {\n"
        "                $dacl = [System.IO.File]::GetAccessControl($tmpPath, [System.Security.AccessControl.AccessControlSections]::Access)\n"
        "                $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(\n"
        "                    $ownerSid,\n"
        "                    [System.Security.AccessControl.FileSystemRights]::FullControl,\n"
        "                    [System.Security.AccessControl.AccessControlType]::Allow\n"
        "                )\n"
        "                $dacl.AddAccessRule($rule)\n"
        "                [System.IO.File]::SetAccessControl($tmpPath, $dacl)\n"
        "            }\n"
        "        }\n"
        "    } catch {}\n"
        "    Move-Item -LiteralPath $tmpPath -Destination $targetPath -Force\n"
        "}\n"
        "function Ensure-DefenderModule() {\n"
        "    if ($null -eq (Get-Command -Name 'Add-MpPreference' -ErrorAction SilentlyContinue)) {\n"
        "        $sysRoot = if ($env:SystemRoot) { $env:SystemRoot } else { 'C:\\Windows' }\n"
        "        $modDir = [System.IO.Path]::Combine($sysRoot, 'System32\\WindowsPowerShell\\v1.0\\Modules\\Defender')\n"
        "        if (Test-Path -LiteralPath $modDir) {\n"
        "            try { Import-Module -Name $modDir -ErrorAction SilentlyContinue | Out-Null } catch {}\n"
        "        } else {\n"
        "            try { Import-Module -Name 'Defender' -ErrorAction SilentlyContinue | Out-Null } catch {}\n"
        "        }\n"
        "    }\n"
        "}\n"
        "function Get-DefenderFailureCode([string]$msg) {\n"
        "    $svc = try { Get-Service -Name 'WinDefend' -ErrorAction SilentlyContinue } catch { $null }\n"
        "    if ($null -ne $svc -and $svc.Status.ToString() -ne 'Running') {\n"
        "        return 'service_inactive'\n"
        "    }\n"
        "    $st = try { Get-MpComputerStatus -ErrorAction SilentlyContinue } catch { $null }\n"
        "    if ($null -eq $svc -and $null -eq $st) {\n"
        "        return 'service_inactive'\n"
        "    }\n"
        "    if ($null -ne $st -and $st.AMServiceEnabled -eq $false) {\n"
        "        return 'service_inactive'\n"
        "    }\n"
        "    if ($msg -match '0x800106ba|0x80070422|0x80070424|0x80041002|0x8004100e|0x80041010|MSFT_MpPreference|WinDefend|Add-MpPreference|Remove-MpPreference|Get-MpPreference|CommandNotFoundException') {\n"
        "        return 'service_inactive'\n"
        "    }\n"
        "    if (($null -ne $st -and $st.IsTamperProtected -eq $true -and $msg -match '0x80070005|Access is denied|denied|拒绝访问|tamper|policy') -or ($msg -match 'Tamper Protection|篡改防护')) {\n"
        "        return 'tamper_blocked'\n"
        "    }\n"
        "    return ''\n"
        "}\n"
    )


def build_inner_elevation_script(payload_json_path: str) -> str:
    """Build the elevated PowerShell script that reads `payload_json_path` and calls `Add-MpPreference`.

    All folder paths and process names are read from the ASCII-escaped JSON file on disk rather than
    interpolated into the command line, preventing any quoting, codepage, or command-length overflow.
    Submits in bounded batches (`WMI_BATCH_SIZE = 20`) to avoid WMI marshaling buffer limits.
    """
    return _build_inner_ps_preamble(payload_json_path) + (
        "try {\n"
        "    Write-AtomicJson $startedPath @{ pid = $PID }\n"
        "    $rawPayload = [System.IO.File]::ReadAllText($payloadPath, [System.Text.Encoding]::UTF8)\n"
        "    $cfg = $rawPayload | ConvertFrom-Json\n"
        "    if ($null -ne $cfg -and $cfg.result_path) {\n"
        "        $resultPath = [string]$cfg.result_path\n"
        "    }\n"
        "    $paths = @($cfg.paths | Where-Object { $_ -ne $null -and $_ -ne '' })\n"
        "    $procs = @($cfg.processes | Where-Object { $_ -ne $null -and $_ -ne '' })\n"
        "    Ensure-DefenderModule\n"
        "    if ($null -eq (Get-Command -Name 'Add-MpPreference' -ErrorAction SilentlyContinue)) {\n"
        "        Write-AtomicJson $resultPath @{\n"
        "            ok = $false\n"
        "            error = 'Microsoft Defender PowerShell module is not installed on this Windows edition'\n"
        "            error_code = 'service_inactive'\n"
        "        }\n"
        "        exit 1\n"
        "    }\n"
        "    for ($i = 0; $i -lt $paths.Count; $i += $batchSize) {\n"
        "        $end = [Math]::Min($i + $batchSize - 1, $paths.Count - 1)\n"
        "        $batch = [string[]]@($paths[$i..$end])\n"
        "        Add-MpPreference -ExclusionPath $batch -ErrorAction Stop\n"
        "    }\n"
        "    for ($i = 0; $i -lt $procs.Count; $i += $batchSize) {\n"
        "        $end = [Math]::Min($i + $batchSize - 1, $procs.Count - 1)\n"
        "        $batch = [string[]]@($procs[$i..$end])\n"
        "        Add-MpPreference -ExclusionProcess $batch -ErrorAction Stop\n"
        "    }\n"
        "    $mpAfter = try { Get-MpPreference -ErrorAction SilentlyContinue } catch { $null }\n"
        "    if ($paths.Count -gt 0 -and $null -ne $mpAfter -and $mpAfter.HideExclusionsFromLocalAdmins -ne $true) {\n"
        "        $afterP = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)\n"
        "        if ($null -ne $mpAfter.ExclusionPath) {\n"
        "            foreach ($x in $mpAfter.ExclusionPath) {\n"
        "                if ($x) { [void]$afterP.Add(([string]$x).Replace('/', '\\').TrimEnd('\\')) }\n"
        "            }\n"
        "        }\n"
        "        $missingPath = $false\n"
        "        foreach ($p in $paths) {\n"
        "            $norm = ([string]$p).Replace('/', '\\').TrimEnd('\\')\n"
        "            if (-not $norm) { continue }\n"
        "            $covered = $afterP.Contains($norm)\n"
        "            if (-not $covered) {\n"
        "                foreach ($ex in $afterP) {\n"
        "                    if ($ex -and $norm.StartsWith($ex + '\\', [System.StringComparison]::OrdinalIgnoreCase)) {\n"
        "                        $covered = $true\n"
        "                        break\n"
        "                    }\n"
        "                }\n"
        "            }\n"
        "            if (-not $covered) {\n"
        "                $missingPath = $true\n"
        "                break\n"
        "            }\n"
        "        }\n"
        "        if ($missingPath) {\n"
        "            $st = try { Get-MpComputerStatus -ErrorAction SilentlyContinue } catch { $null }\n"
        "            $code = if ($null -ne $st -and $st.AMServiceEnabled -eq $false) { 'service_inactive' } else { 'tamper_blocked' }\n"
        "            $errMsg = if ($code -eq 'service_inactive') {\n"
        "                'Microsoft Defender Antivirus service is not active'\n"
        "            } else {\n"
        "                'Windows Security Tamper Protection or policy blocked adding exclusions'\n"
        "            }\n"
        "            Write-AtomicJson $resultPath @{ ok = $false; error = $errMsg; error_code = $code }\n"
        "            exit 1\n"
        "        }\n"
        "    }\n"
        "    Write-AtomicJson $resultPath @{ ok = $true; error = ''; error_code = '' }\n"
        "    exit 0\n"
        "} catch {\n"
        "    $msg = if ($_.Exception) { $_.Exception.Message } else { $_.ToString() }\n"
        "    $errCode = Get-DefenderFailureCode $msg\n"
        "    Write-AtomicJson $resultPath @{ ok = $false; error = $msg; error_code = $errCode }\n"
        "    exit 1\n"
        "}\n"
    )


def build_inner_removal_script(payload_json_path: str) -> str:
    """Build the elevated PowerShell script that reads `payload_json_path` and calls `Remove-MpPreference`.

    - Intersects against `Get-MpPreference` when available so items already deleted manually by the
      user do not trigger spurious WMI calls.
    - Removes in bounded chunks (`WMI_BATCH_SIZE = 20`) to prevent WMI quota/buffer overflow and
      falls back to per-item removal within a failed chunk so one missing/blocked entry never aborts
      the rest of the cleanup.
    """
    return _build_inner_ps_preamble(payload_json_path) + (
        "try {\n"
        "    Write-AtomicJson $startedPath @{ pid = $PID }\n"
        "    $rawPayload = [System.IO.File]::ReadAllText($payloadPath, [System.Text.Encoding]::UTF8)\n"
        "    $cfg = $rawPayload | ConvertFrom-Json\n"
        "    if ($null -ne $cfg -and $cfg.result_path) {\n"
        "        $resultPath = [string]$cfg.result_path\n"
        "    }\n"
        "    $paths = @($cfg.paths | Where-Object { $_ -ne $null -and $_ -ne '' })\n"
        "    $procs = @($cfg.processes | Where-Object { $_ -ne $null -and $_ -ne '' })\n"
        "    Ensure-DefenderModule\n"
        "    if ($null -eq (Get-Command -Name 'Remove-MpPreference' -ErrorAction SilentlyContinue)) {\n"
        "        $svc = try { Get-Service -Name 'WinDefend' -ErrorAction SilentlyContinue } catch { $null }\n"
        "        if ($null -eq $svc -or $svc.Status.ToString() -ne 'Running') {\n"
        "            Write-AtomicJson $resultPath @{ ok = $true; error = ''; error_code = '' }\n"
        "            exit 0\n"
        "        }\n"
        "    }\n"
        "    $mp = try { Get-MpPreference -ErrorAction SilentlyContinue } catch { $null }\n"
        "    if ($null -ne $mp -and $null -ne $mp.ExclusionPath) {\n"
        "        $curP = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)\n"
        "        foreach ($x in $mp.ExclusionPath) { if ($x) { [void]$curP.Add(([string]$x).Replace('/', '\\').TrimEnd('\\')) } }\n"
        "        $paths = @($paths | Where-Object { $curP.Contains(([string]$_).Replace('/', '\\').TrimEnd('\\')) })\n"
        "    }\n"
        "    if ($null -ne $mp -and $null -ne $mp.ExclusionProcess) {\n"
        "        $curPr = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)\n"
        "        foreach ($x in $mp.ExclusionProcess) { if ($x) { [void]$curPr.Add($x) } }\n"
        "        $procs = @($procs | Where-Object { $curPr.Contains($_) })\n"
        "    }\n"
        "    $lastErr = ''\n"
        "    for ($i = 0; $i -lt $paths.Count; $i += $batchSize) {\n"
        "        $end = [Math]::Min($i + $batchSize - 1, $paths.Count - 1)\n"
        "        $batch = [string[]]@($paths[$i..$end])\n"
        "        try {\n"
        "            Remove-MpPreference -ExclusionPath $batch -ErrorAction Stop\n"
        "        } catch {\n"
        "            foreach ($item in $batch) {\n"
        "                try { Remove-MpPreference -ExclusionPath @([string]$item) -ErrorAction Stop }\n"
        "                catch { $lastErr = if ($_.Exception) { $_.Exception.Message } else { $_.ToString() } }\n"
        "            }\n"
        "        }\n"
        "    }\n"
        "    for ($i = 0; $i -lt $procs.Count; $i += $batchSize) {\n"
        "        $end = [Math]::Min($i + $batchSize - 1, $procs.Count - 1)\n"
        "        $batch = [string[]]@($procs[$i..$end])\n"
        "        try {\n"
        "            Remove-MpPreference -ExclusionProcess $batch -ErrorAction Stop\n"
        "        } catch {\n"
        "            foreach ($item in $batch) {\n"
        "                try { Remove-MpPreference -ExclusionProcess @([string]$item) -ErrorAction Stop }\n"
        "                catch { $lastErr = if ($_.Exception) { $_.Exception.Message } else { $_.ToString() } }\n"
        "            }\n"
        "        }\n"
        "    }\n"
        "    $remPaths = @()\n"
        "    $remProcs = @()\n"
        "    $mpAfter = try { Get-MpPreference -ErrorAction SilentlyContinue } catch { $null }\n"
        "    if ($null -ne $mpAfter) {\n"
        "        if ($null -ne $mpAfter.ExclusionPath) {\n"
        "            $afterP = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)\n"
        "            foreach ($x in $mpAfter.ExclusionPath) { if ($x) { [void]$afterP.Add(([string]$x).Replace('/', '\\').TrimEnd('\\')) } }\n"
        "            $remPaths = @($cfg.paths | Where-Object { $_ -and $afterP.Contains(([string]$_).Replace('/', '\\').TrimEnd('\\')) })\n"
        "        }\n"
        "        if ($null -ne $mpAfter.ExclusionProcess) {\n"
        "            $afterPr = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)\n"
        "            foreach ($x in $mpAfter.ExclusionProcess) { if ($x) { [void]$afterPr.Add($x) } }\n"
        "            $remProcs = @($cfg.processes | Where-Object { $_ -and $afterPr.Contains($_) })\n"
        "        }\n"
        "    }\n"
        "    $okFlag = ($remPaths.Count -eq 0 -and $remProcs.Count -eq 0 -and $lastErr -eq '')\n"
        "    $errCode = if ($okFlag) { '' } else { Get-DefenderFailureCode $lastErr }\n"
        "    Write-AtomicJson $resultPath @{ ok = $okFlag; error = $lastErr; error_code = $errCode; remaining_paths = @($remPaths); remaining_processes = @($remProcs) }\n"
        "    if ($okFlag) { exit 0 } else { exit 1 }\n"
        "} catch {\n"
        "    $msg = if ($_.Exception) { $_.Exception.Message } else { $_.ToString() }\n"
        "    $errCode = Get-DefenderFailureCode $msg\n"
        "    Write-AtomicJson $resultPath @{ ok = $false; error = $msg; error_code = $errCode; remaining_paths = @(); remaining_processes = @() }\n"
        "    exit 1\n"
        "}\n"
    )


def build_outer_launcher_script(script_or_encoded: str) -> str:
    """Build the non-elevated PowerShell wrapper that triggers the Windows UAC `RunAs` prompt."""
    target = str(script_or_encoded).strip()
    is_ps1_file = target.lower().endswith('.ps1')
    if is_ps1_file:
        safe_ps1 = target.replace("'", "''")
        arg_expr = (
            "$argList = @('-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden', "
            f"'-ExecutionPolicy', 'Bypass', '-File', '{safe_ps1}')\n"
        )
        wait_block = (
            "    $workDir = [System.IO.Path]::GetDirectoryName('" + safe_ps1 + "')\n"
            "    $resultFile = [System.IO.Path]::Combine($workDir, 'result.json')\n"
            "    $startedFile = [System.IO.Path]::Combine($workDir, 'started.json')\n"
            "    $deadline = [DateTime]::UtcNow.AddSeconds(15)\n"
            "    while (-not (Test-Path -LiteralPath $resultFile) -and [DateTime]::UtcNow -lt $deadline) {\n"
            "        if (Test-Path -LiteralPath $startedFile) {\n"
            "            $st = try { [System.IO.File]::ReadAllText($startedFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json } catch { $null }\n"
            "            if ($null -ne $st -and $st.pid) {\n"
            "                $alive = Get-Process -Id ([int]$st.pid) -ErrorAction SilentlyContinue\n"
            "                if ($null -eq $alive) { break }\n"
            "                $deadline = [DateTime]::UtcNow.AddSeconds(15)\n"
            "            }\n"
            "        }\n"
            "        Start-Sleep -Milliseconds 50\n"
            "    }\n"
            "    if (Test-Path -LiteralPath $resultFile) {\n"
            "        $resObj = try { [System.IO.File]::ReadAllText($resultFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json } catch { $null }\n"
            "        if ($null -ne $resObj -and $resObj.ok -eq $true) { exit 0 }\n"
            "        exit 1\n"
            "    }\n"
        )
    else:
        safe_b64 = target.replace("'", '')
        arg_expr = (
            "$argList = @('-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden', "
            f"'-ExecutionPolicy', 'Bypass', '-EncodedCommand', '{safe_b64}')\n"
        )
        wait_block = ''

    return (
        "$ProgressPreference = 'SilentlyContinue'\n"
        "$ErrorActionPreference = 'Stop'\n"
        "try {\n"
        "    $psExe = Join-Path $env:SystemRoot 'System32\\WindowsPowerShell\\v1.0\\powershell.exe'\n"
        "    if (-not (Test-Path -LiteralPath $psExe)) { $psExe = 'powershell.exe' }\n"
        f"    {arg_expr}"
        "    $p = Start-Process -FilePath $psExe -Verb RunAs -WindowStyle Hidden "
        "-Wait -PassThru -ArgumentList $argList\n"
        f"{wait_block}"
        "    if ($null -eq $p) { exit 1 }\n"
        "    exit $p.ExitCode\n"
        "} catch {\n"
        "    $errText = $_.ToString()\n"
        "    if (($_.Exception -and $_.Exception.NativeErrorCode -eq 1223) -or "
        "($_.Exception.InnerException -and $_.Exception.InnerException.NativeErrorCode -eq 1223) -or "
        "($errText -match '1223|canceled|cancelled|cancelado|annullat|取消|キャンセル|취소|abgebrochen|annul|avbruten')) {\n"
        f"        exit {ERROR_CANCELLED}\n"
        "    }\n"
        "    [Console]::Error.WriteLine($errText)\n"
        "    exit 2\n"
        "}\n"
    )


def _wait_for_elevated_result(
    result_file: Path,
    started_file: Path,
    *,
    initial_done_fn,
    pid_alive_fn,
    timeout_sec: float = POWERSHELL_TIMEOUT_SEC,
    early_start_grace_sec: float = 5.0,
    poll_interval_sec: float = 0.05,
) -> bool:
    """Wait for `result_file` even when the initial launcher handle returns early under Windows Terminal."""
    deadline = time.monotonic() + float(timeout_sec)
    initial_done_at: float | None = None
    inner_pid: int | None = None

    while True:
        if result_file.is_file():
            return True

        if inner_pid is None and started_file.is_file():
            st_obj, _ = _read_json_with_retry(started_file, attempts=2, delay_sec=0.02)
            if isinstance(st_obj, dict) and st_obj.get('pid'):
                try:
                    inner_pid = int(st_obj['pid'])
                except (ValueError, TypeError):
                    pass

        now = time.monotonic()
        if initial_done_fn():
            if initial_done_at is None:
                initial_done_at = now
            if inner_pid is not None:
                if not pid_alive_fn(inner_pid):
                    time.sleep(min(poll_interval_sec, 0.1))
                    return result_file.is_file()
            elif (now - initial_done_at) >= early_start_grace_sec:
                return result_file.is_file()

        if now >= deadline:
            raise subprocess.TimeoutExpired('powershell.exe', timeout_sec)

        time.sleep(min(poll_interval_sec, max(0.005, deadline - now)))


def _win32_is_pid_alive(pid: int) -> bool:
    """Best-effort Win32 check whether `pid` is still running."""
    if pid <= 0:
        return False
    from ctypes import wintypes

    kernel32 = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel32.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    kernel32.OpenProcess.restype = wintypes.HANDLE
    kernel32.GetExitCodeProcess.argtypes = [wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD)]
    kernel32.GetExitCodeProcess.restype = wintypes.BOOL
    kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
    kernel32.CloseHandle.restype = wintypes.BOOL

    handle = kernel32.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, pid)
    if not handle:
        return ctypes.get_last_error() == ERROR_ACCESS_DENIED
    try:
        code = wintypes.DWORD(0)
        if not kernel32.GetExitCodeProcess(handle, ctypes.byref(code)):
            return False
        return code.value == STILL_ACTIVE
    finally:
        kernel32.CloseHandle(handle)


def _launch_elevated_win32(
    script_file: Path,
    work_td: str,
    result_file: Path,
    started_file: Path,
    timeout_sec: float = POWERSHELL_TIMEOUT_SEC,
) -> tuple[int, str]:
    """Elevate `powershell.exe -File <script_file>` directly via Win32 `ShellExecuteExW`."""
    from ctypes import wintypes

    class SHELLEXECUTEINFOW(ctypes.Structure):
        _fields_ = [
            ('cbSize', wintypes.DWORD),
            ('fMask', wintypes.ULONG),
            ('hwnd', wintypes.HWND),
            ('lpVerb', wintypes.LPCWSTR),
            ('lpFile', wintypes.LPCWSTR),
            ('lpParameters', wintypes.LPCWSTR),
            ('lpDirectory', wintypes.LPCWSTR),
            ('nShow', ctypes.c_int),
            ('hInstApp', wintypes.HINSTANCE),
            ('lpIDList', wintypes.LPVOID),
            ('lpClass', wintypes.LPCWSTR),
            ('hkeyClass', wintypes.HKEY),
            ('dwHotKey', wintypes.DWORD),
            ('hIconOrMonitor', wintypes.HANDLE),
            ('hProcess', wintypes.HANDLE),
        ]

    sys_root = os.environ.get('SystemRoot') or os.environ.get('WINDIR') or r'C:\Windows'
    ps_candidate = Path(sys_root) / 'System32' / 'WindowsPowerShell' / 'v1.0' / 'powershell.exe'
    ps_exe = str(ps_candidate) if ps_candidate.is_file() else 'powershell.exe'
    params = (
        f'-NoProfile -NonInteractive -WindowStyle Hidden '
        f'-ExecutionPolicy Bypass -File "{script_file}"'
    )

    shell32 = ctypes.WinDLL('shell32', use_last_error=True)
    shell32.ShellExecuteExW.argtypes = [ctypes.POINTER(SHELLEXECUTEINFOW)]
    shell32.ShellExecuteExW.restype = wintypes.BOOL

    kernel32 = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel32.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
    kernel32.WaitForSingleObject.restype = wintypes.DWORD
    kernel32.GetExitCodeProcess.argtypes = [wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD)]
    kernel32.GetExitCodeProcess.restype = wintypes.BOOL
    kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
    kernel32.CloseHandle.restype = wintypes.BOOL

    parent_dir = str(Path(work_td).parent)

    sei = SHELLEXECUTEINFOW()
    sei.cbSize = ctypes.sizeof(SHELLEXECUTEINFOW)
    sei.fMask = SEE_MASK_NOCLOSEPROCESS
    sei.lpVerb = 'runas'
    sei.lpFile = ps_exe
    sei.lpParameters = params
    sei.lpDirectory = parent_dir if os.path.isdir(parent_dir) else None
    sei.nShow = SW_HIDE

    if not shell32.ShellExecuteExW(ctypes.byref(sei)):
        err = ctypes.get_last_error()
        if err == ERROR_CANCELLED:
            return ERROR_CANCELLED, ''
        return 1, f'ShellExecuteExW failed with Win32 error {err}'

    h_proc = sei.hProcess
    if not h_proc:
        _wait_for_elevated_result(
            result_file,
            started_file,
            initial_done_fn=lambda: True,
            pid_alive_fn=_win32_is_pid_alive,
            timeout_sec=timeout_sec,
        )
        return 0, ''

    try:
        _wait_for_elevated_result(
            result_file,
            started_file,
            initial_done_fn=lambda: kernel32.WaitForSingleObject(h_proc, 0) != WAIT_TIMEOUT,
            pid_alive_fn=_win32_is_pid_alive,
            timeout_sec=timeout_sec,
        )
        # Wait briefly after result.json appears so elevated powershell.exe releases script/dir handles cleanly
        kernel32.WaitForSingleObject(h_proc, 1000)
        code = wintypes.DWORD(0)
        if kernel32.GetExitCodeProcess(h_proc, ctypes.byref(code)):
            return int(code.value), ''
        return 0, ''
    finally:
        kernel32.CloseHandle(h_proc)


def _string_list_field(res_obj: object, key: str) -> list[str]:
    if not isinstance(res_obj, dict):
        return []
    raw = res_obj.get(key)
    if isinstance(raw, list):
        return [str(x) for x in raw if x]
    if isinstance(raw, str) and raw.strip():
        return [raw.strip()]
    return []


def _retry_remove(remove_fn, path_obj: Path, attempts: int = 5, delay_sec: float = 0.05) -> None:
    """Retry single-file unlink or empty-dir rmdir briefly when Windows releases child handles."""
    for i in range(attempts):
        try:
            remove_fn(path_obj)
            return
        except FileNotFoundError:
            return
        except OSError:
            if i + 1 < attempts:
                time.sleep(delay_sec)


def _create_ipc_dir_under(parent: Path, prefix: str) -> str:
    """Create a unique subdirectory via `os.mkdir` so Windows inherits the caller's parent DACL."""
    parent.mkdir(parents=True, exist_ok=True)
    for _ in range(16):
        cand = parent / f'{prefix}{uuid.uuid4().hex[:12]}'
        try:
            os.mkdir(cand)
            return str(cand)
        except FileExistsError:
            continue
    raise OSError(f'failed to create unique directory under {parent}')


def _create_ipc_work_dir(base_dir: Path) -> str:
    """Create the Defender elevation IPC directory without `tempfile.mkdtemp`'s 0o700 OWNER RIGHTS ACL."""
    try:
        return _create_ipc_dir_under(base_dir, 'defender-')
    except OSError:
        return _create_ipc_dir_under(Path(tempfile.gettempdir()), 'nspb-defender-')


def _read_json_with_retry(
    path_obj: Path,
    *,
    attempts: int = 8,
    delay_sec: float = 0.05,
) -> tuple[dict | None, str]:
    """Read and decode a JSON dict with short retries for Move-Item / AV filter handle transient locks."""
    last_err = ''
    for i in range(max(1, attempts)):
        try:
            data = json.loads(path_obj.read_text(encoding='utf-8-sig'))
            if isinstance(data, dict):
                return data, ''
            last_err = f'TypeError: expected JSON object, got {type(data).__name__}'
        except (OSError, ValueError) as e:
            last_err = f'{type(e).__name__}: {e}'
        if i + 1 < attempts:
            time.sleep(delay_sec)
    return None, last_err


def _cleanup_work_dir(work_td: str, *known_files: Path) -> None:
    work_path = Path(work_td)
    for f in known_files:
        if f.exists():
            _retry_remove(Path.unlink, f)
    try:
        for extra in work_path.glob('*.tmp-*'):
            _retry_remove(Path.unlink, extra)
    except OSError:
        pass
    _retry_remove(os.rmdir, work_path)
    if work_path.name.startswith(('defender-', 'nspb-defender-')):
        prefix = 'defender-' if work_path.name.startswith('defender-') else 'nspb-defender-'
        try:
            for stale in work_path.parent.glob(f'{prefix}*'):
                if stale != work_path and stale.is_dir():
                    try:
                        os.rmdir(stale)
                    except OSError:
                        pass
        except OSError:
            pass


def _run_elevated_payload(
    clean_paths: list[str],
    clean_procs: list[str],
    *,
    inner_script_builder,
    runner=subprocess.run,
) -> DefenderResult:
    base_dir = app_data_root()
    work_td = _create_ipc_work_dir(base_dir)

    payload_file = Path(work_td) / 'payload.json'
    script_file = Path(work_td) / 'elevate.ps1'
    started_file = Path(work_td) / 'started.json'
    result_file = Path(work_td) / 'result.json'
    try:
        payload = {
            'paths': clean_paths,
            'processes': clean_procs,
            'result_path': str(result_file),
        }
        payload_file.write_text(json.dumps(payload, ensure_ascii=True), encoding='utf-8')
        inner_script = inner_script_builder(str(payload_file))
        script_file.write_text(inner_script, encoding='utf-8-sig')

        used_native_win32 = False
        if os.name == 'nt' and runner is subprocess.run:
            used_native_win32 = True
            returncode, raw_err = _launch_elevated_win32(
                script_file,
                work_td,
                result_file,
                started_file,
                POWERSHELL_TIMEOUT_SEC,
            )
            clean_stderr = sanitize_powershell_output(raw_err)
        else:
            outer_script = build_outer_launcher_script(str(script_file))
            outer_b64 = encode_powershell_command(outer_script)

            kwargs: dict = {'timeout': POWERSHELL_TIMEOUT_SEC}
            if os.name == 'nt':
                kwargs['creationflags'] = getattr(subprocess, 'CREATE_NO_WINDOW', 0x08000000)

            cmd = [
                'powershell.exe',
                '-NoProfile',
                '-NonInteractive',
                '-WindowStyle',
                'Hidden',
                '-ExecutionPolicy',
                'Bypass',
                '-EncodedCommand',
                outer_b64,
            ]
            try:
                proc = runner(cmd, capture_output=True, **kwargs)
            except TypeError:
                kwargs.pop('timeout', None)
                proc = runner(cmd, capture_output=True, **kwargs)

            returncode = proc.returncode
            raw_stderr = _decode_console_bytes(getattr(proc, 'stderr', None))
            raw_stdout = _decode_console_bytes(getattr(proc, 'stdout', None))
            clean_stderr = sanitize_powershell_output(raw_stderr) or sanitize_powershell_output(raw_stdout)

        if returncode == ERROR_CANCELLED:
            return DefenderResult(
                ok=False,
                cancelled=True,
                added_paths=clean_paths,
                added_processes=clean_procs,
            )

        if result_file.is_file():
            res_obj_opt, read_err = _read_json_with_retry(result_file)
            res_obj = res_obj_opt if isinstance(res_obj_opt, dict) else {}
            rem_paths = _string_list_field(res_obj, 'remaining_paths')
            rem_procs = _string_list_field(res_obj, 'remaining_processes')
            error_code = str(res_obj.get('error_code') or '').strip() if isinstance(res_obj, dict) else ''
            if isinstance(res_obj, dict) and res_obj.get('ok') is True and (used_native_win32 or returncode == 0):
                return DefenderResult(
                    ok=True,
                    added_paths=clean_paths,
                    added_processes=clean_procs,
                    remaining_paths=rem_paths,
                    remaining_processes=rem_procs,
                )
            err_msg = str(res_obj.get('error') or '').strip() if isinstance(res_obj, dict) else ''
            read_fail_note = f'failed to read result.json ({read_err})' if read_err else ''
            return DefenderResult(
                ok=False,
                added_paths=clean_paths,
                added_processes=clean_procs,
                remaining_paths=rem_paths,
                remaining_processes=rem_procs,
                error=err_msg or clean_stderr or read_fail_note or f'exit code {returncode}',
                error_code=error_code,
            )

        return DefenderResult(
            ok=False,
            added_paths=clean_paths,
            added_processes=clean_procs,
            error=clean_stderr or f'elevated PowerShell exited with code {returncode} without writing result.json',
        )
    except subprocess.TimeoutExpired:
        return DefenderResult(
            ok=False,
            added_paths=clean_paths,
            added_processes=clean_procs,
            error=f'Windows Security PowerShell command timed out after {POWERSHELL_TIMEOUT_SEC}s',
        )
    except OSError as e:
        return DefenderResult(
            ok=False,
            added_paths=clean_paths,
            added_processes=clean_procs,
            error=str(e),
        )
    finally:
        _cleanup_work_dir(work_td, payload_file, script_file, started_file, result_file)


def apply_exclusions(
    paths: Iterable[str],
    processes: Iterable[str],
    *,
    runner=subprocess.run,
) -> DefenderResult:
    """Prompt the user via Windows UAC and register `paths` and `processes` in Defender.

    Runs synchronously (call from a worker thread, never on the UI thread).
    """
    clean_paths = [_norm_win_path(p) for p in paths if p and is_safe_exclusion_dir(p)]
    clean_procs = [_norm_win_path(p) for p in processes if p and is_safe_exclusion_process(p)]
    if not clean_paths and not clean_procs:
        return DefenderResult(ok=True, added_paths=[], added_processes=[])

    res = _run_elevated_payload(
        clean_paths,
        clean_procs,
        inner_script_builder=build_inner_elevation_script,
        runner=runner,
    )
    if res.ok:
        save_recorded_state(clean_paths, clean_procs)
    return res


def remove_exclusions(
    paths: Iterable[str] | None = None,
    processes: Iterable[str] | None = None,
    *,
    runner=subprocess.run,
) -> DefenderResult:
    """Prompt the user via Windows UAC and remove the recorded exclusions from Defender."""
    rec_paths, rec_procs = load_recorded_state()
    src_paths = list(rec_paths) if paths is None else list(paths)
    src_procs = list(rec_procs) if processes is None else list(processes)
    clean_paths = [_norm_win_path(p) for p in src_paths if p and str(p).strip()]
    clean_procs = [str(p).strip() for p in src_procs if p and str(p).strip()]
    if not clean_paths and not clean_procs:
        clear_recorded_state()
        return DefenderResult(ok=True, added_paths=[], added_processes=[])

    res = _run_elevated_payload(
        clean_paths,
        clean_procs,
        inner_script_builder=build_inner_removal_script,
        runner=runner,
    )
    if res.ok:
        clear_recorded_state()
    elif res.remaining_paths or res.remaining_processes:
        replace_recorded_state(res.remaining_paths, res.remaining_processes)
    return res
