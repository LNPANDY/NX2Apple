"""Custom QPainter widgets and card primitives mirroring the Mac SwiftUI launcher."""
from __future__ import annotations

from typing import Callable

from PySide6.QtCore import QPointF, QRectF, QSize, Qt, Signal
from PySide6.QtGui import (
    QColor,
    QFont,
    QFontMetrics,
    QLinearGradient,
    QMouseEvent,
    QPainter,
    QPainterPath,
    QPen,
    QPixmap,
    QWheelEvent,
)
from PySide6.QtWidgets import (
    QFrame,
    QHBoxLayout,
    QLabel,
    QPushButton,
    QSizePolicy,
    QVBoxLayout,
    QWidget,
)

from . import style


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


class LauncherSwitch(QWidget):
    """Pill toggle switch matching SwiftUI's LauncherSwitchStyle (40x24, cream track when on)."""

    toggled = Signal(bool)

    def __init__(self, checked: bool = False, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self._checked = bool(checked)
        self.setFixedSize(42, 24)
        self.setCursor(Qt.PointingHandCursor)

    def isChecked(self) -> bool:
        return self._checked

    def setChecked(self, val: bool) -> None:
        val = bool(val)
        if self._checked != val:
            self._checked = val
            self.update()

    def mouseReleaseEvent(self, event: QMouseEvent) -> None:
        if event.button() == Qt.LeftButton and self.isEnabled():
            self._checked = not self._checked
            self.update()
            self.toggled.emit(self._checked)

    def paintEvent(self, _event) -> None:
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        rect = QRectF(1, 1, self.width() - 2, self.height() - 2)
        radius = rect.height() / 2.0

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
        p.drawRoundedRect(rect, radius, radius)

        knob_d = 18.0
        knob_y = (self.height() - knob_d) / 2.0
        knob_x = (self.width() - knob_d - 3.0) if self._checked else 3.0
        p.setPen(Qt.NoPen)
        p.setBrush(knob)
        p.drawEllipse(QRectF(knob_x, knob_y, knob_d, knob_d))


class LauncherSegmented(QWidget):
    """Capsule segmented control matching SwiftUI's LauncherSegmented (cream active pill)."""

    changed = Signal(str)
    _PAD = 4.0
    _GAP = 6.0

    def __init__(self, items: list[tuple[str, str]] | None = None, selected: str = '', parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self._items: list[tuple[str, str]] = list(items or [])
        self._selected = selected or (self._items[0][0] if self._items else '')
        self.setFixedHeight(36)
        self.setCursor(Qt.PointingHandCursor)
        self._recalc_width()

    def set_items(self, items: list[tuple[str, str]], selected: str | None = None) -> None:
        self._items = list(items)
        if selected is not None:
            self._selected = selected
        elif self._items and all(k != self._selected for k, _ in self._items):
            self._selected = self._items[0][0]
        self._recalc_width()
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
            f.setPixelSize(13)
        f.setBold(True)
        fm = QFontMetrics(f)
        widths: list[float] = []
        for _, label in self._items:
            widths.append(max(68.0, float(fm.horizontalAdvance(label) + 34)))
        if not widths:
            return [], 120.0
        total = self._PAD * 2.0 + sum(widths) + self._GAP * max(0, len(widths) - 1)
        return widths, max(120.0, total)

    def _recalc_width(self) -> None:
        _, total = self._measure_segments()
        self.setFixedWidth(int(total + 0.5))

    def _segment_rects(self) -> list[tuple[str, str, QRectF]]:
        widths, total = self._measure_segments()
        if not widths:
            return []
        extra = max(0.0, float(self.width()) - total) / len(widths)
        x = self._PAD
        h = float(self.height()) - self._PAD * 2.0
        out: list[tuple[str, str, QRectF]] = []
        for (key, label), w in zip(self._items, widths):
            seg_w = w + extra
            out.append((key, label, QRectF(x, self._PAD, seg_w, h)))
            x += seg_w + self._GAP
        return out

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
        _, needed = self._measure_segments()
        if abs(self.width() - int(needed + 0.5)) > 2:
            self.setFixedWidth(int(needed + 0.5))
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        outer = QRectF(0.5, 0.5, self.width() - 1.0, self.height() - 1.0)
        p.setPen(QPen(QColor(255, 255, 255, 26), 1.0))
        p.setBrush(QColor(255, 255, 255, 13))
        p.drawRoundedRect(outer, outer.height() / 2.0, outer.height() / 2.0)

        for key, label, r in self._segment_rects():
            active = key == self._selected
            if active:
                p.setPen(Qt.NoPen)
                p.setBrush(QColor(style.ACCENT))
                p.drawRoundedRect(r, r.height() / 2.0, r.height() / 2.0)
                p.setPen(QColor(style.ACCENT_INK))
                f = QFont(self.font())
                f.setBold(True)
                p.setFont(f)
            else:
                p.setPen(QColor(255, 255, 255, 190))
                f = QFont(self.font())
                f.setBold(False)
                p.setFont(f)
            p.drawText(r, Qt.AlignCenter, label)


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
    """Full-bleed Hero showcase for the selected game (mirrors LauncherView+Library.swift hero)."""

    primaryClicked = Signal()
    manageClicked = Signal(QWidget)

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

        # Status + Switch 2 badge row
        status_row = QHBoxLayout()
        status_row.setSpacing(8)
        self.dot = StatusDot(style.GREEN, size=8)
        self.status_lbl = QLabel('')
        self.status_lbl.setStyleSheet('font-size: 11.5px; font-weight: 700; color: rgba(255,255,255,0.82); letter-spacing: 0.6px;')
        self.sw2_badge = QLabel('Switch 2')
        self.sw2_badge.setStyleSheet(
            f'background: rgba(255, 240, 214, 0.16); color: {style.ACCENT}; '
            f'border: 1px solid rgba(255, 240, 214, 0.42); border-radius: 9px; '
            f'padding: 2px 9px; font-size: 11px; font-weight: 700;'
        )
        self.sw2_badge.hide()
        status_row.addWidget(self.dot)
        status_row.addWidget(self.status_lbl)
        status_row.addWidget(self.sw2_badge)
        status_row.addStretch(1)
        lay.addLayout(status_row)

        # Giant game title
        self.title_lbl = QLabel('')
        self.title_lbl.setWordWrap(True)
        self.title_lbl.setStyleSheet('font-size: 38px; font-weight: 800; color: #ffffff;')
        lay.addWidget(self.title_lbl)

        # Subtitle (Title ID / output note)
        self.sub_lbl = QLabel('')
        self.sub_lbl.setObjectName('mono')
        self.sub_lbl.setStyleSheet('font-size: 12px; color: rgba(255,255,255,0.58);')
        lay.addWidget(self.sub_lbl)
        lay.addSpacing(6)

        # Action bar: primary capsule CTA + Manage button
        act_row = QHBoxLayout()
        act_row.setSpacing(12)
        self.primary_btn = QPushButton('')
        self.primary_btn.setObjectName('heroPlay')
        self.primary_btn.setMinimumWidth(196)
        self.primary_btn.setFixedHeight(50)
        self.primary_btn.setCursor(Qt.PointingHandCursor)
        self.primary_btn.clicked.connect(self.primaryClicked.emit)

        self.manage_btn = QPushButton('⋯')
        self.manage_btn.setObjectName('heroSecondary')
        self.manage_btn.setFixedHeight(42)
        self.manage_btn.setCursor(Qt.PointingHandCursor)
        self.manage_btn.clicked.connect(lambda: self.manageClicked.emit(self.manage_btn))

        act_row.addWidget(self.primary_btn)
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
            # Subtle decorative monogram on the right
            if self._title_text:
                p.save()
                f = QFont(self.font())
                f.setPixelSize(160)
                f.setBold(True)
                p.setFont(f)
                p.setPen(QColor(255, 255, 255, 14))
                p.drawText(QRectF(w * 0.45, 10, w * 0.5, h - 20), Qt.AlignRight | Qt.AlignVCenter, self._title_text[:2].upper())
                p.restore()

        # Vertical gradient (matching LauncherView+Library.swift heroScrim)
        vg = QLinearGradient(0, 0, 0, h)
        vg.setColorAt(0.0, QColor(0, 0, 0, 46))
        vg.setColorAt(0.45, QColor(0, 0, 0, 115))
        vg.setColorAt(0.85, QColor(0, 0, 0, 232))
        vg.setColorAt(1.0, QColor(0, 0, 0, 255))
        p.fillRect(rect, vg)

        # Left readability scrim (580px wide)
        hg = QLinearGradient(0, 0, min(w, 620.0), 0)
        hg.setColorAt(0.0, QColor(0, 0, 0, 165))
        hg.setColorAt(1.0, QColor(0, 0, 0, 0))
        p.fillRect(QRectF(0, 0, min(w, 620.0), h), hg)


class GameCardWidget(QWidget):
    """16:9 game card in the Collection strip (mirrors gameCard in LauncherView+Library.swift)."""

    clicked = Signal(str)
    doubleClicked = Signal(str)

    CARD_W = 228
    ART_H = 128
    TOTAL_H = 166

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
        self._pixmap: QPixmap | None = None
        if image_path:
            pm = QPixmap(image_path)
            if not pm.isNull():
                self._pixmap = pm
        self.setFixedSize(self.CARD_W, self.TOTAL_H)
        self.setCursor(Qt.PointingHandCursor)

    def enterEvent(self, _event) -> None:
        self._hovered = True
        self.update()

    def leaveEvent(self, _event) -> None:
        self._hovered = False
        self.update()

    def mouseReleaseEvent(self, event: QMouseEvent) -> None:
        if event.button() == Qt.LeftButton:
            self.clicked.emit(self.title_id)

    def mouseDoubleClickEvent(self, event: QMouseEvent) -> None:
        if event.button() == Qt.LeftButton:
            self.doubleClicked.emit(self.title_id)

    def paintEvent(self, _event) -> None:
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        p.setRenderHint(QPainter.SmoothPixmapTransform)

        art_rect = QRectF(2.0, 2.0, self.CARD_W - 4.0, self.ART_H)
        path = QPainterPath()
        path.addRoundedRect(art_rect, 12.0, 12.0)

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
            # Fallback title inside art
            f = QFont(self.font())
            f.setPixelSize(15)
            f.setBold(True)
            p.setFont(f)
            p.setPen(QColor(255, 255, 255, 210))
            p.drawText(art_rect.adjusted(14, 14, -14, -14), Qt.AlignBottom | Qt.AlignLeft | Qt.TextWordWrap, self.title)

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
            p.drawRoundedRect(brect, 9.0, 9.0)
            p.setPen(QColor(style.ACCENT))
            p.drawText(brect, Qt.AlignCenter, self.switch2_label)
        p.restore()

        # Border around art
        if self.selected:
            p.setPen(QPen(QColor(style.ACCENT), 2.2))
        elif self._hovered:
            p.setPen(QPen(QColor(255, 255, 255, 95), 1.4))
        else:
            p.setPen(QPen(QColor(255, 255, 255, 28), 1.0))
        p.setBrush(Qt.NoBrush)
        p.drawRoundedRect(art_rect, 12.0, 12.0)

        # Title below art
        f = QFont(self.font())
        f.setPixelSize(12)
        f.setBold(self.selected)
        p.setFont(f)
        p.setPen(QColor('#ffffff') if (self.selected or self._hovered) else QColor(255, 255, 255, 175))
        fm = QFontMetrics(f)
        elided = fm.elidedText(self.title, Qt.ElideRight, self.CARD_W - 8)
        text_rect = QRectF(4.0, self.ART_H + 8.0, self.CARD_W - 8.0, 18.0)
        p.drawText(text_rect, Qt.AlignLeft | Qt.AlignVCenter, elided)

        # Cream indicator bar under selected card
        if self.selected:
            p.setPen(Qt.NoPen)
            p.setBrush(QColor(style.ACCENT))
            p.drawRoundedRect(QRectF(4.0, self.TOTAL_H - 5.0, 28.0, 3.0), 1.5, 1.5)


class HorizontalStripViewport(QWidget):
    """Clipping viewport that hosts a horizontally scrollable card strip without expanding parent width."""

    def __init__(self, height: int = 176, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self._fixed_h = height
        self._scroll_x = 0
        self.setFixedHeight(height)
        self.setMinimumWidth(0)
        self.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Fixed)

        self.strip = QWidget(self)
        self.strip.setFixedHeight(height)
        self.strip_layout = QHBoxLayout(self.strip)
        self.strip_layout.setContentsMargins(0, 4, 0, 4)
        self.strip_layout.setSpacing(18)

    def minimumSizeHint(self) -> QSize:
        return QSize(0, self._fixed_h)

    def sizeHint(self) -> QSize:
        return QSize(200, self._fixed_h)

    def _layout_strip(self) -> tuple[int, int]:
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
        return content_w, vw

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
        p.setBrush(QColor(26, 26, 28, 210))
        p.drawRoundedRect(box, 20.0, 20.0)

        f = QFont(self.font())
        f.setPixelSize(18)
        f.setBold(True)
        p.setFont(f)
        p.setPen(QColor(style.ACCENT))
        p.drawText(box, Qt.AlignCenter, self.hint_text)
