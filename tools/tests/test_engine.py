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
SRC = REPO / 'engine'   # made by `python3 tools/engine.py sync`
sys.path.insert(0, str(TOOLS))
E = importlib.import_module('engine')


def setUpModule():
    if not (SRC / 'AGENTS.md').is_file():
        raise RuntimeError('engine/ is missing: run `python3 tools/engine.py sync` first')

BASE_ENV = dict(os.environ, GIT_AUTHOR_NAME='t', GIT_AUTHOR_EMAIL='t@example.invalid', GIT_COMMITTER_NAME='t', GIT_COMMITTER_EMAIL='t@example.invalid',
                GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_SYSTEM='/dev/null')

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

    def test_offline_names_the_fix_and_a_local_clone_needs_no_network(self):
        offline = dict(self.env, NX2APPLE_ENGINE_URL=str(self.tmp / 'nowhere'))
        out = self.tool('sync', expect=2, env=offline)
        self.assertIn('cannot fetch', out); self.assertIn('unreachable', out); self.assertIn('Check the connection', out)
        self.assertNotIn('--seed', out); self.assertFalse((self.eng / '.git' / 'nx2apple-stamp').exists())
        self.tool('stale', expect=1)
        local = self.tmp / 'local.git'
        git(self.tmp, 'clone', '-q', '--bare', '--depth', '1', 'file://' + str(self.up), str(local))
        out = self.tool('sync', env=dict(self.env, NX2APPLE_ENGINE_URL=str(local)))
        self.assertIn('engine: ready', out)
        self.tool('stale')

    def test_the_seed_option_is_gone(self):
        self.tool('--seed', str(self.tmp), 'sync', expect=2)


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

    def test_check_has_no_tree_comparison_any_more(self):
        self.assertIn('unrecognized arguments: --tree', self.tool('check', '--tree', expect=2))

    def test_check_rejects_a_patch_that_touches_the_shader_chain(self):
        self.add_patch('0002-chain.patch', 'dm/gfx/tools/dmsh_pull.py', 'x\n', 'Chain tool', header='Upstream-Status: pending\nReason: r\nIssue: LNPANDY/NX2Apple#4\n')
        out = self.tool('check', expect=1)
        self.assertIn('0002-chain.patch', out); self.assertIn('dm/gfx/tools/dmsh_pull.py', out); self.assertIn('shader chain', out)

    def test_check_rejects_a_patch_that_carries_a_generated_file(self):
        self.add_patch('0002-index.patch', 'docs/agents/game-patches.md', 'hand edit\n', 'Edit the index', header='Upstream-Status: fork-only\nReason: r\nIssue: LNPANDY/NX2Apple#1\n')
        out = self.tool('check', expect=1)
        self.assertIn('0002-index.patch', out); self.assertIn('generated', out)

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


class Relink(Fixture):
    """The pages that link into seedds/nxnative (the engine's docs and images) follow the pin."""
    OLD = 'b' * 40

    def pages(self, sha):
        (self.r / 'README.md').write_text(f'[a](https://github.com/seedds/nxnative/blob/{sha}/docs/a.md) <img src="https://raw.githubusercontent.com/seedds/nxnative/{sha}/docs/images/x.jpg"> https://github.com/seedds/nxnative/issues\n')
        (self.r / 'CHANGELOG.md').write_text(f'history https://github.com/seedds/nxnative/blob/{sha}/docs/a.md\n')

    def test_check_names_a_page_that_links_to_another_commit_and_relink_fixes_it(self):
        self.pages(self.OLD)
        out = self.tool('check', expect=1)
        self.assertIn('README.md', out); self.assertIn('relink', out); self.assertNotIn('CHANGELOG.md', out)
        self.assertIn('README.md', self.tool('relink'))
        text = (self.r / 'README.md').read_text()
        self.assertEqual(text.count(self.up1), 2); self.assertIn('seedds/nxnative/issues', text)
        self.assertIn(self.OLD, (self.r / 'CHANGELOG.md').read_text())   # the history is left as it was
        self.assertIn('apply cleanly', self.tool('check'))
        self.assertIn('already current', self.tool('relink'))

    def test_a_bump_moves_the_links_with_the_pin(self):
        self.pages(self.up1)
        up2 = self.up_commit('dm/b.c', 'b1\nb2\nb3\n', 'upstream moves')
        self.assertIn('README.md', self.tool('bump', '--to', up2))
        self.assertIn(f'blob/{up2}/docs/a.md', (self.r / 'README.md').read_text())


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
        # the root named explicitly and stdin closed: with a pipe on stdin and no path, rg searches stdin (CI runners have one)
        r = subprocess.run(['rg', '-l', 'engine_needle_7f3', '.'], cwd=tmp, capture_output=True, text=True, check=False, stdin=subprocess.DEVNULL)
        self.assertEqual(r.stdout.strip(), './engine/dm/needle.c', r.stderr)


class Tree(Fixture):
    """The engine tree for players: engine/ at its last sync, no git, with the identity and a zip that is the same every time."""
    def make(self, name='out', zipname=None):
        out = self.tmp / name
        args = ['tree', '--out', str(out)] + (['--zip', str(self.tmp / zipname)] if zipname else [])
        return out, self.tool(*args)

    def test_the_tree_is_the_patched_engine_without_git_and_names_its_identity(self):
        self.tool('sync')
        out, said = self.make()
        self.assertEqual((out / 'dm/a.c').read_text(), 'line1\nline2 fork\nline3\nline4\nline5\nline6\nline7\n')   # the patch is in
        self.assertEqual((out / '.upstream-ref').read_text(), self.up1 + '\n')
        eid = (out / '.engine-id').read_text().strip()
        self.assertEqual(eid, self.up1 + '-' + E.stamp_key(self.r)[:12])
        self.assertRegex(eid, r'^[0-9a-f]{40}-[0-9a-f]{12}$')
        self.assertEqual(eid, E.engine_id(self.r)); self.assertIn(eid, said)
        self.assertIn('line-2', (out / 'dm/fork_patches.txt').read_text())
        self.assertTrue((out / 'AGENTS.md').is_file())
        self.assertFalse((out / '.git').exists()); self.assertFalse((out / '.gitignore').exists())   # no history, no repository files
        self.assertFalse((out / 'tools').exists()); self.assertFalse((out / 'patches').exists())    # nothing of the fork

    def test_a_series_change_without_a_pin_move_changes_the_identity(self):
        self.tool('sync'); out, _ = self.make('one')
        self.add_patch('0002-b.patch', 'dm/b.c', 'b1\nb2 fork\n', 'Change b2', header=HEADER.replace('#1', '#2'))
        self.tool('sync'); out2, _ = self.make('two')
        a, b = (out / '.engine-id').read_text().strip(), (out2 / '.engine-id').read_text().strip()
        self.assertEqual(a[:40], b[:40]); self.assertNotEqual(a, b)

    def test_the_zip_is_deterministic_and_unpacks_to_the_tree(self):
        import hashlib, time, zipfile
        self.tool('sync')
        out, _ = self.make('one', 'one.zip')
        time.sleep(1.1)                                    # other modification times, same bytes
        for f in out.rglob('*'): os.utime(f, (time.time(), time.time()))
        out2, _ = self.make('two', 'two.zip')
        h = lambda n: hashlib.sha256((self.tmp / n).read_bytes()).hexdigest()
        self.assertEqual(h('one.zip'), h('two.zip'))
        with zipfile.ZipFile(self.tmp / 'one.zip') as z:
            names = z.namelist()
            self.assertEqual(names, sorted(names)); self.assertIn('.engine-id', names); self.assertIn('dm/a.c', names)
            self.assertEqual({i.date_time for i in z.infolist()}, {E.ZIP_TIME})
            self.assertEqual(z.read('.engine-id').decode(), (out / '.engine-id').read_text())

    def test_executable_bits_and_symlinks_survive(self):
        import stat, zipfile
        self.wu('dm/run.sh', '#!/bin/sh\n'); os.chmod(self.up / 'dm/run.sh', 0o755)
        os.symlink('a.c', self.up / 'dm/link.c')
        up2 = self.up_commit('dm/c.c', 'c\n', 'upstream 2')
        (self.r / '.upstream-ref').write_text(up2 + '\n')
        self.tool('sync'); out, _ = self.make('out', 'e.zip')
        self.assertTrue(os.access(out / 'dm/run.sh', os.X_OK)); self.assertFalse(os.access(out / 'dm/a.c', os.X_OK))
        self.assertTrue((out / 'dm/link.c').is_symlink())
        with zipfile.ZipFile(self.tmp / 'e.zip') as z:
            self.assertEqual(stat.S_IMODE(z.getinfo('dm/run.sh').external_attr >> 16), 0o755)
            self.assertTrue(stat.S_ISLNK(z.getinfo('dm/link.c').external_attr >> 16))

    def test_a_stale_or_dirty_engine_makes_no_tree(self):
        self.tool('tree', '--out', str(self.tmp / 'o'), expect=2)           # no engine/ at all
        self.tool('sync')
        self.add_patch('0002-b.patch', 'dm/b.c', 'b1\nb2 fork\n', 'Change b2', header=HEADER.replace('#1', '#2'))
        self.assertIn('not a current sync', self.tool('tree', '--out', str(self.tmp / 'o'), expect=2))
        self.tool('sync')
        (self.eng / 'dm/a.c').write_text('local edit\n')
        self.assertIn('changes the release must not carry', self.tool('tree', '--out', str(self.tmp / 'o'), expect=2))
        self.assertFalse((self.tmp / 'o/.engine-id').exists())

    def test_it_will_not_empty_a_folder_that_is_not_an_earlier_tree(self):
        self.tool('sync')
        keep = self.tmp / 'precious'; keep.mkdir(); (keep / 'x').write_text('mine')
        self.assertIn('not an engine tree', self.tool('tree', '--out', str(keep), expect=2))
        self.assertEqual((keep / 'x').read_text(), 'mine')
        self.make('again'); self.make('again')                              # an earlier tree is replaced


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
