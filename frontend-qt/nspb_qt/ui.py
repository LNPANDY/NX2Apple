"""The window: header, repository, inputs, dependencies, build progress, log.

The layout follows the SwiftUI app section for section, so a user who has seen one recognises
the other: rounded cards on a dark background, a coloured dot per row, monospaced paths.
"""
from __future__ import annotations

from pathlib import Path

from PySide6.QtCore import Qt, QUrl
from PySide6.QtGui import QDesktopServices, QFontDatabase
from PySide6.QtWidgets import (
    QFileDialog, QFrame, QGridLayout, QHBoxLayout, QLabel, QMainWindow,
    QProgressBar, QPushButton, QScrollArea, QSizePolicy, QTextEdit, QVBoxLayout, QWidget,
)

from . import platform_util as pu
from .model import DepState, Model
from .style import GREEN, MUTED, ORANGE, RED


class MainWindow(QMainWindow):
    def __init__(self, model: Model) -> None:
        super().__init__()
        self.m = model
        self.setWindowTitle('NS Port Builder')
        # Size to the screen, not to a fixed 1000x980: on a handheld's 1280x800 panel a fixed
        # height puts the footer below the screen edge and the window cannot be shrunk enough to
        # reach it. Fit within 90% of the available area and let the scroll area do the rest.
        avail = self.screen().availableGeometry() if self.screen() else None
        if avail is not None:
            # Use most of the panel: a 1280x800 handheld at 150% has only ~853x533 logical pixels,
            # so the margins must be small and the height is what matters.
            self.resize(min(900, int(avail.width() * 0.98)), min(900, int(avail.height() * 0.96)))
        else:
            self.resize(900, 800)
        self.setMinimumSize(420, 300)   # the scroll area carries everything below this
        self._mono = QFontDatabase.systemFont(QFontDatabase.FixedFont)

        root = QWidget()
        self.setCentralWidget(root)
        outer = QVBoxLayout(root)
        outer.setContentsMargins(0, 0, 0, 0)
        outer.setSpacing(0)

        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.NoFrame)
        # kept so a failed build can scroll the log into view: the message says "see the log
        # below", and on a window shorter than about 600 px the log sits below the fold (issue #52)
        self.scroll = scroll
        body = QWidget()
        body.setObjectName('body')
        self.body = QVBoxLayout(body)
        # (widget, string key) pairs re-set on every refresh: anything built once here would
        # otherwise keep its start-up language after the toggle (the half-Chinese report)
        self._translatable: list[tuple[QLabel, str]] = []
        self.body.setContentsMargins(12, 10, 12, 10)
        self.body.setSpacing(8)
        scroll.setWidget(body)
        outer.addWidget(scroll, 1)

        self._build_header()
        self._build_repository()
        self._build_inputs()
        self._build_deps()
        self._build_progress()
        self._build_log()
        outer.addWidget(self._separator())
        self._build_footer()

        self.m.depsChanged.connect(self._refresh_deps)
        self.m.repoChanged.connect(self._refresh_all)
        self.m.stagesChanged.connect(self._refresh_stages)
        self.m.logAppended.connect(self._append_log)
        self.m.runningChanged.connect(self._refresh_running)
        self.m.finished.connect(self._on_finished)

        self._refresh_all()
        self.m.check_deps()

    # ---------------------------------------------------------------- header

    def _build_header(self) -> None:
        row = QHBoxLayout()
        row.setSpacing(8)
        badge = QLabel('🎮')
        badge.setFixedSize(40, 40)
        badge.setAlignment(Qt.AlignCenter)
        badge.setStyleSheet(f'background: {GREEN}; border-radius: 10px; font-size: 18px;')
        row.addWidget(badge)
        left = QVBoxLayout()
        left.setSpacing(3)
        self.title = QLabel('NS Port Builder')
        self.title.setObjectName('title')
        self.subtitle = QLabel(self.m.t('app.subtitle'))
        self.subtitle.setObjectName('subtitle')
        left.addWidget(self.title)
        left.addWidget(self.subtitle)
        row.addLayout(left)
        row.addStretch(1)
        self.lang_btn = QPushButton(self.m.lang.toggle_label)
        self.lang_btn.clicked.connect(self._toggle_lang)
        row.addWidget(self.lang_btn, 0, Qt.AlignTop)
        self.body.addLayout(row)

    # ---------------------------------------------------------------- cards

    def _card(self, title_key: str, note_key: str = '') -> tuple[QFrame, QVBoxLayout]:
        # title/note are registered for re-translation: the language toggle rebuilds nothing, it
        # re-sets text — and a card title built once at start-up stayed English after the toggle
        # (the report's half-Chinese interface).
        box = QFrame()
        box.setObjectName('card')
        lay = QVBoxLayout(box)
        lay.setContentsMargins(12, 10, 12, 10)
        lay.setSpacing(6)
        head = QHBoxLayout()
        head.setSpacing(6)
        t = QLabel(self.m.t(title_key))
        t.setSizePolicy(QSizePolicy.Preferred, QSizePolicy.Preferred)
        f = t.font()
        f.setBold(True)
        f.setPointSize(13)
        t.setFont(f)
        head.addWidget(t)
        n = None
        if note_key:
            n = QLabel(self.m.t(note_key))
            n.setObjectName('note')
            head.addWidget(n)
        head.addStretch(1)
        lay.addLayout(head)
        self._translatable.append((t, title_key))
        if n is not None:
            self._translatable.append((n, note_key))
        self.body.addWidget(box)
        return box, lay

    def _build_repository(self) -> None:
        box, lay = self._card('repo.title', 'repo.note')
        self.repo_box = box
        row = QHBoxLayout()
        self.repo_dot = QLabel('●')
        self.repo_dot.setFixedWidth(14)
        row.addWidget(self.repo_dot)
        self.repo_path_label = QLabel('')
        self.repo_path_label.setObjectName('mono')
        self.repo_path_label.setTextInteractionFlags(Qt.TextSelectableByMouse)
        self.repo_path_label.setSizePolicy(QSizePolicy.Ignored, QSizePolicy.Preferred)   # long paths shrink, the buttons stay on screen
        self.repo_path_label.setMinimumWidth(60)
        row.addWidget(self.repo_path_label, 1)
        self.choose_btn = QPushButton(self.m.t('repo.choose'))
        self._translatable.append((self.choose_btn, 'repo.choose'))
        self.choose_btn.clicked.connect(self._choose_repo)
        row.addWidget(self.choose_btn)
        lay.addLayout(row)
        # A machine without a clone gets Download; a clone gets one update button (fetch, then
        # fast-forward if there is anything to take — see Model.update_repo).
        actions = QHBoxLayout()
        actions.setSpacing(8)
        self.download_btn = QPushButton(self.m.t('repo.download'))
        self._translatable.append((self.download_btn, 'repo.download'))
        self.download_btn.clicked.connect(lambda: self.m.clone_repo())
        self.update_btn = QPushButton(self.m.t('repo.update'))
        self._translatable.append((self.update_btn, 'repo.update'))
        self.update_btn.clicked.connect(self.m.update_repo)
        for b in (self.download_btn, self.update_btn):
            actions.addWidget(b)
        actions.addStretch(1)
        lay.addLayout(actions)
        self.repo_status = QLabel('')
        self.repo_status.setObjectName('note')
        lay.addWidget(self.repo_status)

    def _build_inputs(self) -> None:
        box, lay = self._card('data.title', 'data.note')
        self.data_box = box
        self.folder_label = QLabel(self.m.t('data.folderHint'))
        self.folder_label.setObjectName('mono')
        lay.addWidget(self.folder_label)
        grid = QGridLayout()
        grid.setHorizontalSpacing(8)
        grid.setVerticalSpacing(4)
        grid.setColumnStretch(2, 1)
        self.input_rows: dict[str, tuple[QLabel, QLabel]] = {}
        specs = [('base', 'data.base', False), ('update', 'data.update', True),
                 ('dlc', 'data.dlc', True), ('keys', 'data.keys', False)]
        for i, (key, l10n, optional) in enumerate(specs):
            dot = QLabel('○')
            dot.setFixedWidth(14)
            name = QLabel(self.m.t(l10n))
            name.setFixedWidth(110)
            self._translatable.append((name, l10n))
            val = QLabel('—')
            val.setObjectName('mono')
            val.setTextInteractionFlags(Qt.TextSelectableByMouse)
            val.setSizePolicy(QSizePolicy.Ignored, QSizePolicy.Preferred)   # filenames are long; the Choose button must stay visible
            btn = QPushButton(self.m.t('data.choose'))
            self._translatable.append((btn, 'data.choose'))
            btn.setFixedWidth(72)
            btn.clicked.connect(lambda _=False, k=key: self._choose_input(k))
            grid.addWidget(dot, i, 0)
            grid.addWidget(name, i, 1)
            grid.addWidget(val, i, 2)
            grid.addWidget(btn, i, 3)
            self.input_rows[key] = (dot, val)
        lay.addLayout(grid)
        row = QHBoxLayout()
        row.addStretch(1)
        pick = QPushButton(self.m.t('data.pickFolder'))
        self._translatable.append((pick, 'data.pickFolder'))
        pick.clicked.connect(self._pick_folder)
        row.addWidget(pick)
        lay.addLayout(row)

    def _build_deps(self) -> None:
        box, lay = self._card('dep.title')
        self.deps_box = box
        head = QHBoxLayout()
        self.deps_summary = QLabel('')
        head.addWidget(self.deps_summary)
        head.addStretch(1)
        self.install_all_btn = QPushButton(self.m.t('dep.installAll'))
        self._translatable.append((self.install_all_btn, 'dep.installAll'))
        self.install_all_btn.clicked.connect(self.m.install_all_missing)
        head.addWidget(self.install_all_btn)
        recheck = QPushButton(self.m.t('dep.recheck'))
        self._translatable.append((recheck, 'dep.recheck'))
        recheck.clicked.connect(self.m.check_deps)
        head.addWidget(recheck)
        self.deps_toggle = QPushButton(self.m.t('dep.hide'))
        self._translatable.append((self.deps_toggle, 'dep.hide'))
        self.deps_toggle.clicked.connect(self._toggle_deps)
        head.addWidget(self.deps_toggle)
        lay.addLayout(head)
        self.deps_container = QVBoxLayout()
        self.deps_container.setSpacing(3)
        lay.addLayout(self.deps_container)
        # Open by default, like the Mac's panel (open while anything is missing); remembered for
        # the next start either way.
        self.deps_open = self.m.settings_value('depsExpanded')
        self._apply_deps_open()

    def _toggle_deps(self) -> None:
        self.deps_open = not self.deps_open
        self.m.settings_set('depsExpanded', self.deps_open)
        self._apply_deps_open()

    def _apply_deps_open(self) -> None:
        for i in range(self.deps_container.count()):
            if w := self.deps_container.itemAt(i).widget():
                w.setVisible(self.deps_open)
        self.deps_toggle.setText(self.m.t('dep.hide' if self.deps_open else 'dep.show'))
        self._translatable = [(w, k) if k != 'dep.hide' and w is not self.deps_toggle else (w, 'dep.hide' if self.deps_open else 'dep.show')
                              for w, k in self._translatable]

    def _build_progress(self) -> None:
        box, lay = self._card('prog.title')
        self.progress_box = box
        self.progress_box.setVisible(False)
        self.overall = QProgressBar()
        self.overall.setTextVisible(False)
        lay.addWidget(self.overall)
        self.stages_container = QVBoxLayout()
        self.stages_container.setSpacing(3)
        lay.addLayout(self.stages_container)

    def _build_log(self) -> None:
        head = QHBoxLayout()
        head.setSpacing(6)
        self.log_path_label = QLabel('')
        self.log_path_label.setObjectName('note')
        self.log_path_label.setTextInteractionFlags(Qt.TextSelectableByMouse)
        self.log_path_label.setSizePolicy(QSizePolicy.Ignored, QSizePolicy.Preferred)
        head.addWidget(self.log_path_label, 1)
        self.export_btn = QPushButton(self.m.t('log.export'))
        self._translatable.append((self.export_btn, 'log.export'))
        self.export_btn.clicked.connect(self._export_log)
        head.addWidget(self.export_btn)
        self.body.addLayout(head)
        self.log = QTextEdit()
        self.log.setReadOnly(True)
        self.log.setFont(self._mono)
        self.log.setPlaceholderText(self.m.t('log.placeholder'))
        self.log.setMinimumHeight(90)
        self.log.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Expanding)
        self.body.addWidget(self.log, 1)

    def _build_footer(self) -> None:
        wrap = QWidget()
        outer = QVBoxLayout(wrap)
        outer.setContentsMargins(0, 0, 0, 0)
        outer.setSpacing(2)
        row = QHBoxLayout()
        row.setContentsMargins(12, 6, 12, 4)
        row.setSpacing(10)
        self.build_btn = QPushButton(self.m.t('build.start'))
        self.build_btn.setObjectName('primary')
        self.build_btn.setMinimumWidth(110)
        self.build_btn.clicked.connect(self._build_clicked)
        row.addWidget(self.build_btn)
        self.footer = QLabel('')
        self.footer.setObjectName('footer')
        row.addWidget(self.footer, 1)
        # Output target. A Mac app only exists on macOS (dm/mac/pack_app.py), so the choice is
        # hidden elsewhere rather than shown and rejected.
        if not pu.IS_WIN:
            self.target_btn = QPushButton(self.m.t('target.ios'))
            self.target_btn.setToolTip(self.m.t('target.tip'))
            self.target_btn.clicked.connect(self._toggle_target)
            row.addWidget(self.target_btn)
        self.out_btn = QPushButton(self.m.t('build.outDir'))
        self._translatable.append((self.out_btn, 'build.outDir'))
        self.out_btn.clicked.connect(self._choose_out)
        row.addWidget(self.out_btn)
        # the output folder silently decides where the build cache lives — the report changed it
        # and lost a finished build; say it here, all the time
        hint = QLabel(self.m.t('msg.workdirHint'))
        hint.setObjectName('note')
        hint.setWordWrap(True)
        outer.addLayout(row)
        self._build_failure_box(outer)
        outer.addWidget(hint)
        self._translatable.append((hint, 'msg.workdirHint'))
        self.centralWidget().layout().addWidget(wrap)

    def _build_failure_box(self, outer: QVBoxLayout) -> None:
        """After a known early stop of the script: what happened, the next step, and its button."""
        self.failure_box = QFrame()
        self.failure_box.setObjectName('card')
        box = QVBoxLayout(self.failure_box)
        box.setContentsMargins(12, 8, 12, 8)
        box.setSpacing(4)
        self.failure_what = QLabel('')
        self.failure_what.setWordWrap(True)
        self.failure_what.setStyleSheet(f'color: {ORANGE}; font-weight: 600;')
        self.failure_next = QLabel('')
        self.failure_next.setWordWrap(True)
        self.failure_next.setObjectName('note')
        buttons = QHBoxLayout()
        self.failure_fix_btn = QPushButton('')
        self.failure_fix_btn.clicked.connect(self._fix_failure)
        self.failure_anyway_btn = QPushButton(self.m.t('fail.buildAnyway'))
        self.failure_anyway_btn.clicked.connect(self._build_anyway)
        buttons.addWidget(self.failure_fix_btn)
        buttons.addWidget(self.failure_anyway_btn)
        buttons.addStretch(1)
        box.addWidget(self.failure_what)
        box.addWidget(self.failure_next)
        box.addLayout(buttons)
        self.failure_box.hide()
        outer.addWidget(self.failure_box)

    _FIX_BUTTONS = {'translator': 'fail.translator.button', 'zbic': 'fail.zbic.button', 'iosSDK': 'fail.iosSDK.button',
                    'keys': 'fail.keys.button', 'severalGames': 'fail.showFolder', 'noTitleID': 'fail.showFolder',
                    'diskFull': 'fail.showFolder'}

    def _show_failure(self) -> None:
        f = self.m.failure
        if f is None or self.m.running:
            self.failure_box.hide()
            return
        self.failure_what.setText(self.m.failure_what(f))
        self.failure_next.setText(self.m.t(f.next_key))
        fix = self._FIX_BUTTONS.get(f.kind)
        self.failure_fix_btn.setVisible(fix is not None)
        if fix:
            self.failure_fix_btn.setText(self.m.t(fix))
        self.failure_anyway_btn.setVisible(f.flag is not None)
        self.failure_anyway_btn.setText(self.m.t('fail.buildAnyway'))
        self.failure_box.show()

    def _fix_failure(self) -> None:
        f = self.m.failure
        if f is None:
            return
        if f.kind == 'keys':
            self._choose_input('keys')   # the same picker as the keys row
        elif f.kind in ('severalGames', 'noTitleID', 'diskFull'):
            folder = self.m.failure_folder(f)
            if folder:
                QDesktopServices.openUrl(QUrl.fromLocalFile(folder))
        else:
            self.m.fix_failure(f)

    def _build_anyway(self) -> None:
        """Asks first: the dialog states the risk. Nothing is armed until the player agrees."""
        if self.m.running or not self.m.override.request(self.m.failure):
            return
        from PySide6.QtWidgets import QMessageBox
        risk = self.m.t(f'fail.{self.m.failure.kind}.risk')
        yes = QMessageBox.question(self, self.m.t('fail.confirm.title'), risk,
                                   QMessageBox.Yes | QMessageBox.Cancel, QMessageBox.Cancel)
        if yes != QMessageBox.Yes:
            self.m.override.cancel()
            return
        if self.m.override.confirm():
            self._build_clicked()

    @staticmethod
    def _separator() -> QFrame:
        line = QFrame()
        line.setFrameShape(QFrame.HLine)
        line.setStyleSheet('color: #31373f;')
        return line

    # ---------------------------------------------------------------- refresh

    def _refresh_all(self) -> None:
        self.subtitle.setText(self.m.t('app.subtitle'))
        self.lang_btn.setText(self.m.lang.toggle_label)
        # everything built once at start-up re-reads its string here: the language toggle emits
        # repoChanged, and without this the card titles, the notes and the buttons kept their
        # start-up language — the report's half-Chinese interface
        for w, key in self._translatable:
            w.setText(self.m.t(key))
        self._show_failure()
        full = (pu.short_path(self.m.repo_path) if self.m.repo_ok
                else (self.m.repo_path or self.m.t('repo.notFound')))
        self.repo_path_label.setText(full)
        self.repo_path_label.setToolTip(full)   # the full path on hover when elided
        if self.m.repo_ok:
            self.repo_dot.setStyleSheet(f'color: {GREEN};')
            self.repo_status.setText(self.m.repo_status or
                                     (self.m.t('repo.ok') if self.m.repo_is_git else self.m.t('repo.noGit')))
        else:
            self.repo_dot.setStyleSheet(f'color: {RED};')
            self.repo_status.setText(self.m.repo_status or self.m.t('repo.firstHint'))
        # Download when there is no usable checkout; one update button when there is a git one.
        self.download_btn.setVisible(not self.m.repo_ok)
        self.update_btn.setVisible(self.m.repo_ok and self.m.repo_is_git)
        busy = self.m.repo_busy or self.m.running
        for b in (self.download_btn, self.update_btn, self.choose_btn):
            b.setEnabled(not busy)
        if getattr(self.m, 'log_path', None):
            self.log_path_label.setText(self.m.t('log.at', str(self.m.log_path)))
        self._refresh_inputs()
        self._refresh_deps()

    def _refresh_inputs(self) -> None:
        self.folder_label.setText(pu.short_path(self.m.game_dir) if self.m.game_dir
                                  else self.m.t('data.folderHint'))
        vals = {'base': self.m.base_path, 'update': self.m.update_path, 'keys': self.m.keys_path}
        for key, (dot, val) in self.input_rows.items():
            if key == 'dlc':
                n = len(self.m.dlc_paths)
                text = (Path(self.m.dlc_paths[0]).name + (f'  +{n - 1}' if n > 1 else '')) if n else ''
                set_, optional = bool(n), True
            else:
                v = vals.get(key, '')
                text, set_, optional = (Path(v).name if v else ''), bool(v), key == 'update'
            if set_:
                dot.setText('●')
                dot.setStyleSheet(f'color: {GREEN};')
                val.setText(text)
                val.setStyleSheet(f'color: {MUTED};')
            else:
                dot.setText('○' if optional else '✕')
                dot.setStyleSheet(f'color: {MUTED if optional else RED};')
                val.setText(self.m.t('data.notSelectedOptional') if optional else self.m.t('data.notSelected'))
                val.setStyleSheet(f'color: {MUTED if optional else ORANGE};')
        self._refresh_running()

    @staticmethod
    def _esc(text: str) -> str:
        # The failure line is tool output; keep it out of the rich-text parser.
        return (text.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;'))

    def _refresh_deps(self) -> None:
        while self.deps_container.count():
            item = self.deps_container.takeAt(0)
            if w := item.widget():
                w.deleteLater()
        for d in self.m.deps:
            row = QWidget()
            h = QHBoxLayout(row)
            h.setContentsMargins(0, 0, 0, 0)
            h.setSpacing(6)
            # An optional tool that is missing reads as a muted ○, not a red ✕: it does not block
            # the build in front of the player, and the red row made a complete Metal toolchain look
            # broken (the report's screenshot: spirv-cross and glslangValidator, both OpenGL-only).
            optional_missing = not d.ok and not getattr(d, 'required', True)
            mark = QLabel('●' if d.ok else ('◐' if d.state is DepState.OLD else ('○' if optional_missing else '✕')))
            mark.setFixedWidth(14)
            mark.setStyleSheet(f'color: {GREEN if d.ok else (MUTED if optional_missing else (ORANGE if d.state is DepState.OLD else RED))};')
            h.addWidget(mark)
            name = QLabel(self.m.t(d.title_key))
            name.setFixedWidth(140)
            h.addWidget(name)
            detail = d.detail
            if detail.startswith('dep.'):
                if ':' in detail:
                    key, arg = detail.split(':', 1)
                    detail = self.m.t(key, arg)
                else:
                    detail = self.m.t(detail)
            elif detail:
                detail = pu.short_path(detail)
            lab = QLabel(detail)
            lab.setObjectName('mono')
            lab.setTextInteractionFlags(Qt.TextSelectableByMouse)
            lab.setSizePolicy(QSizePolicy.Ignored, QSizePolicy.Preferred)
            lab.setToolTip(detail)
            h.addWidget(lab, 1)
            if not d.ok:
                if d.install:
                    btn = QPushButton(self.m.t('dep.install'))
                    btn.setEnabled(not d.installing)
                    btn.clicked.connect(lambda _=False, dep=d: self.m.install_dep(dep))
                    h.addWidget(btn)
                if d.pick_key:
                    # Apple-licensed pieces cannot be downloaded by the app: Choose points at a
                    # copy the user already has (validated, remembered in toolchain.json).
                    pick = QPushButton(self.m.t('dep.pick'))
                    pick.clicked.connect(lambda _=False, dep=d: self.m.pick_dep_folder(dep))
                    h.addWidget(pick)
                if not d.install and not d.pick_key:
                    hint = QLabel(self.m.t(d.hint_key))
                    hint.setObjectName('note')
                    hint.setOpenExternalLinks(True)   # the Windows hints carry download links
                    h.addWidget(hint)
            self.deps_container.addWidget(row)
            # Why the last install failed and what to do: the tool's own line under the row, the
            # fix under it (Mac parity). Cleared when the row installs successfully.
            if not d.ok and (d.last_error or d.fix_hint):
                note = QLabel(('<br>' if d.last_error and d.fix_hint else '')
                              + (self._esc(d.last_error) if d.last_error else '')
                              + ('<br>' + self.m.t(d.fix_hint) if d.fix_hint else ''))
                note.setObjectName('note')
                note.setOpenExternalLinks(True)
                note.setContentsMargins(20, 0, 0, 4)
                self.deps_container.addWidget(note)
        for d in self.m.deps:
            if not d.ok and not d.install and d.id == 'ios_sdk':
                guide = QLabel(self.m.t('dep.guide.iossdk'))
                guide.setObjectName('note')
                guide.setOpenExternalLinks(True)
                guide.setContentsMargins(20, 0, 0, 4)
                self.deps_container.addWidget(guide)
            elif not d.ok and not d.install and d.id == 'metal':
                guide = QLabel(self.m.t('dep.guide.metal'))
                guide.setObjectName('note')
                guide.setOpenExternalLinks(True)
                guide.setContentsMargins(20, 0, 0, 4)
                self.deps_container.addWidget(guide)
        if self.m.deps_checked:
            if not self.m.deps:
                # The check produced no rows at all, which means it failed — never report that as
                # "all ready" (see Model.all_deps_ok) or as "0 missing".
                self.deps_summary.setText('⚠  ' + self.m.t('dep.checkFailed'))
                self.deps_summary.setStyleSheet(f'color: {RED}; font-weight: 600;')
            elif self.m.all_deps_ok:
                self.deps_summary.setText('●  ' + self.m.t('dep.allReady'))
                self.deps_summary.setStyleSheet(f'color: {GREEN}; font-weight: 600;')
            else:
                # Required only: an optional tool (glslangValidator for OpenGL games) or one that
                # only some titles need (spirv-cross) was counted here, so a machine that could
                # build the game in front of it read "缺 3 项" and looked broken.
                n = sum(1 for d in self.m.deps if not d.ok and getattr(d, 'required', True))
                optional = sum(1 for d in self.m.deps if not d.ok and not getattr(d, 'required', True))
                if n == 0 and optional:
                    # nothing is actually blocking: saying "缺 0 项（另有 2 项可选）" reads like a
                    # problem where there is none
                    self.deps_summary.setText(self.m.t('dep.onlyOptional', optional))
                    self.deps_summary.setStyleSheet(f'color: {GREEN}; font-weight: 600;')
                    return
                self.deps_summary.setText(self.m.t('dep.missingOptional', n, optional) if optional
                                          else self.m.t('dep.missing', n))
                self.deps_summary.setStyleSheet(f'color: {RED}; font-weight: 600;')
        else:
            self.deps_summary.setText(self.m.t('dep.checking'))
            self.deps_summary.setStyleSheet(f'color: {MUTED};')
        missing_installable = [d for d in self.m.deps if not d.ok and d.install]
        self.install_all_btn.setVisible(bool(missing_installable))
        self.install_all_btn.setEnabled(bool(missing_installable) and
                                        not any(d.installing for d in self.m.deps))
        self._refresh_running()

    def _refresh_stages(self) -> None:
        while self.stages_container.count():
            item = self.stages_container.takeAt(0)
            if w := item.widget():
                w.deleteLater()
        if not self.m.stages:
            self.progress_box.setVisible(False)
            return
        self.progress_box.setVisible(True)
        for st in self.m.stages:
            row = QWidget()
            h = QHBoxLayout(row)
            h.setContentsMargins(0, 0, 0, 0)
            h.setSpacing(6)
            mark = {'done': '●', 'running': '◐', 'failed': '✕'}.get(st.state, '○')
            colour = {'done': GREEN, 'failed': RED}.get(st.state, MUTED)
            lab = QLabel(mark)
            lab.setFixedWidth(14)
            lab.setStyleSheet(f'color: {colour};')
            h.addWidget(lab)
            name = QLabel(st.name)
            h.addWidget(name, 0)
            if st.state == 'running':
                bar = QProgressBar()
                bar.setTextVisible(False)
                bar.setFixedWidth(150)
                bar.setRange(0, 0)
                h.addWidget(bar)
            det = QLabel(st.detail)
            det.setObjectName('mono')
            h.addWidget(det, 1)
            self.stages_container.addWidget(row)
        done = sum(1 for s in self.m.stages if s.state == 'done')
        self.overall.setRange(0, len(self.m.stages))
        self.overall.setValue(done)

    def _refresh_running(self) -> None:
        running = self.m.running
        self.build_btn.setText(self.m.t('build.cancel') if running else self.m.t('build.start'))
        self.build_btn.setObjectName('danger' if running else 'primary')
        self.build_btn.style().unpolish(self.build_btn)
        self.build_btn.style().polish(self.build_btn)
        self.build_btn.setEnabled(running or self.m.can_build)
        # Re-set on every refresh, and clear when a build runs (the build's own progress text
        # takes the footer). "only when empty" wrote the start-up language once and never
        # updated it — the footer was English after the toggle.
        if running:
            self.footer.setText('')
        elif getattr(self, '_failed', False):
            pass          # a failure message stays until the next build: it was being replaced by
                          # the input reminder on the refresh that follows the failure (issue #52)
        elif not self.m.base_path:
            self.footer.setText(self.m.t('status.needInputs'))
        elif not self.m.repo_ok:
            self.footer.setText(self.m.t('status.chooseRepo'))
        elif not self.footer.text() or self.footer.text() in (
                self.m.t('status.needInputs'), self.m.t('status.chooseRepo')):
            self.footer.setText('')

    def _append_log(self, s: str) -> None:
        self.log.moveCursor(self.log.textCursor().MoveOperation.End)
        self.log.insertPlainText(s)
        self.log.moveCursor(self.log.textCursor().MoveOperation.End)
        # The script marks a shader-chain bump with this tag: the cached libraries cannot be
        # reused and this build recompiles them. A popup, not a log line — the report's question
        # ("why is it building shaders again, the artifacts are on the drive") came from exactly
        # this moment passing unnoticed. Once per build: the log chunks arrive in pieces.
        if '[NOTE] chain-changed' in s and not getattr(self, '_chain_note_shown', False):
            self._chain_note_shown = True
            from PySide6.QtWidgets import QMessageBox
            QMessageBox.information(self, 'NS Port Builder', self.m.t('msg.chainChanged'))

    def _on_finished(self, ok: bool, note: str) -> None:
        if ok:
            msg = note or self.m.t('msg.done')
            if self.m.ipa_path:
                msg += '   ' + self.m.t('msg.ipaAt', self.m.ipa_path)
            if self.m.archive_path:
                msg += '   ' + self.m.t('msg.archiveAt', self.m.archive_path)
            self.footer.setStyleSheet(f'color: {GREEN};')
        else:
            msg = note or self.m.t('msg.buildFailed')
            self.footer.setStyleSheet(f'color: {RED};')
        self.footer.setText(msg)
        self._failed = not ok
        self._show_failure()
        if not ok:
            # The message points at the log, so put it in view rather than trusting the window to
            # be tall enough. ensureWidgetVisible also handles the scroll area's own margin.
            self.scroll.ensureWidgetVisible(self.log, 0, 0)
            self.log.setFocus(Qt.OtherFocusReason)
        self._refresh_running()

    # ---------------------------------------------------------------- actions

    def _toggle_lang(self) -> None:
        self.m.toggle_lang()
        self._refresh_all()

    def _build_clicked(self) -> None:
        if self.m.running:
            self.m.cancel_build()
        else:
            self.footer.setText('')
            self.footer.setStyleSheet('')
            self._failed = False
            self.failure_box.hide()
            self.m.start_build()

    def _choose_repo(self) -> None:
        d = QFileDialog.getExistingDirectory(self, self.m.t('repo.pickMessage'))
        if d:
            self.m.repo_path = d
            self.m.repoChanged.emit()

    def _pick_folder(self) -> None:
        d = QFileDialog.getExistingDirectory(self, self.m.t('data.pickFolder'))
        if d:
            self.m.scan_game_dir(d)

    def _choose_input(self, key: str) -> None:
        path, _ = QFileDialog.getOpenFileName(self, self.m.t('data.choose'))
        if not path:
            return
        if key == 'base':
            self.m.base_path = path
        elif key == 'update':
            self.m.update_path = path
        elif key == 'keys':
            self.m.keys_path = path
        else:
            if path not in self.m.dlc_paths:
                self.m.dlc_paths.append(path)
        self.m.repoChanged.emit()

    def _export_log(self) -> None:
        """Save the log to a file the user picks, defaulting to the Desktop.

        The window's log is also written to disk as it grows (m.model.log_path); this is for
        sending a copy somewhere, e.g. attaching it to an issue from a handheld where copying text
        out of the window is awkward.
        """
        default = str(Path.home() / 'Desktop' / 'ns-port-builder-log.txt')
        path, _ = QFileDialog.getSaveFileName(self, self.m.t('log.export'), default,
                                             'Text (*.txt);;All files (*)')
        if not path:
            return
        try:
            Path(path).write_text(self.log.toPlainText(), encoding='utf-8')
            self.footer.setText(self.m.t('log.exported', path))
            self.footer.setStyleSheet(f'color: {GREEN};')
        except OSError as e:
            self.footer.setText(self.m.t('log.exportFail', str(e)))
            self.footer.setStyleSheet(f'color: {RED};')

    def _toggle_target(self) -> None:
        """Switch between an iPhone IPA and a Mac app (macOS only)."""
        self.m.target = 'mac-app' if self.m.target == 'ios' else 'ios'
        self.target_btn.setText(self.m.t('target.mac' if self.m.target == 'mac-app' else 'target.ios'))
        self.footer.setText(self.m.t('target.hint.mac' if self.m.target == 'mac-app' else 'target.hint.ios'))
        self.footer.setStyleSheet('')

    def _choose_out(self) -> None:
        d = QFileDialog.getExistingDirectory(self, self.m.t('build.outDir'))
        if d:
            self.m.out_dir = d
            self._refresh_all()
