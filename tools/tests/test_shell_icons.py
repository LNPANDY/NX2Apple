"""Regression checks for device builds on Macs without iOS Simulator runtimes."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('shell_icons', ROOT / 'frontend-ios/Shell/prepare_icons.py')
icons = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(icons)


class ShellIconsTests(unittest.TestCase):
    def runtime_result(self, runtimes, code=0):
        return subprocess.CompletedProcess([], code, json.dumps({'runtimes': runtimes}), '')

    def test_no_runtimes_and_unavailable_ios_do_not_require_installing_one(self):
        for runtimes in ([], [{'identifier': 'com.apple.CoreSimulator.SimRuntime.iOS-26-2', 'isAvailable': False}],
                         [{'identifier': 'com.apple.CoreSimulator.SimRuntime.tvOS-26-2', 'isAvailable': True}]):
            with self.subTest(runtimes=runtimes), mock.patch.object(icons.subprocess, 'run', return_value=self.runtime_result(runtimes)):
                self.assertFalse(icons.has_ios_runtime())

    def test_an_available_ios_runtime_preserves_icon_composer(self):
        runtime = {'identifier': 'com.apple.CoreSimulator.SimRuntime.iOS-26-2', 'isAvailable': True}
        with mock.patch.object(icons.subprocess, 'run', return_value=self.runtime_result([runtime])):
            self.assertTrue(icons.has_ios_runtime())
        with tempfile.TemporaryDirectory() as temp:
            spec = Path(temp) / 'project.yml'
            original = (ROOT / 'frontend-ios/Shell/project-shell.yml').read_text()
            spec.write_text(original)
            with mock.patch.object(icons, 'has_ios_runtime', return_value=True), mock.patch.object(icons.subprocess, 'run') as run:
                self.assertFalse(icons.prepare_icons(spec, ROOT / 'frontend-ios'))
                run.assert_not_called()
            self.assertEqual(spec.read_text(), original)

    def test_simctl_failure_timeout_or_missing_tool_uses_static_icon(self):
        for failure in (OSError('missing xcrun'), subprocess.TimeoutExpired('simctl', 15)):
            with mock.patch.object(icons.subprocess, 'run', side_effect=failure):
                self.assertFalse(icons.has_ios_runtime())
        for result in (self.runtime_result([], code=1), subprocess.CompletedProcess([], 0, 'invalid json', '')):
            with mock.patch.object(icons.subprocess, 'run', return_value=result):
                self.assertFalse(icons.has_ios_runtime())

    def test_no_runtime_project_has_png_icons_and_no_actool_inputs(self):
        with tempfile.TemporaryDirectory() as temp:
            spec = Path(temp) / 'project.yml'
            spec.write_text((ROOT / 'frontend-ios/Shell/project-shell.yml').read_text())
            with mock.patch.object(icons, 'has_ios_runtime', return_value=False), mock.patch.object(icons.subprocess, 'run') as run:
                self.assertTrue(icons.prepare_icons(spec, ROOT / 'frontend-ios'))
                sizes = [int(call.args[0][2]) for call in run.call_args_list]
            self.assertEqual(sizes, [120, 180, 152, 167])
            text = spec.read_text()
            self.assertNotIn('path: Gen/Assets.xcassets', text)
            self.assertNotIn('path: ${DM_SHELL_PACKAGE}/AppIcon.icon', text)
            self.assertNotIn('ASSETCATALOG_COMPILER_APPICON_NAME:', text)
            self.assertIn('- path: Gen/LegacyIcons\n        buildPhase: resources', text)
            self.assertIn('CFBundleIconFiles: [AppIcon60x60]', text)
            self.assertIn('CFBundleIconFiles: [AppIcon60x60, AppIcon76x76, AppIcon83.5x83.5]', text)
            self.assertIn('UIApplicationSceneManifest:', text)

    @unittest.skipUnless(sys.platform == 'darwin', 'PNG resizing uses macOS sips')
    def test_static_icons_are_real_pngs_at_device_icon_sizes(self):
        with tempfile.TemporaryDirectory() as temp:
            spec = Path(temp) / 'project.yml'
            spec.write_text((ROOT / 'frontend-ios/Shell/project-shell.yml').read_text())
            with mock.patch.object(icons, 'has_ios_runtime', return_value=False):
                icons.prepare_icons(spec, ROOT / 'frontend-ios')
            for name, size in [('AppIcon60x60@2x.png', 120), ('AppIcon60x60@3x.png', 180),
                               ('AppIcon76x76@2x.png', 152), ('AppIcon83.5x83.5@2x.png', 167)]:
                png = (Path(temp) / 'Gen/LegacyIcons' / name).read_bytes()
                self.assertEqual(png[:8], b'\x89PNG\r\n\x1a\n')
                self.assertEqual(struct.unpack('>II', png[16:24]), (size, size))

    def test_unsigned_build_entry_points_select_the_device_sdk_without_destination(self):
        shell = (ROOT / 'frontend-ios/Shell/build_shell.sh').read_text()
        command = shell[shell.index('xcodebuild -project DmShell.xcodeproj'):].split('CODE_SIGNING_ALLOWED=NO')[0]
        self.assertIn('-target DmShell', command)
        self.assertIn('-sdk iphoneos', command)
        self.assertNotIn('-destination', command)
        self.assertIn('prepare_icons.py', shell)
        template = (ROOT / 'tools/build_shell_template.py').read_text()
        self.assertIn("'-target', 'DmShell'", template)
        self.assertIn("'-sdk', 'iphoneos'", template)
        self.assertNotIn("'generic/platform=iOS'", template)
        self.assertIn("prepare_icons.py", template)

    @unittest.skipUnless(sys.platform == 'darwin', 'A device SDK build needs macOS')
    def test_unsigned_device_build_with_no_simulator_and_a_minimal_package(self):
        from tools.tests.test_shell_build import ENGINE, HAS_TOOLS, font_python, framework
        python = font_python()
        if not HAS_TOOLS or not python or not (ENGINE / 'dm/gfx/nvn/dmsh_chain.h').is_file():
            self.skipTest('Needs XcodeGen, iPhoneOS SDK, synced engine and fontTools')
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve()
            package = root / 'package'
            shell = package / 'Shell'
            app = shell / 'App'
            app.mkdir(parents=True)
            for name in ('build_shell.sh', 'project-shell.yml', 'prepare_icons.py'):
                shutil.copy2(ROOT / 'frontend-ios/Shell' / name, shell / name)
            shutil.copytree(ROOT / 'frontend-ios/AppIcon.icon', package / 'AppIcon.icon')
            shutil.copy2(ROOT / 'frontend-ios/AppIcon.png', package / 'AppIcon.png')
            # Compile the unchanged build pipeline without unrelated SDK requirements in the real UI package.
            names = ('ShellUI', 'ShellControllers', 'ShellHost')
            products = ','.join(f'.library(name:"{n}",targets:["{n}"])' for n in names)
            targets = ','.join(f'.target(name:"{n}")' for n in names)
            (package / 'Package.swift').write_text(
                '// swift-tools-version:6.2\nimport PackageDescription\n'
                f'let package = Package(name:"ShellUI",platforms:[.iOS(.v26)],products:[{products}],targets:[{targets}])\n'
            )
            for name in names:
                source = package / 'Sources' / name
                source.mkdir(parents=True)
                (source / 'Fixture.swift').write_text('public struct Fixture {}\n')
            (app / 'Shell-Bridging-Header.h').write_text('')
            (app / 'main.m').write_text(
                '#import <UIKit/UIKit.h>\n'
                '@interface AppDelegate : UIResponder <UIApplicationDelegate>\n@end\n'
                '@implementation AppDelegate\n@end\n'
                'int main(int argc, char **argv) { @autoreleasepool { return UIApplicationMain(argc, argv, nil, @"AppDelegate"); } }\n'
            )
            tools = root / 'tools'
            tools.mkdir()
            xcrun = tools / 'xcrun'
            xcrun.write_text(
                '#!/bin/sh\nif [ "$1" = simctl ]; then echo \'{"runtimes":[]}\'\n'
                'else exec /usr/bin/xcrun "$@"\nfi\n'
            )
            xcrun.chmod(0o755)
            fw = framework(root / 'frameworks', compile_it=True)
            project = root / 'project'
            env = dict(os.environ, SHELL_DIR=str(project), DM_SHELL_PACKAGE=str(package),
                       DM_ENGINE_DIR=str(ENGINE), DM_SHELL_FRAMEWORKS=str(fw), FONT_PY=python,
                       PATH=str(tools) + os.pathsep + os.environ['PATH'])
            result = subprocess.run(['bash', str(shell / 'build_shell.sh'), '--build'],
                                    env=env, capture_output=True, text=True, timeout=240)
            log = (project / 'build.log').read_text() if (project / 'build.log').exists() else ''
            self.assertEqual(result.returncode, 0, result.stdout[-2500:] + log[-4000:])
            built = project / 'dd/Build/Products/Release-iphoneos/DmShell.app'
            self.assertTrue((built / 'DmShell').is_file())
            self.assertTrue((built / f'Frameworks/{fw.name}/{fw.stem}').is_file())
            self.assertTrue((built / 'AppIcon60x60@3x.png').is_file())
            self.assertNotIn('CompileAssetCatalog', log)
            self.assertNotIn('generic/platform=iOS', log)


if __name__ == '__main__':
    unittest.main()
