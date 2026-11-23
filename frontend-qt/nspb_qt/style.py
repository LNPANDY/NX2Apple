"""Palette and stylesheet aligned with frontend/design-tokens/tokens.json (Dark Glass)."""
from __future__ import annotations

import os
import sys

# Surface & border tokens (aligned with frontend/design-tokens/tokens.json)
BG = '#0e0e0f'
SURFACE = '#141416'
CARD = '#1a1a1c'
SURFACE_RAISED = '#202023'
CARD_HOVER = '#222225'
BORDER = '#2a2a2d'
CARD_EDGE = BORDER
HAIRLINE = 'rgba(255, 255, 255, 0.06)'
SEPARATOR = 'rgba(255, 255, 255, 0.10)'
DIVIDER = SEPARATOR

# Text hierarchy
TEXT = '#f5f5f7'
MUTED = '#a1a1a8'
FAINT = '#787880'
PATH = '#7a7c84'
HINT = '#a8aab0'

# Accent tokens (cream)
ACCENT = '#fff0d6'          # color.accent
CREAM = ACCENT
ACCENT_HOVER = '#fff6e6'
ACCENT_PRESSED = '#e8d7ba'
ACCENT_DISABLED = '#3a3834'
ACCENT_INK = '#000000'      # color.accentOn

# Semantic status tokens
GREEN = '#40d678'           # color.status.ready / success
AMBER = '#ffc73d'           # color.status.warning
ORANGE = AMBER
DANGER = '#ff6b66'          # color.status.error
RED = DANGER
DANGER_FILL = '#d23b36'     # color.status.errorFill (4.75:1 contrast with white label)
DANGER_ON = '#ffffff'       # color.status.errorOn
NEUTRAL_DOT = '#787880'

# Four converged corner radii (tokens.json radius: chip / card / sheet / control)
RADIUS_CHIP = 6
RADIUS_CARD = 12
RADIUS_SHEET = 16
RADIUS_CONTROL = 18

BTN = '#1b1b1e'
BTN_HOVER = '#242428'
BTN_PRESSED = '#2d2d32'
BTN_EDGE = '#2a2a2e'
FIELD = '#161618'
TRACK = '#26262a'
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


def build_dark_palette():
    """Build a dark QPalette aligned with Dark Glass tokens so native dialogs, tooltips,
    and Fusion primitives never flash light chrome."""
    from PySide6.QtGui import QColor, QPalette

    pal = QPalette()
    bg = QColor(BG)
    surface = QColor(SURFACE)
    card = QColor(CARD)
    raised = QColor(SURFACE_RAISED)
    text = QColor(TEXT)
    muted = QColor(MUTED)
    faint = QColor(FAINT)
    accent = QColor(ACCENT)
    accent_ink = QColor(ACCENT_INK)
    danger = QColor(DANGER)

    for group in (QPalette.ColorGroup.Active, QPalette.ColorGroup.Inactive):
        pal.setColor(group, QPalette.ColorRole.Window, bg)
        pal.setColor(group, QPalette.ColorRole.WindowText, text)
        pal.setColor(group, QPalette.ColorRole.Base, surface)
        pal.setColor(group, QPalette.ColorRole.AlternateBase, card)
        pal.setColor(group, QPalette.ColorRole.ToolTipBase, raised)
        pal.setColor(group, QPalette.ColorRole.ToolTipText, text)
        pal.setColor(group, QPalette.ColorRole.Text, text)
        pal.setColor(group, QPalette.ColorRole.Button, card)
        pal.setColor(group, QPalette.ColorRole.ButtonText, text)
        pal.setColor(group, QPalette.ColorRole.BrightText, danger)
        pal.setColor(group, QPalette.ColorRole.Link, accent)
        pal.setColor(group, QPalette.ColorRole.LinkVisited, accent)
        pal.setColor(group, QPalette.ColorRole.Highlight, accent)
        pal.setColor(group, QPalette.ColorRole.HighlightedText, accent_ink)
        if hasattr(QPalette.ColorRole, 'PlaceholderText'):
            pal.setColor(group, QPalette.ColorRole.PlaceholderText, muted)

    pal.setColor(QPalette.ColorGroup.Disabled, QPalette.ColorRole.Window, bg)
    pal.setColor(QPalette.ColorGroup.Disabled, QPalette.ColorRole.WindowText, faint)
    pal.setColor(QPalette.ColorGroup.Disabled, QPalette.ColorRole.Base, surface)
    pal.setColor(QPalette.ColorGroup.Disabled, QPalette.ColorRole.Text, faint)
    pal.setColor(QPalette.ColorGroup.Disabled, QPalette.ColorRole.Button, surface)
    pal.setColor(QPalette.ColorGroup.Disabled, QPalette.ColorRole.ButtonText, faint)
    pal.setColor(QPalette.ColorGroup.Disabled, QPalette.ColorRole.Highlight, QColor(ACCENT_DISABLED))
    pal.setColor(QPalette.ColorGroup.Disabled, QPalette.ColorRole.HighlightedText, muted)
    return pal


def ensure_app_theme(app=None) -> None:
    """Idempotently apply the cross-platform Fusion base style and Dark Glass palette.

    `__main__.py` configures Fusion before creating windows, whereas headless tests instantiate
    a bare `QApplication([])`. Applying Fusion here keeps widget metrics and dark palette roles
    consistent across production launches and offscreen test runs on all platforms.
    """
    from PySide6.QtWidgets import QApplication

    target = app if app is not None else QApplication.instance()
    if target is None or getattr(target, '_nspb_fusion_applied', False):
        return
    target.setStyle('Fusion')
    target.setPalette(build_dark_palette())
    setattr(target, '_nspb_fusion_applied', True)


STYLESHEET = f"""
QMainWindow, QWidget#root {{
    background: {BG};
    color: {TEXT};
    font-family: "Manrope", "Segoe UI", "Inter", -apple-system, "PingFang SC", "Microsoft YaHei", sans-serif;
    font-size: 10pt;
}}
QDialog, QMessageBox {{
    background: {SURFACE};
    color: {TEXT};
    font-family: "Manrope", "Segoe UI", "Inter", -apple-system, "PingFang SC", "Microsoft YaHei", sans-serif;
    font-size: 10pt;
}}
QMessageBox QLabel {{
    color: {TEXT};
    font-size: 10pt;
}}
QToolTip {{
    background: {SURFACE_RAISED};
    color: {TEXT};
    border: 1px solid rgba(255, 255, 255, 0.14);
    border-radius: {RADIUS_CHIP}px;
    padding: 5px 9px;
    font-size: 9pt;
}}
QMenu {{
    background: {SURFACE_RAISED};
    color: {TEXT};
    border: 1px solid rgba(255, 255, 255, 0.12);
    border-radius: {RADIUS_CARD}px;
    padding: 6px;
    font-size: 9.5pt;
}}
QMenu::item {{
    padding: 7px 16px;
    border-radius: {RADIUS_CHIP}px;
    color: {TEXT};
}}
QMenu::item:selected {{
    background: rgba(255, 255, 255, 0.11);
    color: #ffffff;
}}
QMenu::item:disabled {{
    color: {FAINT};
}}
QMenu::separator {{
    height: 1px;
    background: {SEPARATOR};
    margin: 5px 10px;
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
    border: 1px solid {HAIRLINE};
    border-radius: {RADIUS_CARD}px;
}}
QFrame#subcard {{
    background: {SURFACE_RAISED};
    border: 1px solid {HAIRLINE};
    border-radius: {RADIUS_CARD}px;
}}
QFrame#failureCard {{
    background: #231517;
    border: 1px solid rgba(255, 107, 102, 0.38);
    border-radius: {RADIUS_CARD}px;
}}
QFrame#bannerCard {{
    background: #1d1b17;
    border: 1px solid rgba(255, 199, 61, 0.28);
    border-radius: {RADIUS_CARD}px;
}}
QFrame#staleShaderBanner {{
    background: rgba(255, 199, 61, 0.10);
    border: 1px solid rgba(255, 199, 61, 0.30);
    border-radius: {RADIUS_CARD}px;
}}
QFrame#divider {{
    background: {SEPARATOR};
    border: none;
    max-height: 1px;
    min-height: 1px;
}}
QFrame#topBar {{
    background: {BG};
    border-bottom: 1px solid {HAIRLINE};
}}
QFrame#activityBar {{
    background: {SURFACE};
    border-top: 1px solid {HAIRLINE};
}}
QLabel {{
    background: transparent;
    color: {TEXT};
}}
QLabel#pageTitle {{
    font-size: 25pt;
    font-weight: 800;
    color: {TEXT};
}}
QLabel#pageNote {{
    font-size: 10.5pt;
    color: {MUTED};
}}
QLabel#sectionTitle {{
    font-size: 11pt;
    font-weight: 600;
    color: {MUTED};
}}
QLabel#sectionFoot {{
    font-size: 8.5pt;
    color: {FAINT};
}}
QLabel#rowTitle {{
    font-size: 10pt;
    font-weight: 600;
    color: {TEXT};
}}
QLabel#muted {{
    color: {MUTED};
    font-size: 9pt;
}}
QLabel#faint {{
    color: {FAINT};
    font-size: 8.5pt;
}}
QLabel#mono {{
    color: {MUTED};
    font-family: {MONO};
    font-size: 9pt;
}}
QPushButton {{
    background: rgba(255, 255, 255, 0.07);
    color: {TEXT};
    border: 1px solid rgba(255, 255, 255, 0.11);
    border-radius: {RADIUS_CARD}px;
    padding: 6px 16px;
    min-height: 20px;
    font-weight: 600;
    font-size: 9.5pt;
    outline: none;
}}
QPushButton:hover {{
    background: rgba(255, 255, 255, 0.12);
    border-color: rgba(255, 255, 255, 0.20);
}}
QPushButton:pressed {{
    background: rgba(255, 255, 255, 0.05);
}}
QPushButton[kbFocus="true"]:focus {{
    border: 2px solid {ACCENT};
}}
QPushButton:disabled {{
    background: rgba(255, 255, 255, 0.03);
    color: #5a5a62;
    border-color: rgba(255, 255, 255, 0.05);
}}
QPushButton#creamPill {{
    background: {ACCENT};
    color: {ACCENT_INK};
    border: 1px solid transparent;
    border-radius: {RADIUS_SHEET}px;
    padding: 6px 18px;
    min-height: 20px;
    font-size: 9.5pt;
    font-weight: 700;
    outline: none;
}}
QPushButton#creamPill:hover {{
    background: {ACCENT_HOVER};
}}
QPushButton#creamPill:pressed {{
    background: {ACCENT_PRESSED};
}}
QPushButton#creamPill[kbFocus="true"]:focus {{
    border: 2px solid #ffffff;
}}
QPushButton#creamPill:disabled {{
    background: {ACCENT_DISABLED};
    color: #84817a;
}}
QPushButton#creamOutlinePill {{
    background: rgba(255, 240, 214, 0.09);
    color: {ACCENT};
    border: 1px solid rgba(255, 240, 214, 0.38);
    border-radius: {RADIUS_SHEET}px;
    padding: 6px 18px;
    min-height: 20px;
    font-size: 9.5pt;
    font-weight: 700;
    outline: none;
}}
QPushButton#creamOutlinePill:hover {{
    background: rgba(255, 240, 214, 0.16);
    border-color: rgba(255, 240, 214, 0.58);
}}
QPushButton#creamOutlinePill:pressed {{
    background: rgba(255, 240, 214, 0.06);
}}
QPushButton#creamOutlinePill[kbFocus="true"]:focus {{
    border: 2px solid {ACCENT};
}}
QPushButton#creamOutlinePill:disabled {{
    background: rgba(255, 255, 255, 0.03);
    color: #5a5a62;
    border-color: rgba(255, 255, 255, 0.06);
}}
QPushButton#primary {{
    background: {ACCENT};
    color: {ACCENT_INK};
    border: 1px solid transparent;
    border-radius: {RADIUS_CONTROL}px;
    padding: 9px 26px;
    min-height: 22px;
    font-size: 10.5pt;
    font-weight: 700;
    outline: none;
}}
QPushButton#primary:hover {{
    background: {ACCENT_HOVER};
}}
QPushButton#primary:pressed {{
    background: {ACCENT_PRESSED};
}}
QPushButton#primary[kbFocus="true"]:focus {{
    border: 2px solid #ffffff;
}}
QPushButton#primary:disabled {{
    background: #262523;
    color: #706d67;
}}
QPushButton#heroPlay {{
    background: {ACCENT};
    color: {ACCENT_INK};
    border: 1px solid transparent;
    border-radius: {RADIUS_CONTROL}px;
    padding: 10px 28px;
    min-height: 24px;
    font-size: 11pt;
    font-weight: 800;
    outline: none;
}}
QPushButton#heroPlay:hover {{
    background: {ACCENT_HOVER};
}}
QPushButton#heroPlay:pressed {{
    background: {ACCENT_PRESSED};
}}
QPushButton#heroPlay[kbFocus="true"]:focus {{
    border: 2px solid #ffffff;
}}
QPushButton#heroPlay:disabled {{
    background: rgba(255, 255, 255, 0.12);
    color: rgba(255, 255, 255, 0.40);
}}
QPushButton#heroSecondary {{
    background: rgba(26, 26, 28, 0.76);
    color: {TEXT};
    border: 1px solid rgba(255, 255, 255, 0.18);
    border-radius: {RADIUS_SHEET}px;
    padding: 7px 18px;
    min-height: 20px;
    font-size: 9.5pt;
    font-weight: 600;
    outline: none;
}}
QPushButton#heroSecondary:hover {{
    background: rgba(40, 40, 44, 0.90);
    border-color: rgba(255, 255, 255, 0.30);
}}
QPushButton#heroSecondary:pressed {{
    background: rgba(20, 20, 22, 0.88);
}}
QPushButton#heroSecondary[kbFocus="true"]:focus {{
    border: 2px solid {ACCENT};
}}
QPushButton#heroSecondary:disabled {{
    background: rgba(26, 26, 28, 0.45);
    color: rgba(255, 255, 255, 0.36);
    border-color: rgba(255, 255, 255, 0.08);
}}
QPushButton#iconBtn {{
    background: transparent;
    color: {MUTED};
    border: 1px solid transparent;
    border-radius: {RADIUS_SHEET}px;
    padding: 0px;
    min-height: 0px;
    outline: none;
}}
QPushButton#iconBtn:hover {{
    background: rgba(255, 255, 255, 0.08);
    color: {TEXT};
}}
QPushButton#iconBtn[kbFocus="true"]:focus {{
    border: 2px solid {ACCENT};
}}
QPushButton#iconBtnActive {{
    background: rgba(255, 240, 214, 0.14);
    color: {ACCENT};
    border: 1px solid rgba(255, 240, 214, 0.32);
    border-radius: {RADIUS_SHEET}px;
    padding: 0px;
    min-height: 0px;
    outline: none;
}}
QPushButton#iconBtnActive:hover {{
    background: rgba(255, 240, 214, 0.20);
}}
QPushButton#iconBtnActive[kbFocus="true"]:focus {{
    border: 2px solid {ACCENT};
}}
QPushButton#winCtrlBtn {{
    background: transparent;
    color: rgba(255, 255, 255, 0.72);
    border: 1px solid transparent;
    border-radius: {RADIUS_CHIP}px;
    padding: 0px;
    min-height: 0px;
    outline: none;
}}
QPushButton#winCtrlBtn:hover {{
    background: rgba(255, 255, 255, 0.11);
    color: #ffffff;
}}
QPushButton#winCtrlBtn[kbFocus="true"]:focus {{
    border: 2px solid {ACCENT};
}}
QPushButton#winCloseBtn {{
    background: transparent;
    color: rgba(255, 255, 255, 0.72);
    border: 1px solid transparent;
    border-radius: {RADIUS_CHIP}px;
    padding: 0px;
    min-height: 0px;
    outline: none;
}}
QPushButton#winCloseBtn:hover {{
    background: {DANGER_FILL};
    color: {DANGER_ON};
}}
QPushButton#winCloseBtn[kbFocus="true"]:focus {{
    border: 2px solid {ACCENT};
}}
QPushButton#danger {{
    background: {DANGER_FILL};
    color: {DANGER_ON};
    border: 1px solid rgba(255, 107, 102, 0.45);
    border-radius: {RADIUS_CARD}px;
    padding: 6px 16px;
    min-height: 20px;
    font-weight: 600;
    font-size: 9.5pt;
    outline: none;
}}
QPushButton#danger:hover {{
    background: #e04640;
}}
QPushButton#danger:pressed {{
    background: #b8302c;
}}
QPushButton#danger[kbFocus="true"]:focus {{
    border: 2px solid {ACCENT};
}}
QPushButton#danger:disabled {{
    background: rgba(210, 59, 54, 0.28);
    color: rgba(255, 255, 255, 0.42);
    border-color: rgba(255, 107, 102, 0.16);
}}
QPushButton#ghost {{
    background: transparent;
    color: {MUTED};
    border: 1px solid transparent;
    border-radius: {RADIUS_CHIP}px;
    padding: 5px 10px;
    min-height: 18px;
    font-weight: 600;
    font-size: 9.5pt;
    outline: none;
}}
QPushButton#ghost:hover {{
    background: rgba(255, 255, 255, 0.07);
    color: {TEXT};
}}
QPushButton#ghost[kbFocus="true"]:focus {{
    border: 2px solid {ACCENT};
}}
QToolButton {{
    background: transparent;
    color: {MUTED};
    border: 1px solid transparent;
    border-radius: {RADIUS_CHIP}px;
    padding: 4px 8px;
    font-size: 9.5pt;
    font-weight: 600;
    outline: none;
}}
QToolButton:hover {{
    background: rgba(255, 255, 255, 0.07);
    color: {TEXT};
}}
QToolButton[kbFocus="true"]:focus {{
    border: 2px solid {ACCENT};
}}
QLineEdit#searchField {{
    background: rgba(255, 255, 255, 0.07);
    color: {TEXT};
    border: 1px solid rgba(255, 255, 255, 0.11);
    border-radius: {RADIUS_SHEET}px;
    padding: 5px 14px;
    font-size: 9.5pt;
    selection-background-color: {ACCENT};
    selection-color: {ACCENT_INK};
}}
QLineEdit#searchField:hover {{
    background: rgba(255, 255, 255, 0.09);
    border-color: rgba(255, 255, 255, 0.18);
}}
QLineEdit#searchField:focus {{
    border: 2px solid {ACCENT};
    background: rgba(255, 255, 255, 0.10);
}}
QCheckBox {{
    color: {TEXT};
    spacing: 8px;
    font-size: 9.5pt;
    font-weight: 500;
    outline: none;
}}
QCheckBox:disabled {{
    color: {FAINT};
}}
QCheckBox::indicator {{
    width: 16px;
    height: 16px;
    border-radius: 4px;
    background: rgba(255, 255, 255, 0.06);
    border: 1px solid rgba(255, 255, 255, 0.24);
}}
QCheckBox::indicator:hover {{
    border-color: rgba(255, 240, 214, 0.65);
    background: rgba(255, 255, 255, 0.10);
}}
QCheckBox::indicator:checked {{
    background: {ACCENT};
    border: 1px solid {ACCENT};
}}
QCheckBox::indicator:disabled {{
    background: rgba(255, 255, 255, 0.03);
    border-color: rgba(255, 255, 255, 0.10);
}}
QCheckBox[kbFocus="true"]:focus {{
    color: {ACCENT};
}}
QCheckBox[kbFocus="true"]:focus::indicator {{
    border: 2px solid {ACCENT};
}}
QCheckBox#platformChipCheck {{
    background: rgba(255, 255, 255, 0.05);
    border: 1px solid rgba(255, 255, 255, 0.12);
    border-radius: {RADIUS_CHIP}px;
    padding: 4px 10px 4px 8px;
    color: {TEXT};
    font-size: 9pt;
    font-weight: 600;
}}
QCheckBox#platformChipCheck:hover {{
    background: rgba(255, 255, 255, 0.09);
    border-color: rgba(255, 255, 255, 0.22);
}}
QCheckBox#platformChipCheck:checked {{
    background: rgba(255, 240, 214, 0.12);
    border-color: rgba(255, 240, 214, 0.42);
    color: {ACCENT};
}}
QCheckBox#platformChipCheck:disabled {{
    background: rgba(255, 255, 255, 0.02);
    border-color: rgba(255, 255, 255, 0.06);
    color: {FAINT};
}}
QCheckBox#platformChipCheck[kbFocus="true"]:focus {{
    border: 2px solid {ACCENT};
}}
QComboBox#launcherDropdown {{
    background: rgba(255, 255, 255, 0.06);
    color: {TEXT};
    border: 1px solid rgba(255, 255, 255, 0.12);
    border-radius: {RADIUS_CARD}px;
    padding: 6px 28px 6px 12px;
    font-size: 9.5pt;
    font-weight: 500;
    min-width: 148px;
    outline: none;
}}
QComboBox#launcherDropdown:hover {{
    background: rgba(255, 255, 255, 0.10);
    border-color: rgba(255, 255, 255, 0.20);
}}
QComboBox#launcherDropdown[kbFocus="true"]:focus {{
    border: 2px solid {ACCENT};
}}
QComboBox#launcherDropdown::drop-down {{
    border: none;
    width: 26px;
}}
QComboBox#launcherDropdown::down-arrow {{
    image: none;
    border: none;
    width: 0px;
    height: 0px;
}}
QComboBox QAbstractItemView {{
    background: {SURFACE_RAISED};
    color: {TEXT};
    border: 1px solid rgba(255, 255, 255, 0.14);
    border-radius: {RADIUS_CARD}px;
    selection-background-color: {ACCENT};
    selection-color: {ACCENT_INK};
    padding: 4px;
    outline: none;
}}
QPlainTextEdit {{
    background: {BG};
    color: #c7c7cc;
    border: 1px solid {HAIRLINE};
    border-radius: {RADIUS_CARD}px;
    padding: 10px;
    font-family: {MONO};
    font-size: 9pt;
    selection-background-color: {ACCENT};
    selection-color: {ACCENT_INK};
}}
QPlainTextEdit:focus {{
    border: 1px solid rgba(255, 240, 214, 0.45);
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
