"""Palette and stylesheet mirroring the Mac SwiftUI launcher (LauncherStyles.swift & LauncherCard.swift)."""
from __future__ import annotations

import os
import sys

BG = '#000000'
SURFACE = '#141416'
CARD = '#1a1a1c'
CARD_HOVER = '#222225'
BORDER = '#2c2c2e'
CARD_EDGE = BORDER
DIVIDER = '#232326'

TEXT = '#f5f5f7'
MUTED = '#9e9ea6'
FAINT = '#73737a'
PATH = '#6f7178'
HINT = '#a8aab0'

ACCENT = '#fff0d6'          # LauncherAccent.cream: rgb(1.0, 0.94, 0.84)
CREAM = ACCENT
ACCENT_HOVER = '#fff6e6'
ACCENT_PRESSED = '#e8d7ba'
ACCENT_DISABLED = '#3a3834'
ACCENT_INK = '#0d0d0f'      # LauncherAccent.ink

GREEN = '#52d97a'           # LauncherTone.ready
AMBER = '#ffbd38'           # LauncherTone.caution
ORANGE = AMBER
RED = '#ff6161'             # LauncherTone.danger
NEUTRAL_DOT = '#73737a'     # LauncherTone.muted

BTN = '#1b1b1c'
BTN_HOVER = '#242425'
BTN_PRESSED = '#2d2d2e'
BTN_EDGE = '#262627'
FIELD = '#161617'
TRACK = '#262627'
MONO = '"Cascadia Mono", "Consolas", "SF Mono", "Menlo", monospace'


def _font_file() -> str | None:
    """Manrope.ttf: in the bundle's `fonts` folder in a frozen build (build-qt.yml adds it), in
    the repository's frontend/fonts in a source run."""
    if getattr(sys, 'frozen', False):
        base = getattr(sys, '_MEIPASS', os.path.dirname(sys.executable))
        candidates = [
            os.path.join(base, 'fonts', 'Manrope.ttf'),
            os.path.join(os.path.dirname(sys.executable), 'fonts', 'Manrope.ttf'),
        ]
    else:
        here = os.path.dirname(os.path.abspath(__file__))
        candidates = [os.path.join(here, '..', '..', 'frontend', 'fonts', 'Manrope.ttf')]
    for c in candidates:
        if os.path.isfile(c):
            return c
    return None


def load_font() -> str:
    """Registers Manrope with Qt and returns its family name, or '' when unavailable."""
    path = _font_file()
    if path is None:
        return ''
    from PySide6.QtGui import QFontDatabase
    fid = QFontDatabase.addApplicationFont(path)
    families = QFontDatabase.applicationFontFamilies(fid) if fid >= 0 else []
    if 'Manrope' in families:
        return 'Manrope'
    return families[0] if families else ''


STYLESHEET = f"""
QMainWindow, QWidget#root {{
    background: {BG};
    color: {TEXT};
    font-family: "Manrope", "Segoe UI", "Inter", -apple-system, "PingFang SC", "Microsoft YaHei", sans-serif;
    font-size: 13px;
}}
QDialog {{
    background: #141416;
    color: {TEXT};
    font-family: "Manrope", "Segoe UI", "Inter", -apple-system, "PingFang SC", "Microsoft YaHei", sans-serif;
    font-size: 13px;
}}
QScrollArea {{
    background: transparent;
    border: none;
}}
QScrollArea > QWidget > QWidget {{
    background: transparent;
}}
QScrollBar:vertical {{
    background: transparent;
    width: 8px;
    margin: 4px 2px 4px 0px;
}}
QScrollBar::handle:vertical {{
    background: rgba(255, 255, 255, 0.18);
    min-height: 28px;
    border-radius: 3px;
}}
QScrollBar::handle:vertical:hover {{
    background: rgba(255, 255, 255, 0.30);
}}
QScrollBar::add-line:vertical, QScrollBar::sub-line:vertical,
QScrollBar::add-page:vertical, QScrollBar::sub-page:vertical {{
    background: none;
    height: 0px;
}}
QScrollBar:horizontal {{
    background: transparent;
    height: 8px;
    margin: 0px 4px 2px 4px;
}}
QScrollBar::handle:horizontal {{
    background: rgba(255, 255, 255, 0.18);
    min-width: 28px;
    border-radius: 3px;
}}
QScrollBar::add-line:horizontal, QScrollBar::sub-line:horizontal,
QScrollBar::add-page:horizontal, QScrollBar::sub-page:horizontal {{
    background: none;
    width: 0px;
}}
QFrame#card {{
    background: {CARD};
    border: 1px solid {BORDER};
    border-radius: 14px;
}}
QFrame#subcard {{
    background: #141416;
    border: 1px solid #262629;
    border-radius: 10px;
}}
QFrame#failureCard {{
    background: #221618;
    border: 1px solid #5c2b2f;
    border-radius: 14px;
}}
QFrame#bannerCard {{
    background: #1c1b18;
    border: 1px solid #3d3526;
    border-radius: 12px;
}}
QFrame#divider {{
    background: {DIVIDER};
    border: none;
    max-height: 1px;
    min-height: 1px;
}}
QFrame#topBar {{
    background: {BG};
    border-bottom: 1px solid #161618;
}}
QFrame#activityBar {{
    background: #0d0d0f;
    border-top: 1px solid #1f1f22;
}}
QLabel {{
    background: transparent;
    color: {TEXT};
}}
QLabel#pageTitle {{
    font-size: 36px;
    font-weight: 800;
    color: {TEXT};
}}
QLabel#pageNote {{
    font-size: 14px;
    color: {MUTED};
}}
QLabel#sectionTitle {{
    font-size: 14px;
    font-weight: 600;
    color: {MUTED};
}}
QLabel#sectionFoot {{
    font-size: 12px;
    color: {FAINT};
}}
QLabel#rowTitle {{
    font-size: 13px;
    font-weight: 600;
    color: {TEXT};
}}
QLabel#muted {{
    color: {MUTED};
    font-size: 12px;
}}
QLabel#faint {{
    color: {FAINT};
    font-size: 11px;
}}
QLabel#mono {{
    color: {MUTED};
    font-family: "Cascadia Mono", "Consolas", "SF Mono", "Menlo", monospace;
    font-size: 11.5px;
}}
QPushButton {{
    background: rgba(255, 255, 255, 0.08);
    color: {TEXT};
    border: 1px solid rgba(255, 255, 255, 0.13);
    border-radius: 12px;
    padding: 6px 16px;
    min-height: 18px;
    font-weight: 600;
    font-size: 12.5px;
}}
QPushButton:hover {{
    background: rgba(255, 255, 255, 0.13);
    border-color: rgba(255, 255, 255, 0.22);
}}
QPushButton:pressed {{
    background: rgba(255, 255, 255, 0.06);
}}
QPushButton:disabled {{
    background: rgba(255, 255, 255, 0.03);
    color: #55555a;
    border-color: rgba(255, 255, 255, 0.05);
}}
QPushButton#creamPill {{
    background: {ACCENT};
    color: {ACCENT_INK};
    border: 1px solid transparent;
    border-radius: 14px;
    padding: 6px 18px;
    min-height: 20px;
    font-size: 13px;
    font-weight: 700;
}}
QPushButton#creamPill:hover {{
    background: {ACCENT_HOVER};
}}
QPushButton#creamPill:pressed {{
    background: {ACCENT_PRESSED};
}}
QPushButton#creamPill:disabled {{
    background: {ACCENT_DISABLED};
    color: #7c7972;
}}
QPushButton#primary {{
    background: {ACCENT};
    color: {ACCENT_INK};
    border: 1px solid transparent;
    border-radius: 18px;
    padding: 10px 26px;
    min-height: 22px;
    font-size: 14px;
    font-weight: 700;
}}
QPushButton#primary:hover {{
    background: {ACCENT_HOVER};
}}
QPushButton#primary:pressed {{
    background: {ACCENT_PRESSED};
}}
QPushButton#primary:disabled {{
    background: #252422;
    color: #6b6862;
}}
QPushButton#heroPlay {{
    background: {ACCENT};
    color: {ACCENT_INK};
    border: 1px solid transparent;
    border-radius: 22px;
    padding: 10px 28px;
    min-height: 24px;
    font-size: 15px;
    font-weight: 800;
}}
QPushButton#heroPlay:hover {{
    background: {ACCENT_HOVER};
}}
QPushButton#heroPlay:disabled {{
    background: rgba(255, 255, 255, 0.12);
    color: rgba(255, 255, 255, 0.40);
}}
QPushButton#heroSecondary {{
    background: rgba(20, 20, 22, 0.72);
    color: {TEXT};
    border: 1px solid rgba(255, 255, 255, 0.20);
    border-radius: 16px;
    padding: 7px 18px;
    min-height: 20px;
    font-size: 13px;
    font-weight: 600;
}}
QPushButton#heroSecondary:hover {{
    background: rgba(38, 38, 42, 0.88);
    border-color: rgba(255, 255, 255, 0.32);
}}
QPushButton#winCtrlBtn {{
    background: transparent;
    color: rgba(255, 255, 255, 0.72);
    border: none;
    border-radius: 6px;
    padding: 0px;
    min-height: 0px;
    font-size: 13px;
    font-weight: 500;
}}
QPushButton#winCtrlBtn:hover {{
    background: rgba(255, 255, 255, 0.12);
    color: #ffffff;
}}
QPushButton#winCloseBtn {{
    background: transparent;
    color: rgba(255, 255, 255, 0.72);
    border: none;
    border-radius: 6px;
    padding: 0px;
    min-height: 0px;
    font-size: 13px;
    font-weight: 500;
}}
QPushButton#winCloseBtn:hover {{
    background: #e81123;
    color: #ffffff;
}}
QPushButton#danger {{
    background: rgba(255, 97, 97, 0.15);
    color: {RED};
    border: 1px solid rgba(255, 97, 97, 0.35);
    border-radius: 9px;
    padding: 6px 14px;
    font-weight: 600;
}}
QPushButton#danger:hover {{
    background: rgba(255, 97, 97, 0.25);
}}
QPushButton#ghost {{
    background: transparent;
    color: {MUTED};
    border: none;
    border-radius: 8px;
    padding: 5px 10px;
    font-weight: 600;
}}
QPushButton#ghost:hover {{
    background: rgba(255, 255, 255, 0.07);
    color: {TEXT};
}}
QPushButton#navTab {{
    background: transparent;
    color: rgba(255, 255, 255, 0.62);
    border: none;
    border-radius: 9px;
    padding: 7px 16px;
    font-size: 13px;
    font-weight: 500;
}}
QPushButton#navTab:hover {{
    color: rgba(255, 255, 255, 0.88);
    background: rgba(255, 255, 255, 0.05);
}}
QPushButton#navTabActive {{
    background: rgba(255, 255, 255, 0.10);
    color: #ffffff;
    border: none;
    border-radius: 9px;
    padding: 7px 16px;
    font-size: 13px;
    font-weight: 700;
}}
QLineEdit#searchField {{
    background: rgba(255, 255, 255, 0.07);
    color: {TEXT};
    border: 1px solid rgba(255, 255, 255, 0.12);
    border-radius: 16px;
    padding: 5px 14px;
    font-size: 12.5px;
}}
QLineEdit#searchField:focus {{
    border-color: {ACCENT};
    background: rgba(255, 255, 255, 0.10);
}}
QComboBox#launcherDropdown {{
    background: rgba(255, 255, 255, 0.06);
    color: {TEXT};
    border: 1px solid rgba(255, 255, 255, 0.14);
    border-radius: 9px;
    padding: 6px 12px;
    font-size: 13px;
    font-weight: 500;
    min-width: 160px;
}}
QComboBox#launcherDropdown:hover {{
    background: rgba(255, 255, 255, 0.10);
}}
QComboBox#launcherDropdown::drop-down {{
    border: none;
    width: 24px;
}}
QComboBox QAbstractItemView {{
    background: #1f1f23;
    color: {TEXT};
    border: 1px solid {BORDER};
    selection-background-color: {ACCENT};
    selection-color: {ACCENT_INK};
    padding: 4px;
}}
QPlainTextEdit {{
    background: #0d0d0f;
    color: #c7c7cc;
    border: 1px solid #242428;
    border-radius: 10px;
    padding: 10px;
    font-family: "Cascadia Mono", "Consolas", "SF Mono", "Menlo", monospace;
    font-size: 11.5px;
}}
QProgressBar {{
    background: rgba(255, 255, 255, 0.10);
    border: none;
    border-radius: 3px;
    max-height: 6px;
    min-height: 6px;
}}
QProgressBar::chunk {{
    background: {ACCENT};
    border-radius: 3px;
}}
"""

STYLE = STYLESHEET
