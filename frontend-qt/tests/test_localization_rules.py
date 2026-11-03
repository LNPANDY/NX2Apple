"""The rules every language file in frontend/l10n has to keep (LNPANDY/NX2Apple#388).

The languages are the files of the folder, so a new `<code>.json` is checked here without a change to this test.
The Mac launcher has the same rules in frontend/Tests/NXCoreTests/LocalizationRulesTests.swift.
"""
from __future__ import annotations

import json
import re
import unittest
from pathlib import Path

L10N = Path(__file__).resolve().parents[2] / 'frontend' / 'l10n'
REQUIRED = ('en', 'zh')   # every key is in these two, and English is what a missing text falls back to

# printf placeholders (%@, %d, %ld, %.1f, %s, positional %1$@, and %%) and {0} or {name}
PRINTF = re.compile(r'%(?:(\d+)\$)?(\.\d+)?(ll|l)?([@dsf%])')
BRACES = re.compile(r'\{(\w*)\}')


def placeholders(text: str) -> tuple[dict[int, str], int, list[str]]:
    """What String(format:) and str.format read: the type of each argument by its position, the count of %%, and the braces.

    A positional `%2$@` is argument 2, so a translation may reorder arguments. Without a position they count 1, 2, 3.
    """
    args: dict[int, str] = {}
    percents = 0
    nxt = 1
    for position, precision, length, kind in PRINTF.findall(text):
        if kind == '%':
            percents += 1
            continue
        index = int(position) if position else nxt
        if not position:
            nxt += 1
        args[index] = f'{precision}{length}{kind}'
    return args, percents, sorted(BRACES.findall(text))


def raw_keys(path: Path) -> list[str]:
    """The keys in the order the file has them. The files are one entry per line, indented by two spaces."""
    return [m.group(1) for m in re.finditer(r'^  "((?:[^"\\]|\\.)*)": ', path.read_text(encoding='utf-8'), re.M)]


class LanguageFiles(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.paths = {p.stem: p for p in sorted(L10N.glob('*.json')) if not p.name.startswith('.')}
        cls.files: dict[str, dict] = {code: json.loads(p.read_text(encoding='utf-8')) for code, p in cls.paths.items()}
        cls.texts = {code: {k: v for k, v in body.items() if k != '_language'} for code, body in cls.files.items()}

    def test_english_and_chinese_exist_and_have_the_same_keys(self):
        for code in REQUIRED:
            self.assertIn(code, self.texts, f'{code}.json is missing')
        self.assertEqual(set(self.texts['en']), set(self.texts['zh']),
                         'English and Chinese need every key: only in en %s, only in zh %s' % (
                             sorted(set(self.texts['en']) - set(self.texts['zh'])),
                             sorted(set(self.texts['zh']) - set(self.texts['en']))))

    def test_no_language_has_a_key_english_does_not_have(self):
        english = set(self.texts['en'])
        for code, texts in self.texts.items():
            self.assertEqual(sorted(set(texts) - english), [], f'{code}.json has keys that en.json does not have')

    def test_placeholders_match_the_english_text_of_the_same_key(self):
        for code, texts in self.texts.items():
            for key, text in texts.items():
                self.assertEqual(placeholders(text), placeholders(self.texts['en'][key]), f'{code}.json {key}')

    def test_every_value_is_a_non_empty_text(self):
        for code, texts in self.texts.items():
            for key, value in texts.items():
                self.assertIsInstance(value, str, f'{code}.json {key} is not a text')
                self.assertTrue(value.strip(), f'{code}.json {key} is empty')

    def test_every_file_has_a_language_entry_with_name_and_locales(self):
        for code, body in self.files.items():
            entry = body.get('_language')
            self.assertIsInstance(entry, dict, f'{code}.json has no _language')
            self.assertTrue(isinstance(entry.get('name'), str) and entry['name'].strip(), f'{code}.json: _language has no name')
            locales = entry.get('locales')
            self.assertTrue(isinstance(locales, list) and locales and all(isinstance(s, str) and s for s in locales),
                            f'{code}.json: _language has no locales')
            self.assertIn(code, locales, f'{code}.json: the code is one of its locales')
            self.assertTrue(all(s == s.lower() for s in locales), f'{code}.json: locales are lowercase')
            if 'order' in entry:
                self.assertTrue(isinstance(entry['order'], int) and not isinstance(entry['order'], bool), f'{code}.json: order is a number')

    def test_the_files_are_flat_and_sorted_with_language_first(self):
        for code, path in self.paths.items():
            keys = raw_keys(path)
            self.assertEqual(keys[:1], ['_language'], f'{code}.json starts with _language')
            self.assertEqual(keys[1:], sorted(keys[1:]), f'{code}.json keys are not sorted')
            self.assertEqual(len(keys), len(set(keys)), f'{code}.json has a duplicate key')
            self.assertEqual(len(keys), len(self.files[code]), f'{code}.json has an entry that is not one line at the top level')
            self.assertTrue(path.read_text(encoding='utf-8').endswith('}\n'), f'{code}.json ends with a newline')

    def test_languages_have_distinct_codes_and_locales(self):
        seen: dict[str, str] = {}
        for code, body in self.files.items():
            for locale in body['_language']['locales']:
                self.assertNotIn(locale, seen, f'{code}.json and {seen.get(locale)}.json both claim {locale}')
                seen[locale] = code


if __name__ == '__main__':
    unittest.main()
