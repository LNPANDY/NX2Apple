"""Issue #52: a failed build says which line failed, and the log it points at is in view.

The reporter saw "Build failed (exit code 1) — see the log below" with no log below it. Two
separate things were wrong, and both are tested here because either alone still leaves the
report unusable:

* the message carried only the exit code, so the window said nothing about the cause;
* the log sits at the bottom of a scroll area, below the fold on any window shorter than about
  600 px, and the failure did not scroll it into view;
* and the input reminder overwrote the failure note on the refresh that follows it.

Needs PySide6 and runs offscreen; skipped when PySide6 is absent.

    QT_QPA_PLATFORM=offscreen python3 -m unittest frontend-qt/tests/test_build_failure.py -v
"""
from __future__ import annotations

import os
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'frontend-qt'))
os.environ.setdefault('QT_QPA_PLATFORM', 'offscreen')

try:
    from PySide6.QtCore import QEvent
    from PySide6.QtWidgets import QApplication, QScrollArea
except ImportError:          # the packaged app always has it; a bare python3 may not
    QApplication = None


@unittest.skipIf(QApplication is None, 'PySide6 is not installed')
class BuildFailure(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app = QApplication.instance() or QApplication([])

    def _delete(self, m, w):
        w.close()
        w.deleteLater()
        m.deleteLater()
        self.app.sendPostedEvents(None, QEvent.DeferredDelete)
        self.app.processEvents()

    def _window(self, height: int):
        from nspb_qt.i18n import Lang
        from nspb_qt.model import Model
        from nspb_qt.ui import MainWindow
        m = Model()
        m.lang = Lang.EN   # these assertions read English whatever the device language is
        w = MainWindow(m)
        # Delete while the app exists: PySide destroys leftovers after it at exit and segfaults.
        self.addCleanup(self._delete, m, w)
        w.resize(900, height)
        w.show()
        for _ in range(3):
            self.app.processEvents()
        return m, w

    def test_the_log_is_below_the_fold_on_a_short_window(self):
        """The precondition for the bug: at this height the log is not on screen."""
        m, w = self._window(460)
        scroll = w.findChild(QScrollArea)
        top = w.log.mapTo(scroll.widget(), w.log.rect().topLeft()).y()
        self.assertGreaterEqual(top, scroll.viewport().height())
        w.close()

    def test_a_failure_scrolls_the_log_into_view(self):
        m, w = self._window(460)
        scroll = w.findChild(QScrollArea)
        for line in ('extract: RomFS not found', 'Traceback (most recent call last):',
                     'RuntimeError: no prod.keys in the game folder'):
            m._on_line(line)
        w._on_finished(False, m.t('msg.buildFailedReason', m._last_error))
        self.app.processEvents()
        self.assertGreater(scroll.verticalScrollBar().value(), 0)
        w.close()

    def test_the_failure_note_names_the_last_real_line(self):
        m, w = self._window(700)
        for line in ('[1/7] extract', '[2/7] build shaders', 'RuntimeError: no prod.keys in the game folder'):
            m._on_line(line)
        self.assertEqual(m._last_error, 'RuntimeError: no prod.keys in the game folder',
                         'stage bookkeeping must not win over the last real line')
        w._on_finished(False, m.t('msg.buildFailedReason', m._last_error))
        self.assertIn('no prod.keys', w.footer.text())
        self.assertIn('see the log below', w.footer.text())
        w.close()

    def test_the_input_reminder_does_not_erase_the_failure(self):
        """The refresh after a failure used to replace the note with "Still need the base game"."""
        m, w = self._window(700)
        m._on_line('RuntimeError: no prod.keys in the game folder')
        w._on_finished(False, m.t('msg.buildFailedReason', m._last_error))
        w._refresh_running()
        self.assertIn('no prod.keys', w.footer.text())
        w.close()

    def test_starting_the_next_build_clears_it(self):
        m, w = self._window(700)
        m._on_line('RuntimeError: no prod.keys')
        w._on_finished(False, m.t('msg.buildFailedReason', m._last_error))
        w._build_clicked()                      # no inputs: start_build returns on its own check
        w._refresh_running()
        self.assertNotIn('no prod.keys', w.footer.text())
        w.close()


if __name__ == '__main__':
    unittest.main()
