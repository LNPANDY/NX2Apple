"""A pull request that was not the tip of its stack becomes the tip when its child is closed, merged or retargeted. Nothing re-triggers its
checks: the heavy jobs stay skipped. This script, run by stack-parent-rerun.yml when a child changes, finds the parent and re-runs the `stack`
job of its latest runs (tests and the app build) for its head commit. `gh run rerun --job` re-runs that job and every job that needs it, so
the heavy jobs start, and the `stack` job asks GitHub again, live, whether the parent is the tip now.

  parent   the open PR (same repository) whose head branch is the child's old base: for `closed` the base the child had, for `edited` the base
           it had before (`changes.base.ref.from`). Nothing to do when there is none (the parent was merged, or the child had no parent).
  only if  the parent has no other open child now (it is the tip), and a run of the workflow is finished and has a `Stack` job
  nothing  runs in progress are left alone, and nothing is re-run twice

The event data arrives as environment variables and is only ever an argument of `gh`, never part of a shell command. No code of the pull
request is checked out or run. Inputs: ACTION, BASE_REF, OLD_BASE_REF, PR_NUMBER, GH_REPO, GH_TOKEN. DRY_RUN=1 only prints.
"""
import json
import os
import sys

from stack_tip import gh, open_children

WORKFLOWS = ('tests', 'Build the NX2Apple app (macOS)')


def parent_branch(env):
    """The head branch of the child's former parent, or ''."""
    if env.get('ACTION') == 'closed':
        return env.get('BASE_REF', '')
    if env.get('ACTION') == 'edited':
        return env.get('OLD_BASE_REF', '')   # empty unless the base changed
    return ''


def find_parent(repo, branch):
    out = json.loads(gh('pr', 'list', '--repo', repo, '--state', 'open', '--head', branch, '--limit', '10',
                        '--json', 'number,headRefName,headRefOid,isCrossRepository'))
    for pr in out:
        if pr.get('headRefName') == branch and not pr.get('isCrossRepository'):
            return pr
    return None


def latest_runs(repo, sha):
    """The newest pull_request run of each workflow in WORKFLOWS for this commit."""
    runs = json.loads(gh('run', 'list', '--repo', repo, '--commit', sha, '--event', 'pull_request', '--limit', '50',
                         '--json', 'databaseId,workflowName,status'))
    latest = {}
    for r in runs:
        if r.get('workflowName') in WORKFLOWS and r['databaseId'] > latest.get(r['workflowName'], {'databaseId': 0})['databaseId']:
            latest[r['workflowName']] = r
    return list(latest.values())


def stack_job(repo, run_id):
    view = json.loads(gh('run', 'view', str(run_id), '--repo', repo, '--json', 'status,jobs'))
    if view.get('status') != 'completed':
        return None
    for job in view.get('jobs', []):
        if job.get('name', '').startswith('Stack'):
            return job.get('databaseId')
    return None


def main(env=os.environ):
    repo = env.get('GH_REPO', '')
    branch = parent_branch(env)
    if not repo or not branch:
        print('Not a close or a base change of a child: nothing to do.')
        return 0
    try:
        parent = find_parent(repo, branch)
        if not parent:
            print(f'No open pull request has the head branch {branch}: nothing to do.')
            return 0
        if open_children(repo, branch):
            print(f'#{parent["number"]} still has an open child: it is not the tip.')
            return 0
        for run in latest_runs(repo, parent['headRefOid']):
            job_id = stack_job(repo, run['databaseId'])
            if not job_id:
                print(f'{run["workflowName"]} (run {run["databaseId"]}) is not finished or has no Stack job: left alone.')
                continue
            print(f'#{parent["number"]} is the tip now: re-running the Stack job of {run["workflowName"]} (run {run["databaseId"]}).')
            if env.get('DRY_RUN') != '1':
                gh('run', 'rerun', str(run['databaseId']), '--repo', repo, '--job', str(job_id))
    except Exception as e:   # the worst case is a skipped check that stays skipped: re-run it by hand
        print(f'::warning::Could not re-run the parent: {e}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
