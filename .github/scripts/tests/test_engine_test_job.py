"""Exercise the workflow's real test loop with synthetic passing and failing files."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

WORKFLOW = Path(__file__).resolve().parents[2] / 'workflows/tests.yml'


def test_step():
    lines = WORKFLOW.read_text().splitlines()
    start = next(i for i, line in enumerate(lines) if line == '      - name: Run the test files')
    start = next(i for i in range(start, len(lines)) if lines[i] == '        run: |') + 1
    end = next(i for i in range(start, len(lines)) if lines[i] and not lines[i].startswith('          '))
    return '\n'.join(line[10:] for line in lines[start:end])


class EngineTestJob(unittest.TestCase):
    def run_job(self, first_test, broken_log=False):
        with tempfile.TemporaryDirectory(prefix='nx-tool-tests-') as tmp:
            root = Path(tmp)
            bin_dir = root / 'bin'
            bin_dir.mkdir()
            (bin_dir / 'python').symlink_to(sys.executable)
            for directory, body in (
                ('dm/tools/tests', first_test),
                ('dm/ios/tests', 'self.assertTrue(True)'),
                ('dm/gfx/tests', 'self.assertTrue(True)'),
            ):
                folder = root / directory
                folder.mkdir(parents=True)
                # Distinct names match the real loop's individual log files.
                name = 'test_' + directory.split('/')[1] + '.py'
                (folder / name).write_text('import unittest\nclass Fixture(unittest.TestCase):\n def test_result(self): ' + body + '\n')
            if broken_log:
                (root / 'logs/test_tools.py.log').mkdir(parents=True)
            # The job-level working-directory defaults leave the runner using bash -e.
            # Failure propagation must remain correct with that actual CI invocation.
            result = subprocess.run(['/bin/bash', '-e', '-c', test_step()], cwd=root,
                                    env=dict(os.environ, PATH=str(bin_dir) + os.pathsep + os.environ['PATH']),
                                    capture_output=True, text=True)
            logs = {p.name: p.read_text() for p in (root / 'logs').iterdir() if p.is_file()}
            return result, logs

    def test_a_failed_file_fails_the_job_and_later_files_still_run(self):
        result, logs = self.run_job('self.fail("intentional regression fixture")')
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('intentional regression fixture', result.stdout)
        self.assertIn('::error::dm/tools/tests/test_tools.py failed', result.stdout)
        self.assertIn('OK', logs['test_gfx.py.log'])

    def test_all_passing_files_succeed_and_keep_their_logs(self):
        result, logs = self.run_job('self.assertTrue(True)')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(set(logs), {'test_tools.py.log', 'test_ios.py.log', 'test_gfx.py.log'})
        self.assertTrue(all('OK' in text for text in logs.values()))

    def test_a_test_error_also_fails_the_job(self):
        result, _ = self.run_job('raise RuntimeError("intentional test error")')
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('intentional test error', result.stdout)

    def test_a_log_write_failure_is_not_reported_as_success(self):
        result, logs = self.run_job('self.assertTrue(True)', broken_log=True)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('OK', logs['test_gfx.py.log'])


if __name__ == '__main__':
    unittest.main()
