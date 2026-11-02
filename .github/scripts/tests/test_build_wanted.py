import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import build_wanted as bw  # noqa: E402

ENV = {'EVENT_NAME': 'pull_request', 'PR_NUMBER': '7', 'HEAD_SHA': 'abc', 'GH_REPO': 'LNPANDY/NX2Apple', 'DEFAULT_BRANCH': 'main'}


def fake_gh(labels=(), files=(), fail=False, calls=None):
    """A fake `gh api`: the labels endpoint and the compare endpoint (paged by ?page=N, 100 per page)."""
    def run(*args):
        if calls is not None:
            calls.append(args)
        if fail:
            raise RuntimeError('gh api failed')
        url = args[1]
        if '/labels' in url:
            return '\n'.join(labels)
        page = int(url.rsplit('page=', 1)[1])
        return '\n'.join(files[(page - 1) * 100:page * 100])
    return run


def decide(env=None, **kw):
    with mock.patch.object(bw, 'gh', fake_gh(**kw)):
        return bw.decide({**ENV, **(env or {})})


class Decide(unittest.TestCase):
    def test_not_a_pull_request_always_builds(self):
        for ev in ('push', 'workflow_dispatch', ''):
            self.assertTrue(decide({'EVENT_NAME': ev}, files=['README.md'])[0], ev)

    def test_docs_only_does_not_build(self):
        self.assertFalse(decide(files=['README.md', 'frontend/Sources/NXCore/A.swift', 'frontend/Tests/T.swift', '.github/scripts/x.py'])[0])

    def test_packaging_files_build(self):
        for f in ('.github/workflows/build-mac-app.yml', 'frontend/Package.swift', 'frontend/Package.resolved', 'frontend/Resources/a.png',
                  'frontend/tools/bundle_tools.sh', 'frontend/AppIcon.icon/icon.json', '.upstream-ref', 'patches/series',
                  'tools/engine.py', 'frontend-ios/Package.swift'):
            self.assertTrue(decide(files=['README.md', f])[0], f)

    def test_a_patch_file_alone_does_not_build_but_the_series_does(self):
        self.assertFalse(decide(files=['patches/0001-x.patch'])[0])

    def test_similar_names_do_not_match(self):
        self.assertFalse(decide(files=['frontend/Package.swift.bak', 'frontend/Resourcesx/a', 'tools/engine.pyc'])[0])

    def test_label_builds(self):
        self.assertEqual(decide(labels=['ci', 'full-build'], files=['README.md'])[0], True)
        self.assertFalse(decide(labels=['ci'], files=['README.md'])[0])

    def test_compare_against_the_default_branch(self):
        calls = []
        decide(files=['README.md'], calls=calls)
        self.assertIn('compare/main...abc', calls[-1][1])

    def test_more_than_one_page(self):
        files = ['docs/%d.md' % i for i in range(150)] + ['frontend/Package.swift']
        self.assertTrue(decide(files=files)[0])

    def test_too_many_files_build(self):
        build, reason = decide(files=['docs/%d.md' % i for i in range(300)])
        self.assertTrue(build)
        self.assertIn('300', reason)

    def test_failure_fails_open(self):
        build, reason = decide(fail=True)
        self.assertTrue(build)
        self.assertIn('fail', reason)

    def test_missing_inputs_build(self):
        self.assertTrue(decide({'HEAD_SHA': ''}, files=[])[0])


class Main(unittest.TestCase):
    def test_output(self):
        with tempfile.TemporaryDirectory() as d:
            out, summary = Path(d, 'out'), Path(d, 'summary')
            env = {**ENV, 'GITHUB_OUTPUT': str(out), 'GITHUB_STEP_SUMMARY': str(summary)}
            with mock.patch.object(bw, 'gh', fake_gh(files=['README.md'])), mock.patch.dict(os.environ, env, clear=True):
                self.assertEqual(bw.main(), 0)
            self.assertEqual(out.read_text(), 'build=false\n')
            self.assertIn('App build: no', summary.read_text())


if __name__ == '__main__':
    unittest.main()
