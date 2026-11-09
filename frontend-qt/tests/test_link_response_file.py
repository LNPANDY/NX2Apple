"""A link with a long command line goes through a response file (issue 870, WinError 206).

CreateProcess refuses a command line over 32767 characters. The link names every object file by its
full path, so a game in a long work folder failed after an hour of building.
"""
from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'frontend-qt'))

from nspb_qt.win import build_app   # noqa: E402


class ResponseFileArgs(unittest.TestCase):
    def test_a_short_command_line_is_left_alone(self):
        with tempfile.TemporaryDirectory() as d:
            rsp = Path(d) / 'x.rsp'
            args = ['clang', '-o', 'out', 'a.o']
            self.assertEqual(build_app.response_file_args(args, rsp), args)
            self.assertFalse(rsp.exists())

    def test_a_long_command_line_moves_into_the_response_file(self):
        with tempfile.TemporaryDirectory() as d:
            rsp = Path(d) / 'x.rsp'
            objs = [f'C:\\work\\a long game name\\obj\\file{i}-0123456789abcdef.o' for i in range(600)]
            args = ['clang', '-o', 'out', *objs]
            self.assertGreater(sum(len(a) + 1 for a in args), build_app.MAX_COMMAND_LINE)
            got = build_app.response_file_args(args, rsp)
            self.assertEqual(got, ['clang', f'@{rsp.as_posix()}'])
            lines = rsp.read_text(encoding='utf-8').splitlines()
            self.assertEqual(len(lines), len(args) - 1)
            self.assertEqual(lines[0], '"-o"')
            self.assertEqual(lines[2], '"C:/work/a long game name/obj/file0-0123456789abcdef.o"')


if __name__ == '__main__':
    unittest.main()
