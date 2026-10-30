"""gen_localization.py turns the Swift escapes into the text they mean, in every column."""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'frontend-qt'))

from nspb_qt.localization import TABLE   # noqa: E402


class Escapes(unittest.TestCase):
    def test_tabs_newlines_and_backslashes_are_unescaped(self):
        for column, text in enumerate(TABLE['install.step1']):
            self.assertIn('\t', text, column)
            self.assertNotIn('\\t', text, column)
        for column, text in enumerate(TABLE['fail.noTitleID.next']):
            self.assertIn('\n', text, column)
        self.assertIn('C:\\VulkanSDK\\', TABLE['dep.spirv.hint.win'][1])
        self.assertNotIn('\\\\', TABLE['dep.spirv.hint.win'][1])


if __name__ == '__main__':
    unittest.main()
