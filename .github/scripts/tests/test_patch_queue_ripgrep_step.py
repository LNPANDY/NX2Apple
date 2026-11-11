"""Exercise the patch-queue ripgrep install step against preinstalled rg and security.ubuntu.com DNS outages."""
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest

WORKFLOW = Path(__file__).resolve().parents[2] / 'workflows/tests.yml'


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


class PatchQueueRipgrepStep(unittest.TestCase):
    def run_step(self, preinstalled_rg=False, unrecoverable=False):
        with tempfile.TemporaryDirectory(prefix='nx-rg-step-') as tmp:
            root = Path(tmp)
            bin_dir = root / 'bin'
            bin_dir.mkdir()
            apt_etc = root / 'etc/apt'
            sources_d = apt_etc / 'sources.list.d'
            sources_d.mkdir(parents=True)
            ubuntu_sources = sources_d / 'ubuntu.sources'
            ubuntu_sources.write_text(
                'Types: deb\n'
                'URIs: http://azure.archive.ubuntu.com/ubuntu/\n'
                'Suites: noble noble-updates\n\n'
                'Types: deb\n'
                'URIs: https://security.ubuntu.com/ubuntu/\n'
                'Suites: noble-security\n'
            )
            log_file = root / 'calls.log'
            state_dir = root / 'state'
            state_dir.mkdir()

            # Locate system tools before restricting PATH so rg from the host machine cannot leak in.
            write_exec(bin_dir / 'sudo', '#!/bin/sh\nexec "$@"\n')
            if preinstalled_rg:
                write_exec(bin_dir / 'rg', '#!/bin/sh\nexit 0\n')

            write_exec(
                bin_dir / 'apt-get',
                f'#!{sys.executable}\n'
                'from pathlib import Path\n'
                'import stat\n'
                'import sys\n'
                'args = sys.argv[1:]\n'
                f'log = Path({str(log_file)!r})\n'
                'with log.open("a") as fh:\n'
                '    fh.write("apt-get " + " ".join(args) + "\\n")\n'
                'if "update" in args:\n'
                f'    Path({str(state_dir / "updated")!r}).write_text("ok\\n")\n'
                '    sys.exit(0)\n'
                'if "install" in args:\n'
                f'    if {unrecoverable!r}:\n'
                '        sys.stderr.write("E: Unable to fetch archives\\n")\n'
                '        sys.exit(100)\n'
                f'    src = Path({str(ubuntu_sources)!r}).read_text()\n'
                '    if "security.ubuntu.com" in src:\n'
                '        sys.stderr.write("E: Temporary failure resolving security.ubuntu.com\\n")\n'
                '        sys.exit(100)\n'
                f'    if not Path({str(state_dir / "updated")!r}).exists():\n'
                '        sys.stderr.write("E: Stale package index without apt-get update\\n")\n'
                '        sys.exit(100)\n'
                f'    rg = Path({str(bin_dir / "rg")!r})\n'
                '    rg.write_text("#!/bin/sh\\nexit 0\\n")\n'
                '    rg.chmod(rg.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)\n'
                '    sys.exit(0)\n'
                'sys.exit(2)\n',
            )
            for tool in ('/usr/bin/perl', '/usr/bin/grep', '/bin/grep'):
                p = Path(tool)
                if p.exists() and not (bin_dir / p.name).exists():
                    (bin_dir / p.name).symlink_to(p)

            env = dict(os.environ, PATH=str(bin_dir), APT_ETC=str(apt_etc))
            result = subprocess.run(
                ['/bin/bash', '--noprofile', '--norc', '-e', '-o', 'pipefail', '-c', ripgrep_step()],
                cwd=root,
                env=env,
                capture_output=True,
                text=True,
            )
            calls = log_file.read_text().splitlines() if log_file.exists() else []
            return result, calls, ubuntu_sources.read_text(), (bin_dir / 'rg').exists()

    def test_preinstalled_rg_skips_apt(self):
        result, calls, _, has_rg = self.run_step(preinstalled_rg=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(calls, [])
        self.assertTrue(has_rg)

    def test_security_ubuntu_dns_failure_falls_back_to_azure_mirror(self):
        result, calls, sources_after, has_rg = self.run_step(preinstalled_rg=False)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn('security.ubuntu.com', sources_after)
        self.assertIn('http://azure.archive.ubuntu.com/ubuntu/', sources_after)
        self.assertTrue(any(' update' in c for c in calls), calls)
        self.assertTrue(has_rg)

    def test_unrecoverable_install_failure_still_fails_the_step(self):
        result, _, _, has_rg = self.run_step(preinstalled_rg=False, unrecoverable=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(has_rg)


if __name__ == '__main__':
    unittest.main()
