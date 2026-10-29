"""Issues #75 and #113: a venv below the script's floor, and Pythons that mise or asdf manage.

    python3 -m unittest discover -s frontend-qt/tests
"""
from __future__ import annotations

import os
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'frontend-qt'))

from nspb_qt import platform_util as pu  # noqa: E402


def _exe(path: Path) -> str:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text('#!/bin/sh\n')
    path.chmod(0o755)
    return str(path)


class StaleVenvTest(unittest.TestCase):
    def test_a_3_9_venv_is_not_returned_as_ready(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            vpy = _exe(Path(td) / 'venv' / 'bin' / 'python3')
            with mock.patch.object(pu, 'IS_WIN', False), \
                    mock.patch.object(pu, 'venv_python', return_value=vpy), \
                    mock.patch.object(pu, '_which', return_value=None), \
                    mock.patch.object(pu, 'version_manager_pythons', return_value=[]), \
                    mock.patch.object(pu, '_python_version', return_value='3.9'), \
                    mock.patch.object(pu, '_runs', return_value=True):
                py, ok, ver = pu.find_python()
        self.assertFalse(ok, 'a 3.9 venv with every package is still below the floor')
        self.assertEqual((py, ver), (vpy, '3.9'), 'the row can say which version is too old')

    def test_a_newer_interpreter_wins_over_a_stale_venv(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            vpy = _exe(Path(td) / 'venv' / 'bin' / 'python3')
            new = _exe(Path(td) / 'mise' / 'python3.12')
            versions = {vpy: '3.9', new: '3.12'}
            with mock.patch.object(pu, 'IS_WIN', False), \
                    mock.patch.object(pu, 'venv_python', return_value=vpy), \
                    mock.patch.object(pu, '_which', return_value=None), \
                    mock.patch.object(pu, 'version_manager_pythons', return_value=[new]), \
                    mock.patch.object(pu, '_python_version', side_effect=lambda p: versions.get(p, '')), \
                    mock.patch.object(pu, '_runs', return_value=True):
                py, ok, ver = pu.find_python()
        self.assertEqual((py, ok, ver), (new, True, '3.12'))


class VersionManagerPythonsTest(unittest.TestCase):
    def test_mise_installs_shims_and_asdf_installs_are_candidates(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            install = _exe(root / 'mise' / 'installs' / 'python' / '3.12.8' / 'bin' / 'python3')
            minor = _exe(root / 'mise' / 'installs' / 'python' / '3.12.8' / 'bin' / 'python3.12')
            config = _exe(root / 'mise' / 'installs' / 'python' / '3.12.8' / 'bin' / 'python3-config')
            shim = _exe(root / 'mise' / 'shims' / 'python3')
            asdf = _exe(root / 'asdf' / 'installs' / 'python' / '3.13.1' / 'bin' / 'python3')
            env = {'MISE_DATA_DIR': str(root / 'mise'), 'ASDF_DATA_DIR': str(root / 'asdf')}
            with mock.patch.object(pu, 'IS_WIN', False), mock.patch.dict(os.environ, env):
                cands = pu.version_manager_pythons()
        for p in (install, minor, shim, asdf):
            self.assertIn(p, cands)
        self.assertNotIn(config, cands, 'python3-config is not an interpreter')


try:
    from nspb_qt.model import Model
except ImportError:          # PySide6 is not installed
    Model = None


@unittest.skipIf(Model is None, 'PySide6 is not installed')
class MakeVenvTest(unittest.TestCase):
    def _run(self, venv_ver: str, base: str | None):
        logs: list[str] = []
        fake = types.SimpleNamespace(log=logs.append)
        with tempfile.TemporaryDirectory() as td:
            vdir = Path(td) / 'venv'
            vpy = _exe(vdir / 'bin' / 'python3')
            base_py = base if base is not None else vpy
            if base is not None:
                base_py = _exe(Path(td) / 'base' / 'python3.12')
            versions = {base_py: '3.12'} if base is not None else {}
            versions[vpy] = venv_ver
            with mock.patch.object(pu, 'venv_dir', return_value=vdir), \
                    mock.patch.object(pu, 'venv_python', return_value=vpy), \
                    mock.patch.object(pu, '_python_version', side_effect=lambda p: versions.get(p, '')), \
                    mock.patch.object(pu, 'python_candidates', return_value=[]), \
                    mock.patch.object(pu, '_runs', return_value=False):
                ok = Model._make_venv(fake, base_py)
            return ok, sorted(p.name for p in Path(td).iterdir()), logs

    def test_a_too_old_venv_is_renamed_not_deleted(self) -> None:
        ok, names, _ = self._run('3.9', 'new')
        self.assertFalse(ok)       # venv creation is mocked to fail: the move is what is tested
        self.assertEqual(len([n for n in names if n.startswith('venv.old-')]), 1, names)

    def test_a_too_old_venv_stays_when_there_is_no_newer_base(self) -> None:
        ok, names, logs = self._run('3.9', None)
        self.assertFalse(ok)
        self.assertEqual(names, ['venv'])
        self.assertTrue(any('no newer Python' in line for line in logs))


if __name__ == '__main__':
    unittest.main()
