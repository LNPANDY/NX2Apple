"""Tests for build_seed_cache .img.zst support, pure-Python seed_compression, and SeedCompressionDialog.

CRITICAL: All core tests run cleanly without PySide6 installed (Linux CI launcher-qt).
"""
from __future__ import annotations

import ast
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

os.environ.setdefault('QT_QPA_PLATFORM', 'offscreen')

ROOT = Path(__file__).resolve().parents[2]
QT_DIR = ROOT / 'frontend-qt'
ENGINE_DIR = ROOT / 'engine'
if str(QT_DIR) not in sys.path:
    sys.path.insert(0, str(QT_DIR))

from nspb_qt import build_seed_cache  # noqa: E402
from nspb_qt import seed_compression as sc  # noqa: E402

try:
    from PySide6.QtWidgets import QApplication
    from nspb_qt import seed_compression_dialog as scd
    from nspb_qt.model import Model
    from nspb_qt.i18n import Lang
    from nspb_qt.ui import MainWindow
    HAS_QT = True
except ImportError:
    QApplication = None
    scd = None
    Model = None
    Lang = None
    MainWindow = None
    HAS_QT = False


def _make_fake_dmromfs(payload: bytes = b'SHADER_DATA') -> bytes:
    """Create a minimal valid file starting with DMROMFS1 magic for scanner/compressor tests."""
    # Pack via engine shader_lib when available so real compress-seeds validates DMROMFS1 + full stream
    dm_tools = ENGINE_DIR / 'dm' / 'tools'
    if (dm_tools / 'shader_lib.py').is_file():
        if str(dm_tools) not in sys.path:
            sys.path.insert(0, str(dm_tools))
        import shader_lib  # type: ignore
        with tempfile.TemporaryDirectory() as td:
            out_p = Path(td) / 'tmp.img'
            shader_lib.write(
                {
                    '0000000000000001_b.metal': b'vertex float4 v() { return 0; }\n' + payload,
                    'inputs.tsv': b'inputs\tst\n',
                },
                str(out_p),
            )
            return out_p.read_bytes()
    return b'DMROMFS1' + b'\x00' * 56 + payload


class SeedCompressionCoreTests(unittest.TestCase):
    """Pure-Python tests (zero PySide6 required)."""

    def setUp(self) -> None:
        self._td = tempfile.TemporaryDirectory()
        self.tmp = Path(self._td.name)

    def tearDown(self) -> None:
        self._td.cleanup()

    def _create_seed(
        self,
        seed_root: Path,
        tid: str,
        *,
        app_name: str = 'Test Game',
        chain: str = '1122334455667788',
        legacy_img: bool = True,
        zst_img: bool = False,
        multi_program: bool = False,
    ) -> Path:
        sdir = seed_root / tid.upper()
        (sdir / 'ExeFS').mkdir(parents=True, exist_ok=True)
        (sdir / 'ExeFS' / 'main').write_bytes(b'MAIN')
        (sdir / 'shader' / 'pkg').mkdir(parents=True, exist_ok=True)
        (sdir / 'shader' / 'ios').mkdir(parents=True, exist_ok=True)
        (sdir / 'shader' / 'tables').mkdir(parents=True, exist_ok=True)
        (sdir / 'shader' / 'tables' / 'c1_full.tsv').write_text('# c1\n', encoding='utf-8')
        (sdir / 'shader' / 'tables' / 'cb_extent.tsv').write_text('# cb\n', encoding='utf-8')
        (sdir / 'seed.json').write_text(
            json.dumps({
                'schema': 1,
                'title_id': tid.upper(),
                'app_name': app_name,
                'gfx_api': 'nvn',
                'chain': chain,
            }),
            encoding='utf-8',
        )

        ms_dir = sdir / 'metal-sources'
        targets = [ms_dir / 'p0', ms_dir / 'p1'] if multi_program else [ms_dir]
        raw_bytes = _make_fake_dmromfs(b'X' * 4096)
        for tdir in targets:
            tdir.mkdir(parents=True, exist_ok=True)
            if legacy_img:
                (tdir / f'b-{chain}.img').write_bytes(raw_bytes)
            if zst_img:
                (tdir / f'b-{chain}.img.zst').write_bytes(b'\x28\xb5\x2f\xfdZST_PAYLOAD')
        return sdir

    def test_pure_python_modules_have_zero_pyside6_imports(self) -> None:
        for rel in ('build_seed_cache.py', 'seed_compression.py'):
            src = (QT_DIR / 'nspb_qt' / rel).read_text(encoding='utf-8')
            tree = ast.parse(src, filename=rel)
            for node in ast.walk(tree):
                if isinstance(node, ast.Import):
                    for alias in node.names:
                        self.assertFalse(alias.name.startswith('PySide6'), f'{rel} must not import PySide6')
                elif isinstance(node, ast.ImportFrom) and node.module:
                    self.assertFalse(node.module.startswith('PySide6'), f'{rel} must not import PySide6')

    def test_build_seed_cache_supports_img_zst_and_legacy_img(self) -> None:
        seed_root = self.tmp / 'seeds'
        tid_both = '0100000000010001'
        tid_legacy = '0100000000010002'
        tid_zst = '0100000000010003'
        chain = 'aabbccddeeff0011'

        s_both = self._create_seed(seed_root, tid_both, chain=chain, legacy_img=True, zst_img=True, multi_program=True)
        s_leg = self._create_seed(seed_root, tid_legacy, chain=chain, legacy_img=True, zst_img=False)
        s_zst = self._create_seed(seed_root, tid_zst, chain=chain, legacy_img=False, zst_img=True)

        # Ignored temp files must never be reported
        (s_zst / 'metal-sources' / f'b-{chain}.img.zst.tmp').write_bytes(b'TEMP')

        # When both .img and .img.zst exist, .img.zst wins per stem
        both_archives = build_seed_cache.metal_sources_archives(s_both)
        self.assertEqual(
            [p.relative_to(s_both / 'metal-sources').as_posix() for p in both_archives],
            [f'p0/b-{chain}.img.zst', f'p1/b-{chain}.img.zst'],
        )
        self.assertEqual(
            build_seed_cache.resolve_metal_sources_archive(s_both / 'metal-sources' / 'p0', chain),
            s_both / 'metal-sources' / 'p0' / f'b-{chain}.img.zst',
        )

        # Legacy-only .img still recognized
        self.assertEqual(
            [p.name for p in build_seed_cache.metal_sources_archives(s_leg)],
            [f'b-{chain}.img'],
        )
        self.assertEqual(
            build_seed_cache.resolve_metal_sources_archive(s_leg / 'metal-sources', chain),
            s_leg / 'metal-sources' / f'b-{chain}.img',
        )

        # .img.zst-only inspect_seed + prefill_candidates
        info_zst = build_seed_cache.inspect_seed(seed_root, tid_zst)
        self.assertTrue(info_zst['valid'])
        self.assertTrue(info_zst['has_metal_sources'])

        info_leg = build_seed_cache.inspect_seed(seed_root, tid_legacy)
        self.assertTrue(info_leg['valid'])
        self.assertTrue(info_leg['has_metal_sources'])

        cands = build_seed_cache.prefill_candidates(tid_zst, None, work_dir=s_zst / 'metal-sources')
        # Add msl dir directly under work_dir/msl with .img.zst
        work_dir = self.tmp / 'work_prefill'
        msl_dir = work_dir / 'msl'
        msl_dir.mkdir(parents=True)
        (msl_dir / f'b-{chain}.img.zst').write_bytes(b'ZST')
        cands = build_seed_cache.prefill_candidates(tid_zst, None, work_dir=work_dir)
        self.assertIn(msl_dir, cands)

    def test_scan_uncompressed_local_fallback_and_json_parse(self) -> None:
        seed_root = self.tmp / 'seeds'
        tid1 = '01007EF00011E000'
        tid2 = '0100F2C0115B6000'
        tid3 = '0100000000010000'
        self._create_seed(seed_root, tid1, app_name='Zelda BOTW', legacy_img=True, zst_img=False)
        self._create_seed(seed_root, tid2, app_name='Zelda TOTK', legacy_img=True, zst_img=False, multi_program=True)
        self._create_seed(seed_root, tid3, app_name='Mario Odyssey', legacy_img=False, zst_img=True)

        # Temp files and symlinks must be skipped safely
        (seed_root / tid1 / 'metal-sources' / 'b-temp.img.tmp').write_bytes(b'IGNORED')
        if hasattr(os, 'symlink'):
            try:
                os.symlink(seed_root / tid1 / 'metal-sources' / 'b-1122334455667788.img', seed_root / tid3 / 'metal-sources' / 'b-link.img')
            except OSError:
                pass

        # Force fallback by pointing engine_path at a dir without build_seed.py
        summary = sc.scan_uncompressed(
            seed_root=seed_root,
            engine_path=self.tmp / 'no_engine',
            game_names={tid1: '旷野之息'},
        )
        self.assertTrue(summary.used_fallback)
        self.assertEqual(summary.total_seed_games, 3)
        self.assertEqual(summary.total_games, 2)
        self.assertEqual(summary.total_files, 3)
        self.assertEqual(summary.games[0].title_id, tid2)   # 2 files -> larger uncompressed_bytes first
        self.assertEqual(summary.games[1].display_name, '旷野之息')
        self.assertGreater(summary.estimated_saved_bytes, 0)
        self.assertGreaterEqual(summary.estimated_saved_pct, 90)

        # parse_scan_json matches CLI contract
        parsed = sc.parse_scan_json(
            {
                'seed_root': str(seed_root),
                'zstd_available': True,
                'total_games': 1,
                'total_files': 2,
                'uncompressed_bytes': 1000,
                'estimated_compressed_bytes': 80,
                'estimated_saved_bytes': 920,
                'games': [
                    {
                        'title_id': tid1,
                        'app_name': 'BotW',
                        'files': ['b-1.img', 'p1/b-1.img'],
                        'uncompressed_bytes': 1000,
                        'estimated_compressed_bytes': 80,
                    }
                ],
            },
            game_names={tid1: 'BotW Custom'},
            total_seed_games=4,
        )
        self.assertTrue(parsed.zstd_available)
        self.assertEqual(parsed.total_seed_games, 4)
        self.assertEqual(parsed.games[0].label, 'BotW Custom')
        self.assertEqual(parsed.estimated_saved_pct, 92)

    def test_ndjson_parser_and_state_machine_transitions(self) -> None:
        self.assertIsNone(sc.parse_ndjson_line(''))
        self.assertIsNone(sc.parse_ndjson_line('not json'))
        self.assertIsNone(sc.parse_ndjson_line('{"foo": 1}'))

        ev = sc.parse_ndjson_line('{"event":"item_done","index":1,"total_games":2,"title_id":"01007EF00011E000","before_bytes":1000,"after_bytes":100,"saved_bytes":900,"files_compressed":1}')
        self.assertIsNotNone(ev)
        assert ev is not None
        self.assertEqual(ev['event'], 'item_done')

        summary = sc.SeedScanSummary(
            seed_root=str(self.tmp),
            zstd_available=True,
            total_games=2,
            total_files=2,
            uncompressed_bytes=3000,
            estimated_compressed_bytes=240,
            estimated_saved_bytes=2760,
            games=[
                sc.SeedGameScanItem('0100000000000001', 'Game 1', ['b-1.img'], 2000, 160, 'Game 1'),
                sc.SeedGameScanItem('0100000000000002', 'Game 2', ['b-2.img'], 1000, 80, 'Game 2'),
            ],
            total_seed_games=2,
        )
        st = sc.SeedCompressionState(summary)
        self.assertEqual(st.stage, 'prompt')

        st.begin_running()
        st.apply_event({'event': 'start', 'total_games': 2, 'total_files': 2, 'total_bytes': 3000})
        self.assertEqual(st.stage, 'running')

        st.apply_event({'event': 'item_start', 'index': 1, 'total_games': 2, 'title_id': '0100000000000001', 'before_bytes': 2000})
        self.assertEqual(st.item_for('0100000000000001').status, 'compressing')

        st.apply_event({'event': 'item_done', 'index': 1, 'total_games': 2, 'title_id': '0100000000000001', 'before_bytes': 2000, 'after_bytes': 200, 'saved_bytes': 1800, 'files_compressed': 1})
        self.assertEqual(st.item_for('0100000000000001').status, 'done')
        self.assertEqual(st.processed_bytes, 2000)
        self.assertEqual(st.freed_bytes, 1800)

        st.apply_event({'event': 'item_error', 'index': 2, 'total_games': 2, 'title_id': '0100000000000002', 'before_bytes': 1000, 'error': 'disk full'})
        self.assertEqual(st.item_for('0100000000000002').status, 'failed')
        self.assertEqual(st.processed_bytes, 3000)

        st.apply_event({
            'event': 'done',
            'status': 'partial',
            'completed_games': 1,
            'failed_games': 1,
            'before_bytes': 3000,
            'after_bytes': 1200,
            'saved_bytes': 1800,
            'elapsed_sec': 1.25,
            'results': [
                {'title_id': '0100000000000001', 'status': 'completed', 'before_bytes': 2000, 'after_bytes': 200, 'saved_bytes': 1800, 'files_compressed': 1},
                {'title_id': '0100000000000002', 'status': 'error', 'before_bytes': 1000, 'after_bytes': 1000, 'saved_bytes': 0, 'files_compressed': 0, 'error': 'disk full'},
            ],
        })
        self.assertEqual(st.stage, 'done')
        self.assertIsNotNone(st.done_result)
        assert st.done_result is not None
        self.assertEqual(st.done_result.status, 'partial')
        self.assertEqual(st.done_result.saved_pct, 60)
        self.assertEqual(st.done_result.ratio_pct, 40)

    def test_runner_stop_mid_stream_synthesizes_stopped_and_cleans_tmp(self) -> None:
        seed_root = self.tmp / 'seeds'
        tid1 = '0100000000000001'
        tid2 = '0100000000000002'
        self._create_seed(seed_root, tid1, legacy_img=True)
        self._create_seed(seed_root, tid2, legacy_img=True)
        # Simulate residual .tmp left by abrupt Windows termination
        tmp_zst = seed_root / tid2 / 'metal-sources' / 'b-1122334455667788.img.zst.tmp'
        tmp_zst.write_bytes(b'PARTIAL_TMP')

        summary = sc.local_scan_uncompressed(seed_root, zstd_ok=True)
        runner = sc.SeedCompressionRunner()

        class _FakeProc:
            def __init__(self) -> None:
                lines = [
                    json.dumps({'event': 'start', 'total_games': 2, 'total_files': 2, 'total_bytes': summary.uncompressed_bytes}) + '\n',
                    json.dumps({'event': 'item_start', 'index': 1, 'total_games': 2, 'title_id': tid1, 'before_bytes': summary.games[0].uncompressed_bytes}) + '\n',
                    json.dumps({'event': 'item_done', 'index': 1, 'total_games': 2, 'title_id': tid1, 'before_bytes': summary.games[0].uncompressed_bytes, 'after_bytes': 120, 'saved_bytes': summary.games[0].uncompressed_bytes - 120, 'files_compressed': 1}) + '\n',
                    json.dumps({'event': 'item_start', 'index': 2, 'total_games': 2, 'title_id': tid2, 'before_bytes': summary.games[1].uncompressed_bytes}) + '\n',
                ]
                self.stdout = io.StringIO(''.join(lines))
                self.stderr = io.StringIO('')
                self.terminated = False

            def poll(self):
                return 0 if self.terminated else None

            def terminate(self):
                self.terminated = True

            def kill(self):
                self.terminated = True

            def wait(self, timeout=None):
                return 1

        fake_proc = _FakeProc()
        events: list[dict] = []

        def _on_ev(ev: dict) -> None:
            events.append(ev)
            if ev.get('event') == 'item_start' and ev.get('title_id') == tid2:
                runner.request_stop()

        fake_engine = self.tmp / 'fake_engine'
        fake_script = fake_engine / 'dm' / 'tools' / 'build_seed.py'
        fake_script.parent.mkdir(parents=True, exist_ok=True)
        fake_script.write_text('#!/usr/bin/env python3\n', encoding='utf-8')

        res = runner.run(
            summary,
            engine_path=fake_engine,
            on_event=_on_ev,
            popen_factory=lambda *_a, **_kw: fake_proc,
        )
        self.assertTrue(fake_proc.terminated)
        self.assertEqual(res.status, 'stopped')
        self.assertEqual(res.completed_games, 1)
        self.assertEqual(res.failed_games, 0)
        self.assertFalse(tmp_zst.exists(), 'residual .img.zst.tmp must be cleaned on stop')
        self.assertTrue((seed_root / tid2 / 'metal-sources' / 'b-1122334455667788.img').is_file())
        self.assertEqual(events[-1]['event'], 'done')
        self.assertEqual(events[-1]['status'], 'stopped')

    def test_runner_uses_process_group_and_kills_tree_on_windows_and_force_kill(self) -> None:
        seed_root = self.tmp / 'seeds'
        tid = '0100000000000001'
        self._create_seed(seed_root, tid, legacy_img=True)
        summary = sc.local_scan_uncompressed(seed_root, zstd_ok=True)
        fake_engine = self.tmp / 'fake_engine'
        fake_script = fake_engine / 'dm' / 'tools' / 'build_seed.py'
        fake_script.parent.mkdir(parents=True, exist_ok=True)
        fake_script.write_text('#!/usr/bin/env python3\n', encoding='utf-8')

        captured_kwargs: list[dict] = []
        killed_procs: list[object] = []
        runner = sc.SeedCompressionRunner()

        class _WinFakeProc:
            def __init__(self) -> None:
                self.stdout = io.StringIO(
                    json.dumps({'event': 'item_start', 'index': 1, 'total_games': 1, 'title_id': tid, 'before_bytes': summary.uncompressed_bytes}) + '\n'
                )
                self.stderr = io.StringIO('')
                self.alive = True
                self.terminated = False

            def poll(self):
                return None if self.alive else 1

            def terminate(self):
                self.terminated = True
                self.alive = False

            def wait(self, timeout=None):
                return 1

        proc = _WinFakeProc()

        def _fake_popen(*_a, **kw):
            captured_kwargs.append(kw)
            return proc

        def _fake_kill_tree(p, **_kw):
            killed_procs.append(p)
            p.alive = False

        with mock.patch.object(sc.pu, 'IS_WIN', True), \
                mock.patch.object(sc.pu, 'process_group_kwargs', return_value={'creationflags': 0x08000200}), \
                mock.patch.object(sc.pu, 'kill_process_tree', side_effect=_fake_kill_tree):
            res = runner.run(
                summary,
                engine_path=fake_engine,
                on_event=lambda ev: runner.request_stop() if ev.get('event') == 'item_start' else None,
                popen_factory=_fake_popen,
            )
            # Also verify force_kill invokes kill_process_tree uniformly
            proc.alive = True
            with runner._lock:
                runner._proc = proc
            runner.force_kill()
            with runner._lock:
                runner._proc = None

        self.assertEqual(res.status, 'stopped')
        self.assertEqual(captured_kwargs[0].get('creationflags'), 0x08000200)
        self.assertFalse(proc.terminated, 'Windows request_stop must use kill_process_tree instead of bare terminate')
        self.assertEqual(killed_procs, [proc, proc])

    def test_dismissed_preference_persistence_across_backends(self) -> None:
        # 1. JSON file persistence (no Qt)
        pref_file = self.tmp / 'cfg' / 'prefs.json'
        self.assertFalse(sc.is_prompt_dismissed(pref_file))
        sc.set_prompt_dismissed(pref_file, True)
        self.assertTrue(sc.is_prompt_dismissed(pref_file))
        raw = json.loads(pref_file.read_text(encoding='utf-8'))
        self.assertTrue(raw[sc.PREF_DISMISSED_JSON_KEY])
        sc.set_prompt_dismissed(pref_file, False)
        self.assertFalse(sc.is_prompt_dismissed(pref_file))

        # 2. Duck-typed QSettings object
        class _DuckQSettings:
            def __init__(self) -> None:
                self.store: dict[str, str] = {}

            def value(self, k: str, default: object = '', type=str) -> object:  # noqa: A002
                return self.store.get(k, default)

            def setValue(self, k: str, v: object) -> None:
                self.store[k] = str(v)

        qs = _DuckQSettings()
        self.assertFalse(sc.is_prompt_dismissed(qs))
        sc.set_prompt_dismissed(qs, True)
        self.assertTrue(sc.is_prompt_dismissed(qs))
        sc.set_prompt_dismissed(qs, False)
        self.assertFalse(sc.is_prompt_dismissed(qs))

    def test_build_subprocess_env_injects_zstd_and_strips_meipass(self) -> None:
        fake_zstd = self.tmp / 'zstd-bin' / 'zstd'
        fake_zstd.parent.mkdir(parents=True)
        fake_zstd.write_text('#!/bin/sh\n', encoding='utf-8')
        with mock.patch.object(sc, 'find_zstd_bin', return_value=str(fake_zstd)), \
                mock.patch.dict(os.environ, {'_MEIPASS': '/tmp/frozen', 'PATH': '/usr/bin'}, clear=False):
            env = sc.build_subprocess_env(ENGINE_DIR)
        self.assertNotIn('_MEIPASS', env)
        self.assertIn(str(ENGINE_DIR / 'dm' / 'tools'), env['PYTHONPATH'])
        self.assertEqual(env['PATH'].split(os.pathsep)[0], str(fake_zstd.parent))

    def test_end_to_end_real_engine_scan_and_compress(self) -> None:
        script = sc.build_seed_script_path(ENGINE_DIR)
        if script is None:
            self.skipTest('engine/dm/tools/build_seed.py not synced')
        if not sc.resolve_zstd_available(sys.executable):
            self.skipTest('zstd unavailable in test environment')

        seed_root = self.tmp / 'seeds'
        tid1 = '01007EF00011E000'
        tid2 = '0100000000010000'
        self._create_seed(seed_root, tid1, app_name='Game One', legacy_img=True)
        self._create_seed(seed_root, tid2, app_name='Game Two', legacy_img=True)

        summary = sc.scan_uncompressed(seed_root=seed_root, engine_path=ENGINE_DIR, python_exe=sys.executable)
        self.assertFalse(summary.used_fallback)
        self.assertTrue(summary.zstd_available)
        self.assertEqual(summary.total_games, 2)
        self.assertEqual(summary.total_seed_games, 2)

        events: list[dict] = []
        runner = sc.SeedCompressionRunner()
        res = runner.run(
            summary,
            engine_path=ENGINE_DIR,
            python_exe=sys.executable,
            on_event=events.append,
        )
        self.assertEqual(res.status, 'completed')
        self.assertEqual(res.completed_games, 2)
        self.assertEqual(res.failed_games, 0)
        self.assertGreater(res.saved_bytes, 0)
        self.assertTrue((seed_root / tid1 / 'metal-sources' / 'b-1122334455667788.img.zst').is_file())
        self.assertFalse((seed_root / tid1 / 'metal-sources' / 'b-1122334455667788.img').exists())

        # Re-scanning after compression must find 0 uncompressed games but still 2 seed games
        after = sc.scan_uncompressed(seed_root=seed_root, engine_path=ENGINE_DIR, python_exe=sys.executable)
        self.assertEqual(after.total_games, 0)
        self.assertEqual(after.total_seed_games, 2)


@unittest.skipUnless(HAS_QT, 'PySide6 required for live QDialog widget tests')
class SeedCompressionDialogTests(unittest.TestCase):
    """Live Qt widget tests verifying three-stage rendering, Stop transition, and Settings row."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.app = QApplication.instance() or QApplication([])

    def setUp(self) -> None:
        self._td = tempfile.TemporaryDirectory()
        self.tmp = Path(self._td.name)

    def tearDown(self) -> None:
        self._td.cleanup()

    def _sample_summary(self) -> sc.SeedScanSummary:
        games = [
            sc.SeedGameScanItem('01007EF00011E000', 'BotW', ['b-1.img'], 1_600_000_000, 128_000_000, '塞尔达传说 旷野之息'),
            sc.SeedGameScanItem('0100F2C0115B6000', 'TotK', ['b-1.img'], 1_200_000_000, 96_000_000, '塞尔达传说 王国之泪'),
            sc.SeedGameScanItem('0100000000010000', 'Odyssey', ['b-1.img'], 800_000_000, 64_000_000, '超级马力欧 奥德赛'),
            sc.SeedGameScanItem('01006A800016E000', 'SSBU', ['b-1.img'], 600_000_000, 48_000_000, '任天堂明星大乱斗 特别版'),
            sc.SeedGameScanItem('0100152000022000', 'MK8D', ['b-1.img'], 400_000_000, 32_000_000, '马力欧卡丁车 8 豪华版'),
        ]
        total_b = sum(g.uncompressed_bytes for g in games)
        est_b = sum(g.estimated_compressed_bytes for g in games)
        return sc.SeedScanSummary(
            seed_root=str(self.tmp / 'seeds'),
            zstd_available=True,
            total_games=len(games),
            total_files=len(games),
            uncompressed_bytes=total_b,
            estimated_compressed_bytes=est_b,
            estimated_saved_bytes=total_b - est_b,
            games=games,
            total_seed_games=5,
        )

    def test_dialog_three_stages_and_dont_ask_persistence(self) -> None:
        m = Model()
        m.lang = Lang('zh')
        summary = self._sample_summary()
        dlg = scd.SeedCompressionDialog(m, summary, auto_prompt=True)

        # Stage 1: Prompt (LauncherCheckBox + min-height guard against vertical overlap)
        from nspb_qt.widgets import LauncherCheckBox
        self.assertIsInstance(dlg.dont_ask_cb, LauncherCheckBox)
        self.assertEqual(dlg.current_stage, 'prompt')
        first_row = dlg.prompt_games_group.body_layout.itemAt(0).widget()
        self.assertIsNotNone(first_row)
        self.assertGreaterEqual(first_row.minimumHeight(), 52)
        self.assertIsNotNone(dlg.more_games_lbl)
        self.assertEqual(dlg.more_games_lbl.text(), m.t('seedCompress.prompt.moreGames', 1))
        dlg.dont_ask_cb.setChecked(True)
        dlg._persist_dont_ask()
        self.assertTrue(sc.is_prompt_dismissed(m))

        # Stage 2: Running via event injection + stopping state
        dlg._on_worker_event({'event': 'start', 'total_games': 5, 'total_files': 5, 'total_bytes': summary.uncompressed_bytes})
        dlg._on_worker_event({'event': 'item_start', 'index': 1, 'total_games': 5, 'title_id': '01007EF00011E000', 'before_bytes': 1_600_000_000})
        dlg.stack.setCurrentWidget(dlg.running_page)
        self.assertEqual(dlg.current_stage, 'running')
        self.assertIn('正在压缩', dlg.run_current_lbl.text())

        dlg._on_stop_clicked()
        self.assertFalse(dlg.stop_btn.isEnabled())
        self.assertEqual(dlg.stop_btn.text(), m.t('seedCompress.progress.stopping'))

        # Stage 3: Done (completed / partial / stopped)
        done_res = sc.SeedCompressionResult(
            status='stopped',
            completed_games=1,
            failed_games=0,
            before_bytes=1_600_000_000,
            after_bytes=120_000_000,
            saved_bytes=1_480_000_000,
            elapsed_sec=8.4,
            results=[
                sc.SeedCompressionItemState('01007EF00011E000', '塞尔达传说 旷野之息', 'done', 1_600_000_000, 120_000_000, 1_480_000_000, 1),
            ],
        )
        dlg.show_done(done_res)
        self.assertEqual(dlg.current_stage, 'done')
        self.assertEqual(dlg.done_title_lbl.text(), m.t('seedCompress.done.titleStopped'))
        self.assertIn('1', dlg.done_stats_lbl.text())
        dlg.accept()

    def test_settings_row_and_manual_entry_ignores_dismissed_flag(self) -> None:
        m = Model()
        m.lang = Lang('en')
        sc.set_prompt_dismissed(m, True)
        win = MainWindow(m, perform_startup_checks=False)
        try:
            summary = self._sample_summary()
            win._seed_compress_summary = summary
            win._refresh_seed_compress_row()
            self.assertIn('5', win.seed_compress_status_lbl.text())

            # Clicking manual compress ignores dontAskAgain and opens dialog
            opened: list[bool] = []
            with mock.patch.object(sc, 'scan_uncompressed', return_value=summary), \
                    mock.patch.object(win, '_open_seed_compression_dialog', side_effect=lambda s, auto_prompt=False: opened.append(auto_prompt)):
                win._handle_seed_compress_scan_done(
                    win._seed_compress_scan_gen,
                    summary,
                    open_after=True,
                    auto_prompt=False,
                )
            self.assertEqual(opened, [False])

            # Startup auto_prompt respects dontAskAgain=True
            auto_opened: list[bool] = []
            with mock.patch.object(win, '_open_seed_compression_dialog', side_effect=lambda s, auto_prompt=False: auto_opened.append(auto_prompt)):
                win._handle_seed_compress_scan_done(
                    win._seed_compress_scan_gen,
                    summary,
                    open_after=False,
                    auto_prompt=True,
                )
            self.assertEqual(auto_opened, [])

            # Build running mutex: scan callback and dialog.start_compression must refuse when m.running=True
            m.running = True
            mutex_opened: list[bool] = []
            with mock.patch.object(win, '_open_seed_compression_dialog', side_effect=lambda s, auto_prompt=False: mutex_opened.append(auto_prompt)):
                win._handle_seed_compress_scan_done(
                    win._seed_compress_scan_gen,
                    summary,
                    open_after=True,
                    auto_prompt=False,
                )
            self.assertEqual(mutex_opened, [])

            dlg = scd.SeedCompressionDialog(m, summary)
            dlg.start_compression()
            self.assertEqual(dlg.current_stage, 'prompt')
            dlg.close()

            # closeEvent must cancel pending scan generation and reset scanning flag
            win._seed_compress_scanning = True
            gen_before = win._seed_compress_scan_gen
            win.close()
            self.assertFalse(win._seed_compress_scanning)
            self.assertEqual(win._seed_compress_scan_gen, gen_before + 1)
        finally:
            win.close()


if __name__ == '__main__':
    unittest.main()
