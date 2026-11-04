"""Localised strings and the language list, read from the language files `frontend/l10n/<code>.json` (LNPANDY/NX2Apple#388).

The Mac launcher reads the same files, so both front ends say the same thing. Each file is one flat JSON
object: the keys are the texts' names, the values the texts, and `_language` is not a text. It holds the
language's own name (`name`), the lowercased prefixes and Windows locale names that select it (`locales`)
and optionally where the picker puts it (`order`). English and Chinese have every key. The other languages
may miss keys and then show the English text.

The languages are the files: a new `<code>.json` is a new language, with no change in the code.

Where the files are, in this order:
    NX_L10N_DIR              a folder named in the environment, for a try-out
    <bundle>/l10n            a frozen build (build-qt.yml adds the folder with --add-data)
    <next to the exe>/l10n   a frozen build that keeps its data beside the executable
    ../../frontend/l10n      a source run from the checkout

A missing or broken file never stops the app: that language has no texts, `t` shows the English text and
then the key, and the problem goes to standard error once (the files are read once, when this is imported).
"""
from __future__ import annotations

import json
import os
import re
import sys
from dataclasses import dataclass
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from .i18n import Lang

REQUIRED = ('en', 'zh')   # every key is in these two, and English is what a missing text falls back to


@dataclass(frozen=True)
class Language:
    """What a file says about its language. Without `_language` the name is the code and so is the only locale."""
    code: str
    name: str
    locales: tuple[str, ...]
    order: int | None = None


def _directory() -> str | None:
    """The folder with the language files, None when none of the places has en.json."""
    candidates = []
    named = os.environ.get('NX_L10N_DIR')
    if named:
        candidates.append(named)
    if getattr(sys, 'frozen', False):
        candidates.append(os.path.join(getattr(sys, '_MEIPASS', os.path.dirname(sys.executable)), 'l10n'))
        candidates.append(os.path.join(os.path.dirname(sys.executable), 'l10n'))
    else:
        candidates.append(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'frontend', 'l10n'))
    for c in candidates:
        if os.path.isfile(os.path.join(c, 'en.json')):
            return os.path.normpath(c)
    return None


def _report(message: str) -> None:
    print(f'l10n: {message}', file=sys.stderr)


def _language(code: str, body: dict) -> Language:
    entry = body.get('_language')
    name, locales, order = code, (code,), None
    if isinstance(entry, dict):
        if isinstance(entry.get('name'), str) and entry['name']:
            name = entry['name']
        given = tuple(s.lower() for s in entry.get('locales', ()) if isinstance(s, str) and s) \
            if isinstance(entry.get('locales'), list) else ()
        if given:
            locales = given
        if isinstance(entry.get('order'), int) and not isinstance(entry.get('order'), bool):
            order = entry['order']
    return Language(code, name, locales, order)


def read(directory: str | None, report=_report) -> tuple[list[Language], dict[str, dict[str, str]]]:
    """Every `*.json` in the folder: the languages in picker order and each one's texts by code.

    A file that is broken is left out. Picker order is `order` where a file has one, then the rest by code.
    """
    if directory is None:
        report('no language files found (l10n next to the app or frontend/l10n), the app shows its keys')
        return [], {}
    languages: list[Language] = []
    catalogs: dict[str, dict[str, str]] = {}
    try:
        names = sorted(n for n in os.listdir(directory) if n.endswith('.json') and not n.startswith('.'))
    except OSError as e:
        report(f'{directory} cannot be read: {e}')
        names = []
    for name in names:
        code = name[:-5]
        path = os.path.join(directory, name)
        try:
            with open(path, encoding='utf-8') as f:
                body = json.load(f)
        except (OSError, ValueError) as e:
            report(f'{path} cannot be read: {e}')
            continue
        if not isinstance(body, dict):
            report(f'{path} is not a JSON object')
            continue
        texts = {}
        for key, value in body.items():
            if key == '_language':
                continue
            if isinstance(value, str):
                texts[key] = value
            else:
                report(f'{code}.json: {key} is not a text')
        catalogs[code] = texts
        languages.append(_language(code, body))
    for code in REQUIRED:
        if f'{code}.json' not in names:
            report(f'{code}.json is missing, English and Chinese are needed')
    languages.sort(key=lambda lang: (lang.order is None, lang.order or 0, lang.code))
    return languages, catalogs


def load(directory: str | None, report=_report) -> dict[str, dict[str, str]]:
    """Every language's texts by code. A language whose file is missing or broken is left out."""
    return read(directory, report)[1]


def _table(catalogs: dict[str, dict[str, str]]) -> dict[str, dict[str, str]]:
    """key: {code: text}, for the languages that have a file. A text a language lacks is the English one."""
    english = catalogs.get('en', {})
    return {key: {code: texts.get(key, text) for code, texts in catalogs.items()} for key, text in english.items()}


LANGUAGES: list[Language]
CATALOGS: dict[str, dict[str, str]]
LANGUAGES, CATALOGS = read(_directory())
TABLE: dict[str, dict[str, str]] = _table(CATALOGS)


def t(key: str, lang: Lang, *args: object) -> str:
    """The string for `key` in `lang`, with %@-style arguments filled in.

    The files use %@ as the placeholder (the Mac launcher's String(format:)); the Qt side uses
    Python's %s, so the placeholder is translated here rather than in every call site.
    """
    row = TABLE.get(key)
    s = row.get(lang.code, row.get('en', key)) if row else key
    if not args:
        return s
    try:
        if re.search(r'%\d+\$[@d]', s):   # positional (%1$@, %2$d): the argument by its number
            return re.sub(r'%(\d+)\$([@d])', lambda m: str(args[int(m.group(1)) - 1]), s)
        py = s.replace("%@", "%s")   # %d is the same in both; %@ is Swift-only
        return py % args
    except (TypeError, ValueError, IndexError):
        return s
