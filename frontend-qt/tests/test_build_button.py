"""The Windows window's build button, and the line that says why it is grey.

The report: the panel said "everything required is installed (2 optional missing)", the game files
and the keys were chosen, and the build button stayed grey with nothing on the screen to say why. The
two optional rows (spirv-cross and glslangValidator, only an OpenGL game uses them) were counted by
`all_deps_ok`, so `can_build` was false. The same four conditions of `can_build` now each have a line.

Needs PySide6 and runs offscreen, skipped when PySide6 is absent.

    QT_QPA_PLATFORM=offscreen python3 -m unittest frontend-qt/tests/test_build_button.py -v
"""
from __future__ import annotations

import os
import sys
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'frontend-qt'))
os.environ.setdefault('QT_QPA_PLATFORM', 'offscreen')

try:
    from PySide6.QtCore import QEvent
    from PySide6.QtWidgets import QApplication
except ImportError:          # the packaged app always has it, a bare python3 may not
    QApplication = None


@unittest.skipIf(QApplication is None, 'PySide6 is not installed')
class BuildButton(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app = QApplication.instance() or QApplication([])

    def _delete(self, m, w):
        w.close()
        w.deleteLater()
        m.deleteLater()
        self.app.sendPostedEvents(None, QEvent.DeferredDelete)
        self.app.processEvents()

    def _window(self, *, deps, checked=True, repo=True, base='a.nsp', keys='prod.keys'):
        from nspb_qt.i18n import Lang
        from nspb_qt.model import Model
        from nspb_qt.ui import MainWindow
        patches = [mock.patch.object(Model, 'check_deps', lambda self: None),   # no probe thread: the rows are the test's
                   mock.patch.object(Model, 'repo_ok', new_callable=mock.PropertyMock, return_value=repo)]
        for p in patches:
            p.start()
            self.addCleanup(p.stop)
        m = Model()
        m.lang = Lang('en')   # these assertions read English whatever the device language is
        m.deps, m.deps_checked = deps, checked
        m.base_path, m.keys_path = base, keys
        w = MainWindow(m)
        self.addCleanup(self._delete, m, w)
        w.show()
        for _ in range(3):
            self.app.processEvents()
        w._refresh_deps()
        return m, w

    @staticmethod
    def _rows(*, required_missing=False, optional_missing=0):
        from nspb_qt.model import Dep, DepState
        rows = [Dep('python', 'dep.python', 'dep.python.hint', DepState.OK, 'python.exe'),
                Dep('zstd', 'dep.zstd.win', 'dep.zstd.hint.win', DepState.MISSING if required_missing else DepState.OK, '')]
        for pid in ('spirv-cross', 'glslangValidator')[:optional_missing]:
            rows.append(Dep(pid, 'dep.spirv.win', 'dep.spirv.hint.win', DepState.MISSING, '', required=False))
        return rows

    def test_the_button_is_on_when_only_optional_tools_are_missing(self):
        m, w = self._window(deps=self._rows(optional_missing=2))
        self.assertTrue(m.can_build)
        self.assertTrue(w.build_btn.isEnabled())
        self.assertIn('everything required is installed', w.deps_summary.text())
        self.assertIn('2 optional missing', w.deps_summary.text())

    def test_all_ready_when_nothing_is_missing(self):
        m, w = self._window(deps=self._rows())
        self.assertTrue(w.build_btn.isEnabled())
        self.assertIn('All ready', w.deps_summary.text())

    def test_a_missing_required_tool_greys_the_button_and_says_so(self):
        m, w = self._window(deps=self._rows(required_missing=True, optional_missing=2))
        self.assertFalse(w.build_btn.isEnabled())
        self.assertEqual(w.footer.text(), m.t('status.installFirst'))
        self.assertIn('1 missing', w.deps_summary.text())

    def test_checking_says_so(self):
        m, w = self._window(deps=[], checked=False)
        self.assertFalse(w.build_btn.isEnabled())
        self.assertEqual(w.footer.text(), m.t('status.checkingDeps'))

    def test_every_other_grey_button_has_a_line_too(self):
        m, w = self._window(deps=self._rows(), repo=False)
        self.assertFalse(w.build_btn.isEnabled())
        self.assertEqual(w.footer.text(), m.t('status.chooseRepo'))
        m, w = self._window(deps=self._rows(), keys='')   # the base game is chosen, the keys are not
        self.assertFalse(w.build_btn.isEnabled())
        self.assertEqual(w.footer.text(), m.t('status.needInputs'))

    def test_the_line_goes_when_the_reason_does(self):
        m, w = self._window(deps=self._rows(required_missing=True))
        self.assertEqual(w.footer.text(), m.t('status.installFirst'))
        m.deps = self._rows()
        w._refresh_deps()
        self.assertTrue(w.build_btn.isEnabled())
        self.assertEqual(w.footer.text(), '', 'a line about a dependency does not stay once the dependency is there')


if __name__ == '__main__':
    unittest.main()
