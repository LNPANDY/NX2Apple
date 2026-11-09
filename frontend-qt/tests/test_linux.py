"""The Linux front end: the paths, the tools, the file manager and the dependency rows.

The launcher is cross-platform (Python 3.9+ and PySide6), so Linux is a matter of the few
places where the two existing platforms differ: the venv folder, the file manager, the tool
discovery and the dependency panel (Linux has no Xcode and no Metal, and its shader chain is
Vulkan: spirv-cross and glslangValidator).
"""
from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'frontend-qt'))

from nspb_qt import platform_util as pu   # noqa: E402
from nspb_qt.model import Model           # noqa: E402

L10N = ROOT / 'frontend' / 'l10n'
LINUX_KEYS = ('dep.linux.zstd', 'dep.linux.spirv', 'dep.linux.glslang', 'dep.linux.note')


class LinuxPaths(unittest.TestCase):
    def test_this_machine_is_linux(self):
        self.assertTrue(pu.IS_LINUX, 'this test only means something on Linux')
        self.assertFalse(pu.IS_WIN)
        self.assertFalse(pu.IS_MAC)

    def test_the_venv_lives_under_the_user_data_folder(self):
        v = pu.venv_dir()
        self.assertEqual(v.parent.name, 'NS Port Builder')
        self.assertTrue(str(v).startswith(str(Path.home() / '.local' / 'share')), v)

    def test_the_file_manager_is_asked_over_the_desktop(self):
        """The file is selected in the file manager, the folder is opened."""
        with tempfile.TemporaryDirectory() as td:
            f = Path(td) / 'romfs.img'
            f.write_bytes(b'x')
            other = Path(td) / 'plain'
            other.mkdir()
            with mock.patch('subprocess.Popen') as popen:
                self.assertTrue(pu.reveal(str(f)))
                self.assertTrue(pu.reveal(str(other)))
                self.assertFalse(pu.reveal(''))
            first = popen.call_args_list[0][0][0]
            second = popen.call_args_list[1][0][0]
            self.assertEqual(first[0], 'dbus-send', first)
            self.assertEqual(second[0], 'xdg-open', second)

    def test_the_children_run_in_the_c_locale(self):
        """The engine's own messages are English and the panel's patterns match them."""
        env = pu.child_env()
        self.assertEqual(env['LC_ALL'], 'C')
        self.assertEqual(env['LANG'], 'C')
        self.assertEqual(env['PYTHONUTF8'], '1')

    def test_the_vulkan_shader_tools_are_looked_for(self):
        """The two tools of the Linux shader chain, by name. Whether they are installed is
        the machine's business (the panel says so)."""
        with mock.patch.object(pu, 'find_tool', side_effect=lambda n: '/usr/bin/' + n) as find:
            cross, glslang = pu.vulkan_shader_tools()
        self.assertEqual(find.call_args_list, [mock.call('spirv-cross'), mock.call('glslangValidator')])
        self.assertEqual(cross, '/usr/bin/spirv-cross')
        self.assertEqual(glslang, '/usr/bin/glslangValidator')

    def test_there_is_no_metal_compiler_on_linux(self):
        self.assertFalse(pu.metal_toolchain_ok())


class LinuxDependencyRows(unittest.TestCase):
    def test_the_panel_names_the_vulkan_tools_and_no_xcode(self):
        m = Model()
        rows = {r.id: r for r in m._linux_deps()}
        self.assertEqual(set(rows), {'tool:zstd', 'tool:spirv-cross', 'tool:glslangValidator'})
        self.assertTrue(rows['tool:zstd'].required)
        self.assertFalse(rows['tool:spirv-cross'].required)
        self.assertFalse(rows['tool:glslangValidator'].required)
        self.assertEqual(rows['tool:spirv-cross'].title_key, 'dep.linux.spirv')
        self.assertEqual(rows['tool:glslangValidator'].title_key, 'dep.linux.glslang')


class LinuxTexts(unittest.TestCase):
    def test_english_and_chinese_have_the_linux_rows(self):
        for code in ('en', 'zh'):
            d = json.loads((L10N / f'{code}.json').read_text(encoding='utf-8'))
            for key in LINUX_KEYS:
                self.assertIn(key, d, f'{code}.json lacks {key}')

    def test_no_language_leaves_the_note_in_english(self):
        en = json.loads((L10N / 'en.json').read_text(encoding='utf-8'))['dep.linux.note']
        for path in sorted(L10N.glob('*.json')):
            if path.name == 'en.json':
                continue
            d = json.loads(path.read_text(encoding='utf-8'))
            if 'dep.linux.note' in d:
                self.assertNotEqual(d['dep.linux.note'], en, path.name)


if __name__ == '__main__':
    unittest.main()
