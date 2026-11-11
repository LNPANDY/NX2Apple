"""`multiprocessing.Pool().map` under the Windows shim runs on worker processes.

The shim swaps `multiprocessing.Pool` for a pool of threads, which suits `patch_nso.py` (Capstone
releases the GIL) and not the engine's `c1_guard.py` and `cb_extent.py`: they check every shader
in pure Python, so on threads the whole table was one core's work. These tests run the generated
`sitecustomize.py` with its platform check switched on, the way `test_win.py` does, so they run
on every platform.

    python3 -m unittest discover -s frontend-qt/tests -p "test_win_pool_map.py" -v
"""
from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
QT = HERE.parent
sys.path.insert(0, str(QT))

from nspb_qt.win import shim  # noqa: E402

# What the two table tools do: a function of the script itself, mapped over a long list in chunks.
GUARDED = (
    "import multiprocessing, os\n"
    "def work(n): return n * n, os.getpid()\n"
    "def main():\n"
    "    with multiprocessing.Pool(4) as pool:\n"
    "        rows = pool.map(work, range(400), chunksize=16)\n"
    "    assert [r[0] for r in rows] == [n * n for n in range(400)], 'the list or its order changed'\n"
    "    print('here' if os.getpid() in {r[1] for r in rows} else 'workers')\n"
    "if __name__ == '__main__':\n"
    "    main()\n")


class PoolMapTest(unittest.TestCase):
    def run_script(self, source: str, *args: str) -> str:
        with tempfile.TemporaryDirectory() as td:
            folder = Path(td) / 'shim'
            folder.mkdir()
            active = shim._SITECUSTOMIZE_SRC.replace("if os.name == 'nt'", "if True", 1)
            (folder / 'sitecustomize.py').write_text(active, encoding='utf-8')
            script = Path(td) / 'tool.py'
            script.write_text(source, encoding='utf-8')
            r = subprocess.run([sys.executable, str(script), *args], capture_output=True, text=True, timeout=300,
                               env={**os.environ, 'PYTHONPATH': str(folder), 'NSPB_SHIM_OFF': ''})
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        return r.stdout.strip()

    def test_a_guarded_script_maps_on_worker_processes(self) -> None:
        # how many of the workers take a chunk is the pool's business; none is run in this process
        self.assertEqual(self.run_script(GUARDED), 'workers')

    def test_a_job_of_one_chunk_stays_in_the_process(self) -> None:
        # nothing to share out, so not worth starting workers for
        self.assertEqual(self.run_script(GUARDED.replace('chunksize=16', 'chunksize=400')), 'here')

    def test_a_script_without_the_guard_stays_on_threads(self) -> None:
        # A worker would run such a script from the top again; it has to finish as before.
        unguarded = GUARDED.replace("if __name__ == '__main__':\n    main()\n", "main()\n")
        self.assertEqual(self.run_script(unguarded), 'here')

    def test_a_nested_function_stays_on_threads(self) -> None:
        # a worker process cannot find it by name
        nested = GUARDED.replace("pool.map(work, ", "pool.map(lambda n: work(n), ")
        self.assertEqual(self.run_script(nested), 'here')

    def test_the_initializer_runs_in_each_worker(self) -> None:
        script = (
            "import multiprocessing\n"
            "SEEN = []\n"
            "def init(tag): SEEN.append(tag)\n"
            "def work(n): return SEEN == ['ready']\n"
            "if __name__ == '__main__':\n"
            "    with multiprocessing.Pool(2, init, ('ready',)) as pool:\n"
            "        print(all(pool.map(work, range(64), chunksize=4)))\n")
        self.assertEqual(self.run_script(script), 'True')


if __name__ == '__main__':
    unittest.main()
