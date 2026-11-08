"""frontend/tools/build_launcher.sh: the app is built with it, and its check rejects an executable that records its deployment target as
the SDK version, which is what swift build (Swift Build, Xcode 27) linked without the SDK on the link: no window from the Dock (#962)."""
import os
import platform
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'frontend' / 'tools' / 'build_launcher.sh'
WORKFLOW = ROOT / '.github' / 'workflows' / 'build-mac-app.yml'
TRY_LOCAL = ROOT / 'tools' / 'try-local'


def code(text):
    """The lines that run, without shell and YAML comments."""
    return [l for l in text.splitlines() if l.strip() and not l.strip().startswith('#')]


class BuiltWithIt(unittest.TestCase):
    def test_the_workflow_builds_the_app_with_it(self):
        step = WORKFLOW.read_text().split('      - name: Build\n', 1)[1].split('\n      - name:', 1)[0]
        self.assertIn('run: tools/build_launcher.sh', step)

    def test_try_local_builds_the_app_with_it(self):
        self.assertTrue(any(l.strip().startswith('frontend/tools/build_launcher.sh') for l in code(TRY_LOCAL.read_text())))

    def test_no_bare_release_build_is_left(self):
        for path in (WORKFLOW, TRY_LOCAL):
            for line in code(path.read_text()):
                self.assertNotRegex(line, r'^\s*(run:\s*)?(\( *cd frontend && *)?swift build -c release\b', f'{path.name}: {line.strip()}')

    def test_the_build_puts_the_sdk_on_the_link(self):
        """The flags the script passes to swift build are the ones Check links with."""
        line = next(l for l in code(SCRIPT.read_text()) if l.startswith('swift build'))
        self.assertIn('-Xswiftc -Xclang-linker -Xswiftc -isysroot -Xswiftc -Xclang-linker -Xswiftc "$SDK"', line)


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('xcrun'), 'needs macOS with Xcode')
class Check(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.dir = Path(cls.tmp.name)
        (cls.dir / 'main.swift').write_text('print("hello")\n')
        cls.env = {k: v for k, v in os.environ.items() if k != 'SDKROOT'}   # clang would read the SDK version from SDKROOT
        cls.sdk = subprocess.run(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], capture_output=True, text=True, check=True).stdout.strip()
        cls.swiftc = subprocess.run(['xcrun', '-f', 'swiftc'], capture_output=True, text=True, check=True).stdout.strip()

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def link(self, name, *extra):
        """main.swift linked for macOS 13 as Swift Build links the launcher: the toolchain's swiftc with -sdk and no SDKROOT."""
        out = self.dir / name
        subprocess.run([self.swiftc, '-target', f'{platform.machine()}-apple-macos13.0', '-sdk', self.sdk, *extra,
                        str(self.dir / 'main.swift'), '-o', str(out)], env=self.env, capture_output=True, check=True)
        return out

    def check(self, exe):
        return subprocess.run([str(SCRIPT), '--check', str(exe)], capture_output=True, text=True)

    def test_rejects_the_deployment_target_as_the_sdk(self):
        r = self.check(self.link('swift-build'))
        self.assertNotEqual(r.returncode, 0, r.stdout)
        self.assertIn('records SDK 13.0', r.stderr)
        self.assertIn('#962', r.stderr)

    def test_accepts_the_sdk_on_the_link(self):
        r = self.check(self.link('isysroot', '-Xclang-linker', '-isysroot', '-Xclang-linker', self.sdk))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertRegex(r.stdout, r'^ok .*SDK \d+(\.\d+)*, minimum macOS 13\.0$')


if __name__ == '__main__':
    unittest.main()
