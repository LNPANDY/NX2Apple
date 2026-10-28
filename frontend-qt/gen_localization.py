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
SWEDISH = re.compile(r'"([^"]+)":\s*"((?:[^"\\]|\\.)*)"')


def main() -> None:
    text = SWIFT.read_text(encoding='utf-8')
    rows = PAIR.findall(text)
    if not rows:
        raise SystemExit(f'no strings found in {SWIFT}')
    lines = [
        '"""Localised strings, generated from the SwiftUI app\'s Localization.swift.',
        '',
        'Do not edit by hand: run frontend-qt/gen_localization.py after changing the Swift table,',
        'so both front ends say the same thing."""',
        'from __future__ import annotations',
        '',
        'from .i18n import Lang',
        '',
        '# key: (Chinese, English, Swedish fallback)',
        'TABLE: dict[str, tuple[str, str, str]] = {',
    ]
    overlay_match = re.search(r'static let sv: \[String: String\] = \[(.*?)\n    \]', text, re.S)
    swedish = dict(SWEDISH.findall(overlay_match.group(1))) if overlay_match else {}
    for key, zh, en in rows:
        # Swift Unicode escapes keep the shared table ASCII without losing translations.
        zh = re.sub(r'\\u\{([0-9a-fA-F]+)\}', lambda m: chr(int(m[1], 16)), zh)
        en = re.sub(r'\\u\{([0-9a-fA-F]+)\}', lambda m: chr(int(m[1], 16)), en)
        zh = zh.replace('\\"', '"').replace('\\n', '\\n')
        en = en.replace('\\"', '"').replace('\\n', '\\n')
        sv = swedish.get(key, en).replace('\\"', '"').replace('\\n', '\\n')
        lines.append(f'    {key!r}: ({zh!r}, {en!r}, {sv!r}),')
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
        '    zh, en, sv = TABLE.get(key, (key, key, key))',
        '    s = zh if lang is Lang.ZH else sv if lang is Lang.SV else en',
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
