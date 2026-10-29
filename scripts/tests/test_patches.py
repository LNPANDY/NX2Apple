"""scripts/patches.py on a fixture repository: the series reproduces the vendored tree, a patch that upstream took drops on a bump,
a conflict names its patch, export writes the header, a patch that touches the shader chain is rejected, and the list of carried
patches is generated, and the generated indexes are regenerated on the patched tree. No game files, no network: upstream is a branch of the fixture."""
import importlib.util, os, shutil, subprocess, sys, tempfile, unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
TOOL = REPO / 'scripts/patches.py'
spec = importlib.util.spec_from_file_location('patches_tool', TOOL)
P = importlib.util.module_from_spec(spec); spec.loader.exec_module(P)

ENV = dict(os.environ, GIT_AUTHOR_NAME='t', GIT_AUTHOR_EMAIL='t@example.invalid', GIT_COMMITTER_NAME='t', GIT_COMMITTER_EMAIL='t@example.invalid',
           GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_SYSTEM='/dev/null')


def git(cwd, *a, check=True):
    r = subprocess.run(['git', '-c', 'commit.gpgsign=false', *a], cwd=cwd, capture_output=True, text=True, env=ENV)
    if check and r.returncode: raise AssertionError(f'git {a}: {r.stderr}')
    return r.stdout.strip()


class Fixture(unittest.TestCase):
    """repo/: upstream's first commit (branch up) with the fork's one edit on top, exported as a patch, and the tool installed."""
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix='test-patches-'))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.r = self.tmp / 'repo'; self.r.mkdir()
        git(self.r, 'init', '-q', '-b', 'main')
        self.w('dm/a.c', 'line1\nline2\nline3\nline4\nline5\nline6\nline7\n')
        self.w('dm/b.c', 'b1\nb2\n')
        self.w('docs/x.md', 'x\n')
        shutil.copy(REPO / 'AGENTS.md', self.r / 'AGENTS.md')
        git(self.r, 'add', '-A'); git(self.r, 'commit', '-q', '-m', 'upstream 1')
        self.up1 = git(self.r, 'rev-parse', 'HEAD')
        git(self.r, 'branch', 'up')
        # the tool lives in the fork's scripts/, which is vendored but not part of the generated tree
        (self.r / 'scripts').mkdir(); shutil.copy(TOOL, self.r / 'scripts/patches.py')
        self.w('dm/a.c', 'line1\nline2 fork\nline3\nline4\nline5\nline6\nline7\n')
        git(self.r, 'add', '-A'); git(self.r, 'commit', '-q', '-m', 'Make line 2 the fork\'s\n\nWhy: a test.')
        self.run_tool('export', 'HEAD', '--status', 'forwarded seedds/nxnative#475', '--reason', 'the fork needs line 2', '--issue', 'LNPANDY/NX2Apple#1')
        (self.r / '.upstream-ref').write_text(self.up1 + '\n')
        git(self.r, 'add', '-A'); git(self.r, 'commit', '-q', '-m', 'patches')
        self.patch = next((self.r / 'patches').glob('0001-*.patch'))

    def w(self, path, text):
        f = self.r / path; f.parent.mkdir(parents=True, exist_ok=True); f.write_text(text)

    def run_tool(self, *a, expect=0):
        r = subprocess.run([sys.executable, str(self.r / 'scripts/patches.py'), '--tmp', str(self.tmp), *a], cwd=self.r, capture_output=True, text=True, env=ENV)
        if expect is not None: self.assertEqual(r.returncode, expect, r.stdout + r.stderr)
        return r.stdout + r.stderr

    def upstream_commit(self, files, msg):
        """A new commit on branch up (a child of the last one), made in a scratch worktree."""
        wt = self.tmp / 'upwt'
        git(self.r, 'worktree', 'add', '-q', str(wt), 'up')
        for p, t in files.items():
            (wt / p).parent.mkdir(parents=True, exist_ok=True); (wt / p).write_text(t)
        git(wt, 'add', '-A'); git(wt, 'commit', '-q', '-m', msg)
        sha = git(wt, 'rev-parse', 'HEAD')
        git(self.r, 'worktree', 'remove', '--force', str(wt))
        return sha


class ApplyAndCheck(Fixture):
    def test_series_on_the_pin_reproduces_the_tree(self):
        out = self.run_tool('check')
        self.assertIn('1 patches apply', out)
        self.assertEqual((self.r / 'dm/fork_patches.txt').read_text(), 'make-line-2-the-fork-s\n')

    def test_a_hand_edit_of_a_vendored_file_fails_check_and_apply_restores_it(self):
        self.w('dm/b.c', 'b1\nb2 edited\n')
        out = self.run_tool('check', expect=1)
        self.assertIn('dm/b.c', out); self.assertIn('run `python3 scripts/patches.py absorb dm/b.c` and commit patches/', out)
        self.run_tool('apply')
        self.assertEqual((self.r / 'dm/b.c').read_text(), 'b1\nb2\n')
        self.run_tool('check')

    def test_apply_deletes_a_tracked_file_the_series_does_not_produce(self):
        self.w('dm/stray.c', 'x\n'); git(self.r, 'add', 'dm/stray.c')
        self.run_tool('check', expect=1)
        self.run_tool('apply')
        self.assertFalse((self.r / 'dm/stray.c').exists())

    def test_a_patch_without_a_header_fails_check(self):
        text = self.patch.read_text().replace('Reason: the fork needs line 2\n', '')
        self.patch.write_text(text)
        self.assertIn('Reason is missing', self.run_tool('check', expect=1))

    def test_status_lists_the_patch(self):
        out = self.run_tool('status')
        self.assertIn('forwarded seedds/nxnative#475', out); self.assertIn('the fork needs line 2', out)


class Bump(Fixture):
    def test_a_patch_upstream_has_taken_drops_and_is_listed(self):
        new = self.upstream_commit({'dm/a.c': 'line1\nline2 fork\nline3\nline4\nline5\nline6\nline7\n', 'docs/y.md': 'y\n'}, 'upstream 2: takes the fix')
        out = self.run_tool('bump', '--to', new)
        self.assertIn('landed upstream, dropped (1): make-line-2-the-fork-s', out)
        self.assertFalse(self.patch.exists())
        self.assertNotIn('0001', (self.r / 'patches/series').read_text())
        self.assertEqual((self.r / '.upstream-ref').read_text().strip(), new)
        self.assertEqual((self.r / 'docs/y.md').read_text(), 'y\n')
        self.assertEqual((self.r / 'dm/fork_patches.txt').read_text(), '')
        self.run_tool('check')

    def test_a_patch_that_still_applies_is_refreshed_on_the_new_base(self):
        new = self.upstream_commit({'dm/a.c': 'line1\nline2\nline3\nline4\nline5\nline6\nline7 upstream\n'}, 'upstream 2: touches line 7')
        out = self.run_tool('bump', '--to', new)
        self.assertIn('applied cleanly (1): make-line-2-the-fork-s', out)
        self.assertEqual((self.r / 'dm/a.c').read_text(), 'line1\nline2 fork\nline3\nline4\nline5\nline6\nline7 upstream\n')
        self.run_tool('check')

    def test_a_conflict_names_the_patch_its_reason_and_status_and_changes_nothing(self):
        new = self.upstream_commit({'dm/a.c': 'line1\nline2 upstream\nline3\nline4\nline5\nline6\nline7\n'}, 'upstream 2: its own line 2')
        before = (self.r / 'dm/a.c').read_text()
        for args in (('--dry',), ()):
            out = self.run_tool('bump', *args, '--to', new, expect=1)
            self.assertIn(self.patch.name, out)
            self.assertIn('Reason: the fork needs line 2', out)
            self.assertIn('Upstream-Status: forwarded seedds/nxnative#475', out)
            self.assertIn('dm/a.c', out)
            self.assertEqual((self.r / '.upstream-ref').read_text().strip(), self.up1)
            self.assertEqual((self.r / 'dm/a.c').read_text(), before)
            self.assertTrue(self.patch.exists())

    def test_the_conflict_is_left_in_a_worktree_for_a_human(self):
        new = self.upstream_commit({'dm/a.c': 'line1\nline2 upstream\nline3\nline4\nline5\nline6\nline7\n'}, 'upstream 2: its own line 2')
        out = self.run_tool('bump', '--to', new, expect=1)
        wt = next(l.split(' is left in ')[1].split(':')[0] for l in out.splitlines() if ' is left in ' in l)
        self.assertTrue((Path(wt) / 'dm/a.c').read_text().count('<<<<<<<') == 1)
        git(wt, 'checkout', '--theirs', 'dm/a.c'); git(wt, 'add', 'dm/a.c')
        git(wt, '-c', 'user.name=t', '-c', 'user.email=t@example.invalid', 'am', '--continue')
        self.run_tool('refresh', wt, '--to', new)
        self.assertEqual((self.r / '.upstream-ref').read_text().strip(), new)
        self.assertEqual((self.r / 'dm/a.c').read_text().splitlines()[1], 'line2 fork')
        self.run_tool('check')
        git(self.r, 'worktree', 'remove', '--force', wt)


class Absorb(Fixture):
    def export_second(self):
        """A second patch, on dm/b.c, so that dm/ has two owners."""
        self.w('dm/b.c', 'b1\nb2 fork\n'); git(self.r, 'add', '-A'); git(self.r, 'commit', '-q', '-m', 'Fork b2')
        self.run_tool('export', 'HEAD', '--reason', 'r', '--issue', 'LNPANDY/NX2Apple#2')
        git(self.r, 'add', '-A'); git(self.r, 'commit', '-q', '-m', 'patches 2')

    def test_an_edit_of_a_file_a_patch_touches_goes_into_that_patch(self):
        self.w('dm/a.c', 'line1\nline2 fork\nline3\nline4\nline5\nline6\nline7 more\n')
        self.run_tool('check', expect=1)
        out = self.run_tool('absorb')
        self.assertIn('absorbed dm/a.c', out); self.assertIn('patch queue: ok', out)
        self.assertIn('+line7 more', self.patch.read_text())
        self.assertIn('Reason: the fork needs line 2', self.patch.read_text())   # the header survives
        self.run_tool('check')

    def test_absorb_works_on_a_committed_edit_too(self):
        self.w('dm/a.c', 'line1\nline2 fork\nline3\nline4\nline5\nline6\nline7 more\n'); git(self.r, 'add', '-A'); git(self.r, 'commit', '-q', '-m', 'direct')
        self.run_tool('check', expect=1)
        self.run_tool('absorb', 'dm/a.c')
        self.run_tool('check')

    def test_a_file_goes_to_the_last_patch_that_touches_it(self):
        self.export_second()
        self.w('dm/b.c', 'b1\nb2 fork\nb3\n')
        self.run_tool('absorb')
        self.assertIn('+b3', (self.r / 'patches/0002-fork-b2.patch').read_text())
        self.assertNotIn('+b3', self.patch.read_text())

    def test_a_new_file_next_to_a_patched_one_goes_to_its_patch(self):
        self.w('dm/new.c', 'n\n')
        self.assertIn('dm/new.c', self.run_tool('absorb'))
        self.assertIn('+++ b/dm/new.c', self.patch.read_text())
        self.run_tool('check')

    def test_a_new_file_in_an_untouched_folder_stops_and_asks_for_into(self):
        self.w('docs/y.md', 'y\n')
        out = self.run_tool('absorb', expect=2)
        self.assertIn('docs/y.md', out); self.assertIn('--into <patch>', out)
        self.assertNotIn('docs/y.md', self.patch.read_text())   # nothing was written
        self.run_tool('absorb', '--into', 'make-line-2-the-fork-s', 'docs/y.md')
        self.assertIn('+++ b/docs/y.md', self.patch.read_text())
        self.run_tool('check')

    def test_a_new_file_in_a_folder_two_patches_touch_is_ambiguous(self):
        self.export_second()
        self.w('dm/c.c', 'c\n')
        out = self.run_tool('absorb', expect=2)
        self.assertIn('ambiguous', out); self.assertIn('fork-b2', out); self.assertIn('make-line-2-the-fork-s', out)
        self.run_tool('absorb', '--into', 'fork-b2', 'dm/c.c')
        self.assertIn('+++ b/dm/c.c', (self.r / 'patches/0002-fork-b2.patch').read_text())

    def test_paths_limit_what_is_folded_in(self):
        self.w('dm/a.c', 'line1\nline2 fork\nline3\nline4\nline5\nline6\nline7 more\n'); self.w('dm/b.c', 'b1\nb2 edited\n')
        out = self.run_tool('absorb', 'dm/a.c', expect=1)   # dm/b.c is still a difference, so the closing check fails
        self.assertIn('absorbed dm/a.c', out); self.assertNotIn('absorbed dm/b.c', out)
        self.assertIn('absorb dm/b.c', out)

    def test_a_deleted_file_is_removed_by_its_patch(self):
        self.w('dm/new.c', 'n\n'); self.run_tool('absorb')
        (self.r / 'dm/new.c').unlink()
        self.run_tool('absorb')
        self.assertNotIn('dm/new.c', self.patch.read_text())
        self.run_tool('check')

    def test_nothing_to_absorb_just_checks(self):
        self.assertIn('nothing to fold in', self.run_tool('absorb'))

    def test_selectors_are_normalised_and_dot_is_the_whole_tree(self):
        self.w('dm/a.c', 'line1\nline2 fork\nline3\nline4\nline5\nline6\nline7 one\n'); self.w('dm/new.c', 'n\n')
        self.assertIn('absorbed dm/a.c', self.run_tool('absorb', './dm/a.c', expect=1))      # dm/new.c is still a difference
        self.assertIn('absorbed dm/new.c', self.run_tool('absorb', str(self.r / 'dm') + '/'))   # absolute, trailing slash
        self.w('dm/b.c', 'b1\nb2 edited\n')
        self.assertIn('absorbed dm/b.c', self.run_tool('absorb', '.'))
        self.assertIn('outside the checkout', self.run_tool('absorb', '../elsewhere', expect=2))

    def test_the_check_hint_lists_the_whole_tree_command_without_truncation(self):
        for n in range(8): self.w(f'dm/n{n}.c', 'n\n')
        out = self.run_tool('check', expect=1)
        self.assertNotIn('...', out)
        self.assertIn('`python3 scripts/patches.py absorb`', out)

    def test_a_full_revert_that_empties_a_patch_is_refused_and_changes_nothing(self):
        self.w('dm/a.c', 'line1\nline2\nline3\nline4\nline5\nline6\nline7\n')
        before = self.patch.read_text()
        out = self.run_tool('absorb', expect=2)
        self.assertIn('would leave', out); self.assertIn('empty', out)
        self.assertEqual(self.patch.read_text(), before)

    def test_into_that_makes_a_later_patch_empty_is_refused_before_writing(self):
        self.export_second()          # 0002 sets b2 to "b2 fork"; putting dm/b.c into 0001 makes 0002 a no-op or a conflict
        self.w('dm/b.c', 'b1\nb2 fork\nb3\n')
        before = {f.name: f.read_text() for f in (self.r / 'patches').glob('*.patch')}
        out = self.run_tool('absorb', '--into', 'make-line-2-the-fork-s', 'dm/b.c', expect=2)
        self.assertTrue('would be empty' in out or 'no longer applies' in out, out)
        self.assertEqual(before, {f.name: f.read_text() for f in (self.r / 'patches').glob('*.patch')})

    def test_the_shader_chain_is_refused(self):
        self.w('dm/gfx/nvn/dmsh_chain.h', 'x\n')
        self.assertIn('shader chain', self.run_tool('absorb', expect=2))


class Export(Fixture):
    def commit_edit(self, msg, path='dm/b.c', text='b1\nb2 changed\n'):
        self.w(path, text); git(self.r, 'add', '-A'); git(self.r, 'commit', '-q', '-m', msg)

    def test_export_writes_the_header_template_and_extends_the_series(self):
        self.commit_edit('Change b2')
        out = self.run_tool('export', 'HEAD')
        new = sorted((self.r / 'patches').glob('0002-*.patch'))
        self.assertEqual(len(new), 1, out)
        text = new[0].read_text()
        for key in ('Upstream-Status: pending', 'Reason: TODO', 'Issue: TODO'): self.assertIn(key, text)
        self.assertIn('Subject: [PATCH] Change b2', text)
        self.assertIn('0002-change-b2.patch', (self.r / 'patches/series').read_text().splitlines())
        self.assertEqual((self.r / 'dm/fork_patches.txt').read_text(), 'make-line-2-the-fork-s\nchange-b2\n')
        self.assertIn('still the export template', self.run_tool('check', expect=1))   # the header has to be filled in

    def test_export_keeps_a_header_the_commit_already_has(self):
        self.commit_edit('Change b2\n\nUpstream-Status: backport abcdef1\nReason: r\nIssue: LNPANDY/NX2Apple#2')
        self.run_tool('export', 'HEAD')
        text = next((self.r / 'patches').glob('0002-*.patch')).read_text()
        self.assertEqual(text.count('Upstream-Status:'), 1); self.assertIn('backport abcdef1', text)
        self.run_tool('check')

    def test_export_of_a_range_makes_one_patch_per_commit(self):
        base = git(self.r, 'rev-parse', 'HEAD')
        self.commit_edit('First', text='b1\nb2 first\n'); self.commit_edit('Second', 'docs/x.md', 'x2\n')
        self.run_tool('export', f'{base}..HEAD', '--reason', 'r', '--issue', 'LNPANDY/NX2Apple#3')
        self.assertEqual(len(list((self.r / 'patches').glob('000[23]-*.patch'))), 2)
        self.run_tool('check')

    def test_export_skips_a_commit_outside_the_vendored_paths(self):
        self.commit_edit('Frontend only', 'frontend/x.swift', 'x\n')
        out = self.run_tool('export', 'HEAD')
        self.assertIn('no change under the vendored paths', out)
        self.assertFalse(list((self.r / 'patches').glob('0002-*')))


class ChainRule(Fixture):
    def test_the_chain_paths_come_from_agents_md(self):
        g = P.chain_paths(self.r)
        for want in ('dm/gfx/nvn/dmsh_chain.h', 'dm/gfx/tools/dmsh_*', 'dm/gfx/tools/Program.cs', 'dm/gfx/tools/ios_metal.py', 'dm/gfx/tools/dmsh_chain.lock', 'dm/gfx/tools/dmsh_xlate_bin*'):
            self.assertIn(want, g)

    def test_export_rejects_a_commit_that_touches_the_chain(self):
        for path in ('dm/gfx/nvn/dmsh_chain.h', 'dm/gfx/tools/dmsh_build.py', 'dm/gfx/tools/Program.cs', 'dm/gfx/tools/dmsh_chain.lock', 'dm/gfx/tools/dmsh_xlate_bin/x'):
            self.w(path, 'x\n'); git(self.r, 'add', '-A'); git(self.r, 'commit', '-q', '-m', f'touch {path}')
            out = self.run_tool('export', 'HEAD', expect=2)
            self.assertIn(path, out); self.assertIn('shader chain', out)
        self.assertFalse(list((self.r / 'patches').glob('0002-*')))

    def test_check_rejects_a_patch_in_the_series_that_touches_the_chain(self):
        self.w('dm/gfx/tools/dmsh_pull.py', 'x\n'); git(self.r, 'add', '-A'); git(self.r, 'commit', '-q', '-m', 'chain tool')
        diff = git(self.r, 'format-patch', '--stdout', '-1', 'HEAD')
        text = diff.replace('\n---\n', '\n\nUpstream-Status: pending\nReason: r\nIssue: LNPANDY/NX2Apple#4\n---\n', 1) + '\n'
        (self.r / 'patches/0002-chain.patch').write_text(text)
        s = self.r / 'patches/series'; s.write_text(s.read_text() + '0002-chain.patch\n')
        out = self.run_tool('check', expect=1)
        self.assertIn('0002-chain.patch', out); self.assertIn('dm/gfx/tools/dmsh_pull.py', out)

    def test_chain_free_patches_pass(self):
        self.run_tool('check')


class ForkPatchList(Fixture):
    def test_check_fails_when_the_generated_list_is_stale(self):
        (self.r / 'dm/fork_patches.txt').write_text('something-else\n')
        self.assertIn('fork_patches.txt', self.run_tool('check', expect=1))
        self.run_tool('apply')
        self.run_tool('check')

    def test_the_list_follows_the_series_order(self):
        self.w('dm/b.c', 'b1\nb2 changed\n'); git(self.r, 'add', '-A'); git(self.r, 'commit', '-q', '-m', 'Second thing')
        self.run_tool('export', 'HEAD', '--reason', 'r', '--issue', 'LNPANDY/NX2Apple#5')
        self.run_tool('apply')
        self.assertEqual((self.r / 'dm/fork_patches.txt').read_text().split(), ['make-line-2-the-fork-s', 'second-thing'])

    def test_the_mac_app_stamps_the_list_into_info_plist(self):
        """pack_app.py's DMForkPatches is dm/fork_patches.txt, comma-separated, and empty without the file"""
        sys.path.insert(0, str(REPO / 'dm/tools'))
        spec = importlib.util.spec_from_file_location('pack_app_under_test', REPO / 'dm/mac/pack_app.py')
        mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
        fake = self.tmp / 'dm/mac'; fake.mkdir(parents=True)
        mod.__file__ = str(fake / 'pack_app.py')
        self.assertEqual(mod.fork_patches(), '')
        (self.tmp / 'dm/fork_patches.txt').write_text('runtime-profile\nbc-cpu-decode\n')
        self.assertEqual(mod.fork_patches(), 'runtime-profile,bc-cpu-decode')
        args = type('A', (), dict(name='G', bundle_id=None, title_id='0100000000000000', version=None, category=None, marker=None, lang=None, settings=None))()
        self.assertEqual(mod.info_plist(args, '26.0', False)['DMForkPatches'], 'runtime-profile,bc-cpu-decode')

    def test_the_first_log_line_and_the_ios_key_are_in_the_sources(self):
        """a read of the sources, not a run: the iOS app and the Mac launcher write the line, project.yml carries the key"""
        self.assertIn('"fork patches: %s\\n"', (REPO / 'dm/ios/Sources/main.m').read_text())
        self.assertIn('"fork patches: %s\\n"', (REPO / 'dm/mac/launcher.c').read_text())
        self.assertIn('DMForkPatches: ${DM_FORK_PATCHES}', (REPO / 'dm/ios/project.yml').read_text())


class GeneratedIndexes(Fixture):
    """docs/agents/game-patches.md and symptoms.md are written by upstream's tools from the tree: bump, apply and check regenerate them
    on the patched tree, and a patch must not carry them."""
    GEN = ("import pathlib\nr = pathlib.Path(__file__).resolve().parents[2]\n(r / 'docs/agents').mkdir(parents=True, exist_ok=True)\n"
           "(r / 'docs/agents/%s').write_text('fork=%%d\\n' %% ('fork' in (r / 'dm/a.c').read_text()))\n")

    def with_tools(self):
        return self.upstream_commit({'dm/tools/docs_patches.py': self.GEN % 'game-patches.md', 'dm/tools/docs_symptoms.py': self.GEN % 'symptoms.md',
                                     'docs/agents/game-patches.md': 'fork=0\n', 'docs/agents/symptoms.md': 'fork=0\n'}, 'upstream: the index tools')

    def test_bump_writes_the_indexes_from_the_patched_tree(self):
        sha = self.with_tools()
        self.run_tool('bump', '--to', sha)
        for f in ('game-patches.md', 'symptoms.md'): self.assertEqual((self.r / 'docs/agents' / f).read_text(), 'fork=1\n')
        self.assertIn('ok.', self.run_tool('check'))

    def test_check_fails_on_a_stale_index_and_apply_restores_it(self):
        self.run_tool('bump', '--to', self.with_tools())
        (self.r / 'docs/agents/symptoms.md').write_text('stale\n')
        self.assertIn('docs/agents/symptoms.md', self.run_tool('check', expect=1))
        self.run_tool('apply')
        self.run_tool('check')

    def test_a_patch_that_carries_a_generated_file_is_rejected(self):
        self.run_tool('bump', '--to', self.with_tools())
        git(self.r, 'add', '-A'); git(self.r, 'commit', '-q', '-m', 'bump')
        self.w('docs/agents/game-patches.md', 'hand edit\n'); git(self.r, 'add', '-A'); git(self.r, 'commit', '-q', '-m', 'Edit the index by hand')
        self.assertIn('no change under the vendored paths', self.run_tool('export', 'HEAD'))
        text = git(self.r, 'format-patch', '--stdout', '-1', 'HEAD').replace('\n---\n', '\nUpstream-Status: fork-only\nReason: r\nIssue: LNPANDY/NX2Apple#1\n---\n', 1)
        (self.r / 'patches/0002-index.patch').write_text(text + '\n')
        s = self.r / 'patches/series'; s.write_text(s.read_text() + '0002-index.patch\n')
        out = self.run_tool('check', expect=1)
        self.assertIn('0002-index.patch', out); self.assertIn('generated', out)


class HostTestRules(unittest.TestCase):
    def test_sdk16_tests_keep_runtime_profile_linkage_after_refresh(self):
        r = subprocess.run(
            ['make', '-n', '-B', 'GAME=010015100B514000', 'build/t_language', 'build/t_shared_font'],
            cwd=REPO / 'dm/host/tests', capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        for name in ('t_language', 't_shared_font'):
            command = next(line for line in r.stdout.splitlines() if f'-o build/{name} ' in line)
            self.assertIn(f'{name}.c ../hle_profile.c', command)
            if name == 't_language':
                self.assertIn('-fsanitize=address,undefined', command)
        rules = (REPO / 'dm/host/tests/Makefile').read_text().splitlines()
        prerequisites = ' '.join(line for line in rules if line.startswith('run:'))
        for name in ('t_language', 't_input_map', 't_launcher_contract'):
            self.assertIn(f'$(B)/{name}', prerequisites)
            self.assertIn(f'\t$(B)/{name}', rules)


if __name__ == '__main__':
    unittest.main()
