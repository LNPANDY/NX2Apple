"""Does this run need the app build? A step of the `stack` job of build-mac-app.yml.

The app build (build-mac-app.yml, `build`) is the second macOS job of a pull request, and it adds a lot of minutes. `swift test` already
checks the launcher's code. The build adds the packaging: bundle assembly, bundled tools, the signing steps, the icon. So a pull request
builds the app only when

  - it carries the label `full-build` (read live, so "Re-run all jobs" after adding the label works), or
  - the changes against the default branch touch a file that goes into the packaging (PACKAGING below).

The changes are taken against the default branch, not against the PR's base: in a stack the tip then counts every PR below it, and a
packaging change in a lower PR (whose own run skipped the heavy jobs) is built at the tip. Everything but a pull request (push to main, a
tag, workflow_dispatch) always builds. A failed lookup builds too (fail open).

Inputs are environment variables: EVENT_NAME, PR_NUMBER, HEAD_SHA, GH_REPO, DEFAULT_BRANCH, GH_TOKEN. Writes `build=true|false` to
GITHUB_OUTPUT and the reason to GITHUB_STEP_SUMMARY.
"""
import os
import sys

from stack_tip import gh

LABEL = 'full-build'
PAGE = 100
MAX_PAGES = 3   # the compare API lists at most 300 files; a change that big builds

# What build-mac-app.yml consumes besides Swift sources: a path ending in / is a folder.
PACKAGING = (
    '.github/workflows/build-mac-app.yml',
    '.upstream-ref',
    'patches/series',
    'tools/engine.py',
    'tools/release_manifest.py',
    'tools/release_notes.py',
    'tools/requirements-release.txt',
    'frontend/Package.swift',
    'frontend/Package.resolved',
    'frontend/engine-signing.pub',
    'frontend/nxbuild.pin',
    'frontend/Resources/',
    'frontend/AppIcon.icon/',
    'frontend/bundled-python/',
    'frontend/fonts/',
    'frontend/tools/',
    'frontend-ios/Package.swift',
)


def is_packaging(path):
    return any(path == p or (p.endswith('/') and path.startswith(p)) for p in PACKAGING)


def changed_files(repo, default_branch, head_sha):
    files = []
    for page in range(1, MAX_PAGES + 1):
        out = gh('api', f'repos/{repo}/compare/{default_branch}...{head_sha}?per_page={PAGE}&page={page}', '--jq', '.files[].filename')
        got = [line for line in out.splitlines() if line]
        files += got
        if len(got) < PAGE:
            return files, False
    return files, True


def decide(env):
    """(build, reason)."""
    if env.get('EVENT_NAME') != 'pull_request':
        return True, 'not a pull request: it always builds'
    repo, number = env.get('GH_REPO', ''), env.get('PR_NUMBER', '')
    sha, default_branch = env.get('HEAD_SHA', ''), env.get('DEFAULT_BRANCH') or 'main'
    if not (repo and number and sha):
        return True, 'missing inputs: it builds'
    try:
        labels = gh('api', f'repos/{repo}/issues/{number}/labels', '--paginate', '--jq', '.[].name').split()
        if LABEL in labels:
            return True, f'label {LABEL}'
        files, truncated = changed_files(repo, default_branch, sha)
    except Exception as e:   # fail open
        print(f'::warning::Lookup failed, so the app builds: {e}')
        return True, 'lookup failed: it builds'
    if truncated:
        return True, 'more than 300 files changed: it builds'
    hit = [f for f in files if is_packaging(f)]
    if hit:
        return True, 'packaging files changed: ' + ', '.join(hit[:5]) + (' and more' if len(hit) > 5 else '')
    return False, f'no packaging file changed (label {LABEL} or workflow_dispatch builds anyway)'


def main():
    build, reason = decide(os.environ)
    line = f'build={"true" if build else "false"}'
    print(line, '-', reason)
    if path := os.environ.get('GITHUB_OUTPUT'):
        with open(path, 'a') as f:
            f.write(line + '\n')
    if path := os.environ.get('GITHUB_STEP_SUMMARY'):
        with open(path, 'a') as f:
            f.write(f'App build: {"yes" if build else "no"}, {reason}\n')
    return 0


if __name__ == '__main__':
    sys.exit(main())
