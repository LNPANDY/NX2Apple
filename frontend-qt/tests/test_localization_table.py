"""nspb_qt.l10n reads frontend/l10n/*.json: the texts are the ones in the files, and a missing or broken file never stops the app."""
from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'frontend-qt'))

from nspb_qt import l10n   # noqa: E402
from nspb_qt.i18n import Lang   # noqa: E402
from nspb_qt.l10n import TABLE, load, t   # noqa: E402


class Files(unittest.TestCase):
    def test_the_checkout_has_every_language_and_english_and_chinese_have_every_key(self):
        loaded = load(str(ROOT / 'frontend' / 'l10n'))
        self.assertEqual(sorted(loaded), ['de', 'en', 'fr', 'it', 'ja', 'sv', 'zh'])
        self.assertEqual(set(loaded['en']), set(loaded['zh']))
        self.assertNotIn('_language', loaded['en'])
        self.assertEqual(set(TABLE), set(loaded['en']))

    def test_tabs_newlines_and_backslashes_are_the_text_they_mean(self):
        for code, text in TABLE['fail.noTitleID.next'].items():
            self.assertIn('\n', text, code)
        self.assertIn('C:\\VulkanSDK\\', TABLE['dep.spirv.hint.win']['en'])
        self.assertNotIn('\\\\', TABLE['dep.spirv.hint.win']['en'])

    def test_the_stale_frameworks_texts_are_there(self):
        self.assertEqual(t('stale.go', Lang('de')), 'Fortfahren')
        self.assertEqual(t('stale.go', Lang('zh')), '继续')

    def test_a_language_without_the_key_shows_english_and_an_unknown_key_shows_itself(self):
        with tempfile.TemporaryDirectory() as d:
            for code, body in {'en': {'a': 'A'}, 'zh': {'a': '甲'}, 'sv': {}}.items():
                (Path(d) / f'{code}.json').write_text(json.dumps({'_language': {'name': code, 'locales': [code]}, **body}), encoding='utf-8')
            reports: list[str] = []
            table = l10n._table(load(d, report=reports.append))
            self.assertEqual(table['a'], {'zh': '甲', 'en': 'A', 'sv': 'A'})
            self.assertEqual(reports, [])   # de and fr have no file, so they are not languages here
    def test_nothing_found_or_a_broken_file_reports_and_loads_nothing(self):
        reports: list[str] = []
        self.assertEqual(load(None, report=reports.append), {})
        self.assertEqual(len(reports), 1)
        with tempfile.TemporaryDirectory() as d:
            (Path(d) / 'en.json').write_text('{ not json', encoding='utf-8')
            reports.clear()
            self.assertEqual(load(d, report=reports.append), {})
            self.assertEqual(len(reports), 2, reports)   # en.json is broken and zh.json is missing
            self.assertEqual(l10n._table({}), {})


if __name__ == '__main__':
    unittest.main()
