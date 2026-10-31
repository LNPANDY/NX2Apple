"""The git hooks (tools/githooks.py), their installation (engine.install_hooks) and the Claude Code guard (tools/claude_guard.py).
The hook tests use a throwaway repository, never this one."""
import contextlib
import importlib
import io
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

TOOLS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOLS))
H = importlib.import_module('githooks')
G = importlib.import_module('claude_guard')
E = importlib.import_module('engine')
P = H.P

# git exports GIT_DIR and others to a hook. A test must never reach the repository that runs it, whatever it inherited.
for _k in P.REPO_ENV:
    os.environ.pop(_k, None)

ENV = dict({k: v for k, v in P.clean_env().items() if not k.startswith('GIT_CONFIG_')}, GIT_AUTHOR_NAME='t', GIT_AUTHOR_EMAIL='t@example.invalid', GIT_COMMITTER_NAME='t', GIT_COMMITTER_EMAIL='t@example.invalid',
           GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_SYSTEM='/dev/null')


def git(cwd, *a):
    r = subprocess.run(['git', '-c', 'commit.gpgsign=false', *a], cwd=cwd, capture_output=True, text=True, env=ENV)
    assert r.returncode == 0, f'git {a}: {r.stderr}'
    return r.stdout.strip()


def names(paths):
    return [c.name for c in H.checks_for(paths)]


class ChecksFor(unittest.TestCase):
    def test_docs_only_runs_nothing(self):
        self.assertEqual(names(['README.md', 'CONTRIBUTING.md', 'AGENTS.md', 'GAMES.md']), [])

    def test_patches_and_pin_run_the_patch_queue(self):
        self.assertEqual(names(['patches/0036-x.patch']), ['patch queue'])
        self.assertEqual(names(['.upstream-ref']), ['patch queue'])
        self.assertEqual(H.CHECKS[0].command, 'python3 tools/engine.py check')

    def test_each_area_runs_its_own_check(self):
        self.assertEqual(names(['tools/engine.py']), ['tools'])
        self.assertEqual(names(['.github/scripts/triage_apply.py']), ['triage scripts'])
        self.assertEqual(names(['frontend-qt/nspb_qt/app.py']), ['Qt front end'])
        self.assertEqual(names(['frontend/Package.swift']), ['Mac launcher (slow)'])

    def test_workflow_files_and_frontend_ios_run_nothing(self):
        self.assertEqual(names(['.github/workflows/tests.yml', 'frontend-ios/Package.swift']), [])

    def test_qt_does_not_match_the_mac_launcher(self):
        self.assertNotIn('Mac launcher (slow)', names(['frontend-qt/x.py']))

    def test_cheapest_first_and_the_slow_one_last(self):
        got = names(['frontend/a.swift', 'tools/a.py', 'patches/series', 'frontend-qt/a.py'])
        self.assertEqual(got, ['patch queue', 'Qt front end', 'tools', 'Mac launcher (slow)'])

    def test_the_commands_are_the_ones_in_ci(self):
        cmds = {c.name: c.command for c in H.CHECKS}
        self.assertEqual(cmds['tools'], 'python3 -m unittest discover tools/tests')
        self.assertIn('python3 -m unittest discover -s frontend-qt/tests', cmds['Qt front end'])
        self.assertIn('python3 frontend-qt/gen_localization.py', cmds['Qt front end'])
        self.assertIn('git diff --exit-code HEAD -- frontend-qt/nspb_qt/localization.py', cmds['Qt front end'])
        self.assertEqual(cmds['triage scripts'], 'python3 -m unittest discover -s .github/scripts/tests')
        self.assertEqual(cmds['Mac launcher (slow)'], 'swift build && swift test')


def snapshot(repo):
    """Everything a stray git command could change in a repository: config, HEAD, refs, index, stash."""
    g = Path(repo) / '.git'
    return {str(f.relative_to(g)): f.read_bytes() for f in sorted(g.rglob('*')) if f.is_file() and 'hooks' not in f.relative_to(g).parts}


class HookEnvironment(unittest.TestCase):
    """In a worktree git runs a hook with GIT_DIR set to the real repository. The checks make repositories of their own
    and must never reach that one (2026-10-31: tests wrote core.bare and refs into the shared repository)."""
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='test-hookenv-')
        self.addCleanup(self.tmp.cleanup)
        self.outer = Path(self.tmp.name) / 'outer'
        self.outer.mkdir()
        git(self.outer, 'init', '-q', '-b', 'main')
        git(self.outer, 'commit', '-q', '--allow-empty', '-m', 'outer')
        self.before = snapshot(self.outer)
        self.hook_env = {'GIT_DIR': str(self.outer / '.git'), 'GIT_WORK_TREE': str(self.outer), 'GIT_INDEX_FILE': str(self.outer / '.git/index'), 'GIT_PREFIX': ''}
        patcher = mock.patch.dict(os.environ, self.hook_env)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.work = Path(self.tmp.name) / 'work'

    def test_a_check_started_with_git_dir_set_works_in_its_own_repository(self):
        script = (f'git init -q -b main "{self.work}" && git -C "{self.work}" config core.bare false'
                  f' && git -C "{self.work}" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m probe'
                  f' && git -C "{self.work}" branch other')
        self.assertEqual(H.sh(script, self.tmp.name), 0)
        self.assertEqual(snapshot(self.outer), self.before)
        self.assertEqual(git(self.work, 'log', '--format=%s'), 'probe')

    def test_the_git_helper_of_the_tools_ignores_git_dir(self):
        P.git('init', '-q', '-b', 'main', str(self.work), cwd=self.tmp.name)
        P.git('-c', 'user.name=t', '-c', 'user.email=t@example.invalid', 'commit', '-q', '--allow-empty', '-m', 'probe', cwd=self.work)
        P.git('config', 'core.bare', 'false', cwd=self.work)
        P.git('update-ref', 'refs/remotes/origin/main', 'HEAD', cwd=self.work)
        self.assertEqual(snapshot(self.outer), self.before)
        self.assertEqual(git(self.work, 'rev-parse', 'origin/main'), git(self.work, 'rev-parse', 'HEAD'))

    def test_the_hook_script_with_git_dir_set_leaves_the_outer_repository_alone(self):
        head = subprocess.run(['git', 'rev-parse', 'HEAD'], cwd=TOOLS, capture_output=True, text=True, env=P.clean_env()).stdout.strip()
        lines = f'refs/heads/x {head} refs/heads/x {head}\n(delete) {H.ZERO} refs/heads/y {"2" * 40}\n'   # nothing changes, so no check runs
        r = subprocess.run([sys.executable, str(TOOLS / 'githooks.py'), 'pre-push'], input=lines, capture_output=True, text=True, env=dict(os.environ))
        self.assertEqual(snapshot(self.outer), self.before, r.stdout + r.stderr)
        self.assertEqual((r.returncode, 'nothing to check' in r.stdout), (0, True), r.stdout + r.stderr)

    def test_all_variables_git_exports_to_a_hook_are_removed(self):
        for k in ('GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE', 'GIT_OBJECT_DIRECTORY', 'GIT_ALTERNATE_OBJECT_DIRECTORIES', 'GIT_COMMON_DIR', 'GIT_PREFIX'):
            with mock.patch.dict(os.environ, {k: 'x'}):
                self.assertNotIn(k, P.clean_env())


class PushedPaths(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='test-githooks-')
        self.addCleanup(self.tmp.cleanup)
        self.repo = Path(self.tmp.name)
        git(self.repo, 'init', '-q', '-b', 'main')
        self.commit('README.md', 'a')
        git(self.repo, 'update-ref', 'refs/remotes/origin/main', 'HEAD')
        self.main = git(self.repo, 'rev-parse', 'HEAD')
        patcher = mock.patch.object(H, 'ROOT', self.repo)
        patcher.start()
        self.addCleanup(patcher.stop)

    def commit(self, path, text):
        f = self.repo / path
        f.parent.mkdir(parents=True, exist_ok=True)
        f.write_text(text)
        git(self.repo, 'add', '-A')
        git(self.repo, 'commit', '-q', '-m', path)
        return git(self.repo, 'rev-parse', 'HEAD')

    def test_new_branch_is_compared_with_origin_main(self):
        git(self.repo, 'checkout', '-q', '-b', 'feature')
        self.commit('patches/0001-x.patch', 'p')
        head = self.commit('docs.md', 'd')
        paths = H.pushed_paths([f'refs/heads/feature {head} refs/heads/feature {H.ZERO}'])
        self.assertEqual(paths, {'patches/0001-x.patch', 'docs.md'})

    def test_known_remote_sha_is_the_base(self):
        git(self.repo, 'checkout', '-q', '-b', 'feature')
        old = self.commit('patches/0001-x.patch', 'p')
        head = self.commit('docs.md', 'd')
        self.assertEqual(H.pushed_paths([f'refs/heads/feature {head} refs/heads/feature {old}']), {'docs.md'})

    def test_unknown_remote_sha_falls_back_to_origin_main(self):
        git(self.repo, 'checkout', '-q', '-b', 'feature')
        head = self.commit('tools/a.py', 'x')
        self.assertEqual(H.pushed_paths([f'refs/heads/feature {head} refs/heads/feature {"1" * 40}']), {'tools/a.py'})

    def test_a_delete_pushes_no_code(self):
        self.assertEqual(H.pushed_paths([f'(delete) {H.ZERO} refs/heads/old {self.main}']), set())

    def test_no_base_means_everything(self):
        git(self.repo, 'update-ref', '-d', 'refs/remotes/origin/main')
        git(self.repo, 'checkout', '-q', '-b', 'feature')
        head = self.commit('docs.md', 'd')
        self.assertIsNone(H.pushed_paths([f'refs/heads/feature {head} refs/heads/feature {H.ZERO}']))

    def run_hook(self, paths_changed):
        git(self.repo, 'checkout', '-q', '-b', 'feature')
        head = self.commit(paths_changed, 'x')
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = H.pre_push([f'refs/heads/feature {head} refs/heads/feature {H.ZERO}'])
        return code, out.getvalue()

    def test_docs_only_push_runs_nothing(self):
        with mock.patch.object(H, 'sh', side_effect=AssertionError('nothing may run')):
            code, out = self.run_hook('README.md')
        self.assertEqual(code, 0)
        self.assertIn('nothing to check', out)

    def test_a_failing_check_stops_the_push_with_the_command(self):
        err = io.StringIO()
        with mock.patch.object(H, 'sh', return_value=1) as run, contextlib.redirect_stderr(err):
            code, _ = self.run_hook('patches/0036-x.patch')
        self.assertEqual(code, 1)
        self.assertEqual(run.call_args.args[0], 'python3 tools/engine.py check')
        self.assertIn('Reproduce: python3 tools/engine.py check', err.getvalue())

    def test_a_patch_push_does_not_sync_the_engine_or_run_slow_checks(self):
        with mock.patch.object(H, 'sh', return_value=0) as run:
            code, _ = self.run_hook('.upstream-ref')
        self.assertEqual(code, 0)
        self.assertEqual([c.args[0] for c in run.call_args_list], ['python3 tools/engine.py check'])

    def test_pre_commit_checks_only_staged_patches(self):
        self.repo.joinpath('docs.md').write_text('d')
        git(self.repo, 'add', 'docs.md')
        with mock.patch.object(H, 'sh', side_effect=AssertionError('nothing may run')), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(H.pre_commit(), 0)
        self.repo.joinpath('tools').mkdir()
        self.repo.joinpath('tools/a.py').write_text('x')
        self.repo.joinpath('patches').mkdir()
        self.repo.joinpath('patches/series').write_text('x')
        git(self.repo, 'add', '-A')
        with mock.patch.object(H, 'sh', return_value=0) as run, contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(H.pre_commit(), 0)
        self.assertEqual([c.args[0] for c in run.call_args_list], ['python3 tools/engine.py check'])


class InstallHooks(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='test-hooksinstall-')
        self.addCleanup(self.tmp.cleanup)
        self.repo = Path(self.tmp.name) / 'repo'
        self.repo.mkdir()
        git(self.repo, 'init', '-q', '-b', 'main')
        (self.repo / '.githooks').mkdir()
        (self.repo / '.githooks/pre-push').write_text('#!/bin/sh\n')
        git(self.repo, 'add', '-A')
        git(self.repo, 'commit', '-q', '-m', 'init')

    def install(self, root=None):
        out = io.StringIO()
        with mock.patch.dict(os.environ, ENV, clear=True), contextlib.redirect_stdout(out):
            E.install_hooks(root or self.repo)
        return out.getvalue()

    def path(self, root=None):
        return subprocess.run(['git', 'config', '--get', 'core.hooksPath'], cwd=root or self.repo, capture_output=True, text=True, env=ENV).stdout.strip()

    def test_sets_it_when_unset_and_stays_quiet_after(self):
        self.assertIn('set core.hooksPath', self.install())
        self.assertEqual(self.path(), '.githooks')
        self.assertEqual(self.install(), '')

    def test_keeps_another_path_and_warns(self):
        git(self.repo, 'config', 'core.hooksPath', '/somewhere/else')
        out = self.install()
        self.assertEqual(self.path(), '/somewhere/else')
        self.assertIn('WARNING', out)
        self.assertIn('git config core.hooksPath .githooks', out)

    def test_a_worktree_inherits_it(self):
        wt = Path(self.tmp.name) / 'wt'
        git(self.repo, 'worktree', 'add', '-q', '-b', 'other', str(wt))
        self.assertEqual(self.path(wt), '')
        self.install()
        self.assertEqual(self.path(wt), '.githooks')
        self.assertEqual(self.install(wt), '')

    def test_a_checkout_without_hooks_is_left_alone(self):
        bare = Path(self.tmp.name) / 'plain'
        bare.mkdir()
        git(bare, 'init', '-q')
        self.assertEqual(self.install(bare), '')
        self.assertEqual(self.path(bare), '')


def blocked(command, cwd='.'):
    return G.verdict(command, cwd) is not None


class ClaudeGuard(unittest.TestCase):
    def test_push_to_main_or_master_is_blocked(self):
        for c in ('git push origin main', 'git push origin master', 'git push -u origin main', 'git push origin HEAD:main',
                  'git push origin feature:main', 'git push origin HEAD:refs/heads/main', 'git push origin +main',
                  'git push --force origin main', 'git push -f origin main', 'git push --force-with-lease origin main',
                  'git -C /some/repo push origin main', 'cd repo && git push origin main', 'git fetch; git push origin main',
                  'sudo git push origin main', 'GIT_TRACE=1 git push origin main', 'bash -c "git push origin main"',
                  'git push --delete origin main', 'git push --all origin', 'git push --mirror'):
            self.assertTrue(blocked(c), c)

    def test_push_of_a_branch_is_allowed(self):
        for c in ('git push origin v0lumehi/pre-push-checks', 'git push -u origin my-branch', 'git push origin HEAD:my-branch',
                  'git push --force origin my-branch', 'git push origin main-fix', 'git push origin v1.0',
                  'git push https://x-access-token:t@github.com/LNPANDY/NX2Apple.git v0lumehi/foo', 'git pull origin main',
                  'git fetch origin main', 'git checkout main', 'git merge main', 'git log origin/main..HEAD'):
            self.assertFalse(blocked(c), c)

    def test_text_that_only_mentions_a_push_is_allowed(self):
        self.assertFalse(blocked('echo "git push origin main"'))
        self.assertFalse(blocked('git commit -m "never git push origin main"'))
        self.assertFalse(blocked('gh pr create --title "no git push to main"'))

    def test_a_bare_push_depends_on_the_current_branch(self):
        with tempfile.TemporaryDirectory(prefix='test-guard-') as d:
            git(d, 'init', '-q', '-b', 'main')
            git(d, 'commit', '-q', '--allow-empty', '-m', 'x')
            self.assertTrue(blocked('git push', d))
            self.assertTrue(blocked('git push origin', d))
            self.assertTrue(blocked('git push origin HEAD', d))
            git(d, 'checkout', '-q', '-b', 'feature')
            self.assertFalse(blocked('git push', d))
            self.assertFalse(blocked('git push origin HEAD', d))

    def test_no_verify_is_blocked_on_commit_and_push(self):
        for c in ('git commit --no-verify -m x', 'git commit -n -m x', 'git commit -nm x', 'git push --no-verify origin feature'):
            self.assertTrue(blocked(c), c)
        self.assertFalse(blocked('git commit -am "fix"'))
        self.assertFalse(blocked('git commit --amend'))
        self.assertFalse(blocked('git push -n origin feature'))

    def test_unbalanced_quotes_still_catch_a_push_to_main(self):
        self.assertTrue(blocked('git push origin main "'))

    def run_guard(self, payload):
        return subprocess.run([sys.executable, str(TOOLS / 'claude_guard.py')], input=payload, capture_output=True, text=True)

    def test_hook_protocol(self):
        import json
        r = self.run_guard(json.dumps({'tool_name': 'Bash', 'tool_input': {'command': 'git push origin main'}, 'cwd': str(TOOLS)}))
        self.assertEqual(r.returncode, 2)
        self.assertIn('PR', r.stderr)
        r = self.run_guard(json.dumps({'tool_name': 'Bash', 'tool_input': {'command': 'git push origin feature'}, 'cwd': str(TOOLS)}))
        self.assertEqual((r.returncode, r.stderr), (0, ''))
        self.assertEqual(self.run_guard('not json').returncode, 0)

    def test_settings_json_wires_both_hooks(self):
        import json
        s = json.loads((TOOLS.parent / '.claude/settings.json').read_text())['hooks']
        self.assertIn('tools/engine.py" hook', s['SessionStart'][0]['hooks'][0]['command'])
        pre = s['PreToolUse'][0]
        self.assertEqual(pre['matcher'], 'Bash')
        self.assertIn('tools/claude_guard.py', pre['hooks'][0]['command'])


if __name__ == '__main__':
    unittest.main()
