"""Entry point: python3 -m nspb_qt  (or run main.py)."""
from __future__ import annotations

import sys

from PySide6.QtCore import Qt
from PySide6.QtGui import QGuiApplication
from PySide6.QtWidgets import QApplication

from .model import Model
from .platform_util import hide_console_for_children
from .style import STYLE, load_font
from .ui import MainWindow


def main() -> int:
    # Before anything can spawn a child: on Windows every subprocess would otherwise open its own
    # console window (see the docstring — this is the "black window, nothing happens" report).
    hide_console_for_children()
    # High-DPI: let Qt scale with the screen. On a handheld (a small 720p/800p panel at
    # 125-150%) the default policy rounds the scale factor up and the window no longer fits;
    # PassThrough honours the system factor as-is and the font sizes below stay in points.
    QGuiApplication.setHighDpiScaleFactorRoundingPolicy(
        Qt.HighDpiScaleFactorRoundingPolicy.PassThrough)
    app = QApplication(sys.argv)
    app.setApplicationName('NS Port Builder')
    app.setApplicationDisplayName('NS Port Builder')
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
