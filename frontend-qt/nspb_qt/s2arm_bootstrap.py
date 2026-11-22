"""Turnkey bootstrap helpers for S2Arm external engine trees (macOS / Linux / Windows).

Pure Python standard library module (no PySide6 dependency) so headless CI tests run anywhere.
"""
from __future__ import annotations

import os
import re
import shutil
import stat
import subprocess
import sys
from collections.abc import Callable, Mapping
from pathlib import Path

from . import platform_util as pu

REQUIREMENT_FILES: tuple[str, ...] = (
    'tools/rewriter-requirements.txt',
    'pack/fonts/requirements.txt',
    'launchers/macos/requirements-runtime.txt',
)

FALLBACK_PYTHON_SPECS: tuple[str, ...] = (
    'capstone',
    'lz4',
    'zstandard',
    'numpy',
    'Pillow',
    'fonttools',
    'skia-pathops',
)

REQUIRED_BUILD_TOOLS_POSIX: tuple[str, ...] = ('cmake', 'meson', 'ninja')
REQUIRED_BUILD_TOOLS_WIN: tuple[str, ...] = ('cmake', 'ninja')

REQUIRED_RUNTIME_TOOLS_POSIX: tuple[str, ...] = (
    'spirv-as',
    'spirv-val',
    'glslangValidator',
    'spirv-cross',
    'zstd',
)

GIT_EXCLUDE_ENTRIES: tuple[str, ...] = (
    '/.venv/',
    '/.nx2apple-shims/',
    '/.upstream-version.json',
    '/build/',
)

_GIT_PATHSPEC_EXCLUDES: tuple[str, ...] = (
    ':(exclude).venv',
    ':(exclude).nx2apple-shims',
    ':(exclude).upstream-version.json',
    ':(exclude)build',
)

BASH_VERSION = '5.2.37'
BASH_TARBALL_PRIMARY = f'https://ftpmirror.gnu.org/gnu/bash/bash-{BASH_VERSION}.tar.gz'
BASH_TARBALL_FALLBACK = f'https://ftp.gnu.org/gnu/bash/bash-{BASH_VERSION}.tar.gz'
RUNTIME_TOOLS_MARKER = 'NX2APPLE_RUNTIME_TOOLS='

_PROXY_ACTIVE_KEYS = ('http_proxy', 'HTTP_PROXY', 'https_proxy', 'HTTPS_PROXY', 'all_proxy', 'ALL_PROXY')
_SPEC_NAME_RE = re.compile(r'^([A-Za-z0-9_.-]+)')


def _is_win(is_windows: bool | None) -> bool:
    return (sys.platform == 'win32') if is_windows is None else is_windows


def env_with_git_proxy_safety(base_env: Mapping[str, str] | None = None) -> dict[str, str]:
    """Return a mutable child env preserving proxy vars and hardening git HTTP/1.1 under proxies."""
    env = dict(base_env) if base_env is not None else pu.child_env()
    has_proxy = any(str(env.get(k) or '').strip() for k in _PROXY_ACTIVE_KEYS)
    if has_proxy and not str(env.get('GIT_CONFIG_COUNT') or '').strip():
        env['GIT_CONFIG_COUNT'] = '2'
        env['GIT_CONFIG_KEY_0'] = 'http.version'
        env['GIT_CONFIG_VALUE_0'] = 'HTTP/1.1'
        env['GIT_CONFIG_KEY_1'] = 'http.postBuffer'
        env['GIT_CONFIG_VALUE_1'] = '524288000'
    return env


def _run_cmd(
    argv: list[str],
    *,
    cwd: str | None = None,
    env: Mapping[str, str] | None = None,
    timeout: float = 1800.0,
    runner: Callable[..., tuple[int, str]] | None = None,
    on_line: Callable[[str], None] | None = None,
) -> tuple[int, str]:
    run_env = dict(env) if env is not None else pu.child_env()
    if runner is not None:
        return runner(argv, run_env, cwd)
    try:
        if on_line is None:
            r = subprocess.run(
                argv,
                cwd=cwd,
                capture_output=True,
                text=True,
                encoding='utf-8',
                errors='replace',
                timeout=timeout,
                env=run_env,
                **pu.no_window_kwargs(),
            )
            return r.returncode, (r.stdout or '') + (r.stderr or '')
        proc = subprocess.Popen(
            argv,
            cwd=cwd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            encoding='utf-8',
            errors='replace',
            bufsize=1,
            env=run_env,
            **pu.no_window_kwargs(),
        )
        lines: list[str] = []
        assert proc.stdout is not None
        for raw in proc.stdout:
            clean = raw.rstrip('\r\n')
            lines.append(clean)
            on_line(clean)
        rc = proc.wait(timeout=timeout)
        return rc, '\n'.join(lines)
    except Exception as exc:
        return 1, str(exc)


# ---------------------------------------------------------------------------
# 1. Single-commit local Git repository bootstrap for extracted ZIP snapshots
# ---------------------------------------------------------------------------

def ensure_git_exclude(tree: str | os.PathLike[str]) -> None:
    root = Path(tree)
    git_dir = root / '.git'
    if not git_dir.is_dir():
        return
    info_dir = git_dir / 'info'
    exclude_file = info_dir / 'exclude'
    try:
        info_dir.mkdir(parents=True, exist_ok=True)
        existing = exclude_file.read_text(encoding='utf-8') if exclude_file.is_file() else ''
        lines = existing.splitlines()
        changed = not exclude_file.is_file()
        for entry in GIT_EXCLUDE_ENTRIES:
            if entry not in lines:
                lines.append(entry)
                changed = True
        if changed:
            exclude_file.write_text('\n'.join(lines) + '\n', encoding='utf-8')
    except OSError:
        pass


def ensure_git_repo(
    tree: str | os.PathLike[str],
    *,
    runner: Callable[..., tuple[int, str]] | None = None,
) -> bool:
    if not tree:
        return False
    root = Path(tree)
    if (root / 'engine.json').is_file():
        return True
    git_path = root / '.git'
    if git_path.exists():
        ensure_git_exclude(root)
        return True

    git_exe = shutil.which('git') or ('/usr/bin/git' if Path('/usr/bin/git').is_file() else 'git')
    git_env = pu.child_env({
        'GIT_CONFIG_GLOBAL': os.devnull,
        'GIT_CONFIG_NOSYSTEM': '1',
    })

    rc, _ = _run_cmd([git_exe, '-C', str(root), 'init', '-q', '--template='], env=git_env, runner=runner)
    if rc != 0:
        return False

    ensure_git_exclude(root)
    _run_cmd([git_exe, '-C', str(root), 'config', 'gc.auto', '0'], env=git_env, runner=runner)
    _run_cmd([git_exe, '-C', str(root), 'config', 'maintenance.auto', 'false'], env=git_env, runner=runner)

    rc_add, _ = _run_cmd(
        [git_exe, '-C', str(root), 'add', '--force', '--all', '--', '.', *_GIT_PATHSPEC_EXCLUDES],
        env=git_env,
        runner=runner,
    )
    if rc_add != 0:
        shutil.rmtree(git_path, ignore_errors=True)
        return False

    rc_commit, _ = _run_cmd(
        [
            git_exe, '-C', str(root),
            '-c', 'commit.gpgsign=false',
            '-c', 'core.hooksPath=/dev/null',
            '-c', 'user.name=S2Arm',
            '-c', 'user.email=bundle@localhost',
            'commit', '-qm', 'Bundled S2Arm engine inputs',
        ],
        env=git_env,
        runner=runner,
    )
    if rc_commit != 0:
        shutil.rmtree(git_path, ignore_errors=True)
        return False
    return True


# ---------------------------------------------------------------------------
# 2. Dedicated `<s2arm>/.venv` and exact requirements*.txt pin validation
# ---------------------------------------------------------------------------

def parse_requirement_pins(
    tree: str | os.PathLike[str] = '',
    *,
    is_windows: bool | None = None,
) -> tuple[list[str], list[tuple[str, str]]]:
    """Read S2Arm's official requirement files and return `(pip_specs, exact_pins)`."""
    win = _is_win(is_windows)
    specs: list[str] = []
    spec_idx: dict[str, int] = {}
    pinned: list[tuple[str, str]] = []
    pin_idx: dict[str, int] = {}

    def _canon(name: str) -> str:
        return name.strip().lower().replace('_', '-')

    def _record(raw: str, *, prefer_override: bool) -> None:
        clean = raw.strip()
        if not clean or clean.startswith('#') or clean.startswith('-'):
            return
        m = _SPEC_NAME_RE.match(clean)
        if not m:
            return
        name = m.group(1)
        key = _canon(name)
        if key in spec_idx:
            if prefer_override:
                specs[spec_idx[key]] = clean
        else:
            spec_idx[key] = len(specs)
            specs.append(clean)
        if '==' in clean:
            lhs, rhs = clean.split('==', 1)
            lhs = lhs.split('[', 1)[0].strip()
            rhs = rhs.split(';', 1)[0].strip()
            if lhs and rhs:
                if key in pin_idx:
                    if prefer_override:
                        pinned[pin_idx[key]] = (lhs, rhs)
                else:
                    pin_idx[key] = len(pinned)
                    pinned.append((lhs, rhs))

    if tree:
        root = Path(tree)
        for rel in REQUIREMENT_FILES:
            fp = root.joinpath(*rel.split('/'))
            if not fp.is_file():
                continue
            try:
                text = fp.read_text(encoding='utf-8')
            except OSError:
                continue
            for raw_line in text.splitlines():
                line = raw_line.split('#', 1)[0].strip()
                _record(line, prefer_override=True)

    for fallback in FALLBACK_PYTHON_SPECS:
        _record(fallback, prefer_override=False)

    tools = REQUIRED_BUILD_TOOLS_WIN if win else REQUIRED_BUILD_TOOLS_POSIX
    for tool in tools:
        _record(tool, prefer_override=False)

    return specs, pinned


def venv_dir(tree: str | os.PathLike[str]) -> Path:
    return Path(tree) / '.venv'


def venv_python(tree: str | os.PathLike[str], *, is_windows: bool | None = None) -> Path:
    win = _is_win(is_windows)
    base = venv_dir(tree)
    return (base / 'Scripts' / 'python.exe') if win else (base / 'bin' / 'python3')


def required_build_tools(*, is_windows: bool | None = None) -> tuple[str, ...]:
    return REQUIRED_BUILD_TOOLS_WIN if _is_win(is_windows) else REQUIRED_BUILD_TOOLS_POSIX


def missing_venv_build_tools(
    python_exe: str | os.PathLike[str],
    *,
    is_windows: bool | None = None,
) -> list[str]:
    win = _is_win(is_windows)
    tools = required_build_tools(is_windows=win)
    if not python_exe:
        return list(tools)
    bin_dir = Path(python_exe).parent
    missing: list[str] = []
    for tool in tools:
        name = f'{tool}.exe' if win else tool
        cand = bin_dir / name
        if not cand.is_file():
            missing.append(tool)
        elif not win and not os.access(cand, os.X_OK):
            missing.append(tool)
    return missing


def is_venv_ready(
    tree: str | os.PathLike[str],
    *,
    is_windows: bool | None = None,
    py_runner: Callable[[list[str]], tuple[int, str]] | None = None,
) -> bool:
    from . import s2arm_builder

    win = _is_win(is_windows)
    vpy = venv_python(tree, is_windows=win)
    if not vpy.is_file():
        return False
    if not win and not os.access(vpy, os.X_OK):
        return False
    if s2arm_builder.missing_python_packages(str(vpy), tree=str(tree), runner=py_runner):
        return False
    return not missing_venv_build_tools(vpy, is_windows=win)


def ensure_s2arm_venv(
    tree: str | os.PathLike[str],
    base_python: str,
    *,
    is_windows: bool | None = None,
    env: Mapping[str, str] | None = None,
    runner: Callable[..., tuple[int, str]] | None = None,
    py_runner: Callable[[list[str]], tuple[int, str]] | None = None,
    on_line: Callable[[str], None] | None = None,
) -> tuple[bool, bool, str, str]:
    """Create or align `<s2arm>/.venv` to S2Arm's exact pinned requirements + build tools."""
    win = _is_win(is_windows)
    vdir = venv_dir(tree)
    vpy = venv_python(tree, is_windows=win)
    if is_venv_ready(tree, is_windows=win, py_runner=py_runner):
        return True, True, str(vpy), ''

    run_env = env_with_git_proxy_safety(env)
    logs: list[str] = []

    if not vpy.is_file():
        interp = base_python or sys.executable
        rc_v, out_v = _run_cmd(
            [interp, '-m', 'venv', str(vdir)],
            cwd=str(tree),
            env=run_env,
            runner=runner,
            on_line=on_line,
        )
        if out_v:
            logs.append(out_v)
        if rc_v != 0:
            return False, False, str(vpy), '\n'.join(logs)

    specs, _ = parse_requirement_pins(tree, is_windows=win)
    rc_pip, out_pip = _run_cmd(
        [str(vpy), '-m', 'pip', 'install', '--upgrade-strategy', 'only-if-needed', *specs],
        cwd=str(tree),
        env=run_env,
        runner=runner,
        on_line=on_line,
    )
    if out_pip:
        logs.append(out_pip)
    ready = rc_pip == 0 and is_venv_ready(tree, is_windows=win, py_runner=py_runner)
    return ready, False, str(vpy), '\n'.join(logs)


# ---------------------------------------------------------------------------
# 3. .NET 10 SDK auto-install (macOS/Linux + Windows)
# ---------------------------------------------------------------------------

def ensure_dotnet_for_s2arm(
    tree: str | os.PathLike[str],
    *,
    is_windows: bool | None = None,
    env: Mapping[str, str] | None = None,
    runner: Callable[..., tuple[int, str]] | None = None,
    dotnet_probe_runner: Callable[[list[str], dict[str, str]], tuple[int, str]] | None = None,
    on_line: Callable[[str], None] | None = None,
) -> tuple[str, bool, str]:
    from . import s2arm_builder

    win = _is_win(is_windows)
    dn, ok, req_ver, _ = s2arm_builder.find_dotnet_for_s2arm(
        tree=str(tree),
        runner=dotnet_probe_runner,
        is_windows=win,
    )
    if ok:
        return dn, True, ''

    run_env = env_with_git_proxy_safety(env)
    if win:
        ps_cmd = (
            "$ProgressPreference='SilentlyContinue'; "
            "$p=Join-Path $env:TEMP 'dotnet-install.ps1'; "
            "Invoke-WebRequest -UseBasicParsing -Uri 'https://dot.net/v1/dotnet-install.ps1' -OutFile $p; "
            "& $p -Channel 10.0 -InstallDir (Join-Path $env:LOCALAPPDATA 'Microsoft\\dotnet') -NoPath"
        )
        argv = ['powershell', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', ps_cmd]
    else:
        sh_cmd = (
            'curl -fsSL https://dot.net/v1/dotnet-install.sh | '
            'bash -s -- --channel 10.0 --install-dir "$HOME/.dotnet" --no-path'
        )
        argv = ['/bin/bash', '-c', sh_cmd]

    _, out = _run_cmd(argv, env=run_env, runner=runner, on_line=on_line)
    dn2, ok2, _, _ = s2arm_builder.find_dotnet_for_s2arm(
        tree=str(tree),
        runner=dotnet_probe_runner,
        is_windows=win,
    )
    return dn2, ok2, (out if not ok2 else '')


# ---------------------------------------------------------------------------
# 4. `<s2arm>/build/rewriter-deps` auto-preparation
# ---------------------------------------------------------------------------

def rewriter_deps_dir(tree: str | os.PathLike[str]) -> Path:
    return Path(tree) / 'build' / 'rewriter-deps'


def is_rewriter_deps_ready(tree: str | os.PathLike[str]) -> bool:
    deps = rewriter_deps_dir(tree)
    return (
        deps.joinpath('capstone-5.0.7', 'src', 'CMakeLists.txt').is_file()
        and deps.joinpath('lz4-4.4.5', 'lz4libs', 'lz4.c').is_file()
    )


def ensure_rewriter_deps(
    tree: str | os.PathLike[str],
    python_exe: str,
    *,
    env: Mapping[str, str] | None = None,
    runner: Callable[..., tuple[int, str]] | None = None,
    on_line: Callable[[str], None] | None = None,
) -> tuple[bool, bool, str, str]:
    root = Path(tree)
    deps = rewriter_deps_dir(root)
    if is_rewriter_deps_ready(root):
        return True, True, str(deps), ''
    script = root / 'runtime' / 'rewriter' / 'prepare_deps.py'
    if not script.is_file():
        return True, True, '', ''
    if deps.exists():
        shutil.rmtree(deps, ignore_errors=True)
    deps.parent.mkdir(parents=True, exist_ok=True)
    run_env = env_with_git_proxy_safety(env)
    rc, out = _run_cmd(
        [python_exe, str(script), str(deps)],
        cwd=str(root),
        env=run_env,
        runner=runner,
        on_line=on_line,
    )
    ok = rc == 0 and is_rewriter_deps_ready(root)
    return ok, False, (str(deps) if ok else ''), out


# ---------------------------------------------------------------------------
# 5. POSIX modern GNU Bash (>= 4) & macOS SPIRV / pinned zstd 1.5.7 tools
# ---------------------------------------------------------------------------

def managed_bash_path(home: str | os.PathLike[str] | None = None) -> Path:
    base = Path(home) if home is not None else Path.home()
    if sys.platform == 'darwin':
        return base / 'Library' / 'Application Support' / 'NX2Apple' / 'tools' / 'bin' / 'bash'
    return base / '.local' / 'share' / 'nx2apple' / 'tools' / 'bin' / 'bash'


def bash_major_version(
    bash_path: str | os.PathLike[str],
    *,
    runner: Callable[..., tuple[int, str]] | None = None,
) -> int | None:
    if not bash_path:
        return None
    rc, out = _run_cmd(
        [str(bash_path), '-c', 'echo "${BASH_VERSINFO[0]}"'],
        env={'PATH': '/usr/bin:/bin'},
        timeout=15.0,
        runner=runner,
    )
    if rc != 0:
        return None
    first = (out.splitlines()[0].strip() if out.splitlines() else '')
    try:
        return int(first)
    except ValueError:
        return None


def find_modern_bash(
    *,
    candidates: list[str] | None = None,
    home: str | os.PathLike[str] | None = None,
    runner: Callable[..., tuple[int, str]] | None = None,
    exists: Callable[[str], bool] | None = None,
) -> str | None:
    cands = candidates if candidates is not None else [
        str(managed_bash_path(home)),
        '/opt/homebrew/bin/bash',
        '/usr/local/bin/bash',
        '/bin/bash',
    ]
    check_exists = exists or (lambda p: Path(p).is_file() and os.access(p, os.X_OK))
    for cand in cands:
        if not cand or not check_exists(cand):
            continue
        major = bash_major_version(cand, runner=runner)
        if major is not None and major >= 4:
            return cand
    return None


def _bash_build_script(install_target: str) -> str:
    quoted = "'" + install_target.replace("'", "'\\''") + "'"
    return (
        'set -euo pipefail\n'
        'WORK="$(mktemp -d /tmp/nx2apple-bash5-XXXXXX)"\n'
        'trap \'rm -rf "$WORK"\' EXIT\n'
        f'TAR="$WORK/bash-{BASH_VERSION}.tar.gz"\n'
        f'if ! curl -fsSL --retry 2 --connect-timeout 20 \'{BASH_TARBALL_PRIMARY}\' -o "$TAR"; then\n'
        f'  curl -fsSL --retry 2 --connect-timeout 20 \'{BASH_TARBALL_FALLBACK}\' -o "$TAR"\n'
        'fi\n'
        'tar -xzf "$TAR" -C "$WORK"\n'
        f'cd "$WORK/bash-{BASH_VERSION}"\n'
        './configure --without-bash-malloc --disable-nls\n'
        'make -j8\n'
        f'MAJOR="$("$WORK/bash-{BASH_VERSION}/bash" -c \'echo "${{BASH_VERSINFO[0]}}"\')"\n'
        '[ -n "$MAJOR" ] && [ "$MAJOR" -ge 4 ]\n'
        f'TARGET={quoted}\n'
        'mkdir -p "$(dirname "$TARGET")"\n'
        'TMP_BIN="$(dirname "$TARGET")/.bash.tmp.$$"\n'
        f'cp "$WORK/bash-{BASH_VERSION}/bash" "$TMP_BIN"\n'
        'chmod 0755 "$TMP_BIN"\n'
        'mv -f "$TMP_BIN" "$TARGET"\n'
    )


def ensure_modern_bash(
    *,
    home: str | os.PathLike[str] | None = None,
    candidates: list[str] | None = None,
    env: Mapping[str, str] | None = None,
    runner: Callable[..., tuple[int, str]] | None = None,
    on_line: Callable[[str], None] | None = None,
) -> str | None:
    found = find_modern_bash(candidates=candidates, home=home, runner=runner)
    if found:
        return found
    target = str(managed_bash_path(home))
    run_env = env_with_git_proxy_safety(env)
    rc, _ = _run_cmd(['/bin/bash', '-c', _bash_build_script(target)], env=run_env, runner=runner, on_line=on_line)
    if rc != 0:
        return None
    return find_modern_bash(candidates=[target], home=home, runner=runner)


def link_bash_shim(modern_bash: str, tree: str | os.PathLike[str]) -> str | None:
    if not modern_bash or not tree:
        return None
    shim_dir = Path(tree) / '.nx2apple-shims'
    link = shim_dir / 'bash'
    try:
        shim_dir.mkdir(parents=True, exist_ok=True)
        if link.exists() or link.is_symlink():
            link.unlink()
        link.symlink_to(modern_bash)
        return str(shim_dir)
    except OSError:
        return None


def runtime_tools_prefix(tree: str | os.PathLike[str]) -> Path:
    return Path(tree) / 'build' / 'macos' / 'runtime-sources' / 'tools'


def is_runtime_tools_prefix_ready(prefix: str | os.PathLike[str]) -> bool:
    p = Path(prefix)
    for name in REQUIRED_RUNTIME_TOOLS_POSIX:
        bin_path = p / 'bin' / name
        if not bin_path.is_file() or not os.access(bin_path, os.X_OK):
            return False
    return (p / 'lib' / 'libzstd.1.dylib').is_file()


def _adjacent_zstd_lib(zstd_bin: str) -> str | None:
    for cand in (Path(zstd_bin), Path(os.path.realpath(zstd_bin))):
        lib = cand.parent.parent / 'lib' / 'libzstd.1.dylib'
        if lib.is_file():
            return str(lib)
    return None


def inspect_system_runtime_tools(
    path_env: str,
    *,
    runner: Callable[..., tuple[int, str]] | None = None,
) -> tuple[bool, str | None]:
    dirs = [d for d in path_env.split(os.pathsep) if d]
    found_zstd: str | None = None
    all_found = True
    for tool in REQUIRED_RUNTIME_TOOLS_POSIX:
        hit = None
        for d in dirs:
            cand = Path(d) / tool
            if cand.is_file() and os.access(cand, os.X_OK):
                hit = str(cand)
                break
        if hit is None:
            all_found = False
        elif tool == 'zstd':
            found_zstd = hit
    zstd_lib = _adjacent_zstd_lib(found_zstd) if found_zstd else None
    if not all_found or not found_zstd or not zstd_lib:
        return False, zstd_lib
    rc, out = _run_cmd([found_zstd, '--version'], env={'PATH': path_env}, timeout=15.0, runner=runner)
    return (rc == 0 and 'v1.5.7' in out), zstd_lib


def ensure_runtime_tools(
    tree: str | os.PathLike[str],
    python_exe: str,
    *,
    env: Mapping[str, str] | None = None,
    runner: Callable[..., tuple[int, str]] | None = None,
    on_line: Callable[[str], None] | None = None,
) -> tuple[bool, bool, str | None, str | None, str]:
    root = Path(tree)
    default_prefix = runtime_tools_prefix(root)
    if is_runtime_tools_prefix_ready(default_prefix):
        return True, True, str(default_prefix / 'bin'), str(default_prefix / 'lib' / 'libzstd.1.dylib'), ''

    run_env = env_with_git_proxy_safety(env)
    sys_ready, sys_zstd_lib = inspect_system_runtime_tools(run_env.get('PATH', ''), runner=runner)
    if sys_ready:
        return True, True, None, sys_zstd_lib, ''

    script = root / 'launchers' / 'macos' / 'runtime_sources.py'
    if not script.is_file():
        return True, True, None, sys_zstd_lib, ''

    snippet = (
        "import sys; sys.path.insert(0, 'launchers/macos'); "
        "import runtime_sources; p, _ = runtime_sources.tools(); "
        f"print('{RUNTIME_TOOLS_MARKER}' + str(p))"
    )
    filtered_on_line = (
        (lambda line: None if line.strip().startswith(RUNTIME_TOOLS_MARKER) else on_line(line))
        if on_line is not None
        else None
    )
    rc, out = _run_cmd(
        [python_exe, '-c', snippet],
        cwd=str(root),
        env=run_env,
        runner=runner,
        on_line=filtered_on_line,
    )
    prefix = default_prefix
    for line in reversed(out.splitlines()):
        stripped = line.strip()
        if stripped.startswith(RUNTIME_TOOLS_MARKER):
            val = stripped[len(RUNTIME_TOOLS_MARKER):].strip()
            if val:
                prefix = Path(val)
                break
    ok = rc == 0 and is_runtime_tools_prefix_ready(prefix)
    if not ok:
        return False, False, None, sys_zstd_lib, out
    return True, False, str(prefix / 'bin'), str(prefix / 'lib' / 'libzstd.1.dylib'), out


# ---------------------------------------------------------------------------
# 6. Windows Git Bash & open shared fonts (7 `.bfttf` files)
# ---------------------------------------------------------------------------

def find_git_bash_windows(
    candidates: list[str] | None = None,
    *,
    exists: Callable[[str], bool] | None = None,
) -> str | None:
    check_exists = exists or (lambda p: Path(p).is_file())
    if candidates is None:
        cands = [
            r'C:\Program Files\Git\usr\bin\bash.exe',
            r'C:\Program Files (x86)\Git\usr\bin\bash.exe',
            os.path.expandvars(r'%LOCALAPPDATA%\Programs\Git\usr\bin\bash.exe'),
            r'C:\Program Files\Git\bin\bash.exe',
        ]
        found = shutil.which('bash.exe')
        if found and 'system32' not in found.lower():
            cands.append(found)
    else:
        cands = list(candidates)
    for cand in cands:
        if cand and '%' not in cand and check_exists(cand):
            return cand
    return None


def count_bfttf_fonts(fonts_dir: str | os.PathLike[str]) -> int:
    p = Path(fonts_dir)
    if not p.is_dir():
        return 0
    try:
        return sum(1 for entry in p.iterdir() if entry.is_file() and entry.suffix.lower() == '.bfttf')
    except OSError:
        return 0


def ensure_open_fonts_windows(
    tree: str | os.PathLike[str],
    python_exe: str,
    fonts_dir: str | os.PathLike[str],
    *,
    env: Mapping[str, str] | None = None,
    runner: Callable[..., tuple[int, str]] | None = None,
    on_line: Callable[[str], None] | None = None,
) -> tuple[bool, bool, str, str]:
    target = Path(fonts_dir)
    if count_bfttf_fonts(target) >= 7:
        return True, True, str(target), ''
    script = Path(tree) / 'pack' / 'fonts' / 'make_open_fonts.py'
    if not script.is_file():
        return True, True, '', ''
    target.mkdir(parents=True, exist_ok=True)
    run_env = env_with_git_proxy_safety(env)
    rc, out = _run_cmd(
        [python_exe, str(script), str(target)],
        cwd=str(tree),
        env=run_env,
        runner=runner,
        on_line=on_line,
    )
    ok = rc == 0 and count_bfttf_fonts(target) >= 7
    return ok, False, (str(target) if ok else ''), out
