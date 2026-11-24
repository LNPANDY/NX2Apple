"""Three-stage seed compression migration dialog (Prompt -> Running -> Done).

Follows Dark Glass tokens and safe PySide6 optional import so headless CI can import cleanly.
"""
from __future__ import annotations

import threading
from typing import TYPE_CHECKING, Any
import weakref

from . import seed_compression as sc
from . import style

from PySide6.QtCore import QObject, QRectF, Qt, Signal
from PySide6.QtGui import QColor, QPainter
from PySide6.QtWidgets import (
    QDialog,
    QFrame,
    QHBoxLayout,
    QLabel,
    QProgressBar,
    QPushButton,
    QScrollArea,
    QSizePolicy,
    QStackedWidget,
    QVBoxLayout,
    QWidget,
)
from .widgets import CardGroup, ElidedLabel, LauncherCheckBox, StatusDot

if TYPE_CHECKING:
    from .model import Model


class _SeedBridge(QObject):
    """Marshal background scan/compression events strictly onto the UI thread."""

    eventReady = Signal(object)
    finishedReady = Signal(object)

    def __init__(self, parent: QObject | None = None) -> None:
        super().__init__(parent)
        self._dead = False

    def mark_dead(self) -> None:
        self._dead = True

    def emit_event(self, ev: dict[str, Any]) -> None:
        if self._dead:
            return
        try:
            self.eventReady.emit(ev)
        except RuntimeError:
            self._dead = True

    def emit_finished(self, res: sc.SeedCompressionResult) -> None:
        if self._dead:
            return
        try:
            self.finishedReady.emit(res)
        except RuntimeError:
            self._dead = True

class _RatioBarWidget(QWidget):
    """Visual before/after compression ratio bar for the Done summary card."""

    def __init__(self, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self._ratio = 0.0
        self.setFixedHeight(10)
        self.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Fixed)

    def set_ratio(self, after_bytes: int, before_bytes: int) -> None:
        if before_bytes <= 0:
            self._ratio = 0.0
        else:
            self._ratio = max(0.02, min(1.0, float(after_bytes) / float(before_bytes)))
        self.update()

    def paintEvent(self, _event) -> None:
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        w = float(self.width())
        h = float(self.height())
        r = h / 2.0
        p.setPen(Qt.NoPen)
        p.setBrush(QColor(255, 255, 255, 22))
        p.drawRoundedRect(QRectF(0.0, 0.0, w, h), r, r)
        fill_w = max(h, w * self._ratio) if self._ratio > 0.0 else 0.0
        if fill_w > 0.0:
            p.setBrush(QColor(style.GREEN))
            p.drawRoundedRect(QRectF(0.0, 0.0, min(w, fill_w), h), r, r)

class SeedCompressionDialog(QDialog):
    """Three-state modal sheet guiding legacy metal-sources .img -> .img.zst migration."""

    def __init__(
        self,
        model: 'Model',
        summary: sc.SeedScanSummary,
        *,
        auto_prompt: bool = False,
        runner_factory=sc.SeedCompressionRunner,
        parent: QWidget | None = None,
    ) -> None:
        super().__init__(parent)
        self.m = model
        self.summary = summary
        self.auto_prompt = auto_prompt
        self._runner_factory = runner_factory
        self._runner: sc.SeedCompressionRunner | None = None
        self._worker_thread: threading.Thread | None = None
        self._state = sc.SeedCompressionState(summary)
        self._closed = False
        self._did_compress = False

        self._bridge = _SeedBridge(self)
        self._bridge.eventReady.connect(self._on_worker_event)
        self._bridge.finishedReady.connect(self._on_worker_finished)

        self.setWindowTitle(self.m.t('seedCompress.prompt.title'))
        self.setMinimumSize(660, 520)
        self.resize(700, 620)
        self.setStyleSheet(style.STYLESHEET)

        root_lay = QVBoxLayout(self)
        root_lay.setContentsMargins(0, 0, 0, 0)
        root_lay.setSpacing(0)

        self.stack = QStackedWidget()
        root_lay.addWidget(self.stack)

        self._progress_rows: dict[str, dict[str, Any]] = {}

        self.prompt_page = self._build_prompt_page()
        self.running_page = self._build_running_page()
        self.done_page = self._build_done_page()

        self.stack.addWidget(self.prompt_page)
        self.stack.addWidget(self.running_page)
        self.stack.addWidget(self.done_page)
        self.stack.setCurrentWidget(self.prompt_page)

    @property
    def current_stage(self) -> str:
        return self._state.stage

    @property
    def did_compress(self) -> bool:
        return self._did_compress

    # --------------------------------------------------------- Page 0: Prompt
    def _build_prompt_page(self) -> QWidget:
        t = self.m.t
        page = QWidget()
        lay = QVBoxLayout(page)
        lay.setContentsMargins(28, 24, 28, 22)
        lay.setSpacing(14)

        self.prompt_title_lbl = QLabel(t('seedCompress.prompt.title'))
        self.prompt_title_lbl.setStyleSheet('font-size: 21px; font-weight: 800;')
        self.prompt_title_lbl.setWordWrap(True)
        lay.addWidget(self.prompt_title_lbl)

        self.prompt_sub_lbl = QLabel(t('seedCompress.prompt.subtitle'))
        self.prompt_sub_lbl.setObjectName('muted')
        self.prompt_sub_lbl.setWordWrap(True)
        lay.addWidget(self.prompt_sub_lbl)

        # 3 metric cards
        metrics_row = QHBoxLayout()
        metrics_row.setSpacing(10)

        c1, self.metric_cur_title, self.metric_cur_val = self._make_metric_card(
            t('seedCompress.prompt.currentSize'),
            sc.format_bytes(self.summary.uncompressed_bytes),
            style.TEXT,
        )
        c2, self.metric_est_title, self.metric_est_val = self._make_metric_card(
            t('seedCompress.prompt.estimatedSize'),
            sc.format_bytes(self.summary.estimated_compressed_bytes),
            style.ACCENT,
        )
        c3, self.metric_sav_title, self.metric_sav_val = self._make_metric_card(
            t('seedCompress.prompt.estimatedSaved'),
            t(
                'seedCompress.prompt.saveSummary',
                sc.format_bytes(self.summary.estimated_saved_bytes),
                self.summary.estimated_saved_pct,
            ),
            style.GREEN,
            value_px=14,
        )
        metrics_row.addWidget(c1, 1)
        metrics_row.addWidget(c2, 1)
        metrics_row.addWidget(c3, 1)
        lay.addLayout(metrics_row)

        # Games list card (first 4 + folded remaining count) inside transparent scroll area
        prompt_scroll = QScrollArea()
        prompt_scroll.setWidgetResizable(True)
        prompt_scroll.setFrameShape(QFrame.NoFrame)
        prompt_scroll.setStyleSheet('QScrollArea { background: transparent; border: none; }')
        prompt_wrap = QWidget()
        prompt_wrap_lay = QVBoxLayout(prompt_wrap)
        prompt_wrap_lay.setContentsMargins(0, 0, 0, 0)
        prompt_wrap_lay.setSpacing(0)

        self.prompt_games_group = CardGroup(title=t('seedCompress.prompt.gamesTitle', self.summary.total_games))
        max_visible = 4
        shown = self.summary.games[:max_visible]
        for idx, g in enumerate(shown):
            if idx > 0:
                self.prompt_games_group.add_divider()
            row = QWidget()
            has_sub_tid = (g.label != g.title_id)
            if has_sub_tid:
                row.setMinimumHeight(52)
            rl = QHBoxLayout(row)
            rl.setContentsMargins(16, 10, 16, 10)
            rl.setSpacing(10)

            name_col = QVBoxLayout()
            name_col.setSpacing(3)
            nl = ElidedLabel(g.label, elide_mode=Qt.ElideRight)
            nl.setObjectName('rowTitle')
            nl.setMinimumHeight(20)
            name_col.addWidget(nl)
            if has_sub_tid:
                tl = QLabel(g.title_id)
                tl.setObjectName('mono')
                tl.setMinimumHeight(16)
                tl.setStyleSheet(f'color: {style.FAINT}; font-size: 11px;')
                name_col.addWidget(tl)
            rl.addLayout(name_col, 1)

            sz = QLabel(sc.format_bytes(g.uncompressed_bytes))
            sz.setObjectName('mono')
            rl.addWidget(sz)
            self.prompt_games_group.add_row(row)

        remaining = max(0, len(self.summary.games) - max_visible)
        if remaining > 0:
            self.prompt_games_group.add_divider()
            mrow = QWidget()
            ml = QHBoxLayout(mrow)
            ml.setContentsMargins(16, 9, 16, 9)
            self.more_games_lbl = QLabel(t('seedCompress.prompt.moreGames', remaining))
            self.more_games_lbl.setObjectName('muted')
            ml.addWidget(self.more_games_lbl)
            self.prompt_games_group.add_row(mrow)
        else:
            self.more_games_lbl = None

        prompt_wrap_lay.addWidget(self.prompt_games_group)
        prompt_wrap_lay.addStretch(1)
        prompt_scroll.setWidget(prompt_wrap)
        lay.addWidget(prompt_scroll, 1)

        # Info note card
        note_card = QFrame()
        note_card.setObjectName('subcard')
        nl_lay = QHBoxLayout(note_card)
        nl_lay.setContentsMargins(14, 10, 14, 10)
        self.prompt_note_lbl = QLabel(t('seedCompress.prompt.note'))
        self.prompt_note_lbl.setObjectName('muted')
        self.prompt_note_lbl.setWordWrap(True)
        nl_lay.addWidget(self.prompt_note_lbl)
        lay.addWidget(note_card)

        # Footer
        foot = QHBoxLayout()
        foot.setSpacing(10)
        self.dont_ask_cb = LauncherCheckBox(t('seedCompress.prompt.dontAskAgain'))
        self.dont_ask_cb.setChecked(sc.is_prompt_dismissed(self.m))
        self.dont_ask_cb.setStyleSheet(
            f'color: {style.MUTED}; font-size: 12.5px; spacing: 7px;'
        )
        foot.addWidget(self.dont_ask_cb)
        foot.addStretch(1)

        self.later_btn = QPushButton(t('seedCompress.prompt.later'))
        self.later_btn.clicked.connect(self._on_later_clicked)
        foot.addWidget(self.later_btn)

        self.compress_now_btn = QPushButton(t('seedCompress.prompt.compressNow'))
        self.compress_now_btn.setObjectName('creamPill')
        self.compress_now_btn.setDefault(True)
        self.compress_now_btn.clicked.connect(self._on_compress_now_clicked)
        foot.addWidget(self.compress_now_btn)

        lay.addLayout(foot)
        return page

    @staticmethod
    def _make_metric_card(
        label: str,
        value: str,
        color: str,
        *,
        value_px: int = 16,
    ) -> tuple[QFrame, QLabel, QLabel]:
        card = QFrame()
        card.setObjectName('subcard')
        col = QVBoxLayout(card)
        col.setContentsMargins(14, 12, 14, 12)
        col.setSpacing(4)
        title_lbl = QLabel(label)
        title_lbl.setObjectName('muted')
        title_lbl.setWordWrap(True)
        val_lbl = QLabel(value)
        val_lbl.setStyleSheet(f'color: {color}; font-size: {value_px}px; font-weight: 800;')
        val_lbl.setWordWrap(True)
        col.addWidget(title_lbl)
        col.addWidget(val_lbl)
        col.addStretch(1)
        return card, title_lbl, val_lbl

    # --------------------------------------------------------- Page 1: Running
    def _build_running_page(self) -> QWidget:
        t = self.m.t
        page = QWidget()
        lay = QVBoxLayout(page)
        lay.setContentsMargins(28, 24, 28, 22)
        lay.setSpacing(14)

        self.run_title_lbl = QLabel(t('seedCompress.progress.title'))
        self.run_title_lbl.setStyleSheet('font-size: 21px; font-weight: 800;')
        self.run_title_lbl.setWordWrap(True)
        lay.addWidget(self.run_title_lbl)

        self.run_sub_lbl = QLabel(t('seedCompress.progress.subtitle'))
        self.run_sub_lbl.setObjectName('muted')
        self.run_sub_lbl.setWordWrap(True)
        lay.addWidget(self.run_sub_lbl)

        prog_card = QFrame()
        prog_card.setObjectName('subcard')
        pcol = QVBoxLayout(prog_card)
        pcol.setContentsMargins(16, 14, 16, 14)
        pcol.setSpacing(8)

        first_name = self.summary.games[0].label if self.summary.games else ''
        self.run_current_lbl = ElidedLabel(
            t('seedCompress.progress.currentGame', 1 if self.summary.total_games else 0, self.summary.total_games, first_name),
            elide_mode=Qt.ElideRight,
        )
        self.run_current_lbl.setObjectName('rowTitle')
        pcol.addWidget(self.run_current_lbl)

        self.run_bar = QProgressBar()
        self.run_bar.setRange(0, 100)
        self.run_bar.setValue(0)
        self.run_bar.setTextVisible(False)
        self.run_bar.setFixedHeight(8)
        self.run_bar.setStyleSheet(
            f'QProgressBar {{ background: rgba(255,255,255,0.08); border: none; border-radius: 4px; }}'
            f'QProgressBar::chunk {{ background: {style.ACCENT}; border-radius: 4px; }}'
        )
        pcol.addWidget(self.run_bar)

        stats_row = QHBoxLayout()
        self.run_processed_lbl = QLabel(
            t('seedCompress.progress.processed', sc.format_bytes(0), sc.format_bytes(self.summary.uncompressed_bytes))
        )
        self.run_processed_lbl.setObjectName('muted')
        self.run_freed_lbl = QLabel(t('seedCompress.progress.freed', sc.format_bytes(0)))
        self.run_freed_lbl.setStyleSheet(f'color: {style.GREEN}; font-size: 12px; font-weight: 700;')
        stats_row.addWidget(self.run_processed_lbl, 1)
        stats_row.addWidget(self.run_freed_lbl)
        pcol.addLayout(stats_row)
        lay.addWidget(prog_card)

        # Scrollable item list (wrap CardGroup so QScrollArea transparent rule keeps CardGroup dark surface)
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.NoFrame)
        scroll.setStyleSheet('QScrollArea { background: transparent; border: none; }')
        run_wrap = QWidget()
        run_wrap_lay = QVBoxLayout(run_wrap)
        run_wrap_lay.setContentsMargins(0, 0, 0, 0)
        run_wrap_lay.setSpacing(0)
        self.run_list_group = CardGroup()
        self._populate_running_rows()
        run_wrap_lay.addWidget(self.run_list_group)
        run_wrap_lay.addStretch(1)
        scroll.setWidget(run_wrap)
        lay.addWidget(scroll, 1)

        foot = QHBoxLayout()
        foot.setSpacing(12)
        self.safe_stop_lbl = QLabel(t('seedCompress.progress.safeStopNote'))
        self.safe_stop_lbl.setObjectName('muted')
        self.safe_stop_lbl.setWordWrap(True)
        foot.addWidget(self.safe_stop_lbl, 1)

        self.stop_btn = QPushButton(t('seedCompress.progress.stop'))
        self.stop_btn.setObjectName('danger')
        self.stop_btn.clicked.connect(self._on_stop_clicked)
        foot.addWidget(self.stop_btn)
        lay.addLayout(foot)
        return page

    def _populate_running_rows(self) -> None:
        t = self.m.t
        self._progress_rows.clear()
        for idx, item in enumerate(self._state.items):
            if idx > 0:
                self.run_list_group.add_divider()
            row = QWidget()
            rl = QHBoxLayout(row)
            rl.setContentsMargins(16, 9, 16, 9)
            rl.setSpacing(10)
            dot = StatusDot(style.NEUTRAL_DOT, size=8)
            rl.addWidget(dot)

            name_lbl = ElidedLabel(item.display_name, elide_mode=Qt.ElideRight)
            name_lbl.setObjectName('rowTitle')
            name_lbl.setMinimumHeight(20)
            rl.addWidget(name_lbl, 1)

            status_lbl = QLabel(t('seedCompress.progress.statusWaiting'))
            status_lbl.setObjectName('muted')
            rl.addWidget(status_lbl)

            size_lbl = QLabel(sc.format_bytes(item.before_bytes))
            size_lbl.setObjectName('mono')
            rl.addWidget(size_lbl)

            self.run_list_group.add_row(row)
            self._progress_rows[item.title_id] = {
                'dot': dot,
                'status': status_lbl,
                'size': size_lbl,
            }

    # --------------------------------------------------------- Page 2: Done
    def _build_done_page(self) -> QWidget:
        t = self.m.t
        page = QWidget()
        lay = QVBoxLayout(page)
        lay.setContentsMargins(28, 24, 28, 22)
        lay.setSpacing(14)

        self.done_title_lbl = QLabel(t('seedCompress.done.title'))
        self.done_title_lbl.setStyleSheet('font-size: 21px; font-weight: 800;')
        self.done_title_lbl.setWordWrap(True)
        lay.addWidget(self.done_title_lbl)

        self.done_sub_lbl = QLabel(t('seedCompress.done.subtitle'))
        self.done_sub_lbl.setObjectName('muted')
        self.done_sub_lbl.setWordWrap(True)
        lay.addWidget(self.done_sub_lbl)

        # Big comparison card
        comp_card = QFrame()
        comp_card.setObjectName('subcard')
        ccol = QVBoxLayout(comp_card)
        ccol.setContentsMargins(18, 14, 18, 14)
        ccol.setSpacing(8)

        self.done_saved_lbl = QLabel('')
        self.done_saved_lbl.setStyleSheet(f'color: {style.GREEN}; font-size: 19px; font-weight: 800;')
        self.done_saved_lbl.setWordWrap(True)
        ccol.addWidget(self.done_saved_lbl)

        meta_row = QHBoxLayout()
        self.done_size_change_lbl = QLabel('')
        self.done_size_change_lbl.setObjectName('rowTitle')
        self.done_ratio_lbl = QLabel('')
        self.done_ratio_lbl.setObjectName('muted')
        meta_row.addWidget(self.done_size_change_lbl, 1)
        meta_row.addWidget(self.done_ratio_lbl)
        ccol.addLayout(meta_row)

        self.done_ratio_bar = _RatioBarWidget()
        ccol.addWidget(self.done_ratio_bar)
        lay.addWidget(comp_card)

        # Details scroll card
        self.done_details_scroll = QScrollArea()
        self.done_details_scroll.setWidgetResizable(True)
        self.done_details_scroll.setFrameShape(QFrame.NoFrame)
        self.done_details_scroll.setStyleSheet('QScrollArea { background: transparent; border: none; }')
        self.done_details_host = QWidget()
        self.done_details_lay = QVBoxLayout(self.done_details_host)
        self.done_details_lay.setContentsMargins(0, 0, 0, 0)
        self.done_details_lay.setSpacing(0)
        self.done_details_scroll.setWidget(self.done_details_host)
        lay.addWidget(self.done_details_scroll, 1)

        foot = QHBoxLayout()
        foot.setSpacing(12)
        self.done_stats_lbl = QLabel('')
        self.done_stats_lbl.setObjectName('muted')
        self.done_stats_lbl.setWordWrap(True)
        foot.addWidget(self.done_stats_lbl, 1)

        self.finish_btn = QPushButton(t('seedCompress.done.finish'))
        self.finish_btn.setObjectName('creamPill')
        self.finish_btn.setDefault(True)
        self.finish_btn.clicked.connect(self.accept)
        foot.addWidget(self.finish_btn)
        lay.addLayout(foot)
        return page

    # --------------------------------------------------------- Actions & State
    def _persist_dont_ask(self) -> None:
        sc.set_prompt_dismissed(self.m, self.dont_ask_cb.isChecked())

    def _on_later_clicked(self) -> None:
        self._persist_dont_ask()
        self.reject()

    def _on_compress_now_clicked(self) -> None:
        self._persist_dont_ask()
        self.start_compression()

    def start_compression(self) -> None:
        if self._state.stage == 'running' or getattr(self.m, 'running', False):
            return
        self._state.begin_running()
        self.stack.setCurrentWidget(self.running_page)
        self.setWindowTitle(self.m.t('seedCompress.progress.title'))
        self.stop_btn.setEnabled(True)
        self.stop_btn.setText(self.m.t('seedCompress.progress.stop'))

        runner = self._runner_factory()
        self._runner = runner
        bridge_ref = weakref.ref(self._bridge)
        summary = self.summary
        eng_path = self.m.engine_path
        py_exe = self.m.python_path or None

        def _worker() -> None:
            def _on_ev(ev: dict[str, Any]) -> None:
                b = bridge_ref()
                if b is not None:
                    b.emit_event(ev)

            res = runner.run(
                summary,
                engine_path=eng_path,
                python_exe=py_exe,
                on_event=_on_ev,
            )
            b = bridge_ref()
            if b is not None:
                b.emit_finished(res)

        t = threading.Thread(target=_worker, daemon=True, name='seed-zstd-compress')
        self._worker_thread = t
        t.start()

    def _on_stop_clicked(self) -> None:
        if self._state.stage != 'running' or self._state.stopping:
            return
        self._state.mark_stopping()
        self.stop_btn.setEnabled(False)
        self.stop_btn.setText(self.m.t('seedCompress.progress.stopping'))
        if self._runner is not None:
            self._runner.request_stop()

    def _on_worker_event(self, ev: dict[str, Any]) -> None:
        if self._closed:
            return
        self._state.apply_event(ev)
        kind = str(ev.get('event') or '')
        if kind in ('start', 'item_start', 'item_done', 'item_error'):
            self._refresh_running_ui()
        elif kind in ('done', 'error'):
            self._did_compress = self._did_compress or any(
                it.status == 'done' for it in self._state.items
            )
            self._render_done_ui()

    def _on_worker_finished(self, res: sc.SeedCompressionResult) -> None:
        if self._closed:
            return
        if self._state.done_result is None:
            self._state.done_result = res
            self._state.stage = 'done'
        self._did_compress = self._did_compress or (res.completed_games > 0)
        self._render_done_ui()

    def _refresh_running_ui(self) -> None:
        t = self.m.t
        total_g = max(1, self._state.total_games)
        idx = max(0, min(self._state.current_index, total_g))
        cur_item = self._state.item_for(self._state.current_title_id) if self._state.current_title_id else None
        cur_name = cur_item.display_name if cur_item else ''
        self.run_current_lbl.setText(
            t('seedCompress.progress.currentGame', idx or 1, total_g, cur_name)
        )
        total_b = max(1, self._state.total_bytes)
        pct = int(min(100, round(self._state.processed_bytes * 100.0 / total_b)))
        self.run_bar.setValue(pct)
        self.run_processed_lbl.setText(
            t(
                'seedCompress.progress.processed',
                sc.format_bytes(self._state.processed_bytes),
                sc.format_bytes(self._state.total_bytes),
            )
        )
        self.run_freed_lbl.setText(
            t('seedCompress.progress.freed', sc.format_bytes(self._state.freed_bytes))
        )

        for item in self._state.items:
            widgets = self._progress_rows.get(item.title_id)
            if not widgets:
                continue
            dot: StatusDot = widgets['dot']
            st_lbl: QLabel = widgets['status']
            sz_lbl: QLabel = widgets['size']
            if item.status == 'compressing':
                dot.set_color(style.AMBER)
                st_lbl.setText(t('seedCompress.progress.statusCompressing'))
                st_lbl.setStyleSheet(f'color: {style.AMBER}; font-size: 12px; font-weight: 600;')
                sz_lbl.setText(sc.format_bytes(item.before_bytes))
            elif item.status == 'done':
                dot.set_color(style.GREEN)
                st_lbl.setText(t('seedCompress.progress.statusDone'))
                st_lbl.setStyleSheet(f'color: {style.GREEN}; font-size: 12px; font-weight: 600;')
                sz_lbl.setText(f'{sc.format_bytes(item.before_bytes)} → {sc.format_bytes(item.after_bytes)}')
            elif item.status == 'failed':
                dot.set_color(style.DANGER)
                st_lbl.setText(t('seedCompress.progress.statusFailed'))
                st_lbl.setStyleSheet(f'color: {style.DANGER}; font-size: 12px; font-weight: 600;')
                sz_lbl.setText(sc.format_bytes(item.before_bytes))
            else:
                dot.set_color(style.NEUTRAL_DOT)
                st_lbl.setText(t('seedCompress.progress.statusWaiting'))
                st_lbl.setStyleSheet('')
                sz_lbl.setText(sc.format_bytes(item.before_bytes))

    def show_done(self, result: sc.SeedCompressionResult) -> None:
        """Public helper allowing tests/gallery to render a completed/partial/stopped summary state."""
        self._state.done_result = result
        self._state.stage = 'done'
        self._render_done_ui()

    def _render_done_ui(self) -> None:
        t = self.m.t
        res = self._state.done_result
        if res is None:
            return

        if res.status == 'stopped':
            title_txt = t('seedCompress.done.titleStopped')
            sub_txt = t('seedCompress.done.subtitleStopped')
        elif res.status in ('partial', 'error'):
            title_txt = t('seedCompress.done.titlePartial')
            sub_txt = t('seedCompress.done.subtitlePartial')
        else:
            title_txt = t('seedCompress.done.title')
            sub_txt = t('seedCompress.done.subtitle')

        self.setWindowTitle(title_txt)
        self.done_title_lbl.setText(title_txt)
        self.done_sub_lbl.setText(sub_txt)

        self.done_saved_lbl.setText(
            t('seedCompress.done.savedSummary', sc.format_bytes(res.saved_bytes), res.saved_pct)
        )
        self.done_size_change_lbl.setText(
            t('seedCompress.done.sizeChange', sc.format_bytes(res.before_bytes), sc.format_bytes(res.after_bytes))
        )
        self.done_ratio_lbl.setText(t('seedCompress.done.ratioNote', res.ratio_pct))
        self.done_ratio_bar.set_ratio(res.after_bytes, res.before_bytes)

        # Rebuild details card cleanly
        while self.done_details_lay.count():
            child = self.done_details_lay.takeAt(0)
            w = child.widget()
            if w is not None:
                w.hide()
                w.deleteLater()

        grp = CardGroup(title=t('seedCompress.done.detailsTitle'))
        items_to_show = res.results or self._state.items
        for idx, item in enumerate(items_to_show):
            if idx > 0:
                grp.add_divider()
            row = QWidget()
            rl = QHBoxLayout(row)
            rl.setContentsMargins(16, 9, 16, 9)
            rl.setSpacing(10)

            if item.status == 'done':
                dot_col = style.GREEN
                st_txt = t('seedCompress.progress.statusDone')
                val_txt = f'{sc.format_bytes(item.before_bytes)} → {sc.format_bytes(item.after_bytes)}'
            elif item.status == 'failed':
                dot_col = style.DANGER
                st_txt = t('seedCompress.progress.statusFailed')
                val_txt = item.error or sc.format_bytes(item.before_bytes)
            else:
                dot_col = style.NEUTRAL_DOT
                st_txt = t('seedCompress.progress.statusWaiting')
                val_txt = sc.format_bytes(item.before_bytes)

            rl.addWidget(StatusDot(dot_col, size=8))
            nl = ElidedLabel(item.display_name, elide_mode=Qt.ElideRight)
            nl.setObjectName('rowTitle')
            nl.setMinimumHeight(20)
            rl.addWidget(nl, 1)

            sl = QLabel(st_txt)
            sl.setStyleSheet(f'color: {dot_col}; font-size: 12px; font-weight: 600;')
            rl.addWidget(sl)

            vl = ElidedLabel(val_txt, elide_mode=Qt.ElideMiddle, alignment=Qt.AlignRight | Qt.AlignVCenter)
            vl.setObjectName('mono')
            rl.addWidget(vl)
            grp.add_row(row)

        self.done_details_lay.addWidget(grp)
        self.done_details_lay.addStretch(1)

        parts = [
            t('seedCompress.done.completedCount', res.completed_games),
            t('seedCompress.done.elapsed', sc.format_duration(res.elapsed_sec)),
        ]
        if res.failed_games > 0:
            parts.append(t('seedCompress.done.failedCount', res.failed_games))
        elif res.error:
            parts.append(res.error)
        self.done_stats_lbl.setText(' · '.join(parts))

        self.stack.setCurrentWidget(self.done_page)

    def reject(self) -> None:
        if self._state.stage == 'running':
            self._on_stop_clicked()
            return
        self._closed = True
        self._bridge.mark_dead()
        super().reject()

    def accept(self) -> None:
        self._closed = True
        self._bridge.mark_dead()
        super().accept()

    def closeEvent(self, event) -> None:
        if self._state.stage == 'running':
            self._on_stop_clicked()
            event.ignore()
            return
        self._closed = True
        self._bridge.mark_dead()
        super().closeEvent(event)
