"""A Switch 2 game as a folder of its files or one NUP file builds with no prod.keys (LNPANDY/NX2Apple#512, #445).
The same cases as the Mac launcher's GameFolder tests. Synthetic folders and NUP bytes, no game data.

The model tests need PySide6 and are skipped without it."""
from __future__ import annotations

import os
import struct
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'frontend-qt'))
os.environ.setdefault('QT_QPA_PLATFORM', 'offscreen')

from nspb_qt import inputs   # noqa: E402

try:
    from nspb_qt import model as model_mod   # noqa: E402
    from nspb_qt.i18n import Lang   # noqa: E402
except ImportError:          # no PySide6
    model_mod = None

TID = 0x0400000000A00000


def npdm(program_id: int) -> bytes:
    """A minimal main.npdm: META header, the ACI0 section at 0x80 with the program ID at +0x10."""
    d = bytearray(0x100)
    d[:4] = b'META'
    struct.pack_into('<II', d, 0x70, 0x80, 0x40)
    d[0x80:0x84] = b'ACI0'
    struct.pack_into('<Q', d, 0x90, program_id)
    return bytes(d)


def nup(packages: list[tuple[int, int, int]], size_delta: int = 0, magic: bytes = b'NUP\x01') -> bytes:
    """A NUP: header, then the table of contents at 0x80 with one 0x40 entry per (title ID, version, kind)."""
    toc = 0x80
    total = toc + 0x30 + 0x40 * len(packages)
    d = bytearray(total)
    d[:4] = magic
    struct.pack_into('<Q', d, 0x08, toc)
    struct.pack_into('<Q', d, 0x40, total + size_delta)
    struct.pack_into('<I', d, 0x48, len(packages))
    d[toc:toc + 4] = b'TOC\x01'
    for i, (tid, version, kind) in enumerate(packages):
        o = toc + 0x30 + i * 0x40
        struct.pack_into('<Q', d, o, tid)
        struct.pack_into('<I', d, o + 20, version)
        d[o + 24] = kind
    return bytes(d)


class FolderTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self._tmp.name) / 'game'
        self.dir.mkdir()

    def tearDown(self):
        self._tmp.cleanup()

    def make(self, rel: str, data: bytes = b'x') -> Path:
        p = self.dir / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(data)
        return p

    def game(self, tid: int = TID):
        self.make('base/exefs/main.npdm', npdm(tid))
        (self.dir / 'base/romfs').mkdir(parents=True, exist_ok=True)

    def scan(self):
        return inputs.scan_game_folder(str(self.dir))

    def problem(self, kind: str, args: tuple = ()):
        r = self.scan()
        self.assertEqual(r, inputs.GameFolderProblem(kind, args))

    # ---- detection

    def test_candidates(self):
        self.assertFalse(inputs.is_game_folder_candidate(str(self.dir)))
        self.make('exefs/main.npdm')
        self.assertTrue(inputs.is_game_folder_candidate(str(self.dir)))   # one level too high
        (self.dir / 'base').mkdir()
        self.assertFalse(inputs.is_game_folder_candidate(str(self.dir)))

    def test_candidate_base_and_nup(self):
        self.game()
        self.assertTrue(inputs.is_game_folder_candidate(str(self.dir)))
        other = self.dir.parent / 'other'
        other.mkdir()
        (other / 'g.NUP').write_bytes(b'')
        self.assertTrue(inputs.is_game_folder_candidate(str(other)))
        self.assertTrue(inputs.is_game_folder_candidate(str(other / 'g.NUP')))
        (other / '._g.nup').write_bytes(b'')
        self.assertEqual(inputs.nup_files(str(other)), ['g.NUP'])

    # ---- a folder of files

    def test_contents(self):
        self.game()
        (self.dir / 'updates/458752/romfs').mkdir(parents=True)
        (self.dir / 'updates/65536/romfs').mkdir(parents=True)
        (self.dir / 'updates/notes').mkdir(parents=True)
        (self.dir / f'dlc/{TID + 0x1001:016x}/0/romfs').mkdir(parents=True)
        (self.dir / f'dlc/{TID + 0x1002:016X}/romfs').mkdir(parents=True)
        r = self.scan()
        self.assertIsInstance(r, inputs.GameFolderContents)
        self.assertEqual(r.title_id, TID)
        self.assertEqual(r.title_id_hex, '0400000000A00000')
        self.assertEqual([v for v, _ in r.updates], [65536, 458752])
        self.assertEqual(r.newest_update[0], 458752)
        self.assertEqual([t for t, _ in r.dlc], [TID + 0x1001, TID + 0x1002])
        self.assertIsNone(r.nup)
        self.assertEqual(r.script_input, str(self.dir))
        self.assertEqual(r.base_path, str(self.dir / 'base'))

    def test_base_without_romfs_but_update_has_one(self):
        self.make('base/exefs/main.npdm', npdm(TID))
        self.problem('missing', ('base/romfs',))
        (self.dir / 'updates/1/romfs').mkdir(parents=True)
        self.assertIsInstance(self.scan(), inputs.GameFolderContents)

    def test_problems(self):
        self.problem('missing', ('base/exefs/main.npdm',))
        self.make('exefs/main.npdm')
        self.problem('noBaseFolder')

    def test_unreadable_npdm(self):
        self.make('base/exefs/main.npdm', b'not an npdm')
        (self.dir / 'base/romfs').mkdir()
        self.problem('unreadableNPDM')
        self.make('base/exefs/main.npdm', npdm(TID)[:0x84])   # ACI0 cut short
        self.problem('unreadableNPDM')

    def test_not_base_title(self):
        self.game(TID + 0x800)
        self.problem('notBaseTitle', ('0400000000A00800',))

    def test_package_beside(self):
        self.game()
        self.make('game.NSZ')
        self.problem('packageBeside', ('game.NSZ',))
        os.remove(self.dir / 'game.NSZ')
        self.make('._x.nsp')
        self.assertIsInstance(self.scan(), inputs.GameFolderContents)

    def test_dlc_problems(self):
        self.game()
        (self.dir / 'dlc/bonus/romfs').mkdir(parents=True)
        self.problem('dlcName', ('bonus',))
        os.rename(self.dir / 'dlc/bonus', self.dir / f'dlc/{TID + 0x5000:016X}')
        self.problem('notDLC', (f'{TID + 0x5000:016X}',))
        os.rename(self.dir / f'dlc/{TID + 0x5000:016X}', self.dir / f'dlc/{TID + 0x1001:016X}')
        self.assertIsInstance(self.scan(), inputs.GameFolderContents)
        (self.dir / f'dlc/{TID + 0x1001:016X}/romfs').rmdir()
        self.problem('dlcRomFS', (f'{TID + 0x1001:016X}', 0))
        (self.dir / f'dlc/{TID + 0x1001:016X}/1/romfs').mkdir(parents=True)
        (self.dir / f'dlc/{TID + 0x1001:016X}/2/romfs').mkdir(parents=True)
        self.problem('dlcRomFS', (f'{TID + 0x1001:016X}', 2))

    def test_problem_keys_exist_in_the_shared_strings(self):
        from nspb_qt import l10n
        for kind in ('missing', 'noBaseFolder', 'unreadableNPDM', 'notBaseTitle', 'packageBeside', 'dlcName', 'notDLC',
                     'dlcRomFS', 'notNUP', 'nupPartial', 'severalNUPs'):
            self.assertIn(inputs.GameFolderProblem(kind).l10n_key, l10n.CATALOGS['en'])

    def test_program_id(self):
        self.assertEqual(inputs.program_id(npdm(TID)), TID)
        self.assertIsNone(inputs.program_id(b'META'))
        self.assertIsNone(inputs.program_id(b'XXXX' + npdm(TID)[4:]))

    # ---- a NUP

    def test_nup_base_updates_dlc(self):
        p = self.make('Game.nup', nup([(TID, 0, 0), (TID + 0x800, 65536, 1), (TID + 0x800, 458752, 1),
                                        (TID + 0x1002, 0, 2), (TID + 0x1001, 0, 2)]))
        for r in (inputs.scan_game_folder(str(p)), self.scan()):   # the file, and the folder that holds it
            self.assertIsInstance(r, inputs.GameFolderContents)
            self.assertEqual(r.title_id, TID)
            self.assertEqual(r.nup, str(p))
            self.assertEqual(r.folder, str(self.dir))
            self.assertEqual([v for v, _ in r.updates], [65536, 458752])
            self.assertEqual([t for t, _ in r.dlc], [TID + 0x1001, TID + 0x1002])
            self.assertEqual(r.script_input, str(p))
            self.assertEqual(r.base_path, str(p))

    def test_nup_title_id_from_an_update_or_none(self):
        p = self.make('a.nup', nup([(TID + 0x800, 1, 1)]))
        self.assertEqual(inputs.read_nup(str(p)).title_id, TID)
        p = self.make('a.nup', nup([(TID, 0, 0), (TID + 0x800, 1, 1)]))
        self.assertEqual(inputs.read_nup(str(p)).title_id, TID)
        p = self.make('a.nup', nup([(TID + 0x1001, 0, 2)]))
        r = inputs.read_nup(str(p))
        self.assertEqual(r.title_id, 0)
        self.assertFalse(r.has_title_id)

    def test_nup_problems(self):
        self.make('a.nup', nup([(TID, 0, 0)], magic=b'NUP\x02'))
        self.problem('notNUP', ('a.nup',))
        self.make('a.nup', nup([(TID, 0, 0)], size_delta=5))
        self.problem('nupPartial', ('a.nup',))
        self.make('a.nup', b'short')
        self.problem('notNUP', ('a.nup',))
        self.make('a.nup', nup([(TID, 0, 0)])[:-8])
        self.assertIsInstance(self.scan(), inputs.GameFolderProblem)   # cut table: partial
        self.make('a.nup', nup([(TID, 0, 0)]))
        self.make('b.nup', nup([(TID, 0, 0)]))
        self.problem('severalNUPs', (2,))

    def test_nup_beside_packages_is_refused(self):
        self.make('a.nup', nup([(TID, 0, 0)]))
        self.make('g.xci')
        self.problem('packageBeside', ('g.xci',))

    def test_outer_wrapper_and_inner_subfolders_resolve_to_game_folder(self):
        nested = self.dir / 'Outer' / 'Donkey Kong Bananza'
        (nested / 'base/exefs').mkdir(parents=True)
        (nested / 'base/exefs/main.npdm').write_bytes(npdm(TID))
        (nested / 'base/romfs').mkdir(parents=True)
        (nested / 'updates/458752/romfs').mkdir(parents=True)
        (nested / f'dlc/{TID + 0x1001:016x}/0/romfs').mkdir(parents=True)

        for picked in (
            self.dir,
            self.dir / 'Outer',
            nested / 'base',
            nested / 'base/exefs',
            nested / 'base/romfs',
            nested / 'updates',
            nested / 'updates/458752',
            nested / 'updates/458752/romfs',
            nested / 'dlc',
            nested / f'dlc/{TID + 0x1001:016x}',
            nested / f'dlc/{TID + 0x1001:016x}/0/romfs',
        ):
            self.assertEqual(inputs.resolve_game_folder(str(picked)), str(nested), f'failed for {picked}')
            self.assertTrue(inputs.is_game_folder_candidate(str(picked)), f'failed for {picked}')
            r = inputs.scan_game_folder(str(picked))
            self.assertIsInstance(r, inputs.GameFolderContents)
            self.assertEqual(r.folder, str(nested))
            self.assertEqual(r.title_id, TID)
            self.assertEqual([v for v, _ in r.updates], [458752])
            self.assertEqual([t for t, _ in r.dlc], [TID + 0x1001])

        (self.dir / 'Outer' / 'Other [010015100B514000][v0].nsp').write_bytes(b'x')
        self.assertFalse(inputs.is_game_folder_candidate(str(self.dir / 'Outer')))
        (self.dir / 'Outer' / 'Other [010015100B514000][v0].nsp').unlink()
        (self.dir / 'Outer' / 'Second' / 'base/exefs').mkdir(parents=True)
        (self.dir / 'Outer' / 'Second' / 'base/exefs/main.npdm').write_bytes(npdm(TID))
        self.assertFalse(inputs.is_game_folder_candidate(str(self.dir / 'Outer')))

        # Mixed-depth collection: GameA at Collection/GameA/base (level 1) and GameB at Collection/Wrapper/GameB/base (level 2)
        from nspb_qt import library as lib
        coll = self.dir / 'Collection'
        game_a = coll / 'GameA'
        game_b = coll / 'Wrapper' / 'GameB'
        tid_b = 0x0400A3A01EE4C000
        for gdir, gtid in ((game_a, TID), (game_b, tid_b)):
            (gdir / 'base/exefs').mkdir(parents=True)
            (gdir / 'base/exefs/main.npdm').write_bytes(npdm(gtid))
            (gdir / 'base/romfs').mkdir(parents=True)
        self.assertEqual(inputs.resolve_game_folder(str(coll)), str(coll))
        self.assertFalse(inputs.is_game_folder_candidate(str(coll)))
        self.assertFalse(lib.GameFolder.is_candidate(str(coll)))
        self.assertEqual(inputs.scan_game_folder(str(coll)), inputs.GameFolderProblem('missing', ('base/exefs/main.npdm',)))
        self.assertEqual(inputs.resolve_game_folder(str(coll / 'Wrapper')), str(game_b))
        found = lib.GameLibrary.discover_in_folder(str(coll))
        by_tid = {g.title_id: g for g in found}
        self.assertEqual(set(by_tid), {f'{TID:016X}', f'{tid_b:016X}'})
        self.assertEqual(by_tid[f'{TID:016X}'].inputs['base'], [str(game_a)])
        self.assertEqual(by_tid[f'{tid_b:016X}'].inputs['base'], [str(game_b)])

        # Root-NUP-plus-nested-dump collection: Collection2/GameA.nup alongside Collection2/DumpB/base/...
        coll2_root = self.dir / 'NupCollectionRoot'
        coll2 = coll2_root / 'Collection'
        nup_a = coll2 / 'GameA.nup'
        dump_b = coll2 / 'DumpB'
        (dump_b / 'base/exefs').mkdir(parents=True)
        (dump_b / 'base/exefs/main.npdm').write_bytes(npdm(tid_b))
        (dump_b / 'base/romfs').mkdir(parents=True)
        nup_a.write_bytes(nup([(TID, 0, 0)]))
        for scan_root in (coll2, coll2_root):
            self.assertEqual(inputs.resolve_game_folder(str(scan_root)), str(scan_root), f'failed for {scan_root}')
            self.assertFalse(inputs.is_game_folder_candidate(str(scan_root)), f'failed for {scan_root}')
            self.assertFalse(lib.GameFolder.is_candidate(str(scan_root)), f'failed for {scan_root}')
            found2 = lib.GameLibrary.discover_in_folder(str(scan_root))
            by_tid2 = {g.title_id: g for g in found2}
            self.assertEqual(set(by_tid2), {f'{TID:016X}', f'{tid_b:016X}'}, f'failed for {scan_root}')
            self.assertEqual(by_tid2[f'{TID:016X}'].inputs['base'], [str(nup_a)])
            self.assertEqual(by_tid2[f'{tid_b:016X}'].inputs['base'], [str(dump_b)])
        self.assertEqual(inputs.resolve_game_folder(str(dump_b)), str(dump_b))
        self.assertTrue(inputs.is_game_folder_candidate(str(dump_b)))

    def test_update_only_dump_without_base_folder(self):
        self.make('updates/131072/exefs/main.npdm', npdm(TID))
        self.assertTrue(inputs.is_game_folder_candidate(str(self.dir)))
        self.problem('missing', ('updates/131072/romfs',))
        (self.dir / 'updates/131072/romfs').mkdir(parents=True)
        r = self.scan()
        self.assertIsInstance(r, inputs.GameFolderContents)
        self.assertEqual(r.title_id, TID)
        self.assertEqual(r.base_path, str(self.dir / 'updates/131072'))


@unittest.skipIf(model_mod is None, 'PySide6 is not installed')
class ModelTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        root = Path(self._tmp.name)
        self.eng = root / 'engine'   # an engine tree: the marker file makes it the repo itself
        (self.eng / 'dm/tools/nx_extract').mkdir(parents=True)
        (self.eng / 'dm/tools/nx_extract/Program.cs').write_text('')
        (self.eng / 'scripts').mkdir()
        for n in ('pack_dump.py', 'pack_nup.py'):
            (self.eng / 'scripts' / n).write_text('')
        (self.eng / 'scripts/build_ipa_from_nsp.py').write_text("p.add_argument('--work-dir')\n")
        (self.eng / f'dm/games/{TID:016X}').mkdir(parents=True)
        (self.eng / f'dm/games/{TID:016X}/game.tsv').write_text('name\tGame\n')
        self.game = root / 'game'
        (self.game / 'base/exefs').mkdir(parents=True)
        (self.game / 'base/romfs').mkdir()
        (self.game / 'base/exefs/main.npdm').write_bytes(npdm(TID))
        self.m = model_mod.Model()
        self.m.lang = Lang('en')
        self.m.repo_path = str(self.eng)
        self.m.python_path = '/usr/bin/python3'

    def tearDown(self):
        self._tmp.cleanup()

    def ready(self):
        """Pass the dependency gate: this is about the inputs."""
        p = mock.patch.object(model_mod.Model, 'all_deps_ok', new_callable=mock.PropertyMock, return_value=True)
        p.start()
        self.addCleanup(p.stop)

    def test_folder_fills_rows_and_needs_no_keys(self):
        self.ready()
        (self.game / 'updates/458752/romfs').mkdir(parents=True)
        (self.game / f'dlc/{TID + 0x1001:016X}/0/romfs').mkdir(parents=True)
        self.m.scan_game_dir(str(self.game))
        self.assertEqual(self.m.keys_path, '')
        self.assertTrue(self.m.can_build)
        self.assertEqual(self.m.input_row_text('base'), 'Game folder, title ID 0400000000A00000 from main.npdm')
        self.assertEqual(self.m.input_row_text('update'), 'Update version 458752')
        self.assertEqual(self.m.input_row_text('dlc'), 'Add-on content folders: 1')
        self.assertIn('Not needed', self.m.input_row_text('keys'))

    def test_several_updates_text_uses_both_numbers(self):
        (self.game / 'updates/1/romfs').mkdir(parents=True)
        (self.game / 'updates/2/romfs').mkdir(parents=True)
        self.m.scan_game_dir(str(self.game))
        self.assertEqual(self.m.input_row_text('update'), 'Update version 2, the newest of 2')

    def test_nup_rows(self):
        self.ready()
        p = self.game.parent / 'g.nup'
        p.write_bytes(nup([(TID, 0, 0)]))
        self.m.scan_game_dir(str(p))
        self.assertTrue(self.m.can_build)
        self.assertEqual(self.m.base_path, str(p))
        self.assertEqual(self.m.input_row_text('base'), f'NUP file, title ID {TID:016X}')
        p.write_bytes(nup([(TID + 0x1001, 0, 2)]))
        self.m.scan_game_dir(str(p))
        self.assertEqual(self.m.input_row_text('base'), 'NUP file. The build reads its title ID.')

    def test_refused_with_the_reason(self):
        self.ready()
        (self.game / 'base/romfs').rmdir()
        self.m.scan_game_dir(str(self.game))
        self.assertFalse(self.m.can_build)
        self.assertEqual(self.m.game_folder_problem, 'This game folder has no base/romfs.')
        self.assertIsNone(self.m.input_row_text('base'))

    def test_refused_without_a_profile_or_with_an_old_engine(self):
        (self.eng / f'dm/games/{TID:016X}/game.tsv').unlink()
        self.m.scan_game_dir(str(self.game))
        self.assertIn(f'The engine has no profile for {TID:016X}.', self.m.game_folder_problem)
        self.assertIsNone(self.m.game_folder)
        (self.eng / 'scripts/pack_dump.py').unlink()
        self.m.scan_game_dir(str(self.game))
        self.assertEqual(self.m.game_folder_problem, 'This engine does not build game folders. Update the engine first.')
        p = self.game.parent / 'g.nup'
        p.write_bytes(nup([(TID, 0, 0)]))
        (self.eng / 'scripts/pack_nup.py').unlink()
        self.m.scan_game_dir(str(p))
        self.assertEqual(self.m.game_folder_problem, 'This engine does not build NUP files. Update the engine first.')

    def test_dlc_problem_text_has_both_numbers(self):
        (self.game / f'dlc/{TID + 0x1001:016X}/romfs').mkdir(parents=True)
        (self.game / f'dlc/{TID + 0x1001:016X}/romfs').rmdir()
        (self.game / f'dlc/{TID + 0x1001:016X}').mkdir(exist_ok=True)
        self.m.scan_game_dir(str(self.game))
        self.assertEqual(self.m.game_folder_problem, f'dlc/{TID + 0x1001:016X} needs one romfs folder and has 0.')

    def test_picking_packages_leaves_the_mode(self):
        self.m.scan_game_dir(str(self.game))
        self.assertIsNotNone(self.m.game_folder)
        self.m.leave_game_folder()
        self.assertIsNone(self.m.game_folder)
        self.assertEqual((self.m.base_path, self.m.update_path, self.m.dlc_paths), ('', '', []))
        self.assertIsNone(self.m.input_row_text('keys'))
        self.assertFalse(self.m.can_build)   # packages need the keys again

    def run_build(self, out_dir: str = '') -> tuple[list[str], 'model_mod.Model']:
        self.m.out_dir = out_dir
        seen: list[list[str]] = []

        class Fake:
            returncode = 1
            stdout: list[str] = []

            def __init__(self, cmd, **kw):
                seen.append(cmd)

            def wait(self):
                pass

        with mock.patch.object(model_mod.subprocess, 'Popen', Fake), \
                mock.patch.object(model_mod.pu, 'IS_WIN', False):
            self.m.start_build()
            self.m._thread.join(10)
        builds = [c for c in seen if '--progress' in c]   # other processes may start too (the dependency checks)
        self.assertTrue(builds, 'the script was not started')
        return builds[0], self.m

    def test_build_arguments_for_a_folder(self):
        self.ready()
        self.m.scan_game_dir(str(self.game))
        args, m = self.run_build()
        self.assertNotIn('-k', args)
        self.assertEqual(args[args.index(str(self.eng / 'scripts/build_ipa_from_nsp.py')) + 1], str(self.game))
        self.assertEqual(args[args.index('--work-dir') + 1], str(self.game / f'{TID:016X}_build'))
        self.assertEqual(m.effective_work_dir, str(self.game / f'{TID:016X}_build'))

    def test_build_arguments_for_a_nup_with_an_output_folder(self):
        self.ready()
        p = self.game.parent / 'g.nup'
        p.write_bytes(nup([(TID, 0, 0)]))
        self.m.scan_game_dir(str(p))
        out = str(self.game.parent / 'out')
        self.m.target = 'mac-app'
        args, _ = self.run_build(out)
        self.assertNotIn('-k', args)
        self.assertEqual(args[args.index(str(self.eng / 'scripts/build_ipa_from_nsp.py')) + 1], str(p))
        self.assertEqual(args[args.index('--work-dir') + 1], str(Path(out, f'{TID:016X}_build')))
        self.assertEqual(args[args.index('-o') + 1], str(Path(out, f'{TID:016X}.app')))

    def test_a_nup_without_a_title_id_names_the_build_after_the_file(self):
        self.ready()
        p = self.game.parent / 'g.nup'
        p.write_bytes(nup([(TID + 0x1001, 0, 2)]))
        self.m.scan_game_dir(str(p))
        self.assertEqual(self.m.build_key, inputs.build_key(str(p)))

    def test_packages_still_pass_the_keys(self):
        self.ready()
        pk = self.game.parent / 'pk'
        pk.mkdir()
        (pk / '0100AAAA0000A000.nsp').write_bytes(b'x')
        (pk / 'prod.keys').write_bytes(b'x')
        self.m.scan_game_dir(str(pk))
        self.assertIsNone(self.m.game_folder)
        args, _ = self.run_build()
        self.assertEqual(args[args.index('-k') + 1], str(pk / 'prod.keys'))

    def test_nested_wrapper_and_base_subfolder_build_without_keys(self):
        self.ready()
        nested = self.game.parent / 'Unzipped' / 'Wrapper' / 'Bananza'
        nested.parent.mkdir(parents=True)
        self.game.rename(nested)
        for picked in (nested.parent.parent, nested.parent, nested / 'base', nested / 'base/exefs'):
            self.m.scan_game_dir(str(picked))
            self.assertEqual(self.m.game_dir, str(nested))
            self.assertIsNotNone(self.m.game_folder)
            self.assertEqual(self.m.game_folder.folder, str(nested))
            self.assertTrue(self.m.can_build)
            self.assertEqual(self.m.keys_path, '')


if __name__ == '__main__':
    unittest.main()
