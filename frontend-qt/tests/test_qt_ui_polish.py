"""Regression tests for Qt launcher UI polish, P0 fixes, responsive layout, focus rings, and l10n resilience."""
from __future__ import annotations

import ast
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

os.environ.setdefault('QT_QPA_PLATFORM', 'offscreen')

ROOT = Path(__file__).resolve().parents[2]
QT_DIR = ROOT / 'frontend-qt'
if str(QT_DIR) not in sys.path:
    sys.path.insert(0, str(QT_DIR))

from nspb_qt import style  # noqa: E402

try:
    from PySide6.QtCore import QEvent, QPointF, Qt
    from PySide6.QtGui import QColor, QKeyEvent, QMouseEvent, QPalette
    from PySide6.QtWidgets import QApplication, QMessageBox
    HAS_QT = True
except ImportError:
    QApplication = None
    QEvent = None
    HAS_QT = False


class StyleTokenContractTests(unittest.TestCase):
    """Pure-Python contract checks that run both with and without PySide6."""

    def test_tokens_align_with_shared_design_tokens_json(self) -> None:
        tokens = json.loads((ROOT / 'frontend' / 'design-tokens' / 'tokens.json').read_text(encoding='utf-8'))
        colors = tokens['color']
        self.assertTrue(hasattr(style, 'DANGER'), 'style.DANGER must be defined for DriveSelectDialog preflight errors')
        self.assertEqual(style.BG.lower(), colors['background']['$value'].lower())
        self.assertEqual(style.CARD.lower(), colors['surface']['$value'].lower())
        self.assertEqual(style.SURFACE_RAISED.lower(), colors['surfaceRaised']['$value'].lower())
        self.assertEqual(style.ACCENT.lower(), colors['accent']['$value'].lower())
        self.assertEqual(style.ACCENT_INK.lower(), colors['accentOn']['$value'].lower())
        self.assertEqual(style.GREEN.lower(), colors['status']['ready']['$value'].lower())
        self.assertEqual(style.AMBER.lower(), colors['status']['warning']['$value'].lower())
        self.assertEqual(style.DANGER.lower(), colors['status']['error']['$value'].lower())
        self.assertEqual(style.DANGER_FILL.lower(), colors['status']['errorFill']['$value'].lower())
        self.assertTrue(callable(getattr(style, 'build_dark_palette', None)))

    def test_stylesheet_covers_dark_primitives_and_focus_rings(self) -> None:
        qss = style.STYLESHEET
        for selector in (
            'QCheckBox',
            'QCheckBox::indicator',
            'QToolTip',
            'QMenu',
            'QMessageBox',
            'QComboBox#launcherDropdown::down-arrow',
            'QPushButton[kbFocus="true"]:focus',
            'QPushButton#creamOutlinePill',
            'QLineEdit#searchField:focus',
            'QFrame#staleShaderBanner',
        ):
            self.assertIn(selector, qss, f'Missing QSS coverage for {selector}')

    def test_static_anti_regression_guards(self) -> None:
        ui_src = (QT_DIR / 'nspb_qt' / 'ui.py').read_text(encoding='utf-8')
        widgets_src = (QT_DIR / 'nspb_qt' / 'widgets.py').read_text(encoding='utf-8')
        rf_src = (QT_DIR / 'nspb_qt' / 'refresh_flow.py').read_text(encoding='utf-8')

        self.assertNotIn('setFixedWidth(184)', ui_src)
        self.assertNotIn('new_build_btn', ui_src)
        self.assertNotIn('🎮', ui_src)
        self.assertNotIn("f'[{plat_name}]'", rf_src)

        # Ensure LauncherSegmented.paintEvent never calls setFixedWidth
        tree = ast.parse(widgets_src)
        seg_cls = next(n for n in tree.body if isinstance(n, ast.ClassDef) and n.name == 'LauncherSegmented')
        paint_fn = next(n for n in seg_cls.body if isinstance(n, ast.FunctionDef) and n.name == 'paintEvent')
        paint_calls = [
            n.func.attr for n in ast.walk(paint_fn)
            if isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute)
        ]
        self.assertNotIn('setFixedWidth', paint_calls)


@unittest.skipUnless(HAS_QT, 'PySide6 is not installed')
class QtUiPolishTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.app = QApplication.instance() or QApplication([])

    def _delete(self, *objs) -> None:
        for obj in objs:
            if hasattr(obj, 'close'):
                obj.close()
            obj.deleteLater()
        self.app.sendPostedEvents(None, QEvent.DeferredDelete)
        self.app.processEvents()

    def _make_window(self, root: Path, *, games=None, lang: str = 'en', width: int = 1080, height: int = 760):
        from PySide6.QtCore import QSettings
        from nspb_qt import library as lib, model as model_mod
        from nspb_qt.i18n import Lang
        from nspb_qt.model import Model
        from nspb_qt.ui import MainWindow

        p_state = mock.patch.object(lib, 'default_state_dir', return_value=root / 'state')
        p_set = mock.patch.object(
            model_mod,
            'QSettings',
            side_effect=lambda *a, **kw: QSettings(str(root / 'settings.ini'), QSettings.IniFormat),
        )
        p_deps = mock.patch.object(Model, 'check_deps', lambda self: None)
        p_art = mock.patch.object(lib.ArtworkStore, 'request_banner_async')
        p_onb = mock.patch.object(MainWindow, '_maybe_show_onboarding', lambda self: None)
        for p in (p_state, p_set, p_deps, p_art, p_onb):
            p.start()
            self.addCleanup(p.stop)

        m = Model()
        m.lang = Lang(lang)
        if games:
            m.library.games = list(games)
            m.library.selected_id = games[0].title_id
        w = MainWindow(m, perform_startup_checks=False)
        self.addCleanup(self._delete, w, m)
        w.resize(width, height)
        w.show()
        for _ in range(3):
            self.app.processEvents()
        return m, w

    def test_drive_select_preflight_error_does_not_raise_attribute_error(self) -> None:
        from nspb_qt import library as lib
        from nspb_qt.i18n import Lang
        from nspb_qt.model import Model
        from nspb_qt.sheets import DriveSelectDialog

        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            with mock.patch.object(lib, 'default_state_dir', return_value=root / 'state'), \
                 mock.patch.object(Model, 'check_deps', lambda self: None):
                m = Model()
                m.lang = Lang('en')
                sources = [('0100000000010000', 'Super Mario Odyssey', str(root / 'arch'), 6 * 1024 ** 3)]
                for err_msg in (
                    'Not enough free space on target drive (need 6.0 GB, free 1.0 GB)',
                    'FAT32 cannot hold files larger than 4 GB',
                ):
                    with mock.patch.object(lib.DriveCopy, 'preflight_batch_copy', return_value=(6 * 1024 ** 3, err_msg)):
                        dlg = DriveSelectDialog(m, str(root), sources)
                        try:
                            self.assertEqual(dlg.space_lbl.text(), err_msg)
                            self.assertFalse(dlg.confirm_btn.isEnabled())
                            self.assertIn(style.DANGER, dlg.space_lbl.styleSheet())
                        finally:
                            self._delete(dlg)
                self._delete(m)

    def test_dark_palette_roles(self) -> None:
        pal = style.build_dark_palette()
        self.assertEqual(pal.color(QPalette.ColorRole.Window).name().lower(), style.BG.lower())
        self.assertEqual(pal.color(QPalette.ColorRole.WindowText).name().lower(), style.TEXT.lower())
        self.assertEqual(pal.color(QPalette.ColorRole.Highlight).name().lower(), style.ACCENT.lower())
        self.assertEqual(pal.color(QPalette.ColorRole.HighlightedText).name().lower(), style.ACCENT_INK.lower())

    def test_startup_landing_page_empty_vs_populated_and_scroll_arrows(self) -> None:
        from nspb_qt import library as lib

        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            # Empty library lands on Library welcome screen
            _m_empty, w_empty = self._make_window(root / 'empty')
            self.assertEqual(w_empty._current_page, 'library')
            self.assertEqual(w_empty.lib_stack.currentIndex(), 0)
            self.assertFalse(w_empty.empty_lib_icon.pixmap().isNull())

            # Single game lands on populated Hero + hides overflow arrows
            g1 = lib.LibraryGame('0100000000010000', 'Celeste', inputs={'base': ['c.nsp']})
            _m_one, w_one = self._make_window(root / 'one', games=[g1], width=1080)
            self.assertEqual(w_one._current_page, 'library')
            self.assertEqual(w_one.lib_stack.currentIndex(), 1)
            self.assertEqual(w_one.hero.refresh_btn.objectName(), 'heroSecondary')
            self.assertEqual(w_one.hero.primary_btn.objectName(), 'heroPlay')
            self.assertTrue(w_one.scroll_left_btn.isHidden())
            self.assertTrue(w_one.scroll_right_btn.isHidden())

            # Many games trigger overflow and show scroll arrows
            many = [
                lib.LibraryGame(f'010000000001000{i}', f'Game {i}', inputs={'base': [f'g{i}.nsp']})
                for i in range(8)
            ]
            _m_many, w_many = self._make_window(root / 'many', games=many, width=900)
            self.assertFalse(w_many.scroll_left_btn.isHidden())
            self.assertFalse(w_many.scroll_right_btn.isHidden())

    def test_narrow_topbar_zero_overlap_across_long_languages(self) -> None:
        from nspb_qt.i18n import Lang

        with tempfile.TemporaryDirectory() as td:
            m, w = self._make_window(Path(td), width=820, height=620)
            for code in ('en', 'zh', 'de', 'fr', 'es'):
                m.set_lang(Lang(code))
                w._switch_page('library')
                self.app.processEvents()
                brand_right = w.title_label.mapTo(w.top_bar, w.title_label.rect().topRight()).x()
                nav_left = w.top_bar.nav_container.geometry().left()
                nav_right = w.top_bar.nav_container.geometry().right()
                search_left = w.search_input.mapTo(w.top_bar, w.search_input.rect().topLeft()).x()
                self.assertLessEqual(
                    brand_right,
                    nav_left,
                    f'Brand overlaps nav in {code} at 820px: {brand_right} > {nav_left}',
                )
                self.assertLessEqual(
                    nav_right,
                    search_left,
                    f'Nav overlaps search in {code} at 820px: {nav_right} > {search_left}',
                )

    def test_centered_920px_columns_box_flattening_and_log_card(self) -> None:
        from nspb_qt.model import Dep, DepState

        with tempfile.TemporaryDirectory() as td:
            m, w = self._make_window(Path(td), width=1440, height=840)
            w._switch_page('builds')
            self.app.processEvents()

            # 920px readable column centered on 1440px window
            col_geom = w.builds_page.column_host.geometry()
            left_gap = col_geom.left()
            right_gap = w.builds_page.width() - (col_geom.left() + col_geom.width())
            self.assertLessEqual(col_geom.width(), 924)
            self.assertGreaterEqual(col_geom.width(), 880)
            self.assertAlmostEqual(left_gap, right_gap, delta=2)

            # failure_box is a top-level sibling, not nested inside action_group
            self.assertFalse(w.action_group.isAncestorOf(w.failure_box))
            self.assertTrue(w.builds_page.isAncestorOf(w.failure_box))

            # Log card defaults collapsed, copies to clipboard, and auto-expands on build failure
            self.assertFalse(w._log_expanded)
            self.assertTrue(w.log_wrap.isHidden())
            w._append_log('ERROR: boom\nWARN: caution\n')
            w._copy_log()
            self.assertIn('ERROR: boom', QApplication.clipboard().text())
            w._on_finished(False, 'failed')
            self.app.processEvents()
            self.assertTrue(w._log_expanded)
            self.assertFalse(w.log_wrap.isHidden())

            # Dependencies render flat (no #subcard nested frame)
            m.deps = [Dep('python', 'dep.python', 'dep.python.hint', DepState.OK, 'python3')]
            m.deps_checked = True
            w._switch_page('settings')
            w._refresh_deps()
            self.app.processEvents()
            dep_frame = w._dep_row_widgets['python']['frame']
            self.assertNotEqual(dep_frame.objectName(), 'subcard')

    def test_all_languages_flexible_buttons_never_truncate(self) -> None:
        from nspb_qt.i18n import Lang

        with tempfile.TemporaryDirectory() as td:
            m, w = self._make_window(Path(td), width=1120, height=780)
            self.assertEqual(w.setup_goto_btn.objectName(), 'creamOutlinePill')
            self.assertEqual(w.pick_folder_btn.objectName(), 'creamOutlinePill')
            self.assertEqual(w.build_btn.objectName(), 'primary')
            buttons = [
                w.setup_goto_btn,
                w.pick_folder_btn,
                w.out_btn,
                w.input_rows['base']['choose'],
                w.input_rows['keys']['choose'],
                w.settings_lib_choose_btn,
                w.defender_btn,
                w.defender_remove_btn,
                w.diag_btn,
                w.run_onboarding_btn,
                w.ver_action_btn,
            ]
            for btn in buttons:
                self.assertEqual(btn.minimumWidth(), 148)
                self.assertGreater(btn.maximumWidth(), 1000)

            langs = Lang.all()
            self.assertGreaterEqual(len(langs), 10)
            for lg in langs:
                m.set_lang(lg)
                self.app.processEvents()
                for btn in buttons:
                    txt = btn.text()
                    if not txt:
                        continue
                    text_w = btn.fontMetrics().horizontalAdvance(txt)
                    hint_w = btn.sizeHint().width()
                    self.assertGreaterEqual(
                        hint_w,
                        text_w + 16,
                        f'Button {txt!r} truncated in {lg.code}: sizeHint={hint_w} < text={text_w}+16',
                    )

    def test_focus_policies_keyboard_navigation_and_shortcuts(self) -> None:
        from nspb_qt.widgets import GameCardWidget, LauncherSegmented, LauncherSwitch

        sw = LauncherSwitch(False)
        self.assertEqual(sw.focusPolicy(), Qt.StrongFocus)
        toggled: list[bool] = []
        sw.toggled.connect(toggled.append)
        sw.keyPressEvent(QKeyEvent(QEvent.Type.KeyPress, Qt.Key_Space, Qt.NoModifier))
        self.assertEqual(toggled, [True])

        seg = LauncherSegmented([('a', 'Alpha'), ('b', 'Beta')], selected='a')
        self.assertEqual(seg.focusPolicy(), Qt.StrongFocus)
        changed: list[str] = []
        seg.changed.connect(changed.append)
        seg.keyPressEvent(QKeyEvent(QEvent.Type.KeyPress, Qt.Key_Right, Qt.NoModifier))
        self.assertEqual(changed, ['b'])

        card = GameCardWidget('0100000000010000', 'Zelda', None, False, style.GREEN)
        self.assertEqual(card.focusPolicy(), Qt.StrongFocus)
        clicked: list[str] = []
        card.clicked.connect(clicked.append)
        card.mousePressEvent(
            QMouseEvent(
                QEvent.Type.MouseButtonPress,
                QPointF(10, 10),
                QPointF(10, 10),
                Qt.LeftButton,
                Qt.LeftButton,
                Qt.NoModifier,
            )
        )
        self.assertTrue(card._pressed)
        card.mouseReleaseEvent(
            QMouseEvent(
                QEvent.Type.MouseButtonRelease,
                QPointF(10, 10),
                QPointF(10, 10),
                Qt.LeftButton,
                Qt.NoButton,
                Qt.NoModifier,
            )
        )
        self.assertFalse(card._pressed)
        self.assertEqual(clicked, ['0100000000010000'])
        self._delete(sw, seg, card)

        with tempfile.TemporaryDirectory() as td:
            _m, w = self._make_window(Path(td))
            self.assertEqual(len(w._shortcuts), 5)
            w._switch_page('builds')
            self.assertEqual(w._current_page, 'builds')
            w._focus_search()
            self.assertEqual(w._current_page, 'library')
            w.search_input.setText('zelda')
            w._handle_escape()
            self.assertEqual(w.search_input.text(), '')
            w._switch_page('settings')
            w._handle_escape()
            self.assertEqual(w._current_page, 'library')

    def test_focus_visible_and_game_card_keyboard_navigation(self) -> None:
        from PySide6.QtGui import QFocusEvent
        from nspb_qt import library as lib
        from nspb_qt.i18n import Lang
        from nspb_qt.widgets import GameCardWidget

        with tempfile.TemporaryDirectory() as td:
            games = [
                lib.LibraryGame('0100000000010000', 'Alpha', inputs={'base': ['a.nsp']}),
                lib.LibraryGame('0100000000020000', 'Beta', inputs={'base': ['b.nsp']}),
                lib.LibraryGame('0100000000030000', 'Gamma', inputs={'base': ['g.nsp']}),
            ]
            m, w = self._make_window(Path(td), games=games, width=1080, height=760)

            # Switching pages must never flash a 2px keyboard focus ring via OtherFocusReason
            for page in ('builds', 'settings', 'library'):
                w._switch_page(page)
                self.app.processEvents()
                self.assertFalse(
                    w.nav_seg._show_focus_ring,
                    f'nav_seg must not show keyboard focus ring after _switch_page({page!r})',
                )

            # Standard button: mouse focus keeps kbFocus False, Tab focus sets kbFocus True
            w._switch_page('builds')
            self.app.processEvents()
            btn = w.pick_folder_btn
            QApplication.sendEvent(btn, QFocusEvent(QEvent.Type.FocusIn, Qt.MouseFocusReason))
            self.assertFalse(bool(btn.property('kbFocus')))
            QApplication.sendEvent(btn, QFocusEvent(QEvent.Type.FocusIn, Qt.TabFocusReason))
            self.assertTrue(bool(btn.property('kbFocus')))
            QApplication.sendEvent(
                btn,
                QMouseEvent(
                    QEvent.Type.MouseButtonPress,
                    QPointF(10, 10),
                    QPointF(10, 10),
                    Qt.LeftButton,
                    Qt.LeftButton,
                    Qt.NoModifier,
                ),
            )
            self.assertFalse(bool(btn.property('kbFocus')))

            # Segmented control: Tab focus enables ring, mouse press clears it
            QApplication.sendEvent(w.nav_seg, QFocusEvent(QEvent.Type.FocusIn, Qt.TabFocusReason))
            self.assertTrue(w.nav_seg._show_focus_ring)
            QApplication.sendEvent(w.nav_seg, QFocusEvent(QEvent.Type.FocusIn, Qt.OtherFocusReason))
            self.assertFalse(w.nav_seg._show_focus_ring)

            # GameCardWidget arrow navigation starts from the focused card, not the previously selected card
            w._switch_page('library')
            self.app.processEvents()
            self.assertEqual(m.library.selected.title_id, games[0].title_id)
            cards = [
                w.coll_strip_layout.itemAt(i).widget()
                for i in range(w.coll_strip_layout.count())
                if isinstance(w.coll_strip_layout.itemAt(i).widget(), GameCardWidget)
            ]
            self.assertEqual([c.title_id for c in cards], [g.title_id for g in games])
            cards[1].setFocus(Qt.TabFocusReason)
            cards[1].keyPressEvent(QKeyEvent(QEvent.Type.KeyPress, Qt.Key_Right, Qt.NoModifier))
            self.app.processEvents()
            self.assertEqual(m.library.selected.title_id, games[2].title_id)

            # Stale shader dismiss button carries accessible name & tooltip and updates on language change
            m.set_lang(Lang('zh'))
            self.app.processEvents()
            self.assertEqual(w.stale_shader_dismiss_btn.toolTip(), m.t('library.dismissSkipped'))
            self.assertEqual(w.stale_shader_dismiss_btn.accessibleName(), m.t('library.dismissSkipped'))

    def test_stale_shader_non_blocking_banner_and_remove_confirmation(self) -> None:
        from nspb_qt import library as lib
        from nspb_qt import refresh_flow as rf

        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            g = lib.LibraryGame('0100000000010000', 'Hollow Knight', inputs={'base': ['hk.nsp']})
            m, w = self._make_window(root, games=[g])

            # Stale shader log line displays non-blocking top banner instead of QMessageBox.exec
            with mock.patch.object(QMessageBox, 'exec', side_effect=AssertionError('must not pop modal QMessageBox')):
                w._append_log('[NOTE] cached shader libraries cannot be reused (the translation chain changed)\n')
            self.assertFalse(w.stale_shader_banner.isHidden())
            w._dismiss_stale_shader_banner()
            self.assertTrue(w.stale_shader_banner.isHidden())

            # Remove from collection requires confirmation
            with mock.patch.object(QMessageBox, 'exec', return_value=0), \
                 mock.patch.object(QMessageBox, 'clickedButton', return_value=None):
                w._confirm_remove_from_library(g)
            self.assertEqual(len(m.library.games), 1)

            # BatchRefreshDialog uses clean platform chips without square brackets and dark QSS
            assess = rf.GameRefreshAssessment(
                state='specific_fast',
                has_specific_update=True,
                version_label='1.5.0',
                can_fast_mac=True,
                can_fast_ios=True,
                needs_img_guide_ios=False,
                missing_original_package=False,
            )
            (root / 'HK.app').mkdir()
            (root / 'HK.ipa').write_bytes(b'ipa')
            g_built = lib.LibraryGame(
                '0100000000010000',
                'Hollow Knight',
                app_path=str(root / 'HK.app'),
                ipa_path=str(root / 'HK.ipa'),
            )
            bd = rf.BatchRefreshDialog(m, [rf.BatchRefreshEntry(game=g_built, assessment=assess)])
            try:
                self.assertIn(style.BG, bd.styleSheet())
                for cb, _item, _fast in bd._checkboxes:
                    self.assertNotIn('[', cb.text())
                    self.assertNotIn(']', cb.text())
                    self.assertEqual(cb.objectName(), 'platformChipCheck')
            finally:
                self._delete(bd)


if __name__ == '__main__':
    unittest.main()
