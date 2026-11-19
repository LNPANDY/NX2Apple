"""Unit tests for built-first game library sorting in the Qt front end (`MainWindow._filtered_games`).

Runs cleanly both with real PySide6 installed and in headless CI environments where PySide6 is absent.
"""
from __future__ import annotations

import os
from pathlib import Path
import sys
import tempfile
import types
from types import SimpleNamespace
import unittest

os.environ.setdefault('QT_QPA_PLATFORM', 'offscreen')

ROOT = Path(__file__).resolve().parents[2]
QT_DIR = ROOT / 'frontend-qt'
if str(QT_DIR) not in sys.path:
    sys.path.insert(0, str(QT_DIR))

from nspb_qt import library as lib  # noqa: E402


class _DummyTypeMeta(type):
    def __getattr__(cls, _name: str):
        return cls


class _DummyWidget(metaclass=_DummyTypeMeta):
    def __init__(self, *_a, **_kw) -> None:
        pass

    def __getattr__(self, _name: str):
        return _DummyWidget


class _FakeSignal:
    def __init__(self, *_a, **_kw) -> None:
        pass

    def __set_name__(self, _owner, _name: str) -> None:
        pass


def _load_ui_with_qt_fallback():
    try:
        import PySide6  # noqa: F401
        from nspb_qt import ui as ui_mod
        return ui_mod, lambda: None
    except ImportError:
        pass

    tracked = (
        'PySide6',
        'PySide6.QtCore',
        'PySide6.QtGui',
        'PySide6.QtWidgets',
        'nspb_qt.model',
        'nspb_qt.widgets',
        'nspb_qt.sheets',
        'nspb_qt.ui',
    )
    saved = {k: sys.modules.get(k) for k in tracked}

    qt_pkg = types.ModuleType('PySide6')
    qt_core = types.ModuleType('PySide6.QtCore')
    qt_gui = types.ModuleType('PySide6.QtGui')
    qt_widgets = types.ModuleType('PySide6.QtWidgets')

    for name in ('QPoint', 'QTimer', 'QUrl', 'QObject', 'QThread', 'QSettings', 'QMetaObject', 'Qt'):
        setattr(qt_core, name, _DummyWidget)
    qt_core.Signal = _FakeSignal
    qt_core.Slot = lambda *_a, **_kw: (lambda fn: fn)
    qt_core.Q_ARG = lambda _t, v: v
    qt_core.Property = lambda *_a, **_kw: property()

    for name in (
        'QColor', 'QDesktopServices', 'QDragEnterEvent', 'QDropEvent', 'QFont', 'QFontMetrics',
        'QIcon', 'QImage', 'QMouseEvent', 'QPainter', 'QPixmap', 'QResizeEvent',
    ):
        setattr(qt_gui, name, _DummyWidget)

    for name in (
        'QApplication', 'QCheckBox', 'QComboBox', 'QDialog', 'QFileDialog', 'QFrame',
        'QGraphicsOpacityEffect', 'QHBoxLayout', 'QLabel', 'QLineEdit', 'QListWidget',
        'QListWidgetItem', 'QMainWindow', 'QMenu', 'QMessageBox', 'QPlainTextEdit',
        'QProgressBar', 'QPushButton', 'QScrollArea', 'QSizePolicy', 'QStackedWidget',
        'QToolButton', 'QVBoxLayout', 'QWidget',
    ):
        setattr(qt_widgets, name, _DummyWidget)

    class _DynamicMod(types.ModuleType):
        def __getattr__(self, _name: str):
            return _DummyWidget

    for sub, mod in (('QtCore', qt_core), ('QtGui', qt_gui), ('QtWidgets', qt_widgets)):
        mod.__class__ = _DynamicMod
        setattr(qt_pkg, sub, mod)

    sys.modules['PySide6'] = qt_pkg
    sys.modules['PySide6.QtCore'] = qt_core
    sys.modules['PySide6.QtGui'] = qt_gui
    sys.modules['PySide6.QtWidgets'] = qt_widgets

    from nspb_qt import ui as ui_mod

    def _cleanup() -> None:
        import nspb_qt
        for k, old in saved.items():
            if old is None:
                sys.modules.pop(k, None)
            else:
                sys.modules[k] = old
        for attr in ('model', 'widgets', 'sheets', 'ui'):
            if saved.get(f'nspb_qt.{attr}') is None and hasattr(nspb_qt, attr):
                delattr(nspb_qt, attr)

    return ui_mod, _cleanup


class QtLibrarySortTests(unittest.TestCase):
    def test_filtered_games_prioritizes_built_games_over_unbuilt_roms(self) -> None:
        ui_mod, cleanup = _load_ui_with_qt_fallback()
        try:
            with tempfile.TemporaryDirectory() as td:
                root = Path(td)
                mac_app = root / 'Zelda.app'
                mac_app.mkdir()
                ipa = root / 'Mario.ipa'
                ipa.write_bytes(b'ipa')
                broken_app = root / 'MissingApp.app'

                g_unbuilt_a = lib.LibraryGame(title_id='0100000000000001', name='Alpha ROM', inputs={'base': ['/a.nsp']})
                g_unbuilt_z = lib.LibraryGame(title_id='0100000000000002', name='Zeta ROM', inputs={'base': ['/z.nsp']})
                g_building = lib.LibraryGame(title_id='0100000000000003', name='Building Game', inputs={'base': ['/b.nsp']})
                g_repair = lib.LibraryGame(title_id='0100000000000004', name='Repair Game', app_path=str(broken_app))
                g_ios = lib.LibraryGame(title_id='0100000000000005', name='Mario iOS', ipa_path=str(ipa))
                g_mac = lib.LibraryGame(title_id='0100000000000006', name='Zelda Mac', app_path=str(mac_app))

                fake_win = SimpleNamespace(
                    _library_filter='owned',
                    _search_query='',
                    _library_build_tier=ui_mod.MainWindow._library_build_tier,
                    m=SimpleNamespace(
                        running=True,
                        build_key=g_building.title_id,
                        library=SimpleNamespace(
                            games=[g_unbuilt_a, g_repair, g_building, g_ios, g_unbuilt_z, g_mac],
                        ),
                    ),
                )

                ordered = ui_mod.MainWindow._filtered_games(fake_win)
                self.assertEqual(
                    [g.title_id for g in ordered],
                    [
                        g_mac.title_id,       # Tier 0: has_app
                        g_ios.title_id,       # Tier 1: is_ready_for_ios
                        g_repair.title_id,    # Tier 2: stale app_path (preserves relative order vs building)
                        g_building.title_id,  # Tier 2: actively building
                        g_unbuilt_a.title_id, # Tier 3: unbuilt ROM (relative order preserved)
                        g_unbuilt_z.title_id, # Tier 3: unbuilt ROM
                    ],
                )

                # Search & built filter preserve built-first ordering on matching subset.
                fake_win._search_query = 'rom'
                searched = ui_mod.MainWindow._filtered_games(fake_win)
                self.assertEqual([g.title_id for g in searched], [g_unbuilt_a.title_id, g_unbuilt_z.title_id])

                fake_win._search_query = ''
                fake_win._library_filter = 'built'
                built_only = ui_mod.MainWindow._filtered_games(fake_win)
                self.assertEqual([g.title_id for g in built_only], [g_mac.title_id, g_ios.title_id])
        finally:
            cleanup()


if __name__ == '__main__':
    unittest.main()
