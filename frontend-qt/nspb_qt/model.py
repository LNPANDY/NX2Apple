"""State, dependency detection and the build runner. No UI here: the window connects to signals."""
from __future__ import annotations

import json
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

from . import app_update
from . import build_failure as bf
from . import engine
from . import input_staging
from . import inputs
from . import library as lib
from . import platform_util as pu
from . import romfs_languages
from .i18n import Lang
from .l10n import t


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
    install_stage: str = ''     # short localized stage summary (e.g. "Step 1/3 · Downloading Python 45%")
    install_detail: str = ''    # detailed progress line (e.g. "Downloading python-3.12.8 — 12 / 26 MB (45%)")
    install_pct: int | None = None  # current sub-stage percentage (0..100), None when indeterminate
    queue_index: int = 0        # 1-based queue position during install_all_missing (0 = not queued)

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
    id: int = 0


_STAGE_LINE_RE = re.compile(r'^(?:([✓✗⚠])\s*)?\[(\d+)/(\d+)\]\s+(.+)$')
_PSO_BASES_CACHE: tuple[tuple[str, int, float], int] | None = None
_PSO_BASES_LOCK = threading.Lock()
_PSO_LOG_BATCH_RE = re.compile(r'pso_offline: \S+: batch (\d+)/(\d+): (ready|\d+ bases)')
_PSO_LOG_MERGE_RE = re.compile(r'pso_offline: \S+: merging (\d+) batches')


def _pso_progress_from_logs(root: Path, cutoff: float) -> tuple[int, int, bool] | None:
    """Parse exact `(done, total, merging)` counts from `pso_offline.py`'s own log lines when present."""
    logs_dir = root / 'logs'
    best_log: Path | None = None
    best_mtime = -1.0
    for name in ('pso_offline_mac.log', 'build_ipa.log', 'build_framework.log', 'prepare_xcode.log'):
        cand = logs_dir / name
        try:
            st = cand.stat()
        except OSError:
            continue
        if st.st_size > 0 and st.st_mtime >= cutoff and st.st_mtime >= best_mtime:
            best_log = cand
            best_mtime = st.st_mtime
    if best_log is None:
        return None
    try:
        text = best_log.read_text(encoding='utf-8', errors='replace')
    except OSError:
        return None
    done = 0
    total = 0
    merging = False
    for line in text.splitlines():
        m = _PSO_LOG_BATCH_RE.search(line)
        if m:
            idx, tot, kind = int(m.group(1)), int(m.group(2)), m.group(3)
            if tot > 0:
                total = tot
                done = idx if kind == 'ready' else max(0, idx - 1)
                merging = False
            continue
        m2 = _PSO_LOG_MERGE_RE.search(line)
        if m2:
            tot = int(m2.group(1))
            if tot > 0:
                total = tot
                done = tot
                merging = True
    return (done, total, merging) if total > 0 else None


def pso_archive_progress(work_dir: str, batch_size: int = 1000) -> tuple[int, int, bool] | None:
    """Batch progress of pso_offline.py read from its log or work directory when native counts are absent."""
    global _PSO_BASES_CACHE
    if not work_dir or batch_size <= 0:
        return None
    root = Path(work_dir)
    chosen_work: Path | None = None
    root_mtime = -1.0
    root_size = 0
    for cand in (root / 'pso' / 'mac-work', root / 'ipa' / 'build' / 'ios' / 'pso' / 'work'):
        js = cand / 'bases.mtl4-json'
        try:
            st = js.stat()
        except OSError:
            continue
        if st.st_size > 0 and st.st_mtime >= root_mtime:
            chosen_work = cand
            root_mtime = st.st_mtime
            root_size = st.st_size
    if chosen_work is None:
        return None
    cutoff = root_mtime - 2.0

    # 1. Prefer `pso_offline.py`'s own batch log lines when present
    from_log = _pso_progress_from_logs(root, cutoff)
    if from_log is not None:
        return from_log

    # 2. Fall back to `batches.<arch>/NNNNN/`. Return None when no `batches.*` directory exists yet
    # so single-invocation `metal-tt` neither reads `bases.mtl4-json` nor shows a stuck "0 / N" at 0%.
    try:
        arch_dirs = [p for p in chosen_work.iterdir() if p.is_dir() and p.name.startswith('batches.') and len(p.name) > 8]
    except OSError:
        return None
    if not arch_dirs:
        return None
    chosen_arch_dir = max(arch_dirs, key=lambda p: p.stat().st_mtime if p.exists() else 0.0)
    arch = chosen_arch_dir.name[len('batches.'):]
    try:
        first_bst = (chosen_arch_dir / '00001' / 'bases.mtl4-json').stat()
    except OSError:
        return None
    if first_bst.st_mtime < cutoff:
        return None

    js_path = str(chosen_work / 'bases.mtl4-json')
    cache_key = (js_path, root_size, root_mtime)
    with _PSO_BASES_LOCK:
        cached = _PSO_BASES_CACHE
    if cached is not None and cached[0] == cache_key:
        bases_count = cached[1]
    else:
        try:
            data = Path(js_path).read_bytes()
        except OSError:
            return None
        bases_count = data.count(b'"vertex_function_descriptor"')
        if bases_count > 0:
            with _PSO_BASES_LOCK:
                _PSO_BASES_CACHE = (cache_key, bases_count)
    if bases_count <= batch_size:
        return None
    total = (bases_count - 1) // batch_size + 1
    done = 0
    for idx in range(1, total + 1):
        bdir = chosen_arch_dir / f'{idx:05d}'
        try:
            bst = (bdir / 'bases.mtl4-json').stat()
        except OSError:
            break
        if bst.st_mtime < cutoff:
            break
        if (bdir / f'{arch}.mtl4a.partial').exists() or not (bdir / f'key.{arch}').exists():
            break
        try:
            ast = (bdir / f'{arch}.mtl4a').stat()
        except OSError:
            break
        if ast.st_size <= 0:
            break
        done = idx
    pack_log = chosen_work / f'metal-pack.{arch}.log'
    try:
        merging = done == total and pack_log.stat().st_mtime >= cutoff
    except OSError:
        merging = False
    return (done, total, merging)


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
    appRelaunching = Signal()
    libraryChanged = Signal()

    #: Set by the window: asks for a folder (QFileDialog lives in the UI layer) and returns the
    #: path, or '' when the user cancelled. `pick_dep_folder` calls it, so the model stays UI-free.
    ask_folder: Callable[[str], str] | None = None
    #: Same, for a file ('Metal Developer Tools*.zip' the user downloaded from Apple).
    ask_file: Callable[[str], str] | None = None
    ask_sdk_archive: Callable[[str], str] | None = None
    _metal_zip: Path | None = None
    _sdk_archive: Path | None = None

    def __init__(self) -> None:
        super().__init__()
        self.settings = QSettings('NS Port Builder', 'NSPortBuilder')
        self.lang = Lang.initial()
        self.repo_path = self._find_repo()
        self.python_path, self.python_ok, self.python_ver = pu.find_python()
        self.dotnet_path, self.dotnet_ok = pu.find_dotnet()
        self.deps: list[Dep] = []
        self.deps_checked = False
        self._install_all_running = False
        self.install_all_step = 0
        self.install_all_total = 0
        self.install_all_pct = 0
        self.stages: list[Stage] = []
        self.running = False
        self.log_tail = ''
        self.engine_syncing = False   # tools/engine.py sync runs: the window shows a status line
        self.engine_failure: bf.Failure | None = None   # how the last sync stopped (engine.py's failure_kind), shown as a failure row with Try again
        self.failure: bf.Failure | None = None   # the script's known early stop (build_failure.py), None for any other
        self._last_build_inputs: tuple[str, ...] = ()
        self.override = bf.OverrideState()      # "Build anyway": one confirmed --allow-* for the next build
        self._last_error = ''   # the last real log line: the failure note names it (issue #52)
        self.game_dir = ''
        self.base_path = ''
        self.update_path = ''
        self.dlc_paths: list[str] = []
        self.keys_path = ''
        self.game_folder: inputs.GameFolderContents | None = None   # a game chosen as a folder of files or a NUP (no keys needed)
        self.game_folder_problem = ''   # why a chosen game folder cannot be built, shown on the base row
        self.out_dir = ''
        self.ipa_path = ''
        self.archive_path = ''
        self.mac_app_path = ''
        self.target = 'ios'   # 'ios' (an IPA) or 'mac-app' (a double-clickable Mac app; macOS only)
        self.bc_on_cpu = False
        self.ipa_kind = 'shared'   # 'shared' (shell.ipaShared) or 'oneGame' (shell.ipaOneGame)
        self.library = lib.GameLibrary()
        self.artwork = lib.ArtworkStore(on_updated=lambda _tid: self._emit_library_changed())
        self.repo_busy = False
        self.repo_behind: int | None = None
        self.repo_status = ''
        self.app_update: app_update.Release | None = None
        self.app_update_busy = False
        self.app_update_progress: float | None = None
        self.app_update_status = ''
        self._app_update_checked = False
        self._proc: subprocess.Popen | None = None
        self._thread: threading.Thread | None = None
        self._line_buf = ''
        self._pso_lock = threading.RLock()
        self._pso_poll_gen = 0
        self._pso_native_progress = False
        self._pso_poll_stop: threading.Event | None = None
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
        res = t(key, self.lang, *args)
        if pu.IS_WIN or getattr(self, 'target_platform', 'ios') == 'ios':
            if key not in ('build.mac', 'build.macNote', 'target.macDone', 'msg.macAppDone', 'target.tip'):
                res = (
                    res.replace('在访达中显示', '在文件夹中显示')
                    .replace('在访达里', '在文件夹中')
                    .replace('在访达中', '在文件夹中')
                    .replace('用访达复制', '用文件资源管理器复制')
                    .replace('在访达边栏', '在文件资源管理器')
                    .replace('访达', '文件夹')
                    .replace('此 Mac', '此电脑')
                    .replace('Reveal in Finder', 'Show in folder')
                    .replace('Show in Finder', 'Show in folder')
                    .replace('in the Finder', 'in the folder')
                    .replace('in Finder', 'in folder')
                    .replace('with Finder', 'with File Explorer')
                    .replace('this Mac', 'this PC')
                    .replace('This Mac', 'This PC')
                )
        return res

    # ---- shell cache folder (mirrors BuildStore+ShellRoot.swift)

    @staticmethod
    def default_shell_cache_path() -> str:
        return str(lib.default_state_dir() / 'shell')

    @property
    def shell_cache_path(self) -> str:
        saved = self.settings.value('shellRoot', defaultValue='', type=str)
        if saved and saved.strip():
            return saved.strip()
        return self.default_shell_cache_path()

    @property
    def shell_cache_is_default(self) -> bool:
        try:
            return Path(self.shell_cache_path).resolve() == Path(self.default_shell_cache_path()).resolve()
        except OSError:
            return self.shell_cache_path == self.default_shell_cache_path()

    def move_shell_cache(self, target_dir: str, *, exact_dest: bool = False) -> tuple[bool, str]:
        if self.running:
            return False, self.t('shellCache.busy')
        if not target_dir or not target_dir.strip():
            return False, self.t('shellCache.problem.readOnly')
        src = Path(self.shell_cache_path)
        raw_target = Path(target_dir.strip())
        dst = raw_target if (exact_dest or raw_target.name.lower() == 'shell') else (raw_target / 'shell')
        try:
            src_res = src.resolve()
            dst_res = dst.resolve()
        except OSError:
            src_res, dst_res = src, dst
        if src_res == dst_res:
            return False, self.t('shellCache.problem.same')
        if src_res in dst_res.parents:
            return False, self.t('shellCache.problem.inside')
        try:
            if src.exists():
                if dst.exists() and any(dst.iterdir()):
                    return False, self.t('shellCache.problem.taken')
                dst.parent.mkdir(parents=True, exist_ok=True)
                shutil.copytree(src, dst, dirs_exist_ok=True)
                shutil.rmtree(src, ignore_errors=True)
            else:
                dst.mkdir(parents=True, exist_ok=True)
        except OSError as e:
            return False, self.t('shellCache.failed', str(e), str(src))
        default_res = Path(self.default_shell_cache_path()).resolve()
        if dst_res == default_res:
            self.settings.setValue('shellRoot', '')
        else:
            self.settings.setValue('shellRoot', str(dst))
        self.repoChanged.emit()
        return True, self.t('shellCache.moved', str(dst))

    def reset_shell_cache_default(self) -> tuple[bool, str]:
        return self.move_shell_cache(self.default_shell_cache_path(), exact_dest=True)

    def settings_value(self, key: str, default: bool | None = None) -> bool | None:
        v = self.settings.value(key, defaultValue='', type=str)
        return default if v == '' else v.lower() == 'true'

    def settings_set(self, key: str, value: bool) -> None:
        self.settings.setValue(key, 'true' if value else 'false')

    def toggle_lang(self) -> None:
        self.lang = self.lang.other
        self.repoChanged.emit()
        self.depsChanged.emit()

    def set_lang(self, lang: Lang) -> None:
        self.lang = lang
        self.repoChanged.emit()
        self.depsChanged.emit()

    @Slot()
    def _emit_library_changed(self) -> None:
        try:
            if QThread.currentThread() is self.thread():
                self.libraryChanged.emit()
            else:
                QMetaObject.invokeMethod(self, '_emit_library_changed', Qt.QueuedConnection)
        except RuntimeError:
            pass

    def load_game_from_library(self, game: lib.LibraryGame) -> None:
        base = (game.inputs.get('base') or [''])[0]
        if base and inputs.is_game_folder_candidate(base):
            self.take_game_folder(base)
        else:
            self.leave_game_folder()
            self.base_path = base
            self.update_path = (game.inputs.get('update') or [''])[0]
            self.dlc_paths = list(game.inputs.get('dlc') or [])
            keys = (game.inputs.get('keys') or [''])[0]
            if keys:
                self.keys_path = keys
        self.out_dir = game.output_dir or ''
        self.ipa_path = game.ipa_path if game.has_ipa else ''
        arch = game.archive_path if game.has_archive else ''
        if (not arch or Path(arch).name == 'romfs') and re.fullmatch(r'[0-9A-Fa-f]{16}', game.title_id or ''):
            base_parent = Path(self.game_folder.folder) if self.game_folder is not None else (
                Path(self.base_path).parent if self.base_path else None)
            root = Path(self.out_dir) if self.out_dir else base_parent
            if root is not None:
                cand = root / 'games' / game.title_id.upper()
                if (cand / 'romfs.img').is_file() or (cand / 'romfs').is_dir() or (cand / 'aoc').is_dir():
                    arch = str(cand)
        self.archive_path = arch
        self.effective_work_dir = ''
        self.library.select(game.title_id)
        self.repoChanged.emit()

    # ---- repository

    @staticmethod
    def is_repo(d: str) -> bool:
        return engine.is_checkout(d)   # a checkout with tools/engine.py, a synced engine/, or an engine tree (#214)

    @property
    def engine_path(self) -> str:
        """The folder holding dm/ and scripts/: the checkout's engine/, or an engine tree itself (engine.py's rule)."""
        return engine.engine_root(self.repo_path)

    def sync_engine(self, then: Callable[[bool], None] | None = None) -> None:
        """Run `tools/engine.py sync` on a thread when engine/ is stale (after a pull, at the start, before a build that
        needs it). A no-op for a checkout from before #214 or a current engine/. `then(ok)` runs after it."""
        if getattr(self, '_engine_syncing', False):
            if then: then(True)
            return
        if not engine.is_stale(self.repo_path):
            self.engine_failure = None
            if then: then(True)
            return
        py = self.python_path or ('python' if pu.IS_WIN else '/usr/bin/python3')
        cmd = engine.sync_command(self.repo_path, py)
        self._engine_syncing = True
        self.engine_syncing = True
        self.engine_failure = None
        self.log('$ ' + ' '.join(cmd) + '\n')
        self.repoChanged.emit()   # the window shows the status line

        def work() -> None:
            # The sync drives git throughout (hooks, fetch, patch, pack), and Windows may have
            # no git at all — the same player this app installed PortableGit for during the
            # clone. Install it here too, and put it on the child's PATH: engine.py and
            # tools/patches.py spawn `git` by name, and a GUI launch inherits no PATH to find
            # it on (the sync failed with WinError 2 before either step ran).
            extra: dict[str, str] | None = None
            if pu.IS_WIN:
                git = self._ensure_windows_git()
                if not git:
                    self._engine_syncing = False
                    self.engine_syncing = False
                    self.engine_failure = bf.Failure(engine.ENGINE_SYNC)
                    self.repoChanged.emit()
                    if then: then(False)
                    return
                extra = {'PATH': str(Path(git).parent) + os.pathsep + pu.child_env()['PATH']}
            ok, kind = engine.run_sync(cmd, self.repo_path, self.log, env=pu.child_env(extra), **pu.no_window_kwargs())
            self._engine_syncing = False
            self.engine_syncing = False
            self.engine_failure = None if ok else bf.Failure(kind or engine.ENGINE_SYNC)
            self.repoChanged.emit()
            if then: then(ok)

        threading.Thread(target=work, daemon=True).start()

    def retry_engine_sync(self) -> None:
        """The failure row's Try again: clears the row and runs the sync again."""
        if self.engine_syncing:
            return
        self.engine_failure = None
        self.sync_engine()
        self.repoChanged.emit()

    def _find_repo(self) -> str:
        bundled = engine.bundled_engine()
        if bundled:
            return bundled
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
    def uses_bundled_engine(self) -> bool:
        return bool(engine.bundled_engine())

    @property
    def repo_is_git(self) -> bool:
        return not self.uses_bundled_engine and bool(self.repo_path) and Path(self.repo_path, '.git').exists()

    def supports_work_dir(self) -> bool:
        """Whether the checkout's build script declares --work-dir (an upstream checkout or an
        old ZIP does not; passing it there stops at argparse — issue #5)."""
        f = Path(self.engine_path, 'scripts', 'build_ipa_from_nsp.py')
        if not f.is_file() and engine.has_engine_tool(self.repo_path):
            return True   # engine/ is not made yet: the fork's engine always has --work-dir (patch 0007)
        try:
            text = f.read_text(encoding='utf-8', errors='replace')
        except OSError:
            return False
        return "'--work-dir'" in text or '"--work-dir"' in text

    def supports_shell_framework(self) -> bool:
        return (Path(self.engine_path, 'dm', 'ios', 'Shell').is_dir()
                or Path(self.engine_path, 'dm', 'ios', 'framework').is_dir()
                or Path(self.engine_path, 'dm', 'ios', 'shell').is_dir())

    # ---- dependencies

    def check_deps(self) -> None:
        self.deps_checked = False
        self.sync_engine()   # at the start: a checkout whose engine/ is missing or older than its pin (#214)
        threading.Thread(target=self._check_deps_worker, daemon=True).start()

    def _check_deps_worker(self) -> None:
        """Build the dependency rows off the UI thread.

        Any exception has to leave the panel in a finished state: an unhandled one killed this
        thread while `deps_checked` stayed False, so the panel sat on "Checking…" forever and the
        handheld report read "Check again does nothing". A failed check now says so.
        """
        try:
            self._check_deps()
        except RuntimeError:
            return
        except Exception as e:                     # noqa: BLE001 - a check must never be fatal
            import traceback
            self.log(f'dependency check failed: {type(e).__name__}: {e}\n')
            self.log(traceback.format_exc() + '\n')
            self.deps = []
            self.deps_checked = True
            try:
                self.depsChanged.emit()
            except RuntimeError:
                pass

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
                                'zbic', 'backports.zstd', 'nsz'])
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
        # The failure note and live progress belong to the row, and a check (which rebuilds every
        # row) must not wipe them: they clear when that row finishes or installs successfully.
        previous = {d.id: d for d in self.deps}
        for d in deps:
            p = previous.get(d.id)
            if p is not None:
                if p.installing:
                    d.install_stage = p.install_stage
                    d.install_detail = p.install_detail
                    d.install_pct = p.install_pct
                if not d.ok:
                    d.queue_index = p.queue_index
                    d.last_error, d.fix_hint = p.last_error, p.fix_hint

        self.deps = deps
        # The panel can only show one row at a time; the log keeps every detail, so a report sent
        # from a handheld always carries the full probe text (the truncated link row is why this
        # exists).
        for d in deps:
            if not d.ok and d.detail:
                # three placeholders, three args: a mismatch makes t() fall back to the raw
                # "dependency %@: [%@] %@" line (the report's log had it six times)
                name = d.title_key.replace('dep.', '').replace('.hint', '')
                detail_text = self.format_dep_detail(d.detail).replace('\n', ' | ')
                self.log(self.t('dep.row.log', name, d.state.value, detail_text) + '\n')
        if not pu.IS_WIN:
            # On Windows `_windows_deps` already set python_path (the interpreter the app
            # installed, which find_python without its candidates cannot see) and dotnet_path
            # from the toolchain probes; assigning the plain find_python result here overwrote
            # the interpreter with the bare fallback "python", and the venv step then ran
            # "python -m venv" — which is exactly how it failed on the report's machine.
            self.python_path, self.python_ok, self.python_ver = py, py_ok, py_ver
            self.dotnet_path, self.dotnet_ok = dn, dn_ok
        self.deps_checked = True
        try:
            self.depsChanged.emit()
        except RuntimeError:
            pass
        if getattr(sys, 'frozen', False) and not self._app_update_checked:
            self._app_update_checked = True
            self.check_app_update(silent=True)

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
        # Required rows only. An optional one (spirv-cross and glslangValidator, which only an OpenGL game
        # uses) never stops a build: counting it kept the button grey on a machine whose panel said
        # "everything required is installed", with nothing on screen to say why.
        return all(d.ok for d in self.deps if d.required)

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
        probes = wtc.check_all(deep=True, t=self.t)   # t: the failure summaries' hint keys reach the panel translated

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
            can_upgrade = p.ok and wtc.sdk_major(p.version) < wtc.sdk_major(wtc.SDK_PINNED[8:-4])
            install = ['__win__:ios_sdk'] if (not p.ok or can_upgrade) else []
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

    def _ensure_windows_git(self) -> str | None:
        """The git for engine.py's sync on Windows: the app's own PortableGit, installed here
        when the player has none (the same one clone_repo installs). None when the install
        failed, with the reason logged. engine.py and tools/patches.py spawn `git` by name, so
        the caller also puts its folder on the child's PATH."""
        git = self.git_binary()
        if git:
            return git
        try:
            from .win import fetch as wf
            self.log(self.t('repo.gitInstalling') + '\n')
            self.repoChanged.emit()
            wf.install_git(log=lambda s: self.log(str(s) + '\n'))
        except Exception as e:
            self.log(f'git install failed: {e}\n')
            return None
        return self.git_binary()

    def clone_repo(self, dest: str | None = None) -> None:
        """Shallow-clone the project into ~/NX2Apple (or `dest`) and select it.

        Shallow on purpose: a quarter of the bytes and a third of the time of a full clone, and
        fetch/pull keep working on it. Runs on a thread with its progress in the log.
        """
        if self.uses_bundled_engine:
            return
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
                                     encoding='utf-8', errors='replace', env=pu.child_env(),
                                     **pu.no_window_kwargs())
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
                self.sync_engine()
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
        if not self.repo_ok or not self.repo_is_git:
            return
        git = self.git_binary()
        if not git:
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
                    self.sync_engine()   # the pull may have moved the pin or the patches
                else:
                    self.repo_status = self.t('repo.pullFail')
                self.log(self.repo_status + '\n')
            finally:
                self.repo_busy = False
                self.repoChanged.emit()

        threading.Thread(target=work, daemon=True).start()

    # ---- app self-update (Windows release zip check + in-place swap) ----

    def check_app_update(self, silent: bool = False) -> None:
        """Check GitHub's latest release for a newer Windows build."""
        if self.app_update_busy:
            return
        self.app_update_busy = True
        if not silent:
            self.app_update_status = self.t('app.checking')
            try:
                self.repoChanged.emit()
            except RuntimeError:
                pass

        def work() -> None:
            try:
                data = app_update.fetch_latest_json()
                outcome = app_update.check_release(data, current=app_update.APP_VERSION)
                if outcome.kind == 'found' and outcome.release is not None:
                    rel = outcome.release
                    self.app_update = rel
                    if getattr(sys, 'frozen', False):
                        self.app_update_status = self.t('app.found', rel.tag)
                    else:
                        self.app_update_status = self.t('app.devBuild', rel.tag)
                    self.log(self.app_update_status + '\n')
                    try:
                        self.appUpdateFound.emit(rel.tag, rel.html_url)
                    except RuntimeError:
                        pass
                elif outcome.kind == 'no_asset':
                    if not silent:
                        self.app_update_status = self.t('app.noAsset', outcome.tag)
                elif outcome.kind == 'unreachable':
                    if not silent:
                        self.app_update_status = self.t('app.netFail')
                else:
                    if not silent:
                        self.app_update_status = self.t('app.upToDate')
            finally:
                self.app_update_busy = False
                try:
                    self.repoChanged.emit()
                except RuntimeError:
                    pass

        threading.Thread(target=work, daemon=True).start()

    def perform_app_update(self) -> None:
        """Download, verify, unpack, and relaunch the staged Windows release."""
        rel = self.app_update
        if rel is None or self.app_update_busy:
            return
        if self.running:
            self.app_update_status = self.t('app.waitForBuild')
            try:
                self.repoChanged.emit()
            except RuntimeError:
                pass
            return
        if not (pu.IS_WIN and getattr(sys, 'frozen', False)):
            self.app_update_status = self.t('app.devBuild', rel.tag)
            try:
                self.repoChanged.emit()
            except RuntimeError:
                pass
            return

        self.app_update_busy = True
        self.app_update_progress = 0.0
        self.app_update_status = self.t('app.downloading', rel.tag)
        self.log(self.app_update_status + '\n')
        try:
            self.repoChanged.emit()
        except RuntimeError:
            pass

        def on_progress(done_bytes: int, total_bytes: int) -> None:
            if total_bytes > 0 and done_bytes >= 0:
                frac = min(max(done_bytes / total_bytes, 0.0), 1.0)
                self.app_update_progress = frac
                pct = int(round(frac * 100))
                self.app_update_status = self.t('app.downloading', f'{pct}%' if pct > 0 else rel.tag)
                try:
                    self.repoChanged.emit()
                except RuntimeError:
                    pass
            self.log(
                f'  {done_bytes // 1048576} MB'
                + (f' / {total_bytes // 1048576} MB ({done_bytes * 100 // total_bytes}%)' if total_bytes else '')
                + '\n'
            )

        def work() -> None:
            try:
                from .win import fetch as wf
                root = app_update.fresh_staging_root()
                zip_path = root / 'update.zip'
                try:
                    wf.download(
                        rel.url,
                        zip_path,
                        progress=on_progress,
                    )
                except Exception as exc:
                    self.log(f'{exc}\n')
                    self.app_update_status = self.t('app.stageNetFail', rel.tag)
                    return

                try:
                    staged = app_update.stage_zip(zip_path, rel, root, require_digest=False)
                except app_update.StageError as err:
                    if err.key == 'app.digestMismatch':
                        self.app_update_status = self.t('app.digestMismatch', rel.tag)
                    elif err.key == 'app.noDigest':
                        self.app_update_status = self.t('app.noDigest', rel.tag)
                    elif err.key == 'app.notOurApp':
                        self.app_update_status = self.t('app.notOurApp', rel.tag)
                    else:
                        self.app_update_status = self.t('app.unpackFail', rel.tag)
                    self.log(self.app_update_status + '\n')
                    return

                self.app_update_status = self.t('app.relaunching', rel.tag)
                self.log(self.app_update_status + '\n')
                if app_update.relaunch_windows_update(staged):
                    try:
                        self.appRelaunching.emit()
                    except RuntimeError:
                        pass
                else:
                    self.app_update_status = self.t('app.relaunchFail', rel.tag)
                    self.log(self.app_update_status + '\n')
            finally:
                self.app_update_busy = False
                self.app_update_progress = None
                try:
                    self.repoChanged.emit()
                except RuntimeError:
                    pass

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
        dep._install_done = False  # type: ignore[attr-defined]
        dep.queue_index = 0
        if dep.id == 'python':
            self._set_dep_progress(
                dep,
                self.t('dep.stage.pyInstall'),
                self.t('dep.detail.pyInstall', self.python_ver or '3.12'),
                10,
                item_overall_pct=40,
                force=True,
            )
        else:
            self._set_dep_progress(dep, self.t('dep.installing'), '', 0, item_overall_pct=0, force=True)

        def work() -> None:
            ok = True
            try:
                if dep.id == 'python':
                    ok = self._make_venv(self.python_path, dep=dep)
                else:
                    self.log('$ ' + ' '.join(dep.install) + '\n')
                    try:
                        p = subprocess.Popen(dep.install, stdout=subprocess.PIPE,
                                             stderr=subprocess.STDOUT, text=True,
                                             encoding='utf-8', errors='replace', env=pu.child_env(),
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
            finally:
                self._clear_installing(dep)
                self.depsChanged.emit()
                self.check_deps()
                dep._install_done = True  # type: ignore[attr-defined]

        threading.Thread(target=work, daemon=True).start()

    def format_dep_detail(self, detail: str) -> str:
        """Translate internal `dep.*` detail markers into localized text for the UI and log."""
        if detail == 'dep.xcode.noSDK':
            return self.t('dep.xcode.noSDK')
        if detail.startswith('dep.python.old:'):
            ver = detail.split(':', 1)[1]
            return self.t('dep.python.old', ver, f'{pu.MIN_PYTHON[0]}.{pu.MIN_PYTHON[1]}')
        if detail.startswith('dep.python.missing:'):
            py = detail.split(':', 1)[1]
            return self.t('dep.python.missing', py)
        if detail.startswith('dep.python.notFound:'):
            need = detail.split(':', 1)[1]
            return self.t('dep.python.notFound', need, need)
        if detail.startswith('dep.python.none:'):
            found = detail.split(':', 1)[1]
            return self.t('dep.python.none', found)
        if detail.startswith('dep.metal.other:'):
            _, got, tested = detail.split(':', 2)
            return self.t('dep.metal.other', got, tested)
        return detail

    def _clear_installing(self, dep: Dep) -> None:
        """Drop `installing` and transient progress on every row with this id, wherever it lives.

        `check_deps` may have rebuilt the rows mid-install (the user pressing Check again, or the
        end-of-install refresh racing the panel): the flag was carried forward onto the NEW
        object, while the installer only clears the one it holds — so the row stayed grey ("Install"
        disabled) forever. The screenshot's LLVM row, grey with its install already failed, was
        exactly that.
        """
        for target in [dep] + [r for r in getattr(self, 'deps', []) if r.id == dep.id]:
            target.installing = False
            target.install_stage = ''
            target.install_detail = ''
            target.install_pct = None
            target.queue_index = 0

    def _set_dep_progress(self, dep: Dep, stage: str = '', detail: str = '',
                          pct: int | None = None, *,
                          item_overall_pct: int | None = None,
                          force: bool = False) -> None:
        """Update live stage text, detail line, and progress bar percentage for `dep` and emit `depsChanged`."""
        if pct is not None:
            pct = max(0, min(100, int(pct)))
        changed = (
            dep.install_stage != stage
            or dep.install_detail != detail
            or dep.install_pct != pct
        )
        for target in [dep] + [r for r in getattr(self, 'deps', []) if r.id == dep.id]:
            target.install_stage = stage
            target.install_detail = detail
            target.install_pct = pct
        if getattr(self, '_install_all_running', False):
            total_steps = max(1, int(getattr(self, 'install_all_total', 1) or 1))
            curr_step = max(1, min(total_steps, int(getattr(self, 'install_all_step', 1) or 1)))
            sub = item_overall_pct if item_overall_pct is not None else (pct if pct is not None else 0)
            sub = max(0, min(100, int(sub)))
            new_overall = ((curr_step - 1) * 100 + sub) // total_steps
            if new_overall > getattr(self, 'install_all_pct', 0):
                self.install_all_pct = min(100, new_overall)
                changed = True
        if changed or force:
            sig = getattr(self, 'depsChanged', None)
            if sig is not None and hasattr(sig, 'emit'):
                try:
                    sig.emit()
                except RuntimeError:
                    pass

    def _stage_progress_logger(self, dep: Dep, label: str, artifact_name: str, *,
                               phase: str = 'download',
                               py_version: str = ''):
        """Wrap `_progress_logger(label)` so every 1% step also updates `dep`'s UI progress bar."""
        base_log = self._progress_logger(label)
        ui_seen = {'pct': -1}

        def report(done: int, total: int) -> None:
            base_log(done, total)
            if not total:
                return
            pct = max(0, min(100, done * 100 // total))
            if pct == ui_seen['pct'] and pct not in (0, 100):
                return
            ui_seen['pct'] = pct
            done_mb = done // 1048576
            total_mb = max(1, total // 1048576)
            if phase == 'py_download':
                stage = self.t('dep.stage.pyDownload', pct)
                detail = self.t('dep.detail.pyDownload', py_version or '3.12', done_mb, total_mb, pct)
                overall_sub = pct * 40 // 100
            elif phase == 'unpack':
                stage = self.t('dep.stage.unpack', pct)
                detail = self.t('dep.detail.unpack', artifact_name, done_mb, total_mb, pct)
                overall_sub = 55 + pct * 45 // 100
            else:
                stage = self.t('dep.stage.download', pct)
                detail = self.t('dep.detail.download', artifact_name, done_mb, total_mb, pct)
                overall_sub = pct * 55 // 100
            self._set_dep_progress(dep, stage, detail, pct, item_overall_pct=overall_sub)

        return report

    def _install_win(self, dep: Dep, what: str) -> None:
        """Download and unpack a Windows toolchain piece, with progress in the log and UI.

        Every step logs before and after itself: the report that prompted this said only
        '--- LLVM-MinGW ---' and then nothing, which gave no clue whether the download had
        started, finished, or thrown.
        """
        dep.installing = True
        dep._install_done = False  # type: ignore[attr-defined]
        dep.queue_index = 0
        for r in getattr(self, 'deps', []):
            if r.id == dep.id:
                r.installing = True
                r.queue_index = 0
        if what == 'python':
            self._set_dep_progress(
                dep,
                self.t('dep.stage.pyDownload', 0),
                self.t('dep.python.downloading'),
                0,
                item_overall_pct=0,
                force=True,
            )
        elif what in ('ios_sdk_archive', 'metal_zip'):
            arc_Obj = self._sdk_archive if what == 'ios_sdk_archive' else self._metal_zip
            arc_name = arc_Obj.name if arc_Obj else what
            self._set_dep_progress(
                dep,
                self.t('dep.stage.unpack', 0),
                self.t('dep.metal.unpacking', arc_name),
                0,
                item_overall_pct=55,
                force=True,
            )
        else:
            self._set_dep_progress(
                dep,
                self.t('dep.stage.download', 0),
                self.t(dep.title_key),
                0,
                item_overall_pct=0,
                force=True,
            )

        def work() -> None:
            ok = False
            try:
                from .win import fetch as wf, toolchain as wtc
                self.log(self.t('dep.install.begin', dep.id) + '\n')
                if what == 'dotnet':
                    self.log(self.t('dep.dotnet.downloading') + '\n')
                    name = wtc.DOTNET_ASSET['name']
                    path = wf.install_dotnet(
                        log=lambda s: self.log(str(s) + '\n'),
                        progress=self._stage_progress_logger(
                            dep, self.t('dep.phase.download'), name, phase='download'),
                        unpack_progress=self._stage_progress_logger(
                            dep, self.t('dep.phase.unpack'), name, phase='unpack'))
                    self.log(self.t('dep.dotnet.done', str(path)) + '\n')
                    ok = True
                elif what == 'python':
                    self.log(self.t('dep.python.downloading') + '\n')
                    py_ver = wtc.PYTHON_VERSION

                    def py_log(s: object) -> None:
                        msg = str(s)
                        self.log(msg + '\n')
                        if 'installing Python' in msg:
                            self._set_dep_progress(
                                dep,
                                self.t('dep.stage.pyInstall'),
                                self.t('dep.detail.pyInstall', py_ver),
                                50,
                                item_overall_pct=45,
                                force=True,
                            )

                    path = wf.install_python(
                        log=py_log,
                        progress=self._stage_progress_logger(
                            dep, self.t('dep.phase.download'),
                            wtc.PYTHON_ASSET['name'],
                            phase='py_download', py_version=py_ver))
                    self.log(self.t('dep.python.done', str(path)) + '\n')
                    py_exe = Path(path) / 'python.exe' if Path(path).is_dir() else Path(path)
                    self.python_path = str(py_exe)
                    ok = self._make_venv(str(py_exe))
                    if not ok:
                        detail = 'venv / package install failed'
                        self.log(self.t('dep.install.fail', detail) + '\n')
                        self._record_install_failure(dep, detail)
                elif what == 'llvm':
                    self.log(self.t('dep.llvm.downloading') + '\n')
                    name = wtc.LLVM_ASSETS.get('AMD64', {}).get('name', 'LLVM-MinGW')
                    path = wf.install_llvm(
                        log=lambda s: self.log(str(s) + '\n'),
                        progress=self._stage_progress_logger(
                            dep, self.t('dep.phase.download'), name, phase='download'),
                        unpack_progress=self._stage_progress_logger(
                            dep, self.t('dep.phase.unpack'), name, phase='unpack'))
                    self.log(self.t('dep.llvm.done', str(path)) + '\n')
                    ok = True
                elif what == 'zstd':
                    name = wtc.ZSTD_ASSET['name']
                    path = wf.install_zstd(
                        log=lambda s: self.log(str(s) + '\n'),
                        progress=self._stage_progress_logger(
                            dep, self.t('dep.phase.download'), name, phase='download'),
                        unpack_progress=self._stage_progress_logger(
                            dep, self.t('dep.phase.unpack'), name, phase='unpack'))
                    self.log(f'zstd installed: {path}\n')
                    ok = True
                elif what == 'ios_sdk':
                    self.log(self.t('dep.iossdk.downloading') + '\n')
                    from .win import sdk_fetch as sf
                    sdk_name = f'{wtc.SDK_PINNED}.zip'
                    try:
                        path = sf.install_sdk(
                            log=lambda s: self.log(str(s) + '\n'),
                            progress=self._stage_progress_logger(
                                dep, self.t('dep.phase.download'), sdk_name, phase='download'),
                            unpack_progress=self._stage_progress_logger(
                                dep, self.t('dep.phase.unpack'), sdk_name, phase='unpack'),
                            fallback_git=False)
                    except Exception as zip_err:
                        self.log(f'{zip_err}\n')
                        if not (wtc.git_exe() or shutil.which('git')):
                            self.log(self.t('dep.git.downloading') + '\n')
                            gpath = wf.install_git(
                                log=lambda s: self.log(str(s) + '\n'),
                                progress=self._stage_progress_logger(
                                    dep, self.t('dep.phase.download'), 'PortableGit', phase='download'))
                            self.log(self.t('dep.git.done', str(gpath)) + '\n')
                        path = sf.clone_sdk(log=lambda s: self.log(str(s) + '\n'))
                    self.log(self.t('dep.iossdk.done', str(path)) + '\n')
                    ok = True
                elif what == 'ios_sdk_archive':
                    from .win import sdk_fetch as sf
                    arc = self._sdk_archive
                    self.log(self.t('dep.metal.unpacking', arc.name) + '\n')
                    if arc.suffix.lower() == '.xip':
                        dest = sf.extract_xip(arc, log=lambda s: self.log(str(s) + '\n'))
                    else:
                        dest = sf.install_sdk_from_zip(
                            arc,
                            log=lambda s: self.log(str(s) + '\n'),
                            unpack_progress=self._stage_progress_logger(
                                dep, self.t('dep.phase.unpack'), arc.name, phase='unpack'))
                    wtc.save_config('ios_sdk', str(dest))
                    self.log(self.t('dep.iossdk.done', str(dest)) + '\n')
                    ok = True
                elif what == 'metal_zip':
                    # Apple's tools are Apple-ID-gated: the browser download is the licensed
                    # path, the app does the unpack and remembers the folder.
                    self.log(self.t('dep.metal.unpacking', self._metal_zip.name) + '\n')
                    from .win import fetch as wf
                    dest = wf.install_metal_from_zip(self._metal_zip,
                                                     log=lambda s: self.log(str(s) + '\n'))
                    wtc.save_config('metal_dir', str(dest))
                    self.log(self.t('dep.metal.done', str(dest)) + '\n')
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
            dep._install_done = True  # type: ignore[attr-defined]

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
        if dep.pick_key == 'metal_dir':
            # The Metal zip is a file, not a folder: the ask_file callback (the window's file
            # dialog filters *.zip) takes the browser download straight away. An already
            # unpacked folder is equally accepted.
            ask_file = self.ask_file
            if ask_file is None:
                return
            picked = ask_file(self.t('dep.pick.metal_dir.title'))
            if not picked:
                return
            if picked.lower().endswith('.zip'):
                return self.install_metal_zip(Path(picked))
            return self._save_metal_folder(Path(picked))
        if dep.pick_key == 'ios_sdk':
            ask_sdk = self.ask_sdk_archive or self.ask_folder
            if ask_sdk is None:
                return
            folder = ask_sdk(self.t('dep.pick.ios_sdk.title'))
            if not folder:
                return
            if folder.lower().endswith(('.zip', '.xip')):
                return self.install_ios_sdk_archive(Path(folder))
            match = wtc.resolve_sdk_dir(folder)
            if match is None:
                self.log(self.t('dep.pick.iossdk.invalid', folder) + '\n')
                return
            try:
                from .win import sdk_fetch as sf
                sf.repair_tbd_stubs(match)
            except OSError:
                pass
            ver, _build = wtc.sdk_version(match)
            wtc.save_config('ios_sdk', str(match))
            self.log(self.t('dep.pick.iossdk.saved', match) + '\n')
            if ver:
                self.log(self.t('dep.pick.iossdk.version', ver) + '\n')
            self.check_deps()
            return
        ask = self.ask_folder
        if ask is None:
            return   # no window attached (tests): nothing to ask with
        folder = ask(self.t('dep.pick.' + dep.pick_key + '.title'))
        if not folder:
            return
        wtc.save_config(dep.pick_key, folder)
        self.log(self.t('dep.pick.saved', folder) + '\n')
        self.check_deps()

    def _save_metal_folder(self, folder: Path) -> None:
        """A folder or executable (`metal.exe` / `metallib.exe`) the user chose: resolve to the
        Metal Developer Tools root that `metal_dir()` accepts."""
        from .win import toolchain as wtc
        resolved = wtc.resolve_metal_dir(folder)
        if resolved is None:
            self.log(self.t('dep.pick.metal.invalid', str(folder)) + '\n')
            return
        wtc.save_config('metal_dir', str(resolved))
        self.log(self.t('dep.pick.saved', str(resolved)) + '\n')
        self.check_deps()

    def install_ios_sdk_archive(self, archive_path: Path) -> None:
        """Unpack an `iPhoneOS*.sdk.zip` or `Xcode_*.xip` the user downloaded and remember the SDK."""
        if not archive_path.is_file():
            self.log(self.t('dep.pick.iossdk.invalid', str(archive_path)) + '\n')
            return
        self._sdk_archive = archive_path
        dep = next((d for d in self.deps if d.id == 'ios_sdk'), None)
        if dep is None:
            return
        self._install_win(dep, 'ios_sdk_archive')

    def install_metal_zip(self, zip_path: Path) -> None:
        """Unpack the Apple zip the player downloaded and remember the folder (the one manual
        dependency on Windows: Apple-ID-gated, so the app cannot fetch it itself)."""
        if not zip_path.is_file():
            self.log(self.t('dep.pick.metal.invalid', str(zip_path)) + '\n')
            return
        self._metal_zip = zip_path
        dep = next((d for d in self.deps if d.id == 'metal'), None)
        if dep is None:
            return
        self._install_win(dep, 'metal_zip')

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

    @staticmethod
    def bundled_wheels() -> Path | None:
        """The wheel folder shipped in the Windows zip (`wheels/` beside the exe).

        The build packages (lz4, capstone, fonttools, nsz, backports.zstd) are downloaded by the
        release workflow at packaging time, so the venv step installs from disk with no network
        and no PyPI — the same "the app carries it" promise the Mac's bundled CPython makes.
        Source runs have no such folder and fall back to PyPI.
        """
        cands: list[Path] = []
        meipass = getattr(sys, '_MEIPASS', None)
        if meipass:
            cands.append(Path(meipass))
            cands.append(Path(meipass).parent)
        cands.append(Path(sys.executable).parent)
        for base in cands:
            w = Path(base) / 'wheels'
            if w.is_dir() and any(w.glob('*.whl')):
                return w
        return None

    @staticmethod
    def _pip_args(pkgs: list[str], wheels: Path | None) -> list[str]:
        """pip's arguments: offline from the bundled wheels when they cover the packages."""
        if wheels:
            return ['install', '--no-index', '--find-links', str(wheels)] + pkgs
        return ['install'] + pkgs

    def _make_venv(self, base: str, dep: Dep | None = None) -> bool:
        """Create or reuse the app's venv and install the build packages into it."""
        if dep is None:
            dep = next((d for d in getattr(self, 'deps', []) if d.id == 'python' and d.installing), None)
        can_prog = dep is not None and hasattr(self, '_set_dep_progress') and hasattr(self, 't')
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
            if can_prog and dep is not None:
                bver = pu._python_version(base) or '3.12'
                self._set_dep_progress(
                    dep,
                    self.t('dep.stage.pyInstall'),
                    self.t('dep.detail.pyInstall', bver),
                    75,
                    item_overall_pct=55,
                    force=True,
                )
            vdir = pu.venv_dir()
            vdir.parent.mkdir(parents=True, exist_ok=True)
            self.log(f'$ {base} -m venv {vdir}\n')
            if not pu._runs(base, ['-m', 'venv', str(vdir)]):
                self.log('venv creation failed\n')
                return False
        ver_str = pu._python_version(vpy)
        ver = pu._ver_tuple(ver_str)
        pkgs = ['lz4', 'capstone', 'fonttools', 'zbic', 'nsz']
        if ver < (3, 14):
            pkgs.insert(4, 'backports.zstd')
        wheels_fn = getattr(self, 'bundled_wheels', Model.bundled_wheels)
        wheels = wheels_fn()
        for attempt_wheels in ([wheels, None] if wheels else [None]):
            args = self._pip_args(pkgs, attempt_wheels)
            self.log(f'$ {vpy} -m pip {" ".join(args)}'
                     + ('' if attempt_wheels else '  (from PyPI)') + '\n')
            if can_prog and dep is not None:
                self._set_dep_progress(
                    dep,
                    self.t('dep.stage.pyPkgs', 0),
                    self.t('dep.detail.pyPkgs', 0, len(pkgs), pkgs[0]),
                    0,
                    item_overall_pct=60,
                    force=True,
                )
            try:
                p = subprocess.Popen([vpy, '-m', 'pip'] + args, stdout=subprocess.PIPE,
                                     stderr=subprocess.STDOUT, text=True, encoding='utf-8',
                                     errors='replace', env=pu.child_env(), **pu.no_window_kwargs())
                assert p.stdout is not None
                seen_pkgs: list[str] = []
                for line in p.stdout:
                    self.log(line)
                    if can_prog and dep is not None:
                        low = line.lower()
                        for pk in pkgs:
                            pk_low = pk.lower()
                            pk_norm = pk_low.replace('.', '_').replace('-', '_')
                            if (pk_low in low or pk_norm in low) and pk not in seen_pkgs:
                                seen_pkgs.append(pk)
                                cnt = len(seen_pkgs)
                                pct = min(95, max(10, cnt * 100 // len(pkgs)))
                                summary = f"{pk} ({', '.join(seen_pkgs)})" if cnt > 1 else pk
                                self._set_dep_progress(
                                    dep,
                                    self.t('dep.stage.pyPkgs', pct),
                                    self.t('dep.detail.pyPkgs', cnt, len(pkgs), summary),
                                    pct,
                                    item_overall_pct=60 + pct * 40 // 100,
                                )
                p.wait()
                if p.returncode == 0:
                    if can_prog and dep is not None:
                        self._set_dep_progress(
                            dep,
                            self.t('dep.stage.pyPkgs', 100),
                            self.t('dep.detail.pyPkgs', len(pkgs), len(pkgs), ', '.join(pkgs)),
                            100,
                            item_overall_pct=100,
                            force=True,
                        )
                    return True
            except OSError as e:
                self.log(f'{e}\n')
                return False
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
        initial_rows = [d for d in self.deps if not d.ok and d.install]
        if not initial_rows:
            return
        for idx, d in enumerate(initial_rows, 1):
            d.queue_index = idx
        self._install_all_running = True
        self.install_all_step = 1
        self.install_all_total = len(initial_rows)
        self.install_all_pct = 0
        try:
            self.depsChanged.emit()
        except RuntimeError:
            pass

        def run_all() -> None:
            try:
                # attempted is keyed by (id, fix): an id may legitimately come back in a later
                # pass with a DIFFERENT fix — installing the Python interpreter turns its row
                # into "pip install the packages", which is exactly the step install-all must
                # then run (the report: only the interpreter was installed, the packages step
                # needed a second click on the row).
                attempted: dict[str, tuple] = {}
                started_ids: list[str] = []
                while True:
                    def pending(d) -> bool:
                        if d.ok or not d.install:
                            return False
                        return attempted.get(d.id) != tuple(d.install)
                    rows = [d for d in self.deps if pending(d)]
                    if not rows:
                        break
                    progressed = False
                    for d in rows:
                        live = next((r for r in self.deps if r.id == d.id), None)
                        if live is None or live.ok or not live.install or live.installing:
                            continue
                        if attempted.get(live.id) == tuple(live.install):
                            continue
                        attempted[live.id] = tuple(live.install)
                        if live.id not in started_ids:
                            started_ids.append(live.id)
                        if len(started_ids) > self.install_all_total:
                            self.install_all_total = len(started_ids)
                        self.install_all_step = started_ids.index(live.id) + 1
                        base_pct = ((self.install_all_step - 1) * 100) // max(self.install_all_total, 1)
                        if base_pct > self.install_all_pct:
                            self.install_all_pct = base_pct
                        self.log(f'--- {self.t(live.title_key)} ---\n')
                        self.install_dep(live)
                        progressed = True
                        waited = 0.0
                        while (
                            not getattr(live, '_install_done', True)
                            or live.installing
                            or any(r.id == live.id and r.installing for r in self.deps)
                        ) and waited < 1800:
                            time.sleep(0.1)
                            waited += 0.1
                        if live.installing or any(r.id == live.id and r.installing for r in self.deps):
                            self.log(self.t('dep.installTimeout') + '\n')
                        # Wait for the post-install check_deps() worker thread so the next step or
                        # pass sees the refreshed self.deps rows (e.g. lld green after llvm, or a
                        # second-stage python fix).
                        check_wait = 0.0
                        while not self.deps_checked and check_wait < 60.0:
                            time.sleep(0.05)
                            check_wait += 0.05
                        done_pct = (self.install_all_step * 100) // max(self.install_all_total, 1)
                        if done_pct > self.install_all_pct:
                            self.install_all_pct = min(100, done_pct)
                    if not progressed:
                        break
                self.check_deps()      # one refresh at the end, with everything in place
                end_wait = 0.0
                while not self.deps_checked and end_wait < 60.0:
                    time.sleep(0.05)
                    end_wait += 0.05
            finally:
                for r in getattr(self, 'deps', []):
                    r.queue_index = 0
                self._install_all_running = False
                self.install_all_step = 0
                self.install_all_total = 0
                self.install_all_pct = 0
                try:
                    self.depsChanged.emit()
                except RuntimeError:
                    pass

        threading.Thread(target=run_all, daemon=True).start()

    @Slot(bool, str)
    def _build_after_sync(self, ok: bool, title_id: str) -> None:
        if ok and not engine.needs_sync_before_build(self.repo_path):
            self.start_build(title_id=title_id or None)
        else:
            self.finished.emit(False, self.t('msg.repoInvalidEmpty'))

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
        try:
            if QThread.currentThread() is self.thread():
                self.logAppended.emit(s)
            else:
                QMetaObject.invokeMethod(self, '_emit_log', Qt.QueuedConnection,
                                         Q_ARG(str, s))
        except RuntimeError:
            return
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
        if inputs.is_game_folder_candidate(d):
            self.take_game_folder(d)
            return
        self.leave_game_folder()
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
        found = inputs.classify(files)
        self.base_path = str(found['base']) if found['base'] else ''
        self.update_path = str(found['update']) if found['update'] else ''
        self.dlc_paths = [str(f) for f in found['dlc']]
        self.repoChanged.emit()

    # ---- a game as a folder of its files or a NUP (Switch 2 games), see inputs.scan_game_folder

    def take_game_folder(self, path: str) -> None:
        """Fill the rows from a game folder or a NUP file, or show the reason it cannot be built on the base row."""
        resolved = inputs.resolve_game_folder(path)
        self.game_dir = str(Path(resolved).parent) if resolved.lower().endswith('.nup') else resolved
        self.game_folder = None
        self.game_folder_problem = ''
        self.base_path = self.update_path = ''
        self.dlc_paths = []
        found = inputs.scan_game_folder(resolved)
        if isinstance(found, inputs.GameFolderProblem):
            self.game_folder_problem = self.t(found.l10n_key, *found.args)
        else:
            why = self.game_folder_engine_problem(found)
            if why:
                self.game_folder_problem = why
            else:
                self.game_folder = found
                self.base_path = found.base_path
                newest = found.newest_update
                self.update_path = newest[1] if newest else ''
                self.dlc_paths = [p for _, p in found.dlc]
        self.repoChanged.emit()

    def leave_game_folder(self) -> None:
        """Back to packages: the folder's rows are emptied, so a picked package never mixes with them."""
        if self.game_folder is None and not self.game_folder_problem:
            return
        self.game_folder = None
        self.game_folder_problem = ''
        self.base_path = self.update_path = ''
        self.dlc_paths = []

    def game_folder_engine_problem(self, found: 'inputs.GameFolderContents') -> str:
        """What the engine lacks for this game: the packer (an older engine) or a profile for the game. '' when nothing,
        and before the engine exists (the build asks again)."""
        eng = self.engine_path
        if not eng or not Path(eng, 'dm').is_dir():
            return ''
        builds = inputs.engine_builds_nups(eng) if found.nup else inputs.engine_builds_folders(eng)
        if not builds:
            return self.t('folder.engineOldNUP' if found.nup else 'folder.engineOld')
        if found.has_title_id and not inputs.engine_has_profile(found.title_id, eng):
            return self.t('folder.noProfile', found.title_id_hex)
        return ''

    def input_row_text(self, key: str) -> str | None:
        """A row's text while a game folder is chosen, None otherwise (the row then shows its files as for packages)."""
        f = self.game_folder
        if f is None:
            return None
        if key == 'base':
            if f.nup is None:
                return self.t('folder.base', f.title_id_hex)
            return self.t('folder.nupBase', f.title_id_hex) if f.has_title_id else self.t('folder.nupBaseNoID')
        if key == 'update':
            newest = f.newest_update
            if newest is None:
                return self.t('data.notSelectedOptional')
            return (self.t('folder.updates', newest[0], len(f.updates)) if len(f.updates) > 1
                    else self.t('folder.update', newest[0]))
        if key == 'dlc':
            return self.t('folder.dlc', len(f.dlc)) if f.dlc else self.t('data.notSelectedDlc')
        if key == 'keys':
            return self.t('folder.keys')
        return None

    @property
    def build_key(self) -> str:
        """The name of the work folder and the app (<key>_build, <key>.app): the folder's title ID, else the base package's."""
        f = self.game_folder
        if f is None:
            return inputs.build_key(self.base_path)
        return f.title_id_hex if f.has_title_id else inputs.build_key(f.script_input)

    @property
    def can_build(self) -> bool:
        # a game folder needs no keys, a refused one cannot build
        inputs_ready = self.game_folder is not None or (bool(self.base_path) and bool(self.keys_path))
        return self.repo_ok and inputs_ready and self.all_deps_ok and not self.running

    # ---- build

    def _package_inputs(self) -> tuple[str, ...]:
        return (self.repo_path, self.base_path, self.update_path, *self.dlc_paths)

    @property
    def selectable_titles(self) -> tuple[str, ...]:
        if self.failure and self._last_build_inputs == self._package_inputs():
            return self.failure.title_ids
        return ()

    def start_build(self, *, title_id: str | None = None) -> None:
        if self.running or (title_id is not None and title_id not in self.selectable_titles):
            return
        self._last_error = ''
        self.failure = None
        if not self.repo_ok:
            self.finished.emit(False, self.t('msg.repoInvalidEmpty'))
            return
        if self.game_folder is None and not self.base_path:
            return
        if engine.needs_sync_before_build(self.repo_path):
            # engine/ is the only engine and is stale or missing: make it, then build (a failed sync names its fix in the log)
            self.sync_engine(lambda ok: QMetaObject.invokeMethod(
                self, '_build_after_sync', Qt.QueuedConnection, Q_ARG(bool, ok), Q_ARG(str, title_id or '')))
            return
        py = self.python_path or ('python' if pu.IS_WIN else '/usr/bin/python3')
        folder = self.game_folder
        if folder is not None:
            why = self.game_folder_engine_problem(folder)
            if why:
                self.finished.emit(False, why)
                return
        base_dir = folder.folder if folder is not None else str(Path(self.base_path).parent)
        # a game folder or a NUP goes to the script as it is: nothing is staged and no file is a package
        all_files = [] if folder is not None else [f for f in ([self.base_path, self.update_path] + list(self.dlc_paths)) if f]
        dirs = {str(Path(f).parent) for f in all_files}
        picked = {Path(f).name for f in all_files}
        unpicked: list[str] = []
        if folder is None:
            try:
                unpicked = sorted(
                    n for n in os.listdir(base_dir)
                    if not n.startswith('._')
                    and Path(n).suffix.lower() in inputs.GAME_SUFFIXES
                    and n not in picked
                    and Path(base_dir, n).is_file()
                )
            except OSError:
                unpicked = []
        staged = list(all_files)
        if folder is None:
            base_tid = int(title_id, 16) if title_id else inputs.title_id(Path(self.base_path).name)
            if base_tid is not None:
                app = base_tid & ~0xFFF
                upd_candidates: list[str] = []
                for f in unpicked:
                    ftid = inputs.title_id(f)
                    if ftid is None or inputs.owner(ftid) != app:
                        continue
                    low = ftid & 0xFFF
                    if low == 0:
                        continue
                    if low == 0x800:
                        if not self.update_path:
                            upd_candidates.append(f)
                        continue
                    if ftid <= app:
                        continue
                    staged.append(str(Path(base_dir, f)))
                if upd_candidates:
                    best_upd = max(upd_candidates, key=lambda n: (inputs.update_version(n), n))
                    staged.append(str(Path(base_dir, best_upd)))

        self._last_build_inputs = self._package_inputs()
        tid_hex = title_id or self.build_key
        work_dir = str(Path(self.out_dir or base_dir, f'{tid_hex}_build'))

        input_dir = folder.script_input if folder is not None else base_dir
        if folder is None and (
            len(dirs) > 1
            or bool(unpicked)
            or any(input_staging.needs_lowercase_name(f) for f in staged if f)
        ):
            # (a .NSP or .Xci file goes through it too, under a lowercase extension: the script's glob misses it, #554)
            # files from different folders or a shared ROMs folder: a stable folder of links per game, so the script sees
            # one game and its fingerprints match on the next build (#58, #132)
            staging = input_staging.folder(work_dir)
            if input_staging.sync(staged, staging, hard_links=not pu.IS_WIN) == 0:
                self.finished.emit(False, self.t('msg.stagingFailed'))
                return
            input_dir = staging
            if unpicked:
                self.log(self.t('msg.stagedFromSharedFolder', Path(self.base_path).name) + '\n')

        compressed = any(Path(f).suffix.lower() in ('.nsz', '.xcz')
                         for f in staged if f)
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
            entry = [str(Path(self.engine_path, 'scripts', 'build_ipa_from_nsp.py'))]
            cwd = self.engine_path
        # a game folder's files are not encrypted: no -k, the keys are not asked for
        args = entry + [input_dir] + ([] if folder is not None else ['-k', self.keys_path]) + ['--progress', 'lines']
        if title_id:
            args += ['--title-id', title_id]
        has_work_dir = self.supports_work_dir()
        if has_work_dir:
            args += ['--work-dir', work_dir]
        else:
            self.log(self.t('msg.noWorkDir') + '\n')
        # A Mac app is a different output, not a different pipeline: --platform mac-app runs the
        # same steps and then packs dm/mac/pack_app.py's result. Its -o names the .app, and the
        # RomFS is inside it, so the archive step is skipped below.
        self.ipa_path = self.archive_path = self.mac_app_path = ''
        mac_app = self.target == 'mac-app'
        self.effective_work_dir = work_dir if has_work_dir else str(Path(base_dir if folder is not None else input_dir, f'{tid_hex}_build'))
        use_shell_fw = not mac_app and self.ipa_kind == 'shared' and self.supports_shell_framework()
        if mac_app:
            args += ['--platform', 'mac-app']
            self.mac_app_path = str(Path(self.out_dir or base_dir, f'{tid_hex}.app'))
            args += ['-o', self.mac_app_path]
        elif use_shell_fw:
            from .win import shell_export as se
            tpl = se.find_shell_template(self.engine_path, root=self.shell_cache_path, log=self.log)
            if tpl is None or not (tpl / se.SCHEME).is_file():
                self.finished.emit(False, self.t('shell.exportFailed', f'missing {se.APP_NAME} template'))
                return
            sf_dir = Path(self.effective_work_dir, 'shell-framework')
            if sf_dir.is_dir():
                for old_fw in sf_dir.glob('DmGame*.framework'):
                    shutil.rmtree(old_fw, ignore_errors=True)
            args += ['--shell-framework', str(sf_dir)]
        elif self.out_dir or title_id:
            self.ipa_path = str(Path(self.out_dir or base_dir, f'{tid_hex}.ipa'))
            args += ['-o', self.ipa_path]
        if self.bc_on_cpu and not mac_app:
            try:
                Path(self.effective_work_dir).mkdir(parents=True, exist_ok=True)
                env_file = Path(self.effective_work_dir, '_env.txt')
                env_file.write_text('DM_TEX_BC_CPU=1\n', encoding='utf-8')
                args += ['--env-file', str(env_file)]
                self.log(self.t('msg.bcOn') + '\n')
            except OSError as e:
                self.log(self.t('msg.bcEnvFailed', str(e)) + '\n')
        flag = self.override.take()   # for this build only: the next one asks again
        args = bf.arguments(args, flag)

        input_game = None
        if self.base_path:
            input_game = self.library.remember_inputs(
                base_path=self.base_path,
                update_path=self.update_path,
                dlc_paths=self.dlc_paths,
                keys_path=self.keys_path,
                output_dir=self.out_dir,
                repo_path=self.engine_path,
                title_id=title_id,
            )
            self._emit_library_changed()

        self.running = True
        self.runningChanged.emit(True)
        self._stop_pso_poll()
        with self._ensure_pso_lock():
            self.stages = []
        self.log_tail = ''
        self._last_error = ''
        self.failure = None
        self.override.cancel()
        self.stagesChanged.emit()
        if flag:
            self.log(self.t('fail.override.note', flag) + '\n')
        self.log(self.t('msg.running', py + ' ' + ' '.join(args)) + '\n')

        env = pu.child_env()
        if self.ipa_kind == 'oneGame' and not mac_app:
            env['DM_FULL_ROMFS'] = '1'
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
                cwd = str(wshim.clean_pkg_root(wshim.shim_dir()))
                ok_shim, why = wshim.verify_shim(env)
                if not ok_shim:
                    self.log(f'[shim] {why}\n')
            except Exception as e:      # a broken shim must be visible, not fatal
                self.log(f'[shim] could not prepare the Windows shim: {e}\n')
            env['NSPB_REPO'] = self.engine_path

        def run_build() -> tuple[bool, str]:
            ok = False
            try:
                self._proc = subprocess.Popen([py] + args, cwd=cwd,
                                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                              text=True, encoding='utf-8', errors='replace',
                                              bufsize=1, env=env,
                                              **pu.no_window_kwargs())
                assert self._proc.stdout is not None
                for line in self._proc.stdout:
                    self._on_line(line.rstrip('\n'))
                self._proc.wait()
                ok = self._proc.returncode == 0
            except OSError as e:
                self.log(f'{e}\n')
            finally:
                self._stop_pso_poll()
                self._proc = None
            self._flush_lines()
            if ok and mac_app:
                ok = bool(self.mac_app_path) and Path(self.mac_app_path).exists()
                note = self.t('target.macDone' if ok else 'target.missingApp')
                if ok and input_game:
                    input_game.app_path = self.mac_app_path
                    self.library.upsert(input_game)
                    self._emit_library_changed()
            elif ok:
                for st in self.stages:
                    if st.state == 'running':
                        st.state = 'done'
                self.stagesChanged.emit()
                if self.ipa_kind != 'oneGame':
                    return self.pack_archive(title_id, export_shell=use_shell_fw)
                if not self.ipa_path:
                    self.ipa_path = str(Path(base_dir, f'{tid_hex}.ipa'))
                self._record_library_ios_completion(title_id)
                note = self.t('shell.oneGameDone', self.ipa_path)
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
            return ok, note

        def work() -> None:
            try:
                ok, note = run_build()
            except Exception as e:
                self.log(f'{e}\n')
                if self.stages:
                    self.stages[-1].state = 'failed'
                    self.stagesChanged.emit()
                ok, note = False, self.t('msg.buildFailedReason', str(e))
            finally:
                self.running = False
                self.runningChanged.emit(False)
            self.finished.emit(ok, note)

        self._thread = threading.Thread(target=work, daemon=True)
        self._thread.start()

    def failure_what(self, f: 'bf.Failure') -> str:
        """The first sentence of a failure's hint (it names the game of a 32-bit program when the message does)."""
        if f.kind == bf.A32_PROGRAM and f.game:
            return self.t('fail.a32Program.whatNamed', f.game)
        if f.kind == bf.DISK_FULL and f.detail:
            return self.t('fail.diskFull.whatNeeds', f.detail)
        if f.kind == bf.PSO_DISK_FULL and f.detail:
            return self.t('fail.psoDiskFull.whatNeeds', f.detail)
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
        elif f.kind == bf.ZBIC:
            # the python row's own fix (a venv with the packages, zbic among them): the row may read OK, so the command is built here
            self.install_dep(Dep('python', 'dep.python', 'dep.python.hint', DepState.MISSING,
                                 install=[self.python_path, '-m', 'pip', 'install', 'zbic']))
        elif f.kind == bf.IOS_SDK and not pu.IS_WIN:
            self.install_dep(Dep('xcode', 'dep.xcode', 'dep.xcode.hint', DepState.MISSING,
                                 install=['/usr/bin/xcodebuild', '-downloadPlatform', 'iOS']))

    def cancel_build(self) -> None:
        self._stop_pso_poll()
        if self._proc and self._proc.poll() is None:
            self._proc.terminate()

    # ---- the script's own progress lines

    def _ensure_pso_lock(self) -> threading.RLock:
        lock = getattr(self, '_pso_lock', None)
        if lock is None:
            lock = threading.RLock()
            self._pso_lock = lock
        return lock

    def _is_pso_stage_text(self, text: str) -> bool:
        low = text.lower()
        return 'pipeline archive' in low or self.t('stage.pipeline_archive').lower() in low

    def _start_pso_poll(self) -> None:
        lock = self._ensure_pso_lock()
        with lock:
            self._stop_pso_poll()
            self._pso_native_progress = False
            gen = self._pso_poll_gen
            stop_ev = threading.Event()
            self._pso_poll_stop = stop_ev
        self.poll_pso_archive()

        def loop() -> None:
            while not stop_ev.wait(1.0):
                with lock:
                    if getattr(self, '_pso_native_progress', False) or getattr(self, '_pso_poll_gen', 0) != gen:
                        break
                self.poll_pso_archive()

        threading.Thread(target=loop, daemon=True).start()

    def _stop_pso_poll(self) -> None:
        with self._ensure_pso_lock():
            self._pso_poll_gen = getattr(self, '_pso_poll_gen', 0) + 1
            ev = getattr(self, '_pso_poll_stop', None)
            if ev is not None:
                ev.set()
                self._pso_poll_stop = None

    def _on_line(self, line: str) -> None:
        """Feed one line of the build's output: stage lines move the stage list, everything
        else goes to the log (which is what the window shows)."""
        self.log(line + '\n')
        self.log_tail = (self.log_tail + line + '\n')[-12000:]   # what the classifier reads on a failure
        body = re.sub(r'^\[\d\d:\d\d:\d\d\]\s*', '', line).strip()
        # The last line that was not stage bookkeeping: a failed build's summary used to be the
        # bare exit code ("Build failed (exit code 1)"), which told the reporter nothing and sent
        # them looking for a log that a short window had below the fold (issue #52)
        m_stage = _STAGE_LINE_RE.match(body)
        is_stage = m_stage is not None
        if body and not is_stage:
            self._last_error = body[:200]
        if body.startswith('output IPA:'):
            self.ipa_path = body.split(':', 1)[1].strip()
        lock = self._ensure_pso_lock()
        if not is_stage:
            action = ''
            with lock:
                for st in self.stages:
                    if st.state == 'running':
                        if not (self._is_pso_stage_text(st.name) and st.percent > 0):
                            st.detail = body[:120]
                        if body.lower().startswith('pipeline archive for'):
                            action = 'start'
                        elif _PSO_LOG_BATCH_RE.search(body) or _PSO_LOG_MERGE_RE.search(body):
                            action = 'poll'
                        break
            if action == 'start':
                self._start_pso_poll()
            elif action == 'poll':
                self.poll_pso_archive()
            return

        assert m_stage is not None
        prefix_mark = m_stage.group(1)
        k = int(m_stage.group(2))
        rest = m_stage.group(4).strip()
        status_mark = prefix_mark
        if status_mark is None:
            for sym in ('✗', '⚠', '✓'):
                if sym in rest:
                    status_mark = sym
                    break

        if status_mark is not None:
            emit_changed = False
            with lock:
                existing = next((st for st in self.stages if st.id == k), None)
                if existing is None and self.stages and self.stages[-1].id == 0 and self.stages[-1].state == 'running':
                    existing = self.stages[-1]
                    existing.id = k
                self._stop_pso_poll()
                summary = ''
                head = rest
                if '): ' in head:
                    head, summary = head.split('): ', 1)
                    head = head + ')'
                    summary = summary.strip()
                head = re.sub(r'\s*\([^()]*\)\s*$', '', head)
                head = re.sub(r'[✓✗⚠]', '', head).strip()
                target_state = 'failed' if status_mark == '✗' else 'done'
                if existing is not None:
                    if head and not existing.name:
                        existing.name = head
                    existing.state = target_state
                    if target_state == 'done' and existing.percent > 0:
                        existing.percent = 100.0
                    if summary:
                        existing.detail = summary
                    emit_changed = True
                elif head:
                    self.stages.append(
                        Stage(
                            id=k,
                            name=head,
                            state=target_state,
                            detail=summary,
                            percent=100.0 if target_state == 'done' else 0.0,
                        )
                    )
                    emit_changed = True
            if emit_changed:
                self.stagesChanged.emit()
            return

        # Running line: initial stage start, step change ("…"), percentage update ("66%"), or uncounted heartbeat (": 0:30")
        pct_m = re.search(r'(\d+(?:\.\d+)?)%', rest)
        should_start_poll = False
        with lock:
            existing = next((st for st in self.stages if st.id == k), None)
            if existing is not None:
                existing.state = 'running'
                if pct_m:
                    if self._is_pso_stage_text(existing.name) or self._is_pso_stage_text(rest):
                        self._pso_native_progress = True
                        self._stop_pso_poll()
                    existing.percent = min(float(pct_m.group(1)), 100.0)
                    after = rest[pct_m.end():].lstrip(' ·,:')
                    if after:
                        existing.detail = after
                elif rest.endswith(' …'):
                    clean_name = rest[:-2].strip()
                    if clean_name:
                        existing.name = clean_name
                    if self._is_pso_stage_text(clean_name):
                        if not getattr(self, '_pso_native_progress', False) and getattr(self, '_pso_poll_stop', None) is None:
                            should_start_poll = True
                    else:
                        self._stop_pso_poll()
                elif ': ' in rest:
                    _head_part, hb_detail = rest.split(': ', 1)
                    if not (self._is_pso_stage_text(existing.name) and existing.percent > 0):
                        existing.detail = hb_detail.strip()
            else:
                for st in self.stages:
                    if st.state == 'running':
                        st.state = 'done'
                clean_name = re.sub(r'\s+…$', '', rest).strip()
                detail = ''
                pct = 0.0
                if pct_m:
                    pct = min(float(pct_m.group(1)), 100.0)
                    clean_name = rest[:pct_m.start()].rstrip(' ·:')
                    detail = rest[pct_m.end():].lstrip(' ·,:')
                elif ': ' in clean_name:
                    clean_name, detail = [p.strip() for p in clean_name.split(': ', 1)]
                self.stages.append(Stage(id=k, name=clean_name, state='running', detail=detail, percent=pct))
                if self._is_pso_stage_text(clean_name):
                    if pct_m:
                        self._pso_native_progress = True
                        self._stop_pso_poll()
                    else:
                        should_start_poll = True
                else:
                    self._stop_pso_poll()
        if should_start_poll:
            self._start_pso_poll()
        self.stagesChanged.emit()

    def poll_pso_archive(self) -> None:
        """Update the running Pipeline archive stage from pso_offline.py's work folder when present."""
        lock = self._ensure_pso_lock()
        with lock:
            if getattr(self, '_pso_native_progress', False):
                return
            work = getattr(self, 'effective_work_dir', '')
            if not work:
                return
            st = next(
                (
                    s for s in reversed(self.stages)
                    if s.state == 'running'
                    and (self._is_pso_stage_text(s.name) or self._is_pso_stage_text(s.detail))
                ),
                None,
            )
            if st is None:
                return
            gen = getattr(self, '_pso_poll_gen', 0)
            stage_id = st.id
        prog = pso_archive_progress(work)
        if prog is None:
            return
        done, total, merging = prog
        pct = min(done / total * 100.0, 99.0)
        unit = self.t('prog.unit.batches')
        note = (' · ' + self.t('prog.note.merging')) if merging else ''
        detail = f'{done:,} / {total:,} {unit}{note}'
        changed = False
        with lock:
            if getattr(self, '_pso_native_progress', False):
                return
            if getattr(self, '_pso_poll_gen', 0) != gen:
                return
            if getattr(self, 'effective_work_dir', '') != work:
                return
            if st not in self.stages or st.id != stage_id or st.state != 'running':
                return
            if not (self._is_pso_stage_text(st.name) or self._is_pso_stage_text(st.detail)):
                return
            if st.percent != pct or st.detail != detail:
                st.percent = pct
                st.detail = detail
                changed = True
        if changed:
            try:
                self.stagesChanged.emit()
            except RuntimeError:
                pass

    def _flush_lines(self) -> None:
        self._line_buf = ''

    # ---- the archive step (what makes a 16 GB game installable)

    def _verified_title_id(self, work: str = '', title_id: str | None = '') -> str:
        if re.fullmatch(r'[0-9A-Fa-f]{16}', title_id or ''):
            return (title_id or '').upper()

        def _from_work(w: str) -> str:
            if not w:
                return ''
            try:
                from .win import shell_export as se
                fw = se.built_framework(w)
                if fw is not None:
                    ftid = se.title_id_of_framework(fw)
                    if re.fullmatch(r'[0-9A-Fa-f]{16}', ftid or ''):
                        return ftid.upper()
                    mp = fw / 'game.manifest.json'
                    if mp.is_file():
                        data = json.loads(mp.read_text(encoding='utf-8'))
                        mtid = str(data.get('title_id') or '').strip() if isinstance(data, dict) else ''
                        if re.fullmatch(r'[0-9A-Fa-f]{16}', mtid):
                            return mtid.upper()
            except Exception:
                pass
            lp = Path(w, 'Gen', 'launcher.json')
            if lp.is_file():
                try:
                    data = json.loads(lp.read_text(encoding='utf-8'))
                    ltid = str((data.get('title_id') or data.get('game')) or '').strip() if isinstance(data, dict) else ''
                    if re.fullmatch(r'[0-9A-Fa-f]{16}', ltid):
                        return ltid.upper()
                except Exception:
                    pass
            return ''

        if work:
            wtid = _from_work(work)
            if wtid:
                return wtid
        arch = getattr(self, 'archive_path', '') or ''
        if arch:
            ap = Path(arch)
            if ap.parent.name == 'games' and re.fullmatch(r'[0-9A-Fa-f]{16}', ap.name):
                return ap.name.upper()
        sel = self.library.selected
        if sel is not None and re.fullmatch(r'[0-9A-Fa-f]{16}', sel.title_id or ''):
            sel_base = (sel.inputs.get('base') or [''])[0]
            cur_base = self.game_folder.folder if self.game_folder is not None else self.base_path
            if not cur_base or not sel_base or os.path.normcase(os.path.abspath(sel_base)) == os.path.normcase(os.path.abspath(cur_base)):
                return sel.title_id.upper()
        bk = self.build_key
        if re.fullmatch(r'[0-9A-Fa-f]{16}', bk or ''):
            return bk.upper()
        wtid = _from_work(getattr(self, 'effective_work_dir', ''))
        if wtid:
            return wtid
        return (title_id or bk or 'game')

    @property
    def packed_title_id(self) -> str:
        return self._verified_title_id()

    def effective_archive_path(self) -> str:
        if self.archive_path and (
            os.path.isfile(os.path.join(self.archive_path, 'romfs.img'))
            or os.path.isdir(os.path.join(self.archive_path, 'romfs'))
            or os.path.isdir(os.path.join(self.archive_path, 'aoc'))
        ):
            return self.archive_path
        tid = self._verified_title_id()
        roots: list[str] = []
        if self.out_dir:
            roots.append(self.out_dir)
        if self.game_folder is not None and self.game_folder.folder:
            roots.append(self.game_folder.folder)
        elif self.base_path:
            roots.append(os.path.dirname(self.base_path))
        if re.fullmatch(r'[0-9A-Fa-f]{16}', tid or ''):
            for r in roots:
                cand = os.path.join(r, 'games', tid.upper())
                if (
                    os.path.isfile(os.path.join(cand, 'romfs.img'))
                    or os.path.isdir(os.path.join(cand, 'romfs'))
                    or os.path.isdir(os.path.join(cand, 'aoc'))
                ):
                    return cand
        for r in roots:
            cand = os.path.join(r, 'romfs')
            if os.path.isfile(os.path.join(cand, 'romfs.img')) or os.path.isdir(cand):
                return cand
        return ''

    def copy_archive_to_drive(
        self,
        dest_root: str,
        progress_cb: Callable[[int, int], None] | None = None,
    ) -> tuple[bool, str]:
        arch = self.effective_archive_path()
        if not arch or not dest_root:
            return False, ''
        tid = self.packed_title_id
        return lib.DriveCopy.copy_to_folder(
            arch,
            dest_root,
            tid,
            progress_cb=progress_cb,
        )

    def pack_archive(self, title_id: str | None = None, *, export_shell: bool = False) -> tuple[bool, str]:
        """Run the final shared-build step on the build worker."""
        work = getattr(self, 'effective_work_dir', '')
        tid = self._verified_title_id(work, title_id)
        extract = Path(work, 'extract')
        versions = []
        if extract.is_dir():
            for d in sorted(extract.iterdir()):
                if d.is_dir() and d.name.startswith('v') and (
                        (d / 'RomFS').is_dir() or (d / 'RomFS.img').is_file()):
                    try:
                        versions.append((int(d.name[1:]), d))
                    except ValueError:
                        pass
            versions.sort(key=lambda x: x[0])
        if not versions:
            if export_shell:
                return self._export_shell_after_archive(True, self.t('msg.archiveSkipped', str(extract)))
            return True, self.t('msg.archiveSkipped', str(extract))
        ver_dir = versions[-1][1]
        romfs_img = ver_dir / 'RomFS.img'
        romfs = str(ver_dir / 'RomFS')
        base_parent = Path(self.game_folder.folder) if self.game_folder is not None else Path(self.base_path).parent
        # games/<id>/ is the per-game layout the shell reads and matches BuildStore+Archive.swift
        if export_shell or bool(title_id) or re.fullmatch(r'[0-9A-Fa-f]{16}', tid):
            dest = str(Path(self.out_dir or base_parent, 'games', tid.upper() if re.fullmatch(r'[0-9A-Fa-f]{16}', tid) else tid))
        else:
            dest = str(Path(self.out_dir or base_parent, 'romfs'))
        self.stages.append(Stage(name=self.t('prog.archiveShort'), state='running'))
        self.stagesChanged.emit()

        ok = True
        out_img = Path(dest, 'romfs.img')
        id_src = Path(f'{romfs_img}.id')
        id_dst = Path(f'{out_img}.id')
        try:
            Path(dest).mkdir(parents=True, exist_ok=True)
            if romfs_img.is_file():
                reused = (out_img.is_file()
                          and out_img.stat().st_size == romfs_img.stat().st_size
                          and abs(out_img.stat().st_mtime - romfs_img.stat().st_mtime) < 1)
                if reused and out_img.stat().st_size <= 1024 * 1024:
                    try:
                        reused = out_img.read_bytes() == romfs_img.read_bytes()
                    except OSError:
                        reused = False
                if not reused:
                    out_img.unlink(missing_ok=True)
                    try:
                        os.link(romfs_img, out_img)
                    except OSError:
                        shutil.copy2(romfs_img, out_img)
                id_dst.unlink(missing_ok=True)
                if id_src.is_file():
                    shutil.copy2(id_src, id_dst)
            else:
                py_exe = self.python_path
                if not py_exe:
                    from .win import shell_export as se
                    py_exe = se._resolve_python_exe(self.python_path)
                args = [py_exe,
                        str(Path(self.engine_path, 'dm', 'tools', 'romfs_image.py')),
                        '--reuse', romfs, str(out_img)]
                env = pu.child_env({'PYTHONPATH': str(Path(self.engine_path, 'dm', 'tools'))})
                p = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                     text=True, encoding='utf-8', errors='replace', env=env,
                                     **pu.no_window_kwargs())
                assert p.stdout is not None
                for line in p.stdout:
                    self.log(line)
                p.wait()
                ok = p.returncode == 0
                id_dst.unlink(missing_ok=True)
                if ok and id_src.is_file():
                    shutil.copy2(id_src, id_dst)
            aoc_dst = Path(dest, 'aoc')
            aoc_src = Path(work, 'aoc')
            if ok:
                shutil.rmtree(aoc_dst, ignore_errors=True)
                if aoc_src.is_dir() and any(aoc_src.iterdir()):
                    shutil.copytree(aoc_src, aoc_dst)
                try:
                    from .win import shell_export as se
                    fw = se.built_framework(work)
                    if fw is not None:
                        romfs_languages.apply_to_launcher_json(fw / 'dm' / 'launcher.json', dest)
                except Exception:
                    pass
        except OSError as e:
            self.log(f'{e}\n')
            ok = False
        if self.stages:
            self.stages[-1].state = 'done' if ok else 'failed'
        self.archive_path = dest if ok else ''
        self.stagesChanged.emit()
        if ok and export_shell:
            return self._export_shell_after_archive(True, '')
        if ok:
            self._record_library_ios_completion(tid if (title_id or re.fullmatch(r'[0-9A-Fa-f]{16}', tid)) else None)
        return ok, '' if ok else self.t('msg.archiveFailed')

    def _export_shell_after_archive(self, archive_ok: bool, archive_note: str) -> tuple[bool, str]:
        if not archive_ok:
            return False, archive_note or self.t('msg.archiveFailed')
        from .win import shell_export as se

        work = getattr(self, 'effective_work_dir', '')
        fw = se.built_framework(work)
        tid = self._verified_title_id(work, se.title_id_of_framework(fw) if fw else '')
        if fw is None:
            fw = Path(work, 'shell-framework', f'DmGame{tid}.framework')

        game_name = ''
        manifest_p = fw / 'game.manifest.json'
        if manifest_p.is_file():
            try:
                data = json.loads(manifest_p.read_text(encoding='utf-8'))
                if isinstance(data, dict):
                    game_name = str(data.get('name') or '').strip()
            except Exception:
                pass
        if not game_name:
            game_name = (
                lib.GameFolder.profile_name(tid, self.engine_path)
                or (lib.clean_game_name(self.base_path) if self.base_path else '')
                or tid
            )

        def on_stage(stage_name: str, state: str) -> None:
            for st in self.stages:
                if st.name == stage_name:
                    st.state = state
                    self.stagesChanged.emit()
                    return
            self.stages.append(Stage(name=stage_name, state=state))
            self.stagesChanged.emit()

        py = self.python_path or sys.executable
        picked = self.artwork.custom_paths.get(tid.upper())
        ok, out_ipa, msg, _notes = se.export_shell(
            root=self.shell_cache_path,
            repo=self.engine_path,
            framework=fw,
            title_id=tid,
            name=game_name,
            python_exe=py,
            banners_dir=self.artwork.banners_dir,
            picked_artwork=picked,
            t_func=self.t,
            log=self.log,
            stage_cb=on_stage,
        )
        if ok:
            self.ipa_path = out_ipa
            self._record_library_ios_completion(tid, name=game_name)
        return ok, msg

    def _record_library_ios_completion(self, title_id: str | None = None, name: str = '') -> None:
        inputs_map: dict[str, list[str]] = {}
        if self.base_path:
            inputs_map['base'] = [self.base_path]
        if self.update_path:
            inputs_map['update'] = [self.update_path]
        if self.dlc_paths:
            inputs_map['dlc'] = list(self.dlc_paths)
        if self.keys_path:
            inputs_map['keys'] = [self.keys_path]
        g = self.library.record_completed_ios(
            ipa_path=self.ipa_path,
            archive_path=self.archive_path,
            base_path=self.base_path,
            output_dir=self.out_dir,
            inputs=inputs_map,
            repo_path=self.engine_path,
            title_id=title_id,
            name=name,
        )
        if g:
            self.artwork.request_banner_async(g.title_id)
        self._emit_library_changed()

    @staticmethod
    def _title_id(nsp: str) -> int | None:
        """The title ID from a dump's file name: bracketed [0100…] or a bare 16-digit ID."""
        return inputs.title_id(Path(nsp).name)
