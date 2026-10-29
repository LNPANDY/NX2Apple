"""State, dependency detection and the build runner. No UI here: the window connects to signals."""
from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
import threading
import time
from collections.abc import Callable
from dataclasses import dataclass, field
from enum import Enum
from pathlib import Path

from PySide6.QtCore import QSettings, Q_ARG, QMetaObject, QObject, Qt, QThread, Signal, Slot

from . import build_failure as bf
from . import input_staging
from . import platform_util as pu
from .i18n import Lang
from .localization import t


# ---------------------------------------------------------------- dependency rows

class DepState(Enum):
    OK = 'ok'
    MISSING = 'missing'
    OLD = 'old'          # present but unusable (a too-old interpreter, a stub launcher)


@dataclass
class Dep:
    id: str
    title_key: str
    hint_key: str
    state: DepState = DepState.MISSING
    detail: str = ''            # a path, or a localisation key, or "key:arg"
    install: list[str] = field(default_factory=list)   # command that fixes it, empty = manual
    installing: bool = False
    required: bool = True       # a missing optional row (spirv-cross for Metal games, glslangValidator)
                                # is not part of "缺 N 项": it does not stop the build in front of you
    pick_key: str = ''          # a manual row the user can point at a folder ('ios_sdk', 'metal_dir'):
                                # the panel grows a Choose button; the pick is validated and remembered
    fix_hint: str = ''          # an L10n key set when this row's install failed: what to do next
    last_error: str = ''        # the tool's own last error line, shown under the row (Mac parity)

    @property
    def ok(self) -> bool:
        return self.state is DepState.OK


# ---------------------------------------------------------------- build stages

@dataclass
class Stage:
    name: str
    state: str = 'pending'      # pending | running | done | failed
    detail: str = ''
    percent: float = 0.0


# ---------------------------------------------------------------- the model

class Model(QObject):
    """Everything the window reads, and every action it can take.

    Long work runs on a thread and reports through signals, so the window never blocks: Qt
    requires UI updates on the main thread, and a build takes minutes.
    """

    depsChanged = Signal()
    stagesChanged = Signal()
    logAppended = Signal(str)
    repoChanged = Signal()
    runningChanged = Signal(bool)
    finished = Signal(bool, str)          # ok, note
    appUpdateFound = Signal(str, str)     # tag, url

    #: Set by the window: asks for a folder (QFileDialog lives in the UI layer) and returns the
    #: path, or '' when the user cancelled. `pick_dep_folder` calls it, so the model stays UI-free.
    ask_folder: Callable[[str], str] | None = None

    def __init__(self) -> None:
        super().__init__()
        self.settings = QSettings('NS Port Builder', 'NSPortBuilder')
        self.lang = Lang.initial()
        self.repo_path = self._find_repo()
        self.python_path, self.python_ok, self.python_ver = pu.find_python()
        self.dotnet_path, self.dotnet_ok = pu.find_dotnet()
        self.deps: list[Dep] = []
        self.deps_checked = False
        self.stages: list[Stage] = []
        self.running = False
        self.log_tail = ''
        self.failure: bf.Failure | None = None   # the script's known early stop (build_failure.py), None for any other
        self.override = bf.OverrideState()      # "Build anyway": one confirmed --allow-* for the next build
        self._last_error = ''   # the last real log line: the failure note names it (issue #52)
        self.game_dir = ''
        self.base_path = ''
        self.update_path = ''
        self.dlc_paths: list[str] = []
        self.keys_path = ''
        self.out_dir = ''
        self.ipa_path = ''
        self.archive_path = ''
        self.mac_app_path = ''
        self.target = 'ios'   # 'ios' (an IPA) or 'mac-app' (a double-clickable Mac app; macOS only)
        self.repo_busy = False
        self.repo_behind: int | None = None
        self.repo_status = ''
        self._proc: subprocess.Popen | None = None
        self._thread: threading.Thread | None = None
        self._line_buf = ''
        # Every log line also goes to a file, so a user on a handheld can send one file instead of
        # copying text out of the window. One file per run, overwritten at start; the path is shown
        # in the log's first line so it can be found.
        try:
            # LOCALAPPDATA is set on every normal Windows session, but a stripped environment
            # (a service, a scheduled task, this project's own test harness) may lack it: fall
            # back to the home directory rather than failing to start over a log file.
            if pu.IS_WIN:
                root = Path(os.environ.get('LOCALAPPDATA') or (Path.home() / 'AppData' / 'Local'))
                base = root / 'NS Port Builder' / 'logs'
            else:
                base = Path.home() / 'Library' / 'Logs' / 'NS Port Builder'
            base.mkdir(parents=True, exist_ok=True)
            self.log_path = base / 'last-run.log'
            self.log_path.write_text('', encoding='utf-8')
        except OSError:
            self.log_path = None

    # ---- strings

    def t(self, key: str, *args: object) -> str:
        return t(key, self.lang, *args)

    def settings_value(self, key: str, default: bool | None = None) -> bool | None:
        v = self.settings.value(key, defaultValue='', type=str)
        return default if v == '' else v.lower() == 'true'

    def settings_set(self, key: str, value: bool) -> None:
        self.settings.setValue(key, 'true' if value else 'false')

    def toggle_lang(self) -> None:
        self.lang = self.lang.other
        self.repoChanged.emit()
        self.depsChanged.emit()

    # ---- repository

    @staticmethod
    def is_repo(d: str) -> bool:
        return bool(d) and Path(d, 'dm', 'tools', 'nx_extract', 'Program.cs').is_file()

    def _find_repo(self) -> str:
        saved = os.environ.get('NSPB_REPO', '')
        if self.is_repo(saved):
            return saved
        seeds = [Path.cwd(), Path(__file__).resolve().parents[2], Path.home()]
        for base in ('Documents', 'Desktop', ''):
            seeds.append(Path.home() / base / 'NX2Apple' if base else Path.home() / 'NX2Apple')
        for s in seeds:
            d = Path(s)
            for _ in range(4):
                if self.is_repo(str(d)):
                    return str(d)
                if d.parent == d:
                    break
                d = d.parent
        return ''

    @property
    def repo_ok(self) -> bool:
        return self.is_repo(self.repo_path)

    @property
    def repo_is_git(self) -> bool:
        return bool(self.repo_path) and Path(self.repo_path, '.git').exists()

    def supports_work_dir(self) -> bool:
        """Whether the checkout's build script declares --work-dir (an upstream checkout or an
        old ZIP does not; passing it there stops at argparse — issue #5)."""
        f = Path(self.repo_path, 'scripts', 'build_ipa_from_nsp.py')
        try:
            text = f.read_text(encoding='utf-8', errors='replace')
        except OSError:
            return False
        return "'--work-dir'" in text or '"--work-dir"' in text

    # ---- dependencies

    def check_deps(self) -> None:
        self.deps_checked = False
        threading.Thread(target=self._check_deps_worker, daemon=True).start()

    def _check_deps_worker(self) -> None:
        """Build the dependency rows off the UI thread.

        Any exception has to leave the panel in a finished state: an unhandled one killed this
        thread while `deps_checked` stayed False, so the panel sat on "Checking…" forever and the
        handheld report read "Check again does nothing". A failed check now says so.
        """
        try:
            self._check_deps()
        except Exception as e:                     # noqa: BLE001 - a check must never be fatal
            import traceback
            self.log(f'dependency check failed: {type(e).__name__}: {e}\n')
            self.log(traceback.format_exc() + '\n')
            self.deps = []
            self.deps_checked = True
            self.depsChanged.emit()

    def _python_row(self, py: str, py_ok: bool, py_ver: str) -> Dep:
        """The interpreter row: fine, missing packages, missing interpreter, or too old.

        "Too old" is wrong when the machine has no interpreter at all — the report's handheld
        fails `python3 --version`, and the old two-placeholder string rendered with one argument
        put a literal %@ on screen. A missing interpreter is its own state, and on Windows its
        fix is the in-app installer.
        """
        if py_ok:
            return Dep('python', 'dep.python', 'dep.python.hint', DepState.OK, py)
        if py_ver and pu._ver_tuple(py_ver) >= pu.MIN_PYTHON:
            return Dep('python', 'dep.python', 'dep.python.hint', DepState.MISSING,
                       f'dep.python.missing:{py} ({py_ver})',
                       install=[py, '-m', 'pip', 'install', 'lz4', 'capstone', 'fonttools',
                                'backports.zstd', 'nsz'])
        if pu.IS_WIN:
            return Dep('python', 'dep.python', 'dep.python.hint', DepState.MISSING,
                       f'dep.python.none:{py or "python3"}',
                       install=['__win__:python'])
        return Dep('python', 'dep.python', 'dep.python.hint', DepState.OLD,
                   f'dep.python.old:{py_ver or "?"}')

    def _check_deps(self) -> None:
        deps: list[Dep] = []

        # Python + packages. The Windows refinement (the interpreter the app installed for
        # itself) happens in `_windows_deps`, which is the only place allowed to load the
        # Windows-only modules.
        py, py_ok, py_ver = pu.find_python()
        deps.append(self._python_row(py, py_ok, py_ver))

        # .NET. On Windows the row comes from `_windows_deps()` instead: there the check has to be
        # "SDK 10 or newer is installed" (nx_extract targets net10.0) and the fix is an in-app
        # download, neither of which `find_dotnet` knows about. This generic row is what the
        # Windows panel used to be missing entirely — the handheld report's first line,
        # ".NET SDK 10 never appears in the log", came from exactly that gap.
        dn = dn_ok = None
        if not pu.IS_WIN:
            dn, dn_ok = pu.find_dotnet()
            deps.append(Dep('dotnet', 'dep.dotnet', 'dep.dotnet.hint',
                            DepState.OK if dn_ok else DepState.MISSING,
                            dn if dn_ok else 'dep.dotnet.missing'))

        # Xcode (macOS) or the cross toolchain (Windows)
        if pu.IS_WIN:
            deps.extend(self._windows_deps(deps))
        else:
            xc = pu.xcode_ok()
            sdk = xc and pu.ios_sdk_ok()
            deps.append(Dep('xcode', 'dep.xcode', 'dep.xcode.hint',
                            DepState.OK if sdk else DepState.MISSING,
                            '' if sdk else ('dep.xcode.noSDK' if xc else ''),
                            install=[] if sdk else (['/usr/bin/xcodebuild', '-downloadPlatform', 'iOS'] if xc else [])))
            mtl = pu.metal_toolchain_ok()
            deps.append(Dep('metal', 'dep.metal', 'dep.metal.hint',
                            DepState.OK if mtl else DepState.MISSING,
                            '' if mtl else 'dep.metal.missing',
                            install=[] if mtl else ['/usr/bin/xcodebuild', '-downloadComponent', 'MetalToolchain']))

            # the remaining command-line tools (xcodegen is macOS-only: the Windows build packs
            # the app directly and needs no project file)
            for tool, key in (('xcodegen', 'dep.xcodegen'), ('zstd', 'dep.zstd'),
                              ('spirv-cross', 'dep.spirv')):
                found = pu.find_tool(tool)
                deps.append(Dep('tool:' + tool, key, key + '.hint',
                                DepState.OK if found else DepState.MISSING, found or ''))

        # Carry the in-flight flag across the rebuild. `check_deps` runs on a timer, at the end of
        # every install, and whenever the user presses "Check again" — and each of those replaces
        # every Dep object. Without this, a row being installed came back as a fresh `installing
        # = False` row, so the panel showed an Install button for a download that was still
        # running and pressing it started a second one (the report: "I installed LLVM and the SDK
        # several times"). Two downloads into one folder is also how a half-unpacked toolchain
        # appears on disk.
        running = {d.id for d in self.deps if d.installing}
        for d in deps:
            if d.id in running:
                d.installing = True
        # The failure note belongs to the row, and a check (which rebuilds every row) must not
        # wipe it: it clears when that row installs successfully instead.
        previous = {d.id: d for d in self.deps}
        for d in deps:
            p = previous.get(d.id)
            if p is not None and not d.ok:
                d.last_error, d.fix_hint = p.last_error, p.fix_hint

        self.deps = deps
        if not pu.IS_WIN:
            # On Windows `_windows_deps` already set python_path (the interpreter the app
            # installed, which find_python without its candidates cannot see) and dotnet_path
            # from the toolchain probes; assigning the plain find_python result here overwrote
            # the interpreter with the bare fallback "python", and the venv step then ran
            # "python -m venv" — which is exactly how it failed on the report's machine.
            self.python_path, self.python_ok, self.python_ver = py, py_ok, py_ver
            self.dotnet_path, self.dotnet_ok = dn, dn_ok
        self.deps_checked = True
        self.depsChanged.emit()

    @property
    def all_deps_ok(self) -> bool:
        """Every required row passed — and an empty list is not "all good".

        `all([])` is True, so when the dependency check threw and left `self.deps = []` (the
        handler below), the panel reported "All ready" while nothing had been checked at all.
        The handheld report was exactly that: ".NET and LLVM installed, then it says every
        dependency is fine — I have not even installed Metal." A check that produced no rows has
        proved nothing, so it is not a pass.
        """
        if not self.deps_checked or not self.deps:
            return False
        return all(d.ok for d in self.deps)

    # ---- Windows toolchain rows

    def _windows_deps(self, deps: list[Dep]) -> list[Dep]:
        """The Windows cross toolchain, in the order it matters.

        The checks come from `nspb_qt.win.toolchain`, which runs the real compilers for the
        probes (a clang that produces an arm64 Mach-O object, an `ld64.lld` that links an
        executable, `metal.exe` that builds a `.metallib`) rather than trusting a path. That is
        what turns "the panel says ok" into "the build will get past the first step".

        `nspb_qt.win` is imported inside this method, and only here: on macOS the package is
        never touched, so nothing Windows-specific can break a Mac start-up.
        """
        from .win import toolchain as wtc     # local import: macOS never loads it

        out: list[Dep] = []
        probes = wtc.check_all(deep=True)

        # Re-do the Python row now that the toolchain can speak: the interpreter this app
        # installed for itself is not on PATH and not in Program Files, so the row built before
        # this point reported "no usable Python" on the very machine that had just installed one
        # (and after such an install, this is what makes the row go green).
        own = wtc.python_dir()
        if own:
            py2, ok2, ver2 = pu.find_python([str(own / 'python.exe')])
            if py2 != (self.deps[0].detail if self.deps else None):
                deps[0] = self._python_row(py2, ok2, ver2)
            self.python_path, self.python_ok, self.python_ver = py2, ok2, ver2
        by_id = {p.id: p for p in probes}

        def state(p) -> DepState:
            return DepState.OK if p.ok else (DepState.OLD if p.state == 'wrong' else DepState.MISSING)

        # .NET first: it is what the extractor and the shader translator run on, and it is the
        # row the Windows panel did not have at all before (a macOS-only branch produced it).
        p = by_id.get('dotnet')
        if p:
            detail = p.detail if not p.ok else (p.version or p.path or 'ok')
            out.append(Dep('dotnet', 'dep.dotnet', 'dep.dotnet.hint', state(p), detail,
                           install=[] if p.ok else ['__win__:dotnet']))
            # the build passes DOTNET_ROOT to its children; this is the only place that knows
            # about the copy the app installed for itself
            if p.path:
                self.dotnet_path, self.dotnet_ok = str(Path(p.path) / 'dotnet.exe'), p.ok
            else:
                self.dotnet_path, self.dotnet_ok = 'dotnet', False

        # LLVM (+ the Mach-O linker, which comes from the same folder)
        p = by_id.get('llvm')
        if p:
            detail = p.path if p.ok else (p.detail or '')
            # A missing LLVM is installable in-app: fetch.install_llvm downloads the pinned
            # LLVM-MinGW and verifies its SHA-256. The marker tells install_dep to run that
            # instead of a command line.
            install = [] if p.ok else ['__win__:llvm']
            out.append(Dep('llvm', 'dep.llvm', 'dep.llvm.hint', state(p), detail,
                           install=install))
        p = by_id.get('lld')
        if p:
            out.append(Dep('lld', 'dep.lld', 'dep.lld.hint', state(p),
                           p.detail if not p.ok else (p.path or 'ok')))

        # the SDK. Apple's SDK cannot be redistributed by us; the in-app download (the
        # xybp888/iOS-SDKs checkout) needs no Apple ID and is the default fix, and Choose lets a
        # user with Apple's own SDK point at it instead — validated and written to
        # toolchain.json, so the choice survives restarts.
        p = by_id.get('ios_sdk')
        if p:
            detail = ''
            if p.ok:
                detail = p.path
            elif p.state == 'wrong':
                detail = p.detail
            install = [] if p.ok else ['__win__:ios_sdk']
            out.append(Dep('ios_sdk', 'dep.iossdk', 'dep.iossdk.hint', state(p), detail,
                           install=install, pick_key='' if p.ok else 'ios_sdk'))

        # Metal. The hint is the Windows one: on macOS this row says
        # `xcodebuild -downloadComponent`, which is an Apple ID login away on Windows
        # (developer.apple.com → "Metal Developer Tools for Windows").
        p = by_id.get('metal')
        if p:
            out.append(Dep('metal', 'dep.metal', 'dep.metal.hint.win', state(p),
                           (p.path or 'ok') if p.ok else (p.detail or ''),
                           pick_key='' if p.ok else 'metal_dir'))

        # the probes: one row each, so a broken toolchain names the step that fails
        for pid, key in (('probe_compile', 'dep.probe.compile'),
                         ('probe_link', 'dep.probe.link'),
                         ('probe_metal', 'dep.probe.metal')):
            p = by_id.get(pid)
            if p:
                out.append(Dep(pid, key, key + '.hint',
                               DepState.OK if p.ok else DepState.MISSING, p.detail))

        # Cross-platform tools. zstd is required (every build unpacks with it) and installable
        # in-app. spirv-cross is needed only by an OpenGL game and glslangValidator only by that
        # same path, so neither is required: a Metal title builds without them, and counting them
        # in "缺 N 项" told a user with a complete Metal toolchain that three things were wrong
        # (the report's screenshot: only spirv-cross was genuinely absent).
        #
        # Both are marked optional but shown in the state they are really in — a green dot on a
        # tool that is not installed read as "present" and hid the one row worth acting on.
        for pid, key, hint, req, install in (
                ('spirv-cross', 'dep.spirv.win', 'dep.spirv.hint.win', False, []),
                ('zstd', 'dep.zstd.win', 'dep.zstd.hint.win', True, ['__win__:zstd']),
                ('glslangValidator', 'dep.glslang', 'dep.glslang.hint', False, [])):
            p = by_id.get(pid)
            if p:
                d = Dep(pid, key, hint,
                        DepState.OK if p.ok else DepState.MISSING,
                        p.path if p.ok else (self.t('dep.optionalMissing') if not req else ''),
                        install=[] if p.ok else install, required=req)
                out.append(d)
        # Windows-on-ARM gets a visible note: the tools are x86-64 and run emulated.
        if note := wtc.host_arch_note():
            out.append(Dep('host_arch', 'dep.hostArch', 'dep.hostArch.hint',
                           DepState.OK, note))
        return out


    # ---- repository download and updates (the SwiftUI app has these; parity matters) ----

    REPO_URL = 'https://github.com/LNPANDY/NX2Apple.git'

    def git_binary(self) -> str | None:
        """The git to use: on Windows the app's own PortableGit first (it may have downloaded
        one), then a system install; on macOS whatever PATH and the usual places give."""
        if pu.IS_WIN:
            from .win import toolchain as wtc
            found = wtc.git_exe()
            return str(found) if found else None
        return pu._which('git')

    def clone_repo(self, dest: str | None = None) -> None:
        """Shallow-clone the project into ~/NX2Apple (or `dest`) and select it.

        Shallow on purpose: a quarter of the bytes and a third of the time of a full clone, and
        fetch/pull keep working on it. Runs on a thread with its progress in the log.
        """
        git = self.git_binary()
        if not git:
            if not pu.IS_WIN:
                self.repoChanged.emit()
                self.log(self.t('repo.gitMissing') + '\n')
                return
            # Windows with no git at all: fetch PortableGit, then carry on with the clone. This is
            # the one case where "one click" has to install something first; it needs no
            # administrator rights and no installer.
            self.repo_busy = True
            self.repoChanged.emit()
            self.log(self.t('repo.gitInstalling') + '\n')

            def install_then_clone() -> None:
                ok = False
                try:
                    from .win import fetch as wf
                    path = wf.install_git(log=lambda s: self.log(str(s) + '\n'),
                                          progress=lambda d, t_: self.log(
                                              f'  {d // 1048576} MB' +
                                              (f' / {t_ // 1048576} MB ({d * 100 // t_}%)' if t_ else '') + '\n'))
                    ok = Path(path).is_file()
                except Exception as e:
                    self.log(self.t('repo.gitInstallFail', str(e)) + '\n')
                self.repo_busy = False
                self.repoChanged.emit()
                if ok:
                    self.clone_repo(dest)      # now git exists: the normal path
                else:
                    self.log(self.t('repo.gitMissing') + '\n')

            threading.Thread(target=install_then_clone, daemon=True).start()
            return
        target = dest or str(Path.home() / 'NX2Apple')
        if Path(target).exists():
            if self.is_repo(target):
                self.repo_path = target
                self.repoChanged.emit()
            else:
                self.log(self.t('repo.destBusy', target) + '\n')
            return
        self.repo_busy = True
        self.repoChanged.emit()
        self.log(f'$ git clone --depth 1 {self.REPO_URL} {target}\n')

        def work() -> None:
            ok = False
            try:
                p = subprocess.Popen([git, 'clone', '--depth', '1', '--single-branch', '--progress',
                                      self.REPO_URL, target],
                                     stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                                     errors='replace', env=pu.child_env(), **pu.no_window_kwargs())
                assert p.stdout is not None
                for line in p.stdout:
                    self.log(line.replace('\r', '\n'))
                p.wait()
                ok = p.returncode == 0
            except OSError as e:
                self.log(f'{e}\n')
            self.repo_busy = False
            if ok and self.is_repo(target):
                self.repo_path = target
            elif not ok:
                shutil.rmtree(target, ignore_errors=True)   # a failed clone leaves a stub
            self.repoChanged.emit()

        threading.Thread(target=work, daemon=True).start()

    def update_repo(self) -> None:
        """Fetch, and fast-forward when there is anything to fast-forward.

        One button, because "check" and "pull" were never two decisions: the only reason to press
        the first was to find out whether to press the second, and a user who has just been told
        "12 new commits" is going to press it. Reported as "why does Check for updates not just
        pull — the extra Pull button is pointless", and it is right.

        The order still matters and is unchanged: `fetch` first (that is what learns about
        origin/main), then `rev-list` to see the gap, then `pull --ff-only` only when the gap is
        non-zero. `--ff-only` never merges and never touches local commits, so a checkout with
        changes of its own is refused rather than rewritten.

        git's own progress is streamed: over a slow link the fetch alone takes tens of seconds and
        the button used to go grey in silence.
        """
        git = self.git_binary()
        if not git or not self.repo_ok or not self.repo_is_git:
            return
        self.repo_busy = True
        self.repo_status = self.t('repo.checking')
        self.repoChanged.emit()
        self.log(self.t('repo.checking') + '\n')

        def stream(args: list[str], what: str) -> bool:
            """Run git, logging its output as it arrives (progress uses \\r)."""
            self.log(f'$ git -C {self.repo_path} {" ".join(args)}\n')
            try:
                p = subprocess.Popen([git, '-C', self.repo_path] + args,
                                     stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                     text=True, errors='replace', encoding='utf-8',
                                     env=pu.child_env(), **pu.no_window_kwargs())
                assert p.stdout is not None
                # git rewrites one progress line per percent per phase ("Counting objects: 7%",
                # "Receiving objects: 62%", …). Logging each of those turned one fetch into
                # hundreds of lines (reported). Keep the phase changes, the final 100%, and every
                # fifth percent; drop the rest.
                seen: dict[str, int] = {}
                for line in p.stdout:
                    for s in line.replace('\r', '\n').split('\n'):
                        s = s.strip()
                        if not s:
                            continue
                        m = re.match(r'^(remote: )?([A-Za-z][\w ]*?):\s+(\d+)%', s)
                        if m:
                            phase, pct = m.group(2), int(m.group(3))
                            last = seen.get(phase)
                            if pct != 100 and last is not None and pct < last + 5:
                                continue
                            seen[phase] = pct
                        self.log(s + '\n')
                p.wait()
                return p.returncode == 0
            except OSError as e:
                self.log(f'{e}\n')
                return False

        def work() -> None:
            try:
                if not stream(['fetch', '--progress', 'origin', 'main'], 'fetch'):
                    self.repo_status = self.t('repo.netFail')
                    return
                try:
                    r = subprocess.run([git, '-C', self.repo_path, 'rev-list', '--count',
                                        'HEAD..origin/main'],
                                       capture_output=True, text=True, env=pu.child_env(),
                                       **pu.no_window_kwargs())
                    behind = int(r.stdout.strip() or 0) if r.returncode == 0 else -1
                except (OSError, ValueError):
                    behind = -1
                if behind < 0:
                    self.repo_status = self.t('repo.netFail')
                    return
                self.repo_behind = behind
                if behind == 0:
                    self.repo_status = self.t('repo.upToDate')
                    self.log(self.repo_status + '\n')
                    return
                self.repo_status = self.t('repo.pulling')
                self.repoChanged.emit()
                self.log(self.t('repo.pulling') + '\n')
                if stream(['pull', '--ff-only', 'origin', 'main'], 'pull'):
                    self.repo_behind = 0
                    self.repo_status = self.t('repo.pulled')
                else:
                    self.repo_status = self.t('repo.pullFail')
                self.log(self.repo_status + '\n')
            finally:
                self.repo_busy = False
                self.repoChanged.emit()

        threading.Thread(target=work, daemon=True).start()

    # ---- installing what is missing ----

    def install_dep(self, dep: Dep) -> None:
        """Run one dependency's fix on a thread, streaming its output to the log.

        Two kinds of fix:
        - a Windows toolchain row carries a '__win__:<what>' marker and is downloaded in-process
          (nspb_qt.win.fetch), because there is no command line to run;
        - everything else carries an argv list that is spawned.

        `dep.installing` is the flag install_all_missing waits on, so every path must clear it —
        including the error paths, or a sequential run would stall on a row that failed instantly.
        """
        if not dep.install:
            return
        if dep.installing:
            # A second click while this row is already downloading. The button is disabled while
            # it runs, but a rebuild of the panel (check_deps) used to hand out a fresh row, and
            # two writers into one staging folder produce a broken toolchain.
            self.log(self.t('dep.install.begin', dep.id) + ' — ' +
                     self.t('dep.installing') + '\n')
            return
        if dep.install[0].startswith('__win__:'):
            self._install_win(dep, dep.install[0].split(':', 1)[1])
            return
        dep.installing = True
        self.depsChanged.emit()

        def work() -> None:
            ok = True
            if dep.id == 'python':
                ok = self._make_venv(self.python_path)
            else:
                self.log('$ ' + ' '.join(dep.install) + '\n')
                try:
                    p = subprocess.Popen(dep.install, stdout=subprocess.PIPE,
                                         stderr=subprocess.STDOUT, text=True,
                                         errors='replace', env=pu.child_env(),
                                         **pu.no_window_kwargs())
                    assert p.stdout is not None
                    for line in p.stdout:
                        self.log(line)
                    p.wait()
                    ok = p.returncode == 0
                except OSError as e:
                    self.log(f'{e}\n')
                    ok = False
            if not ok:
                self.log(self.t('dep.install.fail', '-') + '\n')
            self._clear_installing(dep)
            self.depsChanged.emit()

        threading.Thread(target=work, daemon=True).start()

    def _clear_installing(self, dep: Dep) -> None:
        """Drop `installing` on every row with this id, wherever it currently lives.

        `check_deps` may have rebuilt the rows mid-install (the user pressing Check again, or the
        end-of-install refresh racing the panel): the flag was carried forward onto the NEW
        object, while the installer only clears the one it holds — so the row stayed grey ("Install"
        disabled) forever. The screenshot's LLVM row, grey with its install already failed, was
        exactly that.
        """
        dep.installing = False
        for r in self.deps:
            if r.id == dep.id:
                r.installing = False

    def _install_win(self, dep: Dep, what: str) -> None:
        """Download and unpack a Windows toolchain piece, with progress in the log.

        Every step logs before and after itself: the report that prompted this said only
        '--- LLVM-MinGW ---' and then nothing, which gave no clue whether the download had
        started, finished, or thrown.
        """
        dep.installing = True
        self.depsChanged.emit()

        def progress_logger(label: str):
            return self._progress_logger(label)

        def work() -> None:
            ok = False
            try:
                from .win import fetch as wf, toolchain as wtc
                self.log(self.t('dep.install.begin', dep.id) + '\n')
                if what == 'dotnet':
                    self.log(self.t('dep.dotnet.downloading') + '\n')
                    path = wf.install_dotnet(
                        log=lambda s: self.log(str(s) + '\n'),
                        progress=progress_logger(self.t('dep.phase.download')),
                        unpack_progress=progress_logger(self.t('dep.phase.unpack')))
                    self.log(self.t('dep.dotnet.done', str(path)) + '\n')
                    ok = True
                elif what == 'python':
                    self.log(self.t('dep.python.downloading') + '\n')
                    path = wf.install_python(
                        log=lambda s: self.log(str(s) + '\n'),
                        progress=progress_logger(self.t('dep.phase.download')))
                    self.log(self.t('dep.python.done', str(path)) + '\n')
                    ok = True
                elif what == 'llvm':
                    self.log(self.t('dep.llvm.downloading') + '\n')
                    path = wf.install_llvm(
                        log=lambda s: self.log(str(s) + '\n'),
                        progress=progress_logger(self.t('dep.phase.download')),
                        unpack_progress=progress_logger(self.t('dep.phase.unpack')))
                    self.log(self.t('dep.llvm.done', str(path)) + '\n')
                    ok = True
                elif what == 'zstd':
                    path = wf.install_zstd(
                        log=lambda s: self.log(str(s) + '\n'),
                        progress=progress_logger(self.t('dep.phase.download')),
                        unpack_progress=progress_logger(self.t('dep.phase.unpack')))
                    self.log(f'zstd installed: {path}\n')
                    ok = True
                elif what == 'ios_sdk':
                    self.log(self.t('dep.iossdk.downloading') + '\n')
                    from .win import sdk_fetch as sf
                    path = sf.clone_sdk(log=lambda s: self.log(str(s) + '\n'))
                    self.log(self.t('dep.iossdk.done', str(path)) + '\n')
                    ok = True
                else:
                    self.log(f'unknown Windows install target: {what}\n')
            except Exception as e:
                # DownloadError, OSError, ImportError, a missing attribute: all reported with the
                # type so a bug report names the failure without guessing.
                import traceback
                detail = f'{type(e).__name__}: {e}'
                self.log(self.t('dep.install.fail', detail) + '\n')
                self.log(traceback.format_exc() + '\n')
                self._record_install_failure(dep, detail)
            self._clear_installing(dep)
            self.depsChanged.emit()
            self.check_deps()

        threading.Thread(target=work, daemon=True).start()

    def _record_install_failure(self, dep: Dep, detail: str) -> None:
        """Say why an install failed and what to do, under the row itself (Mac parity).

        The log already carries the traceback; the row gets the one-line error plus a fix chosen
        from it — network for downloads, disk space for unpacks — so the player needs no log
        reading for the two cases that cover most of them.
        """
        fix = self._classify_install_failure(detail)
        for r in self.deps:
            if r.id == dep.id:
                r.last_error = detail
                r.fix_hint = fix

    @staticmethod
    def _classify_install_failure(detail: str) -> str:
        """The fix hint for one install failure, from its text (network, disk space, else the log)."""
        low = detail.lower()
        if 'timed out' in low or 'connection' in low or 'resolve host' in low or 'network' in low:
            return 'dep.fix.network'
        if 'no space' in low or 'disk full' in low or 'errno 28' in low:
            return 'dep.fix.diskspace'
        return 'dep.fix.log'

    def pick_dep_folder(self, dep: Dep) -> None:
        """A folder the user chose for one manual row: validated now, remembered in
        `toolchain.json`, then a fresh check re-reads it.

        Validation before saving keeps a wrong pick from silently becoming the configured answer
        (the SDK probe would then say `wrong` with a confusing version note on every start).
        """
        if not dep.pick_key:
            return
        from .win import toolchain as wtc
        ask = self.ask_folder
        if ask is None:
            return   # no window attached (tests): nothing to ask with
        folder = ask(self.t('dep.pick.' + dep.pick_key + '.title'))
        if not folder:
            return
        if dep.pick_key == 'ios_sdk':
            # The SDK can sit one level down (the guide's step 2 says so): accept both layouts.
            candidates = [Path(folder)] + sorted(Path(folder).glob('iPhoneOS*.sdk'), reverse=True)
            match = next((c for c in candidates if wtc.is_sdk_dir(c)), None)
            if match is None:
                self.log(self.t('dep.pick.iossdk.invalid', folder) + '\n')
                return
            ver, _build = wtc.sdk_version(match)
            wtc.save_config('ios_sdk', str(match))
            self.log(self.t('dep.pick.iossdk.saved', match) + '\n')
            if ver:
                self.log(self.t('dep.pick.iossdk.version', ver) + '\n')
        else:
            wtc.save_config(dep.pick_key, folder)
            self.log(self.t('dep.pick.saved', folder) + '\n')
        self.check_deps()

    def _progress_logger(self, label: str):
        """A progress callback that logs at 5% steps, not on every chunk.

        The download calls back once per MiB, so a 287 MB SDK produced ~280 lines at 1% each and
        buried everything else in the log (reported). Each call gets its own counter, so the
        download and the unpack that follows both start at 0% and each produce about ten lines.
        """
        seen = {'pct': -5}

        def report(done: int, total: int) -> None:
            if not total:
                return
            pct = done * 100 // total
            if pct < seen['pct'] + 5 and pct != 100:
                return
            seen['pct'] = pct
            self.log(f'  {label} {pct}%  ({done // 1048576} / {total // 1048576} MB)\n')

        return report

    def _make_venv(self, base: str) -> bool:
        """Create or reuse the app's venv and install the build packages into it."""
        vpy = pu.venv_python()
        if Path(vpy).is_file():
            ver = pu._python_version(vpy)
            if not ver or pu._ver_tuple(ver) < pu.MIN_PYTHON:
                # A venv an older app made from Apple's 3.9 (issue #75): pip into it would
                # "succeed" and the build would still fail. Moved aside, never deleted, because
                # the folder is the user's. Only when a base can build a new one.
                new_base = pu.venv_base(base)
                if new_base is None or new_base == vpy:
                    self.log(f'{pu.venv_dir()} is older than Python {pu.MIN_PYTHON[0]}.'
                             f'{pu.MIN_PYTHON[1]} and no newer Python was found to rebuild it from\n')
                    return False
                vdir = pu.venv_dir()
                aside = vdir.with_name(f'{vdir.name}.old-{time.strftime("%Y%m%d-%H%M%S")}')
                try:
                    vdir.rename(aside)
                except OSError as e:
                    self.log(f'could not move {vdir} aside: {e}\n')
                    return False
                self.log(f'moved the old venv to {aside}\n')
        if not Path(vpy).is_file():
            # The panel's last resort is /usr/bin/python3 (3.9) or the venv path itself, and
            # neither can run `-m venv`: the row used to stay red however often Install ran.
            base = pu.venv_base(base)
            if base is None:
                self.log(f'no Python {pu.MIN_PYTHON[0]}.{pu.MIN_PYTHON[1]} or newer to create '
                         f'{pu.venv_dir()} from\n')
                return False
            vdir = pu.venv_dir()
            vdir.parent.mkdir(parents=True, exist_ok=True)
            self.log(f'$ {base} -m venv {vdir}\n')
            if not pu._runs(base, ['-m', 'venv', str(vdir)]):
                self.log('venv creation failed\n')
                return False
        ver = pu._ver_tuple(pu._python_version(vpy))
        pkgs = ['lz4', 'capstone', 'fonttools', 'nsz']
        if ver < (3, 14):
            pkgs.insert(3, 'backports.zstd')
        self.log(f'$ {vpy} -m pip install {" ".join(pkgs)}\n')
        try:
            p = subprocess.Popen([vpy, '-m', 'pip', 'install'] + pkgs, stdout=subprocess.PIPE,
                                 stderr=subprocess.STDOUT, text=True, errors='replace',
                                 env=pu.child_env(), **pu.no_window_kwargs())
            assert p.stdout is not None
            for line in p.stdout:
                self.log(line)
            p.wait()
            return p.returncode == 0
        except OSError as e:
            self.log(f'{e}\n')
            return False

    def install_all_missing(self) -> None:
        """Install every missing dependency, one at a time, in order — and re-scan between passes.

        Genuinely sequential: each installer runs on its own thread, so an earlier version
        started them all at once and their downloads interleaved in the log (reported from a
        handheld: LLVM and SDK lines mixed). Order also matters for correctness — the SDK is
        fetched with git, which the git row may be installing.

        **Passes, not a snapshot.** One pass over a snapshot list stopped after the SDK: every
        row after it (Metal, spirv-cross, zstd, the link probe) has no in-app installer, so the
        loop skipped them all and nothing else ran — including the Python *packages* step, whose
        row had changed under the interpreter the same pass had just installed. The plan is now:
        scan → install what is missing and installable → re-scan → repeat, until a pass makes no
        progress. An id that failed is not retried in a later pass; a row whose fix changed
        (interpreter in → "pip install the packages") is picked up by the next pass.

        The row object is resolved by id at every step: `check_deps()` replaces every `Dep`
        after each install, and the panel renders those new objects — flags landing on a
        snapshot are invisible to the UI.
        """
        if not self.deps_checked or getattr(self, '_install_all_running', False):
            return
        self._install_all_running = True

        def run_all() -> None:
            try:
                attempted: set[str] = set()
                while True:
                    rows = [d for d in self.deps if not d.ok and d.install
                            and d.id not in attempted]
                    if not rows:
                        break
                    progressed = False
                    for d in rows:
                        live = next((r for r in self.deps if r.id == d.id), None)
                        if live is None or live.ok or not live.install or live.installing:
                            continue
                        attempted.add(live.id)
                        self.log(f'--- {self.t(live.title_key)} ---\n')
                        self.install_dep(live)
                        progressed = True
                        waited = 0.0
                        while live.installing and waited < 1800:
                            time.sleep(0.25)
                            waited += 0.25
                        if live.installing:
                            self.log(self.t('dep.installTimeout') + '\n')
                    if not progressed:
                        break
                self.check_deps()      # one refresh at the end, with everything in place
            finally:
                self._install_all_running = False

        threading.Thread(target=run_all, daemon=True).start()

    @Slot(str)
    def _emit_log(self, s: str) -> None:
        """Main-thread half of log(): see log() for why the hop exists."""
        self.logAppended.emit(s)

    def log(self, s: str) -> None:
        """Append to the window's log and to the log file.

        The file is what makes a bug report possible from a handheld, where copying text out of
        the window is painful: one path, one file, sent as-is.

        The signal is emitted from worker threads (every installer and the build runner). A Qt
        signal crossing threads is delivered through the receiver's event loop, and a connection
        made to a plain Python callable has no receiver object to queue against — the emission is
        then dropped. That is what made a real Windows run show only the stage header while the
        log file received everything. QMetaObject.invokeMethod with QueuedConnection hands the
        call to the main thread explicitly, which works regardless of how the slot is connected.
        """
        if QThread.currentThread() is self.thread():
            self.logAppended.emit(s)
        else:
            QMetaObject.invokeMethod(self, '_emit_log', Qt.QueuedConnection,
                                     Q_ARG(str, s))
        if getattr(self, 'log_path', None):
            try:
                with open(self.log_path, 'a', encoding='utf-8', errors='replace') as f:
                    f.write(s)
            except OSError:
                self.log_path = None      # one failure disables the file, not the app

    # ---- inputs

    def scan_game_dir(self, d: str) -> None:
        """Pick the four inputs out of a folder (and its subfolders, one level): a base NSP,
        an update, DLCs and prod.keys, by the naming the dumps use."""
        self.game_dir = d
        root = Path(d)
        if not root.is_dir():
            return
        files: list[Path] = []
        for p in sorted(root.iterdir()):
            if p.is_file():
                files.append(p)
            elif p.is_dir():
                files += [q for q in sorted(p.iterdir()) if q.is_file()]
        self.keys_path = next((str(f) for f in files if f.name.lower() == 'prod.keys'), self.keys_path)
        nsps = [f for f in files if f.suffix.lower() in ('.nsp', '.xci', '.nsz', '.xcz')]
        updates = [f for f in nsps if '[upd]' in f.name.lower() or 'update' in f.name.lower()]
        dlcs = [f for f in nsps if '[dlc]' in f.name.lower() or 'addon' in f.name.lower()]
        bases = [f for f in nsps if f not in updates and f not in dlcs]
        self.base_path = str(bases[0]) if bases else ''
        self.update_path = str(updates[0]) if updates else ''
        self.dlc_paths = [str(f) for f in dlcs]
        self.repoChanged.emit()

    @property
    def can_build(self) -> bool:
        return (self.repo_ok and bool(self.base_path) and bool(self.keys_path)
                and self.all_deps_ok and not self.running)

    # ---- build

    def start_build(self) -> None:
        if self.running:
            return
        if not self.repo_ok:
            self.finished.emit(False, self.t('msg.repoInvalidEmpty'))
            return
        py = self.python_path or ('python' if pu.IS_WIN else '/usr/bin/python3')
        base_dir = str(Path(self.base_path).parent)
        all_files = [self.base_path, self.update_path] + self.dlc_paths
        dirs = {str(Path(f).parent) for f in all_files if f}

        tid = self._title_id(self.base_path)
        tid_hex = f'{tid:016X}' if tid else 'game'
        work_dir = str(Path(self.out_dir or base_dir, f'{tid_hex}_build'))

        input_dir = base_dir
        if len(dirs) > 1:
            # files from different folders: a stable folder of links per game, so the script sees one
            # folder and its fingerprints match on the next build (#132)
            staging = input_staging.folder(work_dir)
            if input_staging.sync(all_files, staging, hard_links=not pu.IS_WIN) == 0:
                self.finished.emit(False, self.t('msg.stagingFailed'))
                return
            input_dir = staging

        compressed = any(Path(f).suffix.lower() in ('.nsz', '.xcz')
                         for f in all_files if f)
        if compressed and not pu._runs(py, ['-c', 'import nsz']):
            self.log(self.t('msg.installingNsz') + '\n')
            if not pu._runs(py, ['-m', 'pip', 'install', 'nsz']):
                self.finished.emit(False, self.t('msg.nszFailed', py))
                return

        # On Windows the upstream script is started through the driver, which loads it as a
        # module and replaces the steps that assume a Mac (see nspb_qt/win/driver.py). The
        # options are identical, so the command line stays comparable between the platforms.
        if pu.IS_WIN:
            entry = ['-m', 'nspb_qt.win.driver']
            cwd = str(Path(__file__).resolve().parents[1])
        else:
            entry = [str(Path(self.repo_path, 'scripts', 'build_ipa_from_nsp.py'))]
            cwd = self.repo_path
        args = entry + [input_dir, '-k', self.keys_path, '--progress', 'lines']
        has_work_dir = self.supports_work_dir()
        if has_work_dir:
            args += ['--work-dir', work_dir]
        else:
            self.log(self.t('msg.noWorkDir') + '\n')
        # A Mac app is a different output, not a different pipeline: --platform mac-app runs the
        # same steps and then packs dm/mac/pack_app.py's result. Its -o names the .app, and the
        # RomFS is inside it, so the archive step is skipped below.
        mac_app = self.target == 'mac-app'
        if mac_app:
            args += ['--platform', 'mac-app']
            self.mac_app_path = str(Path(self.out_dir or base_dir, f'{tid_hex}.app'))
            args += ['-o', self.mac_app_path]
        elif self.out_dir:
            self.ipa_path = str(Path(self.out_dir, f'{tid_hex}.ipa'))
            args += ['-o', self.ipa_path]
        self.effective_work_dir = work_dir if has_work_dir else str(Path(input_dir, f'{tid_hex}_build'))
        flag = self.override.take()   # for this build only: the next one asks again
        args = bf.arguments(args, flag)

        self.running = True
        self.runningChanged.emit(True)
        self.stages = []
        self.ipa_path = self.archive_path = self.mac_app_path = ''
        self.log_tail = ''
        self._last_error = ''
        self.failure = None
        self.override.cancel()
        self.stagesChanged.emit()
        if flag:
            self.log(self.t('fail.override.note', flag) + '\n')
        self.log(self.t('msg.running', py + ' ' + ' '.join(args)) + '\n')

        env = pu.child_env()
        droot = pu.dotnet_root(self.dotnet_path) if self.dotnet_ok else None
        if droot:
            env['DOTNET_ROOT'] = droot
            env['DOTNET_ROOT_ARM64'] = droot
        if pu.IS_WIN:
            # The shim folder goes first on PATH/PYTHONPATH so the tools the pipeline spawns by
            # name (xcrun, xcodebuild, which, dmsh_xlate, python3) resolve to the Windows
            # stand-ins, and the child interpreters load sitecustomize. Failing here stops the
            # build before it wastes time instead of twenty minutes in.
            try:
                from .win import shim as wshim
                env = wshim.build_env(env, python_exe=py)
                ok_shim, why = wshim.verify_shim(env)
                if not ok_shim:
                    self.log(f'[shim] {why}\n')
            except Exception as e:      # a broken shim must be visible, not fatal
                self.log(f'[shim] could not prepare the Windows shim: {e}\n')
            env['NSPB_REPO'] = self.repo_path

        def work() -> None:
            ok = False
            try:
                self._proc = subprocess.Popen([py] + args, cwd=cwd,
                                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                              text=True, errors='replace', bufsize=1, env=env,
                                              **pu.no_window_kwargs())
                assert self._proc.stdout is not None
                for line in self._proc.stdout:
                    self._on_line(line.rstrip('\n'))
                self._proc.wait()
                ok = self._proc.returncode == 0
            except OSError as e:
                self.log(f'{e}\n')
            finally:
                self._proc = None
            self._flush_lines()
            self.running = False
            self.runningChanged.emit(False)
            if mac_app:
                exists = bool(self.mac_app_path) and Path(self.mac_app_path).exists()
                self.finished.emit(exists, self.t('target.macDone' if exists else 'target.missingApp'))
            elif ok:
                self.pack_archive()
            else:
                if self.stages:
                    self.stages[-1].state = 'failed'
                    self.stagesChanged.emit()
                # The last real line says more than the exit code: "Build failed (exit code 1)"
                # on its own sent a reporter looking for a log that was not on screen (#52)
                last = getattr(self, '_last_error', '')
                note = self.t('msg.buildFailedReason', last) if last else self.t('msg.buildFailed')
                known = bf.classify(self.log_tail, keys_readable=self._keys_readable())
                if known.kind != bf.UNKNOWN:   # a known early stop: the window explains it and offers the next step
                    self.failure = known
                    note = self.failure_what(known)
                self.finished.emit(False, note)

        self._thread = threading.Thread(target=work, daemon=True)
        self._thread.start()

    def failure_what(self, f: 'bf.Failure') -> str:
        """The first sentence of a failure's hint (it names the game of a 32-bit program when the message does)."""
        if f.kind == bf.A32_PROGRAM and f.game:
            return self.t('fail.a32Program.whatNamed', f.game)
        if f.kind == bf.DISK_FULL and f.detail:
            return self.t('fail.diskFull.whatNeeds', f.detail)
        return self.t(f.what_key)

    def _keys_readable(self) -> bool | None:
        """Whether the chosen keys file can be opened: None when none is chosen."""
        if not self.keys_path:
            return None
        try:
            with open(self.keys_path, 'rb'):
                return True
        except OSError:
            return False

    def failure_folder(self, f: 'bf.Failure') -> str:
        """The folder "Show folder" opens: the one with the game files, else the one the message names. For a full disk the
        build folder (`<title ID>_build`) when it is there, since that is where the space went."""
        game_dir = str(Path(self.base_path).parent) if self.base_path else ''
        folder = game_dir or (f.detail if f.kind == bf.NO_TITLE_ID else '') or ''
        if f.kind == bf.DISK_FULL and game_dir:
            try:
                built = sorted(p.name for p in Path(game_dir).iterdir() if p.name.endswith('_build') and p.is_dir())
            except OSError:
                built = []
            if built:
                folder = str(Path(game_dir, built[0]))
        return folder

    def fix_failure(self, f: 'bf.Failure') -> None:
        """The failure card's fix buttons run the dependency rows' own fixes (install_dep, as Settings does)."""
        if f.kind == bf.TRANSLATOR:
            row = next((d for d in self.deps if d.id == 'dotnet'), None)
            if row:
                self.install_dep(row)
        elif f.kind == bf.IOS_SDK and not pu.IS_WIN:
            self.install_dep(Dep('xcode', 'dep.xcode', 'dep.xcode.hint', DepState.MISSING,
                                 install=['/usr/bin/xcodebuild', '-downloadPlatform', 'iOS']))

    def cancel_build(self) -> None:
        if self._proc and self._proc.poll() is None:
            self._proc.terminate()

    # ---- the script's own progress lines

    def _on_line(self, line: str) -> None:
        """Feed one line of the build's output: stage lines move the stage list, everything
        else goes to the log (which is what the window shows)."""
        self.log(line + '\n')
        self.log_tail = (self.log_tail + line + '\n')[-12000:]   # what the classifier reads on a failure
        # The last line that was not stage bookkeeping: a failed build's summary used to be the
        # bare exit code ("Build failed (exit code 1)"), which told the reporter nothing and sent
        # them looking for a log that a short window had below the fold (issue #52)
        if line.strip() and not (line.startswith('[') and ']' in line and line.find(']') + 1 < len(line)):
            self._last_error = line.strip()[:200]
        if line.startswith('output IPA:'):
            self.ipa_path = line.split(':', 1)[1].strip()
        low = line.lower()
        for st in self.stages:
            if st.state == 'running':
                st.detail = line[:120]
                break
        if '[' in line and ']' in line:
            head = line[:line.find(']') + 1]
            if '/' in head:
                name = line[line.find(']') + 1:].strip()
                if name:
                    if self.stages and self.stages[-1].state == 'running':
                        self.stages[-1].state = 'done'
                    self.stages.append(Stage(name=name, state='running'))
                    self.stagesChanged.emit()
        del low

    def _flush_lines(self) -> None:
        self._line_buf = ''

    # ---- the archive step (what makes a 16 GB game installable)

    def pack_archive(self) -> None:
        work = getattr(self, 'effective_work_dir', '')
        extract = Path(work, 'extract')
        versions = []
        if extract.is_dir():
            for d in sorted(extract.iterdir()):
                if d.is_dir() and d.name.startswith('v') and (d / 'RomFS').is_dir():
                    try:
                        versions.append((int(d.name[1:]), d))
                    except ValueError:
                        pass
        if not versions:
            self.finished.emit(True, self.t('msg.archiveSkipped', str(extract)))
            return
        romfs = str(versions[-1][1] / 'RomFS')
        # games/<id>/ is the per-game layout main.m looks in first, and the file inside it is
        # romfs.img — one file, which copies to a phone at full speed where 300,000 did not
        dest = str(Path(self.out_dir or Path(self.base_path).parent, 'romfs'))
        self.stages.append(Stage(name=self.t('prog.archiveShort'), state='running'))
        self.stagesChanged.emit()

        def work_() -> None:
            args = [self.python_path, str(Path(self.repo_path, 'dm', 'tools', 'romfs_image.py')),
                    '--reuse', romfs, str(Path(dest, 'romfs.img'))]
            env = pu.child_env({'PYTHONPATH': str(Path(self.repo_path, 'dm', 'tools'))})
            ok = True
            try:
                p = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                     text=True, errors='replace', env=env,
                                     **pu.no_window_kwargs())
                assert p.stdout is not None
                for line in p.stdout:
                    self.log(line)
                p.wait()
                ok = p.returncode == 0
            except OSError as e:
                self.log(f'{e}\n')
                ok = False
            if self.stages:
                self.stages[-1].state = 'done' if ok else 'failed'
            self.archive_path = dest if ok else ''
            self.stagesChanged.emit()
            self.finished.emit(ok, '' if ok else self.t('msg.archiveFailed'))

        threading.Thread(target=work_, daemon=True).start()

    @staticmethod
    def _title_id(nsp: str) -> int | None:
        """The title ID from a dump's file name: the 16 hex digits in [0100…], which every
        dumper puts there."""
        import re
        m = re.search(r'\[([0-9A-Fa-f]{16})\]', Path(nsp).name)
        if not m:
            return None
        try:
            return int(m.group(1), 16)
        except ValueError:
            return None
