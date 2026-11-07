"""The Windows link command stays below CreateProcess's limit for large hosts."""
from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path, PureWindowsPath
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from nspb_qt.win import build_app  # noqa: E402


class LinkFileListTests(unittest.TestCase):
    def invoke(self, kind, out, objects, runtime):
        args = [PureWindowsPath('C:/LLVM/bin/clang.exe'),
                PureWindowsPath('C:/SDK/iPhoneOS27.2.sdk'), objects,
                ['Foundation', 'UIKit'], out]
        if kind == 'framework':
            args.append('DmGame0100')
        args += ['26.0', ['-Wl,-segprot,__DM,rwx,rwx'], runtime,
                 PureWindowsPath('C:/LLVM/bin')]
        return getattr(build_app, 'link_framework' if kind == 'framework' else 'link')(*args)

    def test_hundreds_of_long_windows_paths_fit_in_both_link_commands(self):
        root = PureWindowsPath('E:/NX2Apple/Games with spaces, commas and 猫/'
                               'The_Legend_Of_Zelda_Tears_Of_The_Kingdom_NSW-NiiNTENDO/'
                               'n-legendofzeldatotk-c18e96d4_build/build/ios/win/obj')
        objects = [root / f'host_source_{i:03}-0123456789ab.o' for i in range(267)]
        runtime = root.parent / 'compat_rt.o'
        # Even before flags, these paths exceed CreateProcess's 32,767 UTF-16-unit limit.
        long_command = subprocess.list2cmdline([str(p) for p in objects])
        self.assertGreater(len(long_command.encode('utf-16-le')) // 2, 32767)
        for kind in ('app', 'framework'):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as td:
                filelists = []

                def run(args, **kwargs):
                    size = len(subprocess.list2cmdline(args).encode('utf-16-le')) // 2
                    self.assertLess(size, 32767, 'the linker must start on Windows')
                    index = args.index('-filelist')
                    self.assertEqual(args[index - 1:index + 2],
                                     ['-Xlinker', '-filelist', '-Xlinker'])
                    filelist = Path(args[index + 2])
                    filelists.append(filelist)
                    self.assertEqual(filelist.read_text(encoding='utf-8').splitlines(),
                                     [str(p) for p in objects + [runtime]])
                    self.assertNotIn(str(objects[0]), args)
                    self.assertIn('-Wl,-segprot,__DM,rwx,rwx', args)
                    self.assertIn('UIKit', args)
                    if kind == 'framework':
                        self.assertIn('-dynamiclib', args)
                        self.assertIn('-Wl,-install_name,@rpath/DmGame0100.framework/DmGame0100', args)
                    self.assertTrue(kwargs['env']['PATH'].startswith('C:\\LLVM\\bin' + os.pathsep))
                    return subprocess.CompletedProcess(args, 0)

                with mock.patch.object(build_app.subprocess, 'run', side_effect=run), \
                     mock.patch.object(build_app, 'check_executable'), \
                     mock.patch.object(build_app, 'check_dylib'), \
                     mock.patch.object(build_app.macho_sign, 'sign', return_value=0):
                    self.invoke(kind, Path(td) / 'DmIOS', objects, runtime)
                self.assertEqual(len(filelists), 1)
                self.assertFalse(filelists[0].exists(), 'the list is removed after linking')

    def test_filelist_is_removed_if_the_linker_fails_or_cannot_start(self):
        for kind in ('app', 'framework'):
            for fails_to_start in (False, True):
                with self.subTest(kind=kind, fails_to_start=fails_to_start), \
                     tempfile.TemporaryDirectory() as td:
                    filelists = []

                    def run(args, **kwargs):
                        self.assertIn('-filelist', args)
                        index = args.index('-filelist')
                        filelist = Path(args[index + 2])
                        filelists.append(filelist)
                        self.assertEqual(filelist.read_text(encoding='utf-8'), 'host.o\n')
                        if fails_to_start:
                            raise OSError('linker unavailable')
                        return subprocess.CompletedProcess(args, 1, '', 'linker failed')

                    with mock.patch.object(build_app.subprocess, 'run', side_effect=run), \
                         mock.patch.object(build_app, 'check_executable') as executable, \
                         mock.patch.object(build_app, 'check_dylib') as dylib, \
                         mock.patch.object(build_app.macho_sign, 'sign') as sign, \
                         self.assertRaises(OSError if fails_to_start else SystemExit):
                        self.invoke(kind, Path(td) / 'DmIOS', [Path('host.o')], None)
                    self.assertEqual(len(filelists), 1)
                    self.assertFalse(filelists[0].exists())
                    executable.assert_not_called()
                    dylib.assert_not_called()
                    sign.assert_not_called()


if __name__ == '__main__':
    unittest.main()
