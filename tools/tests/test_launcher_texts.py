"""The texts of a game's settings screen are translated in the iOS shell (LNPANDY/NX2Apple#429).

A game's `launcher.json` is English and owned by seedds/nxnative. The shell looks each section, label, note and option label up in
its ShellUI catalog by that English text. Upstream writes the texts in `dm/games/settings.tsv` (and the game language names in
`dm/tools/nacp.py`), so these tests read what the engine at the pin has and fail with the text that has no Chinese entry. When the
pin bump adds or changes a text, add it to `frontend/l10n` (a `launch.*` line, or an `ios.setting.*` line when the Mac's table words
it differently), run `python3 tools/l10n_shell_catalogs.py`, and regenerate `launcher_texts.txt` with
`python3 tools/tests/test_launcher_texts.py --write`. `launcher_texts.txt` is the same list for a checkout without `engine/`.
"""
import importlib
import json
import sys
import unittest
from pathlib import Path

TESTS = Path(__file__).resolve().parent
ROOT = TESTS.parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
C = importlib.import_module('l10n_shell_catalogs')

ENGINE = ROOT / 'engine'
FIXTURE = TESTS / 'launcher_texts.txt'


def engine_texts() -> set[str]:
    """Every English text launcher.json can carry: section, label, note and the fixed choice labels of settings.tsv, and the
    game language names (the options of a `languages` choice)."""
    texts: set[str] = set()
    tsv = ENGINE / 'dm' / 'games' / 'settings.tsv'
    for line in tsv.read_text(encoding='utf-8').splitlines():
        if not line.strip() or line.startswith('#'):
            continue
        cols = line.split('\t')
        texts.update(c for c in cols[5:8] if c)
        if cols[1] == 'choice' and cols[2] != 'languages':
            texts.update(pair.split('?', 1)[0].split('=', 1)[1] for pair in cols[2].split(','))
    sys.path.insert(0, str(ENGINE / 'dm' / 'tools'))
    try:
        nacp = importlib.import_module('nacp')
    finally:
        sys.path.pop(0)
    texts.update(name for _, name in nacp.LANGUAGES)
    return texts


def catalog() -> dict:
    return json.loads(C.catalog_path('ShellUI').read_text(encoding='utf-8'))['strings']


def missing_in_chinese(texts) -> list[str]:
    strings = catalog()
    return sorted(t for t in texts if 'zh-Hans' not in strings.get(t, {}).get('localizations', {}))


class LauncherTexts(unittest.TestCase):
    def test_every_checked_in_text_has_a_chinese_entry(self):
        texts = [t for t in FIXTURE.read_text(encoding='utf-8').splitlines() if t]
        self.assertTrue(texts)
        self.assertEqual(missing_in_chinese(texts), [], 'ShellUI catalog has no zh-Hans text for these launcher.json texts')

    def test_every_text_of_the_engine_has_a_chinese_entry(self):
        if not (ENGINE / 'dm' / 'games' / 'settings.tsv').is_file():
            self.skipTest('engine/ is not built (python3 tools/engine.py sync): only the checked-in list is checked')
        self.assertEqual(missing_in_chinese(engine_texts()), [],
                         'the engine at the pin has launcher.json texts with no zh-Hans entry in the ShellUI catalog: see this file\'s docstring')

    def test_the_checked_in_list_is_the_engines(self):
        if not (ENGINE / 'dm' / 'games' / 'settings.tsv').is_file():
            self.skipTest('engine/ is not built (python3 tools/engine.py sync)')
        checked_in = {t for t in FIXTURE.read_text(encoding='utf-8').splitlines() if t}
        found = engine_texts()
        self.assertEqual(sorted(found - checked_in), [], 'new launcher.json texts upstream: run python3 tools/tests/test_launcher_texts.py --write')
        self.assertEqual(sorted(checked_in - found), [], 'texts upstream no longer has: run python3 tools/tests/test_launcher_texts.py --write')

    def test_a_text_the_mac_words_differently_has_its_own_line(self):
        english = C.load_languages()['en']
        for key in (k for k in english if k.startswith('ios.setting.')):
            twin = key.replace('ios.setting.', 'launch.set.')
            self.assertNotEqual(english[key], english.get(twin), f'{key} says what {twin} says: delete it')


if __name__ == '__main__':
    if sys.argv[1:] == ['--write']:
        FIXTURE.write_text(''.join(t + '\n' for t in sorted(engine_texts())), encoding='utf-8')
        print(f'wrote {FIXTURE}')
    else:
        unittest.main()
