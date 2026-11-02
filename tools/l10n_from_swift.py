#!/usr/bin/env python3
"""One-time converter: the Swift translation tables to one JSON file per language (LNPANDY/NX2Apple#388, step 1).

This script documents how `frontend/l10n/*.json` were made. It reads the tables that lived in
`frontend/Sources/NXCore/Localization.swift` (Chinese and English as pairs, Swedish, German and French as
dictionaries) and in `LocalizationStaleFrameworks.swift`, and writes `en.json`, `zh.json`, `sv.json`, `de.json`
and `fr.json`. It is deleted again in a later step of #388, because the JSON files are the source from then on
and the Swift tables no longer exist. Run it against the two Swift files from before the conversion
(`git show <commit before step 1>:frontend/Sources/NXCore/Localization.swift`):

    python3 tools/l10n_from_swift.py --localization Localization.swift --stale LocalizationStaleFrameworks.swift --out frontend/l10n

The Swift files are read with a small tokenizer, not with regular expressions: strings may span lines of the
source, `//` comments sit between rows, and every row must have the shape the parser expects, or it stops with
the line number. Escapes are `\\u{...}`, `\\n`, `\\t`, `\\"` and `\\\\`. Any other escape is an error.

File format: one flat JSON object per language, `_language` first, the other keys sorted, UTF-8 text without
`\\u` escapes. `_language` holds the language's own name and the locale prefixes that select it, taken from the
`Lang` enum in Swift and `Lang.initial` in `frontend-qt/nspb_qt/i18n.py` (the Windows locale names included).
English and Chinese have every key. Swedish, German and French have the keys their overlays had.
"""
from __future__ import annotations

import argparse
import json
import re
from pathlib import Path

LANGUAGES = {
    'en': {'name': 'English', 'locales': ['en']},
    'zh': {'name': '中文', 'locales': ['zh', 'chinese']},
    'sv': {'name': 'Svenska', 'locales': ['sv', 'swedish']},
    'de': {'name': 'Deutsch', 'locales': ['de', 'german', 'deutsch']},
    'fr': {'name': 'Français', 'locales': ['fr', 'french']},
}

SIMPLE = {'n': '\n', 't': '\t', '"': '"', '\\': '\\'}
ESCAPE = re.compile(r'\\u\{([0-9a-fA-F]+)\}|\\(.)', re.S)


class ParseError(Exception):
    pass


def unescape(body: str, line: int) -> str:
    def one(m: re.Match) -> str:
        if m[1]:
            return chr(int(m[1], 16))
        if m[2] in SIMPLE:
            return SIMPLE[m[2]]
        raise ParseError(f'line {line}: unknown escape \\{m[2]}')
    return ESCAPE.sub(one, body)


def tokenize(text: str) -> list[tuple[str, str, int]]:
    """(kind, value, line) with kind 'str', 'id' (an identifier, `.en` included) or 'p' (one punctuation mark)."""
    out: list[tuple[str, str, int]] = []
    i, line, n = 0, 1, len(text)
    while i < n:
        c = text[i]
        if c == '\n':
            line += 1
            i += 1
        elif c.isspace():
            i += 1
        elif text.startswith('//', i):
            while i < n and text[i] != '\n':
                i += 1
        elif c == '"':
            start, j = line, i + 1
            while j < n and text[j] != '"':
                if text[j] == '\\':
                    j += 1
                if text[j] == '\n':
                    raise ParseError(f'line {line}: a string runs over a line end')
                j += 1
            if j >= n:
                raise ParseError(f'line {start}: unterminated string')
            out.append(('str', unescape(text[i + 1:j], start), start))
            i = j + 1
        elif c.isalpha() or c in '_.':
            j = i + 1
            while j < n and (text[j].isalnum() or text[j] == '_'):
                j += 1
            out.append(('id', text[i:j], line))
            i = j
        else:
            out.append(('p', c, line))
            i += 1
    return out


class Reader:
    def __init__(self, tokens: list[tuple[str, str, int]]):
        self.t, self.i = tokens, 0

    def peek(self) -> tuple[str, str, int] | None:
        return self.t[self.i] if self.i < len(self.t) else None

    def take(self, kind: str, value: str | None = None) -> str:
        tok = self.peek()
        if tok is None or tok[0] != kind or (value is not None and tok[1] != value):
            raise ParseError(f'line {tok[2] if tok else "end"}: expected {value or kind}, found {tok[1] if tok else "end of file"}')
        self.i += 1
        return tok[1]

    def at(self, kind: str, value: str) -> bool:
        tok = self.peek()
        return tok is not None and tok[0] == kind and tok[1] == value

    def seek(self, *words: str) -> None:
        """Move behind the first run of tokens `words` (identifiers and punctuation) that follows."""
        while self.i < len(self.t):
            if all(self.i + k < len(self.t) and self.t[self.i + k][1] == w and self.t[self.i + k][0] != 'str'
                   for k, w in enumerate(words)):
                self.i += len(words)
                return
            self.i += 1
        raise ParseError(f'not found: {" ".join(words)}')

    def open_literal(self) -> None:
        """Move behind the `= [` of the declaration the reader stands in."""
        while not self.at('p', '='):
            self.i += 1
        self.take('p', '=')
        self.take('p', '[')


def put(table: dict, key: str, value, line: int) -> None:
    if key in table:
        raise ParseError(f'line {line}: duplicate key {key}')
    table[key] = value


def pairs(r: Reader) -> dict[str, tuple[str, str]]:
    """`"key": ("zh", "en"),` rows up to the closing bracket."""
    rows: dict[str, tuple[str, str]] = {}
    while not r.at('p', ']'):
        line = r.peek()[2]
        key = r.take('str')
        r.take('p', ':')
        r.take('p', '(')
        zh = r.take('str')
        r.take('p', ',')
        en = r.take('str')
        r.take('p', ')')
        put(rows, key, (zh, en), line)
        if not r.at('p', ']'):
            r.take('p', ',')
    r.take('p', ']')
    return rows


def overlay(r: Reader) -> dict[str, str]:
    """`"key": "text",` rows up to the closing bracket."""
    rows: dict[str, str] = {}
    while not r.at('p', ']'):
        line = r.peek()[2]
        key = r.take('str')
        r.take('p', ':')
        put(rows, key, r.take('str'), line)
        if not r.at('p', ']'):
            r.take('p', ',')
    r.take('p', ']')
    return rows


def stale(text: str) -> dict[str, dict[str, str]]:
    """`"key": [.en: "..", .zh: "..", ...]` rows of LocalizationStaleFrameworks.swift, as {language: {key: text}}."""
    r = Reader(tokenize(text))
    r.seek('staleFrameworks', ':')
    r.open_literal()
    out: dict[str, dict[str, str]] = {code: {} for code in LANGUAGES}
    while not r.at('p', ']'):
        key = r.take('str')
        r.take('p', ':')
        r.take('p', '[')
        while not r.at('p', ']'):
            code = r.take('id')[1:]
            if code not in LANGUAGES:
                raise ParseError(f'unknown language .{code} in {key}')
            r.take('p', ':')
            out[code][key] = r.take('str')
            if not r.at('p', ']'):
                r.take('p', ',')
        r.take('p', ']')
        if not r.at('p', ']'):
            r.take('p', ',')
    return out


def read_swift(localization: str, stale_text: str) -> dict[str, dict[str, str]]:
    r = Reader(tokenize(localization))
    r.seek('table', ':')
    r.open_literal()
    table = pairs(r)
    langs: dict[str, dict[str, str]] = {
        'zh': {k: v[0] for k, v in table.items()},
        'en': {k: v[1] for k, v in table.items()},
    }
    for code in ('sv', 'de', 'fr'):
        r.seek('static', 'let', code, ':')
        r.open_literal()
        langs[code] = overlay(r)
    for code, rows in stale(stale_text).items():
        for key, value in rows.items():
            if key in langs[code]:
                raise ParseError(f'{key} is in the main table and in the stale-frameworks table ({code})')
            langs[code][key] = value
    return langs


def write(langs: dict[str, dict[str, str]], out: Path) -> None:
    out.mkdir(parents=True, exist_ok=True)
    for code, rows in langs.items():
        body = {'_language': LANGUAGES[code]}
        body.update(sorted(rows.items()))
        (out / f'{code}.json').write_text(json.dumps(body, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
        print(f'{code}: {len(rows)} keys')


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    here = Path(__file__).resolve().parent.parent / 'frontend'
    ap.add_argument('--localization', default=here / 'Sources/NXCore/Localization.swift', type=Path)
    ap.add_argument('--stale', default=here / 'Sources/NXCore/LocalizationStaleFrameworks.swift', type=Path)
    ap.add_argument('--out', default=here / 'l10n', type=Path)
    args = ap.parse_args()
    langs = read_swift(args.localization.read_text(encoding='utf-8'), args.stale.read_text(encoding='utf-8'))
    write(langs, args.out)


if __name__ == '__main__':
    main()
