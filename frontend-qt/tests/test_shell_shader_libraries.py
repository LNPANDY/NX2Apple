"""External shader libraries for the shared app (LNPANDY/NX2Apple#947).

The shader library of a big game is one file of several gigabytes, and the install tools cannot
copy it on to the phone: Sideloadly reports PackageExtractionFailed, AltServer reports that the
app could not be found, AltStore and SideStore report that they cannot allocate the memory. The
same archive without that one file installs, and the host already reads a game's own
`Documents/games/<Title ID>/msl/` before the copy inside the framework.

So the exporter writes the library beside the IPA for the player to send to the phone, and leaves
it out of the archive. These tests cover the folder it writes and the arguments it packs with.
"""
from __future__ import annotations

import json
import os
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
QT = HERE.parent
ROOT = QT.parent
sys.path.insert(0, str(QT))

from nspb_qt.win import shell_export as se  # noqa: E402


def make_framework(root: Path, title_id: str, *, shaders: bool = True,
                   chain: str = 'b-0123456789ab') -> Path:
    """A framework the exporter accepts, with (or without) a shader library folder."""
    fw = Path(root) / f'DmGame{title_id}.framework'
    fw.mkdir(parents=True, exist_ok=True)
    if shaders:
        (fw / 'msl' / chain).mkdir(parents=True, exist_ok=True)
        (fw / 'msl' / chain / 'a.metal').write_bytes(b'metal a')
        (fw / 'msl' / chain / 'b.metal').write_bytes(b'metal b')
    (fw / 'game.manifest.json').write_text(json.dumps({
        'schema': 1,
        'title_id': title_id,
        'name': f'Game {title_id}',
        'modules': ['main'],
        'chain': chain,
        'loader': 'FH',
        'framework': fw.name,
        'framework_executable': f'DmGame{title_id}',
        'image_marker': 'dmgame_image_marker',
        'min_os': '26.0',
    }), encoding='utf-8')
    (fw / f'DmGame{title_id}').write_bytes(b'\xcf\xfa\xed\xfe' + b'\0' * 60)
    return fw


def make_template(root: Path) -> Path:
    """A stand-in for the pre-built DmShell.app the exporter stages from."""
    app = Path(root) / 'DmShell.app'
    app.mkdir(parents=True, exist_ok=True)
    (app / 'DmShell').write_bytes(b'\xcf\xfa\xed\xfe' + b'\0' * 60)
    (app / 'Info.plist').write_bytes(b'<?xml version="1.0"?><plist version="1.0"><dict/></plist>')
    (app / 'dm' / 'font').mkdir(parents=True, exist_ok=True)
    return app


class FrameworkShadersTest(unittest.TestCase):
    def setUp(self):
        self.temp = Path(tempfile.mkdtemp(prefix='nspb-shaders-'))

    def tearDown(self):
        shutil.rmtree(self.temp, ignore_errors=True)

    def test_a_framework_with_a_library_reports_its_folder(self):
        fw = make_framework(self.temp, '0100000000000001')
        self.assertEqual(se.framework_shaders(fw), fw / 'msl')

    def test_a_framework_without_a_library_reports_nothing(self):
        fw = make_framework(self.temp, '0100000000000001', shaders=False)
        self.assertIsNone(se.framework_shaders(fw))

    def test_the_skip_path_is_the_frameworks_shader_folder(self):
        self.assertEqual(
            se.shader_library_skip('DmGame0100000000000001.framework'),
            'Payload/DmShell.app/Frameworks/DmGame0100000000000001.framework/msl')


class PlaceShaderLibraryTest(unittest.TestCase):
    def setUp(self):
        self.temp = Path(tempfile.mkdtemp(prefix='nspb-place-'))

    def tearDown(self):
        shutil.rmtree(self.temp, ignore_errors=True)

    def test_the_library_is_written_beside_the_ipa_under_its_title_id(self):
        fw = make_framework(self.temp / 'fw', '0100000000000001')
        placed = se.place_shader_library(fw, self.temp / 'shell', '0100000000000001')

        self.assertEqual(placed, se.external_shader_folder(self.temp / 'shell', '0100000000000001') / 'msl')
        self.assertEqual(placed, self.temp / 'shell' / 'export' / 'shader-libraries'
                         / '0100000000000001' / 'msl')
        self.assertEqual(sorted(p.name for p in placed.rglob('*') if p.is_file()),
                         ['a.metal', 'b.metal'])

    def test_the_library_keeps_the_chain_folder_it_is_found_in(self):
        fw = make_framework(self.temp / 'fw', '0100000000000001')
        placed = se.place_shader_library(fw, self.temp / 'shell', '0100000000000001')
        self.assertTrue((placed / 'b-0123456789ab' / 'a.metal').is_file())

    def test_a_stale_copy_is_replaced(self):
        fw = make_framework(self.temp / 'fw', '0100000000000001')
        dest = self.temp / 'shell' / 'export' / 'shader-libraries' / '0100000000000001' / 'msl'
        dest.mkdir(parents=True)
        (dest / 'gone.metal').write_bytes(b'old')

        se.place_shader_library(fw, self.temp / 'shell', '0100000000000001')

        self.assertFalse((dest / 'gone.metal').exists())
        self.assertTrue((dest / 'b-0123456789ab' / 'a.metal').is_file())

    def test_a_framework_without_a_library_writes_nothing(self):
        fw = make_framework(self.temp / 'fw', '0100000000000001', shaders=False)
        self.assertIsNone(se.place_shader_library(fw, self.temp / 'shell', '0100000000000001'))
        self.assertFalse((self.temp / 'shell' / 'export' / 'shader-libraries').exists())

    def test_the_title_id_folder_is_upper_case(self):
        fw = make_framework(self.temp / 'fw', '0100000000000001')
        placed = se.place_shader_library(fw, self.temp / 'shell', '010000000000000a')
        self.assertEqual(placed.parent.name, '010000000000000A')


class ExportShellSkipTest(unittest.TestCase):
    """The pack call leaves every game's shader folder out, and nothing else."""

    def setUp(self):
        self.temp = Path(tempfile.mkdtemp(prefix='nspb-skip-'))
        self.shell = self.temp / 'shell'
        self.repo = self.temp / 'repo'
        (self.repo / 'dm' / 'ios' / 'tools').mkdir(parents=True)
        (self.repo / 'dm' / 'ios' / 'tools' / 'pack_ipa.py').write_text('# stand-in\n',
                                                                        encoding='utf-8')
        self.template = make_template(self.temp / 'template')
        self.fw1 = make_framework(self.temp / 'build', '0100000000000001')
        self.fw2 = make_framework(self.temp / 'build', '0100000000000002')
        self.commands: list[list[str]] = []

    def tearDown(self):
        shutil.rmtree(self.temp, ignore_errors=True)

    def _fake_run(self, cmd, **kwargs):
        self.commands.append([str(c) for c in cmd])
        tmp = Path(cmd[2])
        tmp.write_bytes(b'PK\x05\x06' + b'\0' * 18)
        return mock.Mock(returncode=0, stdout='', stderr='')

    def _export(self, **kwargs):
        args = dict(framework=self.fw1, title_id='0100000000000001', name='One')
        args.update(kwargs)
        with mock.patch.object(se, 'find_shell_template', return_value=self.template), \
                mock.patch.object(se, '_prepare_fonts', lambda *a, **k: None), \
                mock.patch.object(se, '_update_shell_plist', lambda *a, **k: None), \
                mock.patch.object(se.macho_sign, 'sign', lambda *a, **k: 0), \
                mock.patch.object(se.subprocess, 'run', self._fake_run), \
                mock.patch.object(se, 'check_ipa_has_games', lambda *a, **k: None), \
                mock.patch.object(se.fix_ipa_modes, 'fix', lambda *a, **k: 'modes'), \
                mock.patch.dict(os.environ, {'NSPB_SHELL_TEMPLATE': str(self.template)}):
            return se.export_shell(root=self.shell, repo=self.repo, **args)

    def _skips(self) -> list[str]:
        self.assertTrue(self.commands, 'the packer was not called')
        cmd = self.commands[-1]
        out = []
        for i, part in enumerate(cmd):
            if part == '--skip':
                out.append(cmd[i + 1])
        return out

    def test_both_games_shader_folders_are_left_out_of_the_archive(self):
        self._export()
        # The second game is registered in the library the first export created; the framework
        # mirror of it has to exist for it to be packed, so register it first.
        self.assertIn('Payload/DmShell.app/Frameworks/DmGame0100000000000001.framework/msl',
                      self._skips())

    def test_the_library_of_the_game_being_added_is_written_beside_the_ipa(self):
        self._export()
        placed = se.external_shader_folder(self.shell, '0100000000000001') / 'msl'
        self.assertTrue((placed / 'b-0123456789ab' / 'a.metal').is_file())

    def test_the_ipa_is_still_written(self):
        ok, out, msg, notes = self._export()
        self.assertTrue(ok, msg)
        self.assertEqual(Path(out), se.ipa_path(self.shell))
        self.assertTrue(Path(out).is_file())

    def test_the_note_names_the_folder_to_copy_from(self):
        _ok, _out, msg, notes = self._export()
        self.assertTrue(any('shell.shadersExported' in n for n in notes), notes)
        self.assertIn('shader-libraries', msg)

    def test_packing_the_shaders_in_again_leaves_none_out(self):
        self._export(external_shaders=False)
        self.assertEqual(self._skips(), [])
        self.assertFalse(se.shader_libraries_folder(self.shell).exists())

    def test_a_second_game_gets_its_own_skip_and_library(self):
        self._export()
        self.fw2.parent.mkdir(parents=True, exist_ok=True)
        self._export(framework=self.fw2, title_id='0100000000000002', name='Two')
        skips = self._skips()
        self.assertIn('Payload/DmShell.app/Frameworks/DmGame0100000000000001.framework/msl', skips)
        self.assertIn('Payload/DmShell.app/Frameworks/DmGame0100000000000002.framework/msl', skips)
        for tid in ('0100000000000001', '0100000000000002'):
            placed = se.external_shader_folder(self.shell, tid) / 'msl'
            self.assertTrue((placed / 'b-0123456789ab' / 'a.metal').is_file(), tid)


if __name__ == '__main__':
    unittest.main()
