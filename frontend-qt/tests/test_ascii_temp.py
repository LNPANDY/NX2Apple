"""A tool that cannot open a non-ASCII path gets an ASCII temp directory.

Apple's Windows ports of metal.exe and metallib.exe are LLVM-based and fail with
"LLVM ERROR: Error opening '<path>'" when the path holds characters outside ASCII. On a Chinese
Windows the default TEMP is C:\\Users\\<中文名>\\AppData\\Local\\Temp, so the Metal probe reported a
broken toolchain on a machine where Metal Developer Tools were installed correctly and found — the
report's second screenshot: Metal Toolchain green, then "metallib failed: LLVM ERROR: Error opening
...\\probe.air". clang and ld64.lld read the same path fine, which is why only that probe broke.
"""
from __future__ import annotations

import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'frontend-qt'))

from nspb_qt.win import toolchain   # noqa: E402


def ascii_only(path: str) -> bool:
    return path.encode('ascii', 'ignore').decode() == path


class AsciiTempDir(unittest.TestCase):
    def test_an_ascii_temp_is_used_as_it_is(self):
        with mock.patch.object(tempfile, 'gettempdir', return_value='/tmp'):
            with toolchain.ascii_temp_dir('probe-') as d:
                self.assertTrue(str(d).startswith('/tmp/'), d)
                self.assertTrue(ascii_only(str(d)))

    def test_a_non_ascii_temp_is_skipped_when_an_ascii_one_exists(self):
        """The reported case: TEMP is C:\\Users\\<中文名>\\… and PUBLIC is available."""
        with mock.patch.object(tempfile, 'gettempdir', return_value='/tmp/中文名'), \
             mock.patch.object(toolchain.os, 'name', 'nt'), \
             mock.patch.dict(os.environ, {'PUBLIC': '/tmp'}):
            with toolchain.ascii_temp_dir('probe-') as d:
                self.assertTrue(ascii_only(str(d)), f'{d} is not ASCII')
                self.assertNotIn('中文', str(d))

    def test_a_temp_with_spaces_is_skipped_when_a_space_free_ascii_one_exists(self):
        """metal.exe splits paths on spaces; ascii_temp_dir prefers a space-free ASCII folder."""
        with mock.patch.object(tempfile, 'gettempdir', return_value='/tmp/My User'), \
             mock.patch.object(toolchain.os, 'name', 'nt'), \
             mock.patch.dict(os.environ, {'PUBLIC': '/tmp'}):
            with toolchain.ascii_temp_dir('probe-') as d:
                self.assertTrue(ascii_only(str(d)), f'{d} is not ASCII')
                self.assertNotIn(' ', str(d))

    def test_it_still_yields_a_directory_when_nothing_is_ascii(self):
        """No ASCII option: a directory is still created, so the tool can fail on its own terms."""
        with mock.patch.object(tempfile, 'gettempdir', return_value='/tmp/中文名'), \
             mock.patch.object(toolchain.os, 'name', 'darwin'):
            with toolchain.ascii_temp_dir('probe-') as d:
                self.assertTrue(os.path.isdir(d), d)


if __name__ == '__main__':
    unittest.main()
