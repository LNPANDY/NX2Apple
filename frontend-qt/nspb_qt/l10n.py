"""Localised strings, read from the language files `frontend/l10n/<code>.json` (LNPANDY/NX2Apple#388).

The Mac launcher reads the same files, so both front ends say the same thing. Each file is one flat JSON
object: the keys are the texts' names, the values the texts, and `_language` (the language's own name and
its locale prefixes) is not a text. English and Chinese have every key. The other languages may miss keys
and then show the English text.

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
import sys

from .i18n import Lang

CODES = ('zh', 'en', 'sv', 'de', 'fr')   # the order of a TABLE row


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


def load(directory: str | None, report=_report) -> dict[str, dict[str, str]]:
    """Every language's texts by code. A language whose file is missing or broken is left out."""
    if directory is None:
        report('no language files found (l10n next to the app or frontend/l10n), the app shows its keys')
        return {}
    out: dict[str, dict[str, str]] = {}
    for code in CODES:
        path = os.path.join(directory, f'{code}.json')
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
        out[code] = texts
    return out


def _table(catalogs: dict[str, dict[str, str]]) -> dict[str, tuple[str, str, str, str, str]]:
    """key: (Chinese, English, Swedish, German, French). A text a language lacks is the English one."""
    english = catalogs.get('en', {})
    return {key: tuple(catalogs.get(code, {}).get(key, text) for code in CODES)   # type: ignore[misc]
            for key, text in english.items()}


TABLE: dict[str, tuple[str, str, str, str, str]] = _table(load(_directory()))


def t(key: str, lang: Lang, *args: object) -> str:
    """The string for `key` in `lang`, with %@-style arguments filled in.

    The files use %@ as the placeholder (the Mac launcher's String(format:)); the Qt side uses
    Python's %s, so the placeholder is translated here rather than in every call site.
    """
    row = TABLE.get(key)
    s = row[CODES.index(lang.value)] if row else key
    if not args:
        return s
    py = s.replace("%@", "%s")   # %d is the same in both; %@ is Swift-only
    try:
        return py % args
    except (TypeError, ValueError):
        return s
