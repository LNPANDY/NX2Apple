"""Lang.initial() has to recognise a Chinese Windows.

Two bugs stacked here, and either one alone showed a Chinese user an English interface:

* `locale.getlocale()` on Windows returns the *locale name* ("Chinese (Simplified)_China"), not a
  BCP-47 tag, so `startswith('zh')` was always False there;
* the GetUserDefaultUILanguage fallback ran only `if not tag`, and that name is never empty — so
  the call that knew better was unreachable.

The Windows API is what the Settings app's display language reflects, and it is now asked first
and unconditionally. These tests drive the environment, not the OS, so they run anywhere.
"""
from __future__ import annotations

import os
import sys
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'frontend-qt'))

from nspb_qt.i18n import Lang   # noqa: E402



def detect(locale_name: str, platform: str = 'darwin', env: dict | None = None) -> Lang:
    """Lang.initial() with locale.getlocale() answering `locale_name` and only `env` set."""
    with mock.patch.dict(os.environ, env or {}, clear=True), \
         mock.patch('locale.getlocale', return_value=(locale_name, None)), \
         mock.patch.object(sys, 'platform', platform):
        return Lang.initial()


class Detect(unittest.TestCase):
    def test_language_button_cycles_through_each_available_language(self):
        self.assertEqual(Lang.ZH.other, Lang.EN)
        self.assertEqual(Lang.EN.other, Lang.SV)
        self.assertEqual(Lang.SV.other, Lang.ZH)

    def test_a_saved_choice_wins(self):
        self.assertEqual(detect('English_United States', env={'NSPB_LANG': 'zh'}), Lang.ZH)
        self.assertEqual(detect('Chinese (Simplified)_China', env={'NSPB_LANG': 'en'}), Lang.EN)

    def test_the_windows_locale_name_is_recognised(self):
        for name in ('Chinese (Simplified)_China', 'Chinese (Traditional)_Taiwan', 'Chinese_China'):
            self.assertEqual(detect(name, platform='win32'), Lang.ZH, name)
        for name in ('English_United States', 'Japanese_Japan'):
            self.assertEqual(detect(name, platform='win32'), Lang.EN, name)

    def test_a_bcp47_tag_still_works(self):
        for tag in ('zh_CN', 'zh-Hans', 'zh'):
            self.assertEqual(detect(tag), Lang.ZH, tag)
        self.assertEqual(detect('en_US'), Lang.EN)

    def test_windows_is_asked_before_the_environment(self):
        """The API decides on Windows even though locale.getlocale() returned a name — that was the bug."""
        fake = mock.Mock()
        fake.windll.kernel32.GetUserDefaultUILanguage.return_value = 0x04   # zh-CN primary id

        def getlocale(lang, kind, buf, n):
            buf.value = 'zh'
            return 1
        fake.windll.kernel32.GetLocaleInfoW.side_effect = getlocale
        with mock.patch.dict(os.environ, {}, clear=True), \
             mock.patch.dict(sys.modules, {'ctypes': fake}), \
             mock.patch('locale.getlocale', return_value=('English_United States', None)), \
             mock.patch.object(sys, 'platform', 'win32'):
            self.assertEqual(Lang.initial(), Lang.ZH)

    def test_an_empty_locale_falls_through_to_the_environment(self):
        self.assertEqual(detect('', env={'LANG': 'zh_CN.UTF-8'}), Lang.ZH)
        self.assertEqual(detect('', env={'LANG': 'en_US.UTF-8'}), Lang.EN)

    def test_no_signal_at_all_is_english(self):
        self.assertEqual(detect(''), Lang.EN)


if __name__ == '__main__':
    unittest.main()
