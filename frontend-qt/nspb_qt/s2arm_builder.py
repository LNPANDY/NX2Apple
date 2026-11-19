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
from . import platform_util as pu

DEFAULT_MIN_DOTNET_SDK = '10.0.403'
DEFAULT_DOTNET_ROLL_FORWARD = 'latestFeature'
PIP_PACKAGES: tuple[str, ...] = ('numpy', 'Pillow', 'fonttools', 'skia-pathops')
REQUIRED_PYTHON_PACKAGES: tuple[tuple[str, str], ...] = (
    ('numpy', 'numpy'),
    ('PIL', 'Pillow'),
    ('fontTools', 'fonttools'),
    ('pathops', 'skia-pathops'),
)


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
) -> tuple[str, bool, str, str | None]:
    """Locate a `dotnet` executable whose SDK meets S2Arm's global.json requirement."""
    req_ver, req_rf = sdk_requirement(tree)
    parsed_req = _parse_sdk_version(req_ver)
    req_major = parsed_req[0] if parsed_req else 10
    if candidates is None:
        if pu.IS_WIN:
            cands = [
                r'C:\Program Files\dotnet\dotnet.exe',
                os.path.expandvars(r'%LOCALAPPDATA%\Microsoft\dotnet\dotnet.exe'),
            ]
        else:
            cands = [
                '/opt/homebrew/bin/dotnet',
                '/usr/local/bin/dotnet',
                '/usr/local/share/dotnet/dotnet',
                str(Path.home() / '.dotnet' / 'dotnet'),
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
    fallback = existing[0] if existing else ('dotnet.exe' if pu.IS_WIN else 'dotnet')
    return fallback, False, req_ver, best_old


def missing_python_packages(
    python_exe: str,
    *,
    runner: Callable[[list[str]], tuple[int, str]] | None = None,
) -> list[str]:
    """Return missing S2Arm Python pip package names for `python_exe`."""
    if not python_exe:
        return [pkg for _, pkg in REQUIRED_PYTHON_PACKAGES]
    probe = (
        'import importlib.util\n'
        'checks = [("numpy", "numpy"), ("PIL", "Pillow"), ("fontTools", "fonttools"), ("pathops", "skia-pathops")]\n'
        'print(",".join(pkg for mod, pkg in checks if importlib.util.find_spec(mod) is None))\n'
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
        argv = ['/bin/bash', script, source_input]
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
