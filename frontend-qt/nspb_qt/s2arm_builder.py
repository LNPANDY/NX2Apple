"""S2Arm external builder adapter for Desktop (macOS + Windows Qt).

100% original implementation. Cleanroom boundary: no code copied from external repositories.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
from collections.abc import Callable, Mapping
from pathlib import Path
from typing import Any

from . import engine
from . import input_staging
from . import platform_util as pu
from . import s2arm_bootstrap

_SIBLING_CONTAINER_SUFFIXES: frozenset[str] = frozenset({'.nup', '.nsp', '.xci', '.nsz', '.xcz'})

DEFAULT_MIN_DOTNET_SDK = '10.0.403'
DEFAULT_DOTNET_ROLL_FORWARD = 'latestFeature'
PIP_PACKAGES: tuple[str, ...] = (
    'capstone',
    'lz4',
    'zstandard',
    'numpy',
    'Pillow',
    'fonttools',
    'skia-pathops',
    'cmake',
    'meson',
    'ninja',
)
REQUIRED_PYTHON_PACKAGES: tuple[tuple[str, str], ...] = (
    ('capstone', 'capstone'),
    ('lz4', 'lz4'),
    ('zstandard', 'zstandard'),
    ('numpy', 'numpy'),
    ('PIL', 'Pillow'),
    ('fontTools', 'fonttools'),
    ('pathops', 'skia-pathops'),
)


def is_homebrew_dotnet_path(path: str) -> bool:
    """Return True when `path` or its resolved realpath points inside Homebrew (`/Cellar/` or `/homebrew/`)."""
    if not path:
        return False
    resolved = os.path.realpath(path)
    for p in (path, resolved):
        if '/Cellar/' in p or '/homebrew/' in p:
            return True
    return False


def _parse_sdk_version(raw: str) -> tuple[int, int, int, int] | None:
    core = raw.split('-', 1)[0].split('+', 1)[0].strip()
    parts = core.split('.')
    if len(parts) < 3:
        return None
    try:
        major = int(parts[0])
        minor = int(parts[1])
        third = int(parts[2])
    except ValueError:
        return None
    return (major, minor, third // 100, third % 100)


def sdk_requirement(tree: str = '') -> tuple[str, str]:
    """Read required .NET SDK version and rollForward policy from S2Arm's compat/tree/global.json."""
    if tree:
        global_json = Path(tree, 'compat', 'tree', 'global.json')
        try:
            if global_json.is_file():
                data = json.loads(global_json.read_text(encoding='utf-8'))
                sdk = data.get('sdk') if isinstance(data, dict) else None
                if isinstance(sdk, dict):
                    ver = str(sdk.get('version') or '').strip()
                    if _parse_sdk_version(ver) is not None:
                        rf = str(sdk.get('rollForward') or 'patch').strip() or 'patch'
                        return ver, rf
        except (OSError, ValueError, TypeError):
            pass
    return DEFAULT_MIN_DOTNET_SDK, DEFAULT_DOTNET_ROLL_FORWARD


def sdk_satisfies(
    version: str,
    required: str = DEFAULT_MIN_DOTNET_SDK,
    roll_forward: str = DEFAULT_DOTNET_ROLL_FORWARD,
) -> bool:
    """Evaluate whether a listed .NET SDK version satisfies `required` under `roll_forward`."""
    have = _parse_sdk_version(version)
    want = _parse_sdk_version(required)
    if have is None or want is None:
        return False
    if roll_forward in ('latestFeature', 'feature'):
        return have[:2] == want[:2] and have[2:] >= want[2:]
    if roll_forward in ('patch', 'latestPatch'):
        return have[:3] == want[:3] and have[3] >= want[3]
    if roll_forward in ('latestMinor', 'minor'):
        return have[0] == want[0] and have[1:] >= want[1:]
    if roll_forward in ('latestMajor', 'major'):
        return have >= want
    return have == want


def inspect_dotnet_sdks(
    list_sdks_output: str,
    required: str = DEFAULT_MIN_DOTNET_SDK,
    roll_forward: str = DEFAULT_DOTNET_ROLL_FORWARD,
) -> tuple[bool, list[str]]:
    """Parse `dotnet --list-sdks` output and check against S2Arm's minimum SDK requirement."""
    versions: list[str] = []
    satisfied = False
    for line in list_sdks_output.splitlines():
        trimmed = line.strip()
        if not trimmed or '[' not in trimmed or not trimmed.endswith(']'):
            continue
        ver = trimmed.split(None, 1)[0]
        if _parse_sdk_version(ver) is None:
            continue
        if ver not in versions:
            versions.append(ver)
        if sdk_satisfies(ver, required=required, roll_forward=roll_forward):
            satisfied = True
    return satisfied, versions


def find_dotnet_for_s2arm(
    candidates: list[str] | None = None,
    tree: str = '',
    *,
    runner: Callable[[list[str], dict[str, str]], tuple[int, str]] | None = None,
    is_windows: bool | None = None,
) -> tuple[str, bool, str, str | None]:
    """Locate a non-Homebrew `dotnet` executable whose SDK meets S2Arm's global.json requirement."""
    win = pu.IS_WIN if is_windows is None else is_windows
    req_ver, req_rf = sdk_requirement(tree)
    parsed_req = _parse_sdk_version(req_ver)
    req_major = parsed_req[0] if parsed_req else 10
    if candidates is None:
        if win:
            cands = [
                r'C:\Program Files\dotnet\dotnet.exe',
                os.path.expandvars(r'%LOCALAPPDATA%\Microsoft\dotnet\dotnet.exe'),
            ]
        else:
            cands = [
                str(Path.home() / '.dotnet' / 'dotnet'),
                '/usr/local/share/dotnet/dotnet',
                '/usr/local/bin/dotnet',
            ]
        w = pu._which('dotnet')
        if w and w not in cands:
            cands.append(w)
    else:
        cands = list(candidates)

    def _default_run(cmd: list[str], env: dict[str, str]) -> tuple[int, str]:
        try:
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=30, env=env, **pu.no_window_kwargs())
            return r.returncode, r.stdout or ''
        except Exception:
            return 1, ''

    run_fn = runner or _default_run
    existing: list[str] = []
    best_old: str | None = None
    for cand in cands:
        if not cand:
            continue
        if not win and is_homebrew_dotnet_path(cand):
            continue
        if runner is None and not Path(cand).is_file():
            continue
        existing.append(cand)
        env = pu.child_env({'DOTNET_ROOT': str(Path(cand).parent)})
        rc, out = run_fn([cand, '--list-sdks'], env)
        if rc != 0:
            continue
        ok, vers = inspect_dotnet_sdks(out, required=req_ver, roll_forward=req_rf)
        if ok:
            return cand, True, req_ver, None
        same_major = [v for v in vers if (_parse_sdk_version(v) or (0,))[0] == req_major]
        if same_major:
            best_old = same_major[-1]
        elif best_old is None and vers:
            best_old = vers[-1]
    fallback = existing[0] if existing else ('dotnet.exe' if win else 'dotnet')
    return fallback, False, req_ver, best_old


def missing_python_packages(
    python_exe: str,
    *,
    tree: str = '',
    runner: Callable[[list[str]], tuple[int, str]] | None = None,
) -> list[str]:
    """Return missing S2Arm Python packages or exact `pkg==ver` pin mismatches for `python_exe`."""
    if not python_exe:
        return [pkg for _, pkg in REQUIRED_PYTHON_PACKAGES]
    pins = s2arm_bootstrap.parse_requirement_pins(tree)[1] if tree else []
    checks_repr = repr(list(REQUIRED_PYTHON_PACKAGES))
    pins_repr = repr(list(pins))
    probe = (
        'import importlib.metadata, importlib.util\n'
        f'checks = {checks_repr}\n'
        f'pins = {pins_repr}\n'
        'missing = []\n'
        'for mod, pkg in checks:\n'
        '    if importlib.util.find_spec(mod) is None:\n'
        '        missing.append(pkg)\n'
        'for pkg, expected in pins:\n'
        '    try:\n'
        '        have = importlib.metadata.version(pkg)\n'
        '    except importlib.metadata.PackageNotFoundError:\n'
        '        have = None\n'
        '    if have != expected:\n'
        '        tag = f"{pkg}=={expected}"\n'
        '        if tag not in missing:\n'
        '            missing.append(tag)\n'
        'print(",".join(missing))\n'
    )
    if runner is not None:
        rc, out = runner([python_exe, '-c', probe])
    else:
        if not Path(python_exe).is_file():
            return [pkg for _, pkg in REQUIRED_PYTHON_PACKAGES]
        try:
            r = subprocess.run(
                [python_exe, '-c', probe],
                capture_output=True,
                text=True,
                timeout=30,
                env=pu.child_env(),
                **pu.no_window_kwargs(),
            )
            rc, out = r.returncode, r.stdout or ''
        except Exception:
            rc, out = 1, ''
    if rc != 0:
        return [pkg for _, pkg in REQUIRED_PYTHON_PACKAGES]
    line = out.strip()
    if not line:
        return []
    return [item.strip() for item in line.split(',') if item.strip()]


def feature_enabled(env: Mapping[str, str] | None = None) -> bool:
    """Return whether the multi-upstream feature toggle is enabled."""
    return (env if env is not None else os.environ).get('NX2APPLE_MULTI_UPSTREAM') != '0'


def is_usable_tree(path: str, *, is_windows: bool | None = None) -> bool:
    """Check if the given path is a valid usable S2Arm repository tree."""
    if not path or not engine.is_upstream_tree(path, 's2arm'):
        return False
    win = sys.platform == 'win32' if is_windows is None else is_windows
    p = Path(path)
    if win:
        return p.joinpath('pack', 'orch', 'oneclick_win.py').is_file()
    return p.joinpath('pack', 'oneclick', 'oneclick.sh').is_file()


def resolve_source_input(
    source_input: str,
    *,
    work_dir: str,
    hard_links: bool = True,
) -> tuple[str, bool]:
    """Ensure the source path passed to S2Arm is always a directory.

    Returns `(directory_path, used_staging)`. If staging is needed and fails,
    returns `('', True)`.
    """
    if not source_input:
        return source_input, False
    p = Path(source_input)
    if not p.is_file():
        return source_input, False
    parent = p.parent
    try:
        siblings = [
            entry.name
            for entry in parent.iterdir()
            if not entry.name.startswith('._')
            and entry.is_file()
            and entry.suffix.lower() in _SIBLING_CONTAINER_SUFFIXES
        ]
    except OSError:
        siblings = []
    if siblings == [p.name]:
        return str(parent), False
    staging = input_staging.folder(work_dir)
    if input_staging.sync([source_input], staging, hard_links=hard_links) == 0:
        return '', True
    return staging, True


def build_command(
    tree: str,
    *,
    python_exe: str,
    source_input: str,
    keys_path: str = '',
    is_unencrypted: bool = False,
    work_dir: str,
    target: str = 'ios',
    title_id: str = '',
    install_udid: str = '',
    events_file: str = '',
    is_windows: bool | None = None,
    bash_exe: str = '/bin/bash',
) -> tuple[list[str], str, dict[str, str]]:
    """Construct command arguments, working directory, and extra environment variables for S2Arm build."""
    win = sys.platform == 'win32' if is_windows is None else is_windows
    s2a_target = 'mac' if target == 'mac-app' else 'ios'
    cwd = str(Path(tree))
    extra_env: dict[str, str] = {'PYTHONUNBUFFERED': '1'}

    if win:
        argv = [
            python_exe,
            '-X',
            'utf8',
            '-m',
            'pack.orch.oneclick_win',
            source_input,
            '--out',
            work_dir,
            '--target',
            s2a_target,
        ]
        if keys_path and not is_unencrypted:
            extra_env['S2A_KEYS'] = keys_path
        if title_id.strip():
            argv.extend(['--title-id', title_id.strip().upper()])
        if s2a_target != 'mac' and install_udid.strip():
            argv.extend(['--install', install_udid.strip()])
        if events_file:
            argv.extend(['--events', events_file])
    else:
        script = str(Path(tree, 'pack', 'oneclick', 'oneclick.sh'))
        resolved_bash = bash_exe or '/bin/bash'
        argv = [resolved_bash, script, source_input]
        if keys_path and not is_unencrypted:
            argv.extend(['--keys', keys_path])
            extra_env['S2A_KEYS'] = keys_path
        argv.extend(['--out', work_dir, '--target', s2a_target])
        if title_id.strip():
            argv.extend(['--title-id', title_id.strip().upper()])
        if s2a_target != 'mac' and install_udid.strip():
            argv.extend(['--device', install_udid.strip()])
        if events_file:
            argv.extend(['--events', events_file])
        extra_env['S2A_PYTHON'] = python_exe

    return argv, cwd, extra_env


def detect_physical_memory_bytes() -> int:
    """Return total physical RAM in bytes across macOS, Linux, and Windows (0 if unavailable)."""
    if sys.platform == 'win32':
        try:
            import ctypes

            class _MemoryStatusEx(ctypes.Structure):
                _fields_ = [
                    ('dwLength', ctypes.c_ulong),
                    ('dwMemoryLoad', ctypes.c_ulong),
                    ('ullTotalPhys', ctypes.c_ulonglong),
                    ('ullAvailPhys', ctypes.c_ulonglong),
                    ('ullTotalPageFile', ctypes.c_ulonglong),
                    ('ullAvailPageFile', ctypes.c_ulonglong),
                    ('ullTotalVirtual', ctypes.c_ulonglong),
                    ('ullAvailVirtual', ctypes.c_ulonglong),
                    ('ullAvailExtendedVirtual', ctypes.c_ulonglong),
                ]

            status = _MemoryStatusEx()
            status.dwLength = ctypes.sizeof(_MemoryStatusEx)
            if ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(status)):
                return int(status.ullTotalPhys)
        except Exception:
            return 0
    try:
        page_size = os.sysconf('SC_PAGE_SIZE')
        phys_pages = os.sysconf('SC_PHYS_PAGES')
        if page_size > 0 and phys_pages > 0:
            return int(page_size) * int(phys_pages)
    except (AttributeError, OSError, ValueError):
        pass
    try:
        meminfo = Path('/proc/meminfo')
        if meminfo.is_file():
            for line in meminfo.read_text(encoding='utf-8').splitlines():
                if line.startswith('MemTotal:'):
                    parts = line.split()
                    if len(parts) >= 2 and parts[1].isdigit():
                        return int(parts[1]) * 1024
    except OSError:
        pass
    return 0


def recommended_concurrency(
    *,
    physical_memory_bytes: int | None = None,
    cpu_count: int | None = None,
) -> tuple[int, int] | None:
    """Return conservative fallback `(S2A_DIRECT_J, S2A_CPU_BAKE)` floors from RAM and CPU count."""
    mem_bytes = detect_physical_memory_bytes() if physical_memory_bytes is None else max(0, int(physical_memory_bytes))
    cores = max(1, (os.cpu_count() or 1) if cpu_count is None else int(cpu_count))
    mem_gib = mem_bytes // (1024 * 1024 * 1024)
    if mem_gib >= 32:
        return (min(cores, 8), min(cores, 4))
    if mem_gib >= 24:
        return (min(cores, 6), min(cores, 3))
    if mem_gib >= 16:
        return (min(cores, 4), min(cores, 2))
    if mem_gib >= 8:
        return (min(cores, 2), 1)
    return None


def apply_concurrency_defaults(
    env: Mapping[str, str],
    *,
    process_env: Mapping[str, str] | None = None,
    physical_memory_bytes: int | None = None,
    cpu_count: int | None = None,
) -> dict[str, str]:
    """Apply conservative `S2A_DIRECT_J` and `S2A_CPU_BAKE` defaults without overriding explicit values."""
    out = dict(env)
    parent = os.environ if process_env is None else process_env
    existing_direct = str(out.get('S2A_DIRECT_J') or parent.get('S2A_DIRECT_J') or '').strip()
    existing_bake = str(out.get('S2A_CPU_BAKE') or parent.get('S2A_CPU_BAKE') or '').strip()
    if existing_direct:
        out['S2A_DIRECT_J'] = existing_direct
    if existing_bake:
        out['S2A_CPU_BAKE'] = existing_bake
    rec = recommended_concurrency(
        physical_memory_bytes=physical_memory_bytes,
        cpu_count=cpu_count,
    )
    if rec is None:
        return out
    direct_j, cpu_bake = rec
    if not existing_direct:
        out['S2A_DIRECT_J'] = str(direct_j)
    if not existing_bake:
        out['S2A_CPU_BAKE'] = str(cpu_bake)
    return out


def parse_events(text: str) -> dict[str, Any] | None:
    """Parse newline-delimited JSON events and return the first result dictionary from the end."""
    for line in reversed(text.splitlines()):
        line = line.strip()
        if not line or not line.startswith('{'):
            continue
        try:
            data = json.loads(line)
            if isinstance(data, dict) and data.get('ev') == 'result':
                return data
        except (ValueError, TypeError):
            continue
    return None


def last_error(log_text: str, events_text: str = '') -> str:
    """Extract the most meaningful error line from events text or log text."""
    if events_text:
        res = parse_events(events_text)
        if res and not res.get('ok') and res.get('msg'):
            return str(res['msg']).strip()
    for line in reversed(log_text.splitlines()):
        trimmed = line.strip()
        if not trimmed:
            continue
        if '🔴' in trimmed or '【红】' in trimmed or trimmed.startswith('ERROR:'):
            return trimmed
    for line in reversed(log_text.splitlines()):
        trimmed = line.strip()
        if trimmed:
            return trimmed
    return ''
