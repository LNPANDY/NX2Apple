"""tools/game_archive.py on fixture repositories: an archive holds the game's folder and the shared files its commits change, leaves
docs, tests and generated files out, and is refused on another game's folder, the wrong branch, uncommitted changes or a repository
that is not nxnative. No network: the fixture's remote is only a URL."""
import contextlib
import importlib
import io
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / 'tools'))
G = importlib.import_module('game_archive')

ENV = G.P.clean_env(GIT_AUTHOR_NAME='t', GIT_AUTHOR_EMAIL='t@example.invalid', GIT_COMMITTER_NAME='t', GIT_COMMITTER_EMAIL='t@example.invalid',
                    GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_SYSTEM='/dev/null')
TID = '0100ABCD12340000'
OTHER = '0100000000010000'


def git(cwd, *a):
    r = subprocess.run(['git', '-c', 'commit.gpgsign=false', *a], cwd=cwd, capture_output=True, text=True, env=ENV)
    if r.returncode: raise AssertionError(f'git {a}: {r.stderr}')
    return r.stdout.strip()


def write(root, rel, text):
    p = root / rel
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(text)


class Fixture(unittest.TestCase):
    """eng/: an nxnative-shaped repository with upstream's URL as a remote, `nx2apple` at the base, and the branch `game` checked out."""
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix='test-game-archive-')).resolve()
        self.eng = self.tmp / 'eng'
        self.eng.mkdir()
        git(self.eng, 'init', '-q', '-b', 'nx2apple')
        write(self.eng, 'AGENTS.md', 'guide\n')
        write(self.eng, 'scripts/build_ipa_from_nsp.py', 'print(1)\n')
        write(self.eng, 'dm/tools/sdk_patches.py', 'RULES = [1]\n')
        write(self.eng, f'dm/games/{OTHER}/game.tsv', 'title_id\t0100000000010000\n')
        write(self.eng, 'dm/games/README.md', '# games\n')
        git(self.eng, 'add', '-A'); git(self.eng, 'commit', '-q', '-m', 'base')
        self.base = git(self.eng, 'rev-parse', 'HEAD')
        git(self.eng, 'remote', 'add', 'upstream', 'git@github.com:seedds/nxnative.git')
        git(self.eng, 'switch', '-q', '-c', 'game')

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def add_game(self):
        write(self.eng, f'dm/games/{TID}/game.tsv', f'title_id\t{TID}\nname\tA Test Game\nbuild\tv65536\t1.0.1\tmain=00\nbuild\tv131072\t1.0.2\tmain=11\n')
        write(self.eng, f'dm/games/{TID}/README.md', '# A Test Game\n')
        write(self.eng, 'dm/tools/sdk_patches.py', 'RULES = [1, 2]\n')
        write(self.eng, 'dm/tools/tests/test_new.py', 'pass\n')
        write(self.eng, 'docs/reference/memory.md', 'notes\n')
        write(self.eng, 'dm/games/README.md', '# games\n- A Test Game\n')
        write(self.eng, 'dm/fork_patches.txt', 'x\n')
        git(self.eng, 'add', '-A'); git(self.eng, 'commit', '-q', '-m', 'A Test Game plays')

    def run_tool(self, *args):
        o, e = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(o), contextlib.redirect_stderr(e):
            code = G.main([*args])
        return code, o.getvalue(), e.getvalue()

    def make(self, *extra):
        out = self.tmp / 'a.nxgame'
        code, o, e = self.run_tool(TID, '--engine', str(self.eng), '--out', str(out), *extra)
        return code, o + e, out


class Make(Fixture):
    def test_archive_holds_the_game_and_the_shared_change(self):
        self.add_game()
        code, text, out = self.make('--notes', 'tested to the title screen')
        self.assertEqual(code, 0, text)
        with zipfile.ZipFile(out) as z:
            names = set(z.namelist())
            m = json.loads(z.read('manifest.json'))
            patch = z.read('engine.patch').decode()
        self.assertEqual(names, {'manifest.json', 'engine.patch', f'game/dm/games/{TID}/game.tsv', f'game/dm/games/{TID}/README.md'})
        self.assertIn('+RULES = [1, 2]', patch)
        self.assertNotIn('memory.md', patch); self.assertNotIn('test_new', patch); self.assertNotIn('fork_patches', patch)
        self.assertEqual(m['title_id'], TID)
        self.assertEqual(m['name'], 'A Test Game')
        self.assertEqual(m['updates'], [65536, 131072])
        self.assertEqual(m['patched'], ['dm/tools/sdk_patches.py'])
        self.assertEqual(m['base']['commit'], self.base)
        self.assertEqual(m['base']['remote'], 'github.com/seedds/nxnative')
        self.assertEqual(m['notes'], 'tested to the title screen')
        self.assertEqual(len(m['commits']), 1)
        for word in ('docs/reference/memory.md (docs)', 'dm/tools/tests/test_new.py (tests)', 'dm/fork_patches.txt (generated)'):
            self.assertIn(word, text)
        self.assertEqual(self.run_tool('--show', str(out))[0], 0)

    def test_same_commits_same_bytes(self):
        self.add_game()
        _, _, out = self.make()
        first = out.read_bytes()
        out.unlink()
        self.make()
        self.assertEqual(first, out.read_bytes())

    def test_game_folder_only_has_no_patch(self):
        write(self.eng, f'dm/games/{TID}/game.tsv', f'title_id\t{TID}\n')
        git(self.eng, 'add', '-A'); git(self.eng, 'commit', '-q', '-m', 'only the folder')
        code, text, out = self.make()
        self.assertEqual(code, 0, text)
        with zipfile.ZipFile(out) as z: self.assertNotIn('engine.patch', z.namelist())

    def test_the_patch_applies_to_the_base_tree(self):
        self.add_game()
        _, _, out = self.make()
        tree = self.tmp / 'tree'
        tree.mkdir()
        subprocess.run(f'git archive {self.base} | tar -x -C "{tree}"', shell=True, cwd=self.eng, check=True, env=ENV)
        with zipfile.ZipFile(out) as z: (self.tmp / 'p').write_bytes(z.read('engine.patch'))
        r = subprocess.run(['git', 'apply', str(self.tmp / 'p')], cwd=tree, capture_output=True, text=True, env={**ENV, 'GIT_CEILING_DIRECTORIES': str(self.tmp)})
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual((tree / 'dm/tools/sdk_patches.py').read_text(), 'RULES = [1, 2]\n')


class Refuse(Fixture):
    def assertRefused(self, code, text, words):
        self.assertEqual(code, 2, text)
        self.assertIn(words, text)

    def test_branch_nx2apple(self):
        git(self.eng, 'switch', '-q', 'nx2apple')
        self.add_game()
        self.assertRefused(*self.make()[:2], 'the current branch is nx2apple')

    def test_branch_main(self):
        git(self.eng, 'switch', '-q', '-c', 'main')
        self.add_game()
        self.assertRefused(*self.make()[:2], 'the current branch is main')

    def test_detached(self):
        self.add_game()
        git(self.eng, 'switch', '-q', '--detach')
        self.assertRefused(*self.make()[:2], 'HEAD is detached')

    def test_dirty_unless_allowed(self):
        self.add_game()
        write(self.eng, 'dm/tools/wip.py', 'x\n')
        self.assertRefused(*self.make()[:2], '--allow-dirty')
        code, text, out = self.make('--allow-dirty')
        self.assertEqual(code, 0, text)
        self.assertIn('dm/tools/wip.py', text)
        with zipfile.ZipFile(out) as z: self.assertNotIn('wip', ' '.join(z.namelist()) + z.read('engine.patch').decode())

    def test_no_shared_remote(self):
        git(self.eng, 'remote', 'set-url', 'upstream', 'https://example.invalid/someone/else.git')
        self.add_game()
        self.assertRefused(*self.make()[:2], 'not an nxnative repository')

    def test_not_nxnative_layout(self):
        self.add_game()
        git(self.eng, 'rm', '-q', 'AGENTS.md'); git(self.eng, 'commit', '-q', '-m', 'x')
        self.assertRefused(*self.make()[:2], 'has no AGENTS.md')

    def test_another_games_folder(self):
        self.add_game()
        write(self.eng, f'dm/games/{OTHER}/game.tsv', 'changed\n')
        git(self.eng, 'commit', '-q', '-am', 'touch another game')
        self.assertRefused(*self.make()[:2], 'another game\'s folder')

    def test_no_commits(self):
        self.assertRefused(*self.make()[:2], 'is not in HEAD')
        write(self.eng, f'dm/games/{TID}/game.tsv', 'x\n')
        git(self.eng, 'add', '-A'); git(self.eng, 'commit', '-q', '-m', 'game')
        git(self.eng, 'branch', '-f', 'nx2apple', 'HEAD')   # the game's commit is on nx2apple: not the game's
        self.assertRefused(*self.make()[:2], 'no commits of the game')

    def test_commits_on_a_remote_branch_are_not_the_games(self):
        self.add_game()
        git(self.eng, 'update-ref', 'refs/remotes/upstream/main', 'HEAD')
        self.assertRefused(*self.make()[:2], 'no commits of the game')

    def test_bad_title_id(self):
        code, o, e = self.run_tool('0100XYZ', '--engine', str(self.eng))
        self.assertRefused(code, o + e, 'is not a title ID')


class Read(Fixture):
    def test_tampered_file_is_a_problem(self):
        self.add_game()
        _, _, out = self.make()
        bad = self.tmp / 'bad.nxgame'
        with zipfile.ZipFile(out) as src, zipfile.ZipFile(bad, 'w') as dst:
            for n in src.namelist():
                data = src.read(n)
                dst.writestr(n, data + b'\n' if n.endswith('game.tsv') else data)
            dst.writestr(f'game/dm/games/{TID}/extra.tsv', 'x')
        code, o, _ = self.run_tool('--show', str(bad))
        self.assertEqual(code, 1)
        self.assertIn('game.tsv: SHA-256 does not match', o)
        self.assertIn('extra.tsv: not listed', o)


class Urls(unittest.TestCase):
    def test_forms_of_one_repository(self):
        want = 'github.com/seedds/nxnative'
        for u in ('https://github.com/seedds/nxnative.git', 'https://github.com/seedds/nxnative', 'git@github.com:seedds/nxnative.git',
                  'ssh://git@github.com/seedds/nxnative.git', 'https://GitHub.com/seedds/nxnative/'):
            self.assertEqual(G.normalize_url(u), want, u)
        self.assertNotEqual(G.normalize_url('https://github.com/other/nxnative'), want)


class Classify(unittest.TestCase):
    def test_kinds(self):
        self.assertEqual(G.classify(f'dm/games/{TID}/game.tsv', TID), 'game')
        self.assertEqual(G.classify('dm/gfx/tools/shader_split.py', TID), 'patch')
        self.assertEqual(G.classify('dm/fork_patches.txt', TID), 'generated')
        self.assertEqual(G.classify('docs/agents/symptoms.md', TID), 'generated')
        self.assertEqual(G.classify('docs/reference/memory.md', TID), 'docs')
        self.assertEqual(G.classify('dm/games/README.md', TID), 'docs')
        self.assertEqual(G.classify('ref/x.txt', TID), 'docs')
        self.assertEqual(G.classify('dm/tools/tests/fixtures/a.bin', TID), 'tests')
        self.assertEqual(G.classify('scripts/test_build.py', TID), 'tests')
        self.assertEqual(G.classify('dm/games/game.py', TID), 'patch')
        with self.assertRaises(G.Fail): G.classify(f'dm/games/{OTHER}/game.tsv', TID)


if __name__ == '__main__':
    unittest.main()
