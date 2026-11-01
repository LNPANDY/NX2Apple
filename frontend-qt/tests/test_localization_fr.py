"""The generated Qt table carries the French column of Localization.swift, complete."""
from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'frontend-qt'))

from nspb_qt.i18n import Lang   # noqa: E402
from nspb_qt.localization import TABLE, t   # noqa: E402

# %@, %d, %ld, %%, positional %1$@ and float %.1f, as in FrenchLocalizationTests.swift
PLACEHOLDER = re.compile(r'%(?:\d+\$)?(?:\.\d+)?l{0,2}[@dfs%]')


class FrenchTable(unittest.TestCase):
    def test_every_row_has_french_and_its_placeholders(self):
        for key, (_, en, _, _, fr, _) in TABLE.items():
            self.assertTrue(fr, key)
            self.assertEqual(PLACEHOLDER.findall(fr), PLACEHOLDER.findall(en), key)

    def test_t_reads_the_french_column(self):
        self.assertEqual(t('onboarding.start', Lang.FR), 'Commencer')
        self.assertEqual(t('settings.language.fr', Lang.FR), 'Français')
        self.assertEqual(t('dep.install.begin', Lang.FR, 'zstd'), 'Installation de zstd…')


if __name__ == '__main__':
    unittest.main()
