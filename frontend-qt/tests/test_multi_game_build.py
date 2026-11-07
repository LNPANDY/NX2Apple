"""Qt launcher retries a multi-game package with the selected application identity (#376)."""
from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'frontend-qt'))
os.environ.setdefault('QT_QPA_PLATFORM', 'offscreen')

from nspb_qt import build_failure as bf
from nspb_qt import library

try:
    from PySide6.QtCore import QEvent
    from PySide6.QtWidgets import QApplication, QPushButton
    from nspb_qt import model
    from nspb_qt.ui import MainWindow
except ImportError:
    QApplication = None

FIXTURES = json.loads((ROOT / 'frontend/Tests/Fixtures/build_failures.json').read_text())
DIAGNOSTIC = next(f['text'] for f in FIXTURES if f['id'] == 'games.several')
FIRST, SECOND = '0100000000010000', '01006F8002326000'


class MultiGameStop(unittest.TestCase):
    def test_only_complete_base_ids_from_the_selection_diagnostic(self):
        self.assertEqual(bf.classify('update 01006F8002326800\n' + DIAGNOSTIC).title_ids, (FIRST, SECOND))
        for text in (DIAGNOSTIC.replace('--title-id', 'another folder'), DIAGNOSTIC.replace(SECOND, FIRST),
                     DIAGNOSTIC.replace(SECOND, SECOND[:-3] + '800'), DIAGNOSTIC.replace(', ' + SECOND, ''),
                     DIAGNOSTIC.replace(SECOND, 'broken'), 'more than one game in the folder'):
            with self.subTest(text=text):
                self.assertEqual(bf.classify(text).title_ids, ())


class LibraryAppPath(unittest.TestCase):
    def test_reload_drops_deleted_mac_app_but_keeps_the_game_and_its_inputs(self):
        with tempfile.TemporaryDirectory() as temp:
            state = Path(temp) / 'state'
            app = Path(temp) / 'Game.app'
            app.mkdir()
            games = library.GameLibrary(state)
            games.upsert(library.LibraryGame(SECOND, 'Game', app_path=str(app)))
            inputs = {'base': ['Cartridge.xci']}
            games.upsert(library.LibraryGame(SECOND, 'Game', inputs=inputs))
            self.assertEqual(library.GameLibrary(state).selected.app_path, str(app))
            app.rmdir()
            reloaded = library.GameLibrary(state).selected
            self.assertEqual(reloaded.app_path, '')
            self.assertEqual(reloaded.title_id, SECOND)
            self.assertEqual(reloaded.inputs, inputs)


@unittest.skipIf(QApplication is None, 'PySide6 is not installed')
class MultiGameBuild(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app = QApplication.instance() or QApplication([])

    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.engine = self.root / 'engine'
        (self.engine / 'scripts').mkdir(parents=True)
        (self.engine / 'scripts/build_ipa_from_nsp.py').write_text("p.add_argument('--work-dir')\n")
        (self.engine / 'dm/tools/nx_extract').mkdir(parents=True)
        (self.engine / 'dm/tools/nx_extract/Program.cs').touch()
        with mock.patch.object(library, 'default_state_dir', return_value=self.root / 'state'), \
                mock.patch.object(Path, 'home', return_value=self.root), \
                mock.patch.object(model.pu, 'find_python', return_value=(sys.executable, True, '3.13')), \
                mock.patch.object(model.pu, 'find_dotnet', return_value=('', False)):
            self.m = model.Model()
        self.m.repo_path = str(self.engine)
        self.m.base_path = str(self.root / f'Cartridge [{FIRST}].xci')
        self.m.keys_path = str(self.root / 'prod.keys')
        Path(self.m.keys_path).touch()
        self.m.artwork.request_banner_async = mock.Mock()
        self.commands = []

    def run_process(self, diagnostic='', title_id=None):
        m = self.m

        def spawn(cmd, **kwargs):
            self.commands.append(cmd)
            if diagnostic:
                return mock.Mock(stdout=[diagnostic + '\n'], returncode=1)
            output = Path(cmd[cmd.index('-o') + 1])
            output.parent.mkdir(parents=True, exist_ok=True)
            if m.target == 'mac-app':
                output.mkdir()
            else:
                output.touch()
            if m.target == 'ios' and m.ipa_kind == 'shared':
                extracted = Path(m.effective_work_dir, 'extract/v0')
                extracted.mkdir(parents=True, exist_ok=True)
                (extracted / 'RomFS.img').write_bytes(b'fixture')
            return mock.Mock(stdout=[], returncode=0)

        # Exercise the Windows driver entry for iOS. The process and its machine-specific toolchain
        # are stand-ins. The model builds the real command and handles its output on the Qt test thread.
        from nspb_qt.win import shim
        def inline_worker(*, target, daemon):
            return mock.Mock(start=target)

        with mock.patch.object(model.threading, 'Thread', side_effect=inline_worker), \
                mock.patch.object(model.subprocess, 'Popen', side_effect=spawn), \
                mock.patch.object(model.pu, 'IS_WIN', m.target == 'ios'), \
                mock.patch.object(model.pu, 'no_window_kwargs', return_value={}), \
                mock.patch.object(shim, 'build_env', side_effect=lambda env, **kw: env), \
                mock.patch.object(shim, 'verify_shim', return_value=(True, '')):
            m.start_build(title_id=title_id)

    def test_cartridge_second_title_owns_the_ios_output_and_library_entry(self):
        for ipa_kind in ('oneGame', 'shared'):
            with self.subTest(ipa_kind=ipa_kind):
                self.m.ipa_kind = ipa_kind
                self.run_process(DIAGNOSTIC)
                self.run_process(title_id=SECOND)
                cmd = self.commands[-1]
                self.assertEqual(cmd[1:3], ['-m', 'nspb_qt.win.driver'])
                self.assertEqual(cmd[cmd.index('--title-id') + 1], SECOND)
                self.assertEqual(cmd[cmd.index('--work-dir') + 1], str(self.root / f'{SECOND}_build'))
                self.assertEqual(cmd[cmd.index('-o') + 1], str(self.root / f'{SECOND}.ipa'))
                self.assertEqual(self.m.library.selected_id, SECOND)
                if ipa_kind == 'shared':
                    self.assertEqual(Path(self.m.archive_path), self.root / 'games' / SECOND)
                    self.assertEqual(Path(self.m.archive_path, 'romfs.img').read_bytes(), b'fixture')
                self.m.load_game_from_library(self.m.library.selected)
                self.run_process(DIAGNOSTIC)
                self.assertEqual(self.m.selectable_titles, (FIRST, SECOND))
                self.assertNotIn('--title-id', self.commands[-1])

    def test_mac_build_reports_an_ambiguous_cartridge_even_with_an_old_app(self):
        self.m.target = 'mac-app'
        (self.root / f'{FIRST}.app').mkdir()
        self.run_process(DIAGNOSTIC)
        self.assertEqual(self.m.selectable_titles, (FIRST, SECOND))
        self.run_process(title_id=SECOND)
        self.assertEqual(self.commands[-1][-1], str(self.root / f'{SECOND}.app'))
        self.assertEqual(self.m.library.selected.app_path, str(self.root / f'{SECOND}.app'))

    def test_unexpected_errors_during_build_and_archive_finish_the_build(self):
        self.m.out_dir = str(self.root)
        self.m.ipa_kind = 'shared'
        transitions = []
        results = []
        self.m.runningChanged.connect(transitions.append)
        self.m.finished.connect(lambda ok, note: results.append((ok, note)))

        def fail(*args):
            self.assertTrue(self.m.running)
            raise RuntimeError('fixture failed')

        for method in ('_flush_lines', '_record_library_ios_completion'):
            with self.subTest(method=method), mock.patch.object(self.m, method, side_effect=fail):
                transitions.clear()
                results.clear()
                self.run_process()
                self.assertFalse(self.m.running)
                self.assertEqual(transitions, [True, False])
                self.assertEqual(results, [(False, self.m.t('msg.buildFailedReason', 'fixture failed'))])

    def test_the_card_can_retry_only_a_title_offered_for_the_current_inputs(self):
        self.run_process(DIAGNOSTIC)
        w = MainWindow(self.m)
        w._init_timer.stop()
        try:
            w._show_failure()
            buttons = {b.text(): b for b in w.failure_box.findChildren(QPushButton)}
            self.assertIn(SECOND, buttons)
            button = buttons[SECOND]
            self.assertEqual(button.property('titleID'), SECOND)
            button.setText('Second game')
            w._show_failure()
            self.assertIs(w.title_buttons.itemAt(1).widget(), button)
            with mock.patch.object(self.m, 'start_build') as start:
                buttons[SECOND].click()
                start.assert_called_once_with(title_id=SECOND)
            self.m.running = True
            with mock.patch.object(self.m, 'cancel_build') as cancel:
                buttons[SECOND].click()
                cancel.assert_not_called()
            self.m.running = False
            self.m.start_build(title_id='0100000000000000')
            self.m.base_path = str(self.root / 'other.xci')
            self.m.start_build(title_id=SECOND)
            self.assertEqual(len(self.commands), 1)
            self.assertEqual(self.m.selectable_titles, ())
        finally:
            w.close()
            w.deleteLater()
            self.app.sendPostedEvents(None, QEvent.DeferredDelete)
