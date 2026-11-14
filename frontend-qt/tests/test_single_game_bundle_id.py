"""Regression tests for single-game iOS bundle ID resolution in build_app.py (Issue #1143 Option A)."""
from __future__ import annotations

import inspect
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
QT = HERE.parent
sys.path.insert(0, str(QT))

from nspb_qt.win import build_app  # noqa: E402


class SingleGameBundleIDTests(unittest.TestCase):
    GAME = '0100ABCD12340000'

    def test_real_team_id_appends_team_suffix(self) -> None:
        self.assertEqual(
            build_app.resolve_bundle_id(self.GAME, {'DM_TEAM_ID': 'TEAM123456'}),
            'org.nxnative.0100abcd12340000.TEAM123456',
        )

    def test_placeholder_team_id_keeps_bare_bundle_id(self) -> None:
        self.assertEqual(
            build_app.resolve_bundle_id(self.GAME, {'DM_TEAM_ID': '0000000000'}),
            'org.nxnative.0100abcd12340000',
        )

    def test_empty_or_unset_team_id_keeps_bare_bundle_id(self) -> None:
        for env in ({}, {'DM_TEAM_ID': ''}, {'DM_TEAM_ID': '   '}):
            with self.subTest(env=env):
                self.assertEqual(
                    build_app.resolve_bundle_id(self.GAME, env),
                    'org.nxnative.0100abcd12340000',
                )

    def test_explicit_dm_bundle_id_overrides_team_suffix(self) -> None:
        self.assertEqual(
            build_app.resolve_bundle_id(
                self.GAME,
                {'DM_BUNDLE_ID': 'com.example.custom', 'DM_TEAM_ID': 'TEAM123456'},
            ),
            'com.example.custom',
        )

    def test_framework_only_keeps_bare_base_without_team_suffix(self) -> None:
        self.assertEqual(
            build_app.resolve_bundle_id(
                self.GAME,
                {'DM_TEAM_ID': 'TEAM123456', 'DM_FRAMEWORK_ONLY': '1'},
            ),
            'org.nxnative.0100abcd12340000',
        )

    def test_main_calls_resolve_bundle_id_and_defaults_stay_unchanged(self) -> None:
        main_src = inspect.getsource(build_app.main)
        self.assertIn('resolve_bundle_id(game, env)', main_src)
        self.assertEqual(
            inspect.signature(build_app.link).parameters['bundle_id'].default,
            'org.nxnative.app',
        )
        self.assertEqual(
            inspect.signature(build_app.link_framework).parameters['bundle_id'].default,
            'org.nxnative.app.DmGame',
        )


if __name__ == '__main__':
    unittest.main()
