"""The staging folder for files picked from several folders (#132): the same selection stages to the
same paths with the same sizes and dates, and the folder holds exactly the current selection."""
from __future__ import annotations

import os
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'frontend-qt'))

from nspb_qt import input_staging   # noqa: E402


def make(path: Path, age: int) -> str:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(b'x' * 4096)
    t = path.stat().st_mtime_ns - age * 10**9
    os.utime(path, ns=(t, t))
    return str(path)


def seen(d: str) -> list[tuple]:
    return [(p.name, p.stat().st_size, p.stat().st_mtime_ns) for p in sorted(Path(d).iterdir())]


class InputStagingTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)
        self.work = str(self.root / '0100000000000000_build')

    def test_two_stagings_are_identical(self):
        for hard in (True, False):
            files = [make(self.root / 'a' / 'base.nsp', 5000), make(self.root / 'b' / 'update.nsp', 9000)]
            d = input_staging.folder(self.work + str(hard))
            self.assertEqual(input_staging.sync(files, d, hard_links=hard), 2)
            first = seen(d)
            self.assertEqual(input_staging.sync(files, d, hard_links=hard), 2)
            self.assertEqual(seen(d), first)
            self.assertEqual([p.stat().st_mtime_ns for p in sorted(Path(d).iterdir())],
                             [os.stat(f).st_mtime_ns for f in sorted(files, key=os.path.basename)])

    def test_stale_entry_removed_build_folders_kept(self):
        base = make(self.root / 'a' / 'base.nsp', 100)
        upd = make(self.root / 'b' / 'update.nsp', 200)
        d = input_staging.folder(self.work)
        input_staging.sync([base, upd], d)
        (Path(d) / '0100000000000000_build' / 'profile').mkdir(parents=True)
        self.assertEqual(input_staging.sync([base], d), 1)
        self.assertEqual({p.name for p in Path(d).iterdir()}, {'base.nsp', '0100000000000000_build'})


if __name__ == '__main__':
    unittest.main()
