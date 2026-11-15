"""Exercise the patch-queue ripgrep install step across release download, checksum guard and apt fallback."""
import io
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import unittest

WORKFLOW = Path(__file__).resolve().parents[2] / 'workflows/tests.yml'
X86_64_SHA = '1c9297be4a084eea7ecaedf93eb03d058d6faae29bbc57ecdaf5063921491599'
AARCH64_SHA = '2b661c6ef508e902f388e9098d9c4c5aca72c87b55922d94abdba830b4dc885e'


def ripgrep_step():
    lines = WORKFLOW.read_text().splitlines()
    start = next(i for i, line in enumerate(lines) if line == '      - name: Install ripgrep (the engine/ search test)')
    run_line = lines[start + 1]
    if run_line == '        run: |':
        body_start = start + 2
        end = next(i for i in range(body_start, len(lines)) if lines[i] and not lines[i].startswith('          '))
        return '\n'.join(line[10:] for line in lines[body_start:end])
    prefix = '        run: '
    if run_line.startswith(prefix):
        return run_line[len(prefix):]
    raise AssertionError(f'unexpected run line: {run_line!r}')


def write_exec(path: Path, body: str):
    path.write_text(body)
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


def build_fake_rg_tarball(archive_path: Path, member_dir: str):
    payload = b'#!/bin/sh\necho "ripgrep 15.1.0"\n'
    with tarfile.open(archive_path, 'w:gz') as tf:
        info = tarfile.TarInfo(name=f'{member_dir}/rg')
        info.size = len(payload)
        info.mode = 0o755
        tf.addfile(info, io.BytesIO(payload))


class PatchQueueRipgrepStep(unittest.TestCase):
    def run_step(
        self,
        arch='x86_64',
        preinstalled_rg=False,
        curl_fails=False,
        bad_sha=False,
        apt_fails=True,
    ):
        with tempfile.TemporaryDirectory(prefix='nx-rg-step-') as tmp:
            root = Path(tmp)
            bin_dir = root / 'bin'
            bin_dir.mkdir()
            runner_temp = root / 'runner_temp'
            runner_temp.mkdir()
            github_path = root / 'github_path'
            github_path.write_text('')
            log_file = root / 'calls.log'

            fixtures = root / 'fixtures'
            fixtures.mkdir()
            build_fake_rg_tarball(fixtures / 'x86_64.tar.gz', 'ripgrep-15.1.0-x86_64-unknown-linux-musl')
            build_fake_rg_tarball(fixtures / 'aarch64.tar.gz', 'ripgrep-15.1.0-aarch64-unknown-linux-gnu')

            for name in ('awk', 'gzip', 'install', 'mkdir', 'mktemp', 'rm', 'tar'):
                real = shutil.which(name)
                self.assertIsNotNone(real, f'missing host utility {name}')
                (bin_dir / name).symlink_to(real)

            write_exec(bin_dir / 'sudo', '#!/bin/sh\nexec "$@"\n')
            write_exec(bin_dir / 'uname', f'#!/bin/sh\necho "{arch}"\n')
            if preinstalled_rg:
                write_exec(bin_dir / 'rg', '#!/bin/sh\necho "ripgrep preinstalled"\n')

            expected_sha = X86_64_SHA if arch == 'x86_64' else AARCH64_SHA
            reported_sha = ('0' * 64) if bad_sha else expected_sha
            fixture_tar = fixtures / ('x86_64.tar.gz' if arch == 'x86_64' else 'aarch64.tar.gz')

            write_exec(
                bin_dir / 'curl',
                f'#!{sys.executable}\n'
                'from pathlib import Path\n'
                'import shutil\n'
                'import sys\n'
                'args = sys.argv[1:]\n'
                f'with Path({str(log_file)!r}).open("a") as fh:\n'
                '    fh.write("curl " + " ".join(args) + "\\n")\n'
                f'if {curl_fails!r}:\n'
                '    sys.stderr.write("curl: (6) Could not resolve host\\n")\n'
                '    sys.exit(6)\n'
                'out = args[args.index("-o") + 1]\n'
                f'shutil.copyfile({str(fixture_tar)!r}, out)\n'
                'sys.exit(0)\n',
            )

            write_exec(
                bin_dir / 'sha256sum',
                f'#!{sys.executable}\n'
                'from pathlib import Path\n'
                'import sys\n'
                'target = Path(sys.argv[1])\n'
                'if not target.is_file() or target.stat().st_size == 0:\n'
                '    sys.exit(1)\n'
                f'print("{reported_sha}  " + str(target))\n',
            )

            write_exec(
                bin_dir / 'apt-get',
                f'#!{sys.executable}\n'
                'from pathlib import Path\n'
                'import stat\n'
                'import sys\n'
                'args = sys.argv[1:]\n'
                f'with Path({str(log_file)!r}).open("a") as fh:\n'
                '    fh.write("apt-get " + " ".join(args) + "\\n")\n'
                f'if {apt_fails!r}:\n'
                '    sys.stderr.write("E: Temporary failure resolving security.ubuntu.com\\n")\n'
                '    sys.exit(100)\n'
                'if "install" in args:\n'
                f'    rg = Path({str(bin_dir / "rg")!r})\n'
                '    rg.write_text("#!/bin/sh\\necho \\"ripgrep apt\\"\\n")\n'
                '    rg.chmod(rg.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)\n'
                'sys.exit(0)\n',
            )

            env = dict(
                os.environ,
                PATH=str(bin_dir),
                RUNNER_TEMP=str(runner_temp),
                GITHUB_PATH=str(github_path),
            )
            result = subprocess.run(
                ['/bin/bash', '--noprofile', '--norc', '-e', '-o', 'pipefail', '-c', ripgrep_step()],
                cwd=root,
                env=env,
                capture_output=True,
                text=True,
            )
            calls = log_file.read_text().splitlines() if log_file.exists() else []
            gh_paths = github_path.read_text().splitlines()
            installed_rg = runner_temp / 'ripgrep-bin/rg'
            return result, calls, gh_paths, installed_rg.is_file()

    def test_preinstalled_rg_skips_download_and_apt(self):
        result, calls, gh_paths, _ = self.run_step(preinstalled_rg=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(calls, [])
        self.assertEqual(gh_paths, [])

    def test_x86_64_installs_pinned_release_when_ubuntu_dns_is_down(self):
        result, calls, gh_paths, installed = self.run_step(arch='x86_64', apt_fails=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(installed)
        self.assertEqual(len(gh_paths), 1)
        self.assertTrue(gh_paths[0].endswith('/ripgrep-bin'), gh_paths)
        self.assertTrue(any('ripgrep-15.1.0-x86_64-unknown-linux-musl.tar.gz' in c for c in calls), calls)
        self.assertFalse(any(c.startswith('apt-get ') for c in calls), calls)

    def test_aarch64_installs_pinned_arm64_release(self):
        result, calls, _, installed = self.run_step(arch='aarch64', apt_fails=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(installed)
        self.assertTrue(any('ripgrep-15.1.0-aarch64-unknown-linux-gnu.tar.gz' in c for c in calls), calls)
        self.assertFalse(any(c.startswith('apt-get ') for c in calls), calls)

    def test_sha256_mismatch_aborts_without_apt_fallback(self):
        result, calls, _, installed = self.run_step(arch='x86_64', bad_sha=True, apt_fails=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('sha256', result.stderr)
        self.assertFalse(installed)
        self.assertFalse(any(c.startswith('apt-get ') for c in calls), calls)

    def test_curl_failure_falls_back_to_apt(self):
        ok_res, ok_calls, _, _ = self.run_step(arch='x86_64', curl_fails=True, apt_fails=False)
        self.assertEqual(ok_res.returncode, 0, ok_res.stdout + ok_res.stderr)
        self.assertTrue(any(c.startswith('apt-get ') and 'install' in c for c in ok_calls), ok_calls)

        bad_res, _, _, _ = self.run_step(arch='x86_64', curl_fails=True, apt_fails=True)
        self.assertNotEqual(bad_res.returncode, 0)


if __name__ == '__main__':
    unittest.main()
