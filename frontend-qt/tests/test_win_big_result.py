"""A pool worker's result that is too large for a Windows pipe goes through a file (#858).

`nspb_qt/win/big_result.py` is plain Python, so its tests run on every platform with a real
`ProcessPoolExecutor` and a small limit. `ShimRoutesSubmitTest` runs the generated
`sitecustomize.py` with its platform guard switched on (as `test_win_pool_map.py` does) so the
process-boundary shim and cleanup paths execute on macOS, Linux and Windows alike without skips.

    python3 -m unittest discover -s frontend-qt/tests -p "test_win_big_result.py" -v
"""
from __future__ import annotations

import concurrent.futures as cf
import importlib
import multiprocessing
import os
import pickle
import subprocess
import sys
import tempfile
import time
import types
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
QT = HERE.parent
sys.path.insert(0, str(QT))

from nspb_qt.win import big_result, driver, shim  # noqa: E402


def spools(folder: str) -> list[str]:
    return sorted(n for n in os.listdir(folder) if n.startswith('nspb-result-'))


class _CountedPayload:
    """Counts how many times the worker pickles the returned object graph."""

    def __init__(self, marker_dir: str, value: str) -> None:
        self.marker_dir = marker_dir
        self.value = value

    def __reduce_ex__(self, protocol):
        fd, p = tempfile.mkstemp(prefix='reduce-hit-', dir=self.marker_dir)
        os.close(fd)
        return (_rebuild_counted_payload, (self.marker_dir, self.value))


def _rebuild_counted_payload(marker_dir: str, value: str) -> _CountedPayload:
    obj = _CountedPayload.__new__(_CountedPayload)
    obj.marker_dir = marker_dir
    obj.value = value
    return obj


def _make_counted_payload(marker_dir: str, value: str) -> _CountedPayload:
    return _CountedPayload(marker_dir, value)


class CallTest(unittest.TestCase):
    """The worker's side, run in this process."""

    def test_a_small_result_is_returned_pre_pickled(self) -> None:
        got = big_result.call(1 << 20, bytes, (100,), {})
        self.assertIsInstance(got, big_result.Inline)
        self.assertEqual(pickle.loads(got.blob), bytes(100))

    def test_a_large_result_is_written_to_a_file(self) -> None:
        with tempfile.TemporaryDirectory() as td, mock.patch.dict(os.environ, {'NSPB_SPOOL_DIR': ''}), \
                mock.patch.object(tempfile, 'tempdir', td):
            got = big_result.call(1000, bytes, (5000,), {})
            self.assertIsInstance(got, big_result.Spooled)
            self.assertEqual(spools(td), [os.path.basename(got.path)])

    def test_a_large_result_honors_nspb_spool_dir(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            spool = os.path.join(td, 'scoped')
            with mock.patch.dict(os.environ, {'NSPB_SPOOL_DIR': spool}):
                got = big_result.call(1000, bytes, (5000,), {})
            self.assertEqual(os.path.dirname(got.path), spool)
            self.assertEqual(spools(spool), [os.path.basename(got.path)])

    def test_a_failed_write_unlinks_the_partial_spool_file(self) -> None:
        with tempfile.TemporaryDirectory() as td, mock.patch.dict(os.environ, {'NSPB_SPOOL_DIR': td}):
            real_fdopen = os.fdopen

            def failing_fdopen(fd, mode='r', *a, **k):
                f = real_fdopen(fd, mode, *a, **k)

                class _BrokenWriter:
                    def __enter__(self):
                        return self

                    def __exit__(self, *exc):
                        f.close()
                        return False

                    def write(self, _b):
                        raise OSError(28, 'No space left on device')

                return _BrokenWriter()

            with mock.patch.object(os, 'fdopen', side_effect=failing_fdopen):
                with self.assertRaises(OSError):
                    big_result.call(1000, bytes, (5000,), {})
            self.assertEqual(spools(td), [])

    def test_keyword_arguments_reach_the_job(self) -> None:
        got = big_result.call(1 << 20, int, ('ff',), {'base': 16})
        self.assertIsInstance(got, big_result.Inline)
        self.assertEqual(pickle.loads(got.blob), 255)

    def test_the_limit_is_far_below_a_pipe_message(self) -> None:
        self.assertLess(big_result.LIMIT, 1 << 32)


class PoolTest(unittest.TestCase):
    """Both sides through a real pool. Its workers are started the way Windows starts them."""

    def setUp(self) -> None:
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.td = folder.name
        # the workers take their temporary folder from the environment they start with
        env = mock.patch.dict(os.environ, {
            'TMPDIR': self.td, 'TEMP': self.td, 'TMP': self.td, 'NSPB_SPOOL_DIR': self.td,
        })
        env.start()
        self.addCleanup(env.stop)
        limit = mock.patch.object(big_result, 'LIMIT', 1000)
        limit.start()
        self.addCleanup(limit.stop)
        self.pool = cf.ProcessPoolExecutor(2, mp_context=multiprocessing.get_context('spawn'))
        self.addCleanup(self.pool.shutdown)

    def submit(self, fn, *args, **kwargs):
        return big_result.submit(self.pool.submit, fn, args, kwargs)

    def test_a_large_result_crosses_as_a_file_and_the_file_is_removed(self) -> None:
        future = self.submit(bytes, 5000)
        cf.wait([future])
        self.assertEqual(len(spools(self.td)), 1, 'the result did not go through a file')
        self.assertEqual(future.result(), bytes(5000))
        self.assertEqual(spools(self.td), [])

    def test_the_result_can_be_read_after_pool_shutdown(self) -> None:
        with cf.ProcessPoolExecutor(1, mp_context=multiprocessing.get_context('spawn')) as pool:
            future = big_result.submit(pool.submit, bytes, (5000,), {})
        self.assertEqual(len(spools(self.td)), 1)
        self.assertEqual(future.result(), bytes(5000))
        self.assertEqual(spools(self.td), [])

    def test_the_result_can_be_asked_for_again(self) -> None:
        big_fut = self.submit(bytes, 5000)
        self.assertIs(big_fut.result(), big_fut.result())
        small_fut = self.submit(dict, a=[1, 2, 3])
        self.assertIs(small_fut.result(), small_fut.result())

    def test_a_small_result_takes_the_pipe_and_pickles_only_once(self) -> None:
        markers = os.path.join(self.td, 'markers')
        os.makedirs(markers, exist_ok=True)
        future = self.submit(_make_counted_payload, markers, 'ok')
        got = future.result()
        self.assertEqual(got.value, 'ok')
        self.assertEqual(spools(self.td), [])
        hits = [n for n in os.listdir(markers) if n.startswith('reduce-hit-')]
        self.assertEqual(len(hits), 1, f'expected 1 object-graph pickle, got {len(hits)}')

    def test_an_unconsumed_spooled_future_cleans_up_when_dropped(self) -> None:
        def submit_and_drop() -> None:
            fut = self.submit(bytes, 5000)
            cf.wait([fut])
            self.assertEqual(len(spools(self.td)), 1)

        submit_and_drop()
        # No gc.collect(): breaking the future->result reference cycle lets CPython refcounting
        # finalize the Spooled wrapper deterministically as soon as `fut` goes out of scope.
        self.assertEqual(spools(self.td), [])

    def test_corrupt_spool_file_is_still_unlinked_and_repeats_its_error(self) -> None:
        future = self.submit(bytes, 5000)
        cf.wait([future])
        names = spools(self.td)
        self.assertEqual(len(names), 1)
        Path(self.td, names[0]).write_bytes(b'corrupted')
        with self.assertRaises(pickle.UnpicklingError):
            future.result()
        self.assertEqual(spools(self.td), [])
        with self.assertRaises(pickle.UnpicklingError):
            future.result()

    def test_results_keep_their_jobs(self) -> None:
        sizes = [5000, 10, 7000, 0, 6000]
        futures = [self.submit(bytes, n) for n in sizes]
        self.assertEqual([len(f.result()) for f in futures], sizes)
        self.assertEqual(spools(self.td), [])

    def test_a_failing_job_raises_its_own_error(self) -> None:
        with self.assertRaises(ZeroDivisionError):
            self.submit(divmod, 1, 0).result()


class ShimRoutesSubmitTest(unittest.TestCase):
    def test_the_generated_shim_names_the_module(self) -> None:
        self.assertIn('_big_result.submit(super().submit, fn, args, kwargs)', shim._SITECUSTOMIZE_SRC)

    def test_a_pool_under_the_shim_routes_and_cleans_unconsumed_spools_on_exit(self) -> None:
        # Runs on every OS by switching on the shim's platform guard (no @skipUnless).
        script = (
            "import concurrent.futures as cf, os\n"
            "import big_result\n"
            "big_result.LIMIT = 1000\n"
            "def spools(): return [n for n in os.listdir(os.environ['NSPB_SPOOL_DIR']) if n.startswith('nspb-result-')]\n"
            "if __name__ == '__main__':\n"
            "    with cf.ProcessPoolExecutor(2) as ex:\n"
            "        f = ex.submit(bytes, 5000)\n"
            "        leaked = ex.submit(bytes, 6000)\n"
            "        cf.wait([f, leaked])\n"
            "        assert len(spools()) == 2, spools()\n"
            "        assert f.result() == bytes(5000)\n"
            "        assert len(spools()) == 1, spools()\n"
            "        assert list(ex.map(bytes, [6000, 10])) == [bytes(6000), bytes(10)]\n"
            "        # `leaked` stays referenced until interpreter exit so atexit cleanup is exercised too\n"
        )
        with tempfile.TemporaryDirectory() as td, tempfile.TemporaryDirectory() as spool:
            folder = Path(td) / 'shim'
            folder.mkdir()
            active = shim._SITECUSTOMIZE_SRC.replace("if os.name == 'nt'", "if True", 1)
            (folder / 'sitecustomize.py').write_text(active, encoding='utf-8')
            tool = Path(td) / 'pool_tool.py'
            tool.write_text(script, encoding='utf-8')
            env = {
                **os.environ,
                'PYTHONPATH': str(folder),
                'NSPB_WIN_DIR': str(QT / 'nspb_qt' / 'win'),
                'NSPB_SHIM_OFF': '',
                'NSPB_SPOOL_DIR': spool,
            }
            r = subprocess.run([sys.executable, str(tool)], env=env, capture_output=True, text=True, timeout=120)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            self.assertEqual(spools(spool), [])


class OuterLifecycleCleanupTest(unittest.TestCase):
    """Outer build entry points (`driver.main` and `model.Model.start_build`) remove `NSPB_SPOOL_DIR`."""

    def test_driver_main_creates_and_removes_its_owned_spool_dir_on_failure(self) -> None:
        captured: list[str] = []

        class _FakeMod:
            @staticmethod
            def cli(_argv):
                sdir = os.environ.get('NSPB_SPOOL_DIR', '')
                captured.append(sdir)
                Path(sdir, 'nspb-result-orphan.pickle').write_bytes(b'orphan')
                raise RuntimeError('boom')

        with tempfile.TemporaryDirectory() as td:
            repo = Path(td) / 'repo'
            (repo / 'scripts').mkdir(parents=True)
            (repo / 'scripts' / 'build_ipa_from_nsp.py').write_text('# stub\n', encoding='utf-8')
            saved_env = dict(os.environ)
            try:
                os.environ.pop('NSPB_SPOOL_DIR', None)
                os.environ['NSPB_ALLOW_NON_WINDOWS'] = '1'
                os.environ['NSPB_REPO'] = str(repo)
                with mock.patch.object(shim, 'build_env', return_value=dict(os.environ)), \
                        mock.patch.object(driver, 'check_cli'), \
                        mock.patch.object(driver, 'load_upstream', return_value=_FakeMod), \
                        mock.patch.object(driver, 'patch'):
                    with self.assertRaisesRegex(RuntimeError, 'boom'):
                        driver.main(['dummy.nsp'])
            finally:
                os.environ.clear()
                os.environ.update(saved_env)

            self.assertEqual(len(captured), 1)
            self.assertTrue(captured[0])
            self.assertFalse(os.path.exists(captured[0]), f'spool dir leaked: {captured[0]}')

    def _load_model_module(self):
        try:
            from nspb_qt import model
            return model
        except ModuleNotFoundError:
            # Headless fallback when PySide6 is absent, so CI never skips this outer-caller test.
            qtcore = types.ModuleType('PySide6.QtCore')

            class _Sig:
                def __init__(self, *_a, **_k):
                    self._subs = []

                def __get__(self, inst, owner):
                    if inst is None:
                        return self
                    slots = inst.__dict__.setdefault('_sig_slots', {})
                    if self not in slots:
                        slots[self] = _BoundSig()
                    return slots[self]

            class _BoundSig:
                def __init__(self):
                    self._cbs = []

                def connect(self, cb):
                    self._cbs.append(cb)

                def emit(self, *a):
                    for cb in list(self._cbs):
                        cb(*a)

            class _QSettings:
                def __init__(self, *_a, **_k):
                    self._d = {}

                def value(self, k, default=None, **_kw):
                    return self._d.get(k, default)

                def setValue(self, k, v):
                    self._d[k] = v

                def remove(self, k):
                    self._d.pop(k, None)

                def sync(self):
                    pass

            class _QObject:
                def __init__(self, *_a, **_k):
                    pass

                def thread(self):
                    return _main_thread

            _main_thread = object()
            qtcore.QObject = _QObject
            qtcore.QThread = types.SimpleNamespace(currentThread=lambda: _main_thread)
            qtcore.QSettings = _QSettings
            qtcore.Signal = _Sig
            qtcore.Slot = lambda *_a, **_k: (lambda fn: fn)
            qtcore.Qt = types.SimpleNamespace(
                QueuedConnection=0,
                ConnectionType=types.SimpleNamespace(QueuedConnection=0),
            )
            qtcore.QMetaObject = types.SimpleNamespace(invokeMethod=lambda *_a, **_k: None)
            qtcore.Q_ARG = lambda _t, v: v
            pkg = types.ModuleType('PySide6')
            pkg.QtCore = qtcore
            with mock.patch.dict(sys.modules, {'PySide6': pkg, 'PySide6.QtCore': qtcore}):
                return importlib.import_module('nspb_qt.model')

    def test_model_build_removes_spool_dir_after_cancelled_process_tree(self) -> None:
        model_mod = self._load_model_module()
        with tempfile.TemporaryDirectory() as td:
            marker = Path(td) / 'spool_path.txt'
            child_script = Path(td) / 'hang_worker.py'
            child_script.write_text(
                "import os, pathlib, time\n"
                "sdir = os.environ['NSPB_SPOOL_DIR']\n"
                f"pathlib.Path({str(marker)!r}).write_text(sdir, encoding='utf-8')\n"
                "pathlib.Path(sdir, 'nspb-result-killed.pickle').write_bytes(b'x' * 2048)\n"
                "print('ready', flush=True)\n"
                "time.sleep(30)\n",
                encoding='utf-8',
            )
            nsp = Path(td) / 'game [0100000000010000][v0].nsp'
            nsp.write_bytes(b'PFS0' + b'\0' * 64)
            keys = Path(td) / 'prod.keys'
            keys.write_text('header_key = 00\n', encoding='utf-8')
            repo = Path(td) / 'repo'
            (repo / 'engine' / 'scripts').mkdir(parents=True)
            (repo / 'engine' / 'scripts' / 'build_ipa_from_nsp.py').write_text('# stub\n', encoding='utf-8')
            out_dir = Path(td) / 'out'
            out_dir.mkdir()

            m = model_mod.Model()
            m.repo_path = str(repo)
            m.python_path = sys.executable
            m.base_path = str(nsp)
            m.keys_path = str(keys)
            m.out_dir = str(out_dir)
            m.target = 'ios'
            m.ipa_kind = 'oneGame'

            real_popen = subprocess.Popen

            def redirect_popen(_cmd, *a, **kw):
                return real_popen([sys.executable, str(child_script)], *a, **kw)

            with mock.patch.object(model_mod.pu, 'IS_WIN', True), \
                    mock.patch.object(model_mod.pu, 'no_window_kwargs', return_value={}), \
                    mock.patch.object(model_mod.pu, 'process_group_kwargs', return_value={}), \
                    mock.patch.object(model_mod.pu, 'kill_process_tree', side_effect=lambda p: p.kill()), \
                    mock.patch.object(model_mod.Model, 'repo_ok', new_callable=mock.PropertyMock, return_value=True), \
                    mock.patch.object(m, 'prebuild_block_reason', return_value=''), \
                    mock.patch.object(model_mod.engine, 'needs_sync_before_build', return_value=False), \
                    mock.patch.object(shim, 'build_env', side_effect=lambda env, python_exe=None: dict(env)), \
                    mock.patch.object(shim, 'clean_pkg_root', return_value=Path(td)), \
                    mock.patch.object(shim, 'verify_shim', return_value=(True, 'ok')), \
                    mock.patch.object(model_mod.subprocess, 'Popen', side_effect=redirect_popen):
                m.start_build()
                deadline = time.monotonic() + 10.0
                while not marker.is_file() and time.monotonic() < deadline:
                    time.sleep(0.05)
                self.assertTrue(marker.is_file(), 'child process did not write spool marker')
                spool_dir = marker.read_text(encoding='utf-8').strip()
                self.assertTrue(os.path.isfile(os.path.join(spool_dir, 'nspb-result-killed.pickle')))
                m.cancel_build()
                assert m._thread is not None
                m._thread.join(timeout=10.0)
                self.assertFalse(m._thread.is_alive())

            self.assertTrue(spool_dir)
            self.assertFalse(os.path.exists(spool_dir), f'cancelled build leaked spool dir: {spool_dir}')


if __name__ == '__main__':
    unittest.main()
