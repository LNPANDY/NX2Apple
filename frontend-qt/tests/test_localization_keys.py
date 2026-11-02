"""The keys the code uses and the keys en.json has have to be the same set (LNPANDY/NX2Apple#388).

1. A key that code names in a lookup (`t('key')`, `self.m.t('key')`, `L10n.string("key", ...)`) is in en.json.
2. A key that code builds at run time (a prefix and a variable) starts with an entry of `dynamicKeys` in
   frontend/Tests/l10n-key-rules.json, and every entry has a key in en.json and a place in the sources that builds it.
3. A key of en.json that no source mentions, literally or under a `dynamicKeys` or `catalogKeys` entry, fails, unless it is in
   `unusedAllowed`. `catalogKeys` are the iOS shell's texts (`ios.*`): tools/l10n_shell_catalogs.py writes them into the shell's
   string catalogs, and tools/tests/test_l10n_shell_catalogs.py checks that the catalogs are current.

The sources are both front ends, so a key only the Windows launcher or only the Mac launcher uses is used. The Mac launcher
runs the same rules in frontend/Tests/NXCoreTests/LocalizationKeyTests.swift.
"""
from __future__ import annotations

import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
EN = ROOT / 'frontend' / 'l10n' / 'en.json'
RULES = ROOT / 'frontend' / 'Tests' / 'l10n-key-rules.json'
SOURCES = (ROOT / 'frontend-qt' / 'nspb_qt', ROOT / 'frontend' / 'Sources')

# A string literal that is a key lookup. Python: t('k'), .t("k"), t(f'k.{x}'), t('k.' + x). Swift: t("k"), L10n.string("k", ...),
# L10n.table["k"], t("k.\(x)"), t("k." + x). Group 2 is the literal's text, group 3 what follows it.
CALLS = (
    re.compile(r'''(?<![A-Za-z0-9_])t\(\s*f?(['"])((?:(?!\1).)*)\1(\s*[+%])?'''),
    re.compile(r'''L10n\.string\(\s*()"((?:[^"\\]|\\.)*)"()'''),
    re.compile(r'''L10n\.table\[\s*()"((?:[^"\\]|\\.)*)"()'''),
)
LITERAL = re.compile(r'''["']([A-Za-z0-9_][A-Za-z0-9_.\-]*)["']''')
DYNAMIC = re.compile(r'\\\(|\{')   # Swift interpolation, Python f-string field
# win/build_app.py has its own t() that writes a log line, it does not look up a text
NOT_LOOKUPS = ('build_app.py',)


def source_files():
    for base in SOURCES:
        for path in sorted(base.rglob('*')):
            if path.suffix in ('.py', '.swift') and path.is_file():
                yield path


class LocalizationKeys(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        en = json.loads(EN.read_text(encoding='utf-8'))
        cls.keys = {k for k in en if k != '_language'}
        rules = json.loads(RULES.read_text(encoding='utf-8'))
        cls.dynamic = [(d['prefix'], d['suffix']) for d in rules['dynamicKeys']]
        cls.catalog = [c['prefix'] for c in rules['catalogKeys']]
        cls.allowed = {a['key'] for a in rules['unusedAllowed']}
        cls.rules = rules
        cls.text = {p: p.read_text(encoding='utf-8') for p in source_files()}
        cls.literals: set[str] = set()
        cls.looked_up: list[tuple[Path, str, bool]] = []   # file, the literal's text, whether the key is built at run time
        for path, text in cls.text.items():
            cls.literals.update(LITERAL.findall(text))
            if path.name in NOT_LOOKUPS:
                continue
            for call in CALLS:
                for m in call.finditer(text):
                    body, tail = m.group(2), m.group(3) or ''
                    built = bool(DYNAMIC.search(body)) or tail.strip() in ('+', '%')
                    cls.looked_up.append((path, DYNAMIC.split(body)[0] if built else body, built))

    def covered(self, key: str) -> bool:
        return (any(key.startswith(p) and key.endswith(s) and len(key) >= len(p) + len(s) for p, s in self.dynamic)
                or any(key.startswith(p) for p in self.catalog))

    def test_the_sources_were_found(self):
        self.assertTrue(any(p.suffix == '.py' for p in self.text), 'no Python sources')
        self.assertTrue(any(p.suffix == '.swift' for p in self.text), 'no Swift sources')
        self.assertGreater(len(self.looked_up), 100, 'the lookup patterns found almost nothing')

    def test_every_literal_key_in_a_lookup_is_in_english(self):
        missing = sorted({f'{p.relative_to(ROOT)}: {k}' for p, k, built in self.looked_up if not built and k not in self.keys})
        self.assertEqual(missing, [], 'keys that a lookup names and en.json lacks')

    def test_every_built_key_starts_with_a_declared_prefix(self):
        undeclared = sorted({f'{p.relative_to(ROOT)}: {k}' for p, k, built in self.looked_up
                             if built and not any(k.startswith(prefix) or prefix.startswith(k) for prefix, _ in self.dynamic)})
        self.assertEqual(undeclared, [], 'keys built at run time whose prefix is not in dynamicKeys of l10n-key-rules.json')

    def test_every_declared_prefix_has_keys_and_is_built_somewhere(self):
        for prefix, suffix in self.dynamic:
            matching = [k for k in self.keys if k.startswith(prefix) and k.endswith(suffix) and len(k) >= len(prefix) + len(suffix)]
            self.assertTrue(matching, f'dynamicKeys {prefix!r} {suffix!r} has no key in en.json')
            # Built in a lookup or anywhere else (a Dep's name, a labelKey), so the check is that a string literal starts with it
            self.assertTrue(any(f'"{prefix}' in t or f"'{prefix}" in t for t in self.text.values()), f'no source has a string that starts with {prefix!r}')

    def test_every_catalog_prefix_has_keys_and_a_reason(self):
        for entry in self.rules['catalogKeys']:
            self.assertTrue(any(k.startswith(entry['prefix']) for k in self.keys), f'catalogKeys {entry["prefix"]!r} has no key in en.json')
            self.assertTrue(entry.get('why', '').strip(), f'catalogKeys {entry["prefix"]!r} has no reason')

    def test_no_key_is_unused(self):
        unused = sorted(k for k in self.keys if k not in self.literals and not self.covered(k) and k not in self.allowed)
        self.assertEqual(unused, [], 'keys in en.json that no source uses (remove them from every language file, or explain them in unusedAllowed)')

    def test_the_unused_allowlist_has_no_stale_entries(self):
        for entry in self.rules['unusedAllowed']:
            self.assertTrue(entry.get('why', '').strip(), f'{entry.get("key")} has no reason')
            self.assertIn(entry['key'], self.keys, f'{entry["key"]} is not in en.json any more')
            self.assertNotIn(entry['key'], self.literals, f'{entry["key"]} is used, so it needs no entry')
            self.assertFalse(self.covered(entry['key']), f'{entry["key"]} is covered by a dynamicKeys entry')


if __name__ == '__main__':
    unittest.main()
