"""tools/l10n_shell_catalogs.py: the committed string catalogs of the iOS shell are what the language files give (LNPANDY/NX2Apple#388, step 5).

The catalogs are generated, so a hand edit of a catalog or an edit of `frontend/l10n` without the tool fails here. The shell offers every
language that has a file in the folder: the catalogs carry each, and the app declares each as CFBundleLocalizations.
"""
import importlib
import json
import re
import sys
import tempfile
import unittest
from pathlib import Path

TOOLS = Path(__file__).resolve().parents[1]
ROOT = TOOLS.parent
sys.path.insert(0, str(TOOLS))
C = importlib.import_module('l10n_shell_catalogs')

PRINTF = re.compile(r'%(?:\d+\$)?(?:\.\d+)?(?:ll|l)?[@dsf%]')


def write_language(folder: Path, code: str, texts: dict) -> None:
    body = {'_language': {'name': code, 'locales': [code]}, **texts}
    (folder / f'{code}.json').write_text(json.dumps(body, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


class CommittedCatalogs(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.languages = C.load_languages()

    def test_every_committed_catalog_is_what_the_language_files_give(self):
        for target, text in C.expected().items():
            path = C.catalog_path(target)
            self.assertTrue(path.exists(), f'{path} is missing')
            self.assertEqual(path.read_text(encoding='utf-8'), text,
                             f'{path.relative_to(ROOT)} is out of date: run python3 tools/l10n_shell_catalogs.py')

    def test_the_check_mode_passes_on_the_committed_files(self):
        self.assertEqual(C.main(['--check']), 0)

    def test_the_catalogs_are_in_xcode_format(self):
        for target in C.CATALOGS:
            catalog = json.loads(C.catalog_path(target).read_text(encoding='utf-8'))
            self.assertEqual(catalog['sourceLanguage'], 'en')
            self.assertEqual(catalog['version'], '1.0')
            self.assertEqual(set(catalog), {'sourceLanguage', 'strings', 'version'})
            self.assertTrue(catalog['strings'])
            for key, entry in catalog['strings'].items():
                self.assertEqual(set(entry), {'localizations'}, key)
                self.assertEqual(entry['localizations']['en']['stringUnit']['value'], key, f'the key is the English text: {key}')
                for code, localization in entry['localizations'].items():
                    self.assertEqual(localization['stringUnit']['state'], 'translated', f'{key} {code}')

    def test_format_specifiers_are_kept_in_every_language(self):
        for target in C.CATALOGS:
            for key, entry in json.loads(C.catalog_path(target).read_text(encoding='utf-8'))['strings'].items():
                for code, localization in entry['localizations'].items():
                    self.assertEqual(sorted(PRINTF.findall(localization['stringUnit']['value'])), sorted(PRINTF.findall(key)), f'{code}: {key}')

    def test_every_language_has_every_shell_text(self):
        codes = C.apple_codes(self.languages)
        self.assertEqual(sorted(codes), sorted(['en', 'zh-Hans', 'de', 'sv', 'fr', 'it', 'ja']))
        for target in C.CATALOGS:
            for key, entry in json.loads(C.catalog_path(target).read_text(encoding='utf-8'))['strings'].items():
                self.assertEqual(sorted(entry['localizations']), sorted(codes), f'{target}: {key} lacks a language')
        self.assertEqual(C.missing(self.languages), {})

    def test_every_ios_key_belongs_to_a_catalog(self):
        prefixes = tuple(p for target in C.CATALOGS for p in C.prefixes(target))
        for code, texts in self.languages.items():
            stray = sorted(k for k in texts if k.startswith('ios.') and not k.startswith(prefixes))
            self.assertEqual(stray, [], f'{code}.json has ios.* keys that no catalog takes')

    def test_the_demo_app_declares_every_language_of_the_files(self):
        codes = C.apple_codes(self.languages)
        project = (ROOT / 'frontend-ios' / 'Demo' / 'project.yml').read_text(encoding='utf-8')
        declared = re.search(r'CFBundleLocalizations:\s*\[([^\]]*)\]', project)
        self.assertIsNotNone(declared, 'Demo/project.yml has no CFBundleLocalizations')
        self.assertEqual([c.strip() for c in declared.group(1).split(',')], codes,
                         'Demo/project.yml: CFBundleLocalizations are the language files, en first')
        plist = (ROOT / 'frontend-ios' / 'Demo' / 'Gen' / 'Info.plist').read_text(encoding='utf-8')
        block = re.search(r'<key>CFBundleLocalizations</key>\s*<array>(.*?)</array>', plist, re.S)
        self.assertEqual(re.findall(r'<string>([^<]*)</string>', block.group(1)), codes, 'Demo/Gen/Info.plist is out of step with project.yml')

    def test_the_shell_app_of_the_engine_declares_every_language_of_the_files(self):
        project = ROOT / 'engine' / 'dm' / 'ios' / 'project-shell.yml'
        if not project.exists():
            self.skipTest('engine/ is not built (python3 tools/engine.py sync)')
        declared = re.search(r'CFBundleLocalizations:\s*\[([^\]]*)\]', project.read_text(encoding='utf-8'))
        self.assertIsNotNone(declared, 'dm/ios/project-shell.yml has no CFBundleLocalizations')
        self.assertEqual([c.strip() for c in declared.group(1).split(',')], C.apple_codes(self.languages),
                         'dm/ios/project-shell.yml: CFBundleLocalizations are the language files, en first (a patch in patches/)')

    def test_try_local_declares_every_language_of_the_files(self):
        text = (TOOLS / 'try-local').read_text(encoding='utf-8')
        declared = re.search(r'<key>CFBundleLocalizations</key><array>(.*?)</array>', text)
        self.assertEqual(sorted(re.findall(r'<string>([^<]*)</string>', declared.group(1))), sorted(C.apple_codes(self.languages)))


class Generator(unittest.TestCase):
    def folder(self, **languages):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        for code, texts in languages.items():
            write_language(Path(tmp.name), code, texts)
        return Path(tmp.name)

    def test_a_new_language_file_is_in_the_catalog_with_no_change_to_the_tool(self):
        folder = self.folder(en={'ios.ui.done': 'Done', 'a.b': 'x'}, zh={'ios.ui.done': '完成', 'a.b': 'y'}, es={'ios.ui.done': 'Hecho'})
        catalog = C.build(C.load_languages(folder), 'ios.ui.')
        self.assertEqual(list(catalog['strings']), ['Done'], 'only the ios.ui. keys, the key is the English text')
        self.assertEqual(list(catalog['strings']['Done']['localizations']), ['en', 'es', 'zh-Hans'])
        self.assertEqual(catalog['strings']['Done']['localizations']['es']['stringUnit']['value'], 'Hecho')
        self.assertEqual(C.apple_codes(C.load_languages(folder)), ['en', 'es', 'zh-Hans'])

    def test_a_language_without_a_key_has_no_localization_of_it(self):
        folder = self.folder(en={'ios.ui.a': 'A', 'ios.ui.b': 'B'}, zh={'ios.ui.a': 'a', 'ios.ui.b': 'b'}, sv={'ios.ui.a': 'sa'})
        strings = C.build(C.load_languages(folder), 'ios.ui.')['strings']
        self.assertIn('sv', strings['A']['localizations'])
        self.assertNotIn('sv', strings['B']['localizations'])

    def test_a_language_without_a_shell_text_fails_the_check(self):
        folder = self.folder(en={'ios.ui.a': 'A', 'ios.host.b': 'B', 'other.c': 'C'}, zh={'ios.ui.a': 'a', 'ios.host.b': 'b', 'other.c': 'c'},
                             de={'ios.ui.a': 'dA', 'other.c': 'dC'}, sv={'ios.ui.a': 'sA', 'ios.host.b': 'sB'})
        self.assertEqual(C.missing(C.load_languages(folder)), {'de': ['ios.host.b']}, 'only shell texts count, other keys may be missing')

    def test_format_specifiers_and_quotes_pass_through(self):
        folder = self.folder(en={'ios.ui.n': '"%@" is %lld of %.1f'}, zh={'ios.ui.n': '"%@" 是 %lld / %.1f'})
        strings = C.build(C.load_languages(folder), 'ios.ui.')['strings']
        self.assertEqual(list(strings), ['"%@" is %lld of %.1f'])
        self.assertEqual(strings['"%@" is %lld of %.1f']['localizations']['zh-Hans']['stringUnit']['value'], '"%@" 是 %lld / %.1f')

    def test_two_keys_with_the_same_english_text_and_different_translations_in_one_catalog_fail(self):
        folder = self.folder(en={'ios.ui.a': 'Same', 'ios.ui.b': 'Same'}, zh={'ios.ui.a': 'x', 'ios.ui.b': 'y'})
        with self.assertRaises(SystemExit):
            C.build(C.load_languages(folder), 'ios.ui.')

    def test_two_keys_with_the_same_english_text_and_the_same_translations_are_one_entry(self):
        folder = self.folder(en={'ios.ui.a': 'Same', 'launch.set.b': 'Same'}, zh={'ios.ui.a': 'x', 'launch.set.b': 'x'})
        strings = C.build(C.load_languages(folder), ('ios.ui.', 'launch.set.'))['strings']
        self.assertEqual(list(strings), ['Same'])

    def test_the_output_is_stable(self):
        folder = self.folder(en={'ios.ui.b': 'B', 'ios.ui.a': 'A'}, zh={'ios.ui.b': 'b', 'ios.ui.a': 'a'})
        first = C.render(C.build(C.load_languages(folder), 'ios.ui.'))
        self.assertEqual(first, C.render(C.build(C.load_languages(folder), 'ios.ui.')))
        self.assertLess(first.index('"A"'), first.index('"B"'))
        self.assertFalse(first.endswith('\n'))


if __name__ == '__main__':
    unittest.main()
