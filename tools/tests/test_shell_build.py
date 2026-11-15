"""Route C shell (notes/launcher-c-plan.md M2): frontend-ios/Shell/build_shell.sh, off a device.

The checks of the frameworks it is given run anywhere: a manifest without a host in the framework, two frameworks of one title, a folder
whose name the manifest does not give and a missing executable are refused before anything is generated, and two games go into one
shell (each framework carries its own host). With XcodeGen and an iPhoneOS SDK the shell is also generated and built, unsigned, around a
synthetic framework (a one-symbol dylib, no game code): the app embeds the framework without linking it (the shell dlopens it), carries
LC_RPATH @executable_path/Frameworks, the frontend-ios package's resource bundles, its name and the chain in Info.plist, and a prepared
project asks for the Increased Memory Limit (DM_ENTITLEMENTS= leaves it out). No game files, shaders or signing are involved.
"""
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ENGINE = ROOT / 'engine'
SCRIPT = ROOT / 'frontend-ios/Shell/build_shell.sh'
GAME = '010015100B514000'
OTHER = '0100000000010000'
HAS_TOOLS = (sys.platform == 'darwin' and shutil.which('xcodegen') and shutil.which('xcodebuild')
             and subprocess.run(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], capture_output=True, check=False).returncode == 0)


def chain_version():
    hdr = ENGINE / 'dm/gfx/nvn/dmsh_chain.h'
    if not hdr.is_file():
        return 'b-000000000000'
    return 'b-' + next(line.split('"')[1] for line in hdr.read_text().splitlines()
                       if line.startswith('#define DMSH_CHAIN "'))


def font_python():
    """A python that has fontTools, for make_ext_font.py (FONT_PY), or None."""
    for py in (os.environ.get('FONT_PY'), sys.executable, shutil.which('python3')):
        if py and subprocess.run([py, '-c', 'import fontTools'], capture_output=True, check=False).returncode == 0:
            return py
    return None


def framework(root, title=GAME, chain=None, loader='FH', name=None, executable=True, compile_it=False):
    """A framework folder as build_ipa.sh DM_FRAMEWORK_ONLY writes it, with a manifest and, optionally, a real arm64 dylib."""
    chain = chain or chain_version()
    name = name or f'DmGame{title}'
    fw = Path(root) / f'{name}.framework'
    (fw / 'dm').mkdir(parents=True)
    exe = f'DmGame{title}'
    manifest = {'schema': 1, 'title_id': title, 'name': f'Fixture {title}', 'display_version': '1.0', 'package_version': 'v0',
                'modules': ['main'], 'nro_count': 0, 'chain': chain, 'loader': loader, 'framework': f'DmGame{title}.framework',
                'framework_executable': exe, 'image_marker': 'dmgame_image_marker', 'profile': 'profile.tsv',
                'shader_map': 'dm/shader_map.tsv', 'launcher': 'dm/launcher.json', 'romfs_marker': 'fixture.marker',
                'romfs_identity': '', 'min_os': '26.0'}
    (fw / 'game.manifest.json').write_text(json.dumps(manifest, indent=2))
    (fw / 'dm/launcher.json').write_text(json.dumps({'schema': 1, 'game': title, 'settings': []}))
    (fw / 'profile.tsv').write_text(f'id\t{title}\n')
    plist = {'CFBundleExecutable': exe, 'CFBundleIdentifier': f'org.nxnative.ci.{title.lower()}', 'CFBundleName': exe,
             'CFBundlePackageType': 'FMWK', 'CFBundleShortVersionString': '1.0', 'CFBundleVersion': '1.0',
             'CFBundleSupportedPlatforms': ['iPhoneOS'], 'MinimumOSVersion': '26.0'}
    (fw / 'Info.plist').write_bytes(plistlib.dumps(plist))
    if compile_it:
        src = Path(root) / 'marker.c'
        src.write_text('__attribute__((used, visibility("default"))) const char dmgame_image_marker[] = "DmGame";\n')
        r = subprocess.run(['xcrun', '-sdk', 'iphoneos', 'clang', '-arch', 'arm64', '-mios-version-min=26.0', '-dynamiclib',
                            '-install_name', f'@rpath/{exe}.framework/{exe}', str(src), '-o', str(fw / exe)], capture_output=True, text=True, check=False)
        assert r.returncode == 0, r.stderr
    elif executable:
        (fw / exe).write_bytes(b'stand-in')
    return fw


def run_script(mode, frameworks, shell_dir, **extra):
    env = dict(os.environ, SHELL_DIR=str(shell_dir), DM_SHELL_FRAMEWORKS='\n'.join(str(f) for f in frameworks), **extra)
    return subprocess.run(['bash', str(SCRIPT), mode], env=env, capture_output=True, text=True, check=False)


@unittest.skipUnless((ENGINE / 'dm/gfx/nvn/dmsh_chain.h').is_file(), 'engine/ is not synced (python3 tools/engine.py sync)')
class FrameworkChecks(unittest.TestCase):
    """What build_shell.sh refuses before it generates anything."""
    def setUp(self):
        self.root = Path(tempfile.mkdtemp()).resolve()
        self.addCleanup(shutil.rmtree, self.root)
        self.shell = self.root / 'shell'

    def refused(self, frameworks, text, **extra):
        r = run_script('--prepare-xcode', frameworks, self.shell, **extra)
        self.assertNotEqual(r.returncode, 0, r.stdout)
        self.assertIn(text, r.stdout + r.stderr)
        self.assertFalse((self.shell / 'Gen').exists(), 'nothing is generated for a refused set')

    def test_a_framework_without_its_host_is_refused(self):
        self.refused([framework(self.root, loader='FR')], 'built without a host in the framework')

    def test_two_frameworks_of_one_title_are_refused(self):
        a = framework(self.root / 'a')
        b = framework(self.root / 'b')
        self.refused([a, b], f'title ID {GAME} is already in the shell')

    def test_two_games_of_different_chains_go_into_one_shell(self):
        chain = chain_version()
        r = run_script('--prepare-xcode', [framework(self.root / 'a', chain='b-000000000000'), framework(self.root / 'b', title=OTHER, chain=chain)],
                       self.shell, PATH='/usr/bin:/bin', DM_ENGINE_DIR=str(ENGINE))
        rows = (self.shell / 'frameworks.txt').read_text().splitlines()
        self.assertEqual([row.split('\t')[0] for row in rows], [GAME, OTHER], r.stdout)

    def test_missing_engine_dir_is_refused_cleanly(self):
        empty = self.root / 'empty-engine'
        empty.mkdir()
        self.refused([framework(self.root)], 'no engine dm/ folder', DM_ENGINE_DIR=str(empty))

    def test_a_folder_the_manifest_does_not_name_is_refused(self):
        self.refused([framework(self.root, name='Renamed')], f'the manifest names DmGame{GAME}.framework')

    def test_a_framework_without_its_executable_is_refused(self):
        self.refused([framework(self.root, executable=False)], f'no executable DmGame{GAME}')

    def test_no_frameworks_and_no_mode_are_refused(self):
        r = run_script('--prepare-xcode', [], self.shell)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('DM_SHELL_FRAMEWORKS is not set', r.stdout)
        r = run_script('--sign', [framework(self.root)], self.shell)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('usage', r.stdout)


@unittest.skipUnless((ENGINE / 'dm/ios/Sources/front_ios.m').is_file(), 'engine/ is not synced (python3 tools/engine.py sync)')
class ShellMainProvidesWhatFrontIosTakes(unittest.TestCase):
    """front_ios.m is compiled into each game's framework unchanged and main.m is not linked, so ShellGlue.m has to
    define every function front_ios.m declares as coming from main.m and the glue symbols ShellMain.m looks up with dlsym."""
    def test_every_symbol_front_ios_and_shell_main_take_is_defined(self):
        front = (ENGINE / 'dm/ios/Sources/front_ios.m').read_text()
        wanted = re.findall(r'^[A-Za-z_][\w \t\*]*?\b(\w+)\([^)]*\);[ \t]*//[^\n]*\bmain\.m\b', front, re.M)
        self.assertIn('front_ios_boot_message', wanted)
        glue = (ENGINE / 'dm/ios/framework/ShellGlue.m').read_text()
        wanted_all = [*dict.fromkeys(wanted), 'dm_glue_start_game', 'dm_glue_present_game', 'dm_glue_focus_event']
        missing = [n for n in wanted_all if not re.search(r'^[A-Za-z_][\w \t\*]*?\b' + n + r'\([^)]*\)[ \t]*\{', glue, re.M)]
        self.assertEqual(missing, [], 'ShellGlue.m does not define what front_ios.m and ShellMain.m take')
        self.assertIn('dm_glue_version =', glue)
        shell_main = (ROOT / 'frontend-ios/Shell/App/ShellMain.m').read_text()
        self.assertRegex(shell_main, r'\bdm_shell_return_to_library\s*\(void\)')
        self.assertIn('dm_shell_return_to_library', front)
        self.assertIn('dm_host_teardown_for_shell', front)
        self.assertEqual(
            (ROOT / 'frontend-ios/Shell/App/ShellGlue.h').read_text(),
            (ENGINE / 'dm/ios/framework/ShellGlue.h').read_text(),
            'ShellGlue.h must stay identical between frontend-ios/Shell/App and engine/dm/ios/framework',
        )


@unittest.skipUnless(HAS_TOOLS and font_python() and (ENGINE / 'dm/gfx/nvn/dmsh_chain.h').is_file(),
                     'needs macOS, XcodeGen, an iPhoneOS SDK, synced engine/ and a python with fontTools')
class ShellBuild(unittest.TestCase):
    def test_the_shell_embeds_the_framework_unlinked_and_builds(self):
        root = Path(tempfile.mkdtemp()).resolve()
        self.addCleanup(shutil.rmtree, root)
        chain = chain_version()
        fw = framework(root / 'frameworks', chain=chain, compile_it=True)
        shell = root / 'shell'
        r = run_script('--prepare-xcode', [fw], shell, FONT_PY=font_python(), DM_ENGINE_DIR=str(ENGINE),
                       DM_SHELL_NAME='Shell Fixture', DM_BUNDLE_ID='org.nxnative.ci.shell')
        self.assertEqual(r.returncode, 0, r.stdout[-3000:] + r.stderr[-2000:])
        spec = (shell / 'project.yml').read_text()
        self.assertIn(f'- framework: "{fw}"', spec)
        self.assertIn('embed: true', spec)
        self.assertIn('link: false', spec)
        self.assertIn('path: ${DM_SHELL_PACKAGE}', spec)
        self.assertIn('CODE_SIGN_ENTITLEMENTS = Gen/DmShell.entitlements', (shell / 'Gen/dm.xcconfig').read_text())
        self.assertIn('increased-memory-limit', (shell / 'Gen/DmShell.entitlements').read_text())
        pbx = (shell / 'DmShell.xcodeproj/project.pbxproj').read_text()
        self.assertIn('Embed Frameworks', pbx)
        self.assertIn('XCLocalSwiftPackageReference', pbx)
        r = run_script('--prepare-xcode', [fw], shell, FONT_PY=font_python(), DM_ENGINE_DIR=str(ENGINE), DM_ENTITLEMENTS='')
        self.assertEqual(r.returncode, 0, r.stdout[-3000:])
        self.assertNotIn('CODE_SIGN_ENTITLEMENTS', (shell / 'Gen/dm.xcconfig').read_text())

        r = run_script('--build', [fw], shell, FONT_PY=font_python(), DM_ENGINE_DIR=str(ENGINE),
                       DM_SHELL_NAME='Shell Fixture', DM_BUNDLE_ID='org.nxnative.ci.shell')
        log = (shell / 'build.log').read_text() if (shell / 'build.log').exists() else ''
        self.assertEqual(r.returncode, 0, r.stdout[-3000:] + log[-4000:])
        app = shell / 'dd/Build/Products/Release-iphoneos/DmShell.app'
        info = plistlib.loads((app / 'Info.plist').read_bytes())
        self.assertEqual(info['CFBundleDisplayName'], 'Shell Fixture')
        self.assertEqual(info['CFBundleIdentifier'], 'org.nxnative.ci.shell')
        self.assertNotIn('UIRequiresFullScreen', info)
        landscape = {'UIInterfaceOrientationLandscapeLeft', 'UIInterfaceOrientationLandscapeRight'}
        self.assertEqual(set(info['UISupportedInterfaceOrientations']), landscape | {'UIInterfaceOrientationPortrait'})
        self.assertEqual(set(info['UISupportedInterfaceOrientations~ipad']),
                         landscape | {'UIInterfaceOrientationPortrait', 'UIInterfaceOrientationPortraitUpsideDown'})
        self.assertEqual('b-' + info['DMChain'], chain)
        self.assertEqual(info['CFBundleIcons']['CFBundlePrimaryIcon']['CFBundleIconName'], 'AppIcon')
        self.assertTrue((app / 'Assets.car').is_file())
        self.assertEqual(info['UIApplicationSceneManifest']['UISceneConfigurations']['UIWindowSceneSessionRoleApplication'][0]['UISceneDelegateClassName'], 'SceneDelegate')
        self.assertTrue((app / f'Frameworks/{fw.name}/{fw.stem}').is_file())
        self.assertTrue((app / f'Frameworks/{fw.name}/game.manifest.json').is_file())
        self.assertTrue((app / 'dm/font/standard.ttf').is_file())
        self.assertTrue(any(p.name.endswith('ShellHost.bundle') for p in app.iterdir()), 'the ShellHost package resources')
        load = subprocess.run(['otool', '-l', str(app / 'DmShell')], capture_output=True, text=True, check=False).stdout
        self.assertIn('@executable_path/Frameworks', load)
        self.assertNotIn(fw.stem, subprocess.run(['otool', '-L', str(app / 'DmShell')], capture_output=True, text=True, check=False).stdout,
                         'the shell dlopens the game framework, it must not link it')
        exported = subprocess.run(['nm', '-gU', str(app / 'DmShell')], capture_output=True, text=True, check=False).stdout
        self.assertIn('_dm_shell_return_to_library', exported, 'the shell executable must export _dm_shell_return_to_library for front_ios.m dlsym')


if __name__ == '__main__':
    unittest.main()
