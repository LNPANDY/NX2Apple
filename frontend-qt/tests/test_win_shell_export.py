"""The two Windows shared-shell defects that broke every shared build, and the reveal path.

`REQUIRED_DYLIB_SYMBOLS` used to list names the engine never defines, so `check_dylib()` rejected
the framework `link_framework()` had just linked and `[7/8] game framework` failed on every game.
The reveal button used to ask `Model.ipa_path` first, which names whichever kind built last, so
after switching between shared and one-game it opened the other mode's IPA.

Both are pure-Python and run without PySide6: the symbol names are read out of the engine's own
sources, and `library.reveal_ipa_path` takes its state as arguments.
"""
from __future__ import annotations

import os
import re
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
QT = HERE.parent
ROOT = QT.parent
sys.path.insert(0, str(QT))

from nspb_qt import library as lib  # noqa: E402
from nspb_qt.win import build_app  # noqa: E402


# ---------------------------------------------------------------- the framework's exports

def _engine_ios_dir() -> Path:
    return ROOT / 'engine' / 'dm' / 'ios'


def _engine_sources() -> list[Path]:
    """The engine's own sources that define or declare the framework's exported symbols."""
    engine = ROOT / 'engine' / 'dm'
    out: list[Path] = []
    for sub in ('ios', 'host'):
        d = engine / sub
        if d.is_dir():
            out += sorted(d.rglob('*.m')) + sorted(d.rglob('*.c')) + sorted(d.rglob('*.h'))
    return out


def _defined_in(path: Path, name: str) -> bool:
    """Whether `path` defines or declares `name` (not merely mentions it).

    A definition or declaration puts the identifier right before its parameter list, its
    initialiser, its array brackets or the end of the statement. A dlsym() call, a comment and a
    macro that happens to spell the name do not.
    """
    if not path.is_file():
        return False
    pat = re.compile(r'\b' + re.escape(name) + r'\s*[\(\[=;{]')
    for line in path.read_text(encoding='utf-8', errors='replace').splitlines():
        stripped = line.strip()
        if stripped.startswith('//') or stripped.startswith('#') or stripped.startswith('*'):
            continue
        if 'dlsym' in stripped:
            continue
        if pat.search(stripped):
            return True
    return False


class RequiredDylibSymbolsTest(unittest.TestCase):
    """Every symbol `check_dylib()` demands must be one the engine actually defines, under the
    exact name the linker exports (a leading underscore on Mach-O)."""

    def test_the_list_is_not_empty(self) -> None:
        self.assertTrue(build_app.REQUIRED_DYLIB_SYMBOLS)

    def test_every_symbol_is_defined_by_the_engine(self) -> None:
        sources = _engine_sources()
        if not sources:
            self.skipTest('engine/ is missing: run python3 tools/engine.py sync')
        missing = []
        for sym in build_app.REQUIRED_DYLIB_SYMBOLS:
            name = sym[1:] if sym.startswith('_') else sym
            if not any(_defined_in(p, name) for p in sources):
                missing.append(sym)
        self.assertEqual(missing, [], f'the engine defines none of these: {missing}')

    def test_the_marker_is_the_name_framework_bootstrap_looks_for(self) -> None:
        header = _engine_ios_dir() / 'Sources' / 'FrameworkBootstrap.h'
        if not header.is_file():
            self.skipTest('engine/ is missing: run python3 tools/engine.py sync')
        text = header.read_text(encoding='utf-8', errors='replace')
        self.assertIn('#define DM_FRAMEWORK_MARKER "dmgame_image_marker"', text)
        self.assertIn('_dmgame_image_marker', build_app.REQUIRED_DYLIB_SYMBOLS)

    def test_the_glue_symbols_the_shell_dlsyms_are_all_required(self) -> None:
        shell_main = _engine_ios_dir() / 'Shell' / 'ShellMain.m'
        if not shell_main.is_file():
            self.skipTest('engine/ is missing: run python3 tools/engine.py sync')
        text = shell_main.read_text(encoding='utf-8', errors='replace')
        for name in ('dm_glue_version', 'dm_glue_start_game', 'dm_glue_present_game',
                     'dm_glue_focus_event'):
            if f'"{name}"' not in text:
                continue        # the shell stopped asking for it; nothing to require
            self.assertIn('_' + name, build_app.REQUIRED_DYLIB_SYMBOLS,
                          f'ShellMain.m dlsyms {name}, so a framework must export it')


# ---------------------------------------------------------------- the reveal button's file

class RevealIpaPathTest(unittest.TestCase):
    """`library.reveal_ipa_path` answers for the selected kind, not for the last build."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.shell = str(self.root / 'shell')
        self.out = str(self.root / 'out')
        (self.root / 'shell' / 'export').mkdir(parents=True)
        Path(self.out).mkdir(parents=True)
        self.tid = '010063301BD50000'
        self.shared = Path(self.shell) / 'export' / 'NX2Apple.ipa'
        self.one = Path(self.out) / f'{self.tid}.ipa'

    def _reveal(self, kind: str, last: str = '', library: str = '') -> str:
        return lib.reveal_ipa_path(ipa_kind=kind, shell_cache=self.shell, out_dir=self.out,
                                   build_key=self.tid, last_ipa=last, library_ipa=library)

    def test_shared_mode_finds_the_shell_ipa(self) -> None:
        self.shared.write_bytes(b'zip')
        self.assertEqual(self._reveal('shared'), str(self.shared))

    def test_one_game_mode_finds_its_own_ipa(self) -> None:
        self.one.write_bytes(b'zip')
        self.assertEqual(self._reveal('oneGame'), str(self.one))

    def test_a_switch_does_not_reveal_the_other_kind(self) -> None:
        # both files exist, and the last build was the shared one
        self.shared.write_bytes(b'zip')
        self.one.write_bytes(b'zip')
        self.assertEqual(self._reveal('oneGame', last=str(self.shared)), str(self.one))
        self.assertEqual(self._reveal('shared', last=str(self.one)), str(self.shared))

    def test_a_stale_last_path_is_not_used_when_it_is_the_other_kind(self) -> None:
        # the selected kind's file is gone, and the last build named the other kind's IPA
        self.shared.write_bytes(b'zip')
        self.assertEqual(self._reveal('oneGame', last=str(self.shared)), '')

    def test_a_last_path_of_the_selected_kind_is_used(self) -> None:
        # a build that wrote somewhere else still belongs to the selected kind
        elsewhere = self.root / 'elsewhere.ipa'
        elsewhere.write_bytes(b'zip')
        self.assertEqual(self._reveal('oneGame', last=str(elsewhere)), str(elsewhere))

    def test_the_library_record_is_the_last_resort(self) -> None:
        self.assertEqual(self._reveal('shared', library=str(self.root / 'lib.ipa')),
                         str(self.root / 'lib.ipa'))

    def test_nothing_known_returns_empty(self) -> None:
        self.assertEqual(self._reveal('shared'), '')

    def test_the_paths_match_what_the_export_writes(self) -> None:
        from nspb_qt.win import shell_export as se
        self.assertEqual(os.path.normcase(lib.shell_ipa_path(self.shell)),
                         os.path.normcase(str(se.ipa_path(self.shell))))
        self.assertEqual(os.path.normcase(lib.one_game_ipa_path(self.out, self.tid)),
                         os.path.normcase(str(self.one)))


if __name__ == '__main__':
    unittest.main()
