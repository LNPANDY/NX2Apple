"""Entry point: python3 -m nspb_qt  (or run main.py)."""
from __future__ import annotations

import sys
from pathlib import Path

from PySide6.QtCore import Qt
from PySide6.QtGui import QGuiApplication, QIcon
from PySide6.QtWidgets import QApplication

from .model import Model
from .platform_util import IS_WIN, hide_console_for_children
from .style import STYLE, load_font
from .ui import MainWindow


def app_icon() -> QIcon:
    assets = Path(__file__).resolve().parent / 'assets'
    for name in ('app_icon.png', 'app_icon.ico'):
        p = assets / name
        if p.is_file():
            return QIcon(str(p))
    return QIcon()


def main() -> int:
    # Before anything can spawn a child: on Windows every subprocess would otherwise open its own
    # console window (see the docstring — this is the "black window, nothing happens" report).
    hide_console_for_children()
    if IS_WIN:
        try:
            import ctypes
            ctypes.windll.shell32.SetCurrentProcessExplicitAppUserModelID('nxnative.nx2apple.launcher')
        except Exception:
            pass
    # High-DPI: let Qt scale with the screen. On a handheld (a small 720p/800p panel at
    # 125-150%) the default policy rounds the scale factor up and the window no longer fits;
    # PassThrough honours the system factor as-is and the font sizes below stay in points.
    QGuiApplication.setHighDpiScaleFactorRoundingPolicy(
        Qt.HighDpiScaleFactorRoundingPolicy.PassThrough)
    app = QApplication(sys.argv)
    app.setApplicationName('NS Port Builder')
    app.setApplicationDisplayName('NX2Apple')
    icon = app_icon()
    if not icon.isNull():
        app.setWindowIcon(icon)
    app.setStyleSheet(STYLE)
    app.setStyle('Fusion')   # the same widget look on Windows and macOS
    family = load_font()     # Manrope, as the Mac launcher; the system font when it cannot load
    if family:
        font = app.font()
        font.setFamily(family)
        app.setFont(font)
    model = Model()
    win = MainWindow(model)
    win.show()
    return app.exec()


if __name__ == '__main__':
    raise SystemExit(main())
