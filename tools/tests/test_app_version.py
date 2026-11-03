"""`appVersion`: the one line that says which release the launcher is, and everything that reads it by path.

The line is `static let appVersion = "x.y.z"` in frontend/Sources/NXModel/AppUpdateStore.swift (LNPANDY/NX2Apple#387). The release
workflow, the engine sync workflow, tools/try-local and RELEASING.md read it there. When the line moves, a reader that still names the
old file breaks the release build, so this test finds every reader and checks that it names a file that holds the line."""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LINE = re.compile(r'static let appVersion = "(\d+(?:\.\d+)+)"')
READERS = [
    '.github/workflows/build-mac-app.yml',
    '.github/workflows/sync-upstream.yml',
    'tools/try-local',
    'tools/tests/test_try_local.py',
    'RELEASING.md',
]


def swift_paths(text):
    """The Swift files named on the lines that read appVersion."""
    return {path for line in text.splitlines() if 'appVersion' in line
            for path in re.findall(r'frontend/Sources/[A-Za-z0-9_/]+\.swift', line)}


class AppVersion(unittest.TestCase):
    def test_exactly_one_swift_file_holds_the_line(self):
        holders = [p for p in (ROOT / 'frontend/Sources').rglob('*.swift') if LINE.search(p.read_text())]
        self.assertEqual([p.relative_to(ROOT).as_posix() for p in holders], ['frontend/Sources/NXModel/AppUpdateStore.swift'])

    def test_every_reader_names_a_file_that_holds_it(self):
        for name in READERS:
            paths = swift_paths((ROOT / name).read_text())
            self.assertTrue(paths, f'{name} names no Swift file for appVersion')
            for rel in paths:
                self.assertTrue((ROOT / rel).is_file(), f'{name} reads appVersion in {rel}, which does not exist')
                self.assertRegex((ROOT / rel).read_text(), LINE, f'{name} reads appVersion in {rel}, which has no such line')

    def test_no_other_file_reads_it_by_path(self):
        # Anything that reads the version with sed or a regex is a reader: it must be in the list above, or it can break unseen.
        found = set()
        for base in ('.github', 'tools', 'frontend/tools', 'RELEASING.md', 'AGENTS.md', 'CONTRIBUTING.md'):
            path = ROOT / base
            files = [path] if path.is_file() else [p for p in path.rglob('*') if p.is_file()] if path.exists() else []
            for f in files:
                try:
                    text = f.read_text()
                except UnicodeDecodeError:
                    continue
                if 'static let appVersion' in text and f.name != Path(__file__).name:
                    found.add(f.relative_to(ROOT).as_posix())
        self.assertEqual(found - set(READERS), set(), 'a new reader of appVersion: add it to READERS in tools/tests/test_app_version.py')


if __name__ == '__main__':
    unittest.main()
