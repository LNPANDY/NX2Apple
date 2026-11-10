"""A shared-app build must never lose a game that was registered before.

Three defects could each wipe games out of the shared shell_app:
`ShellLibrary.drop_missing()` deleted the record of a game whose framework was not on disk,
`leave_out_incomplete()` did the same and even deleted the mirrored framework, and
`Model.move_shell_cache()` removed the old cache folder right after copying, so the frameworks
that lived only there were gone for good. `export_shell()` then wrote an IPA that held fewer
games over the previous, complete one without a word.

These tests are pure Python: a framework is a directory with a `game.manifest.json` and a
`framework_executable`, so the whole export path runs on temporary folders without PySide6,
without an engine and without a game.
"""
from __future__ import annotations

import json
import os
import shutil
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
QT = HERE.parent
ROOT = QT.parent
sys.path.insert(0, str(QT))

from nspb_qt.win import shell_export as se  # noqa: E402


def make_framework(root: Path, title_id: str, name: str, *, loader: str = 'FH',
                   exe: bool = True, chain: str = 'b-000000000000') -> Path:
    """A framework the exporter accepts: a manifest with loader FH and its executable."""
    fw = Path(root) / f'DmGame{title_id}.framework'
    fw.mkdir(parents=True, exist_ok=True)
    (fw / 'msl').mkdir(exist_ok=True)
    (fw / 'msl' / f'{chain}.img').write_bytes(b'msl' + b'\0' * 64)
    (fw / 'game.manifest.json').write_text(json.dumps({
        'schema': 1,
        'title_id': title_id,
        'name': name,
        'modules': ['main'],
        'chain': chain,
        'loader': loader,
        'framework': f'DmGame{title_id}.framework',
        'framework_executable': f'DmGame{title_id}',
        'image_marker': 'dmgame_image_marker',
        'min_os': '26.0',
    }), encoding='utf-8')
    if exe:
        (fw / f'DmGame{title_id}').write_bytes(b'\xcf\xfa\xed\xfe' + b'\0' * 60)
    return fw


def make_shell_app(root: Path, bundle_id: str = 'org.nxnative.shell') -> Path:
    """The smallest DmShell.app the exporter will copy: the binary and its Info.plist."""
    app = Path(root) / 'DmShell.app'
    app.mkdir(parents=True, exist_ok=True)
    (app / 'DmShell').write_bytes(b'\xcf\xfa\xed\xfe' + b'\0' * 60)
    (app / 'Info.plist').write_text(
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
        '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
        '<plist version="1.0"><dict>'
        f'<key>CFBundleIdentifier</key><string>{bundle_id}</string>'
        '<key>CFBundleExecutable</key><string>DmShell</string>'
        '</dict></plist>\n', encoding='utf-8')
    (app / 'dm' / 'font').mkdir(parents=True, exist_ok=True)
    (app / 'dm' / 'font' / 'standard.ttf').write_bytes(b'ttf')
    (app / 'dm' / 'font' / 'nintendo_ext.ttf').write_bytes(b'ttf')
    return app


def library_with(temp: Path, title_ids: list[str]) -> se.ShellLibrary:
    lib_ = se.ShellLibrary()
    for i, tid in enumerate(title_ids):
        lib_.games.append(se.ShellGame(title_id=tid, name=f'Game {i + 1}', framework=''))
    return lib_


class DropMissingTest(unittest.TestCase):
    """A framework that is not on disk right now is a reason to leave it out, never to forget it."""

    def test_a_missing_framework_stays_registered(self):
        with tempfile.TemporaryDirectory() as d:
            temp = Path(d)
            lib_ = library_with(temp, ['0100000000000001', '0100000000000002'])
            lib_.games[0].framework = str(make_framework(temp, '0100000000000001', 'One'))
            lib_.games[1].framework = str(temp / 'DmGame0100000000000002.framework')

            gone = lib_.drop_missing()

            self.assertEqual([g.title_id for g in gone], ['0100000000000002'])
            self.assertEqual([g.title_id for g in lib_.games],
                             ['0100000000000001', '0100000000000002'])

    def test_drop_missing_says_why_it_left_the_game_out(self):
        seen: list[str] = []
        with tempfile.TemporaryDirectory() as d:
            temp = Path(d)
            lib_ = library_with(temp, ['0100000000000001'])
            lib_.games[0].framework = str(temp / 'DmGame0100000000000001.framework')
            lib_.drop_missing(log=seen.append)
        self.assertTrue(seen)
        self.assertIn('0100000000000001', seen[-1])
        self.assertIn('stays registered', seen[-1])


class LeaveOutIncompleteTest(unittest.TestCase):
    """An incomplete framework is left out of this export, not deleted and not deregistered."""

    def test_an_incomplete_framework_is_not_deleted(self):
        with tempfile.TemporaryDirectory() as d:
            temp = Path(d)
            root = temp / 'shell'
            root.mkdir()
            fw = make_framework(root / 'frameworks', '0100000000000002', 'Two', exe=False)
            good = make_framework(root / 'frameworks', '0100000000000001', 'One')
            lib_ = se.ShellLibrary()
            lib_.games.append(se.ShellGame('0100000000000001', 'One', str(good)))
            lib_.games.append(se.ShellGame('0100000000000002', 'Two', str(fw)))

            left_out, err = se.leave_out_incomplete(
                lib_, root, '0100000000000001', 'One', lambda k, *a: k, lambda _: None)

            self.assertIsNone(err)
            self.assertEqual([g.title_id for g in left_out], ['0100000000000002'])
            self.assertTrue(fw.is_dir(), 'the framework was deleted')
            self.assertEqual([g.title_id for g in lib_.games],
                             ['0100000000000001', '0100000000000002'])

    def test_the_game_being_built_must_be_complete(self):
        with tempfile.TemporaryDirectory() as d:
            temp = Path(d)
            root = temp / 'shell'
            root.mkdir()
            fw = make_framework(root / 'frameworks', '0100000000000001', 'One', exe=False)
            lib_ = se.ShellLibrary()
            lib_.games.append(se.ShellGame('0100000000000001', 'One', str(fw)))
            _, err = se.leave_out_incomplete(
                lib_, root, '0100000000000001', 'One', lambda k, *a: k, lambda _: None)
        self.assertIsNotNone(err)


class SaveKeepsDroppedTest(unittest.TestCase):
    """Replacing shell.json keeps a copy of the entries it would forget."""

    def test_forgotten_entries_are_kept_in_a_backup(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            original = se.ShellLibrary()
            original.games.append(se.ShellGame('0100000000000001', 'One', ''))
            original.games.append(se.ShellGame('0100000000000002', 'Two', ''))
            original.save(root)

            smaller = se.ShellLibrary()
            smaller.games.append(se.ShellGame('0100000000000001', 'One', ''))
            smaller.save(root)

            backup = root / 'shell.json.bak'
            self.assertTrue(backup.is_file(), 'no backup of the dropped entry')
            kept = json.loads(backup.read_text(encoding='utf-8'))
            self.assertEqual([g['titleID'] for g in kept['games']],
                             ['0100000000000002'])

    def test_a_save_that_drops_nothing_writes_no_backup(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            lib_ = se.ShellLibrary()
            lib_.games.append(se.ShellGame('0100000000000001', 'One', ''))
            lib_.save(root)
            lib_.save(root)
            self.assertFalse((root / 'shell.json.bak').exists())


class AdoptMirrorsTest(unittest.TestCase):
    """A cache folder that already holds frameworks is a cache, whatever shell.json says."""

    def test_unregistered_frameworks_in_the_cache_are_adopted(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            make_framework(root / 'frameworks', '0100000000000002', 'Two')
            lib_ = se.ShellLibrary.load(root)
        self.assertEqual([g.title_id for g in lib_.games], ['0100000000000002'])
        self.assertEqual(lib_.games[0].name, 'Two')

    def test_an_incomplete_framework_is_not_adopted(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            make_framework(root / 'frameworks', '0100000000000002', 'Two', exe=False)
            lib_ = se.ShellLibrary.load(root)
        self.assertEqual(lib_.games, [])


class FindFrameworkCopyTest(unittest.TestCase):
    """Recovery looks in the places a cache folder can end up, and nowhere else."""

    def test_it_finds_a_framework_beside_the_cache(self):
        with tempfile.TemporaryDirectory() as d:
            temp = Path(d)
            want = make_framework(temp / 'backup', '0100000000000002', 'Two')
            found = se.find_framework_copy('0100000000000002', [temp / 'backup'])
            self.assertIsNotNone(found)
            self.assertEqual(found.resolve(), want.resolve())

    def test_it_finds_a_framework_in_an_frameworks_subfolder(self):
        with tempfile.TemporaryDirectory() as d:
            temp = Path(d)
            make_framework(temp / 'backup' / 'frameworks', '0100000000000002', 'Two')
            self.assertIsNotNone(se.find_framework_copy('0100000000000002', [temp / 'backup']))

    def test_it_ignores_an_incomplete_copy(self):
        with tempfile.TemporaryDirectory() as d:
            temp = Path(d)
            make_framework(temp / 'backup', '0100000000000002', 'Two', exe=False)
            self.assertIsNone(se.find_framework_copy('0100000000000002', [temp / 'backup']))

    def test_it_does_not_take_another_game_for_this_one(self):
        with tempfile.TemporaryDirectory() as d:
            temp = Path(d)
            make_framework(temp / 'backup', '0100000000000003', 'Three')
            self.assertIsNone(se.find_framework_copy('0100000000000002', [temp / 'backup']))


class RecoverFrameworksTest(unittest.TestCase):
    """Recovery puts the framework back into the cache instead of asking for a rebuild."""

    def test_a_framework_found_on_disk_is_put_back(self):
        seen: list[str] = []
        with tempfile.TemporaryDirectory() as d:
            temp = Path(d)
            root = temp / 'shell'
            (root / 'frameworks').mkdir(parents=True)
            good = make_framework(root / 'frameworks', '0100000000000001', 'One')
            make_framework(temp / 'backup', '0100000000000002', 'Two')
            lib_ = se.ShellLibrary()
            lib_.games.append(se.ShellGame('0100000000000001', 'One', str(good)))
            lib_.games.append(se.ShellGame('0100000000000002', 'Two',
                                           str(root / 'frameworks' / 'DmGame0100000000000002.framework')))

            recovered, still = se.recover_frameworks(lib_, root, [temp / 'backup'], seen.append)

            self.assertEqual(recovered, ['0100000000000002 (Two)'])
            self.assertEqual(still, [])
            mirror = root / 'frameworks' / 'DmGame0100000000000002.framework'
            self.assertTrue(mirror.is_dir())
            self.assertEqual(Path(lib_.games[1].framework).resolve(), mirror.resolve())
            self.assertTrue(any('put back' in line for line in seen))

    def test_it_reports_the_games_it_could_not_find(self):
        with tempfile.TemporaryDirectory() as d:
            temp = Path(d)
            root = temp / 'shell'
            (root / 'frameworks').mkdir(parents=True)
            good = make_framework(root / 'frameworks', '0100000000000001', 'One')
            lib_ = se.ShellLibrary()
            lib_.games.append(se.ShellGame('0100000000000001', 'One', str(good)))
            lib_.games.append(se.ShellGame('0100000000000002', 'Two',
                                           str(root / 'frameworks' / 'DmGame0100000000000002.framework')))
            recovered, still = se.recover_frameworks(lib_, root, [], lambda _: None)
        self.assertEqual(recovered, [])
        self.assertEqual([g.title_id for g in still], ['0100000000000002'])


class CheckIpaHasGamesTest(unittest.TestCase):
    """The last gate: an IPA missing a registered game never replaces the one on disk."""

    def _ipa(self, path: Path, title_ids: list[str]) -> Path:
        with zipfile.ZipFile(path, 'w') as zf:
            zf.writestr(f'Payload/{se.APP_NAME}/{se.SCHEME}', b'binary')
            for tid in title_ids:
                zf.writestr(
                    f'Payload/{se.APP_NAME}/Frameworks/DmGame{tid}.framework/DmGame{tid}', b'x')
        return path

    def test_a_complete_ipa_passes(self):
        with tempfile.TemporaryDirectory() as d:
            ipa = self._ipa(Path(d) / 'a.ipa', ['0100000000000001', '0100000000000002'])
            self.assertEqual(sorted(se.frameworks_in_ipa(ipa)),
                             ['DmGame0100000000000001.framework',
                              'DmGame0100000000000002.framework'])
            se.check_ipa_has_games(ipa, ['0100000000000001', '0100000000000002'])

    def test_an_ipa_missing_a_game_raises(self):
        with tempfile.TemporaryDirectory() as d:
            ipa = self._ipa(Path(d) / 'a.ipa', ['0100000000000001'])
            with self.assertRaises(RuntimeError) as raised:
                se.check_ipa_has_games(ipa, ['0100000000000001', '0100000000000002'])
        self.assertIn('DmGame0100000000000002.framework', str(raised.exception))
        self.assertIn('old IPA was kept', str(raised.exception))


class ExportShellRefusesTest(unittest.TestCase):
    """The whole export: a registered game that cannot be packed stops the run and the old IPA stays."""

    def test_a_missing_game_stops_the_export_and_keeps_the_old_ipa(self):
        with tempfile.TemporaryDirectory() as d:
            temp = Path(d)
            root = temp / 'shell'
            (root / 'export').mkdir(parents=True)
            tpl = make_shell_app(temp / 'template')
            old_ipa = se.ipa_path(root)
            old_ipa.write_bytes(b'OLD IPA')

            lib_ = se.ShellLibrary()
            lib_.games.append(se.ShellGame('0100000000000001', 'One', ''))
            # A registered game whose framework is gone: the record has to survive the export, so
            # the path is real text on disk while the folder itself no longer exists.
            lib_.games.append(se.ShellGame('0100000000000002', 'Two',
                                           str(temp / 'gone' / 'DmGame0100000000000002.framework')))
            lib_.save(root)

            fresh = make_framework(temp / 'build', '0100000000000001', 'One')
            env = {'NSPB_SHELL_TEMPLATE': str(tpl)}
            previous = {k: os.environ.get(k) for k in env}
            os.environ.update(env)
            try:
                ok, out, msg, _notes = se.export_shell(
                    root=root, repo=temp, framework=fresh, title_id='0100000000000001',
                    name='One', python_exe=sys.executable)
            finally:
                for k, v in previous.items():
                    if v is None:
                        os.environ.pop(k, None)
                    else:
                        os.environ[k] = v

            self.assertFalse(ok)
            self.assertEqual(out, '')
            self.assertIn('0100000000000002', msg)
            self.assertEqual(old_ipa.read_bytes(), b'OLD IPA', 'the complete IPA was replaced')
            after = se.ShellLibrary.load(root)
            self.assertEqual(sorted(g.title_id for g in after.games),
                             ['0100000000000001', '0100000000000002'])


class MoveShellCacheTest(unittest.TestCase):
    """`Model.move_shell_cache` copies, merges the two registries and leaves the old folder alone."""

    def test_the_old_folder_is_kept_and_its_games_are_carried_over(self):
        """The merge is what `move_shell_cache` calls; the move itself needs PySide6, the merge does not."""
        with tempfile.TemporaryDirectory() as d:
            temp = Path(d)
            old = temp / 'old'
            new = temp / 'new'
            (old / 'frameworks').mkdir(parents=True)
            (new / 'frameworks').mkdir(parents=True)
            make_framework(old / 'frameworks', '0100000000000001', 'One')
            make_framework(old / 'frameworks', '0100000000000002', 'Two')
            make_framework(new / 'frameworks', '0100000000000003', 'Three')

            src = se.ShellLibrary()
            src.games.append(se.ShellGame('0100000000000001', 'One',
                                          str(old / 'frameworks' / 'DmGame0100000000000001.framework')))
            src.games.append(se.ShellGame('0100000000000002', 'Two',
                                          str(old / 'frameworks' / 'DmGame0100000000000002.framework')))
            src.save(old)
            dst = se.ShellLibrary()
            dst.games.append(se.ShellGame('0100000000000003', 'Three',
                                          str(new / 'frameworks' / 'DmGame0100000000000003.framework')))
            dst.save(new)

            try:
                from nspb_qt import model
            except Exception as e:  # PySide6 is not installed everywhere the tests run
                raise unittest.SkipTest(f'the model needs PySide6: {e}')

            # `move_shell_cache` copies the folder first and merges afterwards; the frameworks of
            # the old games have to be on disk in `new` before the merge can point at them.
            shutil.copytree(old / 'frameworks', new / 'frameworks', dirs_exist_ok=True)
            carried = model.Model._merge_shell_registries(new, old)

            self.assertEqual(carried, ['0100000000000001 (One)', '0100000000000002 (Two)'])
            merged = se.ShellLibrary.load(new)
            self.assertEqual(sorted(g.title_id for g in merged.games),
                             ['0100000000000001', '0100000000000002', '0100000000000003'])
            for g in merged.games:
                self.assertEqual(Path(g.framework).parent.parent.resolve(), new.resolve())

    def test_frameworks_only_in_the_new_cache_are_adopted(self):
        """`shell.json` of the new folder can be behind the frameworks the copy brought along."""
        with tempfile.TemporaryDirectory() as d:
            temp = Path(d)
            old = temp / 'old'
            new = temp / 'new'
            (old / 'frameworks').mkdir(parents=True)
            (new / 'frameworks').mkdir(parents=True)
            se.ShellLibrary().save(old)
            make_framework(new / 'frameworks', '0100000000000004', 'Four')
            se.ShellLibrary().save(new)

            try:
                from nspb_qt import model
            except Exception as e:
                raise unittest.SkipTest(f'the model needs PySide6: {e}')

            carried = model.Model._merge_shell_registries(new, old)

            self.assertEqual(carried, ['0100000000000004 (Four)'])
            merged = se.ShellLibrary.load(new)
            self.assertEqual([g.title_id for g in merged.games], ['0100000000000004'])


if __name__ == '__main__':
    unittest.main()
