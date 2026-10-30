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
OVERLAY_ENTRY = re.compile(r'"([^"]+)":\s*"((?:[^"\\]|\\.)*)"')


def overlay(text: str, name: str) -> dict[str, str]:
    """The `static let <name>: [String: String]` overlay of the Swift table (Swedish, German)."""
    match = re.search(r'static let ' + name + r': \[String: String\] = \[(.*?)\n    \]', text, re.S)
    return dict(OVERLAY_ENTRY.findall(match.group(1))) if match else {}


def unescape(s: str) -> str:
    """A Swift string literal's body as text (unicode, quote and backslash, \\n and \\t escapes)."""
    return re.sub(r'\\(u\{([0-9a-fA-F]+)\}|.)',
                  lambda m: chr(int(m[2], 16)) if m[2] else {'n': '\n', 't': '\t'}.get(m[1], m[1]), s)


def main() -> None:
    text = SWIFT.read_text(encoding='utf-8')
    rows = PAIR.findall(text)
    if not rows:
        raise SystemExit(f'no strings found in {SWIFT}')
    swedish = overlay(text, 'sv')
    german = overlay(text, 'de')
    lines = [
        '"""Localised strings, generated from the SwiftUI app\'s Localization.swift.',
        '',
        'Do not edit by hand: run frontend-qt/gen_localization.py after changing the Swift table,',
        'so both front ends say the same thing."""',
        'from __future__ import annotations',
        '',
        'from .i18n import Lang',
        '',
        '# key: (Chinese, English, Swedish, German). Swedish and German fall back to English.',
        'TABLE: dict[str, tuple[str, str, str, str]] = {',
    ]
    for key, zh, en in rows:
        zh, en = unescape(zh), unescape(en)
        sv = unescape(swedish[key]) if key in swedish else en
        de = unescape(german[key]) if key in german else en
        lines.append(f'    {key!r}: ({zh!r}, {en!r}, {sv!r}, {de!r}),')
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
        '    zh, en, sv, de = TABLE.get(key, (key, key, key, key))',
        '    s = {Lang.ZH: zh, Lang.EN: en, Lang.SV: sv, Lang.DE: de}[lang]',
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
