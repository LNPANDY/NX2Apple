"""Is this pull request the tip of a stack? The first job of tests.yml and build-mac-app.yml runs this, and the heavy macOS jobs wait for it.

The maintainers work in stacks: one PR per step, each PR based on the head branch of the one below. The heavy checks (swift test, the app
build, the engine jobs) run on the tip only. A PR is the tip when no open PR has its head branch as base. That is true for GitHub stacks
and for plain stacked branches alike. The PRs below the tip still report every required check: their heavy jobs are skipped by a job-level
`if` (a skipped job counts as passed, a workflow that never starts would block the merge).

  not a pull request   push to main, a tag, workflow_dispatch, workflow_call: always the tip
  pull request         a tip when it has no open child. A draft child counts, a closed or merged one does not
  fork                 a PR from a fork has no children: the tip
  gh fails             fail open, the tip, so CI runs rather than being skipped by a broken lookup

Inputs are environment variables (no event data goes through the shell): EVENT_NAME, PR_NUMBER, HEAD_REF, HEAD_REPO, BASE_REPO,
GH_REPO (the repository to ask), GH_TOKEN. Writes `is_tip=true|false` to GITHUB_OUTPUT and a line to GITHUB_STEP_SUMMARY and the log.
"""
import json
import os
import subprocess
import sys

MAX_DEPTH = 40   # longest stack followed to name its tip; a loop of branches cannot run away


def gh(*args):
    r = subprocess.run(['gh', *args], capture_output=True, text=True, timeout=60)
    if r.returncode:
        raise RuntimeError(f'gh {args[0]} failed: {r.stderr.strip()[:300]}')
    return r.stdout


def open_children(repo, head_ref):
    """The open PRs whose base is head_ref: [{'number', 'headRefName', 'isCrossRepository'}]. Drafts are open, so they count."""
    out = gh('pr', 'list', '--repo', repo, '--state', 'open', '--base', head_ref, '--limit', '100',
             '--json', 'number,headRefName,isCrossRepository')
    data = json.loads(out)
    if not isinstance(data, list):
        raise RuntimeError('unexpected answer from gh pr list')
    return data


def tips_below(repo, children, seen):
    """The numbers of the tips above `children`, following same-repository children up the stack."""
    tips = []
    queue = [(c, 1) for c in children]
    while queue:
        pr, depth = queue.pop(0)
        number = pr['number']
        if number in seen:
            continue
        seen.add(number)
        nxt = []
        if depth < MAX_DEPTH and not pr.get('isCrossRepository'):
            nxt = open_children(repo, pr['headRefName'])
        if nxt:
            queue.extend((c, depth + 1) for c in nxt)
        else:
            tips.append(number)
    return sorted(tips)


def decide(env):
    """(is_tip, message). message is empty for a tip."""
    if env.get('EVENT_NAME') not in ('pull_request', 'pull_request_target'):
        return True, ''
    head_ref = env.get('HEAD_REF', '')
    repo = env.get('GH_REPO') or env.get('BASE_REPO', '')
    if not head_ref or not repo:
        return True, ''
    if env.get('HEAD_REPO') and env.get('BASE_REPO') and env['HEAD_REPO'].lower() != env['BASE_REPO'].lower():
        return True, ''   # a fork's branch is not a base anybody can target
    try:
        children = open_children(repo, head_ref)
        if not children:
            return True, ''
        try:
            tips = tips_below(repo, children, {int(env.get('PR_NUMBER') or 0)})
        except Exception:
            tips = sorted(c['number'] for c in children)   # the walk failed: name the direct children
    except Exception as e:   # fail open: a broken lookup must never skip the checks
        print(f'::warning::Stack lookup failed, so this PR counts as the tip: {e}')
        return True, ''
    names = ', '.join(f'#{n}' for n in tips)
    return False, f'Not the tip of a stack: heavy checks run on {names}'


def main():
    is_tip, message = decide(os.environ)
    line = f'is_tip={"true" if is_tip else "false"}'
    print(line)
    if path := os.environ.get('GITHUB_OUTPUT'):
        with open(path, 'a') as f:
            f.write(line + '\n')
    if message:
        print(f'::notice title=Stack::{message}')
    if path := os.environ.get('GITHUB_STEP_SUMMARY'):
        with open(path, 'a') as f:
            f.write((message or 'This is the tip of its stack (or not a pull request): the heavy checks run here.') + '\n')
    return 0


if __name__ == '__main__':
    sys.exit(main())
