"""Synthetic package headers only: no game data, ticket contents or keys."""
import ast
from pathlib import Path
import re
import struct
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch
import os

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'frontend-qt'))
from nspb_qt.package_check import check, inspect, MISSING_ID
os.environ.setdefault('QT_QPA_PLATFORM', 'offscreen')
try:
    from PySide6.QtWidgets import QApplication
except ImportError:
    QApplication = None

BASE = 0x0100000000010000


class PackageCheckTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory(dir=ROOT / 'frontend-qt')
        self.root = Path(self.folder.name)
        # Execute just the backend's discovery helpers to verify the real contract without
        # importing the build pipeline or installing any of its dependencies.
        source = ast.parse((ROOT / 'scripts/build_ipa_from_nsp.py').read_text())
        names = {'pfs0_names', 'is_package', 'title_of', 'version_of', 'scan_nsps'}
        module = ast.Module(body=[n for n in source.body if isinstance(n, ast.FunctionDef) and n.name in names], type_ignores=[])
        self.backend = dict(re=re, struct=struct, COMPRESSED={'.nsz': '.nsp', '.xcz': '.xci'},
                            say=lambda _: None, BuildError=ValueError)
        exec(compile(module, '<backend discovery>', 'exec'), self.backend)

    def tearDown(self):
        self.folder.cleanup()

    def package(self, name, title=None, xci=False):
        path = self.root / name
        if xci:
            data = bytes(0x100) + b'HEAD'
        else:
            names = (f'{title:016X}0000000000000000.tik'.encode() + b'\0') if title is not None else b''
            data = b'PFS0' + struct.pack('<III', int(title is not None), len(names), 0)
            if names:
                data += struct.pack('<QQII', 0, 0, 0, 0) + names
        path.write_bytes(data)
        return str(path)

    def assert_backend_ready(self, result):
        self.assertTrue(result.ready, result.diagnostics)
        with tempfile.TemporaryDirectory(dir=self.root) as staged:
            for path in result.paths:
                (Path(staged) / Path(path).name).symlink_to(path)
            title, family = self.backend['scan_nsps'](Path(staged))
            self.assertEqual(title, result.title)
            self.assertIsNotNone(family['base'])

    def test_ticket_only_and_ticket_priority(self):
        path = self.package('wrong [0100000000010001].nsp', BASE)
        result = check((path, ''))
        self.assertEqual(result.title, BASE)
        self.assertEqual(result.packages[0].method, 'ticket name')
        self.assert_backend_ready(result)

    def test_filename_only_and_xci(self):
        for ext in ('.nsp', '.nsz', '.xci', '.xcz'):
            with self.subTest(ext=ext):
                path = self.package(f'game [{BASE:016X}]{ext}', xci=ext in ('.xci', '.xcz'))
                self.assertEqual(inspect(path).method, 'filename tag')
                self.assertEqual(inspect(path).title, BASE)
                Path(path).unlink()

    def test_missing_identity_is_not_a_keys_failure(self):
        path = self.package('untagged.nsp')
        result = check((path, ''))
        self.assertFalse(result.ready)
        self.assertEqual(result.packages[0].reason, MISSING_ID)

    def test_ticketless_base_with_automatic_update(self):
        base = self.package('cartridge.xci', xci=True)
        update = self.package('patch.nsp', BASE + 0x800)
        result = check((base, ''))
        self.assertIn(update, result.paths)
        self.assertIn('ticketless base', result.packages[0].method)
        self.assert_backend_ready(result)

    def test_ambiguous_ticketless_base_is_blocked(self):
        base = self.package('cartridge.xci', xci=True)
        self.package('unknown.nsp')
        self.package('patch.nsp', BASE + 0x800)
        self.assertFalse(check((base, '')).ready)

    def test_ticketless_does_not_replace_a_known_base(self):
        base = self.package('unknown.nsp')
        self.package('known.nsp', BASE)
        self.assertFalse(check((base, '')).ready)

    def test_missing_file_and_malformed_tag_are_blocked(self):
        missing = str(self.root / f'gone [{BASE:016X}].nsp')
        self.assertIn('missing', inspect(missing).reason)
        Path(missing).write_bytes(b'not a package')
        self.assertIn('Malformed', inspect(missing).reason)
        self.assertFalse(check((missing, '')).ready)

    def test_bounded_tables_and_truncation(self):
        path = self.root / 'bad.nsp'
        for data in (b'PFS0', b'PFS0' + struct.pack('<III', 0xffffffff, 0xffffffff, 0),
                     b'PFS0' + struct.pack('<III', 1, 0, 0) + bytes(24),
                     b'PFS0' + struct.pack('<III', 1, 1, 0) + struct.pack('<QQII', 2**64 - 1, 1, 0, 0) + b'\0',
                     b'PFS0' + struct.pack('<III', 1, 1, 0) + bytes(24) + b'x'):
            path.write_bytes(data)
            self.assertIn('Malformed', inspect(str(path)).reason)

    def test_mismatched_slot_and_foreign_selected_game(self):
        base = self.package('base.nsp', BASE)
        update = self.package('update.nsp', BASE + 0x800)
        foreign = self.package('foreign.nsp', BASE + 0x100800)
        self.assertIn('slot', check((update, '')).packages[0].reason)
        result = check((base, foreign))
        self.assertIn('different game', result.packages[1].reason)
        self.assertFalse(result.ready)

    def test_automatic_siblings_and_foreign_isolation(self):
        base = self.package('base.nsp', BASE)
        update = self.package('update.nsp', BASE + 0x800)
        dlc = self.package('dlc.nsp', BASE + 0x1001)
        foreign = self.package('foreign.nsp', BASE + 0x100000)
        result = check((base, ''))
        self.assertEqual(set(result.paths), {base, update, dlc})
        self.assertNotIn(foreign, result.paths)
        self.assertTrue(result.needs_staging)
        self.assert_backend_ready(result)

    def test_decompressed_copy_wins(self):
        base = self.package('base.nsp', BASE)
        compressed = self.package('base.nsz', BASE + 0x100800)
        result = check((compressed, ''))
        self.assertEqual(result.paths, [base])
        self.assertIn('skipped', result.packages[-1].method)
        self.assert_backend_ready(result)
        self.assert_backend_ready(check((base, '')))

    def test_selected_compressed_dlc_is_deduplicated_in_either_order(self):
        base = self.package('base.nsp', BASE)
        dlc = self.package('addon.nsp', BASE + 0x1001)
        compressed = self.package('addon.nsz', BASE + 0x1001)
        for selected in ((dlc, compressed), (compressed, dlc)):
            with self.subTest(selected=selected):
                result = check((base, '', *selected))
                self.assertEqual(result.paths, [base, dlc])
                self.assertEqual(len([p for p in result.packages if not p.consumed]), 1)
                self.assertIn('skipped', result.diagnostics)
                self.assert_backend_ready(result)

    def test_real_basename_collision_is_still_rejected(self):
        base = self.package('base.nsp', BASE)
        dlc = self.package('addon.nsp', BASE + 0x1001)
        other = self.root / 'other'
        other.mkdir()
        collision = other / 'addon.nsp'
        collision.write_bytes(Path(dlc).read_bytes())
        result = check((base, '', dlc, str(collision)))
        self.assertFalse(result.ready)
        self.assertIn('duplicate names', result.packages[0].reason)

    def test_dedicated_folder_does_not_need_staging(self):
        base = self.package('base.nsp', BASE)
        self.assertFalse(check((base, '')).needs_staging)

    def test_selected_metadata_and_uppercase_extensions_are_not_backend_inputs(self):
        for name in ('._metadata.nsp', 'game.NSP'):
            path = self.package(name, BASE)
            self.assertFalse(check((path, '')).ready)

    def test_diagnostics_contain_no_path_name_or_ticket_contents(self):
        base = self.package('private-filename.nsp', BASE)
        text = check((base, '')).diagnostics
        self.assertNotIn('private-filename', text)
        self.assertNotIn(str(self.root), text)
        self.assertNotIn('0000000000000000.tik', text)
        self.assertIn('ticket name', text)
        self.assertIn(f'{BASE:016X}', text)

    def test_task_localizations_match_the_shared_swift_table(self):
        from nspb_qt.localization import TABLE
        swift = (ROOT / 'frontend/Sources/NSPortBuilder/Localization.swift').read_text()
        for key in ('keycheck.fits', 'package.checking', 'package.ready', 'package.blocked',
                    'package.details', 'package.choose'):
            match = re.search(r'"' + re.escape(key) + r'": \("([^"]*)", "([^"]*)"\)', swift)
            self.assertIsNotNone(match, key)
            self.assertEqual(TABLE[key], match.groups())


@unittest.skipIf(QApplication is None, 'PySide6 is not installed')
class PackageModelTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app = QApplication.instance() or QApplication([])

    def wait_for(self, condition):
        deadline = time.monotonic() + 5
        while not condition() and time.monotonic() < deadline:
            self.app.processEvents()
            time.sleep(0.01)
        self.assertTrue(condition())

    def test_folder_scan_chooses_numeric_latest_and_preserves_explicit_update(self):
        from nspb_qt.model import Model
        with tempfile.TemporaryDirectory(dir=ROOT / 'frontend-qt') as folder:
            root = Path(folder)
            base = root / f'base [{BASE:016X}].nsp'
            older = root / f'patch [{BASE + 0x800:016X}][v65536].nsp'
            latest = root / f'patch [{BASE + 0x800:016X}][v131072].nsp'
            untagged = root / f'zzz patch [{BASE + 0x800:016X}].nsp'
            for path in (base, older, latest, untagged):
                path.write_bytes(b'PFS0' + bytes(12))
            m = Model()
            m.scan_game_dir(folder)
            self.wait_for(lambda: m.base_path == str(base) and not m.checking_packages)
            self.assertEqual(m.update_path, str(latest))
            self.assertEqual(set(m.package_result.paths), {str(base), str(latest)})
            self.assertTrue(m.package_result.needs_staging)
            for explicit in (older, untagged):
                m.update_path = str(explicit)
                m.scan_game_dir(folder)
                self.wait_for(lambda: m.package_inputs == m.selected_packages() and not m.checking_packages)
                self.assertEqual(m.update_path, str(explicit))
                self.assertEqual(set(m.package_result.paths), {str(base), str(explicit)})

    def test_folder_scan_does_not_guess_between_versionless_updates(self):
        from nspb_qt.model import Model
        with tempfile.TemporaryDirectory(dir=ROOT / 'frontend-qt') as folder:
            root = Path(folder)
            base = root / f'base [{BASE:016X}].nsp'
            updates = [root / f'{name} [{BASE + 0x800:016X}].nsp' for name in ('patch', 'other patch')]
            for path in [base] + updates:
                path.write_bytes(b'PFS0' + bytes(12))
            m = Model()
            m.scan_game_dir(folder)
            self.wait_for(lambda: m.base_path == str(base) and not m.checking_packages)
            self.assertEqual(m.update_path, '')
            # With no explicit selection the backend can apply its profile-aware version policy.
            self.assertEqual(set(m.package_result.paths), {str(p) for p in [base] + updates})
            updates[1].unlink()
            m.scan_game_dir(folder)
            self.wait_for(lambda: m.update_path == str(updates[0]) and not m.checking_packages)
            self.assertEqual(m.update_path, str(updates[0]))

    def test_build_gate_and_stale_results(self):
        from nspb_qt.model import Model, Dep
        with tempfile.TemporaryDirectory(dir=ROOT / 'frontend-qt') as folder:
            path = Path(folder) / f'game [{BASE:016X}].nsp'
            path.write_bytes(b'PFS0' + bytes(12))
            m = Model()
            m.base_path, m.keys_path = str(path), 'unused.keys'
            m.deps_checked = True
            m.deps = [Dep('fixture', '', '')]
            from nspb_qt.model import DepState
            m.deps[0].state = DepState.OK
            self.assertFalse(m.can_build)
            m.check_packages()
            self.wait_for(lambda: not m.checking_packages)
            self.assertTrue(m.package_result.ready)
            self.assertTrue(m.can_build)
            old_inputs, old_result = m.package_inputs, m.package_result
            m.base_path = str(path.with_name('missing.nsp'))
            self.assertFalse(m.can_build)
            m._receive_packages(m._package_generation, old_inputs, old_result)
            self.assertNotEqual(m.package_inputs, m.selected_packages())
            m.check_packages()
            self.wait_for(lambda: not m.checking_packages)
            self.assertFalse(m.can_build)

    def test_start_rechecks_deleted_file_and_never_spawns_build(self):
        from nspb_qt.model import Model
        with tempfile.TemporaryDirectory(dir=ROOT / 'frontend-qt') as folder:
            path = Path(folder) / f'game [{BASE:016X}].nsp'
            path.write_bytes(b'PFS0' + bytes(12))
            m = Model()
            m.base_path = str(path)
            m.check_packages()
            self.wait_for(lambda: not m.checking_packages)
            path.unlink()
            with patch.object(m, '_start_checked_build') as start:
                m.start_build()
                self.wait_for(lambda: not m.checking_packages)
                start.assert_not_called()
            self.assertIn('missing', m.package_result.packages[0].reason)

    def test_build_staging_contains_only_vetted_game_family(self):
        from nspb_qt.model import Model
        with tempfile.TemporaryDirectory(dir=ROOT / 'frontend-qt') as folder:
            path = Path(folder) / f'game [{BASE:016X}].nsp'
            foreign = Path(folder) / f'other [{BASE + 0x100000:016X}].nsp'
            for p in (path, foreign):
                p.write_bytes(b'PFS0' + bytes(12))
            m = Model()
            m.base_path = str(path)
            with patch.object(m, '_start_checked_build') as start:
                m.start_build()
                self.wait_for(lambda: start.called)
                result, staged = start.call_args.args
                self.assertEqual(result.paths, [str(path)])
                self.assertEqual([p.name for p in Path(staged).iterdir()], [path.name])
                self.assertEqual(inspect(str(Path(staged) / path.name)).title, BASE)
                import shutil
                shutil.rmtree(staged)

    def test_latest_forced_same_path_check_wins(self):
        from nspb_qt.model import Model
        from nspb_qt.package_check import Result
        m = Model()
        m.base_path = 'same.nsp'
        old_started, release_old, old_finished = (threading.Event() for _ in range(3))
        old, latest = Result(), Result(title=BASE, ready=True)
        calls = 0

        def delayed_check(_):
            nonlocal calls
            calls += 1
            if calls == 1:
                old_started.set()
                release_old.wait(5)
                old_finished.set()
                return old
            return latest

        with patch('nspb_qt.model.package_check.check', side_effect=delayed_check):
            m.check_packages()
            old_generation = m._package_generation
            delivered = []
            m._packageDone.connect(lambda generation, *_: delivered.append(generation))
            self.assertTrue(old_started.wait(5))
            m.check_packages(force=True)
            self.wait_for(lambda: m.package_result is latest)
            release_old.set()
            self.assertTrue(old_finished.wait(5))
            self.wait_for(lambda: old_generation in delivered)
            self.assertIs(m.package_result, latest)
            self.assertFalse(m.checking_packages)

    def test_superseded_build_does_not_overwrite_or_leave_latest_check_busy(self):
        from nspb_qt.model import Model
        from nspb_qt.package_check import Result
        for complete_build_first in (True, False):
            with self.subTest(complete_build_first=complete_build_first):
                m = Model()
                m.base_path = 'same.nsp'
                failures = []
                m.finished.connect(lambda *args: failures.append(args))
                old_started, new_started, release_old, release_new = (threading.Event() for _ in range(4))
                latest = Result(title=BASE)
                calls = 0

                def delayed_check(_):
                    nonlocal calls
                    calls += 1
                    if calls == 1:
                        old_started.set()
                        release_old.wait(5)
                        return Result()
                    new_started.set()
                    release_new.wait(5)
                    return latest

                with patch('nspb_qt.model.package_check.check', side_effect=delayed_check), \
                     patch.object(m, '_start_checked_build') as start:
                    m.start_build()
                    self.assertTrue(old_started.wait(5))
                    m.check_packages(force=True)
                    self.assertTrue(new_started.wait(5))
                    if complete_build_first:
                        release_old.set()
                        self.wait_for(lambda: not m._preparing_build)
                        self.assertTrue(m.checking_packages)
                        release_new.set()
                    else:
                        release_new.set()
                        self.wait_for(lambda: m.package_result is latest)
                        release_old.set()
                    self.wait_for(lambda: not m._preparing_build and not m.checking_packages)
                    self.assertIs(m.package_result, latest)
                    start.assert_not_called()
                    self.assertEqual(failures, [])

    def test_staging_uses_writable_output_and_copies_across_devices(self):
        from nspb_qt.model import Model
        import errno
        import shutil
        with tempfile.TemporaryDirectory(dir=ROOT / 'frontend-qt') as folder:
            root = Path(folder)
            source, output = root / 'library', root / 'output'
            source.mkdir()
            output.mkdir()
            base = source / f'base [{BASE:016X}].nsp'
            foreign = source / f'foreign [{BASE + 0x100000:016X}].nsp'
            for path in (base, foreign):
                path.write_bytes(b'PFS0' + bytes(12))
            source.chmod(0o555)
            m = Model()
            m.base_path, m.out_dir = str(base), str(output)
            try:
                with patch.object(m, '_start_checked_build') as start, \
                     patch('nspb_qt.model.os.link', side_effect=OSError(errno.EXDEV, 'cross-device link')), \
                     patch('nspb_qt.model.shutil.copy2', wraps=shutil.copy2) as copy:
                    m.start_build()
                    self.wait_for(lambda: start.called)
                    result, staged = start.call_args.args
                    self.assertEqual(Path(staged).parent, output)
                    self.assertEqual(result.paths, [str(base)])
                    self.assertEqual((Path(staged) / base.name).read_bytes(), base.read_bytes())
                    copy.assert_called_once()
                    shutil.rmtree(staged)
            finally:
                source.chmod(0o755)

    def test_partial_staging_failure_is_cleaned(self):
        from nspb_qt.model import Model
        with tempfile.TemporaryDirectory(dir=ROOT / 'frontend-qt') as folder:
            root = Path(folder)
            output = root / 'output'
            output.mkdir()
            base = root / f'base [{BASE:016X}].nsp'
            foreign = root / f'foreign [{BASE + 0x100000:016X}].nsp'
            for path in (base, foreign):
                path.write_bytes(b'PFS0' + bytes(12))
            m = Model()
            m.base_path, m.out_dir = str(base), str(output)
            with patch.object(m, '_start_checked_build') as start, \
                 patch('nspb_qt.model.os.link', side_effect=OSError('link denied')), \
                 patch('nspb_qt.model.shutil.copy2', side_effect=OSError('copy denied')):
                m.start_build()
                self.wait_for(lambda: not m.checking_packages)
                start.assert_not_called()
            self.assertEqual(list(output.iterdir()), [])

    def test_reselecting_a_repaired_file_rechecks_same_path(self):
        from nspb_qt.model import Model
        with tempfile.TemporaryDirectory(dir=ROOT / 'frontend-qt') as folder:
            path = Path(folder) / f'game [{BASE:016X}].nsp'
            path.write_bytes(b'incomplete')
            m = Model()
            m.base_path = str(path)
            m.check_packages()
            self.wait_for(lambda: not m.checking_packages)
            self.assertFalse(m.package_result.ready)
            path.write_bytes(b'PFS0' + bytes(12))
            m.check_packages(force=True)
            self.wait_for(lambda: not m.checking_packages)
            self.assertTrue(m.package_result.ready)

    def test_recovery_details_and_clipboard_are_visible_and_safe(self):
        from nspb_qt.model import Model
        from nspb_qt.ui import MainWindow
        from PySide6.QtWidgets import QPushButton
        with tempfile.TemporaryDirectory(dir=ROOT / 'frontend-qt') as folder:
            path = Path(folder) / 'unidentified.nsp'
            path.write_bytes(b'PFS0' + bytes(12))
            m = Model()
            m.base_path = str(path)
            with patch.object(m, 'check_deps'):
                w = MainWindow(m)
            self.wait_for(lambda: not m.checking_packages)
            self.assertIn('No recognized ticket name', w.package_status.text())
            self.assertIn('This is not a keys check', w.package_details.toPlainText())
            self.assertFalse(w.build_btn.isEnabled())
            self.assertNotIn(str(path), m.package_result.diagnostics)
            copy = next(b for b in w.findChildren(QPushButton) if b.text() == m.t('diag.copy'))
            copy.click()
            self.assertEqual(self.app.clipboard().text(), m.package_result.diagnostics)
            w.close()

    def test_recovery_replaces_the_failed_dlc_instead_of_keeping_it(self):
        from nspb_qt.model import Model
        from nspb_qt.ui import MainWindow
        with tempfile.TemporaryDirectory(dir=ROOT / 'frontend-qt') as folder:
            base = Path(folder) / f'game [{BASE:016X}].nsp'
            replacement = Path(folder) / f'addon [{BASE + 0x1001:016X}].nsp'
            bad = Path(folder) / 'bad.nsp'
            for path in (base, replacement):
                path.write_bytes(b'PFS0' + bytes(12))
            bad.write_bytes(b'incomplete')
            m = Model()
            m.base_path, m.dlc_paths = str(base), [str(bad)]
            with patch.object(m, 'check_deps'):
                w = MainWindow(m)
            self.wait_for(lambda: not m.checking_packages)
            with patch('nspb_qt.ui.QFileDialog.getOpenFileName', return_value=(str(replacement), '')):
                w._choose_failed_input()
            self.wait_for(lambda: not m.checking_packages)
            self.assertEqual(m.dlc_paths, [str(replacement)])
            self.assertTrue(m.package_result.ready)
            w.close()


if __name__ == '__main__':
    unittest.main()
