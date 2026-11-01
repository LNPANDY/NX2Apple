"""Visual language: the Mac launcher's near-black look with a cream accent, in Qt style sheets.

The palette, the Manrope typeface and the control shapes follow the SwiftUI launcher
(`frontend/Sources/NSPortBuilder/LauncherView.swift` LauncherPalette and `LauncherStyles.swift`),
so the two front ends stay recognisable as the same product. The translucent white fills of the
Mac controls are pre-mixed here into opaque colours, since a Qt style sheet has no cheap overlay.
"""
from __future__ import annotations

import os
import sys

# The palette: LauncherPalette's values as hex.
BG = '#0e0e0f'          # window background, rgb(0.055, 0.055, 0.06)
CARD = '#1a1a1c'        # a card's fill (the launcher's "surface"), rgb(0.10, 0.10, 0.11)
CARD_EDGE = '#2c2c2e'   # a card's hairline: white at 8% over the surface
TEXT = '#ebebeb'        # white at 92%, as the launcher's button labels
MUTED = '#91949c'       # the launcher's "unbuilt" grey
PATH = '#6f7178'    # a filesystem path in a dependency row: dimmer than prose, so the eye
                    # reads the hint beside it first (the report asked for exactly this)
HINT = '#a8aab0'    # a hint or explanation: a step brighter than the path it sits next to
CREAM = '#fff0d6'       # the accent: primary buttons, switches, the chosen choice
GREEN = '#40d678'       # ok / done: the launcher's "ready"
ORANGE = '#ffc73d'      # attention: the launcher's "building"
RED = '#ff6b66'         # missing / failed: the launcher's destructive red

# Controls, as white over the background at the launcher's opacities.
BTN = '#1b1b1c'         # white 5.5%
BTN_HOVER = '#242425'   # white 9%
BTN_PRESSED = '#2d2d2e' # white 13%
BTN_EDGE = '#262627'    # white 10%
FIELD = '#161617'       # an input: a touch above the background
TRACK = '#262627'       # a slider or progress track: white 10%

MONO = 'Menlo, Consolas, monospace'


def _font_file():
    """Manrope.ttf: in the bundle's `fonts` folder in a frozen build (build-qt.yml adds it), in
    the repository's frontend/fonts, the copy the Mac app embeds, in a source run."""
    if getattr(sys, 'frozen', False):
        base = getattr(sys, '_MEIPASS', os.path.dirname(sys.executable))
        candidates = [os.path.join(base, 'fonts', 'Manrope.ttf'),
                      os.path.join(os.path.dirname(sys.executable), 'fonts', 'Manrope.ttf')]
    else:
        here = os.path.dirname(os.path.abspath(__file__))
        candidates = [os.path.join(here, '..', '..', 'frontend', 'fonts', 'Manrope.ttf')]
    for c in candidates:
        if os.path.isfile(c):
            return c
    return None


def load_font() -> str:
    """Registers Manrope with Qt and returns its family name, or '' (keep the system font)
    when the file is missing or Qt rejects it."""
    path = _font_file()
    if path is None:
        return ''
    from PySide6.QtGui import QFontDatabase
    fid = QFontDatabase.addApplicationFont(path)
    families = QFontDatabase.applicationFontFamilies(fid) if fid >= 0 else []
    # The TTF's legacy family name is "Manrope ExtraLight" (a variable font), so prefer the
    # "Manrope" family the stylesheet and Qt's matching use, and fall back to what Qt reports.
    if 'Manrope' in families:
        return 'Manrope'
    return families[0] if families else ''


STYLE = f"""
QMainWindow, QDialog, QScrollArea, QWidget#body {{
    background: {BG};
}}
QWidget {{
    color: {TEXT};
    font-size: 9pt;   /* pt, not px: a handheld at 150% scaling keeps readable text and a window that fits */
}}
QLabel {{
    background: transparent;
}}

QScrollArea > QWidget > QWidget {{
    background: {BG};
}}

/* ---- cards: a plain frame, the title is a label inside it ---- */
QFrame#card {{
    background: {CARD};
    border: 1px solid {CARD_EDGE};
    border-radius: 10px;
}}

/* ---- buttons: white 5.5% on the background, a 10% hairline, radius 9 ---- */
QPushButton {{
    background: {BTN};
    border: 1px solid {BTN_EDGE};
    border-radius: 9px;
    padding: 4px 7px;   /* compact: a 7-inch panel must fit the whole form */
    color: {TEXT};
    font-weight: 600;
}}
QPushButton:hover {{ background: {BTN_HOVER}; }}
QPushButton:pressed {{ background: {BTN_PRESSED}; }}
QPushButton:disabled {{ color: #5a5b60; background: {BTN}; border-color: #1e1e1f; }}

/* the primary action: cream fill, dark text */
QPushButton#primary {{
    background: {CREAM};
    border: 1px solid {CREAM};
    color: {BG};
    font-size: 10pt;
    font-weight: 700;
    padding: 6px 16px;
}}
QPushButton#primary:hover {{ background: #fff6e6; border-color: #fff6e6; }}
QPushButton#primary:pressed {{ background: #e8d9bf; border-color: #e8d9bf; }}
QPushButton#primary:disabled {{ background: #2a2822; border-color: #2a2822; color: #6d6a62; }}

/* a stop or destructive action: the secondary button in red, as the build bar's Stop */
QPushButton#danger {{
    background: {BTN};
    border: 1px solid #a14a48;
    color: {RED};
    font-size: 10pt;
    font-weight: 600;
    padding: 6px 16px;
}}
QPushButton#danger:hover {{ background: {BTN_HOVER}; }}

/* ---- labels ---- */
QLabel#title {{ font-size: 17pt; font-weight: 800; background: transparent; }}
QLabel#subtitle {{ color: {MUTED}; font-size: 9pt; background: transparent; }}
QLabel#note {{ color: {HINT}; font-size: 8pt; background: transparent; }}
QLabel#mono {{ color: {PATH}; font-family: {MONO}; font-size: 8pt; background: transparent; }}
QLabel#ok {{ color: {GREEN}; font-weight: 600; background: transparent; }}
QLabel#warn {{ color: {ORANGE}; font-weight: 600; }}
QLabel#bad {{ color: {RED}; font-weight: 600; background: transparent; }}
QLabel#rowname {{ font-size: 10pt; background: transparent; }}
QLabel#footer {{ color: {MUTED}; font-size: 8pt; padding: 4px 2px; background: transparent; }}

/* ---- the log ---- */
QTextEdit {{
    background: {FIELD};
    border: 1px solid {CARD_EDGE};
    border-radius: 10px;
    padding: 8px;
    color: #b9bbc1;
    font-family: {MONO};
    font-size: 8pt;
    selection-background-color: #5a5445;
    selection-color: {TEXT};
}}

/* ---- progress ---- */
QProgressBar {{
    background: {TRACK};
    border: none;
    border-radius: 4px;
    height: 7px;
    text-align: center;
    color: transparent;
}}
QProgressBar::chunk {{
    background: {GREEN};
    border-radius: 4px;
}}

/* ---- scrollbars ---- */
QScrollBar:vertical {{
    background: transparent;
    width: 10px;
    margin: 0;
}}
QScrollBar::handle:vertical {{
    background: #34343a;
    border-radius: 5px;
    min-height: 30px;
}}
QScrollBar::handle:vertical:hover {{ background: #46464d; }}
QScrollBar::add-line:vertical, QScrollBar::sub-line:vertical {{ height: 0; }}
QScrollBar::add-page:vertical, QScrollBar::sub-page:vertical {{ background: transparent; }}
QScrollBar:horizontal {{
    background: transparent;
    height: 10px;
    margin: 0;
}}
QScrollBar::handle:horizontal {{
    background: #34343a;
    border-radius: 5px;
    min-width: 30px;
}}
QScrollBar::handle:horizontal:hover {{ background: #46464d; }}
QScrollBar::add-line:horizontal, QScrollBar::sub-line:horizontal {{ width: 0; }}
QScrollBar::add-page:horizontal, QScrollBar::sub-page:horizontal {{ background: transparent; }}

/* ---- dialogs inherit the dark look ---- */
QFileDialog, QMessageBox, QInputDialog {{ background: {BG}; }}
QLineEdit {{
    background: {FIELD};
    border: 1px solid {BTN_EDGE};
    border-radius: 9px;
    padding: 5px 9px;
    color: {TEXT};
    selection-background-color: #5a5445;
    selection-color: {TEXT};
}}
QLineEdit:focus {{ border-color: {CREAM}; }}

/* ---- menus and tooltips ---- */
QMenu {{
    background: {CARD};
    border: 1px solid {CARD_EDGE};
    border-radius: 9px;
    padding: 6px;
}}
QMenu::item {{ padding: 6px 14px; border-radius: 7px; }}
QMenu::item:selected {{ background: {BTN_PRESSED}; }}
QMenu::item:disabled {{ color: #5a5b60; }}
QMenu::separator {{ height: 1px; background: {CARD_EDGE}; margin: 4px 6px; }}
QToolTip {{
    background: {CARD};
    color: {TEXT};
    border: 1px solid {CARD_EDGE};
    padding: 4px 6px;
}}
"""
