"""Main window mirroring the Mac SwiftUI launcher (Library / Builds / Settings + Hero + Sheets)."""
from __future__ import annotations

import os
import sys
from pathlib import Path

from PySide6.QtCore import QPoint, QTimer, QUrl, Qt
from PySide6.QtGui import QDesktopServices, QDragEnterEvent, QDropEvent, QFont, QIcon, QMouseEvent, QPixmap
from PySide6.QtWidgets import (
    QApplication,
    QComboBox,
    QFileDialog,
    QFrame,
    QHBoxLayout,
    QLabel,
    QLineEdit,
    QMainWindow,
    QMenu,
    QMessageBox,
    QPlainTextEdit,
    QProgressBar,
    QPushButton,
    QScrollArea,
    QSizePolicy,
    QStackedWidget,
    QToolButton,
    QVBoxLayout,
    QWidget,
)

from . import build_failure as bf
from . import features as feat
from . import inputs
from . import library as lib
from . import platform_util as pu
from . import style
from .app_update import APP_VERSION
from .build_notes import TEXT, TITLE, stale_reason
from .i18n import Lang
from .model import Dep, DepState, Model
from .sheets import CheatsDialog, DeleteGameDialog, FreeSpaceDialog, OnboardingDialog
from .widgets import (
    CardGroup,
    CardPageHeading,
    DropOverlayWidget,
    GameCardWidget,
    HeroBannerWidget,
    HorizontalStripViewport,
    LauncherSegmented,
    LauncherSwitch,
    StatusDot,
    make_divider,
)


def _dot(color: str) -> QLabel:
    d = QLabel()
    d.setFixedSize(8, 8)
    d.setStyleSheet(f'background: {color}; border-radius: 4px;')
    return d


def _set_dot(d: QLabel, color: str) -> None:
    d.setStyleSheet(f'background: {color}; border-radius: 4px;')


class TopBarFrame(QFrame):
    """Custom frameless top bar that keeps the center navigation tabs pinned at the exact horizontal center
    and supports dragging / double-clicking to move or maximize the window."""

    def __init__(self, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.nav_container: QWidget | None = None
        self.search_box: QLineEdit | None = None
        self._drag_offset: QPoint | None = None

    def recenter_nav(self) -> None:
        if self.search_box is not None:
            sw = max(108, min(172, self.width() - 845))
            self.search_box.setFixedWidth(sw)
        if self.nav_container is None:
            return
        self.nav_container.adjustSize()
        nw = self.nav_container.width()
        nh = self.nav_container.height()
        x = max(0, (self.width() - nw) // 2)
        y = max(0, (self.height() - nh) // 2)
        self.nav_container.setGeometry(x, y, nw, nh)
        self.nav_container.raise_()

    def resizeEvent(self, event) -> None:
        super().resizeEvent(event)
        self.recenter_nav()

    def mousePressEvent(self, event: QMouseEvent) -> None:
        if event.button() == Qt.LeftButton:
            win = self.window()
            wh = win.windowHandle() if win else None
            if wh is not None and hasattr(wh, 'startSystemMove'):
                if wh.startSystemMove():
                    event.accept()
                    return
            if win is not None and not win.isMaximized():
                self._drag_offset = event.globalPosition().toPoint() - win.frameGeometry().topLeft()
                event.accept()
                return
        super().mousePressEvent(event)

    def mouseMoveEvent(self, event: QMouseEvent) -> None:
        if self._drag_offset is not None and (event.buttons() & Qt.LeftButton):
            win = self.window()
            if win is not None and not win.isMaximized():
                win.move(event.globalPosition().toPoint() - self._drag_offset)
                event.accept()
                return
        super().mouseMoveEvent(event)

    def mouseReleaseEvent(self, event: QMouseEvent) -> None:
        self._drag_offset = None
        super().mouseReleaseEvent(event)

    def mouseDoubleClickEvent(self, event: QMouseEvent) -> None:
        if event.button() == Qt.LeftButton:
            win = self.window()
            if hasattr(win, '_toggle_maximize_window'):
                win._toggle_maximize_window()
                event.accept()
                return
        super().mouseDoubleClickEvent(event)


class MainWindow(QMainWindow):
    def __init__(self, model: Model) -> None:
        super().__init__()
        self.m = model
        self.m.ask_folder = lambda title: QFileDialog.getExistingDirectory(
            self, title, str(Path.home())
        )
        self.m.ask_file = self._ask_metal_archive
        self.m.ask_sdk_archive = self._ask_sdk_archive
        self.setWindowTitle(f'NX2Apple v{APP_VERSION}')
        self.setWindowFlags(
            Qt.Window
            | Qt.FramelessWindowHint
            | Qt.WindowSystemMenuHint
            | Qt.WindowMinMaxButtonsHint
        )
        icon_file = Path(__file__).resolve().parent / 'assets' / 'app_icon.png'
        if icon_file.is_file():
            self.setWindowIcon(QIcon(str(icon_file)))
        self.resize(1080, 800)
        self.setMinimumSize(820, 440)
        self.setAcceptDrops(True)
        self.setStyleSheet(style.STYLESHEET)

        self._current_page = 'builds'
        self._failed = False
        self._library_filter = 'owned'  # 'owned' or 'built'
        self._search_query = ''
        self._drive_folder = ''
        self._options_expanded = True
        self._deps_expanded = True
        self._onboarding_checked = False
        self._onboarding_dialog: OnboardingDialog | None = None

        root = QWidget()
        root.setObjectName('root')
        self.setCentralWidget(root)
        root_col = QVBoxLayout(root)
        root_col.setContentsMargins(0, 0, 0, 0)
        root_col.setSpacing(0)

        # 1. Top Navigation Bar (64px, frameless with built-in Min/Max/Close & centered nav)
        self.top_bar = self._build_top_bar()
        root_col.addWidget(self.top_bar)

        # 2. Engine Sync / Failure Banner (below top bar)
        self.engine_banner = self._build_engine_banner()
        root_col.addWidget(self.engine_banner)

        # 3. Main Scrollable Workspace
        # `self.scroll` is the ONLY QScrollArea in MainWindow (hosting Library, Builds and Settings),
        # so `w.findChild(QScrollArea)` always returns `self.scroll`, and Library scrolls cleanly at high DPI.
        self.stack = QStackedWidget()
        self.scroll = QScrollArea()
        self.scroll.setWidgetResizable(True)
        self.scroll.setHorizontalScrollBarPolicy(Qt.ScrollBarAlwaysOff)
        scroll_body = QWidget()
        self.scroll_col = QVBoxLayout(scroll_body)
        self.scroll_col.setContentsMargins(0, 0, 0, 0)
        self.scroll_col.setSpacing(0)

        self.library_page = self._build_library_page()
        self.builds_page = self._build_builds_page()
        self.settings_page = self._build_settings_page()
        self.scroll_col.addWidget(self.library_page, 1)
        self.scroll_col.addWidget(self.builds_page)
        self.scroll_col.addWidget(self.settings_page)
        self.scroll.setWidget(scroll_body)

        self.stack.addWidget(self.scroll)
        root_col.addWidget(self.stack, 1)

        # 4. Bottom Global Activity Bar
        self.activity_bar = self._build_activity_bar()
        root_col.addWidget(self.activity_bar)

        # 5. Full-window drag & drop overlay
        self.drop_overlay = DropOverlayWidget(self.m.t('drop.hint'), root)

        # Connect model signals
        self.m.depsChanged.connect(self._refresh_deps)
        self.m.repoChanged.connect(self._refresh_all)
        self.m.stagesChanged.connect(self._refresh_stages)
        self.m.runningChanged.connect(self._refresh_running)
        self.m.logAppended.connect(self._append_log)
        self.m.finished.connect(self._on_finished)
        self.m.appUpdateFound.connect(self._on_app_update)
        self.m.appRelaunching.connect(QApplication.quit)
        self.m.libraryChanged.connect(self._refresh_library)

        if self.m.log_path:
            self._append_log(self.m.t('log.at', str(self.m.log_path)) + '\n\n')

        self._switch_page('builds')

        self._refresh_all()
        for g in self.m.library.games:
            self.m.artwork.request_banner_async(g.title_id)

        self._init_timer = QTimer(self)
        self._init_timer.setSingleShot(True)
        self._init_timer.timeout.connect(self.m.check_deps)
        self._init_timer.start(50)

    # ================================================================ Top Bar & Window Controls

    def _toggle_maximize_window(self) -> None:
        if self.isMaximized():
            self.showNormal()
            self.max_win_btn.setText('□')
        else:
            self.showMaximized()
            self.max_win_btn.setText('❐')

    def _build_top_bar(self) -> TopBarFrame:
        bar = TopBarFrame()
        bar.setObjectName('topBar')
        bar.setFixedHeight(64)
        row = QHBoxLayout(bar)
        row.setContentsMargins(24, 0, 16, 0)
        row.setSpacing(10)

        # Brand (App Icon + NX2Apple — by nxnative)
        brand_row = QHBoxLayout()
        brand_row.setSpacing(10)
        self.app_icon_lbl = QLabel()
        self.app_icon_lbl.setFixedSize(26, 26)
        icon_file = Path(__file__).resolve().parent / 'assets' / 'app_icon.png'
        if icon_file.is_file():
            pm = QPixmap(str(icon_file))
            if not pm.isNull():
                self.app_icon_lbl.setPixmap(
                    pm.scaled(26, 26, Qt.KeepAspectRatio, Qt.SmoothTransformation)
                )
        brand_row.addWidget(self.app_icon_lbl)
        self.title_label = QLabel('NX2Apple')
        self.title_label.setStyleSheet('font-size: 23px; font-weight: 800; color: #ffffff;')
        self.sub_label = QLabel('— by nxnative')
        self.sub_label.setObjectName('faint')
        brand_row.addWidget(self.title_label)
        brand_row.addWidget(self.sub_label)
        row.addLayout(brand_row)

        row.addStretch(1)

        # Pinned-center Navigation tabs: Library / Builds / Settings
        nav_host = QWidget(bar)
        nav_wrap = QHBoxLayout(nav_host)
        nav_wrap.setContentsMargins(0, 0, 0, 0)
        nav_wrap.setSpacing(4)
        self.nav_btns: dict[str, QPushButton] = {}
        for page_id in ('library', 'builds', 'settings'):
            btn = QPushButton(self.m.t('nav.' + page_id))
            btn.setCursor(Qt.PointingHandCursor)
            btn.clicked.connect(lambda _=False, p=page_id: self._switch_page(p))
            self.nav_btns[page_id] = btn
            nav_wrap.addWidget(btn)
        bar.nav_container = nav_host
        bar.recenter_nav()

        # Trailing controls: Search input + New Build + Update pill + Window controls (Min/Max/Close)
        self.search_input = QLineEdit()
        self.search_input.setObjectName('searchField')
        self.search_input.setPlaceholderText(self.m.t('library.search'))
        self.search_input.setFixedWidth(172)
        self.search_input.setClearButtonEnabled(True)
        self.search_input.textChanged.connect(self._on_search_changed)
        bar.search_box = self.search_input
        row.addWidget(self.search_input)

        self.new_build_btn = QPushButton('+ ' + self.m.t('library.newBuild'))
        self.new_build_btn.setCursor(Qt.PointingHandCursor)
        self.new_build_btn.clicked.connect(lambda: self._switch_page('builds'))
        row.addWidget(self.new_build_btn)

        self.update_btn = QPushButton('')
        self.update_btn.setObjectName('creamPill')
        self.update_btn.hide()
        row.addWidget(self.update_btn)

        self.lang_btn = QPushButton(self.m.lang.toggle_label)
        self.lang_btn.setFixedWidth(92)
        self.lang_btn.clicked.connect(self.m.toggle_lang)
        self.lang_btn.hide()   # Language selection lives in Settings -> App -> Language, matching the Mac SwiftUI top bar

        # Built-in Frameless Window Controls (Minimize / Maximize / Close)
        win_ctrl_wrap = QHBoxLayout()
        win_ctrl_wrap.setContentsMargins(6, 0, 0, 0)
        win_ctrl_wrap.setSpacing(2)

        self.min_win_btn = QPushButton('—')
        self.min_win_btn.setObjectName('winCtrlBtn')
        self.min_win_btn.setFixedSize(36, 28)
        self.min_win_btn.setCursor(Qt.PointingHandCursor)
        self.min_win_btn.clicked.connect(self.showMinimized)
        win_ctrl_wrap.addWidget(self.min_win_btn)

        self.max_win_btn = QPushButton('□')
        self.max_win_btn.setObjectName('winCtrlBtn')
        self.max_win_btn.setFixedSize(36, 28)
        self.max_win_btn.setCursor(Qt.PointingHandCursor)
        self.max_win_btn.clicked.connect(self._toggle_maximize_window)
        win_ctrl_wrap.addWidget(self.max_win_btn)

        self.close_win_btn = QPushButton('✕')
        self.close_win_btn.setObjectName('winCloseBtn')
        self.close_win_btn.setFixedSize(36, 28)
        self.close_win_btn.setCursor(Qt.PointingHandCursor)
        self.close_win_btn.clicked.connect(self.close)
        win_ctrl_wrap.addWidget(self.close_win_btn)

        row.addLayout(win_ctrl_wrap)

        return bar

    def _switch_page(self, page_id: str) -> None:
        self._current_page = page_id
        self.library_page.setVisible(page_id == 'library')
        self.builds_page.setVisible(page_id == 'builds')
        self.settings_page.setVisible(page_id == 'settings')
        self.stack.setCurrentIndex(0)
        self.scroll.verticalScrollBar().setValue(0)
        for pid, btn in self.nav_btns.items():
            btn.setObjectName('navTabActive' if pid == page_id else 'navTab')
            btn.style().unpolish(btn)
            btn.style().polish(btn)
        self.search_input.setVisible(page_id == 'library')
        self.new_build_btn.setVisible(page_id != 'builds')
        self.top_bar.recenter_nav()
        self._refresh_activity_bar()
        if page_id == 'library':
            self._refresh_library()

    # ================================================================ Engine Banner

    def _build_engine_banner(self) -> QFrame:
        box = QFrame()
        box.setObjectName('bannerCard')
        box.setContentsMargins(28, 8, 28, 0)
        col = QVBoxLayout(box)
        col.setContentsMargins(16, 12, 16, 12)
        col.setSpacing(6)
        self.engine_sync_label = QLabel()
        self.engine_sync_label.setWordWrap(True)
        col.addWidget(self.engine_sync_label)
        self.engine_fail_what = QLabel()
        self.engine_fail_what.setStyleSheet('font-weight: 700;')
        self.engine_fail_what.setWordWrap(True)
        col.addWidget(self.engine_fail_what)
        self.engine_fail_next = QLabel()
        self.engine_fail_next.setObjectName('muted')
        self.engine_fail_next.setWordWrap(True)
        col.addWidget(self.engine_fail_next)
        row = QHBoxLayout()
        self.engine_retry_btn = QPushButton()
        self.engine_retry_btn.clicked.connect(lambda: self.m.sync_engine())
        row.addWidget(self.engine_retry_btn)
        row.addStretch(1)
        col.addLayout(row)
        box.hide()
        return box

    def _refresh_engine_banner(self) -> None:
        f = self.m.engine_failure
        if self.m.engine_syncing:
            self.engine_sync_label.setText(self.m.t('engine.syncing'))
            self.engine_sync_label.show()
            self.engine_fail_what.hide()
            self.engine_fail_next.hide()
            self.engine_retry_btn.hide()
            self.engine_banner.show()
        elif f is not None:
            self.engine_sync_label.hide()
            self.engine_fail_what.setText(self.m.t(f.what_key))
            self.engine_fail_next.setText(self.m.t(f.next_key))
            self.engine_retry_btn.setText(self.m.t('fail.retry'))
            self.engine_fail_what.show()
            self.engine_fail_next.show()
            self.engine_retry_btn.show()
            self.engine_banner.show()
        else:
            self.engine_banner.hide()

    # ================================================================ Page 0: Library

    def _build_library_page(self) -> QWidget:
        page = QWidget()
        lay = QVBoxLayout(page)
        lay.setContentsMargins(0, 0, 0, 0)
        lay.setSpacing(0)

        self.lib_stack = QStackedWidget()

        # 0A: Empty Library Welcome State (mirrors emptyLibrary in LauncherView+Library.swift)
        empty = QWidget()
        ecol = QVBoxLayout(empty)
        ecol.setContentsMargins(40, 60, 40, 60)
        ecol.setSpacing(14)
        ecol.addStretch(1)

        icon_lbl = QLabel('🎮')
        icon_lbl.setAlignment(Qt.AlignCenter)
        icon_lbl.setStyleSheet('font-size: 46px;')
        ecol.addWidget(icon_lbl)

        self.lib_welcome_title = QLabel(self.m.t('library.welcome'))
        self.lib_welcome_title.setAlignment(Qt.AlignCenter)
        self.lib_welcome_title.setStyleSheet('font-size: 40px; font-weight: 800; color: #ffffff;')
        ecol.addWidget(self.lib_welcome_title)

        self.lib_welcome_note = QLabel(self.m.t('library.welcomeNote'))
        self.lib_welcome_note.setObjectName('pageNote')
        self.lib_welcome_note.setAlignment(Qt.AlignCenter)
        self.lib_welcome_note.setWordWrap(True)
        ecol.addWidget(self.lib_welcome_note)
        ecol.addSpacing(10)

        btn_row = QHBoxLayout()
        btn_row.addStretch(1)
        self.lib_first_build_btn = QPushButton('+ ' + self.m.t('library.firstBuild'))
        self.lib_first_build_btn.setObjectName('primary')
        self.lib_first_build_btn.setCursor(Qt.PointingHandCursor)
        self.lib_first_build_btn.clicked.connect(lambda: self._switch_page('builds'))
        btn_row.addWidget(self.lib_first_build_btn)

        self.lib_choose_folder_btn = QPushButton(self.m.t('library.chooseFolder'))
        self.lib_choose_folder_btn.setCursor(Qt.PointingHandCursor)
        self.lib_choose_folder_btn.clicked.connect(self._pick_library_folder)
        btn_row.addWidget(self.lib_choose_folder_btn)
        btn_row.addStretch(1)
        ecol.addLayout(btn_row)
        ecol.addStretch(1)
        self.lib_stack.addWidget(empty)

        # 0B: Populated Library (Hero showcase + Collection horizontal strip)
        pop = QWidget()
        pcol = QVBoxLayout(pop)
        pcol.setContentsMargins(0, 0, 0, 0)
        pcol.setSpacing(0)

        self.hero = HeroBannerWidget()
        self.hero.primaryClicked.connect(self._on_hero_primary)
        self.hero.manageClicked.connect(self._show_manage_menu)
        pcol.addWidget(self.hero, 1)

        # Collection section below Hero
        coll_wrap = QWidget()
        ccol = QVBoxLayout(coll_wrap)
        ccol.setContentsMargins(36, 14, 36, 20)
        ccol.setSpacing(12)

        chead = QHBoxLayout()
        chead.setSpacing(14)
        self.coll_title_lbl = QLabel(self.m.t('library.collection'))
        self.coll_title_lbl.setStyleSheet('font-size: 18px; font-weight: 800;')
        chead.addWidget(self.coll_title_lbl)

        self.coll_filter_seg = LauncherSegmented(
            [('owned', self.m.t('filter.owned')), ('built', self.m.t('filter.built'))],
            selected='owned',
        )
        self.coll_filter_seg.changed.connect(self._on_library_filter_changed)
        chead.addWidget(self.coll_filter_seg)

        self.coll_count_lbl = QLabel('')
        self.coll_count_lbl.setObjectName('muted')
        chead.addWidget(self.coll_count_lbl)
        chead.addStretch(1)

        self.rescan_lib_btn = QPushButton(self.m.t('library.rescan'))
        self.rescan_lib_btn.setObjectName('ghost')
        self.rescan_lib_btn.clicked.connect(self._rescan_library)
        chead.addWidget(self.rescan_lib_btn)

        scroll_left_btn = QPushButton('‹')
        scroll_left_btn.setFixedSize(30, 30)
        scroll_left_btn.setStyleSheet('padding: 0px; font-size: 16px; font-weight: 700;')
        scroll_left_btn.clicked.connect(lambda: self._scroll_collection(-1))
        scroll_right_btn = QPushButton('›')
        scroll_right_btn.setFixedSize(30, 30)
        scroll_right_btn.setStyleSheet('padding: 0px; font-size: 16px; font-weight: 700;')
        scroll_right_btn.clicked.connect(lambda: self._scroll_collection(1))
        chead.addWidget(scroll_left_btn)
        chead.addWidget(scroll_right_btn)
        ccol.addLayout(chead)

        self._coll_offset = 0
        self._ensure_selected_card_visible = False
        self.coll_viewport = HorizontalStripViewport(height=176)
        self.coll_strip = self.coll_viewport.strip
        self.coll_strip_layout = self.coll_viewport.strip_layout
        ccol.addWidget(self.coll_viewport)

        pcol.addWidget(coll_wrap)
        self.lib_stack.addWidget(pop)

        lay.addWidget(self.lib_stack, 1)
        return page

    def _filtered_games(self) -> list[lib.LibraryGame]:
        games = list(self.m.library.games)
        if self._library_filter == 'built':
            games = [g for g in games if g.has_any_build]
        if self._search_query:
            q = self._search_query.lower()
            games = [g for g in games if q in g.name.lower() or q in g.title_id.lower()]
        return games

    def _refresh_library(self) -> None:
        self.lib_welcome_title.setText(self.m.t('library.welcome'))
        self.lib_welcome_note.setText(self.m.t('library.welcomeNote'))
        self.lib_first_build_btn.setText('+ ' + self.m.t('library.firstBuild'))
        self.lib_choose_folder_btn.setText(self.m.t('library.chooseFolder'))
        self.coll_title_lbl.setText(self.m.t('library.collection'))
        self.coll_filter_seg.set_items(
            [('owned', self.m.t('filter.owned')), ('built', self.m.t('filter.built'))],
            selected=self._library_filter,
        )
        self.rescan_lib_btn.setText(self.m.t('library.rescan'))

        if not self.m.library.games:
            self.lib_stack.setCurrentIndex(0)
            return

        self.lib_stack.setCurrentIndex(1)
        filtered = self._filtered_games()
        self.coll_count_lbl.setText(self.m.t('library.gameCount', len(filtered)))

        sel = self.m.library.selected
        if sel not in filtered and filtered:
            sel = filtered[0]
            self.m.library.select(sel.title_id)

        if sel:
            if self.m.running and self.m.build_key.upper() == sel.title_id.upper():
                st_text = self.m.t('library.building')
                st_color = style.AMBER
                p_label = self.m.t('library.viewBuild')
                p_en = True
            elif sel.has_ipa or sel.has_archive:
                st_text = self.m.t('library.readyIOS')
                st_color = style.GREEN
                p_label = self.m.t('install.reveal')
                p_en = True
            else:
                st_text = self.m.t('library.notBuilt')
                st_color = style.NEUTRAL_DOT
                p_label = self.m.t('build.startGame')
                p_en = not self.m.running

            sub_parts = [sel.title_id]
            if sel.has_ipa:
                sub_parts.append(sel.ipa_path)
            elif sel.inputs.get('base'):
                sub_parts.append(sel.inputs['base'][0])

            art = self.m.artwork.image_path(sel.title_id, self.m.engine_path)
            self.hero.set_data(
                title_id=sel.title_id,
                title=sel.name,
                subtitle='  ·  '.join(sub_parts),
                status_text=st_text,
                status_color=st_color,
                primary_label=p_label,
                primary_enabled=p_en,
                manage_label=self.m.t('library.manage'),
                image_path=art,
                is_switch2=sel.is_switch2(self.m.engine_path),
                switch2_label=self.m.t('switch2.badge'),
            )

        # Rebuild horizontal strip
        while self.coll_strip_layout.count():
            it = self.coll_strip_layout.takeAt(0)
            w_old = it.widget()
            if w_old:
                w_old.hide()
                w_old.setParent(None)
                w_old.deleteLater()

        selected_card: GameCardWidget | None = None
        if not filtered:
            no_lbl = QLabel(self.m.t('library.noResults'))
            no_lbl.setObjectName('muted')
            self.coll_strip_layout.addWidget(no_lbl)
        else:
            for g in filtered:
                dot_c = style.GREEN if g.has_any_build else style.NEUTRAL_DOT
                art = self.m.artwork.image_path(g.title_id, self.m.engine_path)
                is_sel = sel is not None and g.title_id == sel.title_id
                card = GameCardWidget(
                    title_id=g.title_id,
                    title=g.name,
                    image_path=art,
                    selected=is_sel,
                    dot_color=dot_c,
                    is_switch2=g.is_switch2(self.m.engine_path),
                    switch2_label=self.m.t('switch2.badge'),
                )
                if is_sel:
                    selected_card = card
                card.clicked.connect(self._on_card_selected)
                card.doubleClicked.connect(self._on_card_double_clicked)
                self.coll_strip_layout.addWidget(card)
        self.coll_strip_layout.addStretch(1)
        self.coll_viewport.sync_strip(
            ensure_visible=selected_card if self._ensure_selected_card_visible else None
        )
        self._ensure_selected_card_visible = False

    def _on_card_selected(self, title_id: str) -> None:
        self._ensure_selected_card_visible = True
        self.m.library.select(title_id)
        self._refresh_library()

    def _on_card_double_clicked(self, title_id: str) -> None:
        self.m.library.select(title_id)
        g = self.m.library.selected
        if g:
            self.m.load_game_from_library(g)
            self._switch_page('builds')

    def _on_hero_primary(self) -> None:
        g = self.m.library.selected
        if not g:
            return
        if self.m.running and self.m.build_key.upper() == g.title_id.upper():
            self._switch_page('builds')
            return
        if g.has_ipa:
            pu.reveal(g.ipa_path)
        elif g.has_archive:
            pu.reveal(g.archive_path)
        else:
            self.m.load_game_from_library(g)
            self._switch_page('builds')

    def _show_manage_menu(self, anchor: QWidget) -> None:
        g = self.m.library.selected
        if not g:
            return
        menu = QMenu(self)
        menu.setStyleSheet(
            f'QMenu {{ background: #1c1c1f; color: {style.TEXT}; border: 1px solid {style.BORDER}; '
            f'border-radius: 10px; padding: 6px; }} '
            f'QMenu::item {{ padding: 7px 18px; border-radius: 6px; }} '
            f'QMenu::item:selected {{ background: rgba(255,255,255,0.12); }}'
        )

        act_build = menu.addAction(self.m.t('library.buildAgain') if g.has_any_build else self.m.t('build.startGame'))
        act_build.triggered.connect(lambda: (self.m.load_game_from_library(g), self._switch_page('builds')))

        act_cheats = menu.addAction(self.m.t('cheats.menu'))
        act_cheats.triggered.connect(lambda: CheatsDialog(self.m, g, self).exec())

        act_art = menu.addAction(self.m.t('library.changeArtwork'))
        act_art.triggered.connect(lambda: self._pick_custom_artwork(g))

        if self.m.artwork.has_custom(g.title_id):
            act_reset_art = menu.addAction(self.m.t('library.resetArtwork'))
            act_reset_art.triggered.connect(lambda: (self.m.artwork.clear_custom(g.title_id), self._refresh_library()))

        target_reveal = g.ipa_path if g.has_ipa else (g.archive_path if g.has_archive else ((g.inputs.get('base') or [''])[0]))
        if target_reveal and os.path.exists(target_reveal):
            act_reveal = menu.addAction(self.m.t('install.reveal'))
            act_reveal.triggered.connect(lambda: pu.reveal(target_reveal))

        act_free = menu.addAction(self.m.t('free.menu'))
        act_free.triggered.connect(lambda: FreeSpaceDialog(self.m, g, self).exec())

        menu.addSeparator()

        act_remove = menu.addAction(self.m.t('library.remove'))
        act_remove.triggered.connect(lambda: (self.m.library.remove(g.title_id), self._refresh_library()))

        act_delete = menu.addAction(self.m.t('delete.menu'))
        act_delete.triggered.connect(lambda: self._delete_game_dialog(g))

        menu.exec(anchor.mapToGlobal(anchor.rect().bottomLeft()))

    def _pick_custom_artwork(self, game: lib.LibraryGame) -> None:
        f, _ = QFileDialog.getOpenFileName(
            self,
            self.m.t('library.changeArtwork'),
            '',
            'Images (*.png *.jpg *.jpeg *.webp)',
        )
        if f:
            self.m.artwork.set_custom(game.title_id, f)
            self._refresh_library()

    def _delete_game_dialog(self, game: lib.LibraryGame) -> None:
        dlg = DeleteGameDialog(self.m, game, self)
        dlg.exec()
        if dlg.confirmed:
            self._refresh_library()

    def _on_library_filter_changed(self, flt: str) -> None:
        self._library_filter = flt
        self._refresh_library()

    def _on_search_changed(self, text: str) -> None:
        self._search_query = text.strip()
        if self._current_page == 'library':
            self._refresh_library()

    def _scroll_collection(self, direction: int) -> None:
        filtered = self._filtered_games()
        if not filtered:
            return
        sel = self.m.library.selected
        cur_idx = next(
            (i for i, g in enumerate(filtered) if sel is not None and g.title_id == sel.title_id),
            self._coll_offset,
        )
        self._coll_offset = max(0, min(max(0, len(filtered) - 1), cur_idx + direction))
        self._ensure_selected_card_visible = True
        self.m.library.select(filtered[self._coll_offset].title_id)
        self._refresh_library()

    def _pick_library_folder(self) -> None:
        d = QFileDialog.getExistingDirectory(
            self,
            self.m.t('library.folderTitle'),
            self.m.library.games_folder or str(Path.home()),
        )
        if d:
            self.m.library.set_games_folder(d, repo_path=self.m.engine_path, default_keys=self.m.keys_path)
            for g in self.m.library.games:
                self.m.artwork.request_banner_async(g.title_id)
            self._refresh_all()

    def _rescan_library(self) -> None:
        if not self.m.library.games_folder:
            self._pick_library_folder()
            return
        self.m.library.rescan_games_folder(repo_path=self.m.engine_path, default_keys=self.m.keys_path)
        for g in self.m.library.games:
            self.m.artwork.request_banner_async(g.title_id)
        self._refresh_library()

    # ================================================================ Page 1: Builds

    def _build_builds_page(self) -> QWidget:
        body = QWidget()
        self.body_col = QVBoxLayout(body)
        self.body_col.setContentsMargins(40, 28, 40, 36)
        self.body_col.setSpacing(20)

        # Page heading
        self.build_heading = CardPageHeading(self.m.t('build.heading'), self.m.t('build.intro'))
        self.body_col.addWidget(self.build_heading)

        self.running_setup = QToolButton()
        self.running_setup.setCheckable(True)
        self.running_setup.setToolButtonStyle(Qt.ToolButtonTextBesideIcon)
        self.running_setup.toggled.connect(self._refresh_build_inputs)
        self.body_col.addWidget(self.running_setup, 0, Qt.AlignLeft)

        # Setup Hint Card (shown when repo or required deps are not ready)
        self.setup_hint_card = self._build_setup_hint_card()
        self.body_col.addWidget(self.setup_hint_card)

        # Card 1: Game Files (FilesCard)
        self.files_group = self._build_files_card()
        self.body_col.addWidget(self.files_group)

        # Card 2: Play on / Target & BC texture option (TargetCard)
        self.target_group = self._build_target_card()
        self.body_col.addWidget(self.target_group)

        # Card 3: Install or Export / Shared App vs One-Game IPA + Drive Copy (InstallCard)
        self.install_group = self._build_install_card()
        self.body_col.addWidget(self.install_group)

        # Card 4: Action + BuildFailureCard + OutcomeCard
        self.action_group = self._build_action_card()
        self.body_col.addWidget(self.action_group)

        # Card 5: Progress Card
        self.stages_card = self._build_stages_card()
        self.body_col.addWidget(self.stages_card)

        # Card 6: Build Log Card (at the bottom of `self.scroll` so `test_build_failure.py` geometry checks pass)
        self.log_group = self._build_log_card()
        self.body_col.addWidget(self.log_group)

        self.body_col.addStretch(1)
        return body

    def _build_setup_hint_card(self) -> CardGroup:
        grp = CardGroup(title=self.m.t('section.setup'))
        r = QWidget()
        rl = QHBoxLayout(r)
        rl.setContentsMargins(18, 13, 18, 13)
        rl.setSpacing(12)
        self.setup_hint_dot = _dot(style.AMBER)
        rl.addWidget(self.setup_hint_dot)
        col = QVBoxLayout()
        col.setSpacing(2)
        self.setup_hint_title = QLabel(self.m.t('library.setupHint'))
        self.setup_hint_title.setObjectName('rowTitle')
        self.setup_hint_sub = QLabel('')
        self.setup_hint_sub.setObjectName('muted')
        self.setup_hint_sub.setWordWrap(True)
        col.addWidget(self.setup_hint_title)
        col.addWidget(self.setup_hint_sub)
        rl.addLayout(col, 1)
        self.setup_goto_btn = QPushButton(self.m.t('nav.settings'))
        self.setup_goto_btn.setObjectName('creamPill')
        self.setup_goto_btn.clicked.connect(lambda: self._switch_page('settings'))
        rl.addWidget(self.setup_goto_btn)
        grp.add_row(r)
        return grp

    def _build_files_card(self) -> CardGroup:
        grp = CardGroup(title=self.m.t('section.files'), footer=self.m.t('msg.workdirHint'))

        # Row 1: Game folder CTA (cream capsule button)
        r_folder = QWidget()
        rf_lay = QHBoxLayout(r_folder)
        rf_lay.setContentsMargins(18, 14, 18, 14)
        rf_lay.setSpacing(12)
        self.folder_cta_dot = _dot(style.NEUTRAL_DOT)
        rf_lay.addWidget(self.folder_cta_dot)
        fcol = QVBoxLayout()
        fcol.setSpacing(2)
        self.folder_cta_title = QLabel(self.m.t('build.folderCTA') + ' · ' + self.m.t('data.note'))
        self.folder_cta_title.setObjectName('rowTitle')
        self.folder_cta_sub = QLabel(self.m.t('build.folderNote') + ' (' + self.m.t('data.folderHint') + ')')
        self.folder_cta_sub.setObjectName('muted')
        self.folder_cta_sub.setWordWrap(True)
        fcol.addWidget(self.folder_cta_title)
        fcol.addWidget(self.folder_cta_sub)
        rf_lay.addLayout(fcol, 1)
        self.pick_folder_btn = QPushButton(self.m.t('data.pickFolder'))
        self.pick_folder_btn.setObjectName('creamPill')
        self.pick_folder_btn.setFixedWidth(184)
        self.pick_folder_btn.clicked.connect(self._pick_game_dir)
        rf_lay.addWidget(self.pick_folder_btn)
        grp.add_row(r_folder)
        grp.add_divider()

        self.input_rows: dict[str, dict] = {}

        # Row 2 & 3: Required slots (base, keys)
        for idx, (key, title_key, req, multi) in enumerate([
            ('base', 'data.base', True, False),
            ('keys', 'data.keys', True, False),
        ]):
            if idx > 0:
                grp.add_divider()
            grp.add_row(self._make_input_slot_row(key, title_key, req, multi))

        # KeyCheck live verification row (under prod.keys)
        self.keycheck_row = QWidget()
        kc_lay = QHBoxLayout(self.keycheck_row)
        kc_lay.setContentsMargins(38, 4, 18, 10)
        kc_lay.setSpacing(8)
        self.keycheck_dot = _dot(style.GREEN)
        self.keycheck_lbl = QLabel('')
        self.keycheck_lbl.setObjectName('muted')
        self.keycheck_lbl.setWordWrap(True)
        kc_lay.addWidget(self.keycheck_dot)
        kc_lay.addWidget(self.keycheck_lbl, 1)
        self.keycheck_row.hide()
        grp.add_row(self.keycheck_row)
        grp.add_divider()

        # Row 4: Disclosure for Updates & DLC (optional)
        disc_head = QWidget()
        dh_lay = QHBoxLayout(disc_head)
        dh_lay.setContentsMargins(18, 10, 18, 10)
        self.opt_toggle_btn = QPushButton('▾  ' + self.m.t('build.options'))
        self.opt_toggle_btn.setObjectName('ghost')
        self.opt_toggle_btn.clicked.connect(self._toggle_optional_inputs)
        dh_lay.addWidget(self.opt_toggle_btn)
        dh_lay.addStretch(1)
        grp.add_row(disc_head)

        self.opt_container = QWidget()
        opt_col = QVBoxLayout(self.opt_container)
        opt_col.setContentsMargins(0, 0, 0, 0)
        opt_col.setSpacing(0)
        opt_col.addWidget(self._make_input_slot_row('update', 'data.update', False, False))
        opt_col.addWidget(self._make_input_slot_row('dlc', 'data.dlc', False, True))
        grp.add_row(self.opt_container)
        grp.add_divider()

        # Row 5: Output folder (build.saveTo)
        out_row = QWidget()
        or_lay = QHBoxLayout(out_row)
        or_lay.setContentsMargins(18, 12, 18, 12)
        or_lay.setSpacing(12)
        or_lay.addWidget(_dot(style.NEUTRAL_DOT))
        ocol = QVBoxLayout()
        ocol.setSpacing(2)
        self.out_title_lbl = QLabel(self.m.t('build.saveTo'))
        self.out_title_lbl.setObjectName('rowTitle')
        self.out_label = QLabel(self.m.t('build.saveDefault'))
        self.out_label.setObjectName('mono')
        ocol.addWidget(self.out_title_lbl)
        ocol.addWidget(self.out_label)
        or_lay.addLayout(ocol, 1)
        self.out_clear_btn = QPushButton(self.m.t('data.clear'))
        self.out_clear_btn.setObjectName('ghost')
        self.out_clear_btn.clicked.connect(self._clear_out_dir)
        self.out_clear_btn.hide()
        or_lay.addWidget(self.out_clear_btn)
        self.out_btn = QPushButton(self.m.t('build.outDir'))
        self.out_btn.setFixedWidth(184)
        self.out_btn.clicked.connect(self._pick_out_dir)
        or_lay.addWidget(self.out_btn)
        grp.add_row(out_row)

        return grp

    def _make_input_slot_row(self, key: str, title_key: str, req: bool, multi: bool) -> QWidget:
        w = QWidget()
        r = QHBoxLayout(w)
        r.setContentsMargins(18, 11, 18, 11)
        r.setSpacing(12)
        dot = _dot(style.NEUTRAL_DOT)
        r.addWidget(dot)
        col = QVBoxLayout()
        col.setSpacing(2)
        title = QLabel(self.m.t(title_key))
        title.setObjectName('rowTitle')
        path = QLabel()
        path.setObjectName('mono')
        path.setWordWrap(True)
        col.addWidget(title)
        col.addWidget(path)
        r.addLayout(col, 1)

        clear = QPushButton(self.m.t('data.clear'))
        clear.setObjectName('ghost')
        clear.clicked.connect(lambda _=False, k=key: self._clear_input(k))
        r.addWidget(clear)

        choose = QPushButton(self.m.t('data.choose'))
        choose.setFixedWidth(184)
        choose.clicked.connect(lambda _=False, k=key, m=multi: self._pick_input(k, m))
        r.addWidget(choose)

        self.input_rows[key] = {
            'dot': dot,
            'title': title,
            'title_key': title_key,
            'path': path,
            'clear': clear,
            'choose': choose,
            'req': req,
        }
        return w

    def _toggle_optional_inputs(self) -> None:
        self._options_expanded = not self._options_expanded
        self.opt_container.setVisible(self._options_expanded)
        arrow = '▾' if self._options_expanded else '▸'
        self.opt_toggle_btn.setText(f"{arrow}  {self.m.t('build.options')}")

    def _build_target_card(self) -> CardGroup:
        grp = CardGroup(title=self.m.t('section.target'))

        # Platform row
        r_plat = QWidget()
        rp_lay = QHBoxLayout(r_plat)
        rp_lay.setContentsMargins(18, 12, 18, 12)
        rp_lay.setSpacing(12)
        rp_lay.addWidget(_dot(style.GREEN))
        pcol = QVBoxLayout()
        pcol.setSpacing(2)
        self.target_title_lbl = QLabel(self.m.t('build.ios'))
        self.target_title_lbl.setObjectName('rowTitle')
        self.target_hint = QLabel(self.m.t('build.iosNote'))
        self.target_hint.setObjectName('muted')
        self.target_hint.setWordWrap(True)
        pcol.addWidget(self.target_title_lbl)
        pcol.addWidget(self.target_hint)
        rp_lay.addLayout(pcol, 1)

        self.target_btn = QPushButton()
        self.target_btn.clicked.connect(self._toggle_target)
        if pu.IS_WIN:
            self.target_btn.hide()
        rp_lay.addWidget(self.target_btn)
        grp.add_row(r_plat)
        grp.add_divider()

        # Older devices BC texture CPU decode row (opt.bc)
        r_bc = QWidget()
        rbc_lay = QHBoxLayout(r_bc)
        rbc_lay.setContentsMargins(18, 12, 18, 12)
        rbc_lay.setSpacing(12)
        rbc_lay.addWidget(_dot(style.NEUTRAL_DOT))
        bccol = QVBoxLayout()
        bccol.setSpacing(2)
        self.bc_title_lbl = QLabel(self.m.t('opt.bc'))
        self.bc_title_lbl.setObjectName('rowTitle')
        self.bc_note_lbl = QLabel(self.m.t('opt.bc.note'))
        self.bc_note_lbl.setObjectName('muted')
        self.bc_note_lbl.setWordWrap(True)
        bccol.addWidget(self.bc_title_lbl)
        bccol.addWidget(self.bc_note_lbl)
        rbc_lay.addLayout(bccol, 1)
        self.bc_switch = LauncherSwitch(self.m.bc_on_cpu)
        self.bc_switch.toggled.connect(self._on_bc_toggled)
        rbc_lay.addWidget(self.bc_switch)
        grp.add_row(r_bc)

        return grp

    def _on_bc_toggled(self, checked: bool) -> None:
        self.m.bc_on_cpu = checked

    def _build_install_card(self) -> CardGroup:
        grp = CardGroup(title=self.m.t('dev.section'))

        # Row 1: What the IPA holds (Shared app vs One game, all inside)
        r_kind = QWidget()
        rk_lay = QHBoxLayout(r_kind)
        rk_lay.setContentsMargins(18, 12, 18, 12)
        rk_lay.setSpacing(12)
        rk_lay.addWidget(_dot(style.GREEN))
        kcol = QVBoxLayout()
        kcol.setSpacing(2)
        self.ipa_kind_title = QLabel(self.m.t('shell.ipaKind'))
        self.ipa_kind_title.setObjectName('rowTitle')
        self.ipa_kind_note = QLabel(self.m.t('shell.ipaSharedNote'))
        self.ipa_kind_note.setObjectName('muted')
        self.ipa_kind_note.setWordWrap(True)
        kcol.addWidget(self.ipa_kind_title)
        kcol.addWidget(self.ipa_kind_note)
        rk_lay.addLayout(kcol, 1)

        self.ipa_kind_seg = LauncherSegmented(
            [
                ('shared', self.m.t('shell.ipaShared')),
                ('oneGame', self.m.t('shell.ipaOneGame')),
            ],
            selected=self.m.ipa_kind,
        )
        self.ipa_kind_seg.changed.connect(self._on_ipa_kind_changed)
        rk_lay.addWidget(self.ipa_kind_seg)
        grp.add_row(r_kind)
        grp.add_divider()

        # Step 1: Export IPA
        r_s1 = QWidget()
        rs1_lay = QHBoxLayout(r_s1)
        rs1_lay.setContentsMargins(18, 11, 18, 11)
        rs1_lay.setSpacing(10)
        s1_col = QVBoxLayout()
        self.step1_title = QLabel('①  ' + self.m.t('shell.step1Title'))
        self.step1_title.setObjectName('rowTitle')
        self.step1_sub = QLabel(self.m.t('shell.step1Sub'))
        self.step1_sub.setObjectName('muted')
        self.step1_sub.setWordWrap(True)
        s1_col.addWidget(self.step1_title)
        s1_col.addWidget(self.step1_sub)
        rs1_lay.addLayout(s1_col, 1)

        self.step1_reveal_btn = QPushButton(self.m.t('shell.showInFinder'))
        self.step1_reveal_btn.clicked.connect(lambda: pu.reveal(self._effective_ipa_path()))
        self.step1_reveal_btn.hide()
        rs1_lay.addWidget(self.step1_reveal_btn)
        grp.add_row(r_s1)
        grp.add_divider()

        # Step 2: Install with your own tool (AltStore / SideStore)
        r_s2 = QWidget()
        rs2_lay = QHBoxLayout(r_s2)
        rs2_lay.setContentsMargins(18, 11, 18, 11)
        s2_col = QVBoxLayout()
        self.step2_title = QLabel('②  ' + self.m.t('shell.step2Title'))
        self.step2_title.setObjectName('rowTitle')
        self.step2_sub = QLabel(self.m.t('shell.step2Sub'))
        self.step2_sub.setObjectName('muted')
        self.step2_sub.setWordWrap(True)
        s2_col.addWidget(self.step2_title)
        s2_col.addWidget(self.step2_sub)
        rs2_lay.addLayout(s2_col, 1)
        grp.add_row(r_s2)

        # Step 3: Send game data to drive or folder (shown when shared app mode)
        self.step3_container = QWidget()
        s3_outer = QVBoxLayout(self.step3_container)
        s3_outer.setContentsMargins(0, 0, 0, 0)
        s3_outer.setSpacing(0)
        s3_outer.addWidget(make_divider())

        r_s3 = QWidget()
        rs3_lay = QHBoxLayout(r_s3)
        rs3_lay.setContentsMargins(18, 11, 18, 11)
        rs3_lay.setSpacing(10)
        s3_col = QVBoxLayout()
        s3_col.setSpacing(3)
        self.step3_title = QLabel('③  ' + self.m.t('shell.step3Title') + ' · ' + self.m.t('shell.whereDrive'))
        self.step3_title.setObjectName('rowTitle')
        self.drive_path_lbl = QLabel(self.m.t('shell.driveNone'))
        self.drive_path_lbl.setObjectName('mono')
        self.drive_path_lbl.setWordWrap(True)
        self.step3_sub = QLabel(self.m.t('shell.copyExternalNote'))
        self.step3_sub.setObjectName('muted')
        self.step3_sub.setWordWrap(True)
        s3_col.addWidget(self.step3_title)
        s3_col.addWidget(self.drive_path_lbl)
        s3_col.addWidget(self.step3_sub)
        rs3_lay.addLayout(s3_col, 1)

        self.step3_open_romfs_btn = QPushButton(self.m.t('shell.showInFinder'))
        self.step3_open_romfs_btn.clicked.connect(lambda: pu.reveal(self._effective_archive_path()))
        self.step3_open_romfs_btn.hide()
        rs3_lay.addWidget(self.step3_open_romfs_btn)

        self.drive_choose_btn = QPushButton(self.m.t('shell.driveChoose'))
        self.drive_choose_btn.clicked.connect(self._pick_drive_folder)
        rs3_lay.addWidget(self.drive_choose_btn)

        self.drive_copy_btn = QPushButton(self.m.t('shell.driveCopy'))
        self.drive_copy_btn.setObjectName('creamPill')
        self.drive_copy_btn.clicked.connect(self._copy_archive_to_drive)
        rs3_lay.addWidget(self.drive_copy_btn)
        s3_outer.addWidget(r_s3)
        grp.add_row(self.step3_container)

        return grp

    def _shell_ipa_path(self) -> str:
        """The shared app's only output, whatever mode ran last."""
        return lib.shell_ipa_path(self.m.shell_cache_path)

    def _one_game_ipa_path(self) -> str:
        return lib.one_game_ipa_path(self.m.out_dir, self.m.build_key)

    def _effective_ipa_path(self) -> str:
        # The two kinds write different files, so the reveal button answers for the kind that is
        # selected now: `self.m.ipa_path` alone would name the other mode's IPA after a switch.
        sel = self.m.library.selected
        return lib.reveal_ipa_path(
            ipa_kind=self.m.ipa_kind,
            shell_cache=self.m.shell_cache_path,
            out_dir=self.m.out_dir,
            build_key=self.m.build_key,
            last_ipa=self.m.ipa_path,
            library_ipa=sel.ipa_path if (sel and sel.has_ipa) else '',
        )

    def _effective_archive_path(self) -> str:
        eff = self.m.effective_archive_path()
        if eff and os.path.isdir(eff):
            return eff
        sel = self.m.library.selected
        if sel and sel.has_archive:
            return sel.archive_path
        return self.m.archive_path

    def _on_ipa_kind_changed(self, kind: str) -> None:
        self.m.ipa_kind = kind
        self._refresh_install_card()

    def _refresh_install_card(self) -> None:
        self.install_group.set_title(self.m.t('dev.section'))
        self.ipa_kind_title.setText(self.m.t('shell.ipaKind'))
        self.ipa_kind_seg.set_items(
            [
                ('shared', self.m.t('shell.ipaShared')),
                ('oneGame', self.m.t('shell.ipaOneGame')),
            ],
            selected=self.m.ipa_kind,
        )
        one = self.m.ipa_kind == 'oneGame'
        self.ipa_kind_note.setText(self.m.t('shell.ipaOneGameNote' if one else 'shell.ipaSharedNote'))
        self.step1_title.setText('①  ' + self.m.t('shell.step1Title'))
        self.step1_sub.setText(self.m.t('shell.oneGameSub' if one else 'shell.step1Sub'))
        ipa_p = self._effective_ipa_path()
        has_ipa = bool(ipa_p and os.path.exists(ipa_p))
        self.step1_reveal_btn.setText(self.m.t('shell.showInFinder'))
        self.step1_reveal_btn.setToolTip(self.m.t('msg.ipaAt', ipa_p) if has_ipa else '')
        self.step1_reveal_btn.setVisible(has_ipa)
        self.step2_title.setText('②  ' + self.m.t('shell.step2Title'))
        self.step2_sub.setText(self.m.t('shell.oneGameStep2Sub' if one else 'shell.step2Sub'))
        self.step3_title.setText('③  ' + self.m.t('shell.step3Title') + ' · ' + self.m.t('shell.whereDrive'))
        self.drive_path_lbl.setText(self._drive_folder or self.m.t('shell.driveNone'))
        self.step3_open_romfs_btn.setText(self.m.t('shell.showInFinder'))
        self.drive_choose_btn.setText(self.m.t('shell.driveChoose'))
        self.drive_copy_btn.setText(self.m.t('shell.driveCopy'))
        self.step3_container.setVisible(not one)
        arch_p = self._effective_archive_path()
        has_arch = bool(arch_p and os.path.isdir(arch_p))
        self.step3_open_romfs_btn.setToolTip(self.m.t('msg.archiveAt', arch_p) if has_arch else '')
        self.step3_open_romfs_btn.setVisible(has_arch)
        self.drive_copy_btn.setEnabled(has_arch)

    def _pick_drive_folder(self) -> None:
        d = QFileDialog.getExistingDirectory(self, self.m.t('shell.driveChoose'), self._drive_folder or str(Path.home()))
        if d:
            self._drive_folder = d
            self.drive_path_lbl.setText(d)
            self._refresh_install_card()

    def _copy_archive_to_drive(self) -> None:
        arch_p = self._effective_archive_path()
        if not arch_p or not os.path.isdir(arch_p):
            return
        if not self._drive_folder:
            d = QFileDialog.getExistingDirectory(self, self.m.t('shell.driveChoose'), str(Path.home()))
            if not d:
                return
            self._drive_folder = d
            self.drive_path_lbl.setText(d)
        ok, info = self.m.copy_archive_to_drive(self._drive_folder)
        if ok:
            self.step3_sub.setText(self.m.t('shell.driveDone', info, self.m.t('ios.ui.gameData')))
        else:
            self.step3_sub.setText(self.m.t('shell.driveFailed', info))

    def _build_action_card(self) -> CardGroup:
        grp = CardGroup()
        r = QWidget()
        act = QHBoxLayout(r)
        act.setContentsMargins(18, 14, 18, 14)
        act.setSpacing(12)

        self.build_btn = QPushButton(self.m.t('build.start'))
        self.build_btn.setObjectName('primary')
        self.build_btn.setMinimumWidth(190)
        self.build_btn.clicked.connect(self._build_clicked)
        act.addWidget(self.build_btn)

        self.footer = QLabel('')
        self.footer.setObjectName('muted')
        self.footer.setWordWrap(True)
        self.footer.setTextInteractionFlags(Qt.TextSelectableByMouse)
        act.addWidget(self.footer, 1)

        self.reveal_ipa_btn = QPushButton(f"{self.m.t('shell.showInFinder')} (IPA)")
        self.reveal_ipa_btn.clicked.connect(lambda: pu.reveal(self.m.ipa_path))
        self.reveal_ipa_btn.hide()
        act.addWidget(self.reveal_ipa_btn)

        self.reveal_arc_btn = QPushButton(f"{self.m.t('shell.showInFinder')} (romfs)")
        self.reveal_arc_btn.clicked.connect(lambda: pu.reveal(self.m.archive_path))
        self.reveal_arc_btn.hide()
        act.addWidget(self.reveal_arc_btn)

        self.reveal_app_btn = QPushButton('.app')
        self.reveal_app_btn.clicked.connect(lambda: pu.reveal(self.m.mac_app_path))
        self.reveal_app_btn.hide()
        act.addWidget(self.reveal_app_btn)

        grp.add_row(r)

        # BuildFailureCard (shown on a known early stop)
        self.failure_box = QFrame()
        self.failure_box.setObjectName('failureCard')
        self.failure_box.setContentsMargins(14, 8, 14, 14)
        fcol = QVBoxLayout(self.failure_box)
        fcol.setContentsMargins(16, 14, 16, 14)
        fcol.setSpacing(6)
        self.failure_title = QLabel()
        self.failure_title.setObjectName('sectionTitle')
        fcol.addWidget(self.failure_title)
        self.failure_what = QLabel()
        self.failure_what.setStyleSheet('font-weight: 700;')
        self.failure_what.setWordWrap(True)
        fcol.addWidget(self.failure_what)
        self.failure_next = QLabel()
        self.failure_next.setObjectName('muted')
        self.failure_next.setWordWrap(True)
        fcol.addWidget(self.failure_next)
        self.title_buttons = QVBoxLayout()
        self.title_buttons.setAlignment(Qt.AlignLeft)
        fcol.addLayout(self.title_buttons)
        frow = QHBoxLayout()
        frow.setSpacing(8)
        self.failure_folder_btn = QPushButton()
        self.failure_folder_btn.clicked.connect(self._open_failure_folder)
        frow.addWidget(self.failure_folder_btn)
        self.failure_fix_btn = QPushButton()
        self.failure_fix_btn.clicked.connect(self._fix_failure)
        frow.addWidget(self.failure_fix_btn)
        self.failure_anyway_btn = QPushButton()
        self.failure_anyway_btn.setObjectName('danger')
        self.failure_anyway_btn.clicked.connect(self._build_anyway)
        frow.addWidget(self.failure_anyway_btn)
        frow.addStretch(1)
        fcol.addLayout(frow)
        self.failure_box.hide()
        grp.add_row(self.failure_box)

        return grp

    def _build_stages_card(self) -> CardGroup:
        grp = CardGroup(title=self.m.t('prog.title'))
        wrap = QWidget()
        col = QVBoxLayout(wrap)
        self.preparing = QLabel()
        col.addWidget(self.preparing)
        self.stages_col = QVBoxLayout()
        col.addLayout(self.stages_col)
        self.stages_col.setContentsMargins(18, 12, 18, 12)
        self.stages_col.setSpacing(8)
        grp.add_row(wrap)
        grp.hide()
        return grp

    def _build_log_card(self) -> CardGroup:
        grp = CardGroup(title=self.m.t('build.log'))
        head = QWidget()
        hl = QHBoxLayout(head)
        hl.setContentsMargins(18, 10, 18, 6)
        self.log_label = QLabel(self.m.t('build.log'))
        self.log_label.setObjectName('rowTitle')
        hl.addWidget(self.log_label)
        hl.addStretch(1)
        self.export_log_btn = QPushButton(self.m.t('log.export'))
        self.export_log_btn.setObjectName('ghost')
        self.export_log_btn.clicked.connect(self._export_log)
        hl.addWidget(self.export_log_btn)
        grp.add_row(head)

        log_wrap = QWidget()
        lw = QVBoxLayout(log_wrap)
        lw.setContentsMargins(14, 4, 14, 14)
        self.log = QPlainTextEdit()
        self.log.setReadOnly(True)
        self.log.setPlaceholderText(self.m.t('log.placeholder'))
        self.log.setMinimumHeight(200)
        lw.addWidget(self.log)
        grp.add_row(log_wrap)
        return grp

    def _export_log(self) -> None:
        f, _ = QFileDialog.getSaveFileName(self, self.m.t('log.export'), 'nx2apple-build.log', 'Log files (*.log *.txt)')
        if f:
            try:
                Path(f).write_text(self.log.toPlainText(), encoding='utf-8')
                self._append_log(self.m.t('log.exported', f) + '\n')
            except OSError as e:
                self._append_log(self.m.t('log.exportFail', str(e)) + '\n')

    # ================================================================ Page 2: Settings

    def _build_settings_page(self) -> QWidget:
        sbody = QWidget()
        scol = QVBoxLayout(sbody)
        scol.setContentsMargins(40, 28, 40, 36)
        scol.setSpacing(22)

        self.settings_heading = CardPageHeading(self.m.t('settings.heading'), self.m.t('settings.note'))
        scol.addWidget(self.settings_heading)

        # 1. Library Card (section.library)
        self.settings_lib_group = CardGroup(title=self.m.t('section.library'))
        r_lib = QWidget()
        rl_lay = QHBoxLayout(r_lib)
        rl_lay.setContentsMargins(18, 13, 18, 13)
        rl_lay.setSpacing(12)
        self.lib_folder_dot = _dot(style.NEUTRAL_DOT)
        rl_lay.addWidget(self.lib_folder_dot)
        lcol = QVBoxLayout()
        lcol.setSpacing(2)
        self.lib_folder_title = QLabel(self.m.t('library.folderTitle'))
        self.lib_folder_title.setObjectName('rowTitle')
        self.lib_folder_path_lbl = QLabel(self.m.t('library.folderUnset'))
        self.lib_folder_path_lbl.setObjectName('mono')
        self.lib_folder_hint_lbl = QLabel(self.m.t('library.folderHint'))
        self.lib_folder_hint_lbl.setObjectName('muted')
        self.lib_folder_hint_lbl.setWordWrap(True)
        lcol.addWidget(self.lib_folder_title)
        lcol.addWidget(self.lib_folder_path_lbl)
        lcol.addWidget(self.lib_folder_hint_lbl)
        rl_lay.addLayout(lcol, 1)

        self.settings_rescan_btn = QPushButton(self.m.t('library.rescan'))
        self.settings_rescan_btn.clicked.connect(self._rescan_library)
        rl_lay.addWidget(self.settings_rescan_btn)

        self.settings_lib_choose_btn = QPushButton(self.m.t('library.chooseFolder'))
        self.settings_lib_choose_btn.setFixedWidth(184)
        self.settings_lib_choose_btn.clicked.connect(self._pick_library_folder)
        rl_lay.addWidget(self.settings_lib_choose_btn)
        self.settings_lib_group.add_row(r_lib)
        scol.addWidget(self.settings_lib_group)

        # 2. Build Tools Card (section.tools: Repo + Deps + Diagnostics)
        self.tools_group = self._build_tools_card()
        scol.addWidget(self.tools_group)

        # 3. App Card (section.app: 13-Language Dropdown + Notify + Setup Wizard + Version)
        self.app_group = self._build_app_card()
        scol.addWidget(self.app_group)

        scol.addStretch(1)
        return sbody

    def _build_tools_card(self) -> CardGroup:
        grp = CardGroup(title=self.m.t('section.tools'))

        # Row 1: Project repository
        r_repo = QWidget()
        repo_col = QVBoxLayout(r_repo)
        repo_col.setContentsMargins(18, 14, 18, 14)
        repo_col.setSpacing(8)

        r1 = QHBoxLayout()
        r1.setSpacing(10)
        self.repo_dot = _dot(style.NEUTRAL_DOT)
        r1.addWidget(self.repo_dot)
        self.repo_title = QLabel(self.m.t('repo.title'))
        self.repo_title.setObjectName('rowTitle')
        r1.addWidget(self.repo_title)
        self.repo_sub = QLabel(self.m.t('repo.note'))
        self.repo_sub.setObjectName('muted')
        r1.addWidget(self.repo_sub, 1)
        self.clone_btn = QPushButton(self.m.t('repo.download'))
        self.clone_btn.setObjectName('creamPill')
        self.clone_btn.clicked.connect(lambda: self.m.clone_repo())
        r1.addWidget(self.clone_btn)
        self.repo_btn = QPushButton(self.m.t('repo.choose'))
        self.repo_btn.clicked.connect(self._pick_repo)
        r1.addWidget(self.repo_btn)
        repo_col.addLayout(r1)

        self.repo_path_label = QLabel()
        self.repo_path_label.setObjectName('mono')
        self.repo_path_label.setWordWrap(True)
        repo_col.addWidget(self.repo_path_label)

        self.repo_hint_label = QLabel()
        self.repo_hint_label.setObjectName('muted')
        self.repo_hint_label.setWordWrap(True)
        self.repo_hint_label.setOpenExternalLinks(True)
        repo_col.addWidget(self.repo_hint_label)

        r2 = QHBoxLayout()
        r2.setSpacing(8)
        self.repo_status_label = QLabel()
        self.repo_status_label.setObjectName('muted')
        r2.addWidget(self.repo_status_label, 1)
        self.check_upd_btn = QPushButton(self.m.t('repo.update'))
        self.check_upd_btn.clicked.connect(self.m.update_repo)
        r2.addWidget(self.check_upd_btn)
        repo_col.addLayout(r2)
        grp.add_row(r_repo)
        grp.add_divider()

        # Row 2: Device dependencies
        r_deps = QWidget()
        deps_col = QVBoxLayout(r_deps)
        deps_col.setContentsMargins(18, 14, 18, 14)
        deps_col.setSpacing(10)

        dh = QHBoxLayout()
        dh.setSpacing(10)
        self.deps_dot = _dot(style.NEUTRAL_DOT)
        dh.addWidget(self.deps_dot)
        self.deps_title = QLabel(self.m.t('dep.title'))
        self.deps_title.setObjectName('rowTitle')
        dh.addWidget(self.deps_title)
        self.deps_summary = QLabel(self.m.t('dep.checking'))
        self.deps_summary.setObjectName('muted')
        dh.addWidget(self.deps_summary, 1)
        self.install_all_btn = QPushButton(self.m.t('dep.installAll'))
        self.install_all_btn.setObjectName('creamPill')
        self.install_all_btn.clicked.connect(self.m.install_all_missing)
        dh.addWidget(self.install_all_btn)
        self.recheck_btn = QPushButton(self.m.t('dep.recheck'))
        self.recheck_btn.clicked.connect(self.m.check_deps)
        dh.addWidget(self.recheck_btn)
        self.deps_toggle_btn = QPushButton(self.m.t('dep.hide'))
        self.deps_toggle_btn.setObjectName('ghost')
        self.deps_toggle_btn.clicked.connect(self._toggle_deps_expanded)
        dh.addWidget(self.deps_toggle_btn)
        deps_col.addLayout(dh)

        self.deps_rows_host = QWidget()
        self.deps_rows = QVBoxLayout(self.deps_rows_host)
        self.deps_rows.setContentsMargins(0, 4, 0, 0)
        self.deps_rows.setSpacing(8)
        deps_col.addWidget(self.deps_rows_host)
        grp.add_row(r_deps)
        grp.add_divider()

        # Row 2.5: Shell Cache Folder (mirrors ShellCacheRow.swift)
        r_cache = QWidget()
        rc_lay = QHBoxLayout(r_cache)
        rc_lay.setContentsMargins(18, 12, 18, 12)
        rc_lay.setSpacing(12)
        self.cache_dot = _dot(style.GREEN)
        rc_lay.addWidget(self.cache_dot)
        ccol = QVBoxLayout()
        ccol.setSpacing(2)
        self.cache_title_lbl = QLabel(self.m.t('shellCache.row'))
        self.cache_title_lbl.setObjectName('rowTitle')
        self.cache_path_lbl = QLabel(self.m.shell_cache_path)
        self.cache_path_lbl.setObjectName('mono')
        self.cache_path_lbl.setWordWrap(True)
        self.cache_note_lbl = QLabel(self.m.t('shellCache.note'))
        self.cache_note_lbl.setObjectName('muted')
        self.cache_note_lbl.setWordWrap(True)
        self.cache_status_lbl = QLabel('')
        self.cache_status_lbl.setObjectName('muted')
        self.cache_status_lbl.setWordWrap(True)
        self.cache_status_lbl.hide()
        ccol.addWidget(self.cache_title_lbl)
        ccol.addWidget(self.cache_path_lbl)
        ccol.addWidget(self.cache_note_lbl)
        ccol.addWidget(self.cache_status_lbl)
        rc_lay.addLayout(ccol, 1)

        self.cache_open_btn = QPushButton(self.m.t('shellCache.open'))
        self.cache_open_btn.clicked.connect(self._open_shell_cache)
        rc_lay.addWidget(self.cache_open_btn)

        self.cache_move_btn = QPushButton(self.m.t('shellCache.move'))
        self.cache_move_btn.clicked.connect(self._move_shell_cache)
        rc_lay.addWidget(self.cache_move_btn)

        self.cache_default_btn = QPushButton(self.m.t('shellCache.useDefault'))
        self.cache_default_btn.clicked.connect(self._reset_shell_cache)
        self.cache_default_btn.setVisible(not self.m.shell_cache_is_default)
        rc_lay.addWidget(self.cache_default_btn)
        grp.add_row(r_cache)
        grp.add_divider()

        # Row 3: Copy Diagnostics (diag.title / diag.copy)
        r_diag = QWidget()
        rd_lay = QHBoxLayout(r_diag)
        rd_lay.setContentsMargins(18, 12, 18, 12)
        rd_lay.setSpacing(12)
        rd_lay.addWidget(_dot(style.GREEN))
        dcol = QVBoxLayout()
        dcol.setSpacing(2)
        self.diag_title_lbl = QLabel(self.m.t('diag.title'))
        self.diag_title_lbl.setObjectName('rowTitle')
        self.diag_note_lbl = QLabel(self.m.t('diag.note'))
        self.diag_note_lbl.setObjectName('muted')
        self.diag_note_lbl.setWordWrap(True)
        dcol.addWidget(self.diag_title_lbl)
        dcol.addWidget(self.diag_note_lbl)
        rd_lay.addLayout(dcol, 1)
        self.diag_btn = QPushButton(self.m.t('diag.copy'))
        self.diag_btn.setFixedWidth(184)
        self.diag_btn.clicked.connect(self._copy_diagnostics)
        rd_lay.addWidget(self.diag_btn)
        grp.add_row(r_diag)

        return grp

    def _open_shell_cache(self) -> None:
        p = Path(self.m.shell_cache_path)
        try:
            p.mkdir(parents=True, exist_ok=True)
        except OSError:
            pass
        pu.reveal(str(p))

    def _move_shell_cache(self) -> None:
        d = QFileDialog.getExistingDirectory(
            self,
            self.m.t('shellCache.pickMessage'),
            str(Path(self.m.shell_cache_path).parent),
        )
        if not d:
            return
        ok, msg = self.m.move_shell_cache(d)
        self.cache_status_lbl.setText(msg)
        self.cache_status_lbl.setStyleSheet(
            f'color: {style.GREEN if ok else style.AMBER}; font-size: 12px;'
        )
        self.cache_status_lbl.show()
        self._refresh_all()

    def _reset_shell_cache(self) -> None:
        ok, msg = self.m.reset_shell_cache_default()
        self.cache_status_lbl.setText(msg)
        self.cache_status_lbl.setStyleSheet(
            f'color: {style.GREEN if ok else style.AMBER}; font-size: 12px;'
        )
        self.cache_status_lbl.show()
        self._refresh_all()

    def _copy_diagnostics(self) -> None:
        report = feat.Diagnostics.format_report(
            app_version=APP_VERSION,
            repo_path=self.m.repo_path,
            deps=self.m.deps,
            last_log=self.log.toPlainText(),
        )
        cb = QApplication.clipboard()
        if cb:
            cb.setText(report)
        self.diag_btn.setText(self.m.t('diag.copied'))
        QTimer.singleShot(2000, lambda: self.diag_btn.setText(self.m.t('diag.copy')))

    def _toggle_deps_expanded(self) -> None:
        self._deps_expanded = not self._deps_expanded
        self.deps_rows_host.setVisible(self._deps_expanded)
        self.deps_toggle_btn.setText(self.m.t('dep.hide' if self._deps_expanded else 'dep.show'))

    def _build_app_card(self) -> CardGroup:
        grp = CardGroup(title=self.m.t('section.app'))

        # Row 1: Language 13-language dropdown
        r_lang = QWidget()
        rl_lay = QHBoxLayout(r_lang)
        rl_lay.setContentsMargins(18, 12, 18, 12)
        rl_lay.addWidget(_dot(style.GREEN))
        self.app_lang_lbl = QLabel(self.m.t('settings.language'))
        self.app_lang_lbl.setObjectName('rowTitle')
        rl_lay.addWidget(self.app_lang_lbl, 1)

        self.lang_combo = QComboBox()
        self.lang_combo.setObjectName('launcherDropdown')
        self.lang_combo.setFixedWidth(184)
        for lg in Lang.all():
            self.lang_combo.addItem(lg.name, lg.code)
        curr_idx = next((i for i, lg in enumerate(Lang.all()) if lg.code == self.m.lang.code), 0)
        self.lang_combo.setCurrentIndex(curr_idx)
        self.lang_combo.currentIndexChanged.connect(self._on_lang_combo_changed)
        rl_lay.addWidget(self.lang_combo)
        grp.add_row(r_lang)
        grp.add_divider()

        # Row 2: Notify when a build ends
        r_notif = QWidget()
        rn_lay = QHBoxLayout(r_notif)
        rn_lay.setContentsMargins(18, 12, 18, 12)
        rn_lay.addWidget(_dot(style.NEUTRAL_DOT))
        ncol = QVBoxLayout()
        ncol.setSpacing(2)
        self.notif_title_lbl = QLabel(self.m.t('settings.notify'))
        self.notif_title_lbl.setObjectName('rowTitle')
        self.notif_note_lbl = QLabel(self.m.t('settings.notifyNote'))
        self.notif_note_lbl.setObjectName('muted')
        self.notif_note_lbl.setWordWrap(True)
        ncol.addWidget(self.notif_title_lbl)
        ncol.addWidget(self.notif_note_lbl)
        rn_lay.addLayout(ncol, 1)
        notif_on = self.m.settings_value('notifyOnComplete', True)
        self.notif_switch = LauncherSwitch(bool(notif_on))
        self.notif_switch.toggled.connect(lambda v: self.m.settings_set('notifyOnComplete', v))
        rn_lay.addWidget(self.notif_switch)
        grp.add_row(r_notif)
        grp.add_divider()

        # Row 3: Run setup again (OnboardingDialog)
        r_setup = QWidget()
        rs_lay = QHBoxLayout(r_setup)
        rs_lay.setContentsMargins(18, 12, 18, 12)
        rs_lay.addWidget(_dot(style.NEUTRAL_DOT))
        scol = QVBoxLayout()
        scol.setSpacing(2)
        self.setup_row_title = QLabel(self.m.t('settings.setup'))
        self.setup_row_title.setObjectName('rowTitle')
        self.setup_row_note = QLabel(self.m.t('settings.setupNote'))
        self.setup_row_note.setObjectName('muted')
        self.setup_row_note.setWordWrap(True)
        scol.addWidget(self.setup_row_title)
        scol.addWidget(self.setup_row_note)
        rs_lay.addLayout(scol, 1)
        self.run_onboarding_btn = QPushButton(self.m.t('settings.setupBtn'))
        self.run_onboarding_btn.setFixedWidth(184)
        self.run_onboarding_btn.clicked.connect(self._open_onboarding)
        rs_lay.addWidget(self.run_onboarding_btn)
        grp.add_row(r_setup)
        grp.add_divider()

        # Row 4: App Version
        r_ver = QWidget()
        rv_lay = QHBoxLayout(r_ver)
        rv_lay.setContentsMargins(18, 12, 18, 12)
        self.ver_dot = _dot(style.GREEN)
        rv_lay.addWidget(self.ver_dot)
        vcol = QVBoxLayout()
        vcol.setSpacing(2)
        self.ver_title_lbl = QLabel(self.m.t('app.version', APP_VERSION))
        self.ver_title_lbl.setObjectName('rowTitle')
        self.ver_status_lbl = QLabel(self.m.t('app.upToDate'))
        self.ver_status_lbl.setObjectName('muted')
        self.ver_status_lbl.setWordWrap(True)
        vcol.addWidget(self.ver_title_lbl)
        vcol.addWidget(self.ver_status_lbl)
        rv_lay.addLayout(vcol, 1)
        self.ver_action_btn = QPushButton(self.m.t('repo.update'))
        self.ver_action_btn.setFixedWidth(184)
        self.ver_action_btn.clicked.connect(self._on_version_action_clicked)
        rv_lay.addWidget(self.ver_action_btn)
        grp.add_row(r_ver)

        return grp

    def _on_lang_combo_changed(self, idx: int) -> None:
        code = self.lang_combo.itemData(idx)
        if code and code != self.m.lang.code:
            self.m.set_lang(Lang(str(code)))

    @staticmethod
    def should_show_onboarding(model: Model) -> bool:
        """Mirror OnboardingLaunch (Mac): show on first run unless dependencies, keys and games folder are already set."""
        if os.environ.get('NSPB_ONBOARDING_FORCE') == '1':
            return True
        if model.settings_value('onboardingComplete', False):
            return False
        deps_ok = bool(model.deps) and all(d.ok for d in model.deps if d.required)
        keys_ok = bool(model.keys_path and os.path.isfile(model.keys_path))
        games_ok = bool(model.library.games_folder or model.library.games)
        if deps_ok and keys_ok and games_ok:
            model.settings_set('onboardingComplete', True)
            return False
        return True

    def _maybe_show_onboarding(self) -> None:
        if self._onboarding_checked or not self.m.deps_checked or not self.isVisible():
            return
        self._onboarding_checked = True
        if self.should_show_onboarding(self.m):
            QTimer.singleShot(0, self._open_onboarding)

    def showEvent(self, event) -> None:
        super().showEvent(event)
        self._maybe_show_onboarding()

    def _open_onboarding(self) -> None:
        if self._onboarding_dialog is not None and self._onboarding_dialog.isVisible():
            self._onboarding_dialog.raise_()
            self._onboarding_dialog.activateWindow()
            return
        dlg = OnboardingDialog(self.m, self)
        self._onboarding_dialog = dlg
        dlg.finished.connect(lambda _res: self._refresh_all())
        dlg.open()

    # ================================================================ Bottom Activity Bar

    def _build_activity_bar(self) -> QFrame:
        bar = QFrame()
        bar.setObjectName('activityBar')
        bar.setFixedHeight(44)
        row = QHBoxLayout(bar)
        row.setContentsMargins(28, 0, 28, 0)
        row.setSpacing(12)

        self.act_dot = StatusDot(style.NEUTRAL_DOT, size=7)
        row.addWidget(self.act_dot)

        self.act_title = QLabel(self.m.t('library.localNote'))
        self.act_title.setStyleSheet('font-size: 12px; font-weight: 600;')
        row.addWidget(self.act_title)

        self.act_detail = QLabel('')
        self.act_detail.setObjectName('muted')
        row.addWidget(self.act_detail, 1)

        self.act_progress = QProgressBar()
        self.act_progress.setRange(0, 100)
        self.act_progress.setTextVisible(False)
        self.act_progress.setFixedWidth(160)
        self.act_progress.hide()
        row.addWidget(self.act_progress)

        self.act_view_btn = QPushButton(self.m.t('library.viewBuild'))
        self.act_view_btn.setObjectName('ghost')
        self.act_view_btn.clicked.connect(lambda: self._switch_page('builds'))
        self.act_view_btn.hide()
        row.addWidget(self.act_view_btn)

        self.act_stop_btn = QPushButton(self.m.t('btn.stop'))
        self.act_stop_btn.setObjectName('danger')
        self.act_stop_btn.clicked.connect(self.m.cancel_build)
        self.act_stop_btn.hide()
        row.addWidget(self.act_stop_btn)

        return bar

    def _refresh_activity_bar(self) -> None:
        self.activity_bar.setVisible(not self.m.running or self._current_page != 'builds')
        if self.m.running:
            self.act_dot.set_color(style.AMBER)
            self.act_title.setText(self.m.t('activity.ios' if self.m.target == 'ios' else 'activity.mac'))
            curr_stage = next((s for s in self.m.stages if s.state == 'running'), None)
            done_cnt = sum(1 for s in self.m.stages if s.state == 'done')
            total_cnt = max(7, len(self.m.stages))
            pct = int(min(95, (done_cnt * 100) // total_cnt))
            self.act_detail.setText(f"{curr_stage.name}: {curr_stage.detail}" if curr_stage else '')
            self.act_progress.setValue(pct)
            self.act_progress.show()
            self.act_view_btn.setText(self.m.t('library.viewBuild'))
            self.act_view_btn.setVisible(self._current_page != 'builds')
            self.act_stop_btn.setText(self.m.t('btn.stop'))
            self.act_stop_btn.show()
        else:
            self.act_dot.set_color(style.GREEN if self.m.can_build else style.NEUTRAL_DOT)
            self.act_title.setText(self.m.t('library.localNote'))
            self.act_detail.setText(self.footer.text())
            self.act_progress.hide()
            self.act_view_btn.hide()
            self.act_stop_btn.hide()

    # ================================================================ Refresh Logic

    def _refresh_all(self) -> None:
        t = self.m.t
        self.lang_btn.setText(self.m.lang.toggle_label)

        # Sync language dropdown without re-triggering signal
        self.lang_combo.blockSignals(True)
        curr_idx = next((i for i, lg in enumerate(Lang.all()) if lg.code == self.m.lang.code), 0)
        self.lang_combo.setCurrentIndex(curr_idx)
        self.lang_combo.blockSignals(False)

        # Navigation bar texts
        for pid, btn in self.nav_btns.items():
            btn.setText(t('nav.' + pid))
        self.search_input.setPlaceholderText(t('library.search'))
        self.new_build_btn.setText('+ ' + t('library.newBuild'))

        # Headings & Cards
        self.running_setup.setText(t('section.setup'))
        self.preparing.setText(t('library.preparing'))
        self.files_group.set_title(t('section.files'))
        self.files_group.set_footer(t('msg.workdirHint'))
        self.folder_cta_title.setText(t('build.folderCTA') + ' · ' + t('data.note'))
        self.folder_cta_sub.setText(t('build.folderNote') + ' (' + t('data.folderHint') + ')')
        self.pick_folder_btn.setText(t('data.pickFolder'))
        arrow = '▾' if self._options_expanded else '▸'
        self.opt_toggle_btn.setText(f"{arrow}  {t('build.options').replace('&', '&&')}")
        self.out_title_lbl.setText(t('build.saveTo'))
        self.out_btn.setText(t('build.outDir'))
        self.out_clear_btn.setText(t('data.clear'))

        self.target_group.set_title(t('section.target'))
        self.bc_title_lbl.setText(t('opt.bc'))
        self.bc_note_lbl.setText(t('opt.bc.note'))

        self.stages_card.set_title(t('prog.title'))
        self.log_group.set_title(t('build.log'))
        self.log_label.setText(t('build.log'))
        self.export_log_btn.setText(t('log.export'))
        self.log.setPlaceholderText(t('log.placeholder'))

        # Settings page texts
        self.settings_heading.set_text(t('settings.heading'), t('settings.note'))
        self.settings_lib_group.set_title(t('section.library'))
        self.lib_folder_title.setText(t('library.folderTitle'))
        self.lib_folder_path_lbl.setText(self.m.library.games_folder or t('library.folderUnset'))
        self.lib_folder_hint_lbl.setText(t('library.folderHint'))
        _set_dot(self.lib_folder_dot, style.GREEN if self.m.library.games_folder else style.NEUTRAL_DOT)
        self.settings_rescan_btn.setText(t('library.rescan'))
        self.settings_lib_choose_btn.setText(t('library.chooseFolder'))

        self.tools_group.set_title(t('section.tools'))
        self.repo_title.setText(t('repo.title'))
        self.repo_sub.setText(t('repo.note'))
        self.clone_btn.setText(t('repo.download'))
        self.repo_btn.setText(t('repo.choose'))
        self.check_upd_btn.setText(t('repo.update'))
        self.deps_title.setText(t('dep.title'))
        self.recheck_btn.setText(t('dep.recheck'))
        self.deps_toggle_btn.setText(t('dep.hide' if self._deps_expanded else 'dep.show'))
        self.install_all_btn.setText(t('dep.installAll'))
        self.cache_title_lbl.setText(t('shellCache.row'))
        self.cache_path_lbl.setText(self.m.shell_cache_path)
        self.cache_note_lbl.setText(t('shellCache.note'))
        self.cache_open_btn.setText(t('shellCache.open'))
        self.cache_move_btn.setText(t('shellCache.move'))
        self.cache_default_btn.setText(t('shellCache.useDefault'))
        self.cache_default_btn.setVisible(not self.m.shell_cache_is_default)
        self.diag_title_lbl.setText(t('diag.title'))
        self.diag_note_lbl.setText(t('diag.note'))
        self.diag_btn.setText(t('diag.copy'))
        self.reveal_ipa_btn.setText(f"{t('shell.showInFinder')} (IPA)")
        self.reveal_arc_btn.setText(f"{t('shell.showInFinder')} (romfs)")
        self.top_bar.recenter_nav()

        self.app_group.set_title(t('section.app'))
        self.app_lang_lbl.setText(t('settings.language'))
        self.notif_title_lbl.setText(t('settings.notify'))
        self.notif_note_lbl.setText(t('settings.notifyNote'))
        self.setup_row_title.setText(t('settings.setup'))
        self.setup_row_note.setText(t('settings.setupNote'))
        self.run_onboarding_btn.setText(t('settings.setupBtn'))
        self.ver_title_lbl.setText(t('app.version', APP_VERSION))
        self.ver_status_lbl.setText(self.m.app_update_status or t('app.upToDate'))
        if self.m.app_update is not None:
            _set_dot(self.ver_dot, style.ORANGE)
            base_label = t('app.updateBtn', self.m.app_update.tag)
            prog = self.m.app_update_progress
            if prog is not None:
                for btn in (self.update_btn, self.ver_action_btn):
                    if btn.minimumWidth() == 0:
                        btn.setText(base_label)
                        btn.setStyleSheet('')
                        btn.setMinimumWidth(btn.sizeHint().width())
                clamped = min(max(prog, 0.0), 1.0)
                pct = int(round(clamped * 100))
                btn_label = f'{pct}%'
                stop_a = min(max(clamped, 0.001), 0.998)
                stop_b = min(stop_a + 0.001, 0.999)
                grad = (
                    f'qlineargradient(x1:0, y1:0, x2:1, y2:0, '
                    f'stop:0 {style.AMBER}, stop:{stop_a:.3f} {style.AMBER}, '
                    f'stop:{stop_b:.3f} {style.TRACK}, stop:1 {style.TRACK})'
                )
                self.update_btn.setStyleSheet(
                    f'background: {grad}; color: {style.TEXT}; border: 1px solid {style.CARD_EDGE}; '
                    f'border-radius: 14px; padding: 6px 18px; min-height: 20px; font-size: 13px; font-weight: 700;'
                )
                self.ver_action_btn.setStyleSheet(
                    f'background: {grad}; color: {style.TEXT}; border: 1px solid {style.CARD_EDGE}; '
                    f'border-radius: 12px; padding: 6px 16px; min-height: 18px; font-size: 12.5px; font-weight: 600;'
                )
            else:
                btn_label = base_label
                self.update_btn.setStyleSheet('')
                self.ver_action_btn.setStyleSheet('')
                self.update_btn.setMinimumWidth(0)
                self.ver_action_btn.setMinimumWidth(0)
            self.ver_action_btn.setText(btn_label)
            self.update_btn.setText(btn_label)
            self.update_btn.setEnabled(not self.m.app_update_busy and not self.m.running)
            self.update_btn.show()
        else:
            _set_dot(self.ver_dot, style.GREEN)
            self.ver_action_btn.setStyleSheet('')
            self.ver_action_btn.setMinimumWidth(0)
            self.ver_action_btn.setText(t('repo.update'))
        self.ver_action_btn.setEnabled(not self.m.app_update_busy and not self.m.running)

        self._refresh_engine_banner()
        self._refresh_repo()
        self._refresh_deps()
        self._refresh_inputs()
        self._refresh_target()
        self._refresh_install_card()
        self._refresh_stages()
        self._refresh_running()
        self._show_failure()
        self._refresh_library()
        self._refresh_activity_bar()

    def _refresh_repo(self) -> None:
        t = self.m.t
        ok = self.m.repo_ok
        busy = self.m.repo_busy
        _set_dot(self.repo_dot, style.GREEN if ok else style.RED)
        self.repo_path_label.setText(self.m.repo_path if ok else t('repo.notFound'))
        self.clone_btn.setVisible(not ok)
        self.clone_btn.setEnabled(not busy and not self.m.running)
        self.repo_btn.setVisible(not self.m.uses_bundled_engine)
        self.repo_btn.setEnabled(not busy and not self.m.running)
        if not ok:
            url = 'https://github.com/LNPANDY/NX2Apple'
            self.repo_hint_label.setText(
                f'{t("repo.firstHint")}<br>{t("repo.manualHint")} '
                f'<a href="{url}" style="color:{style.ACCENT};">{url}</a>{t("repo.manualHint2")}'
            )
            self.repo_hint_label.show()
        else:
            self.repo_hint_label.hide()
        is_git = self.m.repo_is_git
        self.check_upd_btn.setVisible(is_git)
        self.check_upd_btn.setEnabled(not busy and not self.m.running)
        self.repo_status_label.setText(self.m.repo_status or (t('repo.ok') if ok else ''))
        self.repo_status_label.setVisible(bool(self.m.repo_status or ok))

    def _refresh_deps(self) -> None:
        t = self.m.t
        while self.deps_rows.count():
            item = self.deps_rows.takeAt(0)
            if item.widget():
                item.widget().deleteLater()

        if not self.m.deps_checked:
            _set_dot(self.deps_dot, style.NEUTRAL_DOT)
            self.deps_summary.setText(t('dep.checking'))
            self.install_all_btn.hide()
            self._refresh_running()
            return
        if not self.m.deps:
            _set_dot(self.deps_dot, style.RED)
            self.deps_summary.setText(t('dep.checkFailed'))
            self.install_all_btn.hide()
            self._refresh_running()
            return

        req_missing = sum(1 for d in self.m.deps if not d.ok and d.required)
        opt_missing = sum(1 for d in self.m.deps if not d.ok and not d.required)
        fixable = any(not d.ok and d.install for d in self.m.deps)
        any_busy = any(d.installing for d in self.m.deps) or bool(getattr(self.m, '_install_all_running', False))
        if req_missing == 0 and opt_missing == 0:
            _set_dot(self.deps_dot, style.GREEN)
            self.deps_summary.setText(t('dep.allReady'))
        elif req_missing == 0:
            _set_dot(self.deps_dot, style.GREEN)
            self.deps_summary.setText(t('dep.onlyOptional', opt_missing))
        elif opt_missing:
            _set_dot(self.deps_dot, style.AMBER)
            self.deps_summary.setText(t('dep.missingOptional', req_missing, opt_missing))
        else:
            _set_dot(self.deps_dot, style.AMBER)
            self.deps_summary.setText(t('dep.missing', req_missing))
        self.install_all_btn.setVisible(fixable)
        self.install_all_btn.setEnabled(not any_busy)

        for d in self.m.deps:
            self.deps_rows.addWidget(self._make_dep_row(d))

        self._refresh_running()
        self._maybe_show_onboarding()

    def _make_dep_row(self, d: Dep) -> QFrame:
        t = self.m.t
        f = QFrame()
        f.setObjectName('subcard')
        outer = QVBoxLayout(f)
        outer.setContentsMargins(12, 10, 12, 10)
        outer.setSpacing(6)

        r = QHBoxLayout()
        r.setSpacing(10)
        color = style.GREEN if d.ok else (style.AMBER if getattr(d, 'installing', False) else
                (style.NEUTRAL_DOT if not d.required else
                (style.AMBER if d.state is DepState.OLD else style.RED)))
        r.addWidget(_dot(color))
        col = QVBoxLayout()
        col.setSpacing(2)
        title = QLabel(t(d.title_key))
        title.setStyleSheet('font-weight: 600;')
        detail = self._format_dep_detail(d)
        live_detail = getattr(d, 'install_detail', '') if getattr(d, 'installing', False) else ''
        sub = QLabel(live_detail or detail or t(d.hint_key))
        sub.setObjectName('mono' if (d.ok or live_detail) else 'muted')
        sub.setWordWrap(True)
        sub.setOpenExternalLinks(True)
        col.addWidget(title)
        col.addWidget(sub)
        r.addLayout(col, 1)

        if d.install and (not d.ok or d.id == 'ios_sdk'):
            live_stage = getattr(d, 'install_stage', '') if getattr(d, 'installing', False) else ''
            b = QPushButton((live_stage or t('dep.installing')) if d.installing else t('dep.install'))
            b.setEnabled(not d.installing)
            b.clicked.connect(lambda _=False, dep=d: self.m.install_dep(dep))
            r.addWidget(b)
        elif not d.ok and d.id == 'xcode':
            b = QPushButton(t('dep.openAppStore'))
            b.clicked.connect(lambda: QDesktopServices.openUrl(
                QUrl('macappstore://apps.apple.com/app/id497799835')))
            r.addWidget(b)
        if d.pick_key:
            label_key = 'dep.pick.metal' if d.pick_key in ('metal_dir', 'ios_sdk') else 'dep.pick'
            pb = QPushButton(t(label_key))
            pb.setEnabled(not d.installing)
            pb.clicked.connect(lambda _=False, dep=d: self.m.pick_dep_folder(dep))
            r.addWidget(pb)
        outer.addLayout(r)

        guide_key = {'ios_sdk': 'dep.guide.iossdk', 'metal': 'dep.guide.metal'}.get(d.id)
        if not d.ok and guide_key:
            guide = QLabel(t(guide_key))
            guide.setObjectName('muted')
            guide.setWordWrap(True)
            guide.setOpenExternalLinks(True)
            guide.setContentsMargins(18, 2, 4, 0)
            outer.addWidget(guide)

        if not d.ok and (d.last_error or d.fix_hint):
            msg = (d.last_error + ' — ' if d.last_error else '') + (t(d.fix_hint) if d.fix_hint else '')
            err = QLabel(msg)
            err.setWordWrap(True)
            err.setStyleSheet(f'color: {style.AMBER}; font-size: 11px;')
            err.setContentsMargins(18, 2, 4, 0)
            outer.addWidget(err)
        return f

    def _format_dep_detail(self, d: Dep) -> str:
        return self.m.format_dep_detail(d.detail)

    def _refresh_inputs(self) -> None:
        t = self.m.t
        folder = self.m.game_folder
        problem = self.m.game_folder_problem
        values = {
            'base': self.m.base_path,
            'update': self.m.update_path,
            'dlc': (t('data.files', len(self.m.dlc_paths)) +
                    ', '.join(Path(p).name for p in self.m.dlc_paths)) if self.m.dlc_paths else '',
            'keys': self.m.keys_path,
        }
        empty_label = {
            'base': t('data.notSelected'),
            'update': t('data.notSelectedOptional'),
            'dlc': t('data.notSelectedDlc'),
            'keys': t('data.notSelected'),
        }

        _set_dot(self.folder_cta_dot, style.GREEN if (folder or self.m.base_path) else style.NEUTRAL_DOT)

        for key, widgets in self.input_rows.items():
            widgets['title'].setText(t(widgets['title_key']))
            widgets['clear'].setText(t('data.clear'))
            folder_text = self.m.input_row_text(key)
            if problem and key == 'base':
                widgets['path'].setText(problem)
                widgets['path'].setObjectName('muted')
                _set_dot(widgets['dot'], style.RED)
                widgets['clear'].setVisible(True)
                widgets['choose'].setText(t('data.choose'))
                widgets['choose'].setVisible(True)
            elif folder is not None and folder_text is not None:
                has_val = key == 'base' or (key == 'update' and folder.newest_update is not None) or (key == 'dlc' and bool(folder.dlc))
                widgets['path'].setText(folder_text)
                widgets['path'].setObjectName('mono' if has_val else 'muted')
                _set_dot(widgets['dot'], style.GREEN if has_val else style.NEUTRAL_DOT)
                widgets['clear'].setVisible(key == 'base')
                widgets['choose'].setVisible(False)
            else:
                v = values[key]
                widgets['path'].setText(v if v else empty_label[key])
                widgets['path'].setObjectName('mono' if v else 'muted')
                _set_dot(widgets['dot'],
                         style.GREEN if v else (style.AMBER if widgets['req'] else style.NEUTRAL_DOT))
                widgets['clear'].setVisible(bool(v))
                widgets['choose'].setText(t('data.change') if v else t('data.choose'))
                widgets['choose'].setVisible(True)
            widgets['path'].style().unpolish(widgets['path'])
            widgets['path'].style().polish(widgets['path'])

        # Live KeyCheck status when both base and keys are selected
        if folder is None and self.m.base_path and self.m.keys_path and os.path.isfile(self.m.base_path) and os.path.isfile(self.m.keys_path):
            verdict = feat.KeyCheck.check(
                self.m.keys_path,
                self.m.base_path,
                self.m.update_path,
                self.m.dlc_paths,
            )
            if verdict.kind == 'fits':
                _set_dot(self.keycheck_dot, style.GREEN)
                self.keycheck_lbl.setText(t('keycheck.fits'))
            elif verdict.kind == 'unreadableKeys':
                _set_dot(self.keycheck_dot, style.RED)
                self.keycheck_lbl.setText(t('keycheck.unreadable'))
            elif verdict.kind == 'missingHeaderKey':
                _set_dot(self.keycheck_dot, style.RED)
                self.keycheck_lbl.setText(t('keycheck.noHeaderKey'))
            elif verdict.kind == 'wrongHeaderKey':
                _set_dot(self.keycheck_dot, style.RED)
                part_name = t('keycheck.part.' + (verdict.part or 'base'))
                self.keycheck_lbl.setText(t('keycheck.wrongHeaderKey', part_name))
            elif verdict.kind == 'missingKey':
                _set_dot(self.keycheck_dot, style.AMBER)
                part_name = t('keycheck.part.' + (verdict.part or 'base'))
                msg = t('keycheck.tooOld', part_name, verdict.key)
                if verdict.firmware:
                    msg += ' ' + t('keycheck.firmware', verdict.firmware)
                self.keycheck_lbl.setText(msg)
            else:
                _set_dot(self.keycheck_dot, style.NEUTRAL_DOT)
                self.keycheck_lbl.setText(t('keycheck.cannotCheck', verdict.reason))
            self.keycheck_row.show()
        else:
            self.keycheck_row.hide()

        self.out_label.setText(self.m.out_dir or t('build.saveDefault'))
        self.out_clear_btn.setVisible(bool(self.m.out_dir))
        self._refresh_install_card()
        self._refresh_running()

    def _refresh_target(self) -> None:
        t = self.m.t
        ios = self.m.target == 'ios'
        self.target_title_lbl.setText(t('build.ios') if ios else t('build.mac'))
        self.target_btn.setText(t('target.ios' if ios else 'target.mac'))
        self.target_btn.setToolTip(t('target.tip'))
        self.target_hint.setText(t('target.hint.ios' if ios else 'target.hint.mac'))

    def _toggle_target(self) -> None:
        if self.m.running or pu.IS_WIN:
            return
        self.m.target = 'mac-app' if self.m.target == 'ios' else 'ios'
        self._refresh_target()

    def _refresh_stages(self) -> None:
        while self.stages_col.count():
            item = self.stages_col.takeAt(0)
            if item.widget():
                item.widget().deleteLater()
        self._refresh_progress_visibility()
        for st in self.m.stages:
            r = QHBoxLayout()
            r.setSpacing(8)
            color = {
                'done': style.GREEN,
                'running': style.AMBER,
                'failed': style.RED,
            }.get(st.state, style.NEUTRAL_DOT)
            r.addWidget(_dot(color))
            name = QLabel(st.name)
            if st.state == 'running':
                name.setStyleSheet('font-weight: 700;')
            elif st.state != 'done':
                name.setObjectName('muted')
            r.addWidget(name)
            detail = QLabel(st.detail if st.state == 'running' else '')
            detail.setObjectName('mono')
            r.addWidget(detail, 1, Qt.AlignRight)
            w = QWidget()
            w.setLayout(r)
            self.stages_col.addWidget(w)
        self._refresh_activity_bar()

    def _refresh_progress_visibility(self) -> None:
        self.stages_card.setVisible(self.m.running or bool(self.m.stages))
        self.preparing.setVisible(self.m.running and not self.m.stages)

    def _refresh_build_inputs(self) -> None:
        running = self.m.running
        expanded = not running or self.running_setup.isChecked()
        self.running_setup.setVisible(running)
        self.running_setup.setArrowType(Qt.DownArrow if expanded else Qt.RightArrow)
        self.files_group.setVisible(expanded)
        self.target_group.setVisible(expanded)
        self.files_group.setEnabled(not running)
        self.target_group.setEnabled(not running)
        self.ipa_kind_seg.setEnabled(not running)
        # A previous export can still be revealed or copied to a drive.
        self.install_group.setVisible(expanded or os.path.isfile(self._effective_ipa_path())
                                      or os.path.isdir(self._effective_archive_path()))
        setup_needed = not self.m.repo_ok or (self.m.deps_checked and not self.m.all_deps_ok)
        self.setup_hint_card.setVisible(expanded and setup_needed)

    def _refresh_running(self) -> None:
        self._show_failure()
        t = self.m.t
        if self.m.running:
            self.build_btn.setText(t('build.cancel'))
            self.build_btn.setObjectName('danger')
            self.build_btn.setEnabled(True)
        else:
            self.build_btn.setText(t('build.start'))
            self.build_btn.setObjectName('primary')
            self.build_btn.setEnabled(self.m.can_build)
            if not self.m.can_build and not self._failed:
                if not self.m.repo_ok:
                    why = t('status.chooseRepo')
                elif not self.m.deps_checked:
                    why = t('status.checkingDeps')
                elif not self.m.all_deps_ok:
                    why = t('status.installFirst')
                elif self.m.game_folder_problem:
                    why = t('status.fixFolder')
                else:
                    why = t('status.needInputs')
                self.footer.setText(why)
            elif self.m.can_build and not self.m.ipa_path and not self.m.mac_app_path and self.m.failure is None and not self._failed:
                self.footer.setText('')

        if not self.m.running:
            self.running_setup.setChecked(False)
        self._refresh_build_inputs()
        self._refresh_progress_visibility()
        note = ('activity.ios' if self.m.target == 'ios' else 'activity.mac') if self.m.running else 'build.intro'
        self.build_heading.set_text(t('build.heading'), t(note))
        self.setup_hint_title.setText(t('library.setupHint'))
        self.setup_hint_sub.setText(t('status.chooseRepo') if not self.m.repo_ok else t('status.installFirst'))
        self.setup_goto_btn.setText(t('nav.settings'))

        self.build_btn.style().unpolish(self.build_btn)
        self.build_btn.style().polish(self.build_btn)
        self._refresh_activity_bar()

    def _append_log(self, s: str) -> None:
        c = self.log.textCursor()
        c.movePosition(c.MoveOperation.End)
        c.insertText(s)
        self.log.setTextCursor(c)
        self.log.ensureCursorVisible()
        reason = stale_reason(s)
        if reason and not getattr(self, '_stale_shaders_shown', False):
            self._stale_shaders_shown = True
            box = QMessageBox(QMessageBox.Icon.Information, 'NX2Apple', self.m.t(TITLE), parent=self)
            box.setInformativeText(self.m.t(TEXT[reason]))
            box.exec()

    def _on_finished(self, ok: bool, note: str) -> None:
        t = self.m.t
        self._failed = not ok
        if ok:
            out = self.m.mac_app_path or self.m.ipa_path
            self.footer.setText(note or (t('status.output', out) if out else t('msg.done')))
        else:
            self.footer.setText(note or t('msg.buildFailed'))
            if self._current_page != 'builds':
                self._switch_page('builds')
            self.scroll.ensureWidgetVisible(self.log, 0, 0)
        self._show_failure()
        self.reveal_ipa_btn.hide()
        self.reveal_arc_btn.hide()
        self.reveal_app_btn.setVisible(bool(self.m.mac_app_path) and Path(self.m.mac_app_path).exists())
        self._refresh_install_card()
        self._refresh_library()
        self._refresh_activity_bar()

        if self.m.settings_value('notifyOnComplete', True) and not self.isActiveWindow():
            QApplication.beep()

    # ================================================================ Failure Card Actions

    def _show_failure(self) -> None:
        t = self.m.t
        f = self.m.failure
        if f is None or f.kind == bf.UNKNOWN or self.m.running:
            self.failure_box.hide()
            return
        self.failure_title.setText(t('fail.section'))
        self.failure_what.setText(self.m.failure_what(f))
        titles = self.m.selectable_titles
        if f.title_ids and not titles:   # the selected inputs have changed
            self.failure_box.hide()
            return
        self.failure_next.setText(t('fail.severalGames.choose' if titles else f.next_key))
        current = [self.title_buttons.itemAt(i).widget().property('titleID') for i in range(self.title_buttons.count())]
        if tuple(current) != titles:
            while self.title_buttons.count():
                button = self.title_buttons.takeAt(0).widget()
                button.hide()
                button.deleteLater()
            for title in titles:
                button = QPushButton(title)
                button.setProperty('titleID', title)
                button.clicked.connect(lambda checked=False, tid=title: self._build_clicked(title_id=tid))
                self.title_buttons.addWidget(button)
        folder = self.m.failure_folder(f)
        self.failure_folder_btn.setText(t('fail.showFolder'))
        self.failure_folder_btn.setVisible(
            not titles and f.kind in (bf.NO_TITLE_ID, bf.SEVERAL_GAMES, bf.DISK_FULL, bf.CLOUD_FOLDER) and bool(folder))
        fix_key = {
            bf.KEYS: 'fail.keys.button',
            bf.CLOUD_FOLDER: 'fail.cloudFolder.button',
            bf.TRANSLATOR: 'fail.translator.button',
            bf.ZBIC: 'fail.zbic.button',
            bf.IOS_SDK: 'fail.iosSDK.button',
        }.get(f.kind)
        if fix_key and (f.kind != bf.IOS_SDK or not pu.IS_WIN):
            self.failure_fix_btn.setText(t(fix_key))
            self.failure_fix_btn.show()
        else:
            self.failure_fix_btn.hide()
        self.failure_anyway_btn.setText(t('fail.buildAnyway'))
        self.failure_anyway_btn.setVisible(bool(f.flag))
        self.failure_box.show()

    def _open_failure_folder(self) -> None:
        if self.m.failure:
            folder = self.m.failure_folder(self.m.failure)
            if folder:
                pu.reveal(folder)

    def _fix_failure(self) -> None:
        f = self.m.failure
        if f is None:
            return
        if f.kind == bf.KEYS:
            self._pick_input('keys', False)
        elif f.kind == bf.CLOUD_FOLDER:
            self._pick_out_dir()
        else:
            self.m.fix_failure(f)

    def _build_anyway(self) -> None:
        if not self.m.override.request(self.m.failure):
            return
        f = self.m.override.confirming
        assert f is not None
        ans = QMessageBox.question(
            self,
            self.m.t('fail.confirm.title'),
            self.m.t(f'fail.{f.kind}.risk'),
            QMessageBox.Yes | QMessageBox.Cancel,
            QMessageBox.Cancel,
        )
        if ans == QMessageBox.Yes and self.m.override.confirm():
            self._build_clicked()
        else:
            self.m.override.cancel()

    def _trigger_app_update(self, fallback_url: str = '') -> None:
        rel = self.m.app_update
        if rel is not None and pu.IS_WIN and getattr(sys, 'frozen', False):
            self.m.perform_app_update()
            return
        url = fallback_url or (rel.html_url if rel is not None else '')
        if url:
            QDesktopServices.openUrl(QUrl(url))

    def _on_version_action_clicked(self) -> None:
        if self.m.app_update is not None:
            self._trigger_app_update(self.m.app_update.html_url)
        else:
            self.m.check_app_update(silent=False)

    def _on_app_update(self, tag: str, url: str) -> None:
        self.update_btn.setText(self.m.t('app.updateBtn', tag))
        self.update_btn.setToolTip(url)
        try:
            self.update_btn.clicked.disconnect()
        except (RuntimeError, TypeError):
            pass
        self.update_btn.clicked.connect(lambda: self._trigger_app_update(url))
        self.update_btn.show()

    # ================================================================ File Pickers & Build Trigger

    def _ask_metal_archive(self, title: str) -> str:
        picked, _ = QFileDialog.getOpenFileName(
            self, title, str(Path.home() / 'Downloads'),
            'Metal Developer Tools (metal.exe metallib.exe *.zip *.exe *.msi);;All files (*)')
        if picked:
            return picked
        return QFileDialog.getExistingDirectory(self, title, str(Path.home()))

    def _ask_sdk_archive(self, title: str) -> str:
        picked, _ = QFileDialog.getOpenFileName(
            self, title, str(Path.home() / 'Downloads'),
            'iPhoneOS SDK (*.zip *.xip SDKSettings.json SDKSettings.plist);;All files (*)')
        if picked:
            return picked
        return QFileDialog.getExistingDirectory(self, title, str(Path.home()))

    def _pick_repo(self) -> None:
        d = QFileDialog.getExistingDirectory(
            self, self.m.t('repo.pickMessage'), self.m.repo_path or str(Path.home()))
        if not d:
            return
        if self.m.is_repo(d):
            self.m.repo_path = d
            self.m.sync_engine()
            self._refresh_repo()
            self._refresh_running()
        else:
            QMessageBox.warning(self, self.m.t('repo.title'), self.m.t('repo.notRepo', d))

    def _pick_game_dir(self) -> None:
        d = QFileDialog.getExistingDirectory(
            self, self.m.t('data.pickFolder'), self.m.game_dir or self.m.library.games_folder or str(Path.home()))
        if not d:
            return
        self.m.scan_game_dir(d)
        if not self.m.base_path and self.m.game_folder is None and not self.m.game_folder_problem:
            QMessageBox.information(self, self.m.t('data.title'), self.m.t('data.noBase'))
        elif self.m.base_path:
            g = self.m.library.remember_inputs(
                base_path=self.m.base_path,
                update_path=self.m.update_path,
                dlc_paths=self.m.dlc_paths,
                keys_path=self.m.keys_path,
                output_dir=self.m.out_dir,
                repo_path=self.m.engine_path,
            )
            if g:
                self.m.artwork.request_banner_async(g.title_id)

    def _pick_input(self, key: str, multi: bool) -> None:
        start = self.m.game_dir or (str(Path(self.m.base_path).parent) if self.m.base_path else str(Path.home()))
        if key == 'keys':
            f, _ = QFileDialog.getOpenFileName(
                self, 'prod.keys', start, 'Keys (prod.keys *.keys *);;All files (*)')
            if f:
                self.m.keys_path = f
        elif multi:
            fs, _ = QFileDialog.getOpenFileNames(
                self, 'DLC', start, 'Switch dumps (*.nsp *.xci *.nsz *.xcz)')
            if fs:
                self.m.leave_game_folder()
                self.m.dlc_paths = fs
        else:
            flt = 'Switch games (*.nsp *.xci *.nsz *.xcz *.nup)' if key == 'base' else 'Switch dumps (*.nsp *.xci *.nsz *.xcz)'
            f, _ = QFileDialog.getOpenFileName(self, key, start, flt)
            if f:
                if key == 'base' and inputs.is_game_folder_candidate(f):
                    self.m.take_game_folder(f)
                    return
                self.m.leave_game_folder()
                setattr(self.m, f'{key}_path', f)
        self._refresh_inputs()

    def _clear_input(self, key: str) -> None:
        if key == 'base' and (self.m.game_folder is not None or self.m.game_folder_problem):
            self.m.leave_game_folder()
        elif key == 'dlc':
            self.m.dlc_paths = []
        else:
            setattr(self.m, f'{key}_path', '')
        self._refresh_inputs()

    def _pick_out_dir(self) -> None:
        d = QFileDialog.getExistingDirectory(
            self, self.m.t('build.outDir'), self.m.out_dir or str(Path.home()))
        if d:
            self.m.out_dir = d
            self._refresh_inputs()

    def _clear_out_dir(self) -> None:
        self.m.out_dir = ''
        self._refresh_inputs()

    def _build_clicked(self, *, title_id: str | None = None) -> None:
        if self.m.running:
            if title_id is None:
                self.m.cancel_build()
            return
        self._failed = False
        self._stale_shaders_shown = False
        self.reveal_ipa_btn.hide()
        self.reveal_arc_btn.hide()
        self.reveal_app_btn.hide()
        self.footer.setText('')
        self.m.start_build(title_id=title_id)

    # ================================================================ Full-Window Drag & Drop

    def resizeEvent(self, event) -> None:
        super().resizeEvent(event)
        if hasattr(self, 'top_bar'):
            self.top_bar.recenter_nav()
        if hasattr(self, 'drop_overlay') and self.centralWidget():
            self.drop_overlay.setGeometry(self.centralWidget().rect())

    def mousePressEvent(self, event: QMouseEvent) -> None:
        if event.button() == Qt.LeftButton and not self.isMaximized():
            pos = event.position().toPoint()
            margin = 6
            edges = Qt.Edges()
            if pos.x() <= margin:
                edges |= Qt.LeftEdge
            elif pos.x() >= self.width() - margin:
                edges |= Qt.RightEdge
            if pos.y() <= margin:
                edges |= Qt.TopEdge
            elif pos.y() >= self.height() - margin:
                edges |= Qt.BottomEdge
            if edges:
                wh = self.windowHandle()
                if wh is not None and hasattr(wh, 'startSystemResize'):
                    if wh.startSystemResize(edges):
                        event.accept()
                        return
        super().mousePressEvent(event)

    def dragEnterEvent(self, event: QDragEnterEvent) -> None:
        if event.mimeData().hasUrls():
            event.acceptProposedAction()
            self.drop_overlay.set_hint(self.m.t('drop.hint'))
            self.drop_overlay.setGeometry(self.centralWidget().rect())
            self.drop_overlay.raise_()
            self.drop_overlay.show()

    def dragLeaveEvent(self, _event) -> None:
        self.drop_overlay.hide()

    def dropEvent(self, event: QDropEvent) -> None:
        self.drop_overlay.hide()
        urls = event.mimeData().urls()
        paths = [u.toLocalFile() for u in urls if u.isLocalFile()]
        if not paths:
            return
        event.acceptProposedAction()

        pkg_files: list[Path] = []
        for p in paths:
            if os.path.isdir(p):
                self.m.scan_game_dir(p)
                self._switch_page('builds')
                self._refresh_all()
                return
            low = os.path.basename(p).lower()
            if low == 'prod.keys' or low.endswith('.keys'):
                self.m.keys_path = p
            elif low.endswith('.nup'):
                self.m.take_game_folder(p)
            elif os.path.splitext(low)[1] in inputs.GAME_SUFFIXES:
                pkg_files.append(Path(p))

        if pkg_files:
            self.m.leave_game_folder()
            classified = inputs.classify(pkg_files)
            if classified.get('base'):
                self.m.base_path = str(classified['base'])
            if classified.get('update'):
                self.m.update_path = str(classified['update'])
            if classified.get('dlc'):
                self.m.dlc_paths = [str(x) for x in classified['dlc']]

        if self.m.base_path:
            g = self.m.library.remember_inputs(
                base_path=self.m.base_path,
                update_path=self.m.update_path,
                dlc_paths=self.m.dlc_paths,
                keys_path=self.m.keys_path,
                output_dir=self.m.out_dir,
                repo_path=self.m.engine_path,
            )
            if g:
                self.m.artwork.request_banner_async(g.title_id)

        self._switch_page('builds')
        self._refresh_all()
