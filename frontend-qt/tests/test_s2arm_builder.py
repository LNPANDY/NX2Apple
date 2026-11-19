"""Tests for S2Arm external builder adapter in frontend-qt."""
from __future__ import annotations

import shutil
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'frontend-qt'))

from nspb_qt import s2arm_builder


class S2ArmBuilderTests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = Path(tempfile.mkdtemp(prefix='s2arm-test-'))
        self.addCleanup(shutil.rmtree, self.temp_dir, True)

    def make_fake_tree(self, *, has_sh: bool = True, has_win: bool = True) -> Path:
        tree = self.temp_dir / 's2arm'
        tree.joinpath('pack', 'jobs').mkdir(parents=True, exist_ok=True)
        tree.joinpath('pack', 'jobs', 'main.py').write_text('#!/usr/bin/env python3\n', encoding='utf-8')
        tree.joinpath('runtime', 'rewriter').mkdir(parents=True, exist_ok=True)
        tree.joinpath('runtime', 'rewriter', 'rewriter.c').write_text('/* rewriter */\n', encoding='utf-8')
        if has_sh:
            tree.joinpath('pack', 'oneclick').mkdir(parents=True, exist_ok=True)
            tree.joinpath('pack', 'oneclick', 'oneclick.sh').write_text('#!/bin/bash\n', encoding='utf-8')
        if has_win:
            tree.joinpath('pack', 'orch').mkdir(parents=True, exist_ok=True)
            tree.joinpath('pack', 'orch', 'oneclick_win.py').write_text('#!/usr/bin/env python3\n', encoding='utf-8')
        return tree

    def test_feature_enabled(self):
        self.assertTrue(s2arm_builder.feature_enabled({}))
        self.assertFalse(s2arm_builder.feature_enabled({'NX2APPLE_MULTI_UPSTREAM': '0'}))
        self.assertTrue(s2arm_builder.feature_enabled({'NX2APPLE_MULTI_UPSTREAM': '1'}))

    def test_is_usable_tree(self):
        self.assertFalse(s2arm_builder.is_usable_tree(''))
        self.assertFalse(s2arm_builder.is_usable_tree(str(self.temp_dir)))

        posix_only = self.make_fake_tree(has_sh=True, has_win=False)
        self.assertTrue(s2arm_builder.is_usable_tree(str(posix_only), is_windows=False))
        self.assertFalse(s2arm_builder.is_usable_tree(str(posix_only), is_windows=True))

        win_only = self.temp_dir / 'win_s2arm'
        win_only.joinpath('pack', 'jobs').mkdir(parents=True, exist_ok=True)
        win_only.joinpath('pack', 'jobs', 'main.py').write_text('#!/usr/bin/env python3\n', encoding='utf-8')
        win_only.joinpath('runtime', 'rewriter').mkdir(parents=True, exist_ok=True)
        win_only.joinpath('runtime', 'rewriter', 'rewriter.c').write_text('/* rewriter */\n', encoding='utf-8')
        win_only.joinpath('pack', 'orch').mkdir(parents=True, exist_ok=True)
        win_only.joinpath('pack', 'orch', 'oneclick_win.py').write_text('#!/usr/bin/env python3\n', encoding='utf-8')

        self.assertTrue(s2arm_builder.is_usable_tree(str(win_only), is_windows=True))
        self.assertFalse(s2arm_builder.is_usable_tree(str(win_only), is_windows=False))

    def test_build_command_posix(self):
        tree = self.make_fake_tree()
        argv, cwd, env = s2arm_builder.build_command(
            str(tree),
            python_exe='/opt/homebrew/bin/python3',
            source_input='/roms/game_dir',
            keys_path='/keys/prod.keys',
            is_unencrypted=False,
            work_dir='/out/work',
            target='ios',
            title_id='0100000000001000',
            install_udid='udid-1234',
            events_file='/out/work/s2a-events.jsonl',
            is_windows=False,
        )
        expected_script = str(tree / 'pack' / 'oneclick' / 'oneclick.sh')
        self.assertEqual(argv[0], '/bin/bash')
        self.assertEqual(argv[1], expected_script)
        self.assertEqual(argv[2], '/roms/game_dir')
        self.assertIn('--keys', argv)
        self.assertIn('/keys/prod.keys', argv)
        self.assertIn('--out', argv)
        self.assertIn('/out/work', argv)
        self.assertIn('--target', argv)
        self.assertIn('ios', argv)
        self.assertIn('--title-id', argv)
        self.assertIn('0100000000001000', argv)
        self.assertIn('--device', argv)
        self.assertIn('udid-1234', argv)
        self.assertIn('--events', argv)
        self.assertIn('/out/work/s2a-events.jsonl', argv)
        self.assertEqual(cwd, str(tree))
        self.assertEqual(env['S2A_PYTHON'], '/opt/homebrew/bin/python3')
        self.assertEqual(env['S2A_KEYS'], '/keys/prod.keys')
        self.assertEqual(env['PYTHONUNBUFFERED'], '1')

    def test_build_command_windows(self):
        tree = self.make_fake_tree()
        argv, cwd, env = s2arm_builder.build_command(
            str(tree),
            python_exe='C:\\Python312\\python.exe',
            source_input='D:\\games\\game.nup',
            keys_path='D:\\keys\\prod.keys',
            is_unencrypted=True,
            work_dir='D:\\out\\work',
            target='mac-app',
            title_id='0100000000001000',
            install_udid='udid-1234',
            events_file='D:\\out\\work\\s2a-events.jsonl',
            is_windows=True,
        )
        self.assertEqual(argv[:5], ['C:\\Python312\\python.exe', '-X', 'utf8', '-m', 'pack.orch.oneclick_win'])
        self.assertEqual(argv[5], 'D:\\games\\game.nup')
        self.assertNotIn('--keys', argv)
        self.assertNotIn('S2A_KEYS', env)
        self.assertIn('--target', argv)
        self.assertIn('mac', argv)
        self.assertNotIn('--install', argv)
        self.assertNotIn('--device', argv)
        self.assertIn('--title-id', argv)
        self.assertIn('0100000000001000', argv)
        self.assertIn('--events', argv)
        self.assertIn('D:\\out\\work\\s2a-events.jsonl', argv)
        self.assertEqual(cwd, str(tree))
        self.assertEqual(env['PYTHONUNBUFFERED'], '1')

    def test_parse_events(self):
        self.assertIsNone(s2arm_builder.parse_events(''))
        self.assertIsNone(s2arm_builder.parse_events('not a json'))
        self.assertIsNone(s2arm_builder.parse_events('{"ev": "progress", "done": 10}\n'))

        sample = (
            '{"ev": "stage", "name": "extract"}\n'
            '{"ev": "result", "ok": true, "ipa": "/out/game.ipa", "pack": "/out/pack"}\n'
            '{"ev": "say", "msg": "finished"}\n'
        )
        parsed = s2arm_builder.parse_events(sample)
        self.assertIsNotNone(parsed)
        self.assertTrue(parsed['ok'])
        self.assertEqual(parsed['ipa'], '/out/game.ipa')
        self.assertEqual(parsed['pack'], '/out/pack')

        failed_sample = '{"ev": "result", "ok": false, "msg": "Extraction failed"}\n'
        failed_parsed = s2arm_builder.parse_events(failed_sample)
        self.assertIsNotNone(failed_parsed)
        self.assertFalse(failed_parsed['ok'])
        self.assertEqual(failed_parsed['msg'], 'Extraction failed')

    def test_last_error(self):
        log_with_symbol = "step 1\n【红】 critical packaging error\ncleanup\n"
        self.assertEqual(s2arm_builder.last_error(log_with_symbol), "【红】 critical packaging error")

        log_with_emoji = "step 1\n🔴 fatal shader failure\ncleanup\n"
        self.assertEqual(s2arm_builder.last_error(log_with_emoji), "🔴 fatal shader failure")

        log_with_error_prefix = "step 1\nERROR: invalid key table\ncleanup\n"
        self.assertEqual(s2arm_builder.last_error(log_with_error_prefix), "ERROR: invalid key table")

        events_text = '{"ev": "result", "ok": false, "msg": "events error message"}\n'
        self.assertEqual(s2arm_builder.last_error(log_with_symbol, events_text=events_text), "events error message")

        plain_log = "step 1\nstep 2 done\n"
        self.assertEqual(s2arm_builder.last_error(plain_log), "step 2 done")
        self.assertEqual(s2arm_builder.last_error(""), "")

    def test_sdk_requirement_and_dotnet_version_gate(self):
        from unittest import mock

        self.assertEqual(s2arm_builder.sdk_requirement(''), ('10.0.403', 'latestFeature'))
        tree = self.make_fake_tree()
        self.assertEqual(s2arm_builder.sdk_requirement(str(tree)), ('10.0.403', 'latestFeature'))

        compat = tree / 'compat' / 'tree'
        compat.mkdir(parents=True, exist_ok=True)
        (compat / 'global.json').write_text(
            '{"sdk": {"version": "10.0.403", "rollForward": "latestFeature"}}',
            encoding='utf-8',
        )
        self.assertFalse(s2arm_builder.sdk_satisfies('10.0.402', '10.0.403', 'latestFeature'))
        self.assertTrue(s2arm_builder.sdk_satisfies('10.0.403', '10.0.403', 'latestFeature'))
        self.assertTrue(s2arm_builder.sdk_satisfies('10.0.404', '10.0.403', 'latestFeature'))
        self.assertTrue(s2arm_builder.sdk_satisfies('10.0.500', '10.0.403', 'latestFeature'))

        def fake_run(cmd, _env):
            exe = cmd[0]
            out = '10.0.402 [/sdk]\n' if 'old' in exe else '10.0.403 [/sdk]\n'
            return 0, out

        path_old, ok_old, req_ver, found_old = s2arm_builder.find_dotnet_for_s2arm(
            candidates=['/fake/dotnet-old'],
            tree=str(tree),
            runner=fake_run,
        )
        self.assertFalse(ok_old)
        self.assertEqual(req_ver, '10.0.403')
        self.assertEqual(found_old, '10.0.402')

        path_new, ok_new, _, found_old2 = s2arm_builder.find_dotnet_for_s2arm(
            candidates=['/fake/dotnet-old', '/fake/dotnet-new'],
            tree=str(tree),
            runner=fake_run,
        )
        self.assertTrue(ok_new)
        self.assertEqual(path_new, '/fake/dotnet-new')
        self.assertIsNone(found_old2)

    def test_missing_python_packages_detection(self):
        self.assertEqual(
            s2arm_builder.missing_python_packages(
                '/fake/python3',
                runner=lambda _cmd: (0, 'Pillow,skia-pathops\n'),
            ),
            ['Pillow', 'skia-pathops'],
        )
        self.assertEqual(
            s2arm_builder.missing_python_packages(
                '/fake/python3',
                runner=lambda _cmd: (0, '\n'),
            ),
            [],
        )


try:
    from PySide6.QtCore import QSettings
    from PySide6.QtWidgets import QApplication
    from nspb_qt.i18n import Lang
    from nspb_qt import library as lib_mod
    from nspb_qt import model as model_mod
    from nspb_qt.model import Model
    HAS_QT = True
except ImportError:
    HAS_QT = False


if HAS_QT:
    class S2ArmModelDetailTests(unittest.TestCase):
        @classmethod
        def setUpClass(cls) -> None:
            cls._app = QApplication.instance() or QApplication([])

        def test_format_dep_detail_s2arm_tokens(self) -> None:
            from unittest import mock

            with tempfile.TemporaryDirectory() as td:
                root = Path(td)
                with mock.patch.object(lib_mod, 'default_state_dir', return_value=root / 'state'), \
                     mock.patch.object(model_mod, 'QSettings', side_effect=lambda *a, **kw: QSettings(str(root / 's.ini'), QSettings.IniFormat)), \
                     mock.patch.object(Model, 'check_deps', lambda _self: None), \
                     mock.patch.object(lib_mod.ArtworkStore, 'request_banner_async'):
                    m = Model()
                    m.set_lang(Lang('en'))
                    py_msg = m.format_dep_detail('dep.python.s2armMissing:Pillow, skia-pathops')
                    self.assertNotEqual(py_msg, 'dep.python.s2armMissing')
                    self.assertIn('Pillow, skia-pathops', py_msg)
                    self.assertEqual(py_msg, 'Missing S2Arm Python packages: Pillow, skia-pathops')

                    old_msg = m.format_dep_detail('dep.dotnet.s2armOld:9.0.100:10.0.403')
                    self.assertNotEqual(old_msg, 'dep.dotnet.s2armOld')
                    self.assertEqual(old_msg, 'Found 9.0.100, S2Arm requires .NET SDK 10.0.403 or newer')

                    miss_msg = m.format_dep_detail('dep.dotnet.s2armMissing:10.0.403')
                    self.assertNotEqual(miss_msg, 'dep.dotnet.s2armMissing')
                    self.assertEqual(miss_msg, 'S2Arm requires .NET SDK 10.0.403 or newer')


if __name__ == '__main__':
    unittest.main()
