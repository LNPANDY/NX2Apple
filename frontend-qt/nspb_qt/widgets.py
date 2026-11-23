"""Custom QPainter widgets, inline vector icons, and card primitives aligned with Dark Glass tokens."""
from __future__ import annotations

import re

from PySide6.QtCore import QByteArray, QEvent, QObject, QPointF, QRectF, QSize, Qt, Signal
from PySide6.QtGui import (
    QColor,
    QFont,
    QFontMetrics,
    QIcon,
    QKeyEvent,
    QLinearGradient,
    QMouseEvent,
    QPainter,
    QPainterPath,
    QPen,
    QPixmap,
    QSyntaxHighlighter,
    QTextCharFormat,
    QWheelEvent,
)
from PySide6.QtWidgets import (
    QAbstractButton,
    QApplication,
    QCheckBox,
    QComboBox,
    QFrame,
    QHBoxLayout,
    QLabel,
    QLineEdit,
    QPlainTextEdit,
    QPushButton,
    QSizePolicy,
    QStyle,
    QStyleOptionButton,
    QVBoxLayout,
    QWidget,
)

try:
    import shiboken6
except ImportError:  # pragma: no cover - headless stub environments
    shiboken6 = None  # type: ignore[assignment]

from . import style

_KEYBOARD_FOCUS_REASONS = (
    Qt.TabFocusReason,
    Qt.BacktabFocusReason,
    Qt.ShortcutFocusReason,
)

_FOCUS_FILTER_EVENTS = (
    QEvent.Type.FocusIn,
    QEvent.Type.FocusOut,
    QEvent.Type.MouseButtonPress,
)


def _is_valid_qobject(obj: object) -> bool:
    if obj is None:
        return False
    if shiboken6 is not None:
        try:
            return bool(shiboken6.isValid(obj))
        except Exception:
            return False
    return True


class KeyboardFocusFilter(QObject):
    """Widget-scoped event filter providing CSS :focus-visible semantics via dynamic property `kbFocus`."""

    def eventFilter(self, watched: QObject, event: QEvent) -> bool:
        if event is None:
            return False
        etype = event.type()
        if etype not in _FOCUS_FILTER_EVENTS:
            return False
        if not _is_valid_qobject(watched) or not isinstance(watched, QWidget):
            return False
        if isinstance(watched, (QLineEdit, QPlainTextEdit)):
            return False
        if etype == QEvent.Type.FocusIn:
            reason_fn = getattr(event, 'reason', None)
            reason = reason_fn() if callable(reason_fn) else None
            is_kb = reason in _KEYBOARD_FOCUS_REASONS
            self._set_kb_focus(watched, is_kb, repolish=True)
        elif etype == QEvent.Type.FocusOut:
            try:
                had_kb = bool(watched.property('kbFocus'))
            except RuntimeError:
                return False
            if had_kb:
                # On FocusOut, skip unpolish/polish to avoid touching half-destroyed widgets
                # during ~QWidget(), and mark _kbPolishDirty so a subsequent pointer FocusIn
                # or MouseButtonPress repolishes away the cached cream border.
                self._set_kb_focus(watched, False, repolish=False)
        elif etype == QEvent.Type.MouseButtonPress:
            try:
                had_kb = bool(watched.property('kbFocus'))
                dirty = bool(watched.property('_kbPolishDirty'))
            except RuntimeError:
                return False
            if had_kb or dirty:
                self._set_kb_focus(watched, False, repolish=True)
        return False

    @staticmethod
    def _set_kb_focus(widget: QWidget, active: bool, *, repolish: bool = True) -> None:
        if not _is_valid_qobject(widget):
            return
        try:
            cur_kb = bool(widget.property('kbFocus'))
            dirty = bool(widget.property('_kbPolishDirty'))
            if cur_kb == active and (not repolish or not dirty):
                return
            widget.setProperty('kbFocus', active)
            if not repolish:
                if cur_kb != active:
                    widget.setProperty('_kbPolishDirty', True)
            else:
                did_repolish = False
                if widget.isVisible():
                    win = widget.window()
                    if _is_valid_qobject(win) and win.isVisible() and not getattr(win, '_window_closed', False):
                        st = widget.style()
                        if _is_valid_qobject(st):
                            st.unpolish(widget)
                            st.polish(widget)
                            did_repolish = True
                if did_repolish or not dirty:
                    widget.setProperty('_kbPolishDirty', False)
            if widget.isVisible():
                widget.update()
        except RuntimeError:
            pass


def install_keyboard_focus_filter(target: QObject | None = None) -> KeyboardFocusFilter | None:
    """Install `KeyboardFocusFilter` on interactive child controls under a `QWidget` subtree.

    Never installs an application-wide filter on `QApplication` because routing every internal C++
    `QObject` event (`ChildRemoved`, `Destroy`, `DeferredDelete`, platform backing stores) through a
    Shiboken Python wrapper triggers polymorphic RTTI / half-destroyed vtable crashes on Windows MSVC.
    """
    if target is None or not isinstance(target, QWidget) or not _is_valid_qobject(target):
        return None
    win = target.window()
    host = win if isinstance(win, QWidget) and _is_valid_qobject(win) else target
    existing = getattr(host, '_nspb_kb_focus_filter', None)
    if isinstance(existing, KeyboardFocusFilter) and _is_valid_qobject(existing):
        flt = existing
    else:
        flt = KeyboardFocusFilter(host)
        setattr(host, '_nspb_kb_focus_filter', flt)

    candidates: list[QWidget] = []
    if isinstance(target, (QAbstractButton, QComboBox)):
        candidates.append(target)
    candidates.extend(target.findChildren(QAbstractButton))
    candidates.extend(target.findChildren(QComboBox))

    for w in candidates:
        if not _is_valid_qobject(w):
            continue
        if w.objectName().startswith('qt_') or isinstance(w.parentWidget(), (QLineEdit, QPlainTextEdit)):
            continue
        if not getattr(w, '_nspb_kb_flt_attached', False):
            w.installEventFilter(flt)
            setattr(w, '_nspb_kb_flt_attached', True)
    return flt


# ---------------------------------------------------------------- inline monochrome SVG icons


def render_svg_pixmap(svg_markup: str, size: int, *, dpr: float = 2.0) -> QPixmap:
    """Render an inline monochrome SVG string to a crisp HiDPI QPixmap."""
    px = max(1, int(round(size * dpr)))
    pm = QPixmap(px, px)
    pm.setDevicePixelRatio(dpr)
    pm.fill(Qt.transparent)
    try:
        from PySide6.QtSvg import QSvgRenderer
    except ImportError:
        return pm
    renderer = QSvgRenderer(QByteArray(svg_markup.encode('utf-8')))
    if not renderer.isValid():
        return pm
    p = QPainter(pm)
    p.setRenderHint(QPainter.Antialiasing)
    p.setRenderHint(QPainter.SmoothPixmapTransform)
    renderer.render(p, QRectF(0.0, 0.0, float(size), float(size)))
    p.end()
    return pm


def render_svg_icon(svg_markup: str, size: int, *, dpr: float = 2.0) -> QIcon:
    return QIcon(render_svg_pixmap(svg_markup, size, dpr=dpr))


def _svg_wrap(body: str, viewbox: str = '0 0 24 24') -> str:
    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{viewbox}" fill="none">{body}</svg>'


def svg_gamepad(color: str = style.ACCENT) -> str:
    return _svg_wrap(
        f'<rect x="2.5" y="6.5" width="19" height="11" rx="5.5" stroke="{color}" stroke-width="1.6"/>'
        f'<path d="M8.5 9.5v5M6 12h5" stroke="{color}" stroke-width="1.6" stroke-linecap="round"/>'
        f'<circle cx="15.7" cy="10.7" r="1.1" fill="{color}"/>'
        f'<circle cx="17.8" cy="13.1" r="1.1" fill="{color}"/>'
    )


def svg_settings(color: str = style.MUTED) -> str:
    return _svg_wrap(
        f'<circle cx="12" cy="12" r="3.2" stroke="{color}" stroke-width="1.6"/>'
        f'<path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06'
        f'a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 1 1-4 0v-.09'
        f'a1.65 1.65 0 0 0-1.08-1.51 1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06'
        f'a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 1 1 0-4h.09'
        f'a1.65 1.65 0 0 0 1.51-1.08 1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06'
        f'a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 1 1 4 0v.09'
        f'a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06'
        f'a1.65 1.65 0 0 0-.33 1.82V9c.26.6.85 1 1.51 1H21a2 2 0 1 1 0 4h-.09'
        f'a1.65 1.65 0 0 0-1.51 1Z" stroke="{color}" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>'
    )


def svg_win_minimize(color: str = '#c7c7cc') -> str:
    return _svg_wrap(f'<path d="M5 12h14" stroke="{color}" stroke-width="1.7" stroke-linecap="round"/>')


def svg_win_maximize(color: str = '#c7c7cc') -> str:
    return _svg_wrap(f'<rect x="5.5" y="5.5" width="13" height="13" rx="2" stroke="{color}" stroke-width="1.6"/>')


def svg_win_restore(color: str = '#c7c7cc') -> str:
    return _svg_wrap(
        f'<rect x="5" y="8" width="10.5" height="10.5" rx="1.8" stroke="{color}" stroke-width="1.5"/>'
        f'<path d="M8.5 8V6.8A1.8 1.8 0 0 1 10.3 5h6.9A1.8 1.8 0 0 1 19 6.8v6.9a1.8 1.8 0 0 1-1.8 1.8H15.5" '
        f'stroke="{color}" stroke-width="1.5" stroke-linecap="round"/>'
    )


def svg_win_close(color: str = '#c7c7cc') -> str:
    return _svg_wrap(
        f'<path d="M6 6l12 12M18 6L6 18" stroke="{color}" stroke-width="1.7" stroke-linecap="round"/>'
    )


def svg_chevron_left(color: str = '#e5e5ea') -> str:
    return _svg_wrap(
        f'<path d="M14.5 6.5L9 12l5.5 5.5" stroke="{color}" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/>'
    )


def svg_chevron_right(color: str = '#e5e5ea') -> str:
    return _svg_wrap(
        f'<path d="M9.5 6.5L15 12l-5.5 5.5" stroke="{color}" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/>'
    )


def svg_chevron_down(color: str = style.MUTED) -> str:
    return _svg_wrap(
        f'<path d="M6.5 9.5L12 15l5.5-5.5" stroke="{color}" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/>'
    )


# ---------------------------------------------------------------- utility primitives


class CenteredColumnWidget(QWidget):
    """Host page widget that centers its layout within a readable max width (920px).

    Uses a pure Qt `QHBoxLayout` with balanced side stretches and a `maxWidth`-capped
    column container rather than mutating `contentsMargins` inside `resizeEvent`.
    Mutating layout margins during `resizeEvent` inside `QScrollArea(widgetResizable=True)`
    inflates `minimumSizeHint()` by `2 * side`, triggering a positive-feedback resize loop
    that overflows the 1 MB Win32 main-thread stack (`0xC00000FD`).
    """

    def __init__(
        self,
        *,
        max_width: int = 920,
        min_h_margin: int = 28,
        top_margin: int = 28,
        bottom_margin: int = 36,
        spacing: int = 20,
        parent: QWidget | None = None,
    ) -> None:
        super().__init__(parent)
        self.max_width = max_width
        self._min_h_margin = min_h_margin
        self._top_margin = top_margin
        self._bottom_margin = bottom_margin
        self.setMinimumWidth(0)
        self.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Preferred)

        outer = QHBoxLayout(self)
        outer.setContentsMargins(min_h_margin, top_margin, min_h_margin, bottom_margin)
        outer.setSpacing(0)

        self.column_host = QWidget(self)
        self.column_host.setMaximumWidth(max_width)
        self.column_host.setMinimumWidth(0)
        self.column_host.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Preferred)

        self.body_col = QVBoxLayout(self.column_host)
        self.body_col.setContentsMargins(0, 0, 0, 0)
        self.body_col.setSpacing(spacing)

        outer.addStretch(1)
        outer.addWidget(self.column_host, 1000)
        outer.addStretch(1)

    def minimumSizeHint(self) -> QSize:
        return QSize(0, super().minimumSizeHint().height())


class LauncherCheckBox(QCheckBox):
    """Dark Glass QCheckBox that paints a crisp ink checkmark inside the cream checked indicator."""

    def paintEvent(self, event) -> None:
        super().paintEvent(event)
        if not self.isChecked():
            return
        opt = QStyleOptionButton()
        self.initStyleOption(opt)
        ind = self.style().subElementRect(QStyle.SubElement.SE_CheckBoxIndicator, opt, self)
        if not ind.isValid():
            return
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        ink = QColor(style.ACCENT_INK if self.isEnabled() else style.FAINT)
        pen = QPen(ink, 2.0, Qt.SolidLine, Qt.RoundCap, Qt.RoundJoin)
        p.setPen(pen)
        cx = float(ind.center().x())
        cy = float(ind.center().y())
        p.drawLine(QPointF(cx - 3.6, cy + 0.2), QPointF(cx - 1.0, cy + 3.0))
        p.drawLine(QPointF(cx - 1.0, cy + 3.0), QPointF(cx + 4.0, cy - 2.8))
        p.end()


class LauncherComboBox(QComboBox):
    """Dark Glass QComboBox with crisp anti-aliased chevron indicator."""

    def __init__(self, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self._show_focus_ring = False
        self.setObjectName('launcherDropdown')
        self.setFocusPolicy(Qt.StrongFocus)

    def focusInEvent(self, event) -> None:
        self._show_focus_ring = event.reason() in _KEYBOARD_FOCUS_REASONS
        self.update()
        super().focusInEvent(event)

    def focusOutEvent(self, event) -> None:
        self._show_focus_ring = False
        self.update()
        super().focusOutEvent(event)

    def mousePressEvent(self, event: QMouseEvent) -> None:
        self._show_focus_ring = False
        self.update()
        super().mousePressEvent(event)

    def paintEvent(self, event) -> None:
        super().paintEvent(event)
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        cx = float(self.width()) - 15.0
        cy = float(self.height()) / 2.0
        color = QColor(style.ACCENT if (self.hasFocus() and self._show_focus_ring) else style.MUTED)
        if not self.isEnabled():
            color = QColor(style.FAINT)
        pen = QPen(color, 1.6, Qt.SolidLine, Qt.RoundCap, Qt.RoundJoin)
        p.setPen(pen)
        p.drawLine(QPointF(cx - 4.0, cy - 2.0), QPointF(cx, cy + 2.5))
        p.drawLine(QPointF(cx, cy + 2.5), QPointF(cx + 4.0, cy - 2.0))
        p.end()


class BuildLogHighlighter(QSyntaxHighlighter):
    """Lightweight QSyntaxHighlighter coloring ERROR, WARN, and completion lines in build logs."""

    _ERR_RE = re.compile(
        r'\b(?:ERROR|FATAL|CRITICAL|FAILED|Traceback|Exception|RuntimeError|OSError|ValueError|AssertionError)\b',
        re.IGNORECASE,
    )
    _WARN_RE = re.compile(r'\b(?:WARN|WARNING)\b', re.IGNORECASE)

    def __init__(self, document) -> None:
        super().__init__(document)
        self._err_fmt = QTextCharFormat()
        self._err_fmt.setForeground(QColor(style.DANGER))
        self._err_fmt.setFontWeight(QFont.Weight.DemiBold)

        self._warn_fmt = QTextCharFormat()
        self._warn_fmt.setForeground(QColor(style.AMBER))

        self._ok_fmt = QTextCharFormat()
        self._ok_fmt.setForeground(QColor(style.GREEN))

    def highlightBlock(self, text: str) -> None:
        if not text:
            return
        if self._ERR_RE.search(text):
            self.setFormat(0, len(text), self._err_fmt)
        elif self._WARN_RE.search(text):
            self.setFormat(0, len(text), self._warn_fmt)
        elif '✓' in text:
            self.setFormat(0, len(text), self._ok_fmt)


class StatusDot(QWidget):
    """A 7px status indicator circle (LauncherTone)."""

    def __init__(self, color: str = style.NEUTRAL_DOT, size: int = 8, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self._color = color
        self._size = size
        self.setFixedSize(size + 4, size + 4)

    def set_color(self, color: str) -> None:
        if self._color != color:
            self._color = color
            self.update()

    def paintEvent(self, _event) -> None:
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        p.setPen(Qt.NoPen)
        p.setBrush(QColor(self._color))
        off = 2.0
        p.drawEllipse(QRectF(off, off, self._size, self._size))


class ElidedLabel(QLabel):
    """Single-line QLabel that shrinks cleanly and elides in the middle so trailing ETA stays visible."""

    def __init__(
        self,
        text: str = '',
        elide_mode: Qt.TextElideMode = Qt.ElideMiddle,
        alignment: Qt.AlignmentFlag = Qt.AlignLeft | Qt.AlignVCenter,
        parent: QWidget | None = None,
    ) -> None:
        super().__init__(text, parent)
        self._elide_mode = elide_mode
        self.setAlignment(alignment)
        self.setMinimumWidth(0)
        self.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Preferred)

    def minimumSizeHint(self) -> QSize:
        return QSize(0, super().minimumSizeHint().height())

    def displayed_text(self, width: int | None = None) -> str:
        raw = self.text()
        if not raw:
            return ''
        avail = max(0, self.contentsRect().width() if width is None else width)
        return self.fontMetrics().elidedText(raw, self._elide_mode, avail)

    def paintEvent(self, event) -> None:
        QFrame.paintEvent(self, event)
        raw = self.text()
        if not raw:
            return
        rect = self.contentsRect()
        if rect.width() <= 0:
            return
        elided = self.displayed_text(rect.width())
        p = QPainter(self)
        p.setFont(self.font())
        self.style().drawItemText(
            p,
            rect,
            int(self.alignment()),
            self.palette(),
            self.isEnabled(),
            elided,
            self.foregroundRole(),
        )
        p.end()


class LauncherSwitch(QWidget):
    """Pill toggle switch matching SwiftUI's LauncherSwitchStyle (40x24 track + 2px focus ring)."""

    toggled = Signal(bool)

    def __init__(self, checked: bool = False, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self._checked = bool(checked)
        self._show_focus_ring = False
        self.setFixedSize(46, 28)
        self.setCursor(Qt.PointingHandCursor)
        self.setFocusPolicy(Qt.StrongFocus)

    def focusInEvent(self, event) -> None:
        self._show_focus_ring = event.reason() in _KEYBOARD_FOCUS_REASONS
        self.update()
        super().focusInEvent(event)

    def focusOutEvent(self, event) -> None:
        self._show_focus_ring = False
        self.update()
        super().focusOutEvent(event)

    def isChecked(self) -> bool:
        return self._checked

    def setChecked(self, val: bool) -> None:
        val = bool(val)
        if self._checked != val:
            self._checked = val
            self.update()

    def _flip(self) -> None:
        if not self.isEnabled():
            return
        self._checked = not self._checked
        self.update()
        self.toggled.emit(self._checked)

    def mousePressEvent(self, event: QMouseEvent) -> None:
        self._show_focus_ring = False
        self.update()
        super().mousePressEvent(event)

    def mouseReleaseEvent(self, event: QMouseEvent) -> None:
        if event.button() == Qt.LeftButton and self.isEnabled():
            self._flip()

    def keyPressEvent(self, event: QKeyEvent) -> None:
        if event.key() in (Qt.Key_Space, Qt.Key_Return, Qt.Key_Enter):
            if self.hasFocus():
                self._show_focus_ring = True
            self._flip()
            event.accept()
            return
        super().keyPressEvent(event)

    def paintEvent(self, _event) -> None:
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        track_rect = QRectF(3.0, 3.0, self.width() - 6.0, self.height() - 6.0)
        radius = track_rect.height() / 2.0

        if not self.isEnabled():
            track = QColor(255, 255, 255, 20)
            knob = QColor(255, 255, 255, 90)
        elif self._checked:
            track = QColor(style.ACCENT)
            knob = QColor(style.ACCENT_INK)
        else:
            track = QColor(255, 255, 255, 36)
            knob = QColor(255, 255, 255, 230)

        p.setPen(QPen(QColor(255, 255, 255, 25 if not self._checked else 0), 1.0))
        p.setBrush(track)
        p.drawRoundedRect(track_rect, radius, radius)

        knob_d = 16.0
        knob_y = track_rect.y() + (track_rect.height() - knob_d) / 2.0
        knob_x = (track_rect.right() - knob_d - 3.0) if self._checked else (track_rect.left() + 3.0)
        p.setPen(Qt.NoPen)
        p.setBrush(knob)
        p.drawEllipse(QRectF(knob_x, knob_y, knob_d, knob_d))

        if self.hasFocus() and self._show_focus_ring:
            focus_rect = QRectF(1.0, 1.0, self.width() - 2.0, self.height() - 2.0)
            p.setPen(QPen(QColor(style.ACCENT), 2.0))
            p.setBrush(Qt.NoBrush)
            p.drawRoundedRect(focus_rect, focus_rect.height() / 2.0, focus_rect.height() / 2.0)


class LauncherSegmented(QWidget):
    """Capsule segmented control matching SwiftUI's LauncherSegmented (cream active pill + keyboard focus)."""

    changed = Signal(str)
    _RING = 2.0
    _PAD = 4.0
    _GAP = 6.0

    def __init__(self, items: list[tuple[str, str]] | None = None, selected: str = '', parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self._items: list[tuple[str, str]] = list(items or [])
        self._selected = selected
        self._show_focus_ring = False
        self.setFixedHeight(40)
        self.setCursor(Qt.PointingHandCursor)
        self.setFocusPolicy(Qt.StrongFocus)
        self.setSizePolicy(QSizePolicy.Preferred, QSizePolicy.Fixed)
        self.updateGeometry()

    def focusInEvent(self, event) -> None:
        self._show_focus_ring = event.reason() in _KEYBOARD_FOCUS_REASONS
        self.update()
        super().focusInEvent(event)

    def focusOutEvent(self, event) -> None:
        self._show_focus_ring = False
        self.update()
        super().focusOutEvent(event)

    def set_items(self, items: list[tuple[str, str]], selected: str | None = None) -> None:
        self._items = list(items)
        if selected is not None:
            self._selected = selected
        elif self._items and self._selected and all(k != self._selected for k, _ in self._items):
            self._selected = self._items[0][0]
        self.updateGeometry()
        self.update()

    def selected(self) -> str:
        return self._selected

    def set_selected(self, key: str) -> None:
        if self._selected != key:
            self._selected = key
            self.update()

    def _measure_segments(self) -> tuple[list[float], float]:
        f = QFont(self.font())
        if f.pointSize() <= 0 and f.pixelSize() <= 0:
            f.setPointSizeF(9.5)
        f.setBold(True)
        fm = QFontMetrics(f)
        widths: list[float] = []
        for _, label in self._items:
            widths.append(max(68.0, float(fm.horizontalAdvance(label) + 32)))
        if not widths:
            return [], 120.0
        inset = self._RING + self._PAD
        total = inset * 2.0 + sum(widths) + self._GAP * max(0, len(widths) - 1)
        return widths, max(120.0, total)

    def sizeHint(self) -> QSize:
        _, total = self._measure_segments()
        return QSize(int(total + 0.5), self.height() or 40)

    def minimumSizeHint(self) -> QSize:
        if not self._items:
            return QSize(96, self.height() or 40)
        inset = self._RING + self._PAD
        min_w = inset * 2.0 + len(self._items) * 58.0 + self._GAP * max(0, len(self._items) - 1)
        return QSize(int(min_w + 0.5), self.height() or 40)

    def changeEvent(self, event) -> None:
        super().changeEvent(event)
        if event is not None and event.type() in (
            QEvent.Type.FontChange,
            QEvent.Type.StyleChange,
            QEvent.Type.ApplicationFontChange,
        ):
            self.updateGeometry()

    def _segment_rects(self) -> list[tuple[str, str, QRectF]]:
        widths, total = self._measure_segments()
        if not widths:
            return []
        avail_w = float(self.width()) if self.width() > 0 else total
        inset = self._RING + self._PAD
        h = max(12.0, float(self.height()) - inset * 2.0)
        gaps = self._GAP * max(0, len(widths) - 1)
        inner_avail = max(float(len(widths)) * 32.0, avail_w - inset * 2.0 - gaps)
        sum_w = sum(widths)

        if avail_w >= total:
            extra = (avail_w - total) / len(widths)
            seg_widths = [w + extra for w in widths]
        else:
            scale = inner_avail / max(1.0, sum_w)
            seg_widths = [max(32.0, w * scale) for w in widths]

        x = inset
        out: list[tuple[str, str, QRectF]] = []
        for (key, label), seg_w in zip(self._items, seg_widths):
            out.append((key, label, QRectF(x, inset, seg_w, h)))
            x += seg_w + self._GAP
        return out

    def _select_index(self, idx: int) -> None:
        if not self._items or not self.isEnabled():
            return
        idx = idx % len(self._items)
        chosen_key = self._items[idx][0]
        if chosen_key != self._selected:
            self._selected = chosen_key
            self.update()
            self.changed.emit(chosen_key)

    def keyPressEvent(self, event: QKeyEvent) -> None:
        if not self._items or not self.isEnabled():
            super().keyPressEvent(event)
            return
        cur_idx = next((i for i, (k, _) in enumerate(self._items) if k == self._selected), -1)
        key = event.key()
        if key == Qt.Key_Left:
            if self.hasFocus():
                self._show_focus_ring = True
            self._select_index((cur_idx - 1) if cur_idx >= 0 else 0)
            event.accept()
            return
        if key == Qt.Key_Right:
            if self.hasFocus():
                self._show_focus_ring = True
            self._select_index((cur_idx + 1) if cur_idx >= 0 else 0)
            event.accept()
            return
        if key in (Qt.Key_Space, Qt.Key_Return, Qt.Key_Enter):
            if self.hasFocus():
                self._show_focus_ring = True
            if cur_idx < 0:
                self._select_index(0)
            else:
                self._select_index(cur_idx + 1)
            event.accept()
            return
        super().keyPressEvent(event)

    def mousePressEvent(self, event: QMouseEvent) -> None:
        self._show_focus_ring = False
        self.update()
        super().mousePressEvent(event)

    def mouseReleaseEvent(self, event: QMouseEvent) -> None:
        if event.button() != Qt.LeftButton or not self.isEnabled() or not self._items:
            return
        px = float(event.position().x())
        rects = self._segment_rects()
        chosen_key = None
        for key, _label, r in rects:
            if r.left() - self._GAP / 2.0 <= px <= r.right() + self._GAP / 2.0:
                chosen_key = key
                break
        if chosen_key is None and rects:
            chosen_key = rects[0][0] if px < rects[0][2].left() else rects[-1][0]
        if chosen_key and chosen_key != self._selected:
            self._selected = chosen_key
            self.update()
            self.changed.emit(chosen_key)

    def paintEvent(self, _event) -> None:
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        outer = QRectF(
            self._RING + 0.5,
            self._RING + 0.5,
            max(1.0, self.width() - (self._RING + 0.5) * 2.0),
            max(1.0, self.height() - (self._RING + 0.5) * 2.0),
        )
        p.setPen(QPen(QColor(255, 255, 255, 24), 1.0))
        p.setBrush(QColor(255, 255, 255, 13))
        p.drawRoundedRect(outer, outer.height() / 2.0, outer.height() / 2.0)

        for key, label, r in self._segment_rects():
            active = key == self._selected
            f = QFont(self.font())
            f.setBold(active)
            p.setFont(f)
            if active:
                p.setPen(Qt.NoPen)
                p.setBrush(QColor(style.ACCENT))
                p.drawRoundedRect(r, r.height() / 2.0, r.height() / 2.0)
                p.setPen(QColor(style.ACCENT_INK))
            else:
                p.setPen(QColor(255, 255, 255, 195))
            fm = QFontMetrics(f)
            elided = fm.elidedText(label, Qt.ElideRight, max(12, int(r.width()) - 10))
            p.drawText(r, Qt.AlignCenter, elided)

        if self.hasFocus() and self._show_focus_ring:
            focus_rect = QRectF(1.0, 1.0, self.width() - 2.0, self.height() - 2.0)
            p.setPen(QPen(QColor(style.ACCENT), 2.0))
            p.setBrush(Qt.NoBrush)
            p.drawRoundedRect(focus_rect, focus_rect.height() / 2.0, focus_rect.height() / 2.0)


class CardPageHeading(QWidget):
    """Large page heading + optional subtitle note (CardPageHeading in LauncherCard.swift)."""

    def __init__(self, title: str = '', note: str = '', parent: QWidget | None = None) -> None:
        super().__init__(parent)
        lay = QVBoxLayout(self)
        lay.setContentsMargins(0, 0, 0, 4)
        lay.setSpacing(6)
        self.title_label = QLabel(title)
        self.title_label.setObjectName('pageTitle')
        self.note_label = QLabel(note)
        self.note_label.setObjectName('pageNote')
        self.note_label.setWordWrap(True)
        lay.addWidget(self.title_label)
        lay.addWidget(self.note_label)
        self.note_label.setVisible(bool(note))

    def set_text(self, title: str, note: str = '') -> None:
        self.title_label.setText(title)
        self.note_label.setText(note)
        self.note_label.setVisible(bool(note))


class CardGroup(QWidget):
    """Rounded dark card with optional section header and footer (CardGroup in LauncherCard.swift)."""

    def __init__(self, title: str = '', footer: str = '', parent: QWidget | None = None) -> None:
        super().__init__(parent)
        outer = QVBoxLayout(self)
        outer.setContentsMargins(0, 0, 0, 0)
        outer.setSpacing(8)

        self.header_row = QHBoxLayout()
        self.header_row.setContentsMargins(4, 0, 4, 0)
        self.title_label = QLabel(title)
        self.title_label.setObjectName('sectionTitle')
        self.header_row.addWidget(self.title_label)
        self.header_row.addStretch(1)
        outer.addLayout(self.header_row)
        self.title_label.setVisible(bool(title))

        self.card = QFrame()
        self.card.setObjectName('card')
        self.body_layout = QVBoxLayout(self.card)
        self.body_layout.setContentsMargins(0, 2, 0, 2)
        self.body_layout.setSpacing(0)
        outer.addWidget(self.card)

        self.footer_label = QLabel(footer)
        self.footer_label.setObjectName('sectionFoot')
        self.footer_label.setWordWrap(True)
        self.footer_label.setContentsMargins(4, 0, 4, 0)
        outer.addWidget(self.footer_label)
        self.footer_label.setVisible(bool(footer))

    def set_title(self, title: str) -> None:
        self.title_label.setText(title)
        self.title_label.setVisible(bool(title))

    def set_footer(self, footer: str) -> None:
        self.footer_label.setText(footer)
        self.footer_label.setVisible(bool(footer))

    def add_row(self, widget: QWidget) -> None:
        self.body_layout.addWidget(widget)

    def add_divider(self) -> QFrame:
        div_wrap = QWidget()
        h = QHBoxLayout(div_wrap)
        h.setContentsMargins(18, 0, 18, 0)
        d = QFrame()
        d.setObjectName('divider')
        h.addWidget(d)
        self.body_layout.addWidget(div_wrap)
        return d


def make_divider() -> QFrame:
    d = QFrame()
    d.setObjectName('divider')
    return d


def _fallback_gradient_colors(title_id: str) -> tuple[QColor, QColor]:
    h = 0
    for ch in (title_id or '0100'):
        h = (h * 31 + ord(ch)) & 0xFFFFFFFF
    palettes = [
        (QColor('#1e293b'), QColor('#0f172a')),
        (QColor('#31102f'), QColor('#13071e')),
        (QColor('#14332a'), QColor('#091914')),
        (QColor('#3b2314'), QColor('#1a0f08')),
        (QColor('#1f243d'), QColor('#0c0e1a')),
        (QColor('#2d1b36'), QColor('#120b18')),
    ]
    return palettes[h % len(palettes)]


class HeroBannerWidget(QWidget):
    """Full-bleed Hero showcase for the selected game (one solid cream primary CTA)."""

    primaryClicked = Signal()
    manageClicked = Signal(QWidget)
    refreshClicked = Signal()
    batchRefreshClicked = Signal()

    def __init__(self, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.setMinimumHeight(250)
        self.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Expanding)
        self._pixmap: QPixmap | None = None
        self._image_path: str = ''
        self._title_id: str = ''
        self._title_text: str = ''
        self._status_text: str = ''
        self._status_color: str = style.NEUTRAL_DOT
        self._is_switch2: bool = False
        self._switch2_text: str = 'Switch 2'

        lay = QVBoxLayout(self)
        lay.setContentsMargins(36, 28, 36, 28)
        lay.setSpacing(10)
        lay.addStretch(1)

        # Status + Switch 2 + update badge row
        status_row = QHBoxLayout()
        status_row.setSpacing(8)
        self.dot = StatusDot(style.GREEN, size=8)
        self.status_lbl = QLabel('')
        self.status_lbl.setStyleSheet(
            'font-size: 9pt; font-weight: 700; color: rgba(255,255,255,0.84); letter-spacing: 0.6px;'
        )
        self.sw2_badge = QLabel('Switch 2')
        self.sw2_badge.setStyleSheet(
            f'background: rgba(255, 240, 214, 0.16); color: {style.ACCENT}; '
            f'border: 1px solid rgba(255, 240, 214, 0.42); border-radius: {style.RADIUS_CHIP}px; '
            f'padding: 2px 9px; font-size: 8.5pt; font-weight: 700;'
        )
        self.sw2_badge.hide()

        self.update_badge = QLabel('')
        self.update_badge.setObjectName('mono')
        self.update_badge.hide()

        # Refresh action uses translucent secondary glass pill so primary_btn stays the sole solid cream CTA
        self.refresh_btn = QPushButton('')
        self.refresh_btn.setObjectName('heroSecondary')
        self.refresh_btn.setFixedHeight(44)
        self.refresh_btn.setCursor(Qt.PointingHandCursor)
        self.refresh_btn.clicked.connect(self.refreshClicked.emit)
        self.refresh_btn.hide()

        self.batch_refresh_btn = QPushButton('')
        self.batch_refresh_btn.setObjectName('heroSecondary')
        self.batch_refresh_btn.setCursor(Qt.PointingHandCursor)
        self.batch_refresh_btn.clicked.connect(self.batchRefreshClicked.emit)
        self.batch_refresh_btn.hide()

        status_row.addWidget(self.dot)
        status_row.addWidget(self.status_lbl)
        status_row.addWidget(self.sw2_badge)
        status_row.addWidget(self.update_badge)
        status_row.addStretch(1)
        lay.addLayout(status_row)

        # Giant game title
        self.title_lbl = QLabel('')
        self.title_lbl.setWordWrap(True)
        self.title_lbl.setStyleSheet('font-size: 28pt; font-weight: 800; color: #ffffff;')
        lay.addWidget(self.title_lbl)

        # Subtitle (Title ID / output note)
        self.sub_lbl = QLabel('')
        self.sub_lbl.setObjectName('mono')
        self.sub_lbl.setStyleSheet('font-size: 9pt; color: rgba(255,255,255,0.62);')
        lay.addWidget(self.sub_lbl)

        self.refresh_note_lbl = QLabel('')
        self.refresh_note_lbl.setObjectName('muted')
        self.refresh_note_lbl.setWordWrap(True)
        self.refresh_note_lbl.hide()
        lay.addWidget(self.refresh_note_lbl)

        lay.addSpacing(6)

        # Action bar: sole primary cream CTA + translucent secondary actions
        act_row = QHBoxLayout()
        act_row.setSpacing(12)
        self.primary_btn = QPushButton('')
        self.primary_btn.setObjectName('heroPlay')
        self.primary_btn.setMinimumWidth(184)
        self.primary_btn.setFixedHeight(48)
        self.primary_btn.setCursor(Qt.PointingHandCursor)
        self.primary_btn.clicked.connect(self.primaryClicked.emit)

        self.manage_btn = QPushButton('⋯')
        self.manage_btn.setObjectName('heroSecondary')
        self.manage_btn.setFixedHeight(44)
        self.manage_btn.setCursor(Qt.PointingHandCursor)
        self.manage_btn.clicked.connect(lambda: self.manageClicked.emit(self.manage_btn))

        act_row.addWidget(self.primary_btn)
        act_row.addWidget(self.refresh_btn)
        act_row.addWidget(self.manage_btn)
        act_row.addStretch(1)
        lay.addLayout(act_row)

    def set_data(
        self,
        title_id: str,
        title: str,
        subtitle: str,
        status_text: str,
        status_color: str,
        primary_label: str,
        primary_enabled: bool,
        manage_label: str,
        image_path: str | None,
        is_switch2: bool = False,
        switch2_label: str = 'Switch 2',
        *,
        update_badge_text: str = '',
        refresh_label: str = '',
        batch_refresh_label: str = '',
        refresh_note: str = '',
        refresh_enabled: bool = True,
        batch_refresh_enabled: bool = True,
    ) -> None:
        self._title_id = title_id
        self._title_text = title
        self.title_lbl.setText(title)
        self.sub_lbl.setText(subtitle)
        self.status_lbl.setText(status_text.upper())
        self.dot.set_color(status_color)
        self.primary_btn.setText(primary_label)
        self.primary_btn.setEnabled(primary_enabled)
        self.manage_btn.setText(f'⋯  {manage_label}')
        self.sw2_badge.setText(switch2_label)
        self.sw2_badge.setVisible(is_switch2)

        self.update_badge.setText(update_badge_text)
        self.update_badge.setVisible(bool(update_badge_text))

        self.refresh_btn.setText(refresh_label)
        self.refresh_btn.setEnabled(refresh_enabled)
        self.refresh_btn.setVisible(bool(refresh_label))

        self.batch_refresh_btn.setText(batch_refresh_label)
        self.batch_refresh_btn.setEnabled(batch_refresh_enabled)
        self.batch_refresh_btn.setVisible(bool(batch_refresh_label))

        self.refresh_note_lbl.setText(refresh_note)
        self.refresh_note_lbl.setVisible(bool(refresh_note))

        new_img = image_path or ''
        if new_img != self._image_path:
            self._image_path = new_img
            if new_img:
                pm = QPixmap(new_img)
                self._pixmap = pm if not pm.isNull() else None
            else:
                self._pixmap = None
        self.update()

    def paintEvent(self, _event) -> None:
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        p.setRenderHint(QPainter.SmoothPixmapTransform)
        w, h = float(self.width()), float(self.height())
        rect = QRectF(0, 0, w, h)
        fill_rect = QRectF(0, 0, w + 2.0, h + 2.0)
        p.fillRect(fill_rect, QColor(0, 0, 0))

        p.save()
        p.setClipRect(QRectF(0, 0, w, max(0.0, h - 1.0)))
        if self._pixmap and not self._pixmap.isNull():
            pw, ph = float(self._pixmap.width()), float(self._pixmap.height())
            scale = max(w / max(1.0, pw), h / max(1.0, ph))
            sw, sh = pw * scale, ph * scale
            sx = (w - sw) * 0.5
            sy = (h - sh) * 0.25
            p.drawPixmap(QRectF(sx, sy, sw, sh), self._pixmap, QRectF(0, 0, pw, ph))
        else:
            c1, c2 = _fallback_gradient_colors(self._title_id)
            bg = QLinearGradient(0, 0, w, h)
            bg.setColorAt(0.0, c1)
            bg.setColorAt(1.0, c2)
            p.fillRect(rect, bg)
            if self._title_text:
                p.save()
                f = QFont(self.font())
                f.setPixelSize(160)
                f.setBold(True)
                p.setFont(f)
                p.setPen(QColor(255, 255, 255, 14))
                p.drawText(
                    QRectF(w * 0.45, 10, w * 0.5, h - 20),
                    Qt.AlignRight | Qt.AlignVCenter,
                    self._title_text[:2].upper(),
                )
                p.restore()
        p.restore()

        # Vertical gradient (fades cleanly to zero luminance at bottom edge without a 1px seam)
        vg = QLinearGradient(0, 0, 0, h)
        vg.setColorAt(0.0, QColor(0, 0, 0, 46))
        vg.setColorAt(0.45, QColor(0, 0, 0, 115))
        vg.setColorAt(0.85, QColor(0, 0, 0, 232))
        vg.setColorAt(0.98, QColor(0, 0, 0, 255))
        vg.setColorAt(1.0, QColor(0, 0, 0, 255))
        p.fillRect(fill_rect, vg)

        # Left readability scrim
        hg = QLinearGradient(0, 0, min(w, 620.0), 0)
        hg.setColorAt(0.0, QColor(0, 0, 0, 165))
        hg.setColorAt(1.0, QColor(0, 0, 0, 0))
        p.fillRect(QRectF(0, 0, min(w, 620.0), h), hg)


class GameCardWidget(QWidget):
    """16:9 game card in the Collection strip with hover/press overlays and keyboard focus ring."""

    clicked = Signal(str)
    doubleClicked = Signal(str)
    navigateRequested = Signal(str, int)

    CARD_W = 232
    ART_H = 128
    TOTAL_H = 166
    _INSET = 5.0

    def __init__(
        self,
        title_id: str,
        title: str,
        image_path: str | None,
        selected: bool,
        dot_color: str,
        is_switch2: bool = False,
        switch2_label: str = 'Switch 2',
        parent: QWidget | None = None,
    ) -> None:
        super().__init__(parent)
        self.title_id = title_id
        self.title = title
        self.selected = selected
        self.dot_color = dot_color
        self.is_switch2 = is_switch2
        self.switch2_label = switch2_label
        self._hovered = False
        self._pressed = False
        self._show_focus_ring = False
        self._pixmap: QPixmap | None = None
        if image_path:
            pm = QPixmap(image_path)
            if not pm.isNull():
                self._pixmap = pm
        self.setFixedSize(self.CARD_W, self.TOTAL_H)
        self.setCursor(Qt.PointingHandCursor)
        self.setFocusPolicy(Qt.StrongFocus)
        self.setAccessibleName(title)

    def focusInEvent(self, event) -> None:
        self._show_focus_ring = event.reason() in _KEYBOARD_FOCUS_REASONS
        self.update()
        super().focusInEvent(event)

    def focusOutEvent(self, event) -> None:
        self._show_focus_ring = False
        self.update()
        super().focusOutEvent(event)

    def enterEvent(self, _event) -> None:
        self._hovered = True
        self.update()

    def leaveEvent(self, _event) -> None:
        self._hovered = False
        self._pressed = False
        self.update()

    def mousePressEvent(self, event: QMouseEvent) -> None:
        if event.button() == Qt.LeftButton:
            self._pressed = True
            self._show_focus_ring = False
            self.update()
        super().mousePressEvent(event)

    def mouseReleaseEvent(self, event: QMouseEvent) -> None:
        was_pressed = self._pressed
        self._pressed = False
        self.update()
        if event.button() == Qt.LeftButton and (was_pressed or self.rect().contains(event.position().toPoint())):
            self.clicked.emit(self.title_id)

    def mouseDoubleClickEvent(self, event: QMouseEvent) -> None:
        if event.button() == Qt.LeftButton:
            self.doubleClicked.emit(self.title_id)

    def keyPressEvent(self, event: QKeyEvent) -> None:
        key = event.key()
        if key == Qt.Key_Space:
            if self.hasFocus():
                self._show_focus_ring = True
            self.clicked.emit(self.title_id)
            event.accept()
            return
        if key in (Qt.Key_Return, Qt.Key_Enter):
            if self.hasFocus():
                self._show_focus_ring = True
            self.doubleClicked.emit(self.title_id)
            event.accept()
            return
        if key == Qt.Key_Left:
            if self.hasFocus():
                self._show_focus_ring = True
            self.navigateRequested.emit(self.title_id, -1)
            event.accept()
            return
        if key == Qt.Key_Right:
            if self.hasFocus():
                self._show_focus_ring = True
            self.navigateRequested.emit(self.title_id, 1)
            event.accept()
            return
        super().keyPressEvent(event)

    def paintEvent(self, _event) -> None:
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        p.setRenderHint(QPainter.SmoothPixmapTransform)

        art_rect = QRectF(self._INSET, self._INSET, self.CARD_W - self._INSET * 2.0, self.ART_H)
        path = QPainterPath()
        path.addRoundedRect(art_rect, float(style.RADIUS_CARD), float(style.RADIUS_CARD))

        p.save()
        p.setClipPath(path)
        if self._pixmap and not self._pixmap.isNull():
            pw, ph = float(self._pixmap.width()), float(self._pixmap.height())
            scale = max(art_rect.width() / max(1.0, pw), art_rect.height() / max(1.0, ph))
            sw, sh = pw * scale, ph * scale
            sx = art_rect.x() + (art_rect.width() - sw) * 0.5
            sy = art_rect.y() + (art_rect.height() - sh) * 0.5
            p.drawPixmap(QRectF(sx, sy, sw, sh), self._pixmap, QRectF(0, 0, pw, ph))
        else:
            c1, c2 = _fallback_gradient_colors(self.title_id)
            grad = QLinearGradient(art_rect.topLeft(), art_rect.bottomRight())
            grad.setColorAt(0.0, c1)
            grad.setColorAt(1.0, c2)
            p.fillRect(art_rect, grad)
            f = QFont(self.font())
            f.setPixelSize(15)
            f.setBold(True)
            p.setFont(f)
            p.setPen(QColor(255, 255, 255, 210))
            p.drawText(
                art_rect.adjusted(14, 14, -14, -14),
                Qt.AlignBottom | Qt.AlignLeft | Qt.TextWordWrap,
                self.title,
            )

        # Pointer interaction overlays (tokens.json: hoverOverlay 0.06, pressedOverlay 0.12)
        if self._pressed:
            p.fillRect(art_rect, QColor(255, 255, 255, 31))
        elif self._hovered:
            p.fillRect(art_rect, QColor(255, 255, 255, 15))

        # Top-right status dot pill
        p.setPen(Qt.NoPen)
        p.setBrush(QColor(0, 0, 0, 150))
        p.drawEllipse(QRectF(art_rect.right() - 22, art_rect.top() + 8, 14, 14))
        p.setBrush(QColor(self.dot_color))
        p.drawEllipse(QRectF(art_rect.right() - 19, art_rect.top() + 11, 8, 8))

        # Top-left Switch 2 badge if applicable
        if self.is_switch2:
            f = QFont(self.font())
            f.setPixelSize(10)
            f.setBold(True)
            p.setFont(f)
            fm = QFontMetrics(f)
            bw = fm.horizontalAdvance(self.switch2_label) + 12
            brect = QRectF(art_rect.left() + 8, art_rect.top() + 8, bw, 18)
            p.setBrush(QColor(13, 13, 15, 200))
            p.setPen(QPen(QColor(style.ACCENT), 1.0))
            p.drawRoundedRect(brect, float(style.RADIUS_CHIP), float(style.RADIUS_CHIP))
            p.setPen(QColor(style.ACCENT))
            p.drawText(brect, Qt.AlignCenter, self.switch2_label)
        p.restore()

        # Selection / hover border around artwork
        if self.selected:
            p.setPen(QPen(QColor(style.ACCENT), 2.0))
        elif self._hovered:
            p.setPen(QPen(QColor(255, 255, 255, 95), 1.4))
        else:
            p.setPen(QPen(QColor(255, 255, 255, 24), 1.0))
        p.setBrush(Qt.NoBrush)
        p.drawRoundedRect(art_rect, float(style.RADIUS_CARD), float(style.RADIUS_CARD))

        # Keyboard focus ring with 3px gap outside artwork (tokens.json focusRing 2px / focusRingGap 3px)
        if self.hasFocus() and self._show_focus_ring:
            ring_rect = art_rect.adjusted(-3.0, -3.0, 3.0, 3.0)
            p.setPen(QPen(QColor(style.ACCENT), 2.0))
            p.setBrush(Qt.NoBrush)
            p.drawRoundedRect(ring_rect, float(style.RADIUS_CARD) + 3.0, float(style.RADIUS_CARD) + 3.0)

        # Title below art (no redundant bottom selection bar)
        f = QFont(self.font())
        f.setPointSizeF(9.0)
        f.setBold(self.selected)
        p.setFont(f)
        p.setPen(QColor('#ffffff') if (self.selected or self._hovered) else QColor(255, 255, 255, 180))
        fm = QFontMetrics(f)
        elided = fm.elidedText(self.title, Qt.ElideRight, int(art_rect.width()))
        text_rect = QRectF(self._INSET, art_rect.bottom() + 8.0, art_rect.width(), 20.0)
        p.drawText(text_rect, Qt.AlignLeft | Qt.AlignVCenter, elided)


class HorizontalStripViewport(QWidget):
    """Clipping viewport that hosts a horizontally scrollable card strip without expanding parent width."""

    overflowChanged = Signal(bool)

    def __init__(self, height: int = 176, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self._fixed_h = height
        self._scroll_x = 0
        self._last_overflow: bool | None = None
        self.setFixedHeight(height)
        self.setMinimumWidth(0)
        self.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Fixed)

        self.strip = QWidget(self)
        self.strip.setFixedHeight(height)
        self.strip_layout = QHBoxLayout(self.strip)
        self.strip_layout.setContentsMargins(0, 4, 0, 4)
        self.strip_layout.setSpacing(14)

    def minimumSizeHint(self) -> QSize:
        return QSize(0, self._fixed_h)

    def sizeHint(self) -> QSize:
        return QSize(200, self._fixed_h)

    def _layout_strip(self) -> tuple[int, int]:
        if getattr(self, '_laying_out_strip', False):
            return self.strip_layout.sizeHint().width(), max(1, self.width())
        self._laying_out_strip = True
        try:
            for i in range(self.strip_layout.count()):
                w = self.strip_layout.itemAt(i).widget()
                if w is not None and not w.isVisibleTo(self.strip):
                    w.show()
            self.strip_layout.invalidate()
            self.strip_layout.activate()
            content_w = self.strip_layout.sizeHint().width()
            vw = max(1, self.width())
            self.strip.resize(max(vw, content_w), self._fixed_h)
            self.strip_layout.activate()
            overflow = content_w > vw + 1
            if overflow != self._last_overflow:
                self._last_overflow = overflow
                self.overflowChanged.emit(overflow)
            return content_w, vw
        finally:
            self._laying_out_strip = False

    def has_overflow(self) -> bool:
        return self.max_scroll() > 0

    def max_scroll(self) -> int:
        content_w, vw = self._layout_strip()
        return max(0, content_w - vw)

    def set_scroll_x(self, x: int) -> None:
        content_w, vw = self._layout_strip()
        self._scroll_x = max(0, min(max(0, content_w - vw), x))
        self.strip.move(-self._scroll_x, 0)

    def scroll_by(self, dx: int) -> None:
        self.set_scroll_x(self._scroll_x + dx)

    def sync_strip(self, ensure_visible: QWidget | None = None) -> None:
        content_w, vw = self._layout_strip()
        target_x = self._scroll_x
        if ensure_visible is not None and self.width() > 0:
            left = ensure_visible.x()
            right = left + ensure_visible.width()
            if left < target_x:
                target_x = left
            elif right > target_x + vw:
                target_x = right - vw
        self._scroll_x = max(0, min(max(0, content_w - vw), target_x))
        self.strip.move(-self._scroll_x, 0)

    def resizeEvent(self, event) -> None:
        super().resizeEvent(event)
        self.set_scroll_x(self._scroll_x)

    def wheelEvent(self, event: QWheelEvent) -> None:
        px = event.pixelDelta()
        ang = event.angleDelta()
        if not px.isNull() and (px.x() != 0 or px.y() != 0):
            dx = -px.x() if abs(px.x()) >= abs(px.y()) else -px.y()
        else:
            raw = ang.x() if abs(ang.x()) >= abs(ang.y()) else ang.y()
            dx = -int(raw * 0.8)
        if dx != 0 and self.max_scroll() > 0:
            self.scroll_by(dx)
            event.accept()
            return
        super().wheelEvent(event)


class DropOverlayWidget(QWidget):
    """Full-window drag-and-drop overlay matching GameFilesDropOverlay in SwiftUI."""

    def __init__(self, hint_text: str = '', parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.hint_text = hint_text
        self.setAttribute(Qt.WA_TransparentForMouseEvents, True)
        self.hide()

    def set_hint(self, text: str) -> None:
        self.hint_text = text
        self.update()

    def paintEvent(self, _event) -> None:
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        p.fillRect(self.rect(), QColor(0, 0, 0, 185))
        box = QRectF(self.rect()).adjusted(36, 36, -36, -36)
        pen = QPen(QColor(style.ACCENT), 2.0, Qt.DashLine)
        p.setPen(pen)
        p.setBrush(QColor(26, 26, 28, 215))
        p.drawRoundedRect(box, float(style.RADIUS_SHEET), float(style.RADIUS_SHEET))

        f = QFont(self.font())
        f.setPointSizeF(13.5)
        f.setBold(True)
        p.setFont(f)
        p.setPen(QColor(style.ACCENT))
        p.drawText(box, Qt.AlignCenter, self.hint_text)
