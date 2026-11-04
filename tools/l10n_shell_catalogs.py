#!/usr/bin/env python3
"""Generate the string catalogs of the iOS shell from the language files (LNPANDY/NX2Apple#388, step 5).

The shell's texts are lines of `frontend/l10n/<code>.json`, next to the launchers' texts, under two prefixes:

    ios.ui.*    ShellUI,   frontend-ios/Sources/ShellUI/Resources/Localizable.xcstrings
    ios.host.*  ShellHost, frontend-ios/Sources/ShellHost/Resources/Localizable.xcstrings

The rows of a game's settings screen are not the shell's texts. They come from the game's `launcher.json` (seedds/nxnative, English, its
format is not ours to change), and the shell shows them in the player's language by their English text, through the ShellUI catalog:
the section, label, note and option labels the Mac launcher already translates (`launch.section.*`, `launch.set.*`, `launch.opt.*`)
go into the ShellUI catalog too, with no second copy of the translation, plus the few `ios.setting.*` lines for a text upstream writes
differently from the Mac's table. A text with no catalog entry shows as it is, in English. See "Game settings" in frontend-ios/README.md.

The Swift code asks for a text by its English words (`ShellStrings.text("Done")`, `Text("Settings")`), which is what an Xcode
string catalog keys on. So the catalog's key is the English text of the JSON key (`%@` and `%lld` stay as they are), and every
language file that has the JSON key adds one localization. The languages are the files of the folder: a new `<code>.json` shows
up here with no change in this tool. A language that lacks a key would fall back to English, so `--check` fails when a language file
lacks a text of a catalog: every shell text comes in every language of the folder.

    python3 tools/l10n_shell_catalogs.py            # write the catalogs
    python3 tools/l10n_shell_catalogs.py --check    # exit 1 when a committed catalog differs from what the files give,
                                                    # or a language lacks a shell text
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
L10N = ROOT / 'frontend' / 'l10n'
SOURCES = ROOT / 'frontend-ios' / 'Sources'

# JSON key prefix and the target of the catalog it fills. ShellDemo has its own English-only catalog for the demo app.
CATALOGS = {
    'ShellUI': 'ios.ui.',
    'ShellHost': 'ios.host.',
}

# More prefixes whose texts go into a catalog. Two keys with the same English text share an entry when every language reads the same.
EXTRA_PREFIXES = {
    'ShellUI': ('ios.setting.', 'launch.section.', 'launch.set.', 'launch.opt.'),
}


def prefixes(target: str) -> tuple[str, ...]:
    return (CATALOGS[target], *EXTRA_PREFIXES.get(target, ()))


# The language code of a file and the code Xcode and iOS know it by. Every other code is the same in both.
APPLE_CODES = {'zh': 'zh-Hans'}
SOURCE_LANGUAGE = 'en'


def apple_code(code: str) -> str:
    return APPLE_CODES.get(code, code)


def catalog_path(target: str) -> Path:
    return SOURCES / target / 'Resources' / 'Localizable.xcstrings'


def load_languages(l10n: Path = L10N) -> dict[str, dict[str, str]]:
    """The texts of every language file of the folder, by language code. `_language` is not a text."""
    languages: dict[str, dict[str, str]] = {}
    for path in sorted(l10n.glob('*.json')):
        if path.name.startswith('.'):
            continue
        body = json.loads(path.read_text(encoding='utf-8'))
        languages[path.stem] = {k: v for k, v in body.items() if k != '_language'}
    if SOURCE_LANGUAGE not in languages:
        raise SystemExit(f'{l10n}/{SOURCE_LANGUAGE}.json is missing')
    return languages


def apple_codes(languages: dict[str, dict[str, str]]) -> list[str]:
    """What the shell app declares as CFBundleLocalizations: every language file, English first, the rest by code."""
    codes = sorted(apple_code(c) for c in languages if c != SOURCE_LANGUAGE)
    return [SOURCE_LANGUAGE, *codes]


def build(languages: dict[str, dict[str, str]], prefix: str | tuple[str, ...]) -> dict:
    """One catalog: the English text of each `prefix*` key is the key, each language that has the JSON key is a localization.
    Two keys with the same English text and the same translations are one entry, with different ones they cannot both be."""
    english = languages[SOURCE_LANGUAGE]
    strings: dict[str, dict] = {}
    owner: dict[str, str] = {}
    for json_key in sorted(k for k in english if k.startswith(prefix)):
        text = english[json_key]
        localizations = {}
        for code, texts in languages.items():
            if json_key in texts:
                localizations[apple_code(code)] = {'stringUnit': {'state': 'translated', 'value': texts[json_key]}}
        entry = {'localizations': dict(sorted(localizations.items(), key=lambda item: (item[0] != SOURCE_LANGUAGE, item[0])))}
        if text in owner:
            if strings[text] != entry:
                raise SystemExit(f'{json_key} and {owner[text]} have the same English text {text!r} and different translations: one catalog key cannot carry both')
            continue
        owner[text] = json_key
        strings[text] = entry
    return {'sourceLanguage': SOURCE_LANGUAGE, 'strings': strings, 'version': '1.0'}


def missing(languages: dict[str, dict[str, str]]) -> dict[str, list[str]]:
    """The catalogs' JSON keys that a language file lacks, by language code. Empty when every shell text has every language."""
    wanted = tuple(p for target in CATALOGS for p in prefixes(target))
    keys = sorted(k for k in languages[SOURCE_LANGUAGE] if k.startswith(wanted))
    out = {code: [k for k in keys if k not in texts] for code, texts in sorted(languages.items())}
    return {code: lacking for code, lacking in out.items() if lacking}


def render(catalog: dict) -> str:
    """The text of the file. Keys are sorted, two spaces, no final newline: what the committed catalogs have always had."""
    return json.dumps(catalog, ensure_ascii=False, indent=2, sort_keys=True)


def expected(l10n: Path = L10N) -> dict[str, str]:
    languages = load_languages(l10n)
    return {target: render(build(languages, prefixes(target))) for target in CATALOGS}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('--check', action='store_true', help='do not write, exit 1 when a catalog differs')
    args = parser.parse_args(argv)
    stale = []
    for target, text in expected().items():
        path = catalog_path(target)
        current = path.read_text(encoding='utf-8') if path.exists() else None
        if current == text:
            continue
        stale.append(str(path.relative_to(ROOT)))
        if not args.check:
            path.write_text(text, encoding='utf-8')
            print(f'wrote {path.relative_to(ROOT)}')
    if args.check and stale:
        print('out of date, run python3 tools/l10n_shell_catalogs.py: ' + ', '.join(stale), file=sys.stderr)
        return 1
    lacking = missing(load_languages())
    for code, keys in lacking.items():
        print(f'frontend/l10n/{code}.json lacks {len(keys)} shell texts: ' + ', '.join(keys), file=sys.stderr)
    return 1 if args.check and lacking else 0


if __name__ == '__main__':
    sys.exit(main())
