#!/usr/bin/env python3
# scripts/regress.py: the parts that need no game, GPU or git revision: the MSL interface reader (GitHub issue #283), the [RED] normalization, the routes, and the comparisons
import importlib.util, json, tempfile, unittest
from contextlib import ExitStack
from pathlib import Path
from types import SimpleNamespace as NS
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('regress', REPO / 'scripts/regress.py')
assert spec is not None and spec.loader is not None
regress = importlib.util.module_from_spec(spec); spec.loader.exec_module(regress)

VS = '''struct main0_out
{
    float4 m_51 [[user(locn0)]];
    float4 m_55 [[user(locn2), flat]];
    float4 gl_Position [[position, invariant]];
};

struct main0_in
{
    float4 a0 [[attribute(0)]];
};

vertex main0_out main0(main0_in in [[stage_in]], constant spvDescriptorSetBuffer0& spvDescriptorSet0 [[buffer(0)]])
{
}

vertex main0_out main0_z(main0_in in [[stage_in]], constant spvDescriptorSetBuffer0& spvDescriptorSet0 [[buffer(0)]])
{
}
'''
PS = '''struct main0_out
{
    float4 c0 [[color(0)]];
};

struct main0_in
{
    float4 m_1 [[user(locn0)]];
    float4 m_2 [[user(locn1)]];
    int4 m_3 [[user(locn2), flat]];
};

fragment main0_out main0(main0_in in [[stage_in]], constant spvDescriptorSetBuffer0& spvDescriptorSet0 [[buffer(0)]], float4 gl_FragCoord [[position]])
{
}
'''


class Regress(unittest.TestCase):
    def test_impact_without_machine_paths(self):
        env = {k: v for k, v in regress.os.environ.items() if k not in ('REGRESS_ROOT', 'REGRESS_GAMES')}
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            command = [regress.sys.executable, REPO / 'scripts/regress.py']
            result = regress.sh([*command, 'impact', 'HEAD..HEAD'], cwd=root, env=env)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('## regress.py impact', result.stdout)
            self.assertEqual(list(root.iterdir()), [])   # an unset root must not become cwd/reports
            out = root / 'explicit'
            result = regress.sh([*command, 'impact', 'HEAD..HEAD', '--out', out], cwd=root, env=env)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads((out / 'impact.json').read_text())['schema'], 'nxnative-impact/1')
            self.assertTrue((out / 'impact.md').is_file())
            harness = root / 'harness'; harness.mkdir()
            result = regress.sh([*command, '--root', harness, 'impact', 'HEAD..HEAD'], cwd=root, env=env)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(len(list((harness / 'reports').glob('*/impact.json'))), 1)

    def test_game_commands_require_machine_paths(self):
        env = dict(regress.os.environ, REGRESS_ROOT='', REGRESS_GAMES='')
        with tempfile.TemporaryDirectory() as td:
            command = [regress.sys.executable, REPO / 'scripts/regress.py']
            for cmd in ('baseline', 'check', 'chain', 'usage', 'list'):
                with self.subTest(cmd=cmd):
                    result = regress.sh([*command, cmd], cwd=td, env=env)
                    self.assertEqual(result.returncode, 2)
                    self.assertIn('set --root (REGRESS_ROOT) and --games-dir (REGRESS_GAMES)', result.stderr)
            for option, missing in (('--root', '--games-dir (REGRESS_GAMES)'), ('--games-dir', '--root (REGRESS_ROOT)')):
                with self.subTest(option=option):
                    result = regress.sh([*command, option, td, 'check'], cwd=td, env=env)
                    self.assertEqual(result.returncode, 2)
                    self.assertIn('set ' + missing + ':', result.stderr)
            self.assertEqual(list(Path(td).iterdir()), [])

    def test_interface(self):
        vo, fi = regress.msl_io(VS, 'main0_z', 'vs'), regress.msl_io(PS, 'main0', 'ps')
        self.assertEqual(vo, {'locn0': 'float4', 'locn2': 'float4'})
        self.assertEqual(fi, {'locn0': 'float4', 'locn1': 'float4', 'locn2': 'int4'})
        self.assertIsNone(regress.msl_io(VS, 'main1', 'vs'))
        self.assertEqual(regress.msl_io('fragment main0_out main0(constant X& x [[buffer(0)]])\n{\n}\n', 'main0', 'ps'), {})   # no stage inputs

    def test_red_normalized(self):
        a = regress.normalize_red('[dm] [RED] shader 0a91af5bef8578e2: 12 bindings at 0x1f00 in /Volumes/NX/games/x [y]/b')
        b = regress.normalize_red('[dm] [RED] shader 1b91af5bef8578e3: 7 bindings at 0x2000 in /tmp/z')
        self.assertEqual(a, b)
        # Scarlet: one red line, its register zero in one run ("x1=0") and not in the other ("x1=0x1")
        a = regress.normalize_red('[dm] [RED] NVN unimplemented function called: nvnCommandBufferSetConservativeRasterDilate (x0=0x7f3c2a10 x1=0 x2=0x3)')
        b = regress.normalize_red('[dm] [RED] NVN unimplemented function called: nvnCommandBufferSetConservativeRasterDilate (x0=0x7f3c2a10 x1=0x1 x2=0x3)')
        self.assertEqual(a, b)
        self.assertEqual(regress.red_kind(a.replace('x#=#', 'x#=0x#')), a)   # a kind stored in an older baseline

    def test_routes(self):   # every profile's smoke.tsv reads
        for f in (REPO / 'dm/games').glob('*/smoke.tsv'):
            r = regress.read_route(f)
            self.assertTrue(r['secs'] > 0 and r['quick'] > 0, f)
            self.assertIsInstance(r['keys'], str, f)   # title-screen routes need no input
            if r['reach']: self.assertTrue(r['reach'][1] <= r['secs'], f)

    def test_route_keys_are_optional_and_preserved(self):
        with tempfile.TemporaryDirectory() as td:
            f = Path(td) / 'smoke.tsv'
            for row, keys in (('', ''), ('keys\t\n', ''), ('keys\t1:A,2:B\n', '1:A,2:B')):
                with self.subTest(row=row):
                    f.write_text('save\tnew\nsecs\t40\nquick\t35\nreach\t1200@30\n' + row)
                    r = regress.read_route(f)
                    self.assertEqual(r['keys'], keys)
                    self.assertEqual(r['save'], 'new')
                    self.assertEqual(r['reach'], (1200, 30.0))

    def test_chain_diff(self):
        b = {'shaders': {'a': {'st': 'ok', 'msl': '1'}, 'b': {'st': 'ok', 'msl': '2'}, 'c': {'st': 'metal failed'}, 'd': {'st': 'ok', 'msl': '4'}},
             'interface': {'bad': [{'vs': 'v', 'entry': 'main0', 'ps': 'p', 'missing': ['locn1'], 'type': []}]}}
        c = {'shaders': {'a': {'st': 'ok', 'msl': '1'}, 'b': {'st': 'metal failed', 'err': 'x'}, 'c': {'st': 'ok', 'msl': '3'}, 'd': {'st': 'ok', 'msl': '5'}, 'e': {'st': 'translation failed', 'err': 'y'}},
             'interface': {'bad': [{'vs': 'v', 'entry': 'main0', 'ps': 'p', 'missing': ['locn1'], 'type': []}, {'vs': 'w', 'entry': 'main0', 'ps': 'p', 'missing': ['locn6'], 'type': []}]}}
        d = regress.chain_diff(b, c)
        self.assertEqual([x['key'] for x in d['newly_failing']], ['b']); self.assertEqual(d['newly_passing'], ['c'])
        self.assertEqual([x['key'] for x in d['added_failing']], ['e'])   # shader_regressions.py does not count a new key; the harness lists it apart
        self.assertEqual(d['changed']['msl'], 1); self.assertEqual(d['changed']['keys'], ['d'])
        self.assertEqual([x['vs'] for x in d['interface']['new']], ['w']); self.assertEqual(len(d['interface']['known']), 1)

    def test_smoke_diff(self):
        route = {'reach': (100, 30.0)}
        shot = {'dhash': '0f0f0f0f0f0f0f0f', 'rgb16': '10' * 768}
        base = [{'exit': None, 'max_frame': 500, 'reached': True, 'fps': 60, 'frame_p99': 17, 'peak_footprint_mb': 4000, 'prepare_s': 1.0, 'red': {'a #': 2}, 'shots': {'45': shot}}]
        same = [dict(base[0])]
        lv, known, d = regress.smoke_diff(base, same, route)
        self.assertFalse(lv['NEW-FAIL'] or lv['REGRESSION'] or lv['CHANGED'], lv)
        bad = [dict(base[0], exit=-11, crash={'signal': 'SIGSEGV'}, red={'a #': 1, 'b #': 3}, fps=40, shots={'45': {'dhash': 'f0f0f0f0f0f0f0f0', 'rgb16': '80' * 768}})]
        lv, known, d = regress.smoke_diff(base, bad, route)
        self.assertTrue(any('crash' in x for x in lv['NEW-FAIL']), lv)
        self.assertTrue(any('RED' in x for x in lv['REGRESSION']) and any('fps' in x for x in lv['REGRESSION']) and any('screenshot' in x for x in lv['REGRESSION']), lv)
        self.assertEqual(d['new_red'], [{'text': 'b #', 'count': 3}])
        lv, known, d = regress.smoke_diff(bad, bad, route)   # a failure the baseline has too is known, not new
        self.assertFalse(lv['NEW-FAIL']); self.assertTrue(known)
        slow = [dict(base[0], reached=False, max_frame=90)]   # the reach missed in both, each run with its own max frame: known, not new
        lv, known, d = regress.smoke_diff(slow, [dict(slow[0], max_frame=95)], route)
        self.assertFalse(lv['NEW-FAIL'], lv); self.assertEqual(known, ['frame 100 not reached by 30 s (max 95)'])
        self.assertTrue(regress.smoke_diff(base, slow, route)[0]['NEW-FAIL'])   # missed only in the candidate: new
        segv, abrt = [dict(base[0], exit=-11, crash={'signal': 'SIGSEGV'})], [dict(base[0], exit=-6, crash={'signal': 'SIGABRT'})]
        self.assertTrue(regress.smoke_diff(segv, abrt, route)[0]['NEW-FAIL'])   # a crash with another signal is new
        q1, q139 = [dict(base[0], exit=1)], [dict(base[0], exit=139)]
        self.assertTrue(regress.smoke_diff(q1, q139, route)[0]['NEW-FAIL'])   # so is an exit with another status
        self.assertFalse(regress.smoke_diff(q1, [dict(base[0], exit=1)], route)[0]['NEW-FAIL'])
        quit0 = [dict(base[0], exit=0)]   # the game ended by itself before the route did: a failure even with exit status 0
        self.assertTrue(any('exited before the end' in x for x in regress.smoke_diff(base, quit0, route)[0]['NEW-FAIL']))

    def test_status_order(self):
        self.assertEqual(regress.worst('PASS', 'CHANGED', 'REGRESSION'), 'REGRESSION'); self.assertEqual(regress.worst('NEW-FAIL', 'ERROR'), 'ERROR')

    def test_selection_keeps_games_without_routes(self):
        games = [NS(id='a', name='routed', kind='nvn', route=lambda: {'save': 'new'}), NS(id='b', name='unrouted', kind='nvn', route=lambda: None)]
        with patch.object(regress, 'find_games', return_value=games), patch.object(regress, 'say'):
            self.assertEqual(regress.select(NS(games=None), smoke=True), games)

    def test_no_smoke_checks_every_chain_without_building_hosts(self):
        route = {'save': 'new', 'keys': '1:A', 'secs': 20, 'quick': 10, 'reach': (1, 5)}
        games = [NS(id='a', name='routed', route=lambda: route), NS(id='b', name='unrouted', route=lambda: None)]
        tree = NS(id='tree')
        manifest = {'kind': 'nvn', 'shaders': {}, 'failed': 0}
        a = NS(baseline='base', candidate='cand', no_smoke=True, rewrite=False, quick=True, runs=1)
        with tempfile.TemporaryDirectory() as td, ExitStack() as stack:
            stack.enter_context(patch.object(regress, 'ROOT', Path(td)))
            stack.enter_context(patch.object(regress, 'Tree', return_value=tree))
            stack.enter_context(patch.object(regress, 'select', return_value=games))
            stack.enter_context(patch.object(regress, 'rewriter_key', return_value='same'))
            chain = stack.enter_context(patch.object(regress, 'chain_build', return_value=(manifest, Path(td))))
            hosts = stack.enter_context(patch.object(regress, 'artifacts', side_effect=AssertionError('a static check built a host')))
            smoke = stack.enter_context(patch.object(regress, 'smoke_series', side_effect=AssertionError('a static check ran a game')))
            stack.enter_context(patch.object(regress, 'new_report', return_value={'games': {}}))
            finish = stack.enter_context(patch.object(regress, 'finish', return_value=0))
            stack.enter_context(patch.object(regress, 'say'))
            self.assertEqual(regress.cmd_check(a), 0)
            self.assertEqual(chain.call_count, 4)
            hosts.assert_not_called(); smoke.assert_not_called()
            self.assertEqual([g['status'] for g in finish.call_args.args[0]['games'].values()], ['PASS', 'PASS'])

    def test_reused_chain_rechecks_current_interface(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td); g = NS(id='game', kind='nvn', folder=root)
            out = regress.game_root(g) / 'chain/key'; out.mkdir(parents=True)
            (out / 'manifest.json').write_text(json.dumps({'kind': 'nvn', 'interface': {'bad': []}}))
            current = {'bad': [{'vs': 'new-pair'}]}
            with patch.object(regress, 'ROOT', root), patch.object(regress, 'chain_key', return_value=('v', 'i', 'key')), patch.object(regress, 'interface_check', return_value=current) as check:
                manifest, _ = regress.chain_build(NS(), g, NS(tools_fp='', jobs=1))
            check.assert_called_once()
            self.assertEqual(manifest['interface'], current)

    def test_smoke_requires_prebuild_and_screenshots(self):
        route = {'reach': (100, 10.0), 'shots': [8]}
        good = {'exit': None, 'max_frame': 500, 'reached': True, 'prebuild': {'exit': 0, 'done': True, 'failed': 0},
                'shots': {'8': {'dhash': '0' * 16, 'rgb16': '00' * 768}}}
        for prebuild in ({'exit': -11, 'hang': False}, {'exit': None, 'hang': False}, {'exit': 0, 'done': False}):
            with self.subTest(prebuild=prebuild):
                bad = dict(good, prebuild=prebuild)
                self.assertTrue(regress.smoke_diff([good], [bad], route)[0]['NEW-FAIL'])
        self.assertTrue(regress.smoke_diff([good], [dict(good, shots={})], route)[0]['NEW-FAIL'])
        self.assertTrue(regress.run_failures({'exit': None, 'max_frame': -1, 'reached': False}, {'reach': None}))

    def test_each_candidate_screenshot_is_checked(self):
        route = {'reach': None}
        good = {'exit': None, 'max_frame': 500, 'shots': {'8': {'dhash': '0' * 16, 'rgb16': '00' * 768}}}
        bad = dict(good, shots={'8': {'dhash': 'f' * 16, 'rgb16': 'ff' * 768}})
        self.assertTrue(regress.smoke_diff([good], [good, bad], route)[0]['REGRESSION'])

    def test_shader_build_pauses_for_unknown_lock_owner(self):
        with tempfile.TemporaryDirectory() as td:
            with patch.object(regress.subprocess, 'Popen') as spawn, patch.object(regress.bench, 'lock_holder', return_value=0), patch.object(regress.os, 'killpg') as kill, patch.object(regress.time, 'sleep'), patch.object(regress, 'say'):
                spawn.return_value.poll.side_effect = [None, 0, 0]
                regress.run_heavy(['build'], Path(td) / 'build.log', td, {}, NS(pause_lock=Path(td) / 'lock'), 'build')
            self.assertTrue(any(c.args[1] == regress.signal.SIGSTOP for c in kill.call_args_list))

    def test_heavy_jobs_recognizes_harness_descendants_outside_shared_root(self):
        processes = '100 1 S python3 /source/scripts/regress.py check\n101 100 S python3 /trees/dmsh_build.py\n102 101 R metal /games/title-work/regress/tmp/shader.metal\n103 1 R metal /another/build.metal\n104 100 R make dmhost\n'
        with patch.object(regress, 'sh', return_value=NS(stdout=processes)), patch.object(regress.os, 'getpid', return_value=200):
            self.assertEqual(regress.heavy_jobs(), ['103 metal /another/build.metal', '104 make dmhost'])

    def test_chain_key_tracks_shader_package_and_split_pairs(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td); pkg = root / 'shader/pkg'; pkg.mkdir(parents=True)
            shader = pkg / 'a.bin'; shader.write_bytes(b'original')
            prof = root / 'profile'; prof.mkdir()
            g = regress.Game(root, root / ('0' * 16 + '_build'))
            g.build, g.id, g.kind, g.derived = root, 'game', 'nvn', False
            tree = NS(path=root, py=lambda *args: '["chain", "inputs"]')
            with patch.object(g, 'profile_dir', return_value=prof):
                original = regress.chain_key(tree, g, 'tools')[2]
                shader.write_bytes(b'changed')
                changed = regress.chain_key(tree, g, 'tools')[2]
                (root / 'shader/pso_pairs.tsv').write_text('vertex\tfragment\n')
                paired = regress.chain_key(tree, g, 'tools')[2]
            self.assertNotEqual(original, changed)
            self.assertNotEqual(changed, paired)

    def test_vk_chain_key_tracks_selected_converter_content(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td); tools = root / 'dm/gfx/tools'; tools.mkdir(parents=True)
            bundled = tools / 'spirv_cross_bin/spirv-cross'; bundled.parent.mkdir()
            bundled.write_bytes(b'bundled converter')
            selected = root / 'override'; selected.write_bytes(b'converter A'); selected.chmod(0o755)
            env = dict(regress.os.environ, SPIRV_CROSS=str(selected))
            g = NS(kind='vk', ver='v0', env=lambda tree: env, shader_roots=list, build=root)
            tree = NS(path=root)
            before = regress.chain_key(tree, g, 'tools')[2]
            selected.write_bytes(b'converter B')
            self.assertNotEqual(before, regress.chain_key(tree, g, 'tools')[2])

    def test_baseline_context_tracks_route_save_artifacts_and_settings(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td); save = root / 'save'; save.mkdir()
            (save / 'data').write_bytes(b'original')
            prof = root / 'profile'; prof.mkdir(); (prof / 'game.tsv').write_text('depth_mode\tgl\n')
            art = {'host_key': 'host', 'modules_key': 'modules', 'manifest': {'key': 'chain'}, 'profile': prof}
            a = NS(env=[], tools_fp='tools', no_hud=False, runs=1, prebuild_limit=100, prebuild_hang=10)
            route = {'save': 'run', 'keys': '', 'secs': 90, 'quick': 60, 'shots': [40]}
            with patch.object(regress, 'save_source', return_value=save):
                original = regress.smoke_context(NS(), art, route, a, {})
                self.assertNotEqual(original, regress.smoke_context(NS(), art, dict(route, shots=[45]), a, {}))
                self.assertNotEqual(original, regress.smoke_context(NS(), dict(art, host_key='other'), route, a, {}))
                a.env = ['DM_RENDER_SCALE=0.5']
                self.assertNotEqual(original, regress.smoke_context(NS(), art, route, a, {}))
                a.env = []; (save / 'data').write_bytes(b'changed')
                self.assertNotEqual(original, regress.smoke_context(NS(), art, route, a, {}))

    def test_stored_baseline_is_reused_only_with_matching_context(self):
        with tempfile.TemporaryDirectory() as td, ExitStack() as stack:
            root = Path(td); tree = NS(id='tree')
            route = {'reach': None, 'shots': []}
            g = NS(id='game', name='game', folder=root, route=lambda: route)
            a = NS(baseline='base', candidate='cand', no_smoke=False, rewrite=False, quick=True, runs=1)
            art = {'manifest': {'kind': 'nvn', 'shaders': {}, 'failed': 0}}
            good = {'exit': None, 'max_frame': 500, 'shots': {}}
            stack.enter_context(patch.object(regress, 'ROOT', root))
            stack.enter_context(patch.object(regress, 'Tree', return_value=tree))
            stack.enter_context(patch.object(regress, 'select', return_value=[g]))
            stack.enter_context(patch.object(regress, 'rewriter_key', return_value='same'))
            stack.enter_context(patch.object(regress, 'artifacts', return_value=art))
            stack.enter_context(patch.object(regress, 'new_report', side_effect=lambda *args, **kwargs: {'games': {}, 'machine': {}}))
            stack.enter_context(patch.object(regress, 'finish', return_value=0))
            stack.enter_context(patch.object(regress, 'say'))
            context = stack.enter_context(patch.object(regress, 'smoke_context', return_value={'settings': 'a'}))
            smoke = stack.enter_context(patch.object(regress, 'smoke_series', return_value=[good]))
            regress.cmd_check(a)
            self.assertEqual(smoke.call_count, 2)   # baseline and candidate
            smoke.reset_mock(); regress.cmd_check(a)
            self.assertEqual(smoke.call_count, 1)   # candidate only
            smoke.reset_mock(); context.return_value = {'settings': 'b'}; regress.cmd_check(a)
            self.assertEqual(smoke.call_count, 2)   # changed settings record a fresh baseline

    def test_profiles_and_baselines_stay_in_the_game_work_folder(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td); folder = root / 'nsp'; folder.mkdir()
            build = folder / ('0' * 16 + '_build'); build.mkdir()
            tree = NS(path=root / 'tree', id='tree')
            source = tree.path / 'dm/games' / ('0' * 16); source.mkdir(parents=True)
            (source / 'game.tsv').write_text('depth_mode\tgl\n')
            g = regress.Game(folder, build)
            prof = g.profile_dir(tree)
            self.assertTrue(prof.is_relative_to(folder / f'{g.id}-work'))
            self.assertTrue(regress.baseline_dir(tree, g).is_relative_to(folder / f'{g.id}-work'))
            (prof / 'c1_full.tsv').write_text('generated\n')
            self.assertFalse((source / 'c1_full.tsv').exists())
            (source / 'game.tsv').write_text('depth_mode\tzero\n')
            self.assertNotEqual(g.profile_dir(tree), prof)
            env = g.env(tree)
            self.assertEqual(env['DM_GAMES_DIR'], str(g.profile_dir(tree).parent))
            self.assertEqual(env['DM_GAMES_FIRST'], '1')

    def test_vk_roots_include_runtime_capture(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td); build = root / ('0' * 16 + '_build')
            romfs = build / 'extract/v0/RomFS'; romfs.mkdir(parents=True)
            (build / 'patched_v0').mkdir()
            capture = romfs.parent / 'vk_capture'; capture.mkdir()
            g = regress.Game(root, build)
            self.assertEqual(g.shader_roots(), [romfs, capture])

    def test_rewriter_uses_original_registered_profile_and_keeps_provisional(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            for derived in (False, True):
                with self.subTest(derived=derived):
                    env = {'DM_GAME': 'game', 'DM_GAMES_DIR': '/copied/profile', 'DM_GAMES_FIRST': '1'}
                    g = NS(id='game', folder=root / str(derived), build=root / 'build', ver='v0',
                           patched=root / 'patched_v0', derived=derived, env=lambda tree, config=env: dict(config))
                    tree = NS(id='tree', path=root, py=lambda code, e: 'main')
                    process = NS(poll=lambda: 0, returncode=0)
                    with patch.object(regress, 'rewriter_key', return_value='key'), patch.object(regress, 'say'), \
                         patch.object(regress.subprocess, 'Popen', return_value=process) as spawn, patch.object(regress.time, 'sleep'):
                        dst, _ = regress.modules_for(tree, g, True, 1)
                    selected = spawn.call_args.kwargs['env']
                    self.assertEqual(selected.get('DM_GAMES_DIR'), env['DM_GAMES_DIR'] if derived else None)
                    self.assertEqual(selected.get('DM_GAMES_FIRST'), '1' if derived else None)
                    self.assertEqual(selected['DM_GAME'], 'game')
                    self.assertTrue((dst / '.done').is_file())

    def test_vk_build_records_failure_even_without_generated_shaders(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td); tool = root / 'dm/gfx/tools/vk_shaders.py'; tool.parent.mkdir(parents=True)
            tool.write_text('raise SystemExit(1)\n')
            g = NS(id='game', folder=root, build=root, kind='vk', env=lambda tree: dict(regress.os.environ), shader_roots=list)
            with patch.object(regress, 'chain_key', return_value=('version', 'inputs', 'key')):
                manifest, _ = regress.chain_build(NS(id='tree', path=root), g, NS(tools_fp='', jobs=1, pause_lock=None))
            self.assertTrue(manifest['build_failed'])
            self.assertEqual(manifest['shaders'], {})

    def test_vk_failure_without_msl_fails_the_check(self):
        with tempfile.TemporaryDirectory() as td, ExitStack() as stack:
            root = Path(td)
            tree = NS(id='tree'); g = NS(id='game', name='game')
            a = NS(baseline='base', candidate='cand', no_smoke=True, rewrite=False, quick=False)
            stack.enter_context(patch.object(regress, 'Tree', return_value=tree))
            stack.enter_context(patch.object(regress, 'select', return_value=[g]))
            stack.enter_context(patch.object(regress, 'rewriter_key', return_value='same'))
            baseline = {'kind': 'vk', 'shaders': {'key': {'st': 'ok'}}, 'failed': 0}
            candidate = {'kind': 'vk', 'shaders': {}, 'failed': 0, 'build_failed': True}
            stack.enter_context(patch.object(regress, 'chain_build', side_effect=[(baseline, root), (candidate, root)]))
            stack.enter_context(patch.object(regress, 'new_report', return_value={'games': {}}))
            finish = stack.enter_context(patch.object(regress, 'finish', return_value=1))
            stack.enter_context(patch.object(regress, 'say'))
            regress.cmd_check(a)
            self.assertEqual(finish.call_args.args[0]['games']['game']['status'], 'NEW-FAIL')


class Validated(unittest.TestCase):
    """--record: dm/games/<id>/validated.tsv, the chain a game was last green on"""
    def run_record(self, td, status, record=True, dirty=False, mode='quick', smoke=True, chain='aaaa11112222', runs=None, command='check', derived=False):
        games = Path(td) / 'dm/games'; (games / 'g1').mkdir(parents=True, exist_ok=True)
        head = Path(td) / 'dm/gfx/nvn'; head.mkdir(parents=True, exist_ok=True)
        (head / 'dmsh_chain.h').write_text(f'#define DMSH_CHAIN "{chain}"\n')
        route = {'reach': (120, 5), 'shots': [4]}
        green = {'exit': None, 'max_frame': 180, 'reached': True, 'secs': 6, 'shots': {'4': {'dhash': '0123456789abcdef', 'rgb16': '00' * 768}}}
        label = 'candidate' if command == 'check' else 'baseline'
        gr = {'status': status, **({'smoke': {'route': route, label: [green] if runs is None else runs}} if smoke else {})}
        rep = {'command': command, 'mode': mode, 'machine': {'model': 'Mac14,6', 'macos': '26.1'}, 'games': {'g1': gr}}
        tree = NS(commit='0123456789abcdef', dirty=dirty, path=Path(td))
        with patch.object(regress, 'REPO', Path(td)), patch.object(regress, 'say'):
            regress.record_validated(NS(record=record), rep, tree, [NS(id='g1', derived=derived)])
        return games / 'g1/validated.tsv'

    def test_green_writes_the_file(self):
        for status in ('PASS', 'CHANGED'):
            with self.subTest(status), tempfile.TemporaryDirectory() as td:
                f = self.run_record(td, status)
                self.assertTrue(f.read_text().startswith('# '))
                row = regress.read_validated(f)['quick']
                self.assertEqual((row['chain'], row['commit'], row['machine'], row['macos']), ('aaaa11112222', '0123456789', 'Mac14,6', '26.1'))
                self.assertRegex(row['date'], r'^\d{4}-\d\d-\d\d$')

    def test_modes_keep_one_row_each(self):
        with tempfile.TemporaryDirectory() as td:
            self.run_record(td, 'PASS', mode='quick', chain='aaaa11112222')
            f = self.run_record(td, 'PASS', mode='full', chain='bbbb33334444')
            self.run_record(td, 'PASS', mode='quick', chain='cccc55556666')
            rows = regress.read_validated(f)
            self.assertEqual((rows['quick']['chain'], rows['full']['chain']), ('cccc55556666', 'bbbb33334444'))
            self.assertEqual(sum(1 for x in f.read_text().splitlines() if not x.startswith('#')), 2)

    def test_red_leaves_the_record(self):
        for status in ('NEW-FAIL', 'REGRESSION', 'ERROR'):
            with self.subTest(status), tempfile.TemporaryDirectory() as td:
                f = self.run_record(td, 'PASS'); before = f.read_text()
                self.run_record(td, status, chain='bbbb33334444')
                self.assertEqual(f.read_text(), before)

    def test_without_record_no_file(self):
        with tempfile.TemporaryDirectory() as td:
            self.assertFalse(self.run_record(td, 'PASS', record=False).exists())

    def test_no_boot_run_no_file(self):   # a chain-only result says nothing about the game's boot
        with tempfile.TemporaryDirectory() as td:
            self.assertFalse(self.run_record(td, 'PASS', smoke=False).exists())
            self.assertFalse(self.run_record(td, 'PASS', mode='static').exists())

    def test_known_boot_failure_keeps_last_green(self):
        route = {'reach': (120, 5), 'shots': [4]}
        green = {'exit': None, 'max_frame': 180, 'reached': True, 'secs': 6, 'shots': {'4': {'dhash': '0123456789abcdef', 'rgb16': '00' * 768}}}
        for failure in ({'crash': {'signal': 'SIGSEGV'}}, {'exit': 1}, {'hang_at_s': 3}, {'max_frame': -1},
                        {'reached': False}, {'prebuild': {'exit': 1}}, {'shots': {}}):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as td:
                failed = green | failure
                levels, known, _ = regress.smoke_diff([failed], [failed], route)
                self.assertFalse(any(levels.values()))   # unchanged broken boots are PASS in a regression check
                self.assertTrue(known)
                f = self.run_record(td, 'PASS'); before = f.read_text()
                self.run_record(td, 'PASS', chain='bbbb33334444', runs=[failed])
                self.assertEqual(f.read_text(), before)

    def test_empty_or_partially_failed_runs_do_not_record(self):
        for runs in ([], [{'max_frame': 1}, {'max_frame': -1}]):
            with self.subTest(runs=runs), tempfile.TemporaryDirectory() as td:
                self.assertFalse(self.run_record(td, 'PASS', runs=runs).exists())

    def test_baseline_success_can_record(self):
        with tempfile.TemporaryDirectory() as td:
            self.assertTrue(self.run_record(td, 'PASS', command='baseline').is_file())

    def test_derived_profile_does_not_validate_repository_profile(self):
        with tempfile.TemporaryDirectory() as td:
            f = self.run_record(td, 'PASS'); before = f.read_text()
            self.run_record(td, 'PASS', chain='bbbb33334444', derived=True)
            self.assertEqual(f.read_text(), before)

    def test_record_error_keeps_completed_report(self):
        with tempfile.TemporaryDirectory() as td, ExitStack() as stack:
            root = Path(td)
            self.run_record(td, 'PASS')
            tree = NS(id='tree', path=root, commit='0123456789abcdef', dirty=False,
                      describe=lambda: {'rev': 'test', 'sha': '0123456789abcdef'})
            route = {'reach': None, 'shots': []}
            game = NS(id='g1', name='game', folder=root / 'nsp', derived=False, route=lambda: route)
            manifest = {'key': 'key', 'kind': 'nvn', 'failed': 0, 'total': 1, 'ok': 1}
            a = NS(rev='test', no_smoke=False, quick=True, rewrite=False, runs=1, record=True, out=str(root / 'report'))
            stack.enter_context(patch.object(regress, 'REPO', root))
            stack.enter_context(patch.object(regress, 'Tree', return_value=tree))
            stack.enter_context(patch.object(regress, 'select', return_value=[game]))
            stack.enter_context(patch.object(regress, 'artifacts', return_value={'manifest': manifest}))
            stack.enter_context(patch.object(regress, 'smoke_series', return_value=[{'exit': None, 'max_frame': 180}]))
            stack.enter_context(patch.object(regress, 'smoke_context', return_value={}))
            stack.enter_context(patch.object(regress, 'machine', return_value={'model': 'test', 'chip': 'test', 'macos': 'test', 'xcode': 'test'}))
            stack.enter_context(patch.object(regress, 'say'))
            write_text = Path.write_text
            def fail_record(path, text, *args, **kwargs):
                if path.name == 'validated.tsv': raise PermissionError('read-only profile')
                return write_text(path, text, *args, **kwargs)
            stack.enter_context(patch.object(Path, 'write_text', fail_record))
            with self.assertRaisesRegex(regress.HarnessError, 'regression report was saved'):
                regress.cmd_baseline(a)
            self.assertEqual(json.loads((root / 'report/report.json').read_text())['status'], 'PASS')
            self.assertIn('game `g1`: PASS', (root / 'report/report.md').read_text())

    def test_validation_metadata_does_not_change_profile_inputs(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            prof = root / 'dm/games/g1'; prof.mkdir(parents=True)
            (prof / 'game.tsv').write_text('name\tgame\n')
            g = NS(id='g1', folder=root / 'nsp', derived=False)
            first = regress.Game.profile_dir(g, NS(path=root))
            (prof / 'validated.tsv').write_text('quick\tchain=old\n')
            self.assertEqual(regress.Game.profile_dir(g, NS(path=root)), first)
            self.assertFalse((first / 'validated.tsv').exists())

    def test_dirty_tree(self):
        with tempfile.TemporaryDirectory() as td:
            self.assertEqual(regress.read_validated(self.run_record(td, 'PASS', dirty=True))['quick']['commit'], '0123456789+dirty')

    def test_list_shows_current_and_old(self):
        with tempfile.TemporaryDirectory() as td:
            self.run_record(td, 'PASS', chain='aaaa11112222')
            with patch.object(regress, 'REPO', Path(td)):
                self.assertIn('quick chain aaaa11112222 (current)', regress.validated_text('g1'))
                self.assertEqual(regress.validated_text('nobody'), 'never recorded')
                (Path(td) / 'dm/gfx/nvn/dmsh_chain.h').write_text('#define DMSH_CHAIN "dddd77778888"\n')
                self.assertIn('(old, now dddd77778888)', regress.validated_text('g1'))
                g = NS(id='g1', name='n', kind='nvn', ver='1', folder=Path(td), route=lambda: None)
                with patch.object(regress, 'find_games', return_value=[g]), patch.object(regress, 'say') as say:
                    regress.cmd_list(NS())
                self.assertIn('green: quick chain aaaa11112222 (old', say.call_args.args[0])

    def test_profiles_validated_files_read(self):
        for f in (REPO / 'dm/games').glob('*/validated.tsv'):
            for mode, row in regress.read_validated(f).items():
                self.assertIn(mode, ('quick', 'full'), f)
                self.assertTrue(row.get('chain') and row.get('commit') and row.get('date'), f)


if __name__ == '__main__':
    unittest.main()
