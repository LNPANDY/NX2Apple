"""Tests for PEP 668 externally-managed Python handling and streamed `nsz` installation.

    python3 -m unittest frontend-qt/tests/test_pep668_nsz_install.py
"""
from __future__ import annotations

import os
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'frontend-qt'))

from nspb_qt import nsz_setup  # noqa: E402
from nspb_qt import platform_util as pu  # noqa: E402

try:
    from nspb_qt.model import Model
except ImportError:  # CI runs launcher-qt tests without PySide6
    Model = None


def _write_exe(path: Path, body: str) -> str:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(body, encoding='utf-8')
    path.chmod(0o755)
    return str(path)


def _make_fake_python_script(
    path: Path,
    *,
    has_nsz_state: Path | None = None,
    has_core_pkgs: bool = True,
    pep668_on_pip: bool = False,
    pip_exit_code: int = 0,
    pip_output: str = '',
    pip_marker: Path | None = None,
    pip_sleep: float = 0.0,
    env_dump_file: Path | None = None,
    version: str = '3.12',
    is_venv_python: bool = False,
) -> str:
    """Create a standalone Python-compatible stub script using the real host python3 interpreter."""
    body = textwrap.dedent(
        f"""\
        #!{sys.executable}
        import json
        import os
        import sys
        import time
        from pathlib import Path

        HAS_NSZ_STATE = {repr(str(has_nsz_state) if has_nsz_state else '')}
        HAS_CORE_PKGS = {repr(has_core_pkgs)}
        PEP668_ON_PIP = {repr(pep668_on_pip)}
        PIP_EXIT_CODE = {repr(pip_exit_code)}
        PIP_OUTPUT = {repr(pip_output)}
        PIP_MARKER = {repr(str(pip_marker) if pip_marker else '')}
        PIP_SLEEP = {repr(pip_sleep)}
        ENV_DUMP_FILE = {repr(str(env_dump_file) if env_dump_file else '')}
        VERSION = {repr(version)}
        IS_VENV_PYTHON = {repr(is_venv_python)}

        args = sys.argv[1:]
        if args == ['-c', 'import sys;print("%d.%d"%sys.version_info[:2])']:
            print(VERSION)
            sys.exit(0)

        if len(args) >= 2 and args[0] == '-c':
            code = args[1]
            if 'EXTERNALLY-MANAGED' in code:
                sys_dir = Path(sys.argv[0]).resolve().parent.parent / 'lib' / ('python' + VERSION)
                m = sys_dir / 'EXTERNALLY-MANAGED'
                print('1' if (not IS_VENV_PYTHON and m.is_file()) else '0')
                sys.exit(0)
            if 'import nsz' in code and 'import lz4' not in code:
                ok = bool(HAS_NSZ_STATE and Path(HAS_NSZ_STATE).is_file())
                sys.exit(0 if ok else 1)
            if 'import lz4' in code:
                need_nsz = 'nsz' in code
                ok = HAS_CORE_PKGS and (not need_nsz or (HAS_NSZ_STATE and Path(HAS_NSZ_STATE).is_file()))
                sys.exit(0 if ok else 1)

        if len(args) >= 3 and args[0] == '-m' and args[1] == 'pip' and args[2] == 'install':
            if PIP_MARKER:
                Path(PIP_MARKER).write_text(' '.join(args) + '\\n', encoding='utf-8')
            if ENV_DUMP_FILE:
                keys = ('http_proxy', 'HTTP_PROXY', 'https_proxy', 'HTTPS_PROXY', 'all_proxy', 'ALL_PROXY', 'no_proxy', 'NO_PROXY')
                Path(ENV_DUMP_FILE).write_text(json.dumps({{k: os.environ.get(k, '') for k in keys}}), encoding='utf-8')
            if PEP668_ON_PIP:
                sys.stderr.write('error: externally-managed-environment\\n')
                sys.stderr.write('\\n')
                sys.stderr.write('This environment is externally managed\\n')
                sys.stderr.flush()
                sys.exit(1)
            if PIP_SLEEP > 0:
                print('Collecting nsz...', flush=True)
                time.sleep(PIP_SLEEP)
            if PIP_OUTPUT:
                stream = sys.stdout if PIP_EXIT_CODE == 0 else sys.stderr
                stream.write(PIP_OUTPUT)
                if not PIP_OUTPUT.endswith('\\n'):
                    stream.write('\\n')
                stream.flush()
            if PIP_EXIT_CODE == 0 and HAS_NSZ_STATE:
                Path(HAS_NSZ_STATE).parent.mkdir(parents=True, exist_ok=True)
                Path(HAS_NSZ_STATE).write_text('installed\\n', encoding='utf-8')
            sys.exit(PIP_EXIT_CODE)

        sys.exit(0)
        """
    )
    return _write_exe(path, body)


class Pep668NszInstallTest(unittest.TestCase):
    def test_external_pep668_python_switches_to_app_venv_and_skips_repeat(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            ext_root = root / 'ext_python'
            (ext_root / 'lib' / 'python3.12').mkdir(parents=True, exist_ok=True)
            (ext_root / 'lib' / 'python3.12' / 'EXTERNALLY-MANAGED').write_text('[externally-managed]\n', encoding='utf-8')

            ext_pip_called = root / 'ext_pip_called.txt'
            ext_py = _make_fake_python_script(
                ext_root / 'bin' / 'python3',
                has_nsz_state=None,
                pep668_on_pip=True,
                pip_marker=ext_pip_called,
            )

            vdir = root / 'app_data' / 'venv'
            vpy_path = vdir / ('Scripts/python.exe' if pu.IS_WIN else 'bin/python3')
            venv_nsz_state = vdir / 'nsz_installed.flag'
            venv_pip_called = root / 'venv_pip_called.txt'
            venv_env_dump = root / 'venv_env.json'

            make_venv_calls: list[str] = []

            def fake_make_venv(base: str) -> bool:
                make_venv_calls.append(base)
                vdir.mkdir(parents=True, exist_ok=True)
                (vdir / 'pyvenv.cfg').write_text('home = /usr/bin\n', encoding='utf-8')
                _make_fake_python_script(
                    vpy_path,
                    has_nsz_state=venv_nsz_state,
                    has_core_pkgs=True,
                    pip_output='Collecting nsz\nInstalling collected packages: nsz\nSuccessfully installed nsz-5.0.0\n',
                    pip_marker=venv_pip_called,
                    env_dump_file=venv_env_dump,
                    is_venv_python=True,
                )
                rc, _, _ = nsz_setup.stream_command(
                    [str(vpy_path), '-m', 'pip', 'install', 'lz4', 'nsz'],
                    env=pu.proxy_env(pu.child_env()),
                    log=logs.append,
                )
                return rc == 0

            logs: list[str] = []
            with (
                mock.patch.object(pu, 'IS_WIN', False),
                mock.patch.object(pu, 'venv_dir', return_value=vdir),
                mock.patch.object(pu, 'venv_python', return_value=str(vpy_path)),
                mock.patch.object(pu, 'find_standalone_nsz', return_value=None),
                mock.patch.dict(os.environ, {'https_proxy': 'http://127.0.0.1:7890'}, clear=False),
            ):
                self.assertTrue(pu.has_externally_managed_marker(ext_py))
                self.assertFalse(pu.is_app_managed_python(ext_py))

                res = nsz_setup.ensure_nsz_for_build(
                    py=ext_py,
                    log=logs.append,
                    make_venv=fake_make_venv,
                    installing_notice='Installing nsz...',
                )

                self.assertTrue(res.ok, ''.join(logs))
                self.assertTrue(res.switched_venv)
                self.assertEqual(res.python_path, str(vpy_path))
                self.assertFalse(ext_pip_called.exists(), 'external PEP 668 python must never receive pip install')
                self.assertTrue(venv_pip_called.is_file(), 'app venv pip install should have run')
                self.assertEqual(make_venv_calls, [ext_py])
                joined = ''.join(logs)
                self.assertIn('Successfully installed nsz-5.0.0', joined)
                self.assertIn('isolated app venv', joined)

                # Proxy variables must be propagated in both cases to pip.
                dumped = venv_env_dump.read_text(encoding='utf-8')
                self.assertIn('"HTTPS_PROXY": "http://127.0.0.1:7890"', dumped)
                self.assertIn('"https_proxy": "http://127.0.0.1:7890"', dumped)

                # Subsequent build with external py reuses existing app venv immediately without reinstalling.
                venv_pip_called.unlink()
                logs_second: list[str] = []
                res2 = nsz_setup.ensure_nsz_for_build(
                    py=ext_py,
                    log=logs_second.append,
                    make_venv=lambda _b: self.fail('make_venv should not run when app venv already has nsz'),
                    installing_notice='Installing nsz...',
                )
                self.assertTrue(res2.ok)
                self.assertTrue(res2.switched_venv)
                self.assertEqual(res2.python_path, str(vpy_path))
                self.assertFalse(venv_pip_called.exists(), 'existing venv nsz should skip repeat pip install')
                self.assertIn('reusing app venv with nsz', ''.join(logs_second))

                # Subsequent build already pointed at vpy also skips immediately.
                logs_third: list[str] = []
                res3 = nsz_setup.ensure_nsz_for_build(
                    py=str(vpy_path),
                    log=logs_third.append,
                    make_venv=lambda _b: self.fail('make_venv should not run when vpy already imports nsz'),
                    installing_notice='Installing nsz...',
                )
                self.assertTrue(res3.ok)
                self.assertFalse(res3.switched_venv)
                self.assertEqual(res3.python_path, str(vpy_path))
                self.assertEqual(logs_third, [])

    def test_runtime_pep668_fallback_when_precheck_missed_marker(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            ext_py = _make_fake_python_script(
                root / 'weird_py' / 'bin' / 'python3',
                has_nsz_state=None,
                pep668_on_pip=True,
            )
            vdir = root / 'app_data' / 'venv'
            vpy_path = vdir / 'bin' / 'python3'
            venv_nsz_state = vdir / 'nsz_installed.flag'

            def fake_make_venv(_base: str) -> bool:
                vdir.mkdir(parents=True, exist_ok=True)
                (vdir / 'pyvenv.cfg').write_text('home = /usr/bin\n', encoding='utf-8')
                _make_fake_python_script(
                    vpy_path,
                    has_nsz_state=venv_nsz_state,
                    has_core_pkgs=True,
                    is_venv_python=True,
                )
                venv_nsz_state.write_text('ok\n', encoding='utf-8')
                return True

            logs: list[str] = []
            with (
                mock.patch.object(pu, 'IS_WIN', False),
                mock.patch.object(pu, 'venv_dir', return_value=vdir),
                mock.patch.object(pu, 'venv_python', return_value=str(vpy_path)),
                mock.patch.object(pu, 'is_app_managed_python', return_value=True),
                mock.patch.object(pu, 'has_externally_managed_marker', return_value=False),
                mock.patch.object(pu, 'find_standalone_nsz', return_value=None),
            ):
                res = nsz_setup.ensure_nsz_for_build(
                    py=ext_py,
                    log=logs.append,
                    make_venv=fake_make_venv,
                )
            self.assertTrue(res.ok, ''.join(logs))
            self.assertTrue(res.switched_venv)
            self.assertEqual(res.python_path, str(vpy_path))
            self.assertIn('externally-managed-environment', ''.join(logs))

    def test_existing_standalone_nsz_on_path_skips_install(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            py = _make_fake_python_script(root / 'bin' / 'python3', has_nsz_state=None)
            standalone = _write_exe(
                root / 'tools' / 'nsz',
                f'#!{sys.executable}\nimport sys\nprint("usage: nsz [--keys KEYS]")\n',
            )
            logs: list[str] = []
            with (
                mock.patch.object(pu, 'venv_dir', return_value=root / 'venv'),
                mock.patch.object(pu, 'venv_python', return_value=str(root / 'venv' / 'bin' / 'python3')),
                mock.patch.dict(os.environ, {'PATH': str(Path(standalone).parent)}, clear=False),
            ):
                res = nsz_setup.ensure_nsz_for_build(
                    py=py,
                    log=logs.append,
                    make_venv=lambda _b: self.fail('should not create venv when standalone nsz works'),
                )
            self.assertTrue(res.ok)
            self.assertEqual(res.python_path, py)
            self.assertIn('using standalone nsz on PATH', ''.join(logs))

    def test_install_failure_captures_stderr_and_diagnoses_root_cause(self) -> None:
        scenarios = [
            (
                'network',
                'WARNING: Retrying after connection broken by NewConnectionError\nERROR: Could not find a version that satisfies the requirement nsz\n',
                'Network or proxy error',
            ),
            (
                'permission',
                "PermissionError: [Errno 13] Permission denied: '/app/venv/lib/site-packages/nsz'\n",
                'Permission denied',
            ),
            (
                'pep668',
                'error: externally-managed-environment\nThis environment is externally managed\n',
                'PEP 668',
            ),
        ]
        for expected_kind, stderr_text, expected_guidance in scenarios:
            with self.subTest(kind=expected_kind), tempfile.TemporaryDirectory() as td:
                root = Path(td)
                vdir = root / 'app_data' / 'venv'
                vpy = _make_fake_python_script(
                    vdir / 'bin' / 'python3',
                    has_nsz_state=None,
                    pip_exit_code=1,
                    pip_output=stderr_text,
                    is_venv_python=True,
                )
                (vdir / 'pyvenv.cfg').write_text('home = /usr/bin\n', encoding='utf-8')
                logs: list[str] = []
                with (
                    mock.patch.object(pu, 'IS_WIN', False),
                    mock.patch.object(pu, 'venv_dir', return_value=vdir),
                    mock.patch.object(pu, 'venv_python', return_value=vpy),
                    mock.patch.object(pu, 'find_standalone_nsz', return_value=None),
                ):
                    res = nsz_setup.ensure_nsz_for_build(
                        py=vpy,
                        log=logs.append,
                        make_venv=lambda _b: False,
                    )
                joined = ''.join(logs)
                self.assertFalse(res.ok)
                self.assertEqual(res.error_kind, expected_kind)
                self.assertIn(stderr_text.splitlines()[0], joined)
                self.assertIn(expected_guidance, joined)

    def test_cancellation_stops_pip_subprocess_promptly(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            vdir = root / 'app_data' / 'venv'
            vpy = _make_fake_python_script(
                vdir / 'bin' / 'python3',
                has_nsz_state=None,
                pip_sleep=15.0,
                is_venv_python=True,
            )
            (vdir / 'pyvenv.cfg').write_text('home = /usr/bin\n', encoding='utf-8')
            logs: list[str] = []
            cancelled = False

            def on_log(line: str) -> None:
                nonlocal cancelled
                logs.append(line)
                if 'Collecting nsz' in line:
                    cancelled = True

            t0 = time.monotonic()
            with (
                mock.patch.object(pu, 'IS_WIN', False),
                mock.patch.object(pu, 'venv_dir', return_value=vdir),
                mock.patch.object(pu, 'venv_python', return_value=vpy),
                mock.patch.object(pu, 'find_standalone_nsz', return_value=None),
            ):
                res = nsz_setup.ensure_nsz_for_build(
                    py=vpy,
                    log=on_log,
                    make_venv=lambda _b: False,
                    is_cancelled=lambda: cancelled,
                )
            elapsed = time.monotonic() - t0
            self.assertFalse(res.ok)
            self.assertTrue(res.cancelled)
            self.assertLess(elapsed, 4.0)

    def test_proxy_env_falls_back_to_system_proxies_and_pairs_keys(self) -> None:
        clean_base = {'PATH': '/usr/bin'}
        from_sys = pu.proxy_env(
            clean_base,
            system_proxies={'https': 'http://127.0.0.1:8888', 'no': 'localhost,127.0.0.1'},
        )
        self.assertEqual(from_sys['https_proxy'], 'http://127.0.0.1:8888')
        self.assertEqual(from_sys['HTTPS_PROXY'], 'http://127.0.0.1:8888')
        self.assertEqual(from_sys['no_proxy'], 'localhost,127.0.0.1')
        self.assertEqual(from_sys['NO_PROXY'], 'localhost,127.0.0.1')

        paired = pu.proxy_env({'PATH': '/usr/bin', 'ALL_PROXY': 'socks5h://127.0.0.1:1080'}, system_proxies={'http': 'http://ignored:1'})
        self.assertEqual(paired['all_proxy'], 'socks5h://127.0.0.1:1080')
        self.assertEqual(paired['ALL_PROXY'], 'socks5h://127.0.0.1:1080')
        self.assertNotIn('http_proxy', paired)

    def test_existing_app_venv_missing_only_nsz_installs_nsz_without_rebuild(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            ext_root = root / 'ext_python'
            (ext_root / 'lib' / 'python3.12').mkdir(parents=True, exist_ok=True)
            (ext_root / 'lib' / 'python3.12' / 'EXTERNALLY-MANAGED').write_text('[externally-managed]\n', encoding='utf-8')
            ext_py = _make_fake_python_script(
                ext_root / 'bin' / 'python3',
                has_nsz_state=None,
                pep668_on_pip=True,
            )

            vdir = root / 'app_data' / 'venv'
            vdir.mkdir(parents=True, exist_ok=True)
            (vdir / 'pyvenv.cfg').write_text('home = /usr/bin\n', encoding='utf-8')
            venv_nsz_state = vdir / 'nsz_installed.flag'
            vpy = _make_fake_python_script(
                vdir / 'bin' / 'python3',
                has_nsz_state=venv_nsz_state,
                has_core_pkgs=True,
                pip_output='Successfully installed nsz-5.0.0\n',
                is_venv_python=True,
            )
            logs: list[str] = []
            with (
                mock.patch.object(pu, 'IS_WIN', False),
                mock.patch.object(pu, 'venv_dir', return_value=vdir),
                mock.patch.object(pu, 'venv_python', return_value=vpy),
                mock.patch.object(pu, 'find_standalone_nsz', return_value=None),
            ):
                res = nsz_setup.ensure_nsz_for_build(
                    py=ext_py,
                    log=logs.append,
                    make_venv=lambda _b: self.fail('should not rebuild existing venv when only nsz is missing'),
                )
            self.assertTrue(res.ok, ''.join(logs))
            self.assertTrue(res.switched_venv)
            self.assertEqual(res.python_path, vpy)
            self.assertIn('Successfully installed nsz-5.0.0', ''.join(logs))

    @unittest.skipIf(Model is None, 'PySide6 is not installed')
    def test_make_venv_streams_venv_creation_failure_and_diagnoses_ensurepip(self) -> None:
        import types

        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            vdir = root / 'app_data' / 'venv'
            vpy = vdir / 'bin' / 'python3'
            base_py = _write_exe(
                root / 'sys' / 'python3',
                textwrap.dedent(
                    f"""\
                    #!{sys.executable}
                    import sys
                    args = sys.argv[1:]
                    if args == ['-c', 'import sys;print("%d.%d"%sys.version_info[:2])']:
                        print('3.12')
                        sys.exit(0)
                    if args[:2] == ['-m', 'venv']:
                        sys.stderr.write('The virtual environment was not created successfully because ensurepip is not available.\\n')
                        sys.stderr.flush()
                        sys.exit(1)
                    sys.exit(0)
                    """
                ),
            )
            logs: list[str] = []
            fake = types.SimpleNamespace(log=logs.append)
            with (
                mock.patch.object(pu, 'IS_WIN', False),
                mock.patch.object(pu, 'venv_dir', return_value=vdir),
                mock.patch.object(pu, 'venv_python', return_value=str(vpy)),
                mock.patch.object(pu, 'python_candidates', return_value=[]),
            ):
                ok = Model._make_venv(fake, base_py)
            joined = ''.join(logs)
            self.assertFalse(ok)
            self.assertIn('ensurepip is not available', joined)
            self.assertIn('python3-venv', joined)

    @unittest.skipIf(Model is None, 'PySide6 is not installed')
    def test_model_start_build_switches_external_pep668_python_to_venv(self) -> None:
        from nspb_qt import model as model_mod

        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            eng = root / 'engine'
            (eng / 'scripts').mkdir(parents=True)
            (eng / 'dm' / 'tools' / 'nx_extract').mkdir(parents=True)
            (eng / 'dm' / 'tools' / 'nx_extract' / 'Program.cs').write_text('// stub\n', encoding='utf-8')
            out_ipa = root / 'out' / '0100000000010000.ipa'
            (eng / 'scripts' / 'build_ipa_from_nsp.py').write_text(
                textwrap.dedent(
                    f"""\
                    import sys
                    from pathlib import Path
                    # supports '--work-dir'
                    print('[1/1] Done with ' + sys.executable, flush=True)
                    Path({repr(str(out_ipa))}).parent.mkdir(parents=True, exist_ok=True)
                    Path({repr(str(out_ipa))}).write_bytes(b'IPA')
                    """
                ),
                encoding='utf-8',
            )
            nsz_file = root / 'Game [0100000000010000].nsz'
            nsz_file.write_bytes(b'nsz')
            keys_file = root / 'prod.keys'
            keys_file.write_text('header_key = ' + '0' * 64 + '\n', encoding='utf-8')

            ext_root = root / 'ext_py'
            (ext_root / 'lib' / 'python3.12').mkdir(parents=True, exist_ok=True)
            (ext_root / 'lib' / 'python3.12' / 'EXTERNALLY-MANAGED').write_text('[externally-managed]\n', encoding='utf-8')
            ext_py = _make_fake_python_script(
                ext_root / 'bin' / 'python3',
                has_nsz_state=None,
                pep668_on_pip=True,
            )

            vdir = root / 'app_data' / 'venv'
            vpy_path = vdir / 'bin' / 'python3'
            venv_nsz_state = vdir / 'nsz_installed.flag'

            def fake_make_venv(_self, _base: str, dep=None) -> bool:
                vdir.mkdir(parents=True, exist_ok=True)
                (vdir / 'pyvenv.cfg').write_text('home = /usr/bin\n', encoding='utf-8')
                _make_fake_python_script(
                    vpy_path,
                    has_nsz_state=venv_nsz_state,
                    has_core_pkgs=True,
                    is_venv_python=True,
                )
                venv_nsz_state.write_text('ok\n', encoding='utf-8')
                _self.log('installed nsz into app venv\n')
                return True

            seen_build_cmds: list[list[str]] = []
            real_popen = subprocess.Popen

            def spy_popen(cmd, *a, **kw):
                cmd_list = [str(x) for x in cmd]
                if any('build_ipa_from_nsp.py' in x for x in cmd_list):
                    seen_build_cmds.append(cmd_list)
                    # Execute the stub build script using real host python while passing arg0 info via env/args
                    return real_popen([sys.executable, *cmd_list[1:]], *a, **kw)
                return real_popen(cmd, *a, **kw)

            with (
                mock.patch.object(Model, 'check_deps', lambda self: None),
                mock.patch.object(pu, 'IS_WIN', False),
                mock.patch.object(pu, 'venv_dir', return_value=vdir),
                mock.patch.object(pu, 'venv_python', return_value=str(vpy_path)),
                mock.patch.object(pu, 'find_python', return_value=(ext_py, True, '3.12')),
                mock.patch.object(pu, 'find_standalone_nsz', return_value=None),
                mock.patch.object(model_mod.engine, 'needs_sync_before_build', return_value=False),
                mock.patch.object(Model, 'prebuild_block_reason', return_value=''),
                mock.patch.object(Model, '_make_venv', fake_make_venv),
                mock.patch.object(model_mod.subprocess, 'Popen', side_effect=spy_popen),
                mock.patch.object(model_mod.threading, 'Thread', side_effect=lambda *, target, daemon: mock.Mock(start=target)),
            ):
                m = Model()
                logged: list[str] = []
                outcomes: list[tuple[bool, str]] = []
                m.logAppended.connect(logged.append)
                m.finished.connect(lambda ok, msg: outcomes.append((ok, msg)))
                m.repo_path = str(eng)
                m.base_path = str(nsz_file)
                m.keys_path = str(keys_file)
                m.out_dir = str(root / 'out')
                m.target = 'ios'
                m.ipa_kind = 'oneGame'

                m.start_build()

            self.assertTrue(outcomes and outcomes[-1][0], f'build failed: {outcomes}, logs={"".join(logged)}')
            self.assertEqual(len(seen_build_cmds), 1)
            self.assertEqual(seen_build_cmds[0][0], str(vpy_path))
            self.assertEqual(m.python_path, str(vpy_path))
            self.assertIn('installed nsz into app venv', ''.join(logged))

    def test_failure_message_spec_maps_all_error_kinds(self) -> None:
        self.assertEqual(
            nsz_setup.failure_message_spec(
                nsz_setup.NszEnsureResult(ok=False, python_path='/usr/bin/python3', error_kind='pep668'),
                '/fallback/py',
            ),
            ('msg.nszFailedPEP668', ('/usr/bin/python3',)),
        )
        self.assertEqual(
            nsz_setup.failure_message_spec(
                nsz_setup.NszEnsureResult(ok=False, python_path='/usr/bin/python3', error_kind='permission'),
                '/fallback/py',
                venv_dir='/data/venv',
            ),
            ('msg.nszFailedPermission', ('/data/venv',)),
        )
        self.assertEqual(
            nsz_setup.failure_message_spec(
                nsz_setup.NszEnsureResult(ok=False, python_path='/usr/bin/python3', error_kind='network'),
                '/fallback/py',
            ),
            ('msg.nszFailedNetwork', ()),
        )
        self.assertEqual(
            nsz_setup.failure_message_spec(
                nsz_setup.NszEnsureResult(ok=False, python_path='', error_kind='other'),
                '/fallback/py',
            ),
            ('msg.nszFailed', ('/fallback/py',)),
        )

    def test_case_insensitive_path_checks_use_normcase(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            vdir = root / 'AppData' / 'Venv'
            vpy = vdir / 'Scripts' / 'python.exe'
            vpy.parent.mkdir(parents=True, exist_ok=True)
            vpy.write_text('', encoding='utf-8')
            lower_vpy = Path(str(vpy).lower())

            with mock.patch.object(os.path, 'normcase', side_effect=lambda s: s.lower()):
                self.assertTrue(pu._is_under_dir(lower_vpy, vdir))
                with (
                    mock.patch.object(pu, 'venv_dir', return_value=vdir),
                    mock.patch.object(pu, 'venv_python', return_value=str(vpy)),
                    mock.patch.object(pu, 'find_standalone_nsz', return_value=None),
                    mock.patch.object(pu, '_runs', return_value=False),
                    mock.patch.object(pu, 'is_app_managed_python', return_value=True),
                    mock.patch.object(pu, 'has_externally_managed_marker', return_value=False),
                    mock.patch.object(nsz_setup, '_python_usable_for_app_venv', side_effect=AssertionError('must skip same interpreter regardless of case')),
                    mock.patch.object(nsz_setup, '_install_nsz_into_python', return_value=(False, False, 'network timeout')),
                ):
                    res = nsz_setup.ensure_nsz_for_build(
                        py=str(lower_vpy),
                        log=lambda _m: None,
                        make_venv=lambda _b: False,
                    )
                    self.assertFalse(res.ok)
                    self.assertEqual(res.error_kind, 'network')

    @unittest.skipIf(Model is None, 'PySide6 is not installed')
    def test_make_venv_uses_process_group_and_cleans_partial_new_venv_on_cancel(self) -> None:
        import types

        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            vdir = root / 'app_data' / 'venv'
            vpy = vdir / 'bin' / 'python3'
            base_py = _write_exe(
                root / 'sys' / 'python3',
                textwrap.dedent(
                    f"""\
                    #!{sys.executable}
                    import sys
                    from pathlib import Path
                    args = sys.argv[1:]
                    if args == ['-c', 'import sys;print("%d.%d"%sys.version_info[:2])']:
                        print('3.12')
                        sys.exit(0)
                    if args[:2] == ['-m', 'venv']:
                        target = Path(args[2])
                        (target / 'bin').mkdir(parents=True, exist_ok=True)
                        stub = target / 'bin' / 'python3'
                        stub.write_text('#!{sys.executable}\\nimport sys, time\\nif sys.argv[1:2] == ["-c"]:\\n print("3.12"); sys.exit(0)\\nprint("Collecting...", flush=True)\\ntime.sleep(5)\\n', encoding='utf-8')
                        stub.chmod(0o755)
                        sys.exit(0)
                    sys.exit(0)
                    """
                ),
            )
            logs: list[str] = []
            seen_kwargs: list[dict] = []
            real_popen = subprocess.Popen

            fake = types.SimpleNamespace(
                log=logs.append,
                _pip_args=lambda pkgs, wheels: ['install', *pkgs],
                bundled_wheels=lambda: None,
                _build_cancelled=False,
                _proc=None,
            )

            def spy_popen(cmd, *a, **kw):
                cmd_list = [str(x) for x in cmd]
                if len(cmd_list) >= 3 and cmd_list[1:3] == ['-m', 'pip']:
                    seen_kwargs.append(dict(kw))
                    fake._build_cancelled = True
                return real_popen(cmd, *a, **kw)

            from nspb_qt import model as model_mod
            with (
                mock.patch.object(pu, 'IS_WIN', False),
                mock.patch.object(pu, 'venv_dir', return_value=vdir),
                mock.patch.object(pu, 'venv_python', return_value=str(vpy)),
                mock.patch.object(pu, 'python_candidates', return_value=[]),
                mock.patch.object(model_mod.subprocess, 'Popen', side_effect=spy_popen),
            ):
                ok = Model._make_venv(fake, base_py)

            self.assertFalse(ok)
            self.assertTrue(seen_kwargs, 'pip Popen should have been called')
            self.assertTrue(seen_kwargs[0].get('start_new_session'), f'expected process_group_kwargs, got {seen_kwargs[0]}')
            self.assertFalse(vdir.exists(), 'newly created partial venv must be cleaned up when pip is cancelled')


if __name__ == '__main__':
    unittest.main()
