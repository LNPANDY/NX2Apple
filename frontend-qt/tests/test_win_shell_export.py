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
import zipfile
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

    def _write_ipa(self, path: Path, *bundles: str) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(path, 'w') as ipa:
            for bundle in bundles:
                ipa.writestr(f'Payload/{bundle}.app/Info.plist', b'fixture')
                ipa.writestr(f'Payload/{bundle}.app/{bundle}', b'fixture')

    def test_shared_mode_finds_the_shell_ipa(self) -> None:
        self._write_ipa(self.shared, 'DmShell')
        self.assertEqual(self._reveal('shared'), str(self.shared))

    def test_one_game_mode_finds_its_own_ipa(self) -> None:
        self._write_ipa(self.one, 'DmIOS')
        self.assertEqual(self._reveal('oneGame'), str(self.one))

    def test_a_switch_does_not_reveal_the_other_kind(self) -> None:
        # both files exist, and the last build was the shared one
        self._write_ipa(self.shared, 'DmShell')
        self._write_ipa(self.one, 'DmIOS')
        self.assertEqual(self._reveal('oneGame', last=str(self.shared)), str(self.one))
        self.assertEqual(self._reveal('shared', last=str(self.one)), str(self.shared))

    def test_a_stale_last_path_is_not_used_when_it_is_the_other_kind(self) -> None:
        # the selected kind's file is gone, and the last build named the other kind's IPA
        self._write_ipa(self.shared, 'DmShell')
        self.assertEqual(self._reveal('oneGame', last=str(self.shared)), '')

    def test_a_last_path_of_the_selected_kind_is_used(self) -> None:
        # a build that wrote somewhere else still belongs to the selected kind
        elsewhere = self.root / 'elsewhere' / 'ZeldaBreathOfTheWild.ipa'
        self._write_ipa(elsewhere, 'DmIOS')
        self.assertEqual(self._reveal('oneGame', last=str(elsewhere)), str(elsewhere))

    def test_the_library_record_is_the_last_resort(self) -> None:
        elsewhere = self.root / 'elsewhere' / 'ZeldaBreathOfTheWild.ipa'
        self._write_ipa(elsewhere, 'DmIOS')
        self.assertEqual(self._reveal('oneGame', library=str(elsewhere)), str(elsewhere))

    def test_shared_completion_cannot_reappear_through_the_library_fallback(self) -> None:
        # A real shared export records the same IPA in the model and the library.
        self._write_ipa(self.shared, 'DmShell')
        self.assertEqual(self._reveal('oneGame', last=str(self.shared), library=str(self.shared)), '')

    def test_shared_mode_rejects_one_game_outputs_after_output_directory_changes(self) -> None:
        self._write_ipa(self.one, 'DmIOS')
        for out_dir in (self.out, '', str(self.root / 'new-output')):
            with self.subTest(out_dir=out_dir):
                self.assertEqual(lib.reveal_ipa_path(
                    ipa_kind='shared', shell_cache=self.shell, out_dir=out_dir,
                    build_key=self.tid, last_ipa=str(self.one), library_ipa=str(self.one)), '')

    def test_one_game_fallback_survives_default_or_changed_output_directory(self) -> None:
        self._write_ipa(self.one, 'DmIOS')
        for out_dir in ('', str(self.root / 'new-output')):
            for source in ('last_ipa', 'library_ipa'):
                with self.subTest(out_dir=out_dir, source=source):
                    self.assertEqual(lib.reveal_ipa_path(
                        ipa_kind='oneGame', shell_cache=self.shell, out_dir=out_dir,
                        build_key=self.tid, **{source: str(self.one)}), str(self.one))

    def test_one_game_fallback_uses_the_package_kind_instead_of_its_filename(self) -> None:
        # A default output has a profile name. An explicit multi-title choice can differ
        # from the title ID parsed out of the input package's filename.
        for name in ('0100000000000002.ipa', 'ZeldaBreathOfTheWild.ipa'):
            artifact = self.root / name
            self._write_ipa(artifact, 'DmIOS')
            for source in ('last', 'library'):
                with self.subTest(name=name, source=source):
                    self.assertEqual(self._reveal('oneGame', **{source: str(artifact)}), str(artifact))

    def test_renamed_shared_outputs_cannot_be_used_as_one_game_fallbacks(self) -> None:
        artifact = self.root / f'{self.tid}.ipa'
        self._write_ipa(artifact, 'DmShell')
        self.assertEqual(self._reveal('oneGame', last=str(artifact), library=str(artifact)), '')

    def test_corrupt_unknown_and_ambiguous_archives_are_not_revealed(self) -> None:
        self.one.write_bytes(b'not a zip')
        self.assertEqual(self._reveal('oneGame', last=str(self.one)), '')
        for bundles in (('UnknownApp',), ('DmShell', 'DmIOS')):
            self._write_ipa(self.one, *bundles)
            for kind in ('shared', 'oneGame'):
                with self.subTest(bundles=bundles, kind=kind):
                    self.assertEqual(self._reveal(kind, last=str(self.one), library=str(self.one)), '')

    def test_replacing_an_ipa_rechecks_its_kind(self) -> None:
        self._write_ipa(self.one, 'DmIOS')
        self.assertEqual(self._reveal('oneGame'), str(self.one))
        self._write_ipa(self.one, 'DmShell')
        self.assertEqual(self._reveal('oneGame'), '')

    def test_unsupported_or_malformed_zip_headers_are_not_revealed(self) -> None:
        self._write_ipa(self.one, 'DmIOS')
        original = self.one.read_bytes()
        central = original.index(b'PK\x01\x02')
        unsupported = bytearray(original)
        unsupported[central + 6:central + 8] = (99).to_bytes(2, 'little')
        invalid_utf8 = bytearray(original)
        flags = int.from_bytes(invalid_utf8[central + 8:central + 10], 'little')
        invalid_utf8[central + 8:central + 10] = (flags | 0x800).to_bytes(2, 'little')
        invalid_utf8[central + 46] = 0xff
        for data in (unsupported, invalid_utf8):
            with self.subTest(header=data[central:central + 10]):
                self.one.write_bytes(data)
                self.assertEqual(self._reveal('oneGame', last=str(self.one)), '')

    def test_missing_files_and_directories_are_not_revealable_outputs(self) -> None:
        for path in (self.one, self.shared):
            for is_directory in (False, True):
                if is_directory:
                    path.mkdir()
                for kind in ('shared', 'oneGame'):
                    with self.subTest(path=path, is_directory=is_directory, kind=kind):
                        self.assertEqual(self._reveal(kind, last=str(path), library=str(path)), '')

    def test_a_one_game_named_alias_cannot_reveal_the_shared_ipa(self) -> None:
        self._write_ipa(self.shared, 'DmShell')
        try:
            self.one.symlink_to(self.shared)
        except OSError as error:
            self.skipTest(f'symlinks unavailable: {error}')
        self.assertEqual(self._reveal('oneGame', last=str(self.one), library=str(self.one)), '')

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
