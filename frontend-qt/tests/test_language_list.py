"""The language list comes from frontend/l10n (LNPANDY/NX2Apple#388, step 2): the language button, the detection and the names.

The real files are used, and one more language is a temporary `xx.json` in a temporary folder that NX_L10N_DIR names.
"""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'frontend-qt'))

from nspb_qt import l10n   # noqa: E402
from nspb_qt.i18n import Lang   # noqa: E402

FILES = ROOT / 'frontend' / 'l10n'


def detected_before(low: str) -> str:
    """The detection of the Windows ISO code and of the environment tag before the files, as it was written."""
    if low.startswith('zh') or 'chinese' in low:
        return 'zh'
    if low.startswith('sv') or 'swedish' in low:
        return 'sv'
    if re.match(r'de($|[^a-z])', low) or 'german' in low or 'deutsch' in low:
        return 'de'
    return 'fr' if re.match(r'fr(?![a-z])', low) or 'french' in low else 'en'


# What the old code was given: BCP-47 and POSIX tags, the Windows locale names, the ISO 639 codes GetLocaleInfoW answers.
OLD_INPUTS = [
    '', 'en', 'en_us', 'en-gb', 'english_united states', 'c', 'posix', 'default', 'dv_mv', 'fry', 'fry_nl', 'ja_jp', 'japanese_japan', 'pt_br',
    'portuguese_brazil', 'es_es', 'spanish_spain', 'it_it', 'ko_kr', 'da_dk', 'nb_no', 'fi_fi', 'x',
    'zh', 'zh_cn', 'zh-hans', 'zh-hant', 'zh_tw.utf-8', 'zh_cn.utf-8', 'chinese', 'chinese_china', 'chinese (simplified)_china',
    'chinese (traditional)_taiwan', 'chinese (simplified, prc)', 'chinese_hong kong sar',
    'sv', 'sv_se', 'sv-fi', 'sv_se.utf-8', 'swedish_sweden', 'swedish (finland)_finland',
    'de', 'de_de', 'de-at', 'de_ch.utf-8', 'german_germany', 'german (switzerland)_switzerland', 'deutsch (deutschland)', 'deutsch', 'dev', 'deu',
    'fr', 'fr_fr', 'fr-ca', 'fr_be.utf-8', 'french_france', 'french (canada)_canada', 'french_belgium', 'fra',
]


class PickerList(unittest.TestCase):
    def test_the_button_cycles_the_five_languages_in_the_order_it_always_had_then_italian_and_japanese(self):
        self.assertEqual([lang.code for lang in Lang.all()], ['zh', 'en', 'sv', 'de', 'fr', 'it', 'ja'])
        self.assertEqual([lang.name for lang in Lang.all()], ['中文', 'English', 'Svenska', 'Deutsch', 'Français', 'Italiano', '日本語'])
        self.assertEqual([Lang(c).other.code for c in ('zh', 'en', 'sv', 'de', 'fr', 'it', 'ja')], ['en', 'sv', 'de', 'fr', 'it', 'ja', 'zh'])
        self.assertEqual([Lang(c).toggle_label for c in ('zh', 'en', 'sv', 'de', 'fr', 'it', 'ja')], ['EN', 'Svenska', 'Deutsch', 'Français', 'Italiano', '日本語', '中文'])

    def test_find_knows_a_code_only_when_a_file_has_it(self):
        self.assertEqual(Lang.find('sv'), Lang('sv'))
        for code in ('', 'xx', 'SV'):
            self.assertIsNone(Lang.find(code), code)

    def test_a_language_without_a_file_shows_its_code_and_cycles_to_the_first(self):
        self.assertEqual(Lang('xx').name, 'xx')
        self.assertEqual(Lang('xx').other, Lang('zh'))


class Detection(unittest.TestCase):
    def test_every_input_the_old_detection_handled_selects_the_same_language(self):
        # A language whose file came after the five may claim an input the old code gave English: it_it is Italian now, ja_jp Japanese.
        added = {lang.code for lang in Lang.all()} - {'zh', 'en', 'sv', 'de', 'fr'}
        for low in OLD_INPUTS:
            got, before = Lang.detect(low).code, detected_before(low)
            if before == 'en' and got in added:
                continue
            self.assertEqual(got, before, low)
        self.assertEqual(Lang.detect('it_it').code, 'it')
        self.assertEqual(Lang.detect('ja_jp').code, 'ja')

    def test_every_locale_a_file_lists_selects_that_file(self):
        for lang in Lang.all():
            for name in lang.locales:
                self.assertEqual(Lang.detect(name + '_xx' if len(name) <= 3 else name + ' (xx)_xx'), lang, name)

    def test_the_names_the_old_code_matched_are_in_the_files(self):
        listed = {lang.code: set(lang.locales) for lang in Lang.all()}
        self.assertTrue({'zh', 'chinese'} <= listed['zh'])
        self.assertTrue({'sv', 'swedish'} <= listed['sv'])
        self.assertTrue({'de', 'german', 'deutsch'} <= listed['de'])
        self.assertTrue({'fr', 'french'} <= listed['fr'])


class SixthLanguage(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix='nx-l10n-')
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        for f in FILES.glob('*.json'):
            shutil.copy(f, self.tmp)
        (Path(self.tmp) / 'xx.json').write_text(
            json.dumps({'_language': {'name': 'Xenia', 'locales': ['xx', 'xenian']}, 'onboarding.start': 'Go'}), encoding='utf-8')

    def test_it_is_in_the_list_after_the_ordered_ones_and_a_prefix_selects_it(self):
        languages, catalogs = l10n.read(self.tmp)
        self.assertEqual([lang.code for lang in languages], ['zh', 'en', 'sv', 'de', 'fr', 'it', 'ja', 'xx'])
        self.assertEqual(languages[-1].name, 'Xenia')
        self.assertEqual(Lang.detect('xx_yy', languages), Lang('xx'))
        self.assertEqual(Lang.detect('xenian_land', languages), Lang('xx'))
        self.assertEqual(Lang.detect('de_de', languages), Lang('de'))
        self.assertEqual(Lang.detect('ko_kr', languages), Lang('en'))
        self.assertEqual(catalogs['xx'], {'onboarding.start': 'Go'})
        table = l10n._table(catalogs)
        self.assertEqual(table['onboarding.start']['xx'], 'Go')
        self.assertEqual(table['onboarding.later']['xx'], table['onboarding.later']['en'], 'a text it lacks is English')

    def run_in_new_process(self, code: str, **env: str) -> str:
        """The app's own import, in a process whose NX_L10N_DIR names the temporary folder: no code is changed for the new language."""
        clean = {k: v for k, v in os.environ.items() if k not in ('NSPB_LANG', 'LANG', 'LC_ALL', 'NX_L10N_DIR')}
        out = subprocess.run([sys.executable, '-c', 'import sys; sys.path.insert(0, %r)\n%s' % (str(ROOT / 'frontend-qt'), code)],
                             capture_output=True, text=True, env={**clean, 'NX_L10N_DIR': self.tmp, **env}, check=True)
        return out.stdout.strip()

    def test_the_app_picks_it_up_from_nx_l10n_dir(self):
        listing = self.run_in_new_process('from nspb_qt.i18n import Lang\nprint([(l.code, l.name) for l in Lang.all()][-1], Lang.all()[-2].other.name)')
        self.assertEqual(listing, "('xx', 'Xenia') Xenia")
        self.assertEqual(self.run_in_new_process('from nspb_qt.i18n import Lang\nprint(Lang.initial().code)', NSPB_LANG='xx'), 'xx')
        device = 'import locale\nlocale.getlocale = lambda *a: ("xx_YY", None)   # the device language\nfrom nspb_qt.i18n import Lang\nprint(Lang.initial().code)'
        self.assertEqual(self.run_in_new_process(device), 'xx')
        self.assertEqual(self.run_in_new_process('from nspb_qt.l10n import t\nfrom nspb_qt.i18n import Lang\nprint(t("onboarding.start", Lang("xx")))'), 'Go')


if __name__ == '__main__':
    unittest.main()
