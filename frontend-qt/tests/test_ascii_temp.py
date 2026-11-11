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
    def setUp(self) -> None:
        self._sandbox_td = tempfile.TemporaryDirectory(prefix='nspb-ascii-test-')
        self.addCleanup(self._sandbox_td.cleanup)
        self.sandbox = Path(self._sandbox_td.name)

    def test_an_ascii_temp_is_used_as_it_is(self):
        base = self.sandbox / 'plain'
        base.mkdir()
        with mock.patch.object(tempfile, 'gettempdir', return_value=str(base)):
            with toolchain.ascii_temp_dir('probe-') as d:
                self.assertTrue(str(d).startswith(str(base) + os.sep), d)
                self.assertTrue(ascii_only(str(d)))

    def test_a_non_ascii_temp_is_skipped_when_an_ascii_one_exists(self):
        """The reported case: TEMP is C:\\Users\\<中文名>\\… and PUBLIC is available."""
        non_ascii = self.sandbox / '中文名'
        pub_dir = self.sandbox / 'public'
        pub_dir.mkdir()
        with mock.patch.object(tempfile, 'gettempdir', return_value=str(non_ascii)), \
             mock.patch.object(toolchain.os, 'name', 'nt'), \
             mock.patch.dict(os.environ, {'PUBLIC': str(pub_dir)}):
            with toolchain.ascii_temp_dir('probe-') as d:
                self.assertTrue(ascii_only(str(d)), f'{d} is not ASCII')
                self.assertNotIn('中文', str(d))
                self.assertTrue(str(d).startswith(str(pub_dir / 'Temp') + os.sep), d)

    def test_a_temp_with_spaces_is_skipped_when_a_space_free_ascii_one_exists(self):
        """metal.exe splits paths on spaces; ascii_temp_dir prefers a space-free ASCII folder."""
        spaced = self.sandbox / 'My User'
        pub_dir = self.sandbox / 'public'
        pub_dir.mkdir()
        with mock.patch.object(tempfile, 'gettempdir', return_value=str(spaced)), \
             mock.patch.object(toolchain.os, 'name', 'nt'), \
             mock.patch.dict(os.environ, {'PUBLIC': str(pub_dir)}):
            with toolchain.ascii_temp_dir('probe-') as d:
                self.assertTrue(ascii_only(str(d)), f'{d} is not ASCII')
                self.assertNotIn(' ', str(d))
                self.assertTrue(str(d).startswith(str(pub_dir / 'Temp') + os.sep), d)

    def test_it_still_yields_a_directory_when_nothing_is_ascii(self):
        """No ASCII option: a directory is still created, so the tool can fail on its own terms."""
        non_ascii = self.sandbox / '中文名'
        env_clean = {k: v for k, v in os.environ.items() if k != 'PUBLIC'}
        with mock.patch.object(tempfile, 'gettempdir', return_value=str(non_ascii)), \
             mock.patch.object(toolchain.os, 'name', 'darwin'), \
             mock.patch.dict(os.environ, env_clean, clear=True):
            with toolchain.ascii_temp_dir('probe-') as d:
                self.assertTrue(os.path.isdir(d), d)

    def test_windows_branch_on_posix_never_creates_backslash_dirs_in_cwd(self):
        """Regression for BUG-11: mocking os.name='nt' on macOS/Linux must never create a literal
        'C:\\Windows\\Temp' directory in the current working directory when PUBLIC fails."""
        if os.sep == '\\':
            self.skipTest('POSIX-only regression for literal backslash directory names')
        cwd_box = self.sandbox / 'cwd_clean_check'
        cwd_box.mkdir()
        fallback_non_ascii = self.sandbox / '回退目录'
        orig_cwd = os.getcwd()
        os.chdir(cwd_box)
        self.addCleanup(os.chdir, orig_cwd)

        real_makedirs = os.makedirs

        def reject_unwritable_public(path, *args, **kwargs):
            if str(path).startswith('/readonly_root_sim'):
                raise PermissionError('read-only root volume')
            return real_makedirs(path, *args, **kwargs)

        with mock.patch.object(tempfile, 'gettempdir', return_value=str(fallback_non_ascii)), \
             mock.patch.object(toolchain.os, 'name', 'nt'), \
             mock.patch.dict(os.environ, {'PUBLIC': '/readonly_root_sim'}), \
             mock.patch.object(toolchain.os, 'makedirs', side_effect=reject_unwritable_public):
            with toolchain.ascii_temp_dir('probe-') as d:
                self.assertTrue(os.path.isdir(d), d)

        self.assertEqual(list(cwd_box.iterdir()), [], f'Unexpected dirty dirs in cwd: {list(cwd_box.iterdir())}')
        self.assertFalse((ROOT / r'C:\Windows\Temp').exists())


if __name__ == '__main__':
    unittest.main()
