"""Per-OS paths, tool discovery and process launching.

Everything the UI needs that differs between Windows and macOS lives here, so the model and
the window never branch on sys.platform themselves.
"""
from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

IS_WIN = sys.platform.startswith('win')
IS_MAC = sys.platform == 'darwin'

#: The build script's own floor: `build_ipa_from_nsp.py` raises below 3.12 for a direct RomFS
#: image build, and its f-strings do not parse on 3.9. `/usr/bin/python3` is 3.9 on a stock Mac,
#: and pip-installing into it produced a build that died inside the script (issue #53 in the
#: SwiftUI front end) instead of a row that said why.
MIN_PYTHON = (3, 12)


# ---------------------------------------------------------------- tool discovery

def _which(name: str, extra: list[str] | None = None) -> str | None:
    """shutil.which plus a list of absolute candidates (a GUI launch does not inherit the
    shell's PATH on either OS, so the usual install locations are probed by hand)."""
    if found := shutil.which(name):
        return found
    for c in extra or []:
        if c and Path(c).is_file() and os.access(c, os.X_OK):
            return c
    return None


def uv_pythons() -> list[str]:
    """The interpreters `uv python install` manages.

    uv downloads its own Pythons into a store (`~/.local/share/uv/python`, or
    `UV_PYTHON_INSTALL_DIR`) and links shims into `~/.local/bin`. Neither directory is on a GUI
    process's PATH and neither was in the probe list, so a uv user with a working 3.12 and the
    packages was told no interpreter had been found. Windows keeps the store under
    `%LOCALAPPDATA%\\uv\\python` and puts the exe straight in the install folder.
    """
    # The interpreter itself, not `python3-config` and friends that share the prefix.
    name_re = re.compile(r'^python(3(\.\d+)?)?\.exe$' if IS_WIN else r'^python3(\.\d+)?$')

    def named(d: Path, pattern: str) -> list[str]:
        return sorted(str(p) for p in d.glob(pattern) if name_re.match(p.name))

    out: list[str] = []
    home = Path.home()
    shim_dir = home / '.local' / 'bin'
    if shim_dir.is_dir():
        out += named(shim_dir, 'python*.exe' if IS_WIN else 'python3*')
    local = Path(os.environ.get('LOCALAPPDATA', str(home / 'AppData' / 'Local')))
    roots = [os.environ.get('UV_PYTHON_INSTALL_DIR') or '',
             str(local / 'uv' / 'python') if IS_WIN else str(home / '.local' / 'share' / 'uv' / 'python')]
    for root in roots:
        if not root or not Path(root).is_dir():
            continue
        for install in sorted(Path(root).iterdir(), reverse=True):
            if install.is_dir():
                out += named(install if IS_WIN else install / 'bin',
                             'python*.exe' if IS_WIN else 'python3*')
    return out


def version_manager_pythons() -> list[str]:
    """The interpreters mise and asdf manage (issue #113).

    mise keeps its installs in `~/.local/share/mise` (`MISE_DATA_DIR`) with shims in `shims/`,
    asdf in `~/.asdf` (`ASDF_DATA_DIR`). A GUI process's PATH has neither. asdf's shims are
    scripts that need `asdf` on the PATH, so only its installs are probed. Not on Windows.
    """
    if IS_WIN:
        return []
    # The interpreter itself, not `python3-config` and friends that share the folder.
    name_re = re.compile(r'^python3(\.\d+)?$')

    def newest_first(paths) -> list:
        return sorted(paths, key=lambda n: [int(x) if x.isdigit() else 0
                                            for x in re.split(r'(\d+)', Path(n).name)], reverse=True)

    def named(d: Path) -> list[str]:
        if not d.is_dir():
            return []
        return newest_first(str(p) for p in d.iterdir() if name_re.match(p.name))

    home = Path.home()
    mise = Path(os.environ.get('MISE_DATA_DIR') or home / '.local' / 'share' / 'mise')
    asdf = Path(os.environ.get('ASDF_DATA_DIR') or home / '.asdf')
    out: list[str] = []
    for root in (mise / 'installs' / 'python', asdf / 'installs' / 'python'):
        if root.is_dir():
            for install in newest_first(root.iterdir()):
                out += named(install / 'bin')
    return out + named(mise / 'shims')


def python_candidates(extra_candidates: list[str] | None = None) -> list[str]:
    """Every interpreter a build could run under, best first.

    The app's own venv, then whatever the caller passes (the interpreter the app installed for
    itself, which a machine with no system Python is exactly the one that has to be found again),
    then the platform's usual installs, uv's store, mise and asdf, and last what `which` can see — which, in a
    GUI launch, is next to nothing.
    """
    cands: list[str] = [venv_python()] + [c for c in (extra_candidates or []) if c]
    if IS_WIN:
        cands += [
            os.path.expandvars(r'%LOCALAPPDATA%\Programs\Python\Python312\python.exe'),
            os.path.expandvars(r'%LOCALAPPDATA%\Programs\Python\Python311\python.exe'),
            os.path.expandvars(r'%ProgramFiles%\Python312\python.exe'),
        ]
    else:
        fw = '/Library/Frameworks/Python.framework/Versions'
        if Path(fw).is_dir():
            for v in sorted(os.listdir(fw), reverse=True):
                cands.append(f'{fw}/{v}/bin/python3')
        cands += ['/opt/homebrew/bin/python3', '/usr/local/bin/python3', '/usr/bin/python3']
        cands += uv_pythons()
        cands += version_manager_pythons()
    if w := _which('python3' if not IS_WIN else 'python'):
        cands.append(w)
    return cands


def find_python(extra_candidates: list[str] | None = None) -> tuple[str, bool, str]:
    """The interpreter to build with: (path, has_packages, version_or_empty).

    The build scripts need lz4, capstone, fontTools, zbic, zstd and (for compressed dumps) nsz. A
    system interpreter rarely has them, so the venv the app manages is checked first, then
    every python on the machine (see python_candidates for the order).
    """
    probe = (
        "import lz4, capstone, fontTools, zbic\n"
        "try:\n"
        "    from compression import zstd\n"
        "except ImportError:\n"
        "    from backports import zstd\n"
    )

    ready: tuple[str, str] | None = None     # newest that already has the packages
    fallback: tuple[str, str] | None = None  # newest that runs at all: 安装 finishes it
    old_venv: tuple[str, str] | None = None  # the app's venv when it is below the floor
    seen: set[str] = set()
    for c in python_candidates(extra_candidates):
        if not c or c in seen or not Path(c).is_file():
            continue
        seen.add(c)
        ver = _python_version(c)
        if ver and _ver_tuple(ver) < MIN_PYTHON and c == venv_python():
            old_venv = (c, ver)
        if not ver or _ver_tuple(ver) < MIN_PYTHON:
            continue
        if _runs(c, ['-c', probe]):
            if ready is None or _ver_tuple(ver) > _ver_tuple(ready[1]):
                ready = (c, ver)
        elif fallback is None or _ver_tuple(ver) > _ver_tuple(fallback[1]):
            fallback = (c, ver)
    if ready:
        return (ready[0], True, ready[1])
    if fallback:
        return (fallback[0], False, fallback[1])
    if old_venv:
        return (old_venv[0], False, old_venv[1])   # the row says which version is too old
    return ('python' if IS_WIN else '/usr/bin/python3', False, '')


def venv_base(preferred: str) -> str | None:
    """The interpreter to create the app's venv from, or None when the machine has none.

    `preferred` is what the panel picked; when find_python() found nothing that is `/usr/bin/
    python3` (3.9, below MIN_PYTHON) or the venv path it hopes to create — neither can run
    `-m venv`, and the Python row never recovered from it. So a base that does not run at the
    required version falls back to the newest candidate that does.
    """
    if Path(preferred).is_file() and os.access(preferred, os.X_OK):
        v = _python_version(preferred)
        if v and _ver_tuple(v) >= MIN_PYTHON:
            return preferred
    best: tuple[str, str] | None = None
    for c in python_candidates():
        if not c or not Path(c).is_file() or not os.access(c, os.X_OK):
            continue
        v = _python_version(c)
        if not v or _ver_tuple(v) < MIN_PYTHON:
            continue
        if best is None or _ver_tuple(v) > _ver_tuple(best[1]):
            best = (c, v)
    return best[0] if best else None


def _python_version(py: str) -> str:
    try:
        r = subprocess.run([py, '-c', 'import sys;print("%d.%d"%sys.version_info[:2])'],
                           capture_output=True, text=True, timeout=20)
        return r.stdout.strip() if r.returncode == 0 else ''
    except Exception:
        return ''


def _ver_tuple(v: str) -> tuple[int, int]:
    parts = v.split('.')
    try:
        return (int(parts[0]), int(parts[1]))
    except (IndexError, ValueError):
        return (0, 0)


def _runs(exe: str, args: list[str]) -> bool:
    try:
        return subprocess.run([exe] + args, capture_output=True, timeout=120).returncode == 0
    except Exception:
        return False


def venv_dir() -> Path:
    if IS_WIN:
        base = Path(os.environ.get('LOCALAPPDATA', Path.home() / 'AppData' / 'Local'))
    else:
        base = Path.home() / 'Library' / 'Application Support'
    return base / 'NS Port Builder' / 'venv'


def venv_python() -> str:
    v = venv_dir()
    return str(v / ('Scripts/python.exe' if IS_WIN else 'bin/python3'))


# ---------------------------------------------------------------- dotnet

def find_dotnet() -> tuple[str, bool]:
    cands = []
    if IS_WIN:
        cands += [r'C:\Program Files\dotnet\dotnet.exe',
                  os.path.expandvars(r'%LOCALAPPDATA%\Microsoft\dotnet\dotnet.exe')]
    else:
        cands += [str(Path.home() / '.dotnet' / 'dotnet'),
                  '/usr/local/share/dotnet/dotnet',
                  '/opt/homebrew/bin/dotnet']
    path = _which('dotnet', cands) or ('dotnet.exe' if IS_WIN else 'dotnet')
    ok = _runs(path, ['--list-sdks'])
    return (path, ok)


def dotnet_root(dotnet: str) -> str | None:
    """The runtime root the apphost looks for, from `dotnet --list-runtimes`.

    A set-but-wrong DOTNET_ROOT is worse than none (the apphost stops searching), so this
    returns None when the derivation does not answer and the caller leaves the variable out —
    the build script derives and verifies its own in that case.
    """
    try:
        r = subprocess.run([dotnet, '--list-runtimes'], capture_output=True, text=True, timeout=60)
        if r.returncode != 0:
            return None
    except Exception:
        return None
    for ln in r.stdout.splitlines():
        if not ln.startswith('Microsoft.NETCore.App'):
            continue
        if '[' in ln and ']' in ln:
            p = ln[ln.rfind('[') + 1:ln.rfind(']')]
        else:
            continue
        suffix = os.sep + os.path.join('shared', 'Microsoft.NETCore.App')
        if p.endswith(suffix):
            return p[:-len(suffix)]
        if p:
            return p
    return None


# ---------------------------------------------------------------- external tools

def find_tool(name: str) -> str | None:
    """xcodegen / zstd / spirv-cross / metal, by the usual locations per OS."""
    if IS_WIN:
        extra = [rf'C:\Program Files\{name}\{name}.exe',
                 rf'C:\ProgramData\chocolatey\bin\{name}.exe']
        return _which(name + '.exe', extra)
    return _which(name, [f'/opt/homebrew/bin/{name}', f'/usr/local/bin/{name}'])


def metal_toolchain_ok() -> bool:
    """Whether a Metal compiler answers. On Windows that is Apple's Metal Developer Tools
    (metal.exe + metallib.exe); on macOS it is xcrun's."""
    if IS_WIN:
        return find_tool('metal') is not None and find_tool('metallib') is not None
    return _runs('/usr/bin/xcrun', ['-sdk', 'macosx', 'metal', '--version'])


def ios_sdk_ok() -> bool:
    if IS_WIN:
        # The Windows path uses an iPhoneOS SDK extracted from an archive, located by the
        # caller (the WebUI does the same); presence of the directory is the check.
        return bool(os.environ.get('IPHONEOS_SDK_DIR') and Path(os.environ['IPHONEOS_SDK_DIR']).is_dir())
    return _runs('/usr/bin/xcrun', ['--sdk', 'iphoneos', '--show-sdk-version'])


def xcode_developer_dir() -> str:
    """The selected developer directory (`xcode-select -p`), or '' when none is selected.

    Asked rather than assumed: an Xcode **beta** lives at /Applications/Xcode-beta.app, and the
    hard-coded /Applications/Xcode.app check reported "no Xcode" to anyone whose only install is
    a beta (issue #21). `xcode-select` is the same source of truth xcodebuild and xcrun use, so
    agreeing with it is what makes the panel match what the build will actually do.
    """
    if IS_WIN:
        return ''
    try:
        r = subprocess.run(['/usr/bin/xcode-select', '-p'], capture_output=True, text=True,
                           timeout=30)
    except (OSError, subprocess.SubprocessError):
        return ''
    return (r.stdout or '').strip() if r.returncode == 0 else ''


def xcode_ok() -> bool:
    if IS_WIN:
        return False        # Xcode is macOS-only; Windows uses the cross toolchain instead
    # A selected developer directory that exists is the real condition: it covers Xcode.app,
    # Xcode-beta.app, a custom location, and a Command Line Tools-only setup (which selects
    # /Library/Developer/CommandLineTools and has no xcodebuild-driven iOS build at all — that
    # case is caught by the iOS SDK probe below, which is what the row reports).
    dev = xcode_developer_dir()
    if not dev or not Path(dev).is_dir():
        return False
    return Path('/usr/bin/xcodebuild').is_file()


# ---------------------------------------------------------------- process helpers

def child_env(extra: dict[str, str] | None = None) -> dict[str, str]:
    """The environment every child process gets: a PATH with the usual tool directories,
    HOME/USER present (a GUI launch can strip them), and DOTNET_CLI_HOME so .NET's first-run
    state has somewhere to go."""
    env = dict(os.environ)
    dirs = [env.get('PATH', '')]
    if IS_WIN:
        dirs += [r'C:\Program Files\dotnet', os.path.expandvars(r'%LOCALAPPDATA%\Microsoft\dotnet')]
        sep = ';'
    else:
        dirs += ['/opt/homebrew/bin', '/usr/local/bin', '/usr/bin', '/bin']
        sep = ':'
    env['PATH'] = sep.join(d for d in dirs if d)
    if not env.get('HOME') or not Path(env['HOME']).is_dir():
        env['HOME'] = str(Path.home())
    env.setdefault('USER', os.environ.get('USERNAME') or os.environ.get('USER') or 'user')
    env.setdefault('DOTNET_CLI_HOME', env['HOME'])
    # No first-run banner, no telemetry (issue #10's question): the deps panel runs `dotnet
    # --list-sdks` directly, outside the build script where the same two lines are set. The
    # telemetry call can hang the very first run on a network that cannot reach Microsoft.
    env.setdefault('DOTNET_CLI_TELEMETRY_OPTOUT', '1')
    env.setdefault('DOTNET_NOLOGO', '1')
    if extra:
        env.update(extra)
    return env


def short_path(p: str) -> str:
    """Home shown as ~ (keeps the account name out of screenshots)."""
    home = str(Path.home())
    return '~' + p[len(home):] if p.startswith(home) else p


def no_window_kwargs() -> dict:
    """Hide the console window a child process would otherwise flash on Windows."""
    if IS_WIN:
        return {'creationflags': subprocess.CREATE_NO_WINDOW}
    return {}


def hide_console_for_children() -> None:
    """Stop *every* child this process starts from opening a console window (Windows only).

    Called once at start-up. Per-call `creationflags` cannot be added everywhere: the build runs
    the repository's own Python scripts as children, and those scripts start clang, git, lld and
    zip themselves — dozens of call sites in files this front end does not own. A windowed app has
    no console, so each of those children got a fresh black window, and on a handheld the report
    was "a command-line window appears, shows nothing, and the install stops moving" — the window
    was git's, and it was stealing the foreground while the download ran behind it.

    A child created with CREATE_NO_WINDOW still gets a console, just no window, and its own
    children inherit that invisible console — which is why patching at the boundary is enough to
    cover the whole tree.

    A caller that passes its own `creationflags` keeps them: DETACHED_PROCESS and
    CREATE_NEW_CONSOLE mean something, and silently overriding them would break that intent.
    """
    if not IS_WIN:
        return
    original = subprocess.Popen.__init__

    def patched(self, args, *a, **k):        # noqa: ANN001 - mirrors Popen.__init__
        if not k.get('creationflags') and not k.get('startupinfo'):
            k['creationflags'] = subprocess.CREATE_NO_WINDOW
        original(self, args, *a, **k)

    subprocess.Popen.__init__ = patched       # type: ignore[method-assign]
