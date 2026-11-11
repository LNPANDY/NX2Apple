"""Regression tests for process-tree termination (BUG-05), background drive copy with cancellation
and partial-file cleanup (BUG-05), and full dependency visibility in Onboarding Step 2 (BUG-21)."""
from __future__ import annotations

import ast
import errno
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import types
import unittest
from pathlib import Path
from unittest import mock

os.environ.setdefault('QT_QPA_PLATFORM', 'offscreen')

ROOT = Path(__file__).resolve().parents[2]
QT_DIR = ROOT / 'frontend-qt'
if str(QT_DIR) not in sys.path:
    sys.path.insert(0, str(QT_DIR))

from nspb_qt import platform_util as pu   # noqa: E402

try:
    from PySide6.QtCore import QEvent, QSettings
    from PySide6.QtWidgets import QApplication
    HAS_QT = True
except ImportError:
    HAS_QT = False


def _pid_alive(pid: int) -> bool:
    if pid <= 0:
        return False
    if pu.IS_WIN:
        r = subprocess.run(
            ['tasklist', '/FI', f'PID eq {pid}', '/NH'],
            capture_output=True,
            text=True,
            **pu.no_window_kwargs(),
        )
        return str(pid) in (r.stdout or '')
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def _load_model_with_qt_fallback():
    """Import `nspb_qt.model`, installing a minimal `PySide6.QtCore` stub when PySide6 is absent in CI."""
    try:
        from nspb_qt import model as model_mod
        return model_mod, False, lambda: None
    except ImportError:
        pass

    saved = {k: sys.modules.get(k) for k in ('PySide6', 'PySide6.QtCore', 'nspb_qt.model')}

    class _FakeSignalInstance:
        def __init__(self) -> None:
            self._slots: list = []

        def connect(self, fn) -> None:
            self._slots.append(fn)

        def disconnect(self, fn=None) -> None:
            if fn is None:
                self._slots.clear()
            elif fn in self._slots:
                self._slots.remove(fn)

        def emit(self, *args) -> None:
            for fn in list(self._slots):
                fn(*args)

    class _FakeSignal:
        def __init__(self, *_a) -> None:
            self._name = ''

        def __set_name__(self, _owner, name: str) -> None:
            self._name = f'_sig_{name}'

        def __get__(self, obj, _owner=None):
            if obj is None:
                return self
            inst = getattr(obj, self._name, None)
            if inst is None:
                inst = _FakeSignalInstance()
                setattr(obj, self._name, inst)
            return inst

    class _FakeQObject:
        def __init__(self, *_a, **_kw) -> None:
            pass

        def thread(self):
            return None

        @staticmethod
        def currentThread():
            return None

    class _FakeQSettings:
        def __init__(self, *_a, **_kw) -> None:
            self._d: dict[str, object] = {}

        def value(self, k: str, default: object = '', **kw) -> object:
            fallback = kw.get('defaultValue', default)
            return self._d.get(k, fallback)

        def setValue(self, k: str, v: object) -> None:
            self._d[k] = v

        def remove(self, k: str) -> None:
            self._d.pop(k, None)

    class _FakeQt:
        class ConnectionType:
            QueuedConnection = 0

    class _FakeQMetaObject:
        @staticmethod
        def invokeMethod(obj, name: str, *args) -> None:
            fn = getattr(obj, name, None)
            if callable(fn):
                call_args = args[1:] if args and args[0] == 0 else args
                fn(*call_args)

    qt_pkg = types.ModuleType('PySide6')
    qt_core = types.ModuleType('PySide6.QtCore')
    qt_core.QObject = _FakeQObject
    qt_core.QThread = _FakeQObject
    qt_core.QSettings = _FakeQSettings
    qt_core.Signal = _FakeSignal
    qt_core.Slot = lambda *_a, **_kw: (lambda f: f)
    qt_core.Qt = _FakeQt
    qt_core.QMetaObject = _FakeQMetaObject
    qt_core.Q_ARG = lambda _t, v: v
    qt_pkg.QtCore = qt_core
    sys.modules['PySide6'] = qt_pkg
    sys.modules['PySide6.QtCore'] = qt_core
    from nspb_qt import model as model_mod

    def _cleanup() -> None:
        for k, old in saved.items():
            if old is None:
                sys.modules.pop(k, None)
            else:
                sys.modules[k] = old

    return model_mod, True, _cleanup


CHILD_TREE_CODE = (
    "import os, subprocess, sys, time\n"
    "grand = subprocess.Popen([\n"
    "    sys.executable, '-c',\n"
    "    'import os, signal, sys, time\\n'\n"
    "    'signal.signal(signal.SIGTERM, signal.SIG_IGN)\\n'\n"
    "    'print(\"GRANDCHILD_PID=\" + str(os.getpid()), flush=True)\\n'\n"
    "    'time.sleep(30)\\n'\n"
    "])\n"
    "print('CHILD_PID=' + str(os.getpid()), flush=True)\n"
    "time.sleep(30)\n"
)


class ProcessTreeTerminationTests(unittest.TestCase):
    def test_plain_terminate_leaves_grandchild_holding_stdout_while_kill_process_tree_closes_eof_fast(self) -> None:
        """Verify that plain `proc.terminate()` leaves an inherited-stdout grandchild alive and blocking
        pipe reads, whereas `process_group_kwargs()` + `kill_process_tree(proc)` kills the grandchild
        and closes stdout EOF within < 2 seconds."""
        plain = subprocess.Popen(
            [sys.executable, '-c', CHILD_TREE_CODE],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
        )
        grand_pid_plain = 0
        try:
            assert plain.stdout is not None
            seen_lines: list[str] = []
            while len(seen_lines) < 2:
                ln = plain.stdout.readline()
                if not ln:
                    break
                seen_lines.append(ln.strip())
                if ln.startswith('GRANDCHILD_PID='):
                    grand_pid_plain = int(ln.strip().split('=', 1)[1])
            self.assertGreater(grand_pid_plain, 1)

            eof_plain = threading.Event()

            def drain_plain() -> None:
                assert plain.stdout is not None
                for _ in plain.stdout:
                    pass
                eof_plain.set()

            t_plain = threading.Thread(target=drain_plain, daemon=True)
            t_plain.start()

            plain.terminate()
            plain.wait(timeout=2.0)
            self.assertFalse(eof_plain.wait(0.25), 'Plain terminate unexpectedly closed grandchild pipe')
            self.assertTrue(_pid_alive(grand_pid_plain), 'Grandchild should still be alive after plain terminate')
        finally:
            if grand_pid_plain > 1:
                try:
                    if pu.IS_WIN:
                        subprocess.run(['taskkill', '/F', '/PID', str(grand_pid_plain)], capture_output=True)
                    else:
                        os.kill(grand_pid_plain, signal.SIGKILL)
                except OSError:
                    pass
            if plain.stdout is not None:
                plain.stdout.close()

        grouped = subprocess.Popen(
            [sys.executable, '-c', CHILD_TREE_CODE],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
            **pu.process_group_kwargs(),
        )
        grand_pid_grouped = 0
        try:
            assert grouped.stdout is not None
            seen_grouped: list[str] = []
            while len(seen_grouped) < 2:
                ln = grouped.stdout.readline()
                if not ln:
                    break
                seen_grouped.append(ln.strip())
                if ln.startswith('GRANDCHILD_PID='):
                    grand_pid_grouped = int(ln.strip().split('=', 1)[1])
            self.assertGreater(grand_pid_grouped, 1)

            eof_grouped = threading.Event()

            def drain_grouped() -> None:
                assert grouped.stdout is not None
                for _ in grouped.stdout:
                    pass
                eof_grouped.set()

            t_grouped = threading.Thread(target=drain_grouped, daemon=True)
            t_grouped.start()

            t0 = time.monotonic()
            pu.kill_process_tree(grouped)
            finished_eof = eof_grouped.wait(2.0)
            elapsed = time.monotonic() - t0

            self.assertTrue(finished_eof, 'stdout pipe did not reach EOF within 2 seconds')
            self.assertLess(elapsed, 2.0, f'kill_process_tree took too long: {elapsed:.2f}s')

            deadline = time.monotonic() + 1.0
            while _pid_alive(grand_pid_grouped) and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertFalse(_pid_alive(grand_pid_grouped), 'Grandchild process survived kill_process_tree')
        finally:
            if grand_pid_grouped > 1 and _pid_alive(grand_pid_grouped):
                try:
                    os.kill(grand_pid_grouped, signal.SIGKILL)
                except OSError:
                    pass
            if grouped.stdout is not None:
                grouped.stdout.close()

    def test_windows_process_group_kwargs_and_taskkill_tree_invocation(self) -> None:
        """Verify the Windows branch passes CREATE_NEW_PROCESS_GROUP | CREATE_NO_WINDOW and invokes
        `taskkill /F /T /PID <pid>` before falling back to `proc.kill()`."""
        with (
            mock.patch.object(pu, 'IS_WIN', True),
            mock.patch.object(subprocess, 'CREATE_NEW_PROCESS_GROUP', 0x00000200, create=True),
            mock.patch.object(subprocess, 'CREATE_NO_WINDOW', 0x08000000, create=True),
        ):
            kw = pu.process_group_kwargs()
            self.assertEqual(kw, {'creationflags': 0x08000200})

            fake_proc = mock.Mock()
            fake_proc.pid = 42424
            fake_proc.poll.return_value = None
            with mock.patch.object(pu.subprocess, 'run') as spy_run:
                pu.kill_process_tree(fake_proc)
            spy_run.assert_called_once()
            cmd_called = spy_run.call_args[0][0]
            self.assertEqual(cmd_called, ['taskkill', '/F', '/T', '/PID', '42424'])
            self.assertEqual(spy_run.call_args[1].get('creationflags'), 0x08000000)
            fake_proc.kill.assert_called_once()


class HeadlessCiModelAndOnboardingRegressionTests(unittest.TestCase):
    """End-to-end Model and OnboardingDialog Step 2 tests that run in CI even when PySide6 is absent."""

    def setUp(self) -> None:
        self._td = tempfile.TemporaryDirectory(prefix='nspb-b1-ci-')
        self.addCleanup(self._td.cleanup)
        self.root = Path(self._td.name)

    def _pump(self) -> None:
        if HAS_QT:
            app = QApplication.instance()
            if app is not None:
                app.processEvents()

    def _build_isolated_model(self):
        from nspb_qt import library as lib
        model_mod, using_stub, cleanup_stub = _load_model_with_qt_fallback()
        self.addCleanup(cleanup_stub)
        Model = model_mod.Model
        Dep = model_mod.Dep
        DepState = model_mod.DepState

        app = None
        if HAS_QT and not using_stub:
            app = QApplication.instance() or QApplication([])

        state_dir = self.root / 'state'
        state_dir.mkdir(parents=True, exist_ok=True)
        ini = self.root / 'settings.ini'

        if HAS_QT and not using_stub:
            qsettings_factory = lambda *_a, **_k: QSettings(str(ini), QSettings.IniFormat)
        else:
            qsettings_factory = model_mod.QSettings

        with (
            mock.patch.object(pu, 'find_python', lambda *_a, **_k: (sys.executable, True, '3.12')),
            mock.patch.object(pu, 'find_dotnet', lambda *_a, **_k: ('dotnet', False)),
            mock.patch.object(Model, 'check_deps', lambda self: None),
            mock.patch.object(model_mod, 'QSettings', qsettings_factory),
            mock.patch.object(lib, 'default_state_dir', lambda: state_dir),
        ):
            m = Model()

        if app is not None:
            def _dispose() -> None:
                try:
                    m.deleteLater()
                except RuntimeError:
                    pass
                app.sendPostedEvents(None, QEvent.DeferredDelete)
                app.processEvents()
            self.addCleanup(_dispose)

        m.deps = [Dep('python', 'dep.python', 'dep.python.hint', DepState.OK, sys.executable)]
        m.deps_checked = True
        m.python_path = sys.executable
        m.python_ok = True
        return m, model_mod

    def test_model_cancel_build_kills_descendant_tree_and_resets_running_immediately(self) -> None:
        """Wiring check on `Model.start_build` + `Model.cancel_build`: cancelling kills the grandchild
        holding inherited stdout, unblocks `for line in proc.stdout:`, and resets `m.running` < 2s."""
        m, _ = self._build_isolated_model()

        eng = self.root / 'engine'
        scripts_dir = eng / 'scripts'
        scripts_dir.mkdir(parents=True)
        (eng / 'dm' / 'tools' / 'nx_extract').mkdir(parents=True)
        (eng / 'dm' / 'tools' / 'nx_extract' / 'Program.cs').write_text('// stub\n', encoding='utf-8')
        build_script = scripts_dir / 'build_ipa_from_nsp.py'
        build_script.write_text(
            "import os, subprocess, sys, time\n"
            "# supports '--work-dir'\n"
            "grand = subprocess.Popen([\n"
            "    sys.executable, '-c',\n"
            "    'import os, signal, time\\n'\n"
            "    'signal.signal(signal.SIGTERM, signal.SIG_IGN)\\n'\n"
            "    'print(\"GRANDCHILD_PID=\" + str(os.getpid()), flush=True)\\n'\n"
            "    'time.sleep(30)\\n'\n"
            "])\n"
            "print('[1/3] Extract game files ...', flush=True)\n"
            "time.sleep(30)\n",
            encoding='utf-8',
        )

        nsp = self.root / 'Game [0100000000010000].nsp'
        nsp.write_bytes(b'nsp')
        keys = self.root / 'prod.keys'
        keys.write_text('header_key = ' + '0' * 64 + '\n', encoding='utf-8')

        m.repo_path = str(eng)
        m.base_path = str(nsp)
        m.keys_path = str(keys)
        m.out_dir = str(self.root / 'out')
        m.target = 'ios'
        m.ipa_kind = 'oneGame'

        grand_pid_holder: list[int] = []
        stage_seen = threading.Event()
        finished_results: list[tuple[bool, str]] = []

        def on_log(text: str) -> None:
            for ln in text.splitlines():
                if 'GRANDCHILD_PID=' in ln:
                    try:
                        grand_pid_holder.append(int(ln.split('GRANDCHILD_PID=', 1)[1].strip()))
                    except ValueError:
                        pass
                if '[1/3]' in ln:
                    stage_seen.set()

        m.logAppended.connect(on_log)
        m.finished.connect(lambda ok, note: finished_results.append((ok, note)))

        with mock.patch.object(pu, 'IS_WIN', False):
            m.start_build()
            t_wait = time.monotonic()
            while (not stage_seen.is_set() or not grand_pid_holder) and time.monotonic() - t_wait < 5.0:
                self._pump()
                if not grand_pid_holder and 'GRANDCHILD_PID=' in m.log_tail:
                    on_log(m.log_tail)
                if not stage_seen.is_set() and '[1/3]' in m.log_tail:
                    stage_seen.set()
                time.sleep(0.02)

            self.assertTrue(m.running)
            self.assertTrue(grand_pid_holder, f'Did not capture grandchild PID from log: {m.log_tail!r}')
            grand_pid = grand_pid_holder[0]
            self.assertTrue(_pid_alive(grand_pid))

            t_cancel = time.monotonic()
            m.cancel_build()
            while m.running and time.monotonic() - t_cancel < 2.0:
                self._pump()
                time.sleep(0.02)
            elapsed = time.monotonic() - t_cancel
            self._pump()

            try:
                self.assertFalse(m.running, 'm.running stayed True after cancel_build (worker stuck on stdout)')
                self.assertLess(elapsed, 2.0)
                self.assertTrue(finished_results and not finished_results[-1][0])
                deadline = time.monotonic() + 1.0
                while _pid_alive(grand_pid) and time.monotonic() < deadline:
                    time.sleep(0.02)
                self.assertFalse(_pid_alive(grand_pid), 'Grandchild survived Model.cancel_build')
            finally:
                if _pid_alive(grand_pid):
                    try:
                        os.kill(grand_pid, signal.SIGKILL)
                    except OSError:
                        pass

    def test_model_background_drive_copy_progress_cancel_and_io_error_cleanup(self) -> None:
        """Verify `Model.start_drive_copy` / `cancel_drive_copy` copies asynchronously with progress,
        ignores stale `.part` files in source archive, and removes partial destination files on
        user cancellation or mid-stream I/O error."""
        m, _ = self._build_isolated_model()
        tid = '0100000000010000'
        arch = self.root / 'games' / tid
        (arch / 'aoc').mkdir(parents=True)
        romfs_payload = b'DMROMFS1' + (b'B' * (3 * 1024 * 1024 - 8))  # 3 MiB
        (arch / 'romfs.img').write_bytes(romfs_payload)
        (arch / 'romfs.img.part').write_bytes(b'STALE_SOURCE_PART_MUST_BE_IGNORED')
        (arch / 'aoc' / 'dlc.nca').write_bytes(b'DLC_CONTENT')

        m.archive_path = str(arch)
        m.base_path = str(self.root / f'Game [{tid}].nsp')
        Path(m.base_path).write_bytes(b'x')
        ipa_dummy = self.root / 'NX2Apple.ipa'
        ipa_dummy.write_bytes(b'PK\x03\x04')
        m.library.record_completed_ios(
            ipa_path=str(ipa_dummy),
            archive_path=str(arch),
            base_path=m.base_path,
            output_dir=str(self.root),
            inputs={'base': [m.base_path]},
            repo_path='',
            title_id=tid,
            name='Super Mario Odyssey',
        )
        m.library.select(tid)

        # 1. Normal background completion
        drive_ok = self.root / 'drive_ok'
        drive_ok.mkdir()
        progress_events: list[tuple[int, int]] = []
        finish_events: list[tuple[bool, bool, str]] = []
        m.driveCopyProgress.connect(lambda d, t: progress_events.append((int(d), int(t))))
        m.driveCopyFinished.connect(lambda ok, canc, info: finish_events.append((ok, canc, info)))

        t0 = time.monotonic()
        started = m.start_drive_copy(str(drive_ok))
        self.assertTrue(started)
        self.assertEqual(m.drive_copy_game, 'Super Mario Odyssey')
        self.assertLess(time.monotonic() - t0, 0.2, 'start_drive_copy blocked caller thread')

        deadline = time.monotonic() + 5.0
        while m.drive_copying and time.monotonic() < deadline:
            self._pump()
            time.sleep(0.01)
        self._pump()

        self.assertFalse(m.drive_copying)
        self.assertTrue(progress_events)
        self.assertEqual(progress_events[-1][0], progress_events[-1][1])
        self.assertEqual(finish_events[-1][:2], (True, False))
        self.assertEqual((drive_ok / tid / 'romfs.img').read_bytes(), romfs_payload)
        self.assertEqual((drive_ok / tid / 'aoc' / 'dlc.nca').read_bytes(), b'DLC_CONTENT')
        self.assertFalse((drive_ok / tid / 'romfs.img.part').exists())

        # 2. Mid-copy cancellation deletes `.part` and prunes newly created empty folder
        drive_cancel = self.root / 'drive_cancel'
        drive_cancel.mkdir()
        chunk_seen = threading.Event()
        allow_next = threading.Event()
        real_open = open

        class SlowReader:
            def __init__(self, raw):
                self._raw = raw
                self._n = 0

            def read(self, sz=-1):
                data = self._raw.read(sz)
                self._n += 1
                if self._n == 2:
                    chunk_seen.set()
                    allow_next.wait(timeout=3.0)
                return data

            def __enter__(self):
                self._raw.__enter__()
                return self

            def __exit__(self, *exc):
                return self._raw.__exit__(*exc)

        def slow_open(file, mode='r', *args, **kwargs):
            fh = real_open(file, mode, *args, **kwargs)
            if 'rb' in mode and str(file).endswith('romfs.img'):
                return SlowReader(fh)
            return fh

        finish_events.clear()
        with mock.patch('builtins.open', side_effect=slow_open):
            self.assertTrue(m.start_drive_copy(str(drive_cancel)))
            t_wait = time.monotonic()
            while not chunk_seen.is_set() and time.monotonic() - t_wait < 3.0:
                self._pump()
                time.sleep(0.01)
            self.assertTrue((drive_cancel / tid / 'romfs.img.part').exists())
            m.cancel_drive_copy()
            self.assertTrue(m.drive_copy_cancelling)
            allow_next.set()

            deadline = time.monotonic() + 5.0
            while m.drive_copying and time.monotonic() < deadline:
                self._pump()
                time.sleep(0.01)
            self._pump()

        self.assertEqual(finish_events[-1][:2], (False, True))
        self.assertFalse((drive_cancel / tid / 'romfs.img').exists())
        self.assertEqual(list(drive_cancel.rglob('*.part')), [])
        self.assertFalse((drive_cancel / tid).exists())

        # 3. Mid-copy ENOSPC error deletes `.part` and keeps previous valid destination file intact
        drive_err = self.root / 'drive_err'
        (drive_err / tid).mkdir(parents=True)
        prev_romfs = drive_err / tid / 'romfs.img'
        prev_romfs.write_bytes(b'OLD_INTACT_ROMFS')

        class EnospcWriter:
            def __init__(self, raw):
                self._raw = raw
                self._w = 0

            def write(self, b):
                self._w += 1
                if self._w >= 2:
                    raise OSError(errno.ENOSPC, 'No space left on external drive')
                return self._raw.write(b)

            def flush(self):
                return self._raw.flush()

            def __enter__(self):
                self._raw.__enter__()
                return self

            def __exit__(self, *exc):
                return self._raw.__exit__(*exc)

        def failing_open(file, mode='r', *args, **kwargs):
            fh = real_open(file, mode, *args, **kwargs)
            if 'wb' in mode and str(file).endswith('romfs.img.part'):
                return EnospcWriter(fh)
            return fh

        finish_events.clear()
        with mock.patch('builtins.open', side_effect=failing_open):
            self.assertTrue(m.start_drive_copy(str(drive_err)))
            deadline = time.monotonic() + 5.0
            while m.drive_copying and time.monotonic() < deadline:
                self._pump()
                time.sleep(0.01)
            self._pump()

        self.assertEqual(finish_events[-1][:2], (False, False))
        self.assertIn('No space left on external drive', finish_events[-1][2])
        self.assertEqual(list(drive_err.rglob('*.part')), [])
        self.assertEqual(prev_romfs.read_bytes(), b'OLD_INTACT_ROMFS')

    def test_onboarding_step2_ast_renders_all_seven_windows_dependencies_without_truncation(self) -> None:
        """AST-backed execution of `OnboardingDialog._render_step` (runs even without PySide6 in CI)
        must render all 7 Windows dependency rows including `metal` (#6) and `zstd` (#7)."""
        from nspb_qt import i18n, l10n, style

        sheets_src = (QT_DIR / 'nspb_qt' / 'sheets.py').read_text(encoding='utf-8')
        sheets_tree = ast.parse(sheets_src)
        ob_cls = next(
            n for n in ast.walk(sheets_tree)
            if isinstance(n, ast.ClassDef) and n.name == 'OnboardingDialog'
        )
        fn_map = {n.name: n for n in ob_cls.body if isinstance(n, ast.FunctionDef)}

        class FakeWidget:
            def __init__(self, text: str = '') -> None:
                self.text = str(text)
                self.visible = True
                self.enabled = True
                self.style_sheet = ''
                self.obj_name = ''
                self.value = 0
                self.clicked_cbs: list = []

            def setText(self, s: str) -> None:
                self.text = str(s)

            def setVisible(self, v: bool) -> None:
                self.visible = bool(v)

            def show(self) -> None:
                self.visible = True

            def hide(self) -> None:
                self.visible = False

            def setEnabled(self, e: bool) -> None:
                self.enabled = bool(e)

            def setStyleSheet(self, s: str) -> None:
                self.style_sheet = s

            def setObjectName(self, s: str) -> None:
                self.obj_name = s

            def setWordWrap(self, _w: bool) -> None:
                pass

            def setContentsMargins(self, *_a) -> None:
                pass

            def setRange(self, *_a) -> None:
                pass

            def setValue(self, v: int) -> None:
                self.value = int(v)

            def setTextVisible(self, _v: bool) -> None:
                pass

            def setParent(self, _p) -> None:
                pass

            def deleteLater(self) -> None:
                pass

            @property
            def clicked(self):
                cbs = self.clicked_cbs

                class _Sig:
                    @staticmethod
                    def connect(cb) -> None:
                        cbs.append(cb)
                return _Sig()

        class FakeLayout:
            def __init__(self, _parent=None) -> None:
                self.items: list = []

            def setContentsMargins(self, *_a) -> None:
                pass

            def setSpacing(self, *_a) -> None:
                pass

            def addWidget(self, w, *_a) -> None:
                self.items.append(w)

            def addLayout(self, l, *_a) -> None:
                self.items.append(l)

            def addStretch(self, *_a) -> None:
                self.items.append(None)

            def count(self) -> int:
                return len(self.items)

            def takeAt(self, idx: int):
                w = self.items.pop(idx)

                class _Item:
                    @staticmethod
                    def widget():
                        return w if isinstance(w, FakeWidget) else None
                return _Item()

        class FakeCardGroup(FakeWidget):
            def __init__(self, footer: str = '') -> None:
                super().__init__(footer)
                self.rows: list = []
                self.dividers = 0

            def add_row(self, r) -> None:
                self.rows.append(r)

            def add_divider(self) -> None:
                self.dividers += 1

        ns: dict = {
            'Path': Path,
            'shutil': shutil,
            'style': style,
            'QWidget': FakeWidget,
            'QLabel': FakeWidget,
            'QPushButton': FakeWidget,
            'QProgressBar': FakeWidget,
            'QHBoxLayout': FakeLayout,
            'QVBoxLayout': FakeLayout,
            'CardGroup': FakeCardGroup,
            'StatusDot': FakeWidget,
        }
        for name in ('_clear_body', '_step1_row_meta', '_render_step'):
            fn = fn_map[name]
            for n in ast.walk(fn):
                ast.fix_missing_locations(n)
            exec(
                compile(ast.fix_missing_locations(ast.Module(body=[fn], type_ignores=[])), '<sheets>', 'exec'),
                ns,
            )

        class FakeDep:
            def __init__(self, dep_id: str, title_key: str, ok: bool = False, install=None, required: bool = True):
                self.id = dep_id
                self.title_key = title_key
                self.ok = ok
                self.install = list(install or [])
                self.required = required
                self.installing = False
                self.install_stage = ''
                self.install_detail = ''
                self.install_pct = None
                self.queue_index = 0
                self.last_error = ''
                self.fix_hint = ''

        class FakeModel:
            def __init__(self) -> None:
                self.lang = i18n.Lang('en')
                self.deps = [
                    FakeDep('python', 'dep.python', True, ['__win__:python']),
                    FakeDep('dotnet', 'dep.dotnet', True, ['__win__:dotnet']),
                    FakeDep('llvm', 'dep.llvm', True, ['__win__:llvm']),
                    FakeDep('lld', 'dep.lld', True, []),
                    FakeDep('ios_sdk', 'dep.iossdk', True, ['__win__:ios_sdk']),
                    FakeDep('metal', 'dep.metal', False, [], required=True),
                    FakeDep('zstd', 'dep.zstd.win', False, ['__win__:zstd'], required=True),
                ]
                self._install_all_running = False
                self.install_all_step = 0
                self.install_all_total = 0
                self.install_all_pct = 0

            def t(self, key: str, *args) -> str:
                return l10n.t(key, self.lang, *args)

            def install_all_missing(self) -> None:
                self._install_all_running = True

        class FakeOnboarding:
            _clear_body = ns['_clear_body']
            _step1_row_meta = ns['_step1_row_meta']
            _render_step = ns['_render_step']
            _fit_dialog_height = lambda self: None

            def __init__(self, model) -> None:
                self.m = model
                self.step = 1
                self._step1_sig = None
                self._step1_widgets: dict = {}
                self.step_badge = FakeWidget()
                self.task_pill = FakeWidget()
                self.head_title = FakeWidget()
                self.head_note = FakeWidget()
                self.overall_pct_lbl = FakeWidget()
                self.body_layout = FakeLayout()
                self.later_btn = FakeWidget('Later')
                self.back_btn = FakeWidget('Back')
                self.next_btn = FakeWidget('Continue')

        m = FakeModel()
        dlg = FakeOnboarding(m)
        dlg._render_step()

        rendered_ids = list(dlg._step1_widgets['rows'].keys())
        self.assertEqual(
            rendered_ids,
            ['python', 'dotnet', 'llvm', 'lld', 'ios_sdk', 'metal', 'zstd'],
        )
        self.assertEqual(dlg._step1_widgets['rows']['metal']['title'].text, m.t('dep.metal'))
        self.assertEqual(dlg._step1_widgets['rows']['zstd']['title'].text, m.t('dep.zstd.win'))
        self.assertIsNotNone(dlg._step1_widgets['ibtn'], 'Install all button must appear for missing zstd')


if HAS_QT:
    class QtWidgetEndToEndRegressionTests(unittest.TestCase):
        @classmethod
        def setUpClass(cls) -> None:
            cls.app = QApplication.instance() or QApplication([])
            from nspb_qt import style
            fam = style.load_font()
            if fam:
                f = cls.app.font()
                f.setFamily(fam)
                cls.app.setFont(f)

        def setUp(self) -> None:
            self._td = tempfile.TemporaryDirectory(prefix='nspb-b1-qt-')
            self.addCleanup(self._td.cleanup)
            self.root = Path(self._td.name)

        def _cleanup_qobjects(self, *objs) -> None:
            for obj in objs:
                if hasattr(obj, 'close'):
                    try:
                        obj.close()
                    except RuntimeError:
                        pass
                try:
                    obj.deleteLater()
                except RuntimeError:
                    pass
            self.app.sendPostedEvents(None, QEvent.DeferredDelete)
            self.app.processEvents()

        def _make_model(self):
            from nspb_qt import library as lib
            from nspb_qt.model import Dep, DepState, Model

            ini = self.root / 'settings.ini'
            state_dir = self.root / 'state'
            state_dir.mkdir(parents=True, exist_ok=True)
            with (
                mock.patch.object(pu, 'find_python', lambda *_a, **_k: (sys.executable, True, '3.12')),
                mock.patch.object(pu, 'find_dotnet', lambda *_a, **_k: ('dotnet', False)),
                mock.patch.object(Model, 'check_deps', lambda self: None),
                mock.patch('nspb_qt.model.QSettings', lambda *_a, **_k: QSettings(str(ini), QSettings.IniFormat)),
                mock.patch.object(lib, 'default_state_dir', lambda: state_dir),
            ):
                m = Model()
            m.deps = [Dep('python', 'dep.python', 'dep.python.hint', DepState.OK, sys.executable)]
            m.deps_checked = True
            m.python_path = sys.executable
            m.python_ok = True
            return m

        def test_mainwindow_drive_copy_ui_progress_cancel_64bit_overflow_and_game_switch_isolation(self) -> None:
            """Verify real `MainWindow` Step 3 progress bar, danger Cancel button, 64-bit byte counts,
            and per-title status attribution if the user switches games during a background copy."""
            from nspb_qt.ui import MainWindow

            m = self._make_model()
            tid1 = '0100000000010000'
            tid2 = '01007EF00011E000'
            arch1 = self.root / 'games' / tid1
            arch1.mkdir(parents=True)
            romfs_payload = b'DMROMFS1' + (b'A' * (4 * 1024 * 1024 - 8))
            (arch1 / 'romfs.img').write_bytes(romfs_payload)

            m.archive_path = str(arch1)
            m.base_path = str(self.root / f'Super Mario Odyssey [{tid1}].nsp')
            Path(m.base_path).write_bytes(b'x')
            m.ipa_kind = 'shared'

            with mock.patch.object(MainWindow, '_maybe_show_onboarding', lambda self: None, create=True):
                w = MainWindow(m)
            w._init_timer.stop()
            self.addCleanup(self._cleanup_qobjects, m, w)

            # 1. 64-bit byte counts (> 2 GiB signed 32-bit int max) must not overflow PySide6 Signal
            m.drive_copying = True
            m.drive_copy_game = 'Super Mario Odyssey'
            m.driveCopyProgress.emit(6 * 1024**3, 15 * 1024**3)
            self.app.processEvents()
            self.assertEqual(w.drive_progress_bar.value(), 40)
            self.assertIn('40%', w.step3_sub.text())
            self.assertFalse(w.drive_progress_bar.isHidden())
            m.drive_copying = False
            w._refresh_install_card()

            # 2. UI button cancellation mid-stream removes `.part` and resets UI state cleanly
            drive_cancel = self.root / 'drive_cancel'
            drive_cancel.mkdir()
            w._drive_folder = str(drive_cancel)
            w._refresh_install_card()

            chunk_written = threading.Event()
            allow_continue = threading.Event()
            real_open = open

            class SlowReader:
                def __init__(self, raw):
                    self._raw = raw
                    self._chunks = 0

                def read(self, n=-1):
                    data = self._raw.read(n)
                    self._chunks += 1
                    if self._chunks == 2:
                        chunk_written.set()
                        allow_continue.wait(timeout=3.0)
                    return data

                def __enter__(self):
                    self._raw.__enter__()
                    return self

                def __exit__(self, *exc):
                    return self._raw.__exit__(*exc)

            def slow_open(file, mode='r', *args, **kwargs):
                fh = real_open(file, mode, *args, **kwargs)
                if 'rb' in mode and str(file).endswith('romfs.img'):
                    return SlowReader(fh)
                return fh

            with mock.patch('builtins.open', side_effect=slow_open):
                w._copy_archive_to_drive()
                t_wait = time.monotonic()
                while not chunk_written.is_set() and time.monotonic() - t_wait < 3.0:
                    self.app.processEvents()
                    time.sleep(0.01)
                self.app.processEvents()

                self.assertTrue(m.drive_copying)
                self.assertEqual(w.drive_copy_btn.objectName(), 'danger')
                self.assertEqual(w.drive_copy_btn.text(), m.t('transfer.cancel'))
                self.assertFalse(w.drive_choose_btn.isEnabled())
                self.assertTrue((drive_cancel / tid1 / 'romfs.img.part').exists())

                w.drive_copy_btn.click()
                allow_continue.set()

                deadline = time.monotonic() + 5.0
                while m.drive_copying and time.monotonic() < deadline:
                    self.app.processEvents()
                    time.sleep(0.01)
                self.app.processEvents()

            self.assertFalse(m.drive_copying)
            self.assertFalse((drive_cancel / tid1 / 'romfs.img').exists())
            self.assertEqual(list(drive_cancel.rglob('*.part')), [])
            self.assertEqual(w.step3_sub.text(), m.t('msg.stopped'))

            # 3. Switching active game during copy binds completion status to the copied title ID (`tid1`)
            arch2 = self.root / 'games' / tid2
            arch2.mkdir(parents=True)
            (arch2 / 'romfs.img').write_bytes(b'DMROMFS1_G2')
            drive_switch = self.root / 'drive_switch'
            drive_switch.mkdir()
            w._drive_folder = str(drive_switch)
            m.archive_path = str(arch1)
            m.base_path = str(self.root / f'Super Mario Odyssey [{tid1}].nsp')
            Path(m.base_path).write_bytes(b'x')
            w._refresh_install_card()

            w._copy_archive_to_drive()
            # Switch active game to game 2 while game 1 copy completes
            m.archive_path = str(arch2)
            m.base_path = str(self.root / f'Breath of the Wild [{tid2}].nsp')
            Path(m.base_path).write_bytes(b'x')
            deadline = time.monotonic() + 5.0
            while m.drive_copying and time.monotonic() < deadline:
                self.app.processEvents()
                time.sleep(0.01)
            self.app.processEvents()

            self.assertEqual(w._drive_status[0], tid1)
            self.assertEqual(w.step3_sub.text(), m.t('shell.copyExternalNote'))
            # Switching back to game 1 shows its completed status
            m.archive_path = str(arch1)
            m.base_path = str(self.root / f'Super Mario Odyssey [{tid1}].nsp')
            w._refresh_install_card()
            self.assertIn(str(drive_switch / tid1), w.step3_sub.text())

        def test_real_onboarding_dialog_step2_displays_all_seven_windows_dependencies(self) -> None:
            """Verify real PySide6 `OnboardingDialog` Step 2 renders all 7 Windows dependencies."""
            from nspb_qt.model import Dep, DepState
            from nspb_qt.sheets import OnboardingDialog

            m = self._make_model()
            m.deps = [
                Dep('python', 'dep.python', 'dep.python.hint', DepState.OK, 'ok'),
                Dep('dotnet', 'dep.dotnet', 'dep.dotnet.hint', DepState.OK, '10.0.403'),
                Dep('llvm', 'dep.llvm', 'dep.llvm.hint', DepState.OK, 'ok'),
                Dep('lld', 'dep.lld', 'dep.lld.hint', DepState.OK, 'ok'),
                Dep('ios_sdk', 'dep.iossdk', 'dep.iossdk.hint', DepState.OK, 'ok'),
                Dep('metal', 'dep.metal', 'dep.metal.hint.win', DepState.MISSING, '', pick_key='metal_dir', required=True),
                Dep('zstd', 'dep.zstd.win', 'dep.zstd.hint.win', DepState.MISSING, '', install=['__win__:zstd'], required=True),
            ]
            dlg = OnboardingDialog(m)
            self.addCleanup(self._cleanup_qobjects, m, dlg)
            dlg.step = 1
            dlg._render_step()
            self.app.processEvents()

            rendered_ids = list(dlg._step1_widgets['rows'].keys())
            self.assertEqual(
                rendered_ids,
                ['python', 'dotnet', 'llvm', 'lld', 'ios_sdk', 'metal', 'zstd'],
            )
            self.assertEqual(dlg._step1_widgets['rows']['metal']['title'].text(), m.t('dep.metal'))
            self.assertEqual(dlg._step1_widgets['rows']['zstd']['title'].text(), m.t('dep.zstd.win'))


if __name__ == '__main__':
    unittest.main()
