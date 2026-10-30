"""The generated Qt table carries a complete German column, the same one the Swift table has."""
from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'frontend-qt'))

from nspb_qt.i18n import Lang   # noqa: E402
from nspb_qt.localization import TABLE, t   # noqa: E402

PLACEHOLDER = re.compile(r'%(?:\d+\$)?(?:\.\d+)?(?:ll|l)?[@dsf%]')


class German(unittest.TestCase):
    def test_every_key_has_german_text_that_is_not_the_english_fallback(self):
        # dep.python.hint is a list of package names, the same in every language
        prose = [k for k, row in TABLE.items() if row[3] == row[1] and len(row[1]) > 30 and k != 'dep.python.hint']
        self.assertEqual(prose, [], 'English text left in the German column')
        self.assertTrue(all(row[3] for row in TABLE.values()))

    def test_placeholders_match_english_in_count_and_order(self):
        for key, row in TABLE.items():
            self.assertEqual(PLACEHOLDER.findall(row[3]), PLACEHOLDER.findall(row[1]), key)

    def test_german_has_no_semicolons_and_no_added_product_name(self):
        for key, row in TABLE.items():
            self.assertNotIn(';', row[3], key)
            self.assertNotIn('；', row[3], key)
            if 'NX2Apple' not in row[1]:
                self.assertNotIn('NX2Apple', row[3], key)

    def test_t_picks_the_german_column(self):
        self.assertEqual(t('settings.language.de', Lang.DE), 'Deutsch')
        self.assertEqual(t('dep.recheck', Lang.DE), 'Erneut prüfen')
        self.assertEqual(t('onboarding.stepCount', Lang.DE, 2, 5), 'Schritt 2 von 5')
        self.assertEqual(t('dep.recheck', Lang.EN), 'Check again')

    def test_escapes_of_the_swift_table_become_text(self):
        self.assertIn('\t', t('install.step1', Lang.DE))
        self.assertIn('\n', t('fail.noTitleID.next', Lang.DE))
        self.assertNotIn('\\\\', t('dep.spirv.hint.win', Lang.DE))


if __name__ == '__main__':
    unittest.main()
