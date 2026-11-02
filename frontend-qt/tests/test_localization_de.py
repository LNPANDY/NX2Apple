"""The Qt table carries a complete German column, read from the same file the Swift launcher reads (frontend/l10n/de.json)."""
from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'frontend-qt'))

from nspb_qt.i18n import Lang   # noqa: E402
from nspb_qt.l10n import TABLE, t   # noqa: E402

PLACEHOLDER = re.compile(r'%(?:\d+\$)?(?:\.\d+)?(?:ll|l)?[@dsf%]')


class German(unittest.TestCase):
    def test_every_key_has_german_text_that_is_not_the_english_fallback(self):
        # dep.python.hint is a list of package names, the same in every language
        prose = [k for k, row in TABLE.items() if row['de'] == row['en'] and len(row['en']) > 30 and k != 'dep.python.hint']
        self.assertEqual(prose, [], 'English text left in the German column')
        self.assertTrue(all(row['de'] for row in TABLE.values()))

    def test_placeholders_match_english_in_count_and_order(self):
        for key, row in TABLE.items():
            self.assertEqual(PLACEHOLDER.findall(row['de']), PLACEHOLDER.findall(row['en']), key)

    def test_german_has_no_semicolons_and_no_added_product_name(self):
        for key, row in TABLE.items():
            self.assertNotIn(';', row['de'], key)
            self.assertNotIn('；', row['de'], key)
            if 'NX2Apple' not in row['en']:
                self.assertNotIn('NX2Apple', row['de'], key)

    def test_t_picks_the_german_column(self):
        self.assertEqual(t('settings.language.de', Lang('de')), 'Deutsch')
        self.assertEqual(t('dep.recheck', Lang('de')), 'Erneut prüfen')
        self.assertEqual(t('onboarding.stepCount', Lang('de'), 2, 5), 'Schritt 2 von 5')
        self.assertEqual(t('dep.recheck', Lang('en')), 'Check again')

    def test_newlines_and_backslashes_of_the_files_are_text(self):
        self.assertIn('\n', t('fail.noTitleID.next', Lang('de')))
        self.assertNotIn('\\\\', t('dep.spirv.hint.win', Lang('de')))


if __name__ == '__main__':
    unittest.main()
