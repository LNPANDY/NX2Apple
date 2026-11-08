"""Modal dialogs (FreeSpace, DeleteGame, Cheats, Onboarding) mirroring the Mac SwiftUI sheets."""
from __future__ import annotations

import os
import shutil
from pathlib import Path
from typing import TYPE_CHECKING

from PySide6.QtCore import Qt
from PySide6.QtWidgets import (
    QDialog,
    QFileDialog,
    QFrame,
    QHBoxLayout,
    QLabel,
    QMessageBox,
    QProgressBar,
    QPushButton,
    QScrollArea,
    QVBoxLayout,
    QWidget,
)

from . import features as feat
from . import library as lib
from . import platform_util as pu
from . import style
from .widgets import CardGroup, LauncherSwitch, StatusDot

if TYPE_CHECKING:
    from .model import Model


class FreeSpaceDialog(QDialog):
    """Build-folder cleanup dialog mirroring FreeSpaceSheet in FreeSpace.swift."""

    def __init__(self, model: 'Model', game: lib.LibraryGame, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.m = model
        self.game = game
        self.setWindowTitle(f"{self.m.t('free.title')} — {game.name}")
        self.setMinimumSize(580, 460)
        self.setStyleSheet(style.STYLESHEET)

        folder = lib.BuildFolder.location(game) or (game.work_dir or '')
        self.report = lib.BuildFolder.inspect(folder, game.title_id)
        self.selected_parts: set[str] = {
            it.part for it in self.report.items if it.part in ('extracted', 'oldShaders', 'xcode', 'caches')
        }
        self._switches: dict[str, LauncherSwitch] = {}

        lay = QVBoxLayout(self)
        lay.setContentsMargins(24, 22, 24, 20)
        lay.setSpacing(14)

        title = QLabel(f"{self.m.t('free.title')} · {game.name}")
        title.setStyleSheet('font-size: 20px; font-weight: 800;')
        lay.addWidget(title)

        note = QLabel(self.m.t('free.note'))
        note.setObjectName('muted')
        note.setWordWrap(True)
        lay.addWidget(note)

        if not self.report.items:
            empty_card = CardGroup()
            r = QWidget()
            rl = QHBoxLayout(r)
            rl.setContentsMargins(18, 18, 18, 18)
            lbl = QLabel(self.m.t('free.empty'))
            lbl.setObjectName('muted')
            rl.addWidget(lbl)
            empty_card.add_row(r)
            lay.addWidget(empty_card)
        else:
            group = CardGroup()
            for idx, item in enumerate(self.report.items):
                if idx > 0:
                    group.add_divider()
                row = QWidget()
                rl = QHBoxLayout(row)
                rl.setContentsMargins(18, 12, 18, 12)
                rl.setSpacing(12)

                sw = LauncherSwitch(checked=(item.part in self.selected_parts))
                sw.toggled.connect(lambda checked, p=item.part: self._on_toggle(p, checked))
                self._switches[item.part] = sw
                rl.addWidget(sw)

                col = QVBoxLayout()
                col.setSpacing(2)
                p_title = QLabel(self.m.t('free.part.' + item.part))
                p_title.setObjectName('rowTitle')
                p_cost = QLabel(self.m.t('free.cost.' + item.part))
                p_cost.setObjectName('muted')
                p_cost.setWordWrap(True)
                col.addWidget(p_title)
                col.addWidget(p_cost)
                rl.addLayout(col, 1)

                sz_lbl = QLabel(lib.format_bytes(item.bytes))
                sz_lbl.setObjectName('mono')
                rl.addWidget(sz_lbl)
                group.add_row(row)

            if self.report.kept_bytes > 0:
                group.add_divider()
                krow = QWidget()
                krl = QHBoxLayout(krow)
                krl.setContentsMargins(18, 12, 18, 12)
                kcol = QVBoxLayout()
                kcol.setSpacing(2)
                kt = QLabel(self.m.t('free.kept'))
                kt.setObjectName('rowTitle')
                kn = QLabel(self.m.t('free.keptNote'))
                kn.setObjectName('muted')
                kcol.addWidget(kt)
                kcol.addWidget(kn)
                krl.addLayout(kcol, 1)
                ksz = QLabel(lib.format_bytes(self.report.kept_bytes))
                ksz.setObjectName('mono')
                krl.addWidget(ksz)
                group.add_row(krow)

            lay.addWidget(group)

        lay.addStretch(1)

        foot = QHBoxLayout()
        self.sel_label = QLabel('')
        self.sel_label.setObjectName('muted')
        foot.addWidget(self.sel_label)
        foot.addStretch(1)

        self.remove_btn = QPushButton(self.m.t('free.remove'))
        self.remove_btn.setObjectName('danger')
        self.remove_btn.clicked.connect(self._do_remove)
        if not self.report.items:
            self.remove_btn.hide()
        foot.addWidget(self.remove_btn)

        done_btn = QPushButton(self.m.t('free.done'))
        done_btn.setObjectName('creamPill')
        done_btn.clicked.connect(self.accept)
        foot.addWidget(done_btn)
        lay.addLayout(foot)

        self._update_summary()

    def _on_toggle(self, part: str, checked: bool) -> None:
        if checked:
            self.selected_parts.add(part)
        else:
            self.selected_parts.discard(part)
        self._update_summary()

    def _selected_bytes(self) -> int:
        parts = set(self.selected_parts)
        if 'shaders' in parts:
            parts.discard('oldShaders')
        return sum(it.bytes for it in self.report.items if it.part in parts)

    def _update_summary(self) -> None:
        b = self._selected_bytes()
        self.sel_label.setText(self.m.t('free.selected', lib.format_bytes(b)))
        self.remove_btn.setEnabled(b > 0 and not self.m.running)

    def _do_remove(self) -> None:
        b = self._selected_bytes()
        if b <= 0:
            return
        ans = QMessageBox.question(
            self,
            self.m.t('free.confirm', lib.format_bytes(b)),
            self.m.t('free.confirmNote'),
            QMessageBox.Yes | QMessageBox.No,
            QMessageBox.No,
        )
        if ans != QMessageBox.Yes:
            return
        freed, failed = lib.BuildFolder.remove(self.report, self.selected_parts)
        if failed:
            self.sel_label.setText(self.m.t('free.failed', ', '.join(os.path.basename(p) for p in failed)))
        else:
            self.sel_label.setText(self.m.t('free.freed', lib.format_bytes(freed)))
        self.remove_btn.setEnabled(False)


class DeleteGameDialog(QDialog):
    """Game deletion dialog mirroring DeleteGameSheet.swift."""

    def __init__(self, model: 'Model', game: lib.LibraryGame, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.m = model
        self.game = game
        self.confirmed = False
        self.setWindowTitle(self.m.t('delete.question', game.name))
        self.setMinimumSize(520, 380)
        self.setStyleSheet(style.STYLESHEET)

        self.plan = lib.GameDeletionPlan.plan(game, measure=True)
        self.delete_saves = False

        lay = QVBoxLayout(self)
        lay.setContentsMargins(24, 22, 24, 20)
        lay.setSpacing(14)

        title = QLabel(self.m.t('delete.question', game.name))
        title.setStyleSheet('font-size: 20px; font-weight: 800;')
        lay.addWidget(title)

        note = QLabel(self.m.t('delete.note') + ' ' + self.m.t('delete.sources'))
        note.setObjectName('muted')
        note.setWordWrap(True)
        lay.addWidget(note)

        part_labels = {
            'macApp': self.m.t('delete.part.macApp'),
            'ipa': self.m.t('delete.part.ipa'),
            'iosApp': self.m.t('delete.part.iosApp'),
            'archive': self.m.t('delete.part.archive'),
            'shellFramework': self.m.t('delete.part.shellFramework'),
            'buildFolder': self.m.t('delete.part.buildFolder'),
            'log': self.m.t('delete.part.log'),
        }

        group = CardGroup()
        if not self.plan.items:
            r = QWidget()
            rl = QHBoxLayout(r)
            rl.setContentsMargins(18, 14, 18, 14)
            lbl = QLabel(self.m.t('delete.nothing'))
            lbl.setObjectName('muted')
            lbl.setWordWrap(True)
            rl.addWidget(lbl)
            group.add_row(r)
        else:
            for idx, it in enumerate(self.plan.items):
                if idx > 0:
                    group.add_divider()
                r = QWidget()
                rl = QHBoxLayout(r)
                rl.setContentsMargins(18, 12, 18, 12)
                t_lbl = QLabel(part_labels.get(it.kind, it.kind))
                t_lbl.setObjectName('rowTitle')
                rl.addWidget(t_lbl, 1)
                s_lbl = QLabel(lib.format_bytes(it.bytes))
                s_lbl.setObjectName('mono')
                rl.addWidget(s_lbl)
                group.add_row(r)
        lay.addWidget(group)

        if self.plan.saves:
            sgroup = CardGroup()
            sr = QWidget()
            srl = QHBoxLayout(sr)
            srl.setContentsMargins(18, 12, 18, 12)
            scol = QVBoxLayout()
            st = QLabel(self.m.t('delete.saves'))
            st.setObjectName('rowTitle')
            self.save_note_lbl = QLabel(self.m.t('delete.savesOff'))
            self.save_note_lbl.setObjectName('muted')
            scol.addWidget(st)
            scol.addWidget(self.save_note_lbl)
            srl.addLayout(scol, 1)
            ssz = QLabel(lib.format_bytes(self.plan.saves.bytes))
            ssz.setObjectName('mono')
            srl.addWidget(ssz)
            sw = LauncherSwitch(False)
            sw.toggled.connect(self._on_saves_toggled)
            srl.addWidget(sw)
            sgroup.add_row(sr)
            lay.addWidget(sgroup)

        lay.addStretch(1)

        foot = QHBoxLayout()
        foot.addStretch(1)
        cancel_btn = QPushButton(self.m.t('fail.confirm.cancel'))
        cancel_btn.clicked.connect(self.reject)
        foot.addWidget(cancel_btn)

        self.confirm_btn = QPushButton(self.m.t('delete.confirm'))
        self.confirm_btn.setObjectName('danger')
        self.confirm_btn.setEnabled(not self.m.running)
        self.confirm_btn.clicked.connect(self._do_delete)
        foot.addWidget(self.confirm_btn)
        lay.addLayout(foot)

    def _on_saves_toggled(self, checked: bool) -> None:
        self.delete_saves = checked
        if hasattr(self, 'save_note_lbl'):
            self.save_note_lbl.setText(self.m.t('delete.savesOn' if checked else 'delete.savesOff'))
        self.confirm_btn.setText(self.m.t('delete.confirmSaves' if checked else 'delete.confirm'))

    def _do_delete(self) -> None:
        failed = self.plan.run(delete_saves=self.delete_saves)
        if failed:
            QMessageBox.warning(self, self.m.t('library.error'), self.m.t('delete.failed', '\n'.join(failed)))
        self.m.library.remove(self.game.title_id)
        self.m._emit_library_changed()
        self.confirmed = True
        self.accept()


class CheatsDialog(QDialog):
    """Atmosphere cheat manager dialog mirroring CheatsView.swift."""

    def __init__(self, model: 'Model', game: lib.LibraryGame, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.m = model
        self.game = game
        self.setWindowTitle(f"{self.m.t('cheats.title')} — {game.name}")
        self.setMinimumSize(620, 520)
        self.setStyleSheet(style.STYLESHEET)

        self.folder = feat.CheatFiles.cheats_dir(
            game.title_id,
            work_dir=game.work_dir,
            archive_dir=game.archive_path if game.has_archive else None,
        )
        self.build_id = feat.CheatFiles.read_build_id(
            work_dir=game.work_dir,
            ipa_path=game.ipa_path if game.has_ipa else None,
            title_id=game.title_id,
        )

        lay = QVBoxLayout(self)
        lay.setContentsMargins(24, 22, 24, 20)
        lay.setSpacing(14)

        head = QHBoxLayout()
        title = QLabel(f"{self.m.t('cheats.title')} · {game.name}")
        title.setStyleSheet('font-size: 20px; font-weight: 800;')
        head.addWidget(title)
        head.addStretch(1)

        import_btn = QPushButton(self.m.t('cheats.import'))
        import_btn.clicked.connect(self._import_cheats)
        head.addWidget(import_btn)

        open_btn = QPushButton(self.m.t('cheats.showFolder'))
        open_btn.clicked.connect(self._open_folder)
        head.addWidget(open_btn)
        lay.addLayout(head)

        ios_note = QLabel(self.m.t('cheats.iosNote'))
        ios_note.setObjectName('muted')
        ios_note.setWordWrap(True)
        lay.addWidget(ios_note)

        # Master switch & Build ID card
        top_group = CardGroup()
        mrow = QWidget()
        mrl = QHBoxLayout(mrow)
        mrl.setContentsMargins(18, 12, 18, 12)
        mcol = QVBoxLayout()
        mt = QLabel(self.m.t('cheats.master'))
        mt.setObjectName('rowTitle')
        mn = QLabel(self.m.t('cheats.note'))
        mn.setObjectName('muted')
        mcol.addWidget(mt)
        mcol.addWidget(mn)
        mrl.addLayout(mcol, 1)
        self.master_sw = LauncherSwitch(True)
        self.master_sw.toggled.connect(self._on_master_toggled)
        mrl.addWidget(self.master_sw)
        top_group.add_row(mrow)
        top_group.add_divider()

        brow = QWidget()
        brl = QHBoxLayout(brow)
        brl.setContentsMargins(18, 12, 18, 12)
        bt = QLabel(self.m.t('cheats.buildLabel'))
        bt.setObjectName('rowTitle')
        brl.addWidget(bt, 1)
        bval = QLabel(self.build_id or self.m.t('cheats.buildUnknown'))
        bval.setObjectName('mono')
        brl.addWidget(bval)
        top_group.add_row(brow)
        lay.addWidget(top_group)

        self.status_lbl = QLabel('')
        self.status_lbl.setObjectName('muted')
        lay.addWidget(self.status_lbl)

        self.scroll = QScrollArea()
        self.scroll.setWidgetResizable(True)
        self.list_host = QWidget()
        self.list_layout = QVBoxLayout(self.list_host)
        self.list_layout.setContentsMargins(0, 0, 0, 0)
        self.list_layout.setSpacing(12)
        self.scroll.setWidget(self.list_host)
        lay.addWidget(self.scroll, 1)

        foot = QHBoxLayout()
        foot.addStretch(1)
        done_btn = QPushButton(self.m.t('free.done'))
        done_btn.setObjectName('creamPill')
        done_btn.clicked.connect(self.accept)
        foot.addWidget(done_btn)
        lay.addLayout(foot)

        self._reload()

    def _reload(self) -> None:
        while self.list_layout.count():
            it = self.list_layout.takeAt(0)
            if it.widget():
                it.widget().deleteLater()

        master_on, files = feat.CheatFiles.load_folder(self.folder, self.game.title_id)
        self.master_sw.setChecked(master_on)

        if not files:
            empty = CardGroup()
            r = QWidget()
            rl = QHBoxLayout(r)
            rl.setContentsMargins(18, 18, 18, 18)
            lbl = QLabel(self.m.t('cheats.empty'))
            lbl.setObjectName('muted')
            lbl.setWordWrap(True)
            rl.addWidget(lbl)
            empty.add_row(r)
            self.list_layout.addWidget(empty)
            self.list_layout.addStretch(1)
            return

        for bf in files:
            is_curr = (self.build_id is None) or (bf.build_id.upper() == self.build_id.upper())
            badge = self.m.t('cheats.thisBuild') if is_curr else self.m.t('cheats.otherBuild')
            grp = CardGroup(title=f'{bf.build_id} · {badge}')
            for idx, ch in enumerate(bf.cheats):
                if idx > 0:
                    grp.add_divider()
                row = QWidget()
                rl = QHBoxLayout(row)
                rl.setContentsMargins(18, 10, 18, 10)
                col = QVBoxLayout()
                t_lbl = QLabel(ch.name)
                t_lbl.setObjectName('rowTitle')
                col.addWidget(t_lbl)
                if not ch.is_valid:
                    sub = QLabel(self.m.t('cheats.broken'))
                    sub.setStyleSheet(f'color: {style.RED}; font-size: 11.5px;')
                    col.addWidget(sub)
                elif ch.is_master:
                    sub = QLabel(self.m.t('cheats.alwaysOn'))
                    sub.setObjectName('muted')
                    col.addWidget(sub)
                elif ch.runs_once:
                    sub = QLabel(self.m.t('cheats.once'))
                    sub.setObjectName('muted')
                    col.addWidget(sub)
                rl.addLayout(col, 1)

                if ch.is_valid and not ch.is_master and is_curr:
                    sw = LauncherSwitch(ch.name in bf.enabled)
                    sw.toggled.connect(
                        lambda checked, b=bf.build_id, cname=ch.name: feat.CheatFiles.set_cheat_enabled(
                            self.folder, b, cname, checked
                        )
                    )
                    rl.addWidget(sw)
                grp.add_row(row)
            self.list_layout.addWidget(grp)
        self.list_layout.addStretch(1)

    def _on_master_toggled(self, checked: bool) -> None:
        feat.CheatFiles.set_master(self.folder, self.game.title_id, checked)

    def _import_cheats(self) -> None:
        files, _ = QFileDialog.getOpenFileNames(
            self,
            self.m.t('cheats.pickMessage'),
            '',
            'Cheat files (*.txt)',
        )
        if not files:
            return
        cnt, rejected = feat.CheatFiles.import_paths(files, self.folder, self.game.title_id)
        if cnt > 0:
            self.status_lbl.setText(self.m.t('cheats.imported', cnt))
        elif rejected:
            self.status_lbl.setText(self.m.t('cheats.notNamed', ', '.join(rejected)))
        else:
            self.status_lbl.setText(self.m.t('cheats.nothingFound'))
        self._reload()

    def _open_folder(self) -> None:
        os.makedirs(self.folder, exist_ok=True)
        pu.reveal(self.folder)


class OnboardingDialog(QDialog):
    """First-run setup assistant mirroring OnboardingView.swift."""

    def __init__(self, model: 'Model', parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.m = model
        self.step = 0
        self._step1_sig: tuple | None = None
        self._step1_widgets: dict = {}
        self.setWindowTitle('NX2Apple Setup')
        self.setMinimumSize(640, 520)
        self.setStyleSheet(style.STYLESHEET)

        lay = QVBoxLayout(self)
        lay.setContentsMargins(32, 28, 32, 24)
        lay.setSpacing(16)

        top_row = QHBoxLayout()
        self.step_badge = QLabel('')
        self.step_badge.setObjectName('muted')
        top_row.addWidget(self.step_badge)
        top_row.addStretch(1)
        self.task_pill = QLabel('')
        self.task_pill.setStyleSheet(
            f'color: {style.ACCENT}; background: rgba(255, 240, 214, 0.10); '
            'border: 1px solid rgba(255, 240, 214, 0.22); border-radius: 10px; '
            'padding: 3px 10px; font-size: 11.5px; font-weight: 600;'
        )
        self.task_pill.hide()
        top_row.addWidget(self.task_pill)
        lay.addLayout(top_row)

        self.head_title = QLabel('')
        self.head_title.setStyleSheet('font-size: 28px; font-weight: 800;')
        self.head_title.setWordWrap(True)
        lay.addWidget(self.head_title)

        note_row = QHBoxLayout()
        self.head_note = QLabel('')
        self.head_note.setObjectName('pageNote')
        self.head_note.setWordWrap(True)
        note_row.addWidget(self.head_note, 1)
        self.overall_pct_lbl = QLabel('')
        self.overall_pct_lbl.setObjectName('mono')
        self.overall_pct_lbl.setStyleSheet(f'color: {style.ACCENT}; font-size: 12px; font-weight: 700;')
        self.overall_pct_lbl.hide()
        note_row.addWidget(self.overall_pct_lbl)
        lay.addLayout(note_row)

        self.body_host = QWidget()
        self.body_layout = QVBoxLayout(self.body_host)
        self.body_layout.setContentsMargins(0, 8, 0, 8)
        self.body_layout.setSpacing(12)
        lay.addWidget(self.body_host, 1)

        foot = QHBoxLayout()
        self.later_btn = QPushButton(self.m.t('onboarding.later'))
        self.later_btn.setObjectName('ghost')
        self.later_btn.clicked.connect(self._on_later)
        foot.addWidget(self.later_btn)
        foot.addStretch(1)

        self.back_btn = QPushButton(self.m.t('onboarding.back'))
        self.back_btn.clicked.connect(self._prev_step)
        foot.addWidget(self.back_btn)

        self.next_btn = QPushButton(self.m.t('onboarding.continue'))
        self.next_btn.setObjectName('creamPill')
        self.next_btn.clicked.connect(self._next_step)
        foot.addWidget(self.next_btn)
        lay.addLayout(foot)

        self.m.depsChanged.connect(self._render_step)
        self.m.repoChanged.connect(self._render_step)
        self._render_step()

    def done(self, result: int) -> None:
        try:
            self.m.depsChanged.disconnect(self._render_step)
        except (RuntimeError, TypeError):
            pass
        try:
            self.m.repoChanged.disconnect(self._render_step)
        except (RuntimeError, TypeError):
            pass
        super().done(result)

    def _on_later(self) -> None:
        self.m.settings_set('onboardingComplete', True)
        self.reject()

    def _clear_body(self) -> None:
        self._step1_sig = None
        self._step1_widgets = {}
        while self.body_layout.count():
            it = self.body_layout.takeAt(0)
            w = it.widget()
            if w is not None:
                w.hide()
                w.setParent(None)
                w.deleteLater()

    def _step1_row_meta(self, d, llvm_dep, any_busy: bool) -> tuple[str, str, str, str, str, int | None]:
        """Compute (dot_color, status_text, status_color, detail_text, detail_color, pct) for step 2."""
        if d.ok:
            return (style.GREEN, self.m.t('onboarding.ready'), style.GREEN, '', '', None)
        if getattr(d, 'installing', False):
            stage = getattr(d, 'install_stage', '') or self.m.t('dep.installing')
            detail = getattr(d, 'install_detail', '')
            pct_raw = getattr(d, 'install_pct', None)
            pct = max(0, min(100, int(pct_raw))) if pct_raw is not None else 0
            return (style.AMBER, stage, style.ACCENT, detail, style.MUTED, pct)
        if d.id == 'lld' and llvm_dep is not None and not llvm_dep.ok:
            if getattr(llvm_dep, 'installing', False):
                return (style.AMBER, self.m.t('onboarding.progress.waitingLlvm'), style.MUTED, '', '', None)
            if getattr(llvm_dep, 'queue_index', 0) > 0 or any_busy:
                return (style.NEUTRAL_DOT, self.m.t('onboarding.progress.withLlvm'), style.MUTED, '', '', None)
        q_idx = int(getattr(d, 'queue_index', 0) or 0)
        if q_idx > 0:
            return (style.NEUTRAL_DOT, self.m.t('onboarding.progress.queuePos', q_idx), style.MUTED, '', '', None)
        dot = style.AMBER if not d.required else style.RED
        err = getattr(d, 'last_error', '')
        fix = getattr(d, 'fix_hint', '')
        detail = (err + (' — ' + self.m.t(fix) if fix else '')) if err else ''
        return (dot, self.m.t('onboarding.failed'), '', detail, style.AMBER if detail else '', None)

    def _render_step(self) -> None:
        self.step_badge.setText(self.m.t('onboarding.stepCount', self.step + 1, 4))
        self.back_btn.setVisible(self.step > 0)
        any_busy = (
            any(getattr(d, 'installing', False) for d in self.m.deps)
            or bool(getattr(self.m, '_install_all_running', False))
        )
        if self.step != 1:
            self.task_pill.hide()
            self.overall_pct_lbl.hide()
            self.next_btn.setEnabled(True)
            self.back_btn.setEnabled(True)

        if self.step == 0:
            self._clear_body()
            self.head_title.setText(self.m.t('onboarding.welcome.title'))
            self.head_note.setText(self.m.t('onboarding.welcome.note'))
            self.next_btn.setText(self.m.t('onboarding.start'))

            grp = CardGroup()
            free_gb = int(shutil.disk_usage(Path.home()).free // (1024 ** 3))
            r1 = QWidget()
            rl1 = QHBoxLayout(r1)
            rl1.setContentsMargins(18, 14, 18, 14)
            rl1.addWidget(StatusDot(style.GREEN if free_gb >= 15 else style.AMBER))
            c1 = QVBoxLayout()
            t1 = QLabel(self.m.t('onboarding.require.disk'))
            t1.setObjectName('rowTitle')
            n1 = QLabel(self.m.t('onboarding.require.diskNote', free_gb, 15))
            n1.setObjectName('muted')
            c1.addWidget(t1)
            c1.addWidget(n1)
            rl1.addLayout(c1, 1)
            grp.add_row(r1)
            grp.add_divider()

            r2 = QWidget()
            rl2 = QHBoxLayout(r2)
            rl2.setContentsMargins(18, 14, 18, 14)
            rl2.addWidget(StatusDot(style.GREEN))
            c2 = QVBoxLayout()
            t2 = QLabel(self.m.t('onboarding.require.files'))
            t2.setObjectName('rowTitle')
            n2 = QLabel(self.m.t('onboarding.require.filesNote'))
            n2.setObjectName('muted')
            c2.addWidget(t2)
            c2.addWidget(n2)
            rl2.addLayout(c2, 1)
            grp.add_row(r2)
            self.body_layout.addWidget(grp)

        elif self.step == 1:
            self.head_title.setText(self.m.t('onboarding.background.title'))
            self.head_note.setText(self.m.t('dep.title'))
            self.next_btn.setText(self.m.t('onboarding.continue'))
            self.next_btn.setEnabled(not any_busy)
            self.back_btn.setEnabled(not any_busy)

            active_dep = next((x for x in self.m.deps if getattr(x, 'installing', False)), None)
            if getattr(self.m, '_install_all_running', False) and getattr(self.m, 'install_all_total', 0) > 0:
                curr_step = max(1, int(self.m.install_all_step or 1))
                total_tasks = max(curr_step, int(self.m.install_all_total or 1))
                overall_pct = max(0, min(100, int(getattr(self.m, 'install_all_pct', 0) or 0)))
            elif any_busy:
                curr_step = 1
                total_tasks = 1
                overall_pct = max(0, min(100, int(getattr(active_dep, 'install_pct', 0) or 0)))
            else:
                curr_step = total_tasks = overall_pct = 0

            if any_busy:
                self.task_pill.setText(self.m.t('onboarding.progress.taskBadge', curr_step, total_tasks))
                self.task_pill.show()
                self.overall_pct_lbl.setText(self.m.t('onboarding.progress.overallPct', overall_pct))
                self.overall_pct_lbl.show()
            else:
                self.task_pill.hide()
                self.overall_pct_lbl.hide()

            visible_deps = list(self.m.deps[:5])
            for extra in self.m.deps[5:]:
                if getattr(extra, 'installing', False) and extra not in visible_deps:
                    visible_deps.append(extra)

            llvm_dep = next((x for x in self.m.deps if x.id == 'llvm'), None)
            metas = [self._step1_row_meta(d, llvm_dep, any_busy) for d in visible_deps]
            show_ibtn = any_busy or any(not d.ok and d.install for d in self.m.deps)
            if any_busy:
                active_stage = (
                    (getattr(active_dep, 'install_stage', '') if active_dep else '')
                    or self.m.t('dep.installing')
                )
                ibtn_text = self.m.t('onboarding.progress.installingBtn', curr_step, total_tasks, active_stage)
            else:
                ibtn_text = self.m.t('dep.installAll')

            sig = (
                1,
                any_busy,
                show_ibtn,
                tuple(
                    (d.id, m[0], bool(m[3]), m[5] is not None)
                    for d, m in zip(visible_deps, metas)
                ),
            )
            if sig == self._step1_sig and self._step1_widgets:
                row_map = self._step1_widgets.get('rows', {})
                for d, meta in zip(visible_deps, metas):
                    w = row_map.get(d.id)
                    if not w:
                        continue
                    _dot, st_text, st_color, dt_text, dt_color, pct_val = meta
                    w['status'].setText(st_text)
                    w['status'].setStyleSheet(
                        f'color: {st_color}; font-size: 12px; font-weight: 600;' if st_color else ''
                    )
                    if w.get('detail') is not None and dt_text:
                        w['detail'].setText(dt_text)
                        w['detail'].setStyleSheet(f'color: {dt_color}; font-size: 11.5px;' if dt_color else '')
                    if w.get('bar') is not None and pct_val is not None:
                        w['bar'].setValue(pct_val)
                ibtn_w = self._step1_widgets.get('ibtn')
                if ibtn_w is not None:
                    ibtn_w.setText(ibtn_text)
                    ibtn_w.setEnabled(not any_busy)
                return

            self._clear_body()
            self._step1_sig = sig
            row_widgets: dict = {}

            grp = CardGroup()
            for idx, (d, meta) in enumerate(zip(visible_deps, metas)):
                if idx > 0:
                    grp.add_divider()
                dot_color, st_text, st_color, dt_text, dt_color, pct_val = meta
                r = QWidget()
                v = QVBoxLayout(r)
                v.setContentsMargins(18, 10, 18, 10)
                v.setSpacing(6)

                rl = QHBoxLayout()
                rl.setSpacing(10)
                dot_w = StatusDot(dot_color)
                rl.addWidget(dot_w)
                tl = QLabel(self.m.t(d.title_key))
                tl.setObjectName('rowTitle')
                rl.addWidget(tl, 1)
                st = QLabel(st_text)
                st.setObjectName('muted')
                if st_color:
                    st.setStyleSheet(f'color: {st_color}; font-size: 12px; font-weight: 600;')
                rl.addWidget(st)
                v.addLayout(rl)

                dl = None
                if dt_text:
                    dl = QLabel(dt_text)
                    dl.setObjectName('mono')
                    dl.setWordWrap(True)
                    dl.setContentsMargins(18, 0, 0, 0)
                    if dt_color:
                        dl.setStyleSheet(f'color: {dt_color}; font-size: 11.5px;')
                    v.addWidget(dl)

                bar = None
                if pct_val is not None:
                    bar_wrap = QHBoxLayout()
                    bar_wrap.setContentsMargins(18, 2, 0, 2)
                    bar = QProgressBar()
                    bar.setRange(0, 100)
                    bar.setValue(pct_val)
                    bar.setTextVisible(False)
                    bar_wrap.addWidget(bar)
                    v.addLayout(bar_wrap)

                row_widgets[d.id] = {'dot': dot_w, 'status': st, 'detail': dl, 'bar': bar}
                grp.add_row(r)
            self.body_layout.addWidget(grp)

            ibtn = None
            if show_ibtn:
                ibtn = QPushButton(ibtn_text)
                ibtn.setEnabled(not any_busy)
                ibtn.clicked.connect(self.m.install_all_missing)
                self.body_layout.addWidget(ibtn)

            self._step1_widgets = {'rows': row_widgets, 'ibtn': ibtn}

        elif self.step == 2:
            self._clear_body()
            self.head_title.setText(self.m.t('onboarding.keys.title'))
            self.head_note.setText(self.m.t('onboarding.keys.note'))
            self.next_btn.setText(self.m.t('onboarding.continue'))

            grp = CardGroup(footer=self.m.t('onboarding.keys.privacy'))
            r = QWidget()
            rl = QHBoxLayout(r)
            rl.setContentsMargins(18, 14, 18, 14)
            parsed = feat.KeyCheck.load_keys(self.m.keys_path) if self.m.keys_path else None
            valid = bool(parsed and len(parsed.get('header_key', '')) == 64)
            rl.addWidget(StatusDot(style.GREEN if valid else style.NEUTRAL_DOT))
            col = QVBoxLayout()
            kt = QLabel(self.m.t('onboarding.keys.valid') if valid else (self.m.t('onboarding.keys.invalid') if self.m.keys_path else self.m.t('onboarding.keys.empty')))
            kt.setObjectName('rowTitle')
            kn = QLabel(self.m.keys_path or self.m.t('data.notSelected'))
            kn.setObjectName('mono')
            col.addWidget(kt)
            col.addWidget(kn)
            rl.addLayout(col, 1)
            pick_btn = QPushButton(self.m.t('onboarding.choose'))
            pick_btn.clicked.connect(self._pick_keys)
            rl.addWidget(pick_btn)
            grp.add_row(r)
            self.body_layout.addWidget(grp)

        elif self.step == 3:
            self._clear_body()
            self.head_title.setText(self.m.t('onboarding.games.title'))
            self.head_note.setText(self.m.t('onboarding.games.note'))
            self.next_btn.setText(self.m.t('onboarding.openLibrary'))

            grp = CardGroup()
            r = QWidget()
            rl = QHBoxLayout(r)
            rl.setContentsMargins(18, 14, 18, 14)
            folder = self.m.library.games_folder
            rl.addWidget(StatusDot(style.GREEN if folder else style.NEUTRAL_DOT))
            col = QVBoxLayout()
            gt = QLabel(self.m.t('onboarding.games.count', len(self.m.library.games)) if folder else self.m.t('library.folderTitle'))
            gt.setObjectName('rowTitle')
            gn = QLabel(folder or self.m.t('library.folderUnset'))
            gn.setObjectName('mono')
            col.addWidget(gt)
            col.addWidget(gn)
            rl.addLayout(col, 1)
            pick_btn = QPushButton(self.m.t('onboarding.choose'))
            pick_btn.clicked.connect(self._pick_games_folder)
            rl.addWidget(pick_btn)
            grp.add_row(r)
            self.body_layout.addWidget(grp)

        self.body_layout.addStretch(1)

    def _pick_keys(self) -> None:
        f, _ = QFileDialog.getOpenFileName(self, self.m.t('data.keys'), '', 'Keys (prod.keys *.keys *);;All files (*)')
        if f:
            self.m.keys_path = f
            self.m.repoChanged.emit()
            self._render_step()

    def _pick_games_folder(self) -> None:
        d = QFileDialog.getExistingDirectory(self, self.m.t('library.folderTitle'), self.m.library.games_folder or str(Path.home()))
        if d:
            self.m.library.set_games_folder(d, repo_path=self.m.engine_path, default_keys=self.m.keys_path)
            for g in self.m.library.games:
                self.m.artwork.request_banner_async(g.title_id)
            self.m._emit_library_changed()
            self._render_step()

    def _prev_step(self) -> None:
        if self.step > 0:
            self.step -= 1
            self._render_step()

    def _next_step(self) -> None:
        if self.step < 3:
            self.step += 1
            self._render_step()
        else:
            self.m.settings_set('onboardingComplete', True)
            self.accept()
