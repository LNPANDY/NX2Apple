"""Route C M1 (docs/launcher-c-plan.md): xcodebuild links the game's modules into DmGame.framework, off a device.

Builds the framework target of project-framework.yml from a synthetic Gen/ (two 64 KB stand-in modules: main and one NRO) and
reads the linked dylib back with otool: the three section blocks of each module are in the framework (__TEXT,__dm<mod>x0,
__DM<mod>W,__img, __TEXT,__dm<mod>x1), the NRO pieces with them (__TEXT,__dm_nro_x0, __DM_NRO_W,__img, __TEXT,__dm_nro_x1) and
__DATA,__dm_nro_tab lists them; the install name is @rpath/DmGame.framework/DmGame; the framework carries its dm/ tables,
profile.tsv and game.manifest.json at its root. The generated project also shows what the app does with it: an Embed Frameworks
phase and LD_RUNPATH_SEARCH_PATHS @executable_path/Frameworks. No game files, shaders or signing are involved.

Needs macos, XcodeGen and an iPhoneOS SDK; skipped otherwise (CI's tool tests run without a device but with both).
"""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[3]
GAME = '010015100B514000'
HAS_TOOLS = (sys.platform == 'darwin' and shutil.which('xcodegen') and shutil.which('xcodebuild')
             and subprocess.run(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], capture_output=True).returncode == 0)


def run(*command, cwd=None, env=None):
    return subprocess.run([str(c) for c in command], cwd=cwd, env=env, capture_output=True, text=True)


def fail_tail(result):
    return '\n'.join((result.stdout + result.stderr).splitlines()[-40:])


def sections(binary):
    """(segment, section) pairs from otool -l: a section block names its segment first."""
    out = run('otool', '-l', binary).stdout
    pairs, segment = set(), None
    for line in out.splitlines():
        words = line.split()
        if len(words) == 2 and words[0] == 'segname': segment = words[1]
        elif len(words) == 2 and words[0] == 'sectname' and segment: pairs.add((segment, words[1]))
    return pairs


@unittest.skipUnless(HAS_TOOLS, 'needs macOS, XcodeGen and an iPhoneOS SDK')
class FrameworkLinkTests(unittest.TestCase):
    def test_the_framework_carries_the_module_sections_and_the_loader_tables(self):
        root = Path(tempfile.mkdtemp()).resolve()
        self.addCleanup(shutil.rmtree, root)
        project, gen = root / 'project', root / 'project/Gen'
        (gen / 'dm').mkdir(parents=True)
        (gen / 'src').mkdir()
        (gen / 'main').mkdir()
        (gen / 'Assets.xcassets').mkdir()
        (gen / 'Assets.xcassets/Contents.json').write_text(json.dumps({'info': {'author': 'xcode', 'version': 1}}))
        (gen / 'src/fixture.c').write_text('/* stand-in: the app target is not built here */\n')
        (gen / 'main/main.c').write_text('int dm_main(int argc, char **argv) { (void)argc; (void)argv; return 0; }\n')
        for name in ('Sources', 'tools', 'framework'):
            (project / name).symlink_to(REPO / 'dm/ios' / name, target_is_directory=True)
        shutil.copyfile(REPO / 'dm/ios/project-framework.yml', project / 'project.yml')

        # Two stand-in modules with the rewriter's four boundary keys; the NRO is listed in nro.tsv, so gen_embed.py packs it
        patched = root / 'patched'
        patched.mkdir()
        for name in ('main', 'nrotest'):
            (patched / f'{name}.patched.bin').write_bytes(bytes(0x10000))
            (patched / f'{name}.fixups.tsv').write_text('# TEXT_END 0x4000\n# PATCH_OFF 0xc000\n# KEY_PAGE_OFF 0x8000\n# KEY_PAGE_SIZE 0x4000\n')
        (patched / 'nro.tsv').write_text('nrotest\tfixture.nro\n')
        flags = run(sys.executable, REPO / 'dm/ios/tools/gen_embed.py', patched, gen / 'embed.S', 'main', 'nrotest')
        self.assertEqual(flags.returncode, 0, fail_tail(flags))
        # The app target's config is not used by `xcodebuild -target DmGame`; it only has to exist (xcodegen's configFiles)
        (gen / 'dm.xcconfig').write_text('HEADER_SEARCH_PATHS = $(inherited)\nOTHER_CFLAGS = $(inherited)\nDM_FRAMEWORKS =\nOTHER_LDFLAGS = $(inherited)\n')
        (gen / 'framework.xcconfig').write_text(f'OTHER_LDFLAGS = $(inherited) {flags.stdout.strip()}\n')
        (gen / 'framework/dm').mkdir(parents=True)
        for name in ('main.fixups.tsv', 'nrotest.fixups.tsv', 'nro.tsv'):
            shutil.copyfile(patched / name, gen / 'dm' / name)
        (gen / 'dm/shader_map.tsv').write_text('key\tfixture\n')
        for name in ('main.fixups.tsv', 'nrotest.fixups.tsv', 'nro.tsv', 'shader_map.tsv'):
            shutil.copyfile(gen / 'dm' / name, gen / 'framework/dm' / name)
        profile = run(sys.executable, REPO / 'dm/games/game.py', 'profile', GAME, gen / 'framework/profile.tsv')
        self.assertEqual(profile.returncode, 0, fail_tail(profile))
        chain = next(line.split('"')[1] for line in (REPO / 'dm/gfx/nvn/dmsh_chain.h').read_text().splitlines()
                     if line.startswith('#define DMSH_CHAIN "'))
        manifest = run(sys.executable, REPO / 'dm/ios/tools/gen_manifest.py', gen / 'framework/game.manifest.json', '--game', GAME,
                       '--name', 'Fixture Game', '--display-version', '1.0', '--package-version', 'v0', '--modules', 'main',
                       '--nro-table', patched / 'nro.tsv', '--chain', 'b-' + chain, '--romfs-marker', 'marker')
        self.assertEqual(manifest.returncode, 0, fail_tail(manifest))

        env = dict(os.environ, GAME=GAME, DM_GAME=GAME, DM_BUNDLE_ID='org.nxnative.fixture', DM_DISPLAY_NAME='Fixture Game',
                   DM_APP_VERSION='1.0', DM_APP_CATEGORY='action', DM_TEAM_ID='', DM_SCHEME_NAME='DmIOS', DM_APPICON='',
                   DM_SHOW_FPS='NO', DM_LANG='en-US')
        generated = run('xcodegen', 'generate', cwd=project, env=env)
        self.assertEqual(generated.returncode, 0, fail_tail(generated))
        pbx = (project / 'DmIOS.xcodeproj/project.pbxproj').read_text()
        self.assertIn('Embed Frameworks', pbx)                     # the app embeds the framework ...
        self.assertIn('@executable_path/Frameworks', pbx)          # ... and can find it by that path
        self.assertIn('LD_RUNPATH_SEARCH_PATHS', pbx)

        derived = root / 'derived'
        built = run('xcodebuild', '-project', project / 'DmIOS.xcodeproj', '-target', 'DmGame', '-configuration', 'Release',
                    '-destination', 'generic/platform=iOS',
                    f'SYMROOT={derived}/Build/Products', f'OBJROOT={derived}/Build/Intermediates.noindex',
                    'CODE_SIGNING_ALLOWED=NO', 'CODE_SIGNING_REQUIRED=NO', 'CODE_SIGN_IDENTITY=', 'build', cwd=project, env=env)
        self.assertEqual(built.returncode, 0, fail_tail(built))
        framework = derived / 'Build/Products/Release-iphoneos/DmGame.framework'
        binary = framework / 'DmGame'
        self.assertTrue(binary.is_file(), f'no {binary}')
        self.assertEqual(plistlib.loads((framework / 'Info.plist').read_bytes())['CFBundleExecutable'], 'DmGame')
        for name in ('dm/shader_map.tsv', 'dm/nro.tsv', 'dm/main.fixups.tsv', 'profile.tsv', 'game.manifest.json'):
            self.assertTrue((framework / name).is_file(), f'the framework is missing {name}')
        self.assertEqual(json.loads((framework / 'game.manifest.json').read_text())['nro_count'], 1)

        got = sections(binary)
        for pair in [('__TEXT', '__dmmainx0'), ('__DMmainW', '__img'), ('__TEXT', '__dmmainx1'),
                     ('__TEXT', '__dmnrotestx0'), ('__DMnrotestW', '__img'), ('__TEXT', '__dmnrotestx1'),
                     ('__TEXT', '__dm_nro_x0'), ('__DM_NRO_W', '__img'), ('__TEXT', '__dm_nro_x1'),
                     ('__DATA', '__dm_nro_tab')]:
            self.assertIn(pair, got, f'{pair[0]},{pair[1]} is not a section of the framework')
        self.assertIn('@rpath/DmGame.framework/DmGame', run('otool', '-D', binary).stdout)


if __name__ == '__main__':
    unittest.main()
