"""Sorting a game folder by the title ID in the file names (issue #237), the same cases as the Mac
launcher's DropFilesTests."""
from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'frontend-qt'))

from nspb_qt import inputs   # noqa: E402


class InputsTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    def make(self, name: str, size: int = 16) -> Path:
        p = self.dir / name
        p.write_bytes(b'x' * size)
        return p

    def test_reporter_folder(self):
        base = self.make('01007EF00011E000_v0_420d1c5034ab.nsp', 64)
        old = self.make('01007EF00011E800_v1048576_48d51e6d7ff4.nsp')
        new = self.make('01007EF00011E800_v1114112_038ff9df0888.nsp')
        d1 = self.make('01007EF00011F001_v196608_8a46aae731b8.nsp')
        d2 = self.make('01007EF00011F002_v196608_193e5731baf2.nsp')
        found = inputs.classify([d2, old, base, d1, new])
        self.assertEqual(found['base'], base)
        self.assertEqual(found['update'], new)
        self.assertEqual(found['dlc'], [d1, d2])
        self.assertEqual(found['update_count'], 2)

    def test_bracket_names_still_work(self):
        base = self.make('Game [0100000000010000][v0].nsp', 64)
        upd = self.make('Game [0100000000010800][v131072].nsp')
        dlc = self.make('Game DLC [0100000000011001].nsp')
        self.make('Game [0100000000010000].xci').write_bytes(b'')   # unfinished download
        found = inputs.classify(sorted(self.dir.iterdir()))
        self.assertEqual((found['base'], found['update'], found['dlc']), (base, upd, [dlc]))

    def test_title_id_and_version_tokens(self):
        self.assertEqual(inputs.title_id('Game [0100F2C0115B6000][v0].nsp'), 0x0100F2C0115B6000)
        self.assertEqual(inputs.title_id('Game 0100AAAA00000000 [0100F2C0115B6000].nsp'), 0x0100F2C0115B6000)
        self.assertEqual(inputs.title_id('Game (01007EF00011E000).nsp'), 0x01007EF00011E000)
        self.assertIsNone(inputs.title_id('0200000000000000_v0.nsp'))
        self.assertIsNone(inputs.title_id('x01007EF00011E000.nsp'))
        self.assertIsNone(inputs.title_id('01007EF00011E0001.nsp'))
        self.assertEqual(inputs.update_version('Game [v65536] _v1.nsp'), 65536)
        self.assertEqual(inputs.update_version('01007EF00011E800_v1114112_038ff9df0888.nsp'), 1114112)
        self.assertEqual(inputs.update_version('Game v131072.nsp'), 131072)
        self.assertEqual(inputs.update_version('game.nsp'), 0)

    def test_other_games_are_left_out(self):
        base = self.make('01007EF00011E000_v0_a.nsp', 64)
        upd = self.make('01007EF00011E800_v1_b.nsp')
        self.make('0100AAAA00000800_v9_c.nsp')
        self.make('0100AAAA00001001_v0_d.nsp')
        found = inputs.classify(sorted(self.dir.iterdir()))
        self.assertEqual((found['base'], found['update'], found['dlc']), (base, upd, []))

    def test_names_without_ids_keep_the_old_markers(self):
        base = self.make('game.nsp', 64)
        upd = self.make('game [UPD].nsp')
        dlc = self.make('game [DLC].nsp')
        found = inputs.classify(sorted(self.dir.iterdir()))
        self.assertEqual((found['base'], found['update'], found['dlc']), (base, upd, [dlc]))


if __name__ == '__main__':
    unittest.main()
