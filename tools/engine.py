#!/usr/bin/env python3
"""The engine in engine/: seedds/nxnative at the pin plus the patch queue, fetched and patched where it is needed
(LNPANDY/NX2Apple#214).

The repository keeps the pin (.upstream-ref) and the patches (patches/series, patches/*.patch). engine/ is a real git
repository, ignored by the outer one: upstream's commit at the pin (a shallow fetch of that one commit), then one commit per
patch (`git am -3`), then one commit with the generated files (the indexes of tools/patches.py's GENERATED and
dm/fork_patches.txt). A stamp in engine/.git records the pin and the series it was built from, so `sync` is a no-op while
neither changed.

Subcommands (Python 3.9+, stdlib and git):
  sync [--seed DIR] [--force]  make engine/ match the pin and the series. A no-op when the stamp matches. Refuses to throw
                               away commits or changes made in engine/ (export them first, or --force keeps them on a branch)
  stale                        exit 0 when engine/ matches the pin and the series, 1 when a sync is needed (prints why)
  hook                         for an agent's session start (.claude/settings.json): sync when stale, print one line, always exit 0
  export [REV]                 turn commits made in engine/ (default: everything after the last sync) into patches with the
                               Upstream-Status / Reason / Issue header, and add them to patches/series
  status                       the patches (Upstream-Status, Reason, age) and the state of engine/
  check [--tree]               headers valid, no patch touches the shader chain or the generated files, the series applies
                               cleanly to the pin with no empty patch. --tree also compares the committed vendored tree with
                               pin + series, as long as the repository still commits it (step 1 of #214)
  bump --to SHA|main [--dry]   move the pin: re-apply the series on the new commit, drop the patches upstream has, write
                               patches/ and .upstream-ref (the committed tree is tools/patches.py bump's job while it exists)
  refresh WORKTREE --to SHA    after a conflicting bump was resolved by hand in WORKTREE: its commits become the series

The upstream URL is https://github.com/seedds/nxnative.git, or $NX2APPLE_ENGINE_URL. A seed (--seed or $NX2APPLE_ENGINE_SEED)
is a local git repository that holds the pin, such as the engine.git a release app carries: sync fetches from it first and
needs the network only for what the seed lacks. Scratch worktrees go to $PATCHES_TMP (or --tmp), else the system's temporary
folder.
"""
import argparse
import contextlib
import hashlib
import importlib
import io
import os
import re
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
P = importlib.import_module('patches')   # tools/patches.py: the headers, apply_series, generate, the chain rule

REPO = Path(__file__).resolve().parent.parent
UPSTREAM_URL = 'https://github.com/seedds/nxnative.git'
STAMP = 'nx2apple-stamp'          # in engine/.git: invisible to `git status` in engine/
BRANCH = 'nx2apple'               # the branch sync builds: the pin, the patches, the generated files
GENERATED_SUBJECT = 'NX2Apple: generated files (indexes, dm/fork_patches.txt)'
IDENT = ('-c', 'user.name=tools/engine.py', '-c', 'user.email=engine@localhost', '-c', 'commit.gpgsign=false', '-c', 'core.autocrlf=false')

Fail = P.Fail
say = P.say


def git(*a, cwd, check=True, binary=False):
    return P.git(*a, cwd=cwd, check=check, binary=binary)


def engine_dir(root):
    return root / 'engine'


def pin(root):
    f = root / '.upstream-ref'
    if not f.is_file(): raise Fail(f'{f} is missing: this is not an NX2Apple checkout')
    sha = f.read_text().strip()
    if not re.fullmatch(r'[0-9a-f]{40}', sha): raise Fail(f'.upstream-ref must hold a full commit id (is: {sha!r})')
    return sha


def stamp_key(root):
    """The digest of what engine/ is built from: the pin, and each patch of the series by name and content, in order.
    frontend/Sources/NSPortBuilder/Engine.swift and frontend-qt/nspb_qt/engine.py compute the same, so the launchers can
    tell a stale engine/ without starting Python."""
    h = hashlib.sha256()
    h.update(b'pin ' + pin(root).encode() + b'\n')
    for name in P.read_series(root):
        f = root / 'patches' / name
        if not f.is_file(): raise Fail(f'listed in patches/series but missing: {name}')
        h.update(b'patch ' + name.encode() + b'\n' + hashlib.sha256(f.read_bytes()).hexdigest().encode() + b'\n')
    return h.hexdigest()


def read_stamp(eng):
    try: text = (eng / '.git' / STAMP).read_text()
    except OSError: return {}
    return dict(l.split(' ', 1) for l in text.splitlines() if ' ' in l)


def write_stamp(eng, root, head, key=None):
    (eng / '.git' / STAMP).write_text(f'nx2apple-engine 1\npin {pin(root)}\nkey {key or stamp_key(root)}\nhead {head}\n')


def is_repo(eng):
    return (eng / '.git').is_dir() and git('rev-parse', '--show-toplevel', cwd=eng, check=False).stdout.strip() == str(eng.resolve())


def head(eng):
    r = git('rev-parse', '--verify', '--quiet', 'HEAD', cwd=eng, check=False)
    return r.stdout.strip() if r.returncode == 0 else ''


def local_work(eng, st):
    """What sync would throw away: commits after the last sync, and changes to tracked or new files (ignored build products
    such as dm/host/gen are not work and survive a sync)."""
    out = []
    h = head(eng)
    if st.get('head') and h and h != st['head']:
        n = git('rev-list', '--count', f'{st["head"]}..{h}', cwd=eng, check=False).stdout.strip() or '?'
        out.append(f'{n} commit(s) after the last sync (HEAD {h[:12]})')
    dirty = git('status', '--porcelain', cwd=eng, check=False).stdout.splitlines()
    if dirty: out.append(f'{len(dirty)} changed or new file(s), e.g. {dirty[0][3:]}')
    return out


def why_stale(root):
    """'' when engine/ matches the pin and the series, else the reason in a few words."""
    eng = engine_dir(root)
    if not is_repo(eng): return 'engine/ is missing'
    st = read_stamp(eng)
    if not st: return 'engine/ has no stamp (not made by tools/engine.py sync)'
    if st.get('key') != stamp_key(root):
        return 'the pin moved' if st.get('pin') != pin(root) else 'patches/ changed'
    if st.get('head') != head(eng): return 'engine/ has commits after the last sync'
    return ''


# ---- getting the pinned commit ----

def have_commit(eng, sha):
    return git('cat-file', '-e', f'{sha}^{{commit}}', cwd=eng, check=False).returncode == 0


def fetch(eng, sha, seed=None, url=None):
    """Bring the commit into engine/: from the seed first (no network), then from upstream, one commit deep."""
    if have_commit(eng, sha): return 'already here'
    seed = seed or os.environ.get('NX2APPLE_ENGINE_SEED')
    if seed and Path(seed).exists():
        git('fetch', '--quiet', '--no-tags', '--depth', '1', str(Path(seed).resolve()), sha, cwd=eng, check=False)
        if have_commit(eng, sha): return f'from the seed {seed}'
        # The seed is an older pin: fetch it anyway, so the shallow fetch below can send only what changed since.
        git('fetch', '--quiet', '--no-tags', '--depth', '1', str(Path(seed).resolve()), 'HEAD', cwd=eng, check=False)
    url = url or os.environ.get('NX2APPLE_ENGINE_URL') or UPSTREAM_URL
    r = git('fetch', '--quiet', '--no-tags', '--depth', '1', url, sha, cwd=eng, check=False)
    if r.returncode or not have_commit(eng, sha):
        err = (r.stderr or '').strip().splitlines()
        raise Fail(f'cannot fetch {sha[:12]} from {url}: {err[-1] if err else "unknown error"}\n'
                   f'  Offline? Connect and run `python3 tools/engine.py sync` again, or point --seed at a local copy that has the commit '
                   f'(a release app carries one: NX2Apple.app/Contents/Resources/engine.git). Behind a mirror: set NX2APPLE_ENGINE_URL.')
    return f'from {url}'


def ensure_repo(eng):
    if is_repo(eng): return
    if eng.exists() and any(eng.iterdir()):
        raise Fail(f'{eng} exists but is not a git repository made by tools/engine.py: move it away, then run sync again')
    eng.mkdir(parents=True, exist_ok=True)
    git('init', '--quiet', cwd=eng)
    git('config', 'advice.detachedHead', 'false', cwd=eng)
    git('remote', 'add', 'seedds', UPSTREAM_URL, cwd=eng, check=False)   # for `git fetch seedds` and pull requests upstream


# ---- sync ----

def build(root, eng, patches, sha):
    """Check out the pin on BRANCH (keeping ignored build products), apply the series, commit the generated files."""
    git('checkout', '--quiet', '--force', '-B', BRANCH, sha, cwd=eng)
    git('clean', '--quiet', '-fd', cwd=eng)        # untracked files, not ignored ones (dm/host/gen and other build products stay)
    applied, landed, conflicts = P.apply_series(eng, patches)
    if conflicts:
        p, msg = conflicts[0]
        git('am', '--abort', cwd=eng, check=False)
        raise Fail(f'{p.file} does not apply to the pin {sha[:12]}\n  Reason: {p.reason}\n  Upstream-Status: {p.status}\n  {msg}\n'
                   f'  The series is broken on this pin: see patches/README.md, "Bumping, and what a conflict is".')
    if landed:
        say('empty on the pin (upstream has them, `tools/engine.py bump` drops them): ' + ', '.join(p.file for p in landed))
    for out, tool in P.GENERATED:
        if (eng / tool).is_file():
            r = subprocess.run([sys.executable, str(eng / tool)], cwd=eng, capture_output=True, text=True, check=False)
            if r.returncode: raise Fail(f'{tool} failed on the patched tree: {(r.stderr.strip().splitlines() or [str(r.returncode)])[-1]}')
    (eng / P.FORK_PATCHES).write_text(P.fork_patch_list([p for p, _ in applied]))
    git('add', '--force', '--', P.FORK_PATCHES, *(o for o, _ in P.GENERATED if (eng / o).exists()), cwd=eng)
    git(*IDENT, 'commit', '--quiet', '--allow-empty', '-m', GENERATED_SUBJECT, cwd=eng)
    return applied, landed


def cmd_sync(a):
    root = a.root
    eng = engine_dir(root)
    reason = why_stale(root)
    if not reason and not a.force:
        if not a.quiet: say(f'engine: up to date (upstream {pin(root)[:12]}, {len(P.read_series(root))} patches) in {eng}')
        return 0
    patches = P.load(root)
    ensure_repo(eng)
    st = read_stamp(eng)
    work = local_work(eng, st) if head(eng) else []
    if work and st and not a.force:
        raise Fail('engine/ has work a sync would throw away: ' + '; '.join(work) + '.\n'
                   '  Turn commits into patches with `python3 tools/engine.py export`, then sync. Or keep them on a branch and '
                   'sync anyway: `python3 tools/engine.py sync --force`.')
    if head(eng) and (work or not st):
        keep = f'nx2apple-backup-{time.strftime("%Y%m%d-%H%M%S")}'
        git(*IDENT, 'stash', '--include-untracked', '--quiet', cwd=eng, check=False)
        git('branch', '--force', keep, 'HEAD', cwd=eng, check=False)
        say(f'engine: kept the previous HEAD on branch {keep} (and uncommitted changes in `git -C engine stash list`)')
    sha = pin(root)
    got = fetch(eng, sha, a.seed)
    say(f'engine: building {sha[:12]} + {len(patches)} patches ({reason or "forced"}; upstream commit {got})')
    applied, _ = build(root, eng, patches, sha)
    write_stamp(eng, root, head(eng))
    say(f'engine: ready, {len(applied)} patches on upstream {sha[:12]} in {eng}')
    return 0


def cmd_stale(a):
    reason = why_stale(a.root)
    if reason:
        say(f'engine: stale ({reason}): run `python3 tools/engine.py sync`'); return 1
    if not a.quiet: say('engine: up to date')
    return 0


def cmd_hook(a):
    """One line for a session's context, whatever happens: a failed sync must never block the session."""
    buf = io.StringIO()
    try:
        reason = why_stale(a.root)
        if reason:
            with contextlib.redirect_stdout(buf):
                cmd_sync(a)
        n = len(P.read_series(a.root))
        done = f'synced ({reason})' if reason else 'up to date'
        say(f'engine/: {done}, upstream {pin(a.root)[:12]} + {n} patches. The engine guide is engine/AGENTS.md. '
            f'Engine work: commit in engine/, then `python3 tools/engine.py export`.')
    except (Fail, OSError, ValueError, subprocess.SubprocessError) as e:   # a failed fetch, a missing git: say it in one line
        msg = ' '.join(str(e).split())[:300]
        say(f'engine/: sync failed ({msg}). Run `python3 tools/engine.py sync` to see why. The committed tree (AGENTS.md, dm/) '
            f'is used until then.' if (a.root / 'AGENTS.md').is_file() else
            f'engine/: sync failed ({msg}). Run `python3 tools/engine.py sync` to see why.')
    return 0


# ---- export ----

def cmd_export(a):
    root = a.root
    eng = engine_dir(root)
    if not is_repo(eng): raise Fail('engine/ is missing: run `python3 tools/engine.py sync`, commit your change in engine/, then export')
    st = read_stamp(eng)
    rev = a.rev or (f'{st["head"]}..HEAD' if st.get('head') else None)
    if not rev: raise Fail('engine/ has no stamp: name the commits, e.g. `tools/engine.py export HEAD~2..HEAD`')
    spec = rev if '..' in rev else f'{rev}^..{rev}'
    commits = git('rev-list', '--reverse', spec, cwd=eng).stdout.split()
    if not commits: raise Fail(f'no commits in {spec} (commit your change in engine/ first)')
    existing = P.load(root)
    pd = root / 'patches'
    n = max([int(m.group(1)) for p in existing for m in [re.match(r'(\d+)-', p.file)] if m] or [0])
    series = (pd / 'series').read_text()
    if series and not series.endswith('\n'): series += '\n'
    skip = {P.FORK_PATCHES, *(o for o, _ in P.GENERATED)}
    made = []
    for c in commits:
        if git('log', '-1', '--format=%s', c, cwd=eng).stdout.strip() == GENERATED_SUBJECT: continue
        text = git('format-patch', '--binary', '--zero-commit', '--no-signature', '--no-numbered', '--stdout', f'{c}^..{c}', '--', '.',
                   *(f':(exclude){o}' for o in sorted(skip)), cwd=eng, binary=True).stdout.decode(errors='surrogateescape')
        if not re.search(r'(?m)^diff --git ', text):
            say(f'skipped {c[:10]}: it changes only generated files'); continue
        files = sorted({f for m in re.finditer(r'(?m)^diff --git a/(\S+) b/(\S+)$', text) for f in m.groups()})
        hits = P.chain_hits(files, eng)
        if hits:
            raise Fail(f'{c[:10]} touches the shader chain or the tool pins ({", ".join(hits)}): patches must not change them (patches/README.md, Patch policy)')
        head_, sep, rest = text.partition('\n---\n')
        add = [f'{k}: {v}' for k, v in (('Upstream-Status', a.status), ('Reason', a.reason), ('Issue', a.issue))
               if not re.search(r'(?m)^' + k + ':', head_)]
        if add: head_ = head_.rstrip('\n') + '\n\n' + '\n'.join(add) + '\n'
        text = head_ + sep + rest
        m = re.search(r'(?m)^Subject: (?:\[PATCH[^\]]*\] )?(.*)$', text)
        subj = m.group(1) if m else c[:10]
        n += 1
        name = f'{n:04d}-{P.slug(subj)}.patch'
        (pd / name).write_bytes(text.encode(errors='surrogateescape'))
        series += name + '\n'; made.append(name)
    (pd / 'series').write_text(series)
    for m in made: say('wrote patches/' + m)
    if made:
        # engine/ already holds these changes: record that, so the next sync rebuilds it from the series instead of refusing
        if st: write_stamp(eng, root, head(eng), key=st.get('key'))
        say('Fill in Reason and Issue in the new headers, then `python3 tools/engine.py check`. `python3 tools/engine.py sync` '
            'rebuilds engine/ from the series (your commits stay on a backup branch).')
    return 0


# ---- status, check ----

def cmd_status(a):
    P.cmd_status(a)
    eng = engine_dir(a.root)
    reason = why_stale(a.root)
    if not reason: state = 'up to date'
    else: state = f'stale ({reason}): run `python3 tools/engine.py sync`'
    say(f'engine/: {state}. Pin: upstream {pin(a.root)[:12]}')
    if is_repo(eng):
        work = local_work(eng, read_stamp(eng))
        if work: say('engine/ work not in patches/: ' + '; '.join(work) + ' (`tools/engine.py export`)')
    return 0


def scratch_root(root):
    """The repository the scratch worktrees branch from: engine/, made (and fetched) on demand."""
    eng = engine_dir(root)
    ensure_repo(eng)
    return eng


def cmd_check(a):
    root = a.root
    patches = P.load(root)
    bad = []
    pd = root / 'patches'
    stray = sorted(f.name for f in pd.glob('*.patch') if f.name not in {p.file for p in patches})
    if stray: bad.append('patch files not in patches/series: ' + ', '.join(stray))
    eng = scratch_root(root)
    sha = pin(root)
    fetch(eng, sha, a.seed)
    # The chain rule reads AGENTS.md at the pin plus the series; the pin's own copy is close enough for the globs.
    rules = eng if (eng / 'AGENTS.md').is_file() else root
    for p in patches:
        for m in p.problems(): bad.append(f'{p.file}: {m}')
        gen = sorted(f for f in p.files if f in {o for o, _ in P.GENERATED})
        if gen: bad.append(f'{p.file}: touches generated files ({", ".join(gen)}); sync regenerates them, so a patch must not carry them')
        hits = P.chain_hits(p.files, rules)
        if hits: bad.append(f'{p.file}: touches the shader chain or the tool pins, which patches must not change ({", ".join(hits)}); see patches/README.md, Patch policy')
    if bad:
        say('patch queue: invalid\n  ' + '\n  '.join(bad)); return 1
    with P.Scratch(eng, sha, a.tmp) as s:
        _, landed, conflicts = P.apply_series(s.dir, patches)
        if conflicts:
            p, msg = conflicts[0]
            say(f'patch queue: {p.file} does not apply to the pinned upstream {sha[:12]}\n  Reason: {p.reason}\n  Upstream-Status: {p.status}\n  {msg}'); return 1
        if landed:
            say('patch queue: patches that are empty on the pinned upstream (it has them already; run bump to drop them): ' + ', '.join(p.file for p in landed)); return 1
        if a.tree and any((root / v).exists() for v in P.VENDORED):
            P.generate(s.dir)
            want = P.tree_files(s.dir)
            diff = P.diff_trees(want, P.local_files(root))
            have_list = (root / P.FORK_PATCHES).read_text() if (root / P.FORK_PATCHES).exists() else None
            if have_list != P.fork_patch_list(patches): diff.append(f'  {P.FORK_PATCHES} is not the list of the series (run tools/patches.py apply)')
            if diff:
                say(f'patch queue: the committed vendored tree is not upstream {sha[:12]} plus the series ({len(diff)} differences):')
                say('\n'.join(diff[:40]) + ('\n  ...' if len(diff) > 40 else ''))
                say(P.fix_hint(diff, patches)); return 1
            say(f'patch queue: ok. {len(patches)} patches apply cleanly to upstream {sha[:12]}, and the committed vendored tree matches ({len(want)} files)')
            return 0
    say(f'patch queue: ok. {len(patches)} patches apply cleanly to upstream {sha[:12]}')
    return 0


# ---- bump, refresh ----

def resolve_target(eng, to, seed=None):
    if re.fullmatch(r'[0-9a-f]{40}', to): return to
    url = os.environ.get('NX2APPLE_ENGINE_URL') or UPSTREAM_URL
    r = git('ls-remote', url, to, cwd=eng, check=False)
    line = next((l for l in r.stdout.splitlines() if l.endswith((f'refs/heads/{to}', f'\t{to}'))), '')
    if not line: raise Fail(f'{to} is neither a full commit id nor a branch of {url}')
    return line.split()[0]


def cmd_bump(a):
    root = a.root
    patches = P.load(root)
    eng = scratch_root(root)
    old = pin(root)
    fetch(eng, old, a.seed)                      # the old pin's blobs let `git am -3` merge three ways
    sha = resolve_target(eng, a.to)
    fetch(eng, sha)
    s = P.Scratch(eng, sha, a.tmp, keep=not a.dry)
    try:
        applied, landed, conflicts = P.apply_series(s.dir, patches, stop=not a.dry)
        P.report(old, sha, applied, landed, conflicts)
        if conflicts:
            if a.dry: s.close(); return 1
            p = conflicts[0][0]
            say(f'\nStopped at {p.file}. The conflict is left in {s.dir}:\n'
                f'  resolve it there, `git am --continue`, apply the rest with `git am -3 <patches>`, then run\n'
                f'  tools/engine.py refresh {s.dir} --to {sha[:12]}')
            return 1
        if a.dry: return 0
        P.write_series(root, s.dir, applied, landed, patches)
        (root / '.upstream-ref').write_text(sha + '\n')
        s.close()
        say('wrote patches/ and .upstream-ref; `python3 tools/engine.py sync` builds engine/ on the new pin')
        return 0
    except BaseException:
        s.close(); raise


def cmd_refresh(a):
    root, wt = a.root, Path(a.worktree)
    sha = a.to if re.fullmatch(r'[0-9a-f]{40}', a.to) else git('rev-parse', '--verify', f'{a.to}^{{commit}}', cwd=wt).stdout.strip()
    old = P.load(root)
    commits = git('rev-list', '--reverse', f'{sha}..HEAD', cwd=wt).stdout.split()
    if len(commits) > len(old): raise Fail('more commits than patches')
    by_subject = {p.subject: p for p in old}
    applied, used = [], set()
    for c in commits:
        subj = git('log', '-1', '--format=%s', c, cwd=wt).stdout.strip()
        p = by_subject.get(subj)
        if not p: raise Fail(f'commit "{subj}" matches no patch subject')
        applied.append((p, c)); used.add(p.file)
    landed = [p for p in old if p.file not in used]
    say('landed upstream, dropped: ' + (', '.join(p.name for p in landed) or 'none'))
    P.write_series(root, wt, applied, landed, old)
    (root / '.upstream-ref').write_text(sha + '\n')
    say('wrote patches/ and .upstream-ref; `python3 tools/engine.py sync` builds engine/ on the new pin')
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--repo', default=str(REPO), help="the checkout (default: this script's)")
    ap.add_argument('--tmp', help='folder for scratch worktrees (default $PATCHES_TMP, else the system temporary folder)')
    ap.add_argument('--seed', help='a local git repository holding the pin, tried before the network (default $NX2APPLE_ENGINE_SEED)')
    ap.add_argument('-q', '--quiet', action='store_true', help='print nothing when there is nothing to do')
    sub = ap.add_subparsers(dest='cmd', required=True)
    s = sub.add_parser('sync'); s.add_argument('--force', action='store_true', help='rebuild even when up to date; local work goes to a backup branch'); s.set_defaults(f=cmd_sync)
    sub.add_parser('stale').set_defaults(f=cmd_stale)
    s = sub.add_parser('hook'); s.set_defaults(f=cmd_hook, force=False, quiet=True)
    s = sub.add_parser('export'); s.add_argument('rev', nargs='?', help='a commit or a range in engine/ (default: everything after the last sync)')
    s.add_argument('--status', default='pending'); s.add_argument('--reason', default='TODO: why the fork carries this'); s.add_argument('--issue', default='TODO: LNPANDY/NX2Apple#<n>'); s.set_defaults(f=cmd_export)
    sub.add_parser('status').set_defaults(f=cmd_status)
    s = sub.add_parser('check'); s.add_argument('--tree', action='store_true', help='also compare the committed vendored tree (step 1 of #214)'); s.set_defaults(f=cmd_check)
    s = sub.add_parser('bump'); s.add_argument('--to', required=True, help='the new upstream commit, or a branch such as main'); s.add_argument('--dry', action='store_true'); s.set_defaults(f=cmd_bump)
    s = sub.add_parser('refresh'); s.add_argument('worktree'); s.add_argument('--to', required=True); s.set_defaults(f=cmd_refresh)
    a = ap.parse_args(argv)
    a.root = Path(a.repo).resolve()
    try:
        return a.f(a)
    except Fail as e:
        print(f'engine.py: {e}', file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
