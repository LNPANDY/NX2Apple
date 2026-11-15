"""The two Windows shared-shell defects that broke every shared build, and the reveal path.

`REQUIRED_DYLIB_SYMBOLS` used to list names the engine never defines, so `check_dylib()` rejected
the framework `link_framework()` had just linked and `[7/8] game framework` failed on every game.
The reveal button used to ask `Model.ipa_path` first, which names whichever kind built last, so
after switching between shared and one-game it opened the other mode's IPA.

Both are pure-Python and run without PySide6: the symbol names are read out of the engine's own
sources, and `library.reveal_ipa_path` takes its state as arguments.
"""
from __future__ import annotations

import os
import re
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
QT = HERE.parent
ROOT = QT.parent
sys.path.insert(0, str(QT))

from nspb_qt import library as lib  # noqa: E402
from nspb_qt.win import build_app  # noqa: E402


# ---------------------------------------------------------------- the framework's exports

def _engine_ios_dir() -> Path:
    return ROOT / 'engine' / 'dm' / 'ios'


def _engine_sources() -> list[Path]:
    """The engine's own sources that define or declare the framework's exported symbols."""
    engine = ROOT / 'engine' / 'dm'
    out: list[Path] = []
    for sub in ('ios', 'host'):
        d = engine / sub
        if d.is_dir():
            out += sorted(d.rglob('*.m')) + sorted(d.rglob('*.c')) + sorted(d.rglob('*.h'))
    return out


def _defined_in(path: Path, name: str) -> bool:
    """Whether `path` defines or declares `name` (not merely mentions it).

    A definition or declaration puts the identifier right before its parameter list, its
    initialiser, its array brackets or the end of the statement. A dlsym() call, a comment and a
    macro that happens to spell the name do not.
    """
    if not path.is_file():
        return False
    pat = re.compile(r'\b' + re.escape(name) + r'\s*[\(\[=;{]')
    for line in path.read_text(encoding='utf-8', errors='replace').splitlines():
        stripped = line.strip()
        if stripped.startswith('//') or stripped.startswith('#') or stripped.startswith('*'):
            continue
        if 'dlsym' in stripped:
            continue
        if pat.search(stripped):
            return True
    return False


class RequiredDylibSymbolsTest(unittest.TestCase):
    """Every symbol `check_dylib()` demands must be one the engine actually defines, under the
    exact name the linker exports (a leading underscore on Mach-O)."""

    def test_the_list_is_not_empty(self) -> None:
        self.assertTrue(build_app.REQUIRED_DYLIB_SYMBOLS)

    def test_every_symbol_is_defined_by_the_engine(self) -> None:
        sources = _engine_sources()
        if not sources:
            self.skipTest('engine/ is missing: run python3 tools/engine.py sync')
        missing = []
        for sym in build_app.REQUIRED_DYLIB_SYMBOLS:
            name = sym[1:] if sym.startswith('_') else sym
            if not any(_defined_in(p, name) for p in sources):
                missing.append(sym)
        self.assertEqual(missing, [], f'the engine defines none of these: {missing}')

    def test_the_marker_is_the_name_framework_bootstrap_looks_for(self) -> None:
        header = _engine_ios_dir() / 'Sources' / 'FrameworkBootstrap.h'
        if not header.is_file():
            self.skipTest('engine/ is missing: run python3 tools/engine.py sync')
        text = header.read_text(encoding='utf-8', errors='replace')
        self.assertIn('#define DM_FRAMEWORK_MARKER "dmgame_image_marker"', text)
        self.assertIn('_dmgame_image_marker', build_app.REQUIRED_DYLIB_SYMBOLS)

    def test_the_glue_symbols_the_shell_dlsyms_are_all_required(self) -> None:
        shell_main = ROOT / 'frontend-ios' / 'Shell' / 'App' / 'ShellMain.m'
        self.assertTrue(shell_main.is_file(), f'missing shell source: {shell_main}')
        text = shell_main.read_text(encoding='utf-8', errors='replace')
        for name in ('dm_glue_version', 'dm_glue_start_game', 'dm_glue_present_game',
                     'dm_glue_focus_event'):
            if f'"{name}"' not in text:
                continue        # the shell stopped asking for it; nothing to require
            self.assertIn('_' + name, build_app.REQUIRED_DYLIB_SYMBOLS,
                          f'ShellMain.m dlsyms {name}, so a framework must export it')


# ---------------------------------------------------------------- the reveal button's file

class RevealIpaPathTest(unittest.TestCase):
    """`library.reveal_ipa_path` answers for the selected kind, not for the last build."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.shell = str(self.root / 'shell')
        self.out = str(self.root / 'out')
        (self.root / 'shell' / 'export').mkdir(parents=True)
        Path(self.out).mkdir(parents=True)
        self.tid = '010063301BD50000'
        self.shared = Path(self.shell) / 'export' / 'NX2Apple.ipa'
        self.one = Path(self.out) / f'{self.tid}.ipa'

    def _reveal(self, kind: str, last: str = '', library: str = '') -> str:
        return lib.reveal_ipa_path(ipa_kind=kind, shell_cache=self.shell, out_dir=self.out,
                                   build_key=self.tid, last_ipa=last, library_ipa=library)

    def _write_ipa(self, path: Path, *bundles: str) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(path, 'w') as ipa:
            for bundle in bundles:
                ipa.writestr(f'Payload/{bundle}.app/Info.plist', b'fixture')
                ipa.writestr(f'Payload/{bundle}.app/{bundle}', b'fixture')

    def test_shared_mode_finds_the_shell_ipa(self) -> None:
        self._write_ipa(self.shared, 'DmShell')
        self.assertEqual(self._reveal('shared'), str(self.shared))

    def test_one_game_mode_finds_its_own_ipa(self) -> None:
        self._write_ipa(self.one, 'DmIOS')
        self.assertEqual(self._reveal('oneGame'), str(self.one))

    def test_a_switch_does_not_reveal_the_other_kind(self) -> None:
        # both files exist, and the last build was the shared one
        self._write_ipa(self.shared, 'DmShell')
        self._write_ipa(self.one, 'DmIOS')
        self.assertEqual(self._reveal('oneGame', last=str(self.shared)), str(self.one))
        self.assertEqual(self._reveal('shared', last=str(self.one)), str(self.shared))

    def test_a_stale_last_path_is_not_used_when_it_is_the_other_kind(self) -> None:
        # the selected kind's file is gone, and the last build named the other kind's IPA
        self._write_ipa(self.shared, 'DmShell')
        self.assertEqual(self._reveal('oneGame', last=str(self.shared)), '')

    def test_a_last_path_of_the_selected_kind_is_used(self) -> None:
        # a build that wrote somewhere else still belongs to the selected kind
        elsewhere = self.root / 'elsewhere' / 'ZeldaBreathOfTheWild.ipa'
        self._write_ipa(elsewhere, 'DmIOS')
        self.assertEqual(self._reveal('oneGame', last=str(elsewhere)), str(elsewhere))

    def test_the_library_record_is_the_last_resort(self) -> None:
        elsewhere = self.root / 'elsewhere' / 'ZeldaBreathOfTheWild.ipa'
        self._write_ipa(elsewhere, 'DmIOS')
        self.assertEqual(self._reveal('oneGame', library=str(elsewhere)), str(elsewhere))

    def test_shared_completion_cannot_reappear_through_the_library_fallback(self) -> None:
        # A real shared export records the same IPA in the model and the library.
        self._write_ipa(self.shared, 'DmShell')
        self.assertEqual(self._reveal('oneGame', last=str(self.shared), library=str(self.shared)), '')

    def test_shared_mode_rejects_one_game_outputs_after_output_directory_changes(self) -> None:
        self._write_ipa(self.one, 'DmIOS')
        for out_dir in (self.out, '', str(self.root / 'new-output')):
            with self.subTest(out_dir=out_dir):
                self.assertEqual(lib.reveal_ipa_path(
                    ipa_kind='shared', shell_cache=self.shell, out_dir=out_dir,
                    build_key=self.tid, last_ipa=str(self.one), library_ipa=str(self.one)), '')

    def test_one_game_fallback_survives_default_or_changed_output_directory(self) -> None:
        self._write_ipa(self.one, 'DmIOS')
        for out_dir in ('', str(self.root / 'new-output')):
            for source in ('last_ipa', 'library_ipa'):
                with self.subTest(out_dir=out_dir, source=source):
                    self.assertEqual(lib.reveal_ipa_path(
                        ipa_kind='oneGame', shell_cache=self.shell, out_dir=out_dir,
                        build_key=self.tid, **{source: str(self.one)}), str(self.one))

    def test_one_game_fallback_uses_the_package_kind_instead_of_its_filename(self) -> None:
        # A default output has a profile name. An explicit multi-title choice can differ
        # from the title ID parsed out of the input package's filename.
        for name in ('0100000000000002.ipa', 'ZeldaBreathOfTheWild.ipa'):
            artifact = self.root / name
            self._write_ipa(artifact, 'DmIOS')
            for source in ('last', 'library'):
                with self.subTest(name=name, source=source):
                    self.assertEqual(self._reveal('oneGame', **{source: str(artifact)}), str(artifact))

    def test_renamed_shared_outputs_cannot_be_used_as_one_game_fallbacks(self) -> None:
        artifact = self.root / f'{self.tid}.ipa'
        self._write_ipa(artifact, 'DmShell')
        self.assertEqual(self._reveal('oneGame', last=str(artifact), library=str(artifact)), '')

    def test_corrupt_unknown_and_ambiguous_archives_are_not_revealed(self) -> None:
        self.one.write_bytes(b'not a zip')
        self.assertEqual(self._reveal('oneGame', last=str(self.one)), '')
        for bundles in (('UnknownApp',), ('DmShell', 'DmIOS')):
            self._write_ipa(self.one, *bundles)
            for kind in ('shared', 'oneGame'):
                with self.subTest(bundles=bundles, kind=kind):
                    self.assertEqual(self._reveal(kind, last=str(self.one), library=str(self.one)), '')

    def test_replacing_an_ipa_rechecks_its_kind(self) -> None:
        self._write_ipa(self.one, 'DmIOS')
        self.assertEqual(self._reveal('oneGame'), str(self.one))
        self._write_ipa(self.one, 'DmShell')
        self.assertEqual(self._reveal('oneGame'), '')

    def test_unsupported_or_malformed_zip_headers_are_not_revealed(self) -> None:
        self._write_ipa(self.one, 'DmIOS')
        original = self.one.read_bytes()
        central = original.index(b'PK\x01\x02')
        unsupported = bytearray(original)
        unsupported[central + 6:central + 8] = (99).to_bytes(2, 'little')
        invalid_utf8 = bytearray(original)
        flags = int.from_bytes(invalid_utf8[central + 8:central + 10], 'little')
        invalid_utf8[central + 8:central + 10] = (flags | 0x800).to_bytes(2, 'little')
        invalid_utf8[central + 46] = 0xff
        for data in (unsupported, invalid_utf8):
            with self.subTest(header=data[central:central + 10]):
                self.one.write_bytes(data)
                self.assertEqual(self._reveal('oneGame', last=str(self.one)), '')

    def test_missing_files_and_directories_are_not_revealable_outputs(self) -> None:
        for path in (self.one, self.shared):
            for is_directory in (False, True):
                if is_directory:
                    path.mkdir()
                for kind in ('shared', 'oneGame'):
                    with self.subTest(path=path, is_directory=is_directory, kind=kind):
                        self.assertEqual(self._reveal(kind, last=str(path), library=str(path)), '')

    def test_a_one_game_named_alias_cannot_reveal_the_shared_ipa(self) -> None:
        self._write_ipa(self.shared, 'DmShell')
        try:
            self.one.symlink_to(self.shared)
        except OSError as error:
            self.skipTest(f'symlinks unavailable: {error}')
        self.assertEqual(self._reveal('oneGame', last=str(self.one), library=str(self.one)), '')

    def test_nothing_known_returns_empty(self) -> None:
        self.assertEqual(self._reveal('shared'), '')

    def test_the_paths_match_what_the_export_writes(self) -> None:
        from nspb_qt.win import shell_export as se
        self.assertEqual(os.path.normcase(lib.shell_ipa_path(self.shell)),
                         os.path.normcase(str(se.ipa_path(self.shell))))
        self.assertEqual(os.path.normcase(lib.one_game_ipa_path(self.out, self.tid)),
                         os.path.normcase(str(self.one)))


class ExternalMslAndBatchDriveCopyTest(unittest.TestCase):
    """Stripped framework packing without `external-msl.json`, named DriveCopy without `msl/` merge, stale detection, and batch preflight."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def test_stripped_framework_and_named_drive_copy_skip_external_msl_merge(self) -> None:
        import json
        from nspb_qt import post_build_cleanup as pbc
        from nspb_qt.win import shell_export as se

        tid = '010063301BD50000'
        shell_root = self.root / 'shell'
        mirror_fw = se.mirrored_framework(shell_root, tid)
        (mirror_fw / 'msl' / 'b-chain').mkdir(parents=True)
        (mirror_fw / f'DmGame{tid}').write_bytes(b'macho')
        (mirror_fw / 'game.manifest.json').write_text(
            json.dumps({'loader': 'FH', 'name': 'Test Title', 'chain': 'b-1111'}), encoding='utf-8'
        )
        shader_blob = b'S' * 128
        (mirror_fw / 'msl' / 'b-chain' / 'shaders.img').write_bytes(shader_blob)

        archive_dir = self.root / 'games' / 'Test Title'
        archive_dir.mkdir(parents=True)
        (archive_dir / 'Test Title.img').write_bytes(b'ROMFS')
        pbc.write_title_id_marker(archive_dir, tid)

        sizes, origins = lib.DriveCopy.collect_transfer_files(
            str(archive_dir), shell_root=str(shell_root), title_id=tid, dest_folder_name='Test Title'
        )
        self.assertIn('Test Title.img', sizes)
        self.assertEqual(origins.get('Test Title.img'), str(archive_dir / 'Test Title.img'))
        self.assertFalse(any(k.startswith('msl/') for k in sizes))

        drive_dest = self.root / 'usb'
        ok, out_dir = lib.DriveCopy.copy_to_folder(
            str(archive_dir), str(drive_dest), tid, game_name='Test Title', shell_root=str(shell_root)
        )
        self.assertTrue(ok, out_dir)
        self.assertEqual(Path(out_dir), drive_dest / 'Test Title')
        self.assertEqual((Path(out_dir) / 'Test Title.img').read_bytes(), b'ROMFS')
        self.assertEqual(pbc.read_title_id_marker(out_dir), tid)
        self.assertFalse((Path(out_dir) / 'msl').exists())

    def test_find_stale_frameworks_and_batch_preflight(self) -> None:
        import json
        from unittest import mock
        from nspb_qt.win import shell_export as se

        repo = self.root / 'repo'
        hdr = repo / 'dm' / 'gfx' / 'nvn' / 'dmsh_chain.h'
        hdr.parent.mkdir(parents=True)
        hdr.write_text('#define DMSH_CHAIN "b-newchain"\n', encoding='utf-8')

        shell_root = self.root / 'shell'
        tid_old = '0100000000000001'
        tid_cur = '0100000000000002'
        for tid, ch in ((tid_old, 'b-oldchain'), (tid_cur, 'b-newchain')):
            fw = se.mirrored_framework(shell_root, tid)
            fw.mkdir(parents=True)
            (fw / 'game.manifest.json').write_text(json.dumps({'chain': ch}), encoding='utf-8')
        slib = se.ShellLibrary(
            games=[
                se.ShellGame(title_id=tid_old, name='Old Game', framework=str(se.mirrored_framework(shell_root, tid_old))),
                se.ShellGame(title_id=tid_cur, name='Current Game', framework=str(se.mirrored_framework(shell_root, tid_cur))),
            ]
        )
        slib.save(shell_root)

        stale = se.find_stale_frameworks(shell_root, repo)
        self.assertEqual([g.title_id for g in stale], [tid_old])

        arch1 = self.root / 'arch1'
        arch2 = self.root / 'arch2'
        arch1.mkdir()
        arch2.mkdir()
        (arch1 / 'romfs.img').write_bytes(b'A' * 100)
        (arch2 / 'romfs.img').write_bytes(b'B' * 150)
        dest = self.root / 'drive'
        dest.mkdir()

        needed, err = lib.DriveCopy.preflight_batch_copy(
            [(tid_old, str(arch1)), (tid_cur, str(arch2))], str(dest)
        )
        self.assertEqual(needed, 250)
        self.assertIsNone(err)

        with mock.patch.object(lib.DriveCopy, 'free_space', return_value=200):
            _needed, space_err = lib.DriveCopy.preflight_batch_copy(
                [(tid_old, str(arch1)), (tid_cur, str(arch2))], str(dest)
            )
            self.assertIsNotNone(space_err)

    def test_export_and_install_built_counts_format_across_languages(self) -> None:
        from nspb_qt import l10n
        from nspb_qt.i18n import Lang

        for language in l10n.LANGUAGES:
            lang = Lang(language.code)
            for key in ('shell.exportBuilt', 'shell.installBuilt'):
                label = l10n.t(key, lang, 3)
                self.assertIn('3', label, f'{language.code} {key}: {label!r}')
                self.assertNotIn('%d', label, f'{language.code} {key}: {label!r}')
                self.assertNotIn(';', label, f'{language.code} {key}: {label!r}')

        self.assertEqual(l10n.t('shell.exportBuilt', Lang('en'), 2), 'Export IPA (2)')
        self.assertEqual(l10n.t('shell.exportBuilt', Lang('zh'), 2), '导出 IPA (2)')
        self.assertEqual(l10n.t('shell.exportBuilt', Lang('ja'), 2), 'IPA を書き出し (2)')

        try:
            import os
            from unittest import mock
            os.environ.setdefault('QT_QPA_PLATFORM', 'offscreen')
            from PySide6.QtCore import QEvent, QSettings
            from PySide6.QtWidgets import QApplication
            from nspb_qt import model as model_mod, ui as ui_mod
        except ImportError:
            from test_post_build_cleanup import _load_model_with_qt_fallback

            model_mod, cleanup = _load_model_with_qt_fallback()
            try:
                for code, expected2, expected5 in (
                    ('en', 'Export IPA (2)', 'Export IPA (5)'),
                    ('zh', '导出 IPA (2)', '导出 IPA (5)'),
                    ('ja', 'IPA を書き出し (2)', 'IPA を書き出し (5)'),
                ):
                    fake = type('Stub', (), {
                        't': lambda _s, k, *a, _c=code: l10n.t(k, Lang(_c), *a),
                        'built_shell_games': lambda _s: ['a', 'b'],
                    })()
                    self.assertEqual(model_mod.Model.export_built_label(fake), expected2)
                    self.assertEqual(model_mod.Model.export_built_label(fake, 5), expected5)
            finally:
                cleanup()
            return

        app = QApplication.instance() or QApplication([])
        with mock.patch.object(lib, 'default_state_dir', return_value=self.root / 'state'), \
             mock.patch.object(
                 model_mod,
                 'QSettings',
                 side_effect=lambda *a, **kw: QSettings(str(self.root / 'settings.ini'), QSettings.IniFormat),
             ), \
             mock.patch.object(model_mod.Model, 'check_deps', lambda _self: None):
            m = model_mod.Model()
            m.ipa_kind = 'shared'
            m.target = 'ios'
            m.built_shell_games = lambda: [
                {'title_id': '0100000000000001', 'name': 'One', 'framework': str(self.root / 'a.framework')},
                {'title_id': '0100000000000002', 'name': 'Two', 'framework': str(self.root / 'b.framework')},
            ]
            m.can_export_built_games = lambda: True
            win = ui_mod.MainWindow(m)
            win._init_timer.stop()
            try:
                for code, expected in (('en', 'Export IPA (2)'), ('zh', '导出 IPA (2)'), ('ja', 'IPA を書き出し (2)')):
                    m.set_lang(Lang(code))
                    win._refresh_install_card()
                    app.processEvents()
                    self.assertEqual(win.step1_repack_btn.text(), expected)
            finally:
                win.close()
                win.deleteLater()
                m.deleteLater()
                app.sendPostedEvents(None, QEvent.DeferredDelete)
                app.processEvents()
    def test_partial_overwrite_trailer_interrupt_truncates_to_base_size(self) -> None:
        import struct
        import threading

        def _make_base(size: int = 64) -> bytes:
            ioff = 48
            isz = max(16, size - ioff)
            return b'DMROMFS1' + struct.pack('<QQQ', ioff, isz, 0) + (b'\x11' * 16) + (b'\x33' * isz)

        def _with_trailer(base: bytes, payload: bytes, chain: str) -> bytes:
            base_sz = len(base)
            msl_off = (base_sz + 16383) & ~16383
            out = bytearray(base) + bytearray(msl_off - base_sz) + bytearray(payload)
            aligned_end = (len(out) + 7) & ~7
            out.extend(bytearray(aligned_end - len(out)))
            ch_b = chain.encode('utf-8')[:24]
            footer = bytearray(64)
            footer[0:8] = b'DMMSLTR1'
            struct.pack_into('<IBBHQQQ', footer, 8, 1, 1, 0, len(ch_b), base_sz, msl_off, len(payload))
            footer[40:40 + len(ch_b)] = ch_b
            return bytes(out + footer)

        base = _make_base()
        src_bytes = _with_trailer(base, b'\x55' * 8192, 'b-cur999')
        old_bytes = _with_trailer(base, b'\x22' * 128, 'b-old999')

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            src = root / 'src.img'
            dst = root / 'dst.img'
            peer = root / 'peer.img'
            src.write_bytes(src_bytes)
            dst.write_bytes(old_bytes)
            os.link(dst, peer)
            self.assertGreater(os.stat(dst).st_nlink, 1)

            cancel = threading.Event()
            done, aborted = lib.DriveCopy.partial_overwrite_trailer(
                str(src), str(dst), len(base), chunk_size=4096, cancel_event=cancel,
                on_chunk=lambda _written: cancel.set(),
            )
            self.assertFalse(done)
            self.assertTrue(aborted)
            self.assertEqual(os.stat(dst).st_nlink, 1)
            self.assertEqual(peer.read_bytes(), old_bytes)
            self.assertEqual(dst.read_bytes(), base)

            ok, aborted2 = lib.DriveCopy.partial_overwrite_trailer(
                str(src), str(dst), len(base), chunk_size=4096,
            )
            self.assertTrue(ok)
            self.assertFalse(aborted2)
            self.assertEqual(dst.read_bytes(), src_bytes)

    def test_locate_ios_msl_source_reads_cache_chain_and_fallbacks(self) -> None:
        cleanup = None
        try:
            from nspb_qt.model import Model
        except ImportError:
            if str(HERE) not in sys.path:
                sys.path.insert(0, str(HERE))
            from test_post_build_cleanup import _load_model_with_qt_fallback
            model_mod, cleanup = _load_model_with_qt_fallback()
            Model = model_mod.Model

        try:
            tid = '010015100B514000'
            with tempfile.TemporaryDirectory() as tmp:
                work = Path(tmp) / 'work'
                cache_dir = work / 'shell-framework' / '.msl-cache'
                cache_dir.mkdir(parents=True)
                shader_src = work / 'shader' / 'ios' / 'b-abc123'
                shader_src.mkdir(parents=True)
                (cache_dir / f'{tid}.json').write_text(
                    f'{{"schema": 1, "title_id": "{tid}", "gfx_api": "nvn", "chain": "b-abc123", '
                    f'"lib_path": "{shader_src}", "msl_root": "{shader_src.parent}", "multi_program": false}}',
                    encoding='utf-8',
                )
                found = Model._locate_ios_msl_source(str(work), tid)
                self.assertEqual(found, (str(shader_src), 'nvn', 'b-abc123', False))

                # Fallback without .msl-cache: vk / gl / b-* under shader/ios, then build/ios/dmsh_b
                (cache_dir / f'{tid}.json').unlink()
                self.assertEqual(Model._locate_ios_msl_source(str(work), tid), (str(shader_src), 'nvn', 'b-abc123', False))

                vk_dir = work / 'shader' / 'ios' / 'vk'
                vk_dir.mkdir()
                (shader_src / 'dummy.metallib').write_text('x', encoding='utf-8')
                self.assertEqual(Model._locate_ios_msl_source(str(work), tid), (str(shader_src), 'nvn', 'b-abc123', False))

                # When only vk exists under shader/ios, returns vulkan fallback
                for p in shader_src.iterdir():
                    p.unlink()
                shader_src.rmdir()
                self.assertEqual(Model._locate_ios_msl_source(str(work), tid), (str(vk_dir), 'vulkan', None, False))

                vk_dir.rmdir()
                dmsh_b = work / 'build' / 'ios' / 'dmsh_b'
                dmsh_b.mkdir(parents=True)
                (dmsh_b / 'out.metallib').write_text('m', encoding='utf-8')
                self.assertEqual(Model._locate_ios_msl_source(str(work), tid), (str(dmsh_b), 'nvn', None, False))
        finally:
            if cleanup is not None:
                cleanup()


if __name__ == '__main__':
    unittest.main()
