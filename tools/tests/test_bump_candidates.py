"""tools/bump_candidates.py (LNPANDY/NX2Apple#464): the upstream commits of a pin move that touch what the front ends depend on.
No network: the fixture holds the 53 commits of the v1.0.1 bump (v1.0.0 pin bbc3b737 to cd859c38, files and the changed lines that
matter) with the dependencies of that day (the patched files, the launcher's settings, the failure texts); the API is a function that
a test replaces."""
import importlib
import json
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

TOOLS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOLS))
B = importlib.import_module('bump_candidates')
FIX = json.loads((Path(__file__).parent / 'fixtures' / 'bump_range_v1_0_1.json').read_text())


def fixture_ctx():
    c = FIX['ctx']
    return {'patch_paths': c['patch_paths'], 'launch_vars': set(c['launch_vars']), 'fragments': [re.compile(p) for p in c['fragments']]}


def ctx(**kw):
    return {'patch_paths': {}, 'launch_vars': set(), 'fragments': [], **kw}


def commit(files, message='a change', sha='1' * 40):
    return {'sha': sha, 'message': message, 'files': [{'filename': n, 'patch': p} for n, p in files]}


def rows(c, **kw):
    return B.find_candidates([c], ctx(**kw))


class V101Range(unittest.TestCase):
    """The reading of the 53 commits by hand (the v1.0.1 bump, #464) is the ground truth."""
    def setUp(self):
        self.rows = {r['sha'][:8]: r for r in B.find_candidates(FIX['commits'], fixture_ctx())}

    def test_range_is_the_53_commits(self):
        self.assertEqual(len(FIX['commits']), 53)

    def test_the_commits_found_by_hand_are_listed(self):
        by_hand = {
            'd76c45f7': 'chain and Xcode 27.2', 'd3995ca4': 'chain', 'a7bd05f4': 'chain', 'fdb3710d': 'chain', '5251763d': 'chain',
            'c4b0618c': 'chain', '4de40e62': 'chain', '0e8503e7': 'chain',
            '8ef752a2': 'NSP script, --title-id', '99947471': 'NSP script, folder input', '105f417b': 'DM_PSO_GPUS row, script',
            '68e8dc23': 'pso_offline free-space text', 'cd859c38': 'RomFS.img entry layout',
            '70ca6164': 'fps cap (hle_nvn.c, hle_fpslock.c are patched)', '5fd06dd1': 'APFS text (hle_fs.c is patched)',
            'cadd4be6': 'DM_PRESENT_LATENCY row', 'f4bfc015': 'DM_PRESENT_LATENCY row', 'aea257b9': 'DM_NVN_UNWRITTEN_DC row',
            '9f74a1d6': 'front_ios.m, main.m are patched', 'c1df4dda': 'front_mac.m is patched', 'c0f34133': 'front_mac.m',
            '8482873b': 'front_mac.m', 'a5281d01': 'raw HID pads (front_mac.m is patched)', 'dad38db6': 'Launcher.swift is patched',
            '8dd0c98a': 'Switch 2 bring-up',
        }
        for sha, why in by_hand.items():
            self.assertIn(sha, self.rows, f'{sha} ({why}) is missing')

    def test_the_commits_with_no_dependency_are_not_listed(self):
        for sha in ('d2a86b05', 'ba10db3d', '97f1514a', 'b99fca20', 'caac52fb', '588e01a5', '0e16e0e0', 'ecc41fa8', 'b8ffaf8b', '088429f4'):
            self.assertNotIn(sha, self.rows, f'{sha} is listed')

    def test_the_list_is_the_fixture_s_own_ground_truth(self):
        self.assertEqual(sorted(self.rows), sorted(FIX['listed']))
        self.assertEqual(sorted(set(c['sha'][:8] for c in FIX['commits']) - set(self.rows)), sorted(FIX['not_listed']))

    def test_the_xcode_pin_row_names_the_chain_and_the_requirement(self):
        why = '; '.join(self.rows['d76c45f7']['why'])
        self.assertIn('shader chain', why)
        self.assertIn('own_compilers.py', why)

    def test_env_rows_name_the_variable(self):
        self.assertIn('DM_PSO_GPUS', '; '.join(self.rows['105f417b']['why']))
        self.assertIn('DM_PRESENT_LATENCY', '; '.join(self.rows['f4bfc015']['why']))

    def test_the_script_rows_say_what_changed(self):
        why = '; '.join(self.rows['99947471']['why'])
        self.assertIn('an argument', why)
        self.assertIn('the setting block', '; '.join(self.rows['8ef752a2']['why']))

    def test_the_order_is_the_range_order(self):
        shas = [r['sha'][:8] for r in B.find_candidates(FIX['commits'], fixture_ctx())]
        order = [c['sha'][:8] for c in FIX['commits']]
        self.assertEqual(shas, sorted(shas, key=order.index))

    def test_the_table(self):
        t = B.format_table(B.find_candidates(FIX['commits'], fixture_ctx()), FIX['old'], FIX['new'], 53)
        self.assertIn('## Candidate commits (38 of 53)', t)
        self.assertIn('not a verdict', t)
        self.assertIn('| Commit | Title | Files | Why | Handled |', t)
        self.assertEqual(len([l for l in t.splitlines() if l.startswith('| `')]), 38)
        self.assertTrue(all(l.endswith('| |') for l in t.splitlines() if l.startswith('| `')), 'the Handled column is empty')
        self.assertIn('https://github.com/seedds/nxnative/compare/bbc3b7378475...cd859c38a8f8', t)


class Rules(unittest.TestCase):
    def test_chain_files_by_name(self):
        for n in ('dm/gfx/nvn/dmsh_chain.h', 'dm/gfx/tools/dmsh_chain.lock', 'dm/gfx/nvn/dmsh_chain.lock'):
            self.assertEqual(len(rows(commit([(n, '')]))), 1, n)

    def test_own_compilers(self):
        self.assertEqual(len(rows(commit([('dm/gfx/tools/own_compilers.py', '')]))), 1)

    def test_nothing_we_depend_on(self):
        self.assertEqual(rows(commit([('dm/games/0100/README.md', ''), ('dm/host/tests/t_x.c', ''), ('docs/reference/audio.md', '')])), [])

    def test_breaking_line_and_for_front_ends_come_first(self):
        a = commit([('dm/gfx/nvn/dmsh_chain.h', '')], sha='a' * 40)
        b = commit([('README.md', '')], 'x\n\nBreaking: the manifest key moved', sha='b' * 40)
        c = commit([('README.md', '')], 'y\n\n## For front ends\n\nuse the new field', sha='c' * 40)
        got = B.find_candidates([a, b, c], ctx())
        self.assertEqual([r['sha'][0] for r in got], ['b', 'c', 'a'])
        self.assertTrue(got[0]['breaking'] and got[1]['breaking'] and not got[2]['breaking'])
        self.assertEqual(rows(commit([('README.md', '')], 'a breaking change of the lint')), [])   # no such line

    def test_env_new_row_is_no_candidate_a_removed_or_rewritten_one_is(self):
        new = '+DM_NEW\tdiagnostic\ta new row'
        self.assertEqual(rows(commit([(B.ENV_TSV, new)])), [])
        gone = '-DM_OLD\tdiagnostic\tthe row'
        self.assertIn('env row removed: DM_OLD', rows(commit([(B.ENV_TSV, gone)]))[0]['why'][0])
        rew = '-DM_X\tdiagnostic\told text\n+DM_X\tdiagnostic\tnew text'
        self.assertIn('env row rewritten: DM_X', rows(commit([(B.ENV_TSV, rew)]))[0]['why'][0])
        same = '-DM_X\ta\tt\n+DM_X\ta\tt'
        self.assertEqual(rows(commit([(B.ENV_TSV, same)])), [])

    def test_env_row_the_launcher_shows_is_flagged(self):
        rew = '-DM_FPS_TARGET\ta\told\n+DM_FPS_TARGET\ta\tnew\n-DM_OTHER\ta\told\n+DM_OTHER\ta\tnew'
        why = rows(commit([(B.ENV_TSV, rew)]), launch_vars={'DM_FPS_TARGET'})[0]['why'][0]
        self.assertIn('DM_FPS_TARGET (launcher shows it)', why)
        self.assertNotIn('DM_OTHER (launcher', why)

    def test_script_lines(self):
        s = lambda l: rows(commit([(B.NSP_SCRIPT, l)]))
        self.assertIn('an argument', s("+    ap.add_argument('--title-id')")[0]['why'][0])
        self.assertIn('the setting block', s('+TITLE_ID = None')[0]['why'][0])
        self.assertIn('an exit or an error text', s("+    sys.exit(3)")[0]['why'][0])
        self.assertEqual(s('+    x = compute()'), [])            # an inner line says nothing
        self.assertIn('no diff', rows(commit([(B.NSP_SCRIPT, '')]))[0]['why'][0])   # the API leaves the diff out of a big file

    def test_failure_text_in_any_source_file(self):
        frag = [re.compile('need the zbic package')]
        c = commit([('dm/tools/nso.py', '-    die("need the zbic package (pip)")\n+    die("needs zbic")')])
        self.assertIn('failure row matches', rows(c, fragments=frag)[0]['why'][0])
        self.assertEqual(rows(commit([('dm/tools/tests/test_nso.py', '+ need the zbic package')]), fragments=frag), [])

    def test_red_text_in_a_tool_and_not_in_the_host(self):
        self.assertEqual(len(rows(commit([('dm/gfx/tools/pso_offline.py', '+    print("[RED] pso_offline: low")')]))), 1)
        self.assertEqual(rows(commit([('dm/host/hle_x.c', '+  log("[RED] x")')])), [])

    def test_interface_files_events_and_manifest(self):
        self.assertEqual(len(rows(commit([('docs/frontends.md', '')]))), 1)
        self.assertEqual(len(rows(commit([('dm/launcher.json', '')]))), 1)
        self.assertEqual(len(rows(commit([('scripts/pack.py', "+    P.event('stage_end', ok=True)")]))), 1)
        self.assertEqual(rows(commit([('dm/host/x.c', "+    event('x')")])), [])
        self.assertEqual(len(rows(commit([('dm/tools/x.py', "+    P.event('shaders_stale', n=1)")]))), 1)
        self.assertEqual(len(rows(commit([('dm/tools/x.py', "+    open('game.manifest.json', 'w')")]))), 1)

    def test_binary_layouts(self):
        for n in ('dm/host/romfs_image.h', 'dm/tools/romfs_image.py', 'dm/tools/romfs.py'):
            self.assertEqual(len(rows(commit([(n, '')]))), 1, n)

    def test_patched_files_count_but_documents_tests_and_makefiles_do_not(self):
        paths = {'dm/host/front_mac.m': ['0009', '0032'], 'docs/development.md': ['0005'], 'dm/host/tests/Makefile': ['0001']}
        got = rows(commit([('dm/host/front_mac.m', '')]), patch_paths=paths)
        self.assertEqual(got[0]['why'], ['files our patches change: front_mac.m (0009, 0032)'])
        self.assertEqual(rows(commit([('docs/development.md', ''), ('dm/host/tests/Makefile', '')]), patch_paths=paths), [])

    def test_patch_headers_are_read(self):
        with tempfile.TemporaryDirectory() as t:
            (Path(t) / 'patches').mkdir()
            (Path(t) / 'patches' / '0007-x.patch').write_text('From abc\n\ndiff --git a/dm/host/a.c b/dm/host/a.c\n--- a/dm/host/a.c\n'
                                                               'diff --git a/dm/old.c b/dm/renamed.c\n')
            got = B.patch_paths(t)
            self.assertEqual(got['dm/host/a.c'], ['0007'])
            self.assertEqual(sorted(got), ['dm/host/a.c', 'dm/old.c', 'dm/renamed.c'])

    def test_failure_fragments_come_from_the_swift_rows(self):
        with tempfile.TemporaryDirectory() as t:
            f = Path(t) / B.BUILD_FAILURE
            f.parent.mkdir(parents=True)
            f.write_text('("a.b", .kind, "the shader translator does not run ("),\n("c", .k, "(?m)^\\\\[RED\\\\] no such file: "),\n')
            got = B.failure_fragments(t)
            self.assertTrue(got[0].search('x the shader translator does not run (y'))   # an unbalanced "(" is a text
            self.assertTrue(got[1].search('[RED] no such file: /k'))

    def test_launch_vars_from_the_localization(self):
        with tempfile.TemporaryDirectory() as t:
            f = Path(t) / B.LOCALIZATION
            f.parent.mkdir(parents=True)
            f.write_text('"launch.set.DM_FPS_TARGET": ("a", "b"),\n"launch.set.DM_FPS_TARGET.note": ("c", "d"),\n"launch.set.DM_RUMBLE": ("e", "f"),')
            self.assertEqual(B.launch_vars(t), {'DM_FPS_TARGET', 'DM_RUMBLE'})

    def test_this_checkout_has_the_inputs(self):
        c = B.context(B.REPO)
        self.assertTrue(c['patch_paths'], 'no patch file read')
        self.assertIn('DM_FPS_TARGET', c['launch_vars'])
        self.assertTrue(c['fragments'], 'no failure row read from BuildFailure.swift')


class Sources(unittest.TestCase):
    def test_api_commits_and_the_fallback(self):
        calls = []

        def api(path):
            calls.append(path)
            if '/compare/' in path:
                return {'total_commits': 1, 'commits': [{'sha': 'a' * 40, 'commit': {'message': 'T\n\nbody'}}]}
            return {'files': [{'filename': 'docs/frontends.md', 'patch': '@@\n+x'}, {'filename': 'big.bin'}]}
        got = B.fetch_commits('o' * 40, 'n' * 40, eng=None, api=api)
        self.assertEqual(got, [{'sha': 'a' * 40, 'message': 'T\n\nbody', 'files': [{'filename': 'docs/frontends.md', 'patch': '@@\n+x'}, {'filename': 'big.bin', 'patch': ''}]}])
        self.assertEqual(calls, [f'repos/seedds/nxnative/compare/{"o" * 40}...{"n" * 40}?per_page=100', f'repos/seedds/nxnative/commits/{"a" * 40}?per_page=100'])

    def test_a_truncated_compare_is_an_error(self):
        api = lambda p: {'total_commits': 300, 'commits': [{'sha': 'a' * 40, 'commit': {'message': 'm'}}]}
        with self.assertRaises(RuntimeError): B.api_commits('o', 'n', api)

    def test_local_git_is_used_when_it_holds_both_pins(self):
        with tempfile.TemporaryDirectory() as t:
            def g(*a):
                r = subprocess.run(['git', '-c', 'user.name=t', '-c', 'user.email=t@example.invalid', '-c', 'commit.gpgsign=false', *a], cwd=t, capture_output=True, text=True, check=True)
                return r.stdout.strip()
            g('init', '-q')
            (Path(t) / 'a.txt').write_text('1\n')
            g('add', '-A'); g('commit', '-q', '-m', 'one')
            old = g('rev-parse', 'HEAD')
            (Path(t) / 'docs').mkdir()
            (Path(t) / 'docs' / 'frontends.md').write_text('x\n')
            g('add', '-A'); g('commit', '-q', '-m', 'two\n\nBreaking: yes')
            new = g('rev-parse', 'HEAD')
            def no_api(p): raise AssertionError('the network was used')
            got = B.fetch_commits(old, new, eng=t, api=no_api)
            self.assertEqual([c['files'][0]['filename'] for c in got], ['docs/frontends.md'])
            self.assertEqual(len(B.find_candidates(got, ctx())), 1)
            self.assertIsNone(B.local_commits(t, 'f' * 40, new))   # a pin it does not have: the API takes over

    def test_report_survives_no_network(self):
        def api(p): raise RuntimeError('no gh')
        with tempfile.TemporaryDirectory() as t:
            out = B.report(t, 'o' * 40, 'n' * 40, eng=None, api=api)
        self.assertIn('Not made: no gh', out)


if __name__ == '__main__':
    unittest.main()
