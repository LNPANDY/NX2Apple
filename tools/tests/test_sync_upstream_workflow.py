"""The experimental release uses the tested main commit independently of an upstream bump."""

import os
from pathlib import Path
import re
import subprocess
import textwrap
import unittest


WORKFLOW = Path(__file__).resolve().parents[2] / '.github/workflows/sync-upstream.yml'


class ExperimentalRelease(unittest.TestCase):
    def setUp(self):
        self.job = WORKFLOW.read_text().split('\n  publish-experimental:\n', 1)[1]

    def test_a_blocked_bump_cannot_skip_publication_from_main(self):
        self.assertNotRegex(self.job, r'(?m)^    needs:')
        self.assertIn("    if: github.ref == 'refs/heads/main'\n", self.job)

    def test_publication_requires_success_for_the_checked_out_commit(self):
        step = self.job.split('      - name: "Main\'s tests must be green"\n', 1)[1]
        script = re.search(r'        run: \|\n((?: {10}[^\n]*\n)+)', step)[1]
        # Each sleep advances the mock to the next response, without waiting.
        shell = r"""runs=("$@")
poll=0
gh() { printf '%s\n' "${runs[poll]}"; }
sleep() { if (( poll + 1 < ${#runs[@]} )); then poll=$((poll + 1)); fi; }
""" + textwrap.dedent(script)
        sha = 'a' * 40
        pending, success = f'{sha}\t', f'{sha}\tsuccess'
        other = f'{"b" * 40}\tsuccess'
        for runs, expected in [([success], 0), ([pending, success], 0),
                               ([f'{sha}\tfailure'], 1), ([pending], 1),
                               ([other], 1), ([pending, other, success], 1), ([''], 1)]:
            with self.subTest(runs=runs):
                result = subprocess.run(
                    ['bash', '-e', '-c', shell, 'workflow-test', *runs],
                    env=dict(os.environ, GITHUB_SHA=sha, GITHUB_REPOSITORY='owner/repo'),
                    capture_output=True, text=True, timeout=10,
                )
                self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
