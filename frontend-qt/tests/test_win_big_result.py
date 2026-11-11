"""A pool worker's result that is too large for a Windows pipe goes through a file (#858).

`nspb_qt/win/big_result.py` is plain Python, so its tests run on every platform with a real
`ProcessPoolExecutor` and a small limit. The limit itself (a pipe message of 4 GiB) exists only
on Windows and takes many gigabytes of memory to reach, so no test sends a message that large;
`ShimRoutesSubmitTest` checks on Windows that the pool of a build takes this path.

    python3 -m unittest discover -s frontend-qt/tests -p "test_win_big_result.py" -v
"""
from __future__ import annotations

import concurrent.futures as cf
import multiprocessing
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
QT = HERE.parent
sys.path.insert(0, str(QT))

from nspb_qt.win import big_result, shim  # noqa: E402


def spools(folder: str) -> list[str]:
    return sorted(n for n in os.listdir(folder) if n.startswith('nspb-result-'))


class CallTest(unittest.TestCase):
    """The worker's side, run in this process."""

    def test_a_small_result_is_returned_as_it_is(self) -> None:
        self.assertEqual(big_result.call(1 << 20, bytes, (100,), {}), bytes(100))

    def test_a_large_result_is_written_to_a_file(self) -> None:
        with tempfile.TemporaryDirectory() as td, mock.patch.object(tempfile, 'tempdir', td):
            got = big_result.call(1000, bytes, (5000,), {})
            self.assertIsInstance(got, big_result.Spooled)
            self.assertEqual(spools(td), [os.path.basename(got.path)])

    def test_keyword_arguments_reach_the_job(self) -> None:
        self.assertEqual(big_result.call(1 << 20, int, ('ff',), {'base': 16}), 255)

    def test_the_limit_is_far_below_a_pipe_message(self) -> None:
        self.assertLess(big_result.LIMIT, 1 << 32)


class PoolTest(unittest.TestCase):
    """Both sides through a real pool. Its workers are started the way Windows starts them."""

    def setUp(self) -> None:
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.td = folder.name
        # the workers take their temporary folder from the environment they start with
        env = mock.patch.dict(os.environ, {'TMPDIR': self.td, 'TEMP': self.td, 'TMP': self.td})
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

    def test_the_result_can_be_asked_for_again(self) -> None:
        future = self.submit(bytes, 5000)
        self.assertIs(future.result(), future.result())

    def test_a_small_result_takes_the_pipe(self) -> None:
        future = self.submit(bytes, 10)
        self.assertEqual(future.result(), bytes(10))
        self.assertEqual(spools(self.td), [])

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

    @unittest.skipUnless(os.name == 'nt', 'the shim acts on Windows only')
    def test_a_pool_under_the_shim_sends_a_large_result_through_a_file(self) -> None:
        # ex.map is how the pipeline's second scan asks for results, submit how its first does
        script = (
            "import concurrent.futures as cf, os, sys\n"
            "import big_result\n"
            "big_result.LIMIT = 1000\n"
            "def spools(): return [n for n in os.listdir(os.environ['TEMP']) if n.startswith('nspb-result-')]\n"
            "if __name__ == '__main__':\n"
            "    with cf.ProcessPoolExecutor(2) as ex:\n"
            "        f = ex.submit(bytes, 5000)\n"
            "        cf.wait([f])\n"
            "        assert len(spools()) == 1, spools()\n"
            "        assert f.result() == bytes(5000)\n"
            "        assert list(ex.map(bytes, [6000, 10])) == [bytes(6000), bytes(10)]\n"
            "    assert spools() == [], spools()\n")
        with tempfile.TemporaryDirectory() as td, tempfile.TemporaryDirectory() as tmp:
            shim.install(Path(td), python_exe=sys.executable)
            env = dict(os.environ, PYTHONPATH=td, NSPB_SHIM_OFF='', TEMP=tmp, TMP=tmp)
            r = subprocess.run([sys.executable, '-c', script], env=env, capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)


if __name__ == '__main__':
    unittest.main()
