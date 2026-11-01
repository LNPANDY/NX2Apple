"""Generate localization.py from the SwiftUI app's Localization.swift.

The two front ends show the same strings, so the table has one source: the Swift file. Running
this after editing it keeps the Qt app in step instead of letting the two drift.
    python3 frontend-qt/gen_localization.py
"""
from __future__ import annotations

import re
from pathlib import Path

HERE = Path(__file__).resolve().parent
SWIFT = HERE.parent / 'frontend' / 'Sources' / 'NSPortBuilder' / 'Localization.swift'
OUT = HERE / 'nspb_qt' / 'localization.py'

PAIR = re.compile(r'"([^"]+)":\s*\(\s*"((?:[^"\\]|\\.)*)"\s*,\s*"((?:[^"\\]|\\.)*)"\s*\)', re.S)
OVERLAY = re.compile(r'"([^"]+)":\s*"((?:[^"\\]|\\.)*)"')
ESCAPE = re.compile(r'\\u\{([0-9a-fA-F]+)\}|\\(.)')
SIMPLE = {'n': '\n', 't': '\t', '"': '"', '\\': '\\'}


def unescape(s: str) -> str:
    """A Swift string literal's body as the text it means: \\u{...}, \\n, \\t, \\\" and \\\\, in one pass
    so an escaped backslash is never read as the start of another escape."""
    return ESCAPE.sub(lambda m: chr(int(m[1], 16)) if m[1] else SIMPLE.get(m[2], m[0]), s)


def overlay(text: str, name: str) -> dict[str, str]:
    """One language overlay (`static let <name>: [String: String]`), unescaped."""
    match = re.search(rf'static let {name}: \[String: String\] = \[(.*?)\n    \]', text, re.S)
    return {k: unescape(v) for k, v in OVERLAY.findall(match.group(1))} if match else {}


def main() -> None:
    text = SWIFT.read_text(encoding='utf-8')
    rows = PAIR.findall(text)
    if not rows:
        raise SystemExit(f'no strings found in {SWIFT}')
    swedish = overlay(text, 'sv')
    german = overlay(text, 'de')
    french = overlay(text, 'fr')
    lines = [
        '"""Localised strings, generated from the SwiftUI app\'s Localization.swift.',
        '',
        'Do not edit by hand: run frontend-qt/gen_localization.py after changing the Swift table,',
        'so both front ends say the same thing."""',
        'from __future__ import annotations',
        '',
        'from .i18n import Lang',
        '',
        '# key: (Chinese, English, Swedish, German, French); a missing overlay entry is the English text',
        'TABLE: dict[str, tuple[str, str, str, str, str]] = {',
    ]
    for key, zh, en in rows:
        # Swift Unicode escapes keep the shared table ASCII without losing translations.
        zh, en = unescape(zh), unescape(en)
        sv, de, fr = swedish.get(key, en), german.get(key, en), french.get(key, en)
        lines.append(f'    {key!r}: ({zh!r}, {en!r}, {sv!r}, {de!r}, {fr!r}),')
    lines += [
        '}',
        '',
        '',
        'def t(key: str, lang: Lang, *args: object) -> str:',
        '    """The string for `key` in `lang`, with %@-style arguments filled in.',
        '',
        '    The Swift table uses %@ as its placeholder (String(format:)); the Qt side uses',
        '    Python\'s %s, so the placeholder is translated here rather than in every call site.',
        '    """',
        '    zh, en, sv, de, fr = TABLE.get(key, (key, key, key, key, key))',
        '    s = {Lang.ZH: zh, Lang.EN: en, Lang.SV: sv, Lang.DE: de, Lang.FR: fr}[lang]',
        '    if not args:',
        '        return s',
        '    py = s.replace("%@", "%s")   # %d is the same in both; %@ is Swift-only',
        '    try:',
        '        return py % args',
        '    except (TypeError, ValueError):',
        '        return s',
        '',
    ]
    OUT.write_text('\n'.join(lines), encoding='utf-8')
    print(f'{len(rows)} strings -> {OUT.relative_to(HERE)}')


if __name__ == '__main__':
    main()
