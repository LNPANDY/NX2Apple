"""tools/patches.py, the library tools/engine.py is built on (LNPANDY/NX2Apple#123, #214): the headers of a patch, `status`, the
chain rule read from the engine's AGENTS.md, and the engine sources that carry the fork's patch list. The series itself is
applied and checked by tools/tests/test_engine.py. No game files, no network."""
import importlib.util, os, shutil, subprocess, sys, tempfile, unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
TOOL = REPO / 'tools/patches.py'
# The engine sources the tests read: engine/, made by `python3 tools/engine.py sync` (LNPANDY/NX2Apple#214)
SRC = REPO / 'engine'
spec = importlib.util.spec_from_file_location('patches_tool', TOOL)
P = importlib.util.module_from_spec(spec); spec.loader.exec_module(P)


def setUpModule():
    if not (SRC / 'AGENTS.md').is_file():
        raise RuntimeError('engine/ is missing: run `python3 tools/engine.py sync` first')


PATCH = """From 0000000000000000000000000000000000000000 Mon Sep 17 00:00:00 2001
From: t <t@example.invalid>
Date: Mon, 5 Oct 2026 10:00:00 +0000
Subject: [PATCH] Make line 2 the fork's

Why: a test.

%s
---
 dm/a.c | 2 +-
 1 file changed, 1 insertion(+), 1 deletion(-)

diff --git a/dm/a.c b/dm/a.c
--- a/dm/a.c
+++ b/dm/a.c
@@ -1 +1 @@
-x
+y
"""
HEADER = 'Upstream-Status: forwarded seedds/nxnative#475\nReason: the fork needs line 2\nIssue: LNPANDY/NX2Apple#1'


class Queue(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix='test-patches-'))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        (self.tmp / 'patches').mkdir()
        self.patch = self.tmp / 'patches/0001-line-2.patch'
        self.patch.write_text(PATCH % HEADER)
        (self.tmp / 'patches/series').write_text('# order\n0001-line-2.patch\n')

    def test_the_headers_are_read(self):
        p, = P.load(self.tmp)
        self.assertEqual((p.kind, p.reason, p.issue, p.files), ('forwarded', 'the fork needs line 2', 'LNPANDY/NX2Apple#1', ['dm/a.c']))
        self.assertEqual(p.problems(), [])

    def test_a_patch_without_a_header_has_problems(self):
        self.patch.write_text(PATCH % HEADER.replace('Reason: the fork needs line 2\n', ''))
        self.assertIn('Reason is missing', P.load(self.tmp)[0].problems())
        self.patch.write_text(PATCH % 'Upstream-Status: forwarded\nReason: r\nIssue: LNPANDY/NX2Apple#1')
        self.assertTrue(any('needs the upstream PR' in m for m in P.load(self.tmp)[0].problems()))

    def test_status_lists_the_patch(self):
        r = subprocess.run([sys.executable, str(TOOL), '--repo', str(self.tmp), 'status'], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('forwarded seedds/nxnative#475', r.stdout); self.assertIn('the fork needs line 2', r.stdout)

    def test_a_subject_with_a_non_ascii_character_is_read_as_git_log_prints_it(self):
        # format-patch writes it as RFC 2047 words, split over lines when long: refresh matches commits to patches by this text
        raw = '=?UTF-8?q?Cheats:=20the=20Atmosph=C3=A8re=20cheat=20engin?=\n =?UTF-8?q?e,=20its=20hooks?='
        self.assertEqual(P.Patch.decode_subject(raw), 'Cheats: the Atmosph\u00e8re cheat engine, its hooks')
        self.assertEqual(P.Patch.decode_subject('plain  subject'), 'plain subject')

    def test_the_commands_of_the_committed_tree_are_gone(self):
        r = subprocess.run([sys.executable, str(TOOL), '--repo', str(self.tmp), 'apply'], capture_output=True, text=True)
        self.assertEqual(r.returncode, 2)


class ChainRule(unittest.TestCase):
    def test_the_chain_paths_come_from_the_engines_agents_md(self):
        g = P.chain_paths(SRC)
        for want in ('dm/gfx/nvn/dmsh_chain.h', 'dm/gfx/tools/dmsh_*', 'dm/gfx/tools/Program.cs', 'dm/gfx/tools/ios_metal.py', 'dm/gfx/tools/dmsh_chain.lock', 'dm/gfx/tools/dmsh_xlate_bin*'):
            self.assertIn(want, g)

    def test_hits(self):
        self.assertEqual(P.chain_hits(['dm/gfx/tools/dmsh_pull.py', 'dm/a.c', 'dm/gfx/nvn/dmsh_chain.h'], SRC),
                         ['dm/gfx/nvn/dmsh_chain.h', 'dm/gfx/tools/dmsh_pull.py'])


class ForkPatchList(unittest.TestCase):
    def test_the_mac_app_stamps_the_list_into_info_plist(self):
        """pack_app.py's DMForkPatches is dm/fork_patches.txt, comma-separated, and empty without the file"""
        sys.path.insert(0, str(SRC / 'dm/tools'))
        spec = importlib.util.spec_from_file_location('pack_app_under_test', SRC / 'dm/mac/pack_app.py')
        mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
        self.tmp = Path(tempfile.mkdtemp(prefix='test-patches-')); self.addCleanup(shutil.rmtree, self.tmp, True)
        fake = self.tmp / 'dm/mac'; fake.mkdir(parents=True)
        mod.__file__ = str(fake / 'pack_app.py')
        self.assertEqual(mod.fork_patches(), '')
        (self.tmp / 'dm/fork_patches.txt').write_text('runtime-profile\nbc-cpu-decode\n')
        self.assertEqual(mod.fork_patches(), 'runtime-profile,bc-cpu-decode')
        args = type('A', (), dict(name='G', bundle_id=None, title_id='0100000000000000', version=None, category=None, marker=None, lang=None, settings=None))()
        self.assertEqual(mod.info_plist(args, '26.0', False)['DMForkPatches'], 'runtime-profile,bc-cpu-decode')

    def test_the_first_log_line_and_the_ios_key_are_in_the_sources(self):
        """a read of the sources, not a run: the iOS app and the Mac launcher write the line, project.yml carries the key"""
        self.assertIn('"fork patches: %s\\n"', (SRC / 'dm/ios/Sources/main.m').read_text())
        self.assertIn('"fork patches: %s\\n"', (SRC / 'dm/mac/launcher.c').read_text())
        self.assertIn('DMForkPatches: ${DM_FORK_PATCHES}', (SRC / 'dm/ios/project.yml').read_text())


class HostTestRules(unittest.TestCase):
    def test_sdk16_tests_keep_runtime_profile_linkage_after_refresh(self):
        r = subprocess.run(
            ['make', '-n', '-B', 'GAME=010015100B514000', 'build/t_language', 'build/t_shared_font'],
            cwd=SRC / 'dm/host/tests', capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        for name in ('t_language', 't_shared_font'):
            command = next(line for line in r.stdout.splitlines() if f'-o build/{name} ' in line)
            self.assertIn(f'{name}.c ../hle_profile.c', command)
            if name == 't_language':
                self.assertIn('-fsanitize=address,undefined', command)
        rules = (SRC / 'dm/host/tests/Makefile').read_text().splitlines()
        prerequisites = ' '.join(line for line in rules if line.startswith('run:'))
        for name in ('t_language', 't_input_map', 't_launcher_contract'):
            self.assertIn(f'$(B)/{name}', prerequisites)
            self.assertIn(f'\t$(B)/{name}', rules)


if __name__ == '__main__':
    unittest.main()
