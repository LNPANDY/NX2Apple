import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import stack_tip as st  # noqa: E402

PR = {'EVENT_NAME': 'pull_request', 'PR_NUMBER': '482', 'HEAD_REF': 'v0lumehi/b', 'HEAD_REPO': 'LNPANDY/NX2Apple',
      'BASE_REPO': 'LNPANDY/NX2Apple', 'GH_REPO': 'LNPANDY/NX2Apple'}


def child(number, head, cross=False):
    return {'number': number, 'headRefName': head, 'isCrossRepository': cross}


def fake_gh(table, calls=None):
    """A fake `gh pr list --base X --state open`: answers table[X] (a list, a raw string, or an Exception for a failed gh)."""
    def run(*args):
        if calls is not None:
            calls.append(args)
        v = table.get(args[args.index('--base') + 1], [])
        if isinstance(v, Exception):
            raise v
        return v if isinstance(v, str) else json.dumps(v)
    return run


def decide(env, table, calls=None):
    with mock.patch.object(st, 'gh', fake_gh(table, calls)):
        return st.decide({**PR, **env})


class Decide(unittest.TestCase):
    def test_no_children_is_tip(self):
        self.assertEqual(decide({}, {}), (True, ''))

    def test_one_child_is_not_tip(self):
        tip, msg = decide({}, {'v0lumehi/b': [child(485, 'v0lumehi/c')]})
        self.assertFalse(tip)
        self.assertEqual(msg, 'Not the tip of a stack: heavy checks run on #485')

    def test_names_the_tip_through_the_stack(self):
        table = {'v0lumehi/b': [child(485, 'v0lumehi/c')], 'v0lumehi/c': [child(490, 'v0lumehi/d')]}
        self.assertEqual(decide({}, table)[1], 'Not the tip of a stack: heavy checks run on #490')

    def test_two_children_not_tip_both_children_are_tips(self):
        table = {'v0lumehi/b': [child(485, 'x'), child(486, 'y')]}
        tip, msg = decide({}, table)
        self.assertFalse(tip)
        self.assertEqual(msg, 'Not the tip of a stack: heavy checks run on #485, #486')
        self.assertEqual(decide({'PR_NUMBER': '485', 'HEAD_REF': 'x'}, table), (True, ''))
        self.assertEqual(decide({'PR_NUMBER': '486', 'HEAD_REF': 'y'}, table), (True, ''))

    def test_draft_child_still_counts(self):
        # gh lists drafts for --state open and the script does not filter on isDraft
        table = {'v0lumehi/b': [{'number': 485, 'headRefName': 'c', 'isDraft': True, 'isCrossRepository': False}]}
        self.assertFalse(decide({}, table)[0])

    def test_closed_or_merged_child_does_not_count(self):
        calls = []
        # a closed child is not in the answer of `--state open`
        self.assertEqual(decide({}, {}, calls), (True, ''))
        args = calls[0]
        self.assertEqual(args[args.index('--state') + 1], 'open')

    def test_fork_is_tip_without_asking(self):
        calls = []
        self.assertEqual(decide({'HEAD_REPO': 'someone/NX2Apple'}, {'v0lumehi/b': [child(485, 'c')]}, calls), (True, ''))
        self.assertEqual(calls, [])

    def test_api_failure_fails_open(self):
        for bad in (RuntimeError('gh pr list failed: boom'), 'not json', '{"a": 1}'):
            self.assertEqual(decide({}, {'v0lumehi/b': bad}), (True, ''), bad)

    def test_walk_failure_still_not_tip(self):
        table = {'v0lumehi/b': [child(485, 'c')], 'c': RuntimeError('boom')}
        tip, msg = decide({}, table)
        self.assertFalse(tip)
        self.assertIn('#485', msg)

    def test_cross_repository_child_is_not_followed(self):
        calls = []
        table = {'v0lumehi/b': [child(485, 'c', cross=True)], 'c': [child(999, 'z')]}
        self.assertEqual(decide({}, table, calls)[1], 'Not the tip of a stack: heavy checks run on #485')
        self.assertEqual(len(calls), 1)

    def test_loop_of_branches_ends(self):
        table = {'v0lumehi/b': [child(485, 'c')], 'c': [child(482, 'v0lumehi/b')]}
        self.assertFalse(decide({}, table)[0])

    def test_other_events_are_always_tip(self):
        for ev in ('push', 'workflow_dispatch', 'workflow_call', 'schedule', ''):
            calls = []
            self.assertEqual(decide({'EVENT_NAME': ev}, {'v0lumehi/b': [child(485, 'c')]}, calls), (True, ''), ev)
            self.assertEqual(calls, [])

    def test_missing_inputs_is_tip(self):
        self.assertEqual(decide({'HEAD_REF': ''}, {}), (True, ''))


class Main(unittest.TestCase):
    def run_main(self, table):
        with tempfile.TemporaryDirectory() as d:
            out, summary = Path(d, 'out'), Path(d, 'summary')
            env = {**PR, 'GITHUB_OUTPUT': str(out), 'GITHUB_STEP_SUMMARY': str(summary)}
            with mock.patch.object(st, 'gh', fake_gh(table)), mock.patch.dict(os.environ, env, clear=True):
                self.assertEqual(st.main(), 0)
            return out.read_text(), summary.read_text()

    def test_not_tip_output_and_summary(self):
        out, summary = self.run_main({'v0lumehi/b': [child(485, 'c')]})
        self.assertEqual(out, 'is_tip=false\n')
        self.assertIn('Not the tip of a stack: heavy checks run on #485', summary)

    def test_tip_output(self):
        out, _ = self.run_main({})
        self.assertEqual(out, 'is_tip=true\n')


if __name__ == '__main__':
    unittest.main()
