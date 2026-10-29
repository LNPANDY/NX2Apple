"""tools/engine.py on fixture repositories (LNPANDY/NX2Apple#214): sync builds engine/ from the pin and the series, one commit per
patch, and is a no-op while nothing changed; work made in engine/ is never thrown away; export turns it into a patch; offline and
broken cases name the fix; check and bump work on engine/; ripgrep still searches engine/. No network: upstream is a local
repository, reached through NX2APPLE_ENGINE_URL."""
import importlib
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
TOOLS = REPO / 'tools'
SRC = REPO / 'engine' if (REPO / 'engine/AGENTS.md').is_file() else REPO
sys.path.insert(0, str(TOOLS))
E = importlib.import_module('engine')

BASE_ENV = dict(os.environ, GIT_AUTHOR_NAME='t', GIT_AUTHOR_EMAIL='t@example.invalid', GIT_COMMITTER_NAME='t', GIT_COMMITTER_EMAIL='t@example.invalid',
                GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_SYSTEM='/dev/null')
BASE_ENV.pop('NX2APPLE_ENGINE_SEED', None)

HEADER = 'Upstream-Status: forwarded seedds/nxnative#475\nReason: the fork needs line 2\nIssue: LNPANDY/NX2Apple#1\n'


def git(cwd, *a, check=True):
    r = subprocess.run(['git', '-c', 'commit.gpgsign=false', *a], cwd=cwd, capture_output=True, text=True, env=BASE_ENV, check=False)
    if check and r.returncode: raise AssertionError(f'git {a}: {r.stderr}')
    return r.stdout.strip()


class Fixture(unittest.TestCase):
    """up/: upstream with one commit. repo/: the fork (tools/, .upstream-ref, patches/ with one patch made from a commit on up)."""
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix='test-engine-'))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.up = self.tmp / 'up'; self.up.mkdir()
        git(self.up, 'init', '-q', '-b', 'main')
        self.wu('dm/a.c', 'line1\nline2\nline3\nline4\nline5\nline6\nline7\n')
        self.wu('dm/b.c', 'b1\nb2\n')
        self.wu('.gitignore', 'dm/host/gen/\n')
        shutil.copy(SRC / 'AGENTS.md', self.up / 'AGENTS.md')
        git(self.up, 'add', '-A'); git(self.up, 'commit', '-q', '-m', 'upstream 1')
        self.up1 = git(self.up, 'rev-parse', 'HEAD')
        self.r = self.tmp / 'repo'; self.r.mkdir()
        git(self.r, 'init', '-q', '-b', 'main')
        (self.r / 'tools').mkdir()
        for f in ('engine.py', 'patches.py'): shutil.copy(TOOLS / f, self.r / 'tools' / f)
        shutil.copy(REPO / '.ignore', self.r / '.ignore')
        (self.r / '.gitignore').write_text('/engine/\n__pycache__/\n')
        (self.r / '.upstream-ref').write_text(self.up1 + '\n')
        (self.r / 'patches').mkdir()
        self.add_patch('0001-line-2.patch', 'dm/a.c', 'line1\nline2 fork\nline3\nline4\nline5\nline6\nline7\n', 'Make line 2 the fork\'s')
        git(self.r, 'add', '-A'); git(self.r, 'commit', '-q', '-m', 'fork')
        self.env = dict(BASE_ENV, NX2APPLE_ENGINE_URL=str(self.up), PATCHES_TMP=str(self.tmp))
        self.eng = self.r / 'engine'

    def wu(self, path, text, root=None):
        f = (root or self.up) / path; f.parent.mkdir(parents=True, exist_ok=True); f.write_text(text)

    def add_patch(self, name, path, text, subject, header=HEADER, base=None):
        """A patch made on a scratch clone of upstream at base (default: the pin), appended to the series."""
        wt = self.tmp / 'mk'
        shutil.rmtree(wt, True)
        git(self.tmp, 'clone', '-q', str(self.up), str(wt))
        git(wt, 'checkout', '-q', base or self.up1)
        self.wu(path, text, wt)
        git(wt, 'add', '-A'); git(wt, 'commit', '-q', '-m', f'{subject}\n\n{header}')
        patch = git(wt, 'format-patch', '--zero-commit', '--no-signature', '--stdout', '-1', 'HEAD') + '\n'
        (self.r / 'patches' / name).write_text(patch)
        s = self.r / 'patches/series'
        s.write_text((s.read_text() if s.exists() else '# order\n') + name + '\n')

    def tool(self, *a, expect=0, env=None):
        r = subprocess.run([sys.executable, str(self.r / 'tools/engine.py'), *a], cwd=self.r, capture_output=True, text=True, env=env or self.env, check=False)
        if expect is not None: self.assertEqual(r.returncode, expect, r.stdout + r.stderr)
        return r.stdout + r.stderr

    def up_commit(self, path, text, msg):
        self.wu(path, text); git(self.up, 'add', '-A'); git(self.up, 'commit', '-q', '-m', msg)
        return git(self.up, 'rev-parse', 'HEAD')


class Sync(Fixture):
    def test_sync_builds_the_pin_plus_one_commit_per_patch_and_the_generated_files(self):
        out = self.tool('sync')
        self.assertIn('ready, 1 patches', out)
        self.assertEqual((self.eng / 'dm/a.c').read_text().splitlines()[1], 'line2 fork')
        log = git(self.eng, 'log', '--format=%s').splitlines()
        self.assertEqual(log, [E.GENERATED_SUBJECT, "Make line 2 the fork's", 'upstream 1'])
        self.assertEqual((self.eng / 'dm/fork_patches.txt').read_text(), 'line-2\n')
        self.assertEqual(git(self.eng, 'rev-parse', '--abbrev-ref', 'HEAD'), 'nx2apple')
        self.assertEqual(git(self.eng, 'status', '--porcelain'), '')

    def test_a_second_sync_is_a_no_op_and_quiet_prints_nothing(self):
        self.tool('sync')
        before = git(self.eng, 'rev-parse', 'HEAD')
        self.assertIn('up to date', self.tool('sync'))
        self.assertEqual(self.tool('--quiet', 'sync'), '')
        self.assertEqual(before, git(self.eng, 'rev-parse', 'HEAD'))
        self.tool('stale', expect=0)

    def test_the_outer_repository_does_not_see_engine(self):
        self.tool('sync')
        self.assertEqual(git(self.r, 'status', '--porcelain'), '')

    def test_a_changed_series_or_pin_makes_it_stale_and_sync_rebuilds(self):
        self.tool('sync')
        self.add_patch('0002-b.patch', 'dm/b.c', 'b1\nb2 fork\n', 'Change b2', header=HEADER.replace('#1', '#2'))
        self.assertIn('patches/ changed', self.tool('stale', expect=1))
        self.tool('sync')
        self.assertEqual((self.eng / 'dm/b.c').read_text(), 'b1\nb2 fork\n')
        up2 = self.up_commit('dm/c.c', 'c\n', 'upstream 2')
        (self.r / '.upstream-ref').write_text(up2 + '\n')
        self.assertIn('the pin moved', self.tool('stale', expect=1))
        self.tool('sync')
        self.assertTrue((self.eng / 'dm/c.c').is_file())
        self.assertEqual(git(self.eng, 'log', '--format=%s').splitlines()[-1], 'upstream 2')

    def test_ignored_build_products_survive_a_rebuild(self):
        self.tool('sync')
        self.wu('dm/host/gen/cache.o', 'x', self.eng)
        self.add_patch('0002-b.patch', 'dm/b.c', 'b1\nb2 fork\n', 'Change b2', header=HEADER.replace('#1', '#2'))
        self.tool('sync')
        self.assertTrue((self.eng / 'dm/host/gen/cache.o').is_file())

    def test_a_patch_that_does_not_apply_names_itself_and_its_reason(self):
        self.add_patch('0002-conflict.patch', 'dm/a.c', 'other\n', 'Conflicting', header=HEADER.replace('the fork needs line 2', 'a reason to show'))
        out = self.tool('sync', expect=2)
        self.assertIn('0002-conflict.patch does not apply', out); self.assertIn('a reason to show', out)
        self.assertFalse((self.eng / '.git' / 'rebase-apply').exists())

    def test_offline_names_the_fix_and_a_seed_needs_no_network(self):
        offline = dict(self.env, NX2APPLE_ENGINE_URL=str(self.tmp / 'nowhere'))
        out = self.tool('sync', expect=2, env=offline)
        self.assertIn('cannot fetch', out); self.assertIn('Offline?', out); self.assertIn('--seed', out)
        seed = self.tmp / 'seed.git'
        git(self.tmp, 'clone', '-q', '--bare', '--depth', '1', 'file://' + str(self.up), str(seed))
        out = self.tool('--seed', str(seed), 'sync', env=offline)
        self.assertIn('from the seed', out)
        self.tool('stale')


class Hook(Fixture):
    def test_the_session_hook_syncs_and_prints_one_line(self):
        out = self.tool('hook')
        self.assertEqual(len(out.strip().splitlines()), 1, out); self.assertIn('synced (engine/ is missing)', out)
        self.assertTrue((self.eng / 'dm/a.c').is_file())
        out = self.tool('hook')
        self.assertEqual(len(out.strip().splitlines()), 1, out); self.assertIn('up to date', out)

    def test_a_failed_sync_never_fails_the_hook(self):
        out = self.tool('hook', expect=0, env=dict(self.env, NX2APPLE_ENGINE_URL=str(self.tmp / 'nowhere')))
        self.assertEqual(len(out.strip().splitlines()), 1, out); self.assertIn('sync failed', out)


class LocalWork(Fixture):
    def commit_in_engine(self, path='dm/b.c', text='b1\nb2 engine\n', msg='Change b2 in engine'):
        self.wu(path, text, self.eng); git(self.eng, 'add', '-A'); git(self.eng, 'commit', '-q', '-m', msg)

    def test_sync_refuses_to_drop_a_commit_and_names_export(self):
        self.tool('sync')
        self.commit_in_engine()
        self.add_patch('0002-b.patch', 'dm/b.c', 'b1\nb2 fork\n', 'Unrelated', header=HEADER.replace('#1', '#2'))
        out = self.tool('sync', expect=2)
        self.assertIn('export', out); self.assertIn('1 commit(s)', out)
        self.assertEqual((self.eng / 'dm/b.c').read_text(), 'b1\nb2 engine\n')

    def test_sync_refuses_to_drop_an_uncommitted_change(self):
        self.tool('sync')
        self.wu('dm/b.c', 'dirty\n', self.eng)
        self.add_patch('0002-b.patch', 'dm/b.c', 'b1\nb2 fork\n', 'Unrelated', header=HEADER.replace('#1', '#2'))
        self.assertIn('changed or new file', self.tool('sync', expect=2))

    def test_force_keeps_the_work_on_a_backup_branch(self):
        self.tool('sync')
        self.commit_in_engine()
        out = self.tool('sync', '--force')
        self.assertIn('nx2apple-backup-', out)
        branch = next(b.strip() for b in git(self.eng, 'branch', '--format=%(refname:short)').splitlines() if b.startswith('nx2apple-backup-'))
        self.assertEqual(git(self.eng, 'log', '-1', '--format=%s', branch), 'Change b2 in engine')
        self.assertEqual((self.eng / 'dm/b.c').read_text(), 'b1\nb2\n')

    def test_export_writes_the_header_and_the_next_sync_rebuilds_with_it(self):
        self.tool('sync')
        self.commit_in_engine()
        out = self.tool('export', '--reason', 'r', '--issue', 'LNPANDY/NX2Apple#9')
        self.assertIn('wrote patches/0002-change-b2-in-engine.patch', out)
        text = (self.r / 'patches/0002-change-b2-in-engine.patch').read_text()
        for k in ('Upstream-Status: pending', 'Reason: r', 'Issue: LNPANDY/NX2Apple#9', 'Subject: [PATCH] Change b2 in engine'): self.assertIn(k, text)
        self.assertNotIn('fork_patches.txt', text)
        self.assertIn('0002-change-b2-in-engine.patch', (self.r / 'patches/series').read_text())
        self.tool('sync')
        self.assertEqual((self.eng / 'dm/b.c').read_text(), 'b1\nb2 engine\n')
        self.assertEqual((self.eng / 'dm/fork_patches.txt').read_text(), 'line-2\nchange-b2-in-engine\n')
        self.assertIn('ok.', self.tool('check'))

    def test_export_refuses_the_shader_chain(self):
        self.tool('sync')
        self.commit_in_engine('dm/gfx/nvn/dmsh_chain.h', 'x\n', 'Touch the chain')
        out = self.tool('export', expect=2)
        self.assertIn('shader chain', out)
        self.assertFalse((self.r / 'patches/0002-touch-the-chain.patch').exists())


class CheckAndBump(Fixture):
    def test_check_passes_and_rejects_an_incomplete_header(self):
        self.assertIn('apply cleanly', self.tool('check'))
        self.add_patch('0002-b.patch', 'dm/b.c', 'b1\nb2 fork\n', 'No header', header='Upstream-Status: pending\n')
        out = self.tool('check', expect=1)
        self.assertIn('0002-b.patch: Reason is missing', out)

    def test_check_tree_compares_a_committed_vendored_tree(self):
        self.tool('sync')
        for v in ('dm', 'AGENTS.md'):
            src = self.eng / v
            (shutil.copytree if src.is_dir() else shutil.copy)(src, self.r / v)
        self.assertIn('committed vendored tree matches', self.tool('check', '--tree'))
        (self.r / 'dm/b.c').write_text('edited\n')
        out = self.tool('check', '--tree', expect=1)
        self.assertIn('dm/b.c', out); self.assertIn('absorb', out)

    def test_bump_drops_a_patch_upstream_took_and_moves_the_pin(self):
        self.tool('sync')
        up2 = self.up_commit('dm/a.c', 'line1\nline2 fork\nline3\nline4\nline5\nline6\nline7\n', 'upstream takes line 2')
        self.assertIn('landed upstream, dropped (1): line-2', self.tool('bump', '--dry', '--to', up2))
        self.assertEqual((self.r / '.upstream-ref').read_text().strip(), self.up1)
        self.tool('bump', '--to', 'main')
        self.assertEqual((self.r / '.upstream-ref').read_text().strip(), up2)
        self.assertFalse((self.r / 'patches/0001-line-2.patch').exists())
        self.tool('sync')
        self.assertEqual((self.eng / 'dm/fork_patches.txt').read_text(), '')


class Search(unittest.TestCase):
    def test_the_repository_ignores_engine_for_git_but_not_for_ripgrep(self):
        self.assertIn('/engine/', (REPO / '.gitignore').read_text().splitlines())
        self.assertIn('!/engine/', (REPO / '.ignore').read_text().splitlines())

    @unittest.skipUnless(shutil.which('rg'), 'ripgrep is not installed')
    def test_a_search_from_the_root_finds_a_file_under_engine(self):
        tmp = Path(tempfile.mkdtemp(prefix='test-engine-rg-'))
        self.addCleanup(shutil.rmtree, tmp, True)
        git(tmp, 'init', '-q')
        shutil.copy(REPO / '.gitignore', tmp / '.gitignore'); shutil.copy(REPO / '.ignore', tmp / '.ignore')
        (tmp / 'engine/dm').mkdir(parents=True); (tmp / 'engine/dm/needle.c').write_text('engine_needle_7f3\n')
        self.assertEqual(git(tmp, 'status', '--porcelain', '--untracked-files=all').count('engine/'), 0)
        r = subprocess.run(['rg', '-l', 'engine_needle_7f3'], cwd=tmp, capture_output=True, text=True, check=False)
        self.assertEqual(r.stdout.strip(), 'engine/dm/needle.c', r.stderr)


class StampKey(Fixture):
    def test_the_qt_front_end_computes_the_same_key(self):
        sys.path.insert(0, str(REPO / 'frontend-qt'))
        qt_engine = importlib.import_module('nspb_qt.engine')
        self.tool('sync')
        self.assertEqual(qt_engine.stamp_key(self.r), E.stamp_key(self.r))
        self.assertEqual(qt_engine.engine_root(str(self.r)), str(self.eng))
        self.add_patch('0002-b.patch', 'dm/b.c', 'b1\nb2 fork\n', 'Change b2', header=HEADER.replace('#1', '#2'))
        self.assertTrue(qt_engine.is_stale(str(self.r)))


if __name__ == '__main__':
    unittest.main()
