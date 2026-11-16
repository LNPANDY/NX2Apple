"""S2Arm external builder adapter for Desktop (macOS + Windows Qt).

100% original implementation. Cleanroom boundary: no code copied from external repositories.
"""
from __future__ import annotations

import json
import os
import sys
from collections.abc import Mapping
from pathlib import Path
from typing import Any

from . import engine


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
