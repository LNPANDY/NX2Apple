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

    def test_resolve_source_input_for_single_and_shared_nup_folders(self):
        work_dir = self.temp_dir / 'work'
        work_dir.mkdir()

        solo_dir = self.temp_dir / 'solo'
        solo_dir.mkdir()
        solo_nup = solo_dir / 'Game.nup'
        solo_nup.write_bytes(b'nup')
        resolved, used_staging = s2arm_builder.resolve_source_input(str(solo_nup), work_dir=str(work_dir))
        self.assertEqual(resolved, str(solo_dir))
        self.assertFalse(used_staging)
        self.assertTrue(Path(resolved).is_dir())

        shared_dir = self.temp_dir / 'shared'
        shared_dir.mkdir()
        target_nup = shared_dir / 'Target.nup'
        other_nsp = shared_dir / 'Other.nsp'
        target_nup.write_bytes(b'nup-target')
        other_nsp.write_bytes(b'nsp-other')
        resolved2, used_staging2 = s2arm_builder.resolve_source_input(str(target_nup), work_dir=str(work_dir))
        self.assertTrue(used_staging2)
        self.assertTrue(Path(resolved2).is_dir())
        self.assertEqual([p.name for p in Path(resolved2).iterdir()], ['Target.nup'])

        # Directory input passes through unchanged
        resolved_dir, used_staging_dir = s2arm_builder.resolve_source_input(str(solo_dir), work_dir=str(work_dir))
        self.assertEqual(resolved_dir, str(solo_dir))
        self.assertFalse(used_staging_dir)

    def test_find_dotnet_skips_homebrew_cellar_and_prioritizes_official_paths(self):
        cellar_dotnet = self.temp_dir / 'Cellar' / 'dotnet' / '10.0.403' / 'bin' / 'dotnet'
        cellar_dotnet.parent.mkdir(parents=True, exist_ok=True)
        cellar_dotnet.write_text('#!/bin/sh\n', encoding='utf-8')
        symlink_dotnet = self.temp_dir / 'brew-link-dotnet'
        symlink_dotnet.symlink_to(cellar_dotnet)

        official = self.temp_dir / 'official' / 'dotnet'
        official.parent.mkdir(parents=True, exist_ok=True)
        official.write_text('#!/bin/sh\n', encoding='utf-8')

        self.assertTrue(s2arm_builder.is_homebrew_dotnet_path('/opt/homebrew/bin/dotnet'))
        self.assertTrue(s2arm_builder.is_homebrew_dotnet_path(str(cellar_dotnet)))
        self.assertTrue(s2arm_builder.is_homebrew_dotnet_path(str(symlink_dotnet)))
        self.assertFalse(s2arm_builder.is_homebrew_dotnet_path(str(official)))

        probed: list[str] = []

        def fake_run(cmd, _env):
            probed.append(cmd[0])
            return 0, '10.0.403 [/sdk]\n'

        path, ok, _, _ = s2arm_builder.find_dotnet_for_s2arm(
            candidates=['/opt/homebrew/bin/dotnet', str(symlink_dotnet), str(official)],
            runner=fake_run,
            is_windows=False,
        )
        self.assertTrue(ok)
        self.assertEqual(path, str(official))
        self.assertEqual(probed, [str(official)])

    def test_bootstrap_git_repo_pinned_venv_rewriter_deps_bash_runtime_and_win_fonts(self):
        import os
        import subprocess
        from nspb_qt import s2arm_bootstrap

        tree = self.make_fake_tree()
        tree.joinpath('graphics', 'widen', 'scan').mkdir(parents=True, exist_ok=True)
        tree.joinpath('graphics', 'widen', 'scan', 'a.txt').write_text('ok\n', encoding='utf-8')
        tree.joinpath('.venv', 'bin').mkdir(parents=True, exist_ok=True)
        tree.joinpath('.venv', 'bin', 'marker').write_text('x\n', encoding='utf-8')
        tree.joinpath('.upstream-version.json').write_text('{}\n', encoding='utf-8')
        tree.joinpath('build').mkdir(parents=True, exist_ok=True)
        tree.joinpath('build', 'tmp.o').write_text('o\n', encoding='utf-8')

        self.assertTrue(s2arm_bootstrap.ensure_git_repo(tree))
        git_env = {**os.environ, 'GIT_CONFIG_GLOBAL': os.devnull, 'GIT_CONFIG_NOSYSTEM': '1'}
        ls_out = subprocess.check_output(['git', '-C', str(tree), 'ls-files'], env=git_env, text=True)
        tracked = set(ls_out.splitlines())
        self.assertIn('graphics/widen/scan/a.txt', tracked)
        self.assertNotIn('.venv/bin/marker', tracked)
        self.assertNotIn('.upstream-version.json', tracked)
        self.assertNotIn('build/tmp.o', tracked)
        status = subprocess.check_output(['git', '-C', str(tree), 'status', '--porcelain'], env=git_env, text=True)
        self.assertEqual(status.strip(), '')

        # Official requirements*.txt parsing + exact pin probe
        tree.joinpath('tools').mkdir(parents=True, exist_ok=True)
        tree.joinpath('tools', 'rewriter-requirements.txt').write_text('capstone==5.0.7\nlz4==4.4.5\n', encoding='utf-8')
        tree.joinpath('pack', 'fonts').mkdir(parents=True, exist_ok=True)
        tree.joinpath('pack', 'fonts', 'requirements.txt').write_text('fonttools==4.67.0\nskia-pathops==0.9.2\n', encoding='utf-8')
        tree.joinpath('launchers', 'macos').mkdir(parents=True, exist_ok=True)
        tree.joinpath('launchers', 'macos', 'requirements-runtime.txt').write_text(
            'numpy==2.4.2\nPillow==12.3.0\nzstandard==0.25.0\n', encoding='utf-8'
        )
        specs_posix, pins = s2arm_bootstrap.parse_requirement_pins(tree, is_windows=False)
        self.assertIn('fonttools==4.67.0', specs_posix)
        self.assertIn('skia-pathops==0.9.2', specs_posix)
        self.assertIn('meson', specs_posix)
        self.assertIn(('fonttools', '4.67.0'), pins)
        specs_win, _ = s2arm_bootstrap.parse_requirement_pins(tree, is_windows=True)
        self.assertIn('cmake', specs_win)
        self.assertIn('ninja', specs_win)
        self.assertNotIn('meson', specs_win)

        captured_probe: list[str] = []

        def fake_py_probe(cmd):
            captured_probe.append(cmd[-1])
            return 0, 'fonttools==4.67.0\n'

        self.assertEqual(
            s2arm_builder.missing_python_packages('/fake/py', tree=str(tree), runner=fake_py_probe),
            ['fonttools==4.67.0'],
        )
        self.assertIn('importlib.metadata.version', captured_probe[0])

        # Rewriter deps: cleans stale partial tree before invoking prepare_deps.py
        prep_script = tree / 'runtime' / 'rewriter' / 'prepare_deps.py'
        prep_script.write_text('#!/usr/bin/env python3\n', encoding='utf-8')
        stale = tree / 'build' / 'rewriter-deps' / 'stale.txt'
        stale.parent.mkdir(parents=True, exist_ok=True)
        stale.write_text('broken\n', encoding='utf-8')
        stale_removed = [False]

        def fake_deps_runner(argv, env, _cwd):
            stale_removed[0] = not stale.exists()
            dst = Path(argv[2])
            dst.joinpath('capstone-5.0.7', 'src').mkdir(parents=True, exist_ok=True)
            dst.joinpath('lz4-4.4.5', 'lz4libs').mkdir(parents=True, exist_ok=True)
            dst.joinpath('capstone-5.0.7', 'src', 'CMakeLists.txt').write_text('#\n', encoding='utf-8')
            dst.joinpath('lz4-4.4.5', 'lz4libs', 'lz4.c').write_text('/* */\n', encoding='utf-8')
            return 0, 'ok'

        ok_deps, skipped_deps, deps_path, _ = s2arm_bootstrap.ensure_rewriter_deps(
            tree, '/fake/py', runner=fake_deps_runner
        )
        self.assertTrue(ok_deps)
        self.assertFalse(skipped_deps)
        self.assertTrue(stale_removed[0])
        self.assertTrue(deps_path.endswith('rewriter-deps'))

        # POSIX modern bash & build_command bash_exe override + runtime_sources
        self.assertEqual(
            s2arm_bootstrap.find_modern_bash(
                candidates=['/old/bash', '/new/bash'],
                runner=lambda argv, _e, _c: (0, '3\n' if argv[0] == '/old/bash' else '5\n'),
                exists=lambda _p: True,
            ),
            '/new/bash',
        )
        argv_custom, _, _ = s2arm_builder.build_command(
            str(tree),
            python_exe='/fake/py',
            source_input='/roms/game',
            work_dir='/work',
            is_windows=False,
            bash_exe='/custom/tools/bin/bash',
        )
        self.assertEqual(argv_custom[0], '/custom/tools/bin/bash')

        (tree / 'launchers' / 'macos' / 'runtime_sources.py').write_text('# stub\n', encoding='utf-8')
        rt_prefix = s2arm_bootstrap.runtime_tools_prefix(tree)

        def fake_rt_runner(argv, _env, _cwd):
            (rt_prefix / 'bin').mkdir(parents=True, exist_ok=True)
            (rt_prefix / 'lib').mkdir(parents=True, exist_ok=True)
            for tool in s2arm_bootstrap.REQUIRED_RUNTIME_TOOLS_POSIX:
                p = rt_prefix / 'bin' / tool
                p.write_text('#!/bin/sh\n', encoding='utf-8')
                p.chmod(0o755)
            (rt_prefix / 'lib' / 'libzstd.1.dylib').write_bytes(b'dylib')
            return 0, f'{s2arm_bootstrap.RUNTIME_TOOLS_MARKER}{rt_prefix}\n'

        rt_ok, rt_skip, rt_bin, zstd_lib, _ = s2arm_bootstrap.ensure_runtime_tools(
            tree, '/fake/py', env={'PATH': '/nonexistent'}, runner=fake_rt_runner
        )
        self.assertTrue(rt_ok)
        self.assertFalse(rt_skip)
        self.assertEqual(rt_bin, str(rt_prefix / 'bin'))
        self.assertEqual(zstd_lib, str(rt_prefix / 'lib' / 'libzstd.1.dylib'))

        # Windows Git Bash lookup + 7 open shared fonts generation
        self.assertEqual(
            s2arm_bootstrap.find_git_bash_windows(
                candidates=[r'C:\Missing\bash.exe', r'C:\Program Files\Git\usr\bin\bash.exe'],
                exists=lambda p: 'Program Files' in p,
            ),
            r'C:\Program Files\Git\usr\bin\bash.exe',
        )
        (tree / 'pack' / 'fonts' / 'make_open_fonts.py').write_text('# stub\n', encoding='utf-8')
        fonts_dir = self.temp_dir / 's2arm-openfonts'

        def fake_fonts_runner(argv, _env, _cwd):
            out_dir = Path(argv[2])
            out_dir.mkdir(parents=True, exist_ok=True)
            for i in range(7):
                (out_dir / f'font_{i}.bfttf').write_bytes(b'font')
            return 0, 'generated 7 fonts\n'

        f_ok, f_skip, f_path, _ = s2arm_bootstrap.ensure_open_fonts_windows(
            tree, '/fake/py', fonts_dir, runner=fake_fonts_runner
        )
        self.assertTrue(f_ok)
        self.assertFalse(f_skip)
        self.assertEqual(f_path, str(fonts_dir))
        f_ok2, f_skip2, _, _ = s2arm_bootstrap.ensure_open_fonts_windows(tree, '/fake/py', fonts_dir)
        self.assertTrue(f_ok2)
        self.assertTrue(f_skip2)

    def test_recommended_concurrency_tiers_and_explicit_env_precedence(self):
        gib = 1024 * 1024 * 1024
        self.assertIsNone(s2arm_builder.recommended_concurrency(physical_memory_bytes=6 * gib, cpu_count=8))
        self.assertEqual(s2arm_builder.recommended_concurrency(physical_memory_bytes=8 * gib, cpu_count=12), (2, 1))
        self.assertEqual(s2arm_builder.recommended_concurrency(physical_memory_bytes=16 * gib, cpu_count=8), (4, 2))
        self.assertEqual(s2arm_builder.recommended_concurrency(physical_memory_bytes=24 * gib, cpu_count=10), (6, 3))
        self.assertEqual(s2arm_builder.recommended_concurrency(physical_memory_bytes=32 * gib, cpu_count=12), (8, 4))
        self.assertEqual(s2arm_builder.recommended_concurrency(physical_memory_bytes=32 * gib, cpu_count=2), (2, 2))

        defaulted = s2arm_builder.apply_concurrency_defaults(
            {'PATH': '/usr/bin'},
            process_env={},
            physical_memory_bytes=16 * gib,
            cpu_count=8,
        )
        self.assertEqual(defaulted['S2A_DIRECT_J'], '4')
        self.assertEqual(defaulted['S2A_CPU_BAKE'], '2')

        explicit = s2arm_builder.apply_concurrency_defaults(
            {'S2A_DIRECT_J': '1'},
            process_env={'S2A_CPU_BAKE': '3'},
            physical_memory_bytes=32 * gib,
            cpu_count=12,
        )
        self.assertEqual(explicit['S2A_DIRECT_J'], '1')
        self.assertEqual(explicit['S2A_CPU_BAKE'], '3')

        small = s2arm_builder.apply_concurrency_defaults(
            {},
            process_env={},
            physical_memory_bytes=4 * gib,
            cpu_count=4,
        )
        self.assertNotIn('S2A_DIRECT_J', small)
        self.assertNotIn('S2A_CPU_BAKE', small)


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
