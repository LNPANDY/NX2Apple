"""Run the Swift CI steps with a plain bash runner so failures never depend on runner defaults."""
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

WORKFLOW = Path(__file__).resolve().parents[2] / 'workflows/tests.yml'
STEPS = (
    ('launcher', 'Release build', 'frontend', 'launcher-build.log'),
    ('launcher', 'Tests', 'frontend', 'launcher-tests.log'),
    ('engine-checks', 'iOS shell package (frontend-ios, swift test)', 'frontend-ios', 'shell-package-tests.log'),
)


def step_script(job, name):
    lines = WORKFLOW.read_text().splitlines()
    start = lines.index(f'  {job}:') + 1
    end = next((i for i in range(start, len(lines)) if re.match(r'  [a-z][a-z-]*:', lines[i])), len(lines))
    step = lines.index(f'      - name: {name}', start, end)
    body = lines.index('        run: |', step, end) + 1
    stop = next((i for i in range(body, end) if lines[i] and not lines[i].startswith('          ')), end)
    return '\n'.join(line[10:] for line in lines[body:stop])


class SwiftTestJobs(unittest.TestCase):
    def run_step(self, step, swift_status, broken_log=False):
        job, name, directory, log_name = step
        with tempfile.TemporaryDirectory(prefix='nx-swift-ci-') as folder:
            root = Path(folder)
            cwd = root / directory
            cwd.mkdir()
            if broken_log:
                (root / 'logs' / log_name).mkdir(parents=True)
            # Exercise the real workflow body without installing Swift or inheriting pipefail.
            fake_swift = f'swift() {{ echo "synthetic swift $*"; return {swift_status}; }}\n'
            env = {key: value for key, value in os.environ.items() if key not in ('SHELLOPTS', 'BASHOPTS', 'BASH_ENV')}
            env['BASH_ENV'] = '/dev/null'
            result = subprocess.run(['/bin/bash', '-e', '-c', fake_swift + step_script(job, name)],
                                    cwd=cwd, env=env, capture_output=True, text=True)
            log = root / 'logs' / log_name
            return result, log.read_text() if log.is_file() else None

    def test_a_swift_failure_fails_each_step_and_keeps_the_log(self):
        for step in STEPS:
            with self.subTest(step=step[:2]):
                result, log = self.run_step(step, 7)
                self.assertEqual(result.returncode, 7, result.stdout + result.stderr)
                self.assertIn('synthetic swift', log)

    def test_successful_swift_commands_succeed_and_keep_the_log(self):
        for step in STEPS:
            with self.subTest(step=step[:2]):
                result, log = self.run_step(step, 0)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn('synthetic swift', log)

    def test_a_log_write_failure_fails_each_step(self):
        for step in STEPS:
            with self.subTest(step=step[:2]):
                result, _ = self.run_step(step, 0, broken_log=True)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_changes_skips_mac_launcher_for_qt_and_l10n_only_prs(self):
        script = step_script('changes', 'Which areas changed')
        with tempfile.TemporaryDirectory(prefix='nx-changes-ci-') as folder:
            out_file = Path(folder) / 'out'
            for files, want_engine, want_launcher in (
                ('frontend-qt/nspb_qt/sheets.py\nfrontend/l10n/zh.json', 'false', 'false'),
                ('frontend/Sources/NXApp/LauncherView.swift', 'false', 'true'),
                ('patches/0001-x.patch', 'true', 'true'),
                ('README.md', 'false', 'false'),
            ):
                out_file.write_text('')
                fake_gh = f'gh() {{ printf "%s\\n" "{files}"; }}\n'
                env = {
                    'PATH': os.environ.get('PATH', '/usr/bin:/bin'),
                    'EVENT': 'pull_request',
                    'REPO': 'LNPANDY/NX2Apple',
                    'DEFAULT_BRANCH': 'main',
                    'HEAD_SHA': 'deadbeef',
                    'GITHUB_OUTPUT': str(out_file),
                }
                res = subprocess.run(['/bin/bash', '-e', '-c', fake_gh + script], env=env, capture_output=True, text=True)
                self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
                outputs = dict(line.split('=', 1) for line in out_file.read_text().splitlines() if '=' in line)
                self.assertEqual(outputs.get('engine'), want_engine, files)
                self.assertEqual(outputs.get('launcher'), want_launcher, files)


if __name__ == '__main__':
    unittest.main()
