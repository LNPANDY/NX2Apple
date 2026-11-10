"""Windows Defender exclusion helper for NX2Apple / NS Port Builder.

Real-time scanning (`WdFilter.sys` / `MsMpEng.exe`) intercepts every short-lived shader
compiler subprocess (`dmsh_xlate.exe`, `spirv-cross.exe`, `metal.exe`, `air-lld.exe`,
`metallib.exe`) and every multi-gigabyte SQLite / RomFS image write (`sh/cache/cas.db`,
`b-<chain>.img.part`) during the 99% shader packaging step, throttling disk I/O to a few
MB/s and stalling at 99% for minutes.

This module collects the exact build directories and compiler processes and submits them
in a single elevated PowerShell call (`Add-MpPreference`) after the user confirms the
native Windows UAC prompt.
"""
from __future__ import annotations

import base64
import json
import ntpath
import os
import subprocess
import sys
import tempfile
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

#: Windows error code returned when the user clicks "No" / Cancel on the UAC prompt.
ERROR_CANCELLED = 1223

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


def encode_powershell_command(script: str) -> str:
    """Encode a PowerShell script as UTF-16LE Base64 for `-EncodedCommand`."""
    return base64.b64encode(script.encode('utf-16-le')).decode('ascii')


def build_inner_elevation_script(payload_json_path: str) -> str:
    """Build the elevated PowerShell script that reads `payload_json_path` and calls `Add-MpPreference`.

    All folder paths and process names are read from the UTF-8 JSON file on disk rather than
    interpolated into the command line, preventing any quoting, codepage, or command-length overflow.
    Submits in bounded batches (`WMI_BATCH_SIZE = 20`) to avoid WMI marshaling buffer limits.
    """
    escaped_payload = str(payload_json_path).replace("'", "''")
    return (
        "$ErrorActionPreference = 'Stop'\n"
        f"$payloadPath = '{escaped_payload}'\n"
        f"$batchSize = {WMI_BATCH_SIZE}\n"
        "$cfg = Get-Content -LiteralPath $payloadPath -Raw -Encoding UTF8 | ConvertFrom-Json\n"
        "try {\n"
        "    $paths = @($cfg.paths | Where-Object { $_ -ne $null -and $_ -ne '' })\n"
        "    $procs = @($cfg.processes | Where-Object { $_ -ne $null -and $_ -ne '' })\n"
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
        "    @{ ok = $true; error = '' } | ConvertTo-Json -Compress | "
        "Set-Content -LiteralPath $cfg.result_path -Encoding UTF8\n"
        "    exit 0\n"
        "} catch {\n"
        "    $msg = if ($_.Exception) { $_.Exception.Message } else { $_.ToString() }\n"
        "    @{ ok = $false; error = $msg } | ConvertTo-Json -Compress | "
        "Set-Content -LiteralPath $cfg.result_path -Encoding UTF8\n"
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
    escaped_payload = str(payload_json_path).replace("'", "''")
    return (
        "$ErrorActionPreference = 'Stop'\n"
        f"$payloadPath = '{escaped_payload}'\n"
        f"$batchSize = {WMI_BATCH_SIZE}\n"
        "$cfg = Get-Content -LiteralPath $payloadPath -Raw -Encoding UTF8 | ConvertFrom-Json\n"
        "try {\n"
        "    $paths = @($cfg.paths | Where-Object { $_ -ne $null -and $_ -ne '' })\n"
        "    $procs = @($cfg.processes | Where-Object { $_ -ne $null -and $_ -ne '' })\n"
        "    $mp = try { Get-MpPreference -ErrorAction SilentlyContinue } catch { $null }\n"
        "    if ($null -ne $mp -and $null -ne $mp.ExclusionPath) {\n"
        "        $curP = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)\n"
        "        foreach ($x in $mp.ExclusionPath) { if ($x) { [void]$curP.Add($x.TrimEnd('\\')) } }\n"
        "        $paths = @($paths | Where-Object { $curP.Contains($_.TrimEnd('\\')) })\n"
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
        "            foreach ($x in $mpAfter.ExclusionPath) { if ($x) { [void]$afterP.Add($x.TrimEnd('\\')) } }\n"
        "            $remPaths = @($cfg.paths | Where-Object { $_ -and $afterP.Contains($_.TrimEnd('\\')) })\n"
        "        }\n"
        "        if ($null -ne $mpAfter.ExclusionProcess) {\n"
        "            $afterPr = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)\n"
        "            foreach ($x in $mpAfter.ExclusionProcess) { if ($x) { [void]$afterPr.Add($x) } }\n"
        "            $remProcs = @($cfg.processes | Where-Object { $_ -and $afterPr.Contains($_) })\n"
        "        }\n"
        "    }\n"
        "    $okFlag = ($remPaths.Count -eq 0 -and $remProcs.Count -eq 0 -and $lastErr -eq '')\n"
        "    @{ ok = $okFlag; error = $lastErr; remaining_paths = $remPaths; remaining_processes = $remProcs } | "
        "ConvertTo-Json -Compress | Set-Content -LiteralPath $cfg.result_path -Encoding UTF8\n"
        "    if ($okFlag) { exit 0 } else { exit 1 }\n"
        "} catch {\n"
        "    $msg = if ($_.Exception) { $_.Exception.Message } else { $_.ToString() }\n"
        "    @{ ok = $false; error = $msg } | ConvertTo-Json -Compress | "
        "Set-Content -LiteralPath $cfg.result_path -Encoding UTF8\n"
        "    exit 1\n"
        "}\n"
    )


def build_outer_launcher_script(inner_encoded_command: str) -> str:
    """Build the non-elevated PowerShell wrapper that triggers the Windows UAC `RunAs` prompt."""
    safe_b64 = str(inner_encoded_command).replace("'", '')
    return (
        "$ErrorActionPreference = 'Stop'\n"
        "try {\n"
        "    $argList = @('-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden', "
        f"'-ExecutionPolicy', 'Bypass', '-EncodedCommand', '{safe_b64}')\n"
        "    $p = Start-Process -FilePath 'powershell.exe' -Verb RunAs -WindowStyle Hidden "
        "-Wait -PassThru -ArgumentList $argList\n"
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


def _run_elevated_payload(
    clean_paths: list[str],
    clean_procs: list[str],
    *,
    inner_script_builder,
    runner=subprocess.run,
) -> DefenderResult:
    base_dir = app_data_root()
    try:
        base_dir.mkdir(parents=True, exist_ok=True)
        work_td = tempfile.mkdtemp(prefix='defender-', dir=str(base_dir))
    except OSError:
        work_td = tempfile.mkdtemp(prefix='nspb-defender-')

    payload_file = Path(work_td) / 'payload.json'
    result_file = Path(work_td) / 'result.json'
    try:
        payload = {
            'paths': clean_paths,
            'processes': clean_procs,
            'result_path': str(result_file),
        }
        payload_file.write_text(json.dumps(payload, ensure_ascii=False), encoding='utf-8')
        inner_script = inner_script_builder(str(payload_file))
        inner_b64 = encode_powershell_command(inner_script)
        outer_script = build_outer_launcher_script(inner_b64)
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
            proc = runner(
                cmd,
                capture_output=True,
                text=True,
                encoding='utf-8',
                errors='replace',
                **kwargs,
            )
        except TypeError:
            kwargs.pop('timeout', None)
            proc = runner(
                cmd,
                capture_output=True,
                text=True,
                encoding='utf-8',
                errors='replace',
                **kwargs,
            )

        if proc.returncode == ERROR_CANCELLED:
            return DefenderResult(
                ok=False,
                cancelled=True,
                added_paths=clean_paths,
                added_processes=clean_procs,
            )

        if result_file.is_file():
            try:
                res_obj = json.loads(result_file.read_text(encoding='utf-8-sig'))
            except (OSError, ValueError):
                res_obj = {}
            rem_paths = (
                [str(x) for x in res_obj.get('remaining_paths', ()) if x]
                if isinstance(res_obj, dict) and isinstance(res_obj.get('remaining_paths'), list)
                else []
            )
            rem_procs = (
                [str(x) for x in res_obj.get('remaining_processes', ()) if x]
                if isinstance(res_obj, dict) and isinstance(res_obj.get('remaining_processes'), list)
                else []
            )
            if isinstance(res_obj, dict) and res_obj.get('ok') is True and proc.returncode == 0:
                return DefenderResult(
                    ok=True,
                    added_paths=clean_paths,
                    added_processes=clean_procs,
                    remaining_paths=rem_paths,
                    remaining_processes=rem_procs,
                )
            err_msg = str(res_obj.get('error') or '').strip() if isinstance(res_obj, dict) else ''
            stderr = (proc.stderr or proc.stdout or '').strip()
            return DefenderResult(
                ok=False,
                added_paths=clean_paths,
                added_processes=clean_procs,
                remaining_paths=rem_paths,
                remaining_processes=rem_procs,
                error=err_msg or stderr or f'exit code {proc.returncode}',
            )

        stderr = (proc.stderr or proc.stdout or '').strip()
        return DefenderResult(
            ok=False,
            added_paths=clean_paths,
            added_processes=clean_procs,
            error=stderr or f'elevated PowerShell exited with code {proc.returncode} without writing result.json',
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
        for f in (payload_file, result_file):
            try:
                if f.exists():
                    f.unlink()
            except OSError:
                pass
        try:
            os.rmdir(work_td)
        except OSError:
            pass


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
