"""The script's early stops become hints (nspb_qt/build_failure.py, the SwiftUI app's BuildFailure.swift).

Pure Python, no Qt. frontend/Tests/Fixtures/build_failures.json holds the script's real message for every
pattern, shared with the Swift tests. A sync of scripts/ or dm/ that rewords a message fails here.

    python3 -m unittest frontend-qt/tests/test_build_failure_hints.py -v
"""
from __future__ import annotations

import errno
import importlib.util
import json
import os
import re
import sys
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'frontend-qt'))
os.environ.setdefault('QT_QPA_PLATFORM', 'offscreen')

from nspb_qt import build_failure as bf  # noqa: E402
from nspb_qt.i18n import Lang  # noqa: E402
from nspb_qt.localization import TABLE  # noqa: E402

FIXTURES = json.loads((ROOT / 'frontend/Tests/Fixtures/build_failures.json').read_text(encoding='utf-8'))
SWIFT = (ROOT / 'frontend/Sources/NSPortBuilder/BuildFailure.swift').read_text(encoding='utf-8')


def fixture(pattern_id: str) -> dict:
    return next(f for f in FIXTURES if f['id'] == pattern_id)


class Classifier(unittest.TestCase):
    def test_every_pattern_has_its_real_message_and_matches_it(self):
        for pid, kind, pattern in bf.TABLE:
            with self.subTest(pattern=pid):
                f = fixture(pid)
                self.assertEqual(f['kind'], kind)
                self.assertTrue(re.search(pattern, f['text']), f'{pid} no longer matches its message')
                self.assertEqual(bf.classify(f['text']).kind, kind)
        self.assertEqual({f['id'] for f in FIXTURES}, {p[0] for p in bf.TABLE}, 'a fixture without a pattern')

    def test_every_kind_is_reachable(self):
        self.assertEqual({k for _, k, _ in bf.TABLE}, set(bf.KINDS))

    def test_the_vendored_scripts_still_say_what_the_patterns_expect(self):
        """A sync that rewords a message must fail here, not turn a hint into the raw last line."""
        for f in FIXTURES:
            with self.subTest(pattern=f['id']):
                if f['source'] == 'errno':   # the system's own text, not the script's
                    self.assertEqual(os.strerror(errno.ENOSPC), f['fragment'])
                    continue
                there = f['fragment'] in (ROOT / f['source']).read_text(encoding='utf-8')
                if f.get('pending_sync'):
                    self.assertFalse(there, f"{f['id']} is in {f['source']} now: remove pending_sync ({f['pending_sync']}) from the fixture")
                else:
                    self.assertTrue(there, f"{f['id']}: {f['source']} no longer contains {f['fragment']!r}: update the pattern and the fixture")

    def test_the_failure_is_found_above_the_last_line(self):
        log = ("[3/9] extract\n[RED] the NSP is damaged: 2 files fail the NCA's hash check (x)\n"
               "---- last lines of /w/extract.log ----\n[RED] nx_extract exit code 3 (full output: /w/extract.log)\n")
        self.assertEqual(bf.classify(log).kind, bf.DAMAGED_NSP)

    def test_unknown_output_keeps_todays_behaviour(self):
        for log in ('', 'something odd happened', '[RED] the RomFS image failed',
                    '[RED] the NSP is damaged: 3 files written as read (--allow-damaged)'):   # the note of a build that went on
            self.assertEqual(bf.classify(log), bf.Failure(bf.UNKNOWN), log)

    def test_the_game_of_a_32_bit_program_is_named_when_the_message_names_it(self):
        f = fixture('arm32.program')
        self.assertEqual(bf.classify(f['text']).game, f['game'])
        self.assertIsNone(bf.classify('[RED] ? (0100ABCD00000000) is a 32-bit ARM program (main.npdm)').game)
        self.assertIsNone(bf.classify('[RED] the shader translator does not run (x)').game)

    def test_the_table_is_the_swift_one(self):
        rows = re.findall(r'\("([\w.]+)", \.(\w+), "((?:[^"\\]|\\.)*)"\)', SWIFT)
        self.assertEqual(len(rows), len(bf.TABLE))
        for (sid, skind, spattern), (pid, kind, pattern) in zip(rows, bf.TABLE):
            self.assertEqual((sid, skind), (pid, kind))
            self.assertEqual(spattern.replace('\\\\', '\\'), pattern, pid)

    def test_the_swift_overrides_are_these(self):
        flags = dict(re.findall(r'case \.(\w+): return "(--allow-[\w-]+)"', SWIFT))
        self.assertEqual(flags, bf.OVERRIDE_FLAGS)


class Rows(unittest.TestCase):
    """The rows of issue #141: what sets each one, and that the text names the action."""

    def test_each_row_appears_for_its_log_line(self):
        for pid, kind in (('keys.missing', bf.KEYS), ('games.several', bf.SEVERAL_GAMES), ('games.noTitleID', bf.NO_TITLE_ID),
                          ('disk.low', bf.DISK_FULL), ('disk.full', bf.DISK_FULL)):
            self.assertEqual(bf.classify(fixture(pid)['text']).kind, kind, pid)
        self.assertEqual(bf.classify('copying: no such file: x').kind, bf.UNKNOWN)

    def test_details(self):
        self.assertEqual(bf.classify(fixture('disk.low')['text']).detail, fixture('disk.low')['gb'])
        self.assertIsNone(bf.classify(fixture('disk.full')['text']).detail)
        log = 'skipping an empty file: a.nsp\n' + fixture('games.noTitleID')['text'] + '\n'
        self.assertEqual(bf.classify(log).detail, fixture('games.noTitleID')['folder'])

    def test_a_keys_file_that_cannot_be_read_is_known_from_the_file(self):
        log = '[RED] nx_extract exit code 1 (full output: /w/extract.log)'
        self.assertEqual(bf.classify(log, keys_readable=False).kind, bf.KEYS)
        self.assertEqual(bf.classify(log, keys_readable=True).kind, bf.UNKNOWN)
        self.assertEqual(bf.classify('[RED] the iOS SDK is not installed', keys_readable=False).kind, bf.IOS_SDK)

    def test_the_text_names_the_action(self):
        words = {bf.KEYS: ['Choose your prod.keys again'], bf.SEVERAL_GAMES: ['Move the other games'],
                 bf.NO_TITLE_ID: ['Rename the file', '0100XXXXXXXXXXXX', 'exact package', 'iCloud', 'Show folder'],
                 bf.DISK_FULL: ['Free up space', '_build']}
        for kind, ws in words.items():
            en = TABLE[f'fail.{kind}.next'][1]
            for w in ws:
                self.assertIn(w, en, kind)
        for key in ('fail.showFolder', 'fail.keys.button', 'fail.diskFull.whatNeeds'):
            self.assertIn(key, TABLE)
            self.assertTrue(TABLE[key][2] and TABLE[key][2] != TABLE[key][1], key)   # Swedish present
            self.assertTrue(TABLE[key][3] and TABLE[key][3] != TABLE[key][1], key)   # German present

    def test_a_missing_zbic_package_is_its_own_row(self):
        log = '[3/9] extract\n' + fixture('zbic.missing')['text'] + '\n'
        self.assertEqual(bf.classify(log).kind, bf.ZBIC)
        self.assertEqual(bf.classify('[RED] the zbic package decoded it').kind, bf.UNKNOWN)
        self.assertIn('pip install zbic', TABLE['fail.zbic.next'][1])
        self.assertIn('zbic', TABLE['fail.zbic.button'][1])

    def test_the_python_probe_and_the_venv_install_name_zbic(self):
        pkg = ROOT / 'frontend-qt/nspb_qt'
        self.assertIn('import lz4, capstone, fontTools, zbic', (pkg / 'platform_util.py').read_text(encoding='utf-8'))
        model = (pkg / 'model.py').read_text(encoding='utf-8')
        self.assertIn("pkgs = ['lz4', 'capstone', 'fonttools', 'zbic', 'nsz']", model)
        self.assertIn("'zbic', 'backports.zstd', 'nsz'", model)

    @unittest.skipIf(importlib.util.find_spec('PySide6') is None, 'PySide6 is not installed')
    def test_show_folder_opens_the_game_folder_and_for_a_full_disk_the_build_folder(self):
        import tempfile
        from nspb_qt.model import Model
        m = Model()
        m.lang = Lang.EN   # these assertions read English whatever the device language is
        with tempfile.TemporaryDirectory() as d:
            m.base_path = str(Path(d, 'game.nsp'))
            self.assertEqual(m.failure_folder(bf.Failure(bf.NO_TITLE_ID, detail='/x')), d)
            self.assertEqual(m.failure_folder(bf.Failure(bf.DISK_FULL)), d)
            Path(d, '0100F2C0115B6000_build').mkdir()
            self.assertEqual(m.failure_folder(bf.Failure(bf.DISK_FULL)), str(Path(d, '0100F2C0115B6000_build')))
        m.base_path = ''
        self.assertEqual(m.failure_folder(bf.Failure(bf.NO_TITLE_ID, detail='/x/y')), '/x/y')
        self.assertIn('40 GB', m.failure_what(bf.Failure(bf.DISK_FULL, detail='40')))


class Override(unittest.TestCase):
    BASE = ['-m', 'x', '/in', '-k', '/k', '--progress', 'lines']

    def test_the_build_arguments_get_exactly_one_allow_flag(self):
        self.assertEqual(bf.arguments(self.BASE, None), self.BASE)
        for kind, flag in bf.OVERRIDE_FLAGS.items():
            args = bf.arguments(self.BASE, flag)
            self.assertEqual([a for a in args if a.startswith('--allow-')], [flag], kind)
            self.assertEqual(args[:-1], self.BASE)
        two = bf.arguments(self.BASE + ['--allow-damaged'], '--allow-other-metal')
        self.assertEqual([a for a in two if a.startswith('--allow-')], ['--allow-other-metal'])
        self.assertEqual(bf.arguments(self.BASE, '--platform'), self.BASE, 'not an override')

    def test_nothing_is_armed_until_the_confirmation(self):
        s = bf.OverrideState()
        self.assertTrue(s.request(bf.Failure(bf.OTHER_METAL)))
        self.assertIsNone(s.take())
        s.cancel()
        self.assertFalse(s.confirm())
        self.assertIsNone(s.take())

    def test_a_confirmed_override_serves_one_build_only(self):
        s = bf.OverrideState()
        s.request(bf.Failure(bf.DAMAGED_NSP))
        self.assertTrue(s.confirm())
        self.assertEqual(s.take(), '--allow-damaged')
        self.assertIsNone(s.take(), 'the next build runs without it')

    def test_a_stop_without_an_override_cannot_be_built_anyway(self):
        s = bf.OverrideState()
        for kind in (bf.ROSETTA, bf.TRANSLATOR, bf.IOS_SDK, bf.CLT_SELECTED, bf.A32_PROGRAM, bf.UNKNOWN):
            self.assertFalse(s.request(bf.Failure(kind)), kind)
        self.assertFalse(s.request(None))
        self.assertIsNone(s.confirming)


class Strings(unittest.TestCase):
    def test_every_hint_is_in_both_languages_without_semicolons(self):
        keys = ['fail.section', 'fail.buildAnyway', 'fail.confirm.title', 'fail.confirm.go', 'fail.confirm.cancel',
                'fail.override.note', 'fail.a32Program.whatNamed', 'fail.translator.button', 'fail.iosSDK.button',
                'fail.cltSelected.button', 'dep.metal.other', 'dep.fix.metalPin']
        for kind in bf.KINDS:
            keys += [f'fail.{kind}.what', f'fail.{kind}.next']
            if kind in bf.OVERRIDE_FLAGS:
                keys.append(f'fail.{kind}.risk')
        for key in keys:
            with self.subTest(key=key):
                self.assertIn(key, TABLE)
                row = TABLE[key]
                zh, en = row[0], row[1]   # the table carries more columns (Swedish, German)
                self.assertTrue(zh and en)
                for text in (zh, en):
                    self.assertNotIn(';', text)
                    self.assertNotIn('；', text)
                self.assertNotEqual(zh, en)

    def test_the_risk_text_states_the_risk_and_that_it_is_one_build(self):
        for kind in bf.OVERRIDE_FLAGS:
            en = TABLE[f'fail.{kind}.risk'][1]
            self.assertIn('untested', en)
            self.assertIn('one build', en)

    def test_the_hints_say_what_the_task_asks(self):
        self.assertIn('Xcode 27.1 (macOS 26.6 or later)', TABLE['fail.otherMetal.next'][1])
        self.assertIn("32-bit and can't run on Apple silicon", TABLE['fail.a32Program.what'][1])


try:
    from PySide6.QtCore import QEvent
    from PySide6.QtWidgets import QApplication, QMessageBox
except ImportError:          # the packaged app always has it; a bare python3 may not
    QApplication = None


@unittest.skipIf(QApplication is None, 'PySide6 is not installed')
class Window(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app = QApplication.instance() or QApplication([])

    def _window(self, failure):
        from nspb_qt.model import Model
        from nspb_qt.ui import MainWindow
        m = Model()
        m.lang = Lang.EN   # these assertions read English whatever the device language is
        w = MainWindow(m)
        # A window left alive is destroyed by PySide after the QApplication at interpreter exit,
        # which segfaults. Delete it (and the model) while the app is still there.
        self.addCleanup(self._delete, m, w)
        w.show()
        m.failure = failure
        w._show_failure()
        return m, w

    def _delete(self, m, w):
        w.close()
        w.deleteLater()
        m.deleteLater()
        self.app.sendPostedEvents(None, QEvent.DeferredDelete)
        self.app.processEvents()

    def test_a_known_stop_shows_its_hint_and_the_buttons_it_has(self):
        m, w = self._window(bf.Failure(bf.OTHER_METAL))
        self.assertFalse(w.failure_box.isHidden())
        self.assertFalse(w.failure_anyway_btn.isHidden())
        self.assertTrue(w.failure_fix_btn.isHidden())
        m, w = self._window(bf.Failure(bf.TRANSLATOR))
        self.assertFalse(w.failure_fix_btn.isHidden())
        self.assertTrue(w.failure_anyway_btn.isHidden())
        m, w = self._window(bf.Failure(bf.ROSETTA))
        self.assertTrue(w.failure_fix_btn.isHidden() and w.failure_anyway_btn.isHidden())
        m, w = self._window(None)
        self.assertTrue(w.failure_box.isHidden())

    def test_build_anyway_builds_only_after_the_player_agrees(self):
        m, w = self._window(bf.Failure(bf.DAMAGED_NSP))
        with mock.patch.object(w, '_build_clicked') as build, \
                mock.patch.object(QMessageBox, 'question', return_value=QMessageBox.Cancel):
            w._build_anyway()
            build.assert_not_called()
            self.assertIsNone(m.override.take())
        with mock.patch.object(w, '_build_clicked') as build, \
                mock.patch.object(QMessageBox, 'question', return_value=QMessageBox.Yes) as ask:
            w._build_anyway()
            build.assert_called_once()
            self.assertIn('untested', ask.call_args.args[2])
            self.assertEqual(m.override.take(), '--allow-damaged')


if __name__ == '__main__':
    unittest.main()
