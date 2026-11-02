import io
import json
import sys
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import stack_rerun as sr  # noqa: E402
import stack_tip  # noqa: E402

PARENT = {'number': 482, 'headRefName': 'v0lumehi/b', 'headRefOid': 'sha1', 'isCrossRepository': False}
RUNS = [{'databaseId': 10, 'workflowName': 'tests', 'status': 'completed'},
        {'databaseId': 9, 'workflowName': 'tests', 'status': 'completed'},
        {'databaseId': 11, 'workflowName': 'Build the NX2Apple app (macOS)', 'status': 'completed'},
        {'databaseId': 12, 'workflowName': 'PR labeler', 'status': 'completed'}]
VIEW = {'status': 'completed', 'jobs': [{'name': 'Changed areas', 'databaseId': 1}, {'name': 'Stack (is this the tip?)', 'databaseId': 77}]}


class Fake:
    def __init__(self, parents=(PARENT,), children=(), runs=RUNS, view=VIEW):
        self.calls, self.parents, self.children, self.runs, self.view = [], list(parents), list(children), runs, view

    def __call__(self, *args):
        self.calls.append(args)
        if args[:2] == ('pr', 'list'):
            if '--head' in args:
                return json.dumps(self.parents)
            return json.dumps(self.children)
        if args[:2] == ('run', 'list'):
            return json.dumps(self.runs)
        if args[:2] == ('run', 'view'):
            return json.dumps(self.view)
        return ''

    def reruns(self):
        return [c for c in self.calls if c[:2] == ('run', 'rerun')]


def run(env, **kw):
    fake = Fake(**kw)
    out = io.StringIO()
    with mock.patch.object(sr, 'gh', fake), mock.patch.object(stack_tip, 'gh', fake), redirect_stdout(out):
        code = sr.main({'GH_REPO': 'LNPANDY/NX2Apple', **env})
    return code, fake, out.getvalue()


class Rerun(unittest.TestCase):
    def test_closed_child_reruns_the_stack_job_of_each_workflow(self):
        code, fake, _ = run({'ACTION': 'closed', 'BASE_REF': 'v0lumehi/b'})
        self.assertEqual(code, 0)
        self.assertEqual(fake.reruns(), [('run', 'rerun', '10', '--repo', 'LNPANDY/NX2Apple', '--job', '77'),
                                         ('run', 'rerun', '11', '--repo', 'LNPANDY/NX2Apple', '--job', '77')])
        self.assertIn('headRefOid', ' '.join(next(c for c in fake.calls if '--head' in c)))

    def test_retargeted_child_uses_the_old_base(self):
        _, fake, _ = run({'ACTION': 'edited', 'BASE_REF': 'main', 'OLD_BASE_REF': 'v0lumehi/b'})
        self.assertEqual(len(fake.reruns()), 2)
        self.assertEqual(fake.calls[0][fake.calls[0].index('--head') + 1], 'v0lumehi/b')

    def test_edit_without_base_change_does_nothing(self):
        _, fake, _ = run({'ACTION': 'edited', 'BASE_REF': 'v0lumehi/b', 'OLD_BASE_REF': ''})
        self.assertEqual(fake.calls, [])

    def test_other_actions_do_nothing(self):
        _, fake, _ = run({'ACTION': 'synchronize', 'BASE_REF': 'v0lumehi/b'})
        self.assertEqual(fake.calls, [])

    def test_opened_child_reruns_the_stack_job_of_a_finished_parent(self):
        code, fake, out = run({'ACTION': 'opened', 'BASE_REF': 'v0lumehi/b'})
        self.assertEqual(code, 0)
        self.assertEqual(fake.reruns(), [('run', 'rerun', '10', '--repo', 'LNPANDY/NX2Apple', '--job', '77'),
                                         ('run', 'rerun', '11', '--repo', 'LNPANDY/NX2Apple', '--job', '77')])
        self.assertIn('open child now', out)

    def test_opened_child_does_not_ask_for_other_children(self):
        _, fake, _ = run({'ACTION': 'opened', 'BASE_REF': 'v0lumehi/b'}, children=[{'number': 500, 'headRefName': 'x', 'isCrossRepository': False}])
        self.assertEqual(len(fake.reruns()), 2)

    def test_opened_child_with_a_running_parent_run_changes_nothing(self):
        runs = [{'databaseId': 10, 'workflowName': 'tests', 'status': 'in_progress'},
                {'databaseId': 11, 'workflowName': 'Build the NX2Apple app (macOS)', 'status': 'completed'}]
        code, fake, out = run({'ACTION': 'opened', 'BASE_REF': 'v0lumehi/b'}, runs=runs)
        self.assertEqual(code, 0)
        self.assertEqual(fake.reruns(), [])
        self.assertIn('started before this child existed', out)
        self.assertIn('run 10', out)
        self.assertNotIn('run 11', out)

    def test_opened_child_with_a_queued_parent_run_changes_nothing(self):
        runs = [{'databaseId': 10, 'workflowName': 'tests', 'status': 'queued'}]
        _, fake, out = run({'ACTION': 'opened', 'BASE_REF': 'v0lumehi/b'}, runs=runs)
        self.assertEqual(fake.reruns(), [])
        self.assertIn('run 10', out)
        self.assertFalse([c for c in fake.calls if c[0] == 'run' and c[1] == 'cancel'])

    def test_opened_child_on_main_has_no_parent(self):
        _, fake, out = run({'ACTION': 'opened', 'BASE_REF': 'main'}, parents=[])
        self.assertEqual(fake.reruns(), [])
        self.assertIn('nothing to do', out)

    def test_reopened_child_reruns_like_an_opened_one(self):
        _, fake, _ = run({'ACTION': 'reopened', 'BASE_REF': 'v0lumehi/b'})
        self.assertEqual(len(fake.reruns()), 2)

    def test_opened_child_with_a_fork_parent_is_ignored(self):
        _, fake, _ = run({'ACTION': 'opened', 'BASE_REF': 'v0lumehi/b'}, parents=[{**PARENT, 'isCrossRepository': True}])
        self.assertEqual(fake.reruns(), [])

    def test_opened_dry_run_does_not_rerun(self):
        _, fake, out = run({'ACTION': 'opened', 'BASE_REF': 'v0lumehi/b', 'DRY_RUN': '1'})
        self.assertEqual(fake.reruns(), [])
        self.assertIn('re-running', out)

    def test_no_open_parent(self):
        _, fake, out = run({'ACTION': 'closed', 'BASE_REF': 'main'}, parents=[])
        self.assertEqual(fake.reruns(), [])
        self.assertIn('nothing to do', out)

    def test_fork_parent_is_ignored(self):
        _, fake, _ = run({'ACTION': 'closed', 'BASE_REF': 'v0lumehi/b'}, parents=[{**PARENT, 'isCrossRepository': True}])
        self.assertEqual(fake.reruns(), [])

    def test_parent_with_another_open_child_is_not_the_tip(self):
        _, fake, out = run({'ACTION': 'closed', 'BASE_REF': 'v0lumehi/b'}, children=[{'number': 500, 'headRefName': 'x', 'isCrossRepository': False}])
        self.assertEqual(fake.reruns(), [])
        self.assertIn('not the tip', out)

    def test_run_in_progress_is_left_alone(self):
        _, fake, _ = run({'ACTION': 'closed', 'BASE_REF': 'v0lumehi/b'}, view={**VIEW, 'status': 'in_progress'})
        self.assertEqual(fake.reruns(), [])

    def test_run_without_stack_job_is_left_alone(self):
        _, fake, _ = run({'ACTION': 'closed', 'BASE_REF': 'v0lumehi/b'}, view={'status': 'completed', 'jobs': [{'name': 'x', 'databaseId': 1}]})
        self.assertEqual(fake.reruns(), [])

    def test_dry_run_does_not_rerun(self):
        _, fake, out = run({'ACTION': 'closed', 'BASE_REF': 'v0lumehi/b', 'DRY_RUN': '1'})
        self.assertEqual(fake.reruns(), [])
        self.assertIn('re-running', out)

    def test_gh_failure_is_a_warning_not_a_failure(self):
        def boom(*a):
            raise RuntimeError('boom')
        out = io.StringIO()
        with mock.patch.object(sr, 'gh', boom), redirect_stdout(out):
            self.assertEqual(sr.main({'GH_REPO': 'r', 'ACTION': 'closed', 'BASE_REF': 'b'}), 0)
        self.assertIn('::warning::', out.getvalue())


if __name__ == '__main__':
    unittest.main()
