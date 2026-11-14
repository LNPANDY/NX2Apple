#!/usr/bin/env python3
"""What `.githooks/pre-push` and `.githooks/pre-commit` run (python3 and git only).

pre-push runs the checks that match what the push changes. Each is the command CI or AGENTS.md ("Checks") names, run from the
repository root. A push that touches only docs runs none, and a push that deletes a ref is skipped.
pre-commit runs only the patch queue check, and only when patches/ or .upstream-ref is staged. It takes seconds.
That check reads the working tree, so both hooks stop when patches/ or .upstream-ref there is not what is being committed or pushed.
Install the hooks with `git config core.hooksPath .githooks`: tools/engine.py does it for you.
"""
import os
import shutil
import subprocess
import sys
from collections import namedtuple
from pathlib import Path

import patches as P

ROOT = Path(__file__).resolve().parent.parent
ZERO = '0' * 40
QUEUE_PATHS = ('patches', '.upstream-ref')
SYNC = 'python3 tools/engine.py -q sync'   # these tests read engine/ (AGENTS.md, "Checks"); a no-op when it is current

Check = namedtuple('Check', 'name prefixes command cwd sync')

CHECKS = (
    Check('patch queue', ('patches/', '.upstream-ref'), 'python3 tools/engine.py check', '.', False),
    Check('Qt front end', ('frontend-qt/', 'frontend/l10n/', 'frontend/Sources/', 'frontend/Tests/l10n-key-rules.json'), 'python3 -m unittest discover -s frontend-qt/tests', '.', True),
    Check('tools', ('tools/',), 'python3 -m unittest discover tools/tests', '.', True),
    Check('triage scripts', ('.github/scripts/',), 'python3 -m unittest discover -s .github/scripts/tests', '.', True),
    Check('Mac launcher (slow)', ('frontend/',), 'swift build && swift test', 'frontend', True),
    Check('iOS shell (slow)', ('frontend-ios/',), 'swift build && swift test', 'frontend-ios', True),
)


def checks_for(paths):
    """The checks a change to these paths needs, cheapest first."""
    return [c for c in CHECKS if any(p.startswith(c.prefixes) for p in paths if not (c.cwd == 'frontend' and p.startswith('frontend/l10n/')))]


def git(*a, env=None):
    """git in the repository at ROOT. It never takes GIT_DIR and the like from the environment, unless the caller passes env."""
    r = subprocess.run(['git', *a], cwd=ROOT, capture_output=True, text=True, env=env or P.clean_env())
    return r.stdout.strip() if r.returncode == 0 else None


def sh(command, cwd):
    """A check runs in a clean environment: the repository that runs the hook (GIT_DIR in a worktree) is not the one the tests use."""
    return subprocess.run(command, shell=True, cwd=cwd, env=P.clean_env()).returncode


def has_commit(sha):
    return git('cat-file', '-e', sha + '^{commit}') is not None


def pushed_paths(lines):
    """The files that the pushed refs change, from the hook's stdin lines `<local ref> <local sha> <remote ref> <remote sha>`.
    None when a base cannot be found: then everything counts as changed."""
    paths = set()
    for line in lines:
        f = line.split()
        if len(f) != 4: continue
        _, local, _, remote = f
        if local == ZERO: continue   # a deleted ref pushes no code
        base = remote if remote != ZERO and has_commit(remote) else git('merge-base', local, 'origin/main')
        out = git('diff', '--name-only', base, local) if base else None
        if out is None: return None
        paths.update(out.splitlines())
    return paths


def unchecked(rev=None):
    """The patch queue files in the working tree that differ from `rev` (None: from the index), untracked ones included.
    `tools/engine.py check` reads the working tree, so with any of these it would pass for something that is not being committed."""
    env = os.environ.copy() if rev is None else None   # keeps GIT_INDEX_FILE, the index of this commit
    changed = git('diff', '--name-only', *([rev] if rev else []), '--', *QUEUE_PATHS, env=env) or ''
    new = git('ls-files', '--others', '--exclude-standard', '--', *QUEUE_PATHS, env=env) or ''
    return sorted(set(changed.splitlines()) | set(new.splitlines()))


def refuse_unchecked(hook, files, what):
    stop = 'push' if hook == 'pre-push' else 'commit'
    print(f'{hook}: the patch queue check reads the working tree, and these files are not what is being {what}: ' + ', '.join(files) +
          f'\n{hook}: stage or commit them, or restore them, then {stop} again.', file=sys.stderr)
    return 1


def pre_push(lines):
    if any(len(f) == 4 and f[2] == 'refs/heads/main' for f in map(str.split, lines)):
        print('pre-push: pushing to main is not allowed. Open a pull request.', file=sys.stderr)
        return 1
    paths = pushed_paths(lines)
    if paths is None: print('pre-push: no base to compare with (is origin/main fetched?), so every check runs')
    todo = CHECKS if paths is None else checks_for(paths)
    if CHECKS[0] in todo:
        for local in {f[1] for f in map(str.split, lines) if len(f) == 4 and f[1] != ZERO}:
            files = unchecked(local)
            if files: return refuse_unchecked('pre-push', files, 'pushed')
    return run('pre-push', todo)


def pre_commit():
    staged = (git('diff', '--cached', '--name-only', env=os.environ.copy()) or '').splitlines()   # keeps GIT_INDEX_FILE, the index of this commit
    todo = [c for c in checks_for(staged) if c is CHECKS[0]]
    if todo:
        files = unchecked()
        if files: return refuse_unchecked('pre-commit', files, 'committed')
    return run('pre-commit', todo)


def run(hook, todo):
    stop = 'push' if hook == 'pre-push' else 'commit'
    emergency = f'{hook}: fix the failure. A maintainer may use git {stop} --no-verify in an emergency. An agent never does.'
    if not todo:
        print(f'{hook}: nothing to check for these files')
        return 0
    print(f'{hook}: running ' + ', '.join(c.name for c in todo), flush=True)
    if any(c.sync for c in todo):
        print(f'{hook}: {SYNC}', flush=True)
        if sh(SYNC, ROOT):
            print(f'{hook}: engine/ could not be synced, {stop} stopped. Reproduce: {SYNC}\n{emergency}', file=sys.stderr)
            return 1
    for c in todo:
        if c.cwd == 'frontend' and not shutil.which('swift'):
            print(f'{hook}: {c.name} skipped, swift is not installed. CI runs it.')
            continue
        print(f'{hook}: {c.name}: {c.command}', flush=True)
        if sh(c.command, ROOT / c.cwd):
            repro = c.command if c.cwd == '.' else f'cd {c.cwd} && {c.command}'
            print(f'{hook}: the {c.name} check failed, {stop} stopped. Reproduce: {repro}\n{emergency}', file=sys.stderr)
            return 1
    print(f'{hook}: all checks passed')
    return 0


if __name__ == '__main__':
    if sys.argv[1:] == ['pre-push']: sys.exit(pre_push(sys.stdin.read().splitlines()))
    if sys.argv[1:] == ['pre-commit']: sys.exit(pre_commit())
    sys.exit('usage: githooks.py pre-push|pre-commit')
