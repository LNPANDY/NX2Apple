#!/usr/bin/env python3
"""The fork's patch queue on a pinned upstream (LNPANDY/NX2Apple#123): the library tools/engine.py is built on, and `status`.

The engine (dm/ scripts/ docs/ ref/ AGENTS.md) is not committed here: it is seedds/nxnative at the commit in .upstream-ref, plus
the patches in patches/ applied in the order of patches/series with `git am -3`, built into engine/ by tools/engine.py
(LNPANDY/NX2Apple#214). Each patch is a `git format-patch` file whose message carries a header:

    Upstream-Status: forwarded seedds/nxnative#475 | pending | fork-only | backport <sha>
    Reason: <one line>
    Issue: <repo>#<n>

This module reads the series and the headers, applies the series in a scratch worktree, applies the chain rule and writes the
series back after a bump. Its only command (Python 3.9+, stdlib and git):
  status                a table of the patches: Upstream-Status, Reason, age

Syncing, exporting, checking and bumping are tools/engine.py's. Scratch worktrees go under $PATCHES_TMP (or --tmp), else the
system temporary folder.
"""
import argparse, fnmatch, os, re, shutil, subprocess, sys, tempfile, time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
FORK_PATCHES = 'dm/fork_patches.txt'
# Generated files inside the engine: upstream's tests require each to equal what its tool writes from the tree
# (test_docs.py), and the tree differs from upstream's once the series is in, so a patch cannot carry them (they would
# conflict on every bump). sync runs the tools on the patched tree and commits the result; export and check keep patches away
# from these paths.
GENERATED = (('docs/agents/game-patches.md', 'dm/tools/docs_patches.py'),
             ('docs/agents/symptoms.md', 'dm/tools/docs_symptoms.py'))
KINDS = ('forwarded', 'pending', 'fork-only', 'backport')
# The shader chain and the tool pins (the engine's AGENTS.md: the DMSH_CHAIN paragraph names them; chain_paths() reads it).
# Used only when that file has no such paragraph.
CHAIN_FALLBACK = ('dm/gfx/nvn/dmsh_chain.h', 'dm/gfx/tools/dmsh_*', 'dm/gfx/tools/Program.cs', 'dm/gfx/tools/ios_metal.py',
                  'dm/gfx/tools/dmsh_chain.lock', 'dm/gfx/tools/dmsh_xlate_bin*')


class Fail(Exception):
    pass


def git(*a, cwd=None, check=True, inp=None, binary=False):
    r = subprocess.run(['git', *a], cwd=cwd or REPO, input=inp, capture_output=True, text=not binary)
    if check and r.returncode:
        raise Fail(f'git {" ".join(a)} failed: {(r.stderr if not binary else r.stderr.decode(errors="replace")).strip()[-1500:]}')
    return r


def say(*a):
    print(*a, flush=True)


# ---- the series and the headers ----

class Patch:
    def __init__(self, path):
        self.path = path
        self.file = path.name
        self.name = re.sub(r'^\d+-', '', re.sub(r'\.patch$', '', self.file))
        text = path.read_text(encoding='utf-8', errors='replace')
        head = text.split('\n---\n', 1)[0]
        m = re.search(r'(?m)^Subject: (?:\[PATCH[^\]]*\] )?(.*(?:\n .*)*)', head)
        self.subject = self.decode_subject(m.group(1)) if m else ''
        self.date = (re.search(r'(?m)^Date: (.*)$', head) or [None, ''])[1]
        self.status = self.header(head, 'Upstream-Status')
        self.reason = self.header(head, 'Reason')
        self.issue = self.header(head, 'Issue')
        self.kind = (self.status.split() or [''])[0]
        self.files = sorted({f for m in re.finditer(r'(?m)^diff --git a/(\S+) b/(\S+)$', text) for f in m.groups()})

    @staticmethod
    def decode_subject(raw):
        """format-patch writes a subject with a non-ASCII character as RFC 2047 words (=?UTF-8?q?...?=), git log prints it decoded."""
        import email.errors
        import email.header
        joined = ' '.join(raw.split())
        try: return str(email.header.make_header(email.header.decode_header(joined)))
        except (email.errors.HeaderParseError, LookupError, UnicodeError): return joined

    @staticmethod
    def header(head, key):
        m = re.search(r'(?m)^' + key + r': *(.*)$', head)
        return m.group(1).strip() if m else ''

    def age_days(self):
        import email.utils
        try:
            return max(0, int((time.time() - email.utils.mktime_tz(email.utils.parsedate_tz(self.date))) // 86400))
        except Exception:
            return -1

    def problems(self):
        out = []
        if self.kind not in KINDS:
            out.append(f'Upstream-Status must start with one of {", ".join(KINDS)} (is: {self.status or "missing"})')
        elif self.kind == 'forwarded' and not re.search(r'#\d+', self.status):
            out.append('Upstream-Status: forwarded needs the upstream PR, e.g. forwarded seedds/nxnative#475')
        elif self.kind == 'backport' and not re.search(r'\b[0-9a-f]{7,40}\b', self.status):
            out.append('Upstream-Status: backport needs the upstream commit')
        for key, val in (('Reason', self.reason), ('Issue', self.issue)):
            if not val: out.append(f'{key} is missing')
            elif val.startswith('TODO'): out.append(f'{key} is still the export template ({val})')
        return out


def read_series(root):
    s = root / 'patches/series'
    if not s.is_file(): raise Fail(f'{s} is missing')
    out = []
    for line in s.read_text().splitlines():
        line = line.split('#', 1)[0].strip()
        if line: out.append(line)
    return out


def load(root):
    pd = root / 'patches'
    names = read_series(root)
    missing = [n for n in names if not (pd / n).is_file()]
    if missing: raise Fail('listed in patches/series but missing: ' + ', '.join(missing))
    if len(set(names)) != len(names): raise Fail('patches/series lists a patch twice')
    return [Patch(pd / n) for n in names]


def chain_paths(root):
    """The globs of the shader chain, read from the engine's AGENTS.md (in `root`, a tree of the engine), the chain paragraph (the one naming DMSH_CHAIN)."""
    try: text = (root / 'AGENTS.md').read_text()
    except OSError: return list(CHAIN_FALLBACK)
    para = next((l for l in text.splitlines() if 'DMSH_CHAIN' in l and 'dm/gfx/tools/dmsh_' in l), None)
    found = []
    if para:
        for tok in re.findall(r'`([^`]+)`', para):
            if re.fullmatch(r'dm/gfx/(?:nvn|tools)/[\w./*-]+', tok): found.append(tok)
            elif re.fullmatch(r'[\w-]+\.(?:cs|py|lock)', tok) and not tok.startswith('dmsh_'): found.append('dm/gfx/tools/' + tok)
            elif tok == 'dmsh_chain.lock': found.append('dm/gfx/tools/' + tok)
        m = re.search(r'translator is `([^`]+)`', text)
        if m and re.fullmatch(r'dm/gfx/tools/[\w./-]+', m.group(1)): found.append(m.group(1) + '*')
    return sorted(set(found)) if len(found) >= 4 else list(CHAIN_FALLBACK)


def chain_hits(files, root):
    globs = chain_paths(root)
    return sorted(f for f in files if any(fnmatch.fnmatchcase(f, g) for g in globs))


# ---- applying the series in a scratch worktree ----

class Scratch:
    """A detached worktree of upstream at a commit, removed on exit unless kept."""
    def __init__(self, root, sha, tmp=None, keep=False):
        self.root, self.sha, self.keep = root, sha, keep
        self.base = Path(tempfile.mkdtemp(prefix='patches-', dir=tmp or os.environ.get('PATCHES_TMP') or None))
        self.dir = self.base / 'tree'
        git('worktree', 'add', '--detach', '-q', str(self.dir), sha, cwd=root)

    def close(self):
        if self.keep: return
        git('worktree', 'remove', '--force', str(self.dir), cwd=self.root, check=False)
        shutil.rmtree(self.base, ignore_errors=True)
        git('worktree', 'prune', cwd=self.root, check=False)

    def __enter__(self): return self
    def __exit__(self, *e): self.close()


def am(wt, patch):
    return git('-c', 'user.name=patches.py', '-c', 'user.email=patches@localhost', '-c', 'commit.gpgsign=false', '-c', 'core.autocrlf=false',
               'am', '-3', '--quiet', str(patch.path), cwd=wt, check=False)


def apply_series(wt, patches, stop=True):
    """Apply each patch in turn. Returns (applied, landed, conflicts): applied = [(patch, commit)], landed = patches that came
    out empty (upstream has them), conflicts = [(patch, message)]. With stop, the first conflict stays in the worktree."""
    applied, landed, conflicts = [], [], []
    for p in patches:
        before = git('rev-parse', 'HEAD', cwd=wt).stdout.strip()
        r = am(wt, p)
        if r.returncode == 0:
            after = git('rev-parse', 'HEAD', cwd=wt).stdout.strip()
            if after == before or git('rev-parse', 'HEAD^{tree}', cwd=wt).stdout == git('rev-parse', before + '^{tree}', cwd=wt).stdout:
                git('reset', '--hard', '-q', before, cwd=wt)   # the merge changed nothing: upstream has this patch
                landed.append(p); continue
            applied.append((p, after)); continue
        unmerged = git('ls-files', '-u', cwd=wt).stdout.strip()
        clean = git('diff', '--cached', '--quiet', cwd=wt, check=False).returncode == 0 and git('diff', '--quiet', cwd=wt, check=False).returncode == 0
        if not unmerged and clean and 'Patch failed' not in r.stderr and 'patch does not apply' not in r.stderr:
            git('am', '--skip', cwd=wt, check=False)
            landed.append(p); continue
        files = git('diff', '--name-only', '--diff-filter=U', cwd=wt, check=False).stdout.split()
        errs = [l for l in (r.stderr + r.stdout).splitlines() if re.match(r'(error|CONFLICT|Patch failed|Applying)', l)]
        conflicts.append((p, ('conflicting files: ' + ', '.join(files) + '\n' if files else '') + '\n'.join(errs[-6:])))
        if stop: break
        git('am', '--abort', cwd=wt, check=False)
    return applied, landed, conflicts


def fork_patch_list(patches):
    return ''.join(p.name + '\n' for p in patches)


# ---- subcommands ----

def report(old, sha, applied, landed, conflicts):
    say(f'bump {old[:12]} -> {sha[:12]}')
    say(f'  applied cleanly ({len(applied)}): ' + (', '.join(p.name for p, _ in applied) or 'none'))
    say(f'  landed upstream, dropped ({len(landed)}): ' + (', '.join(p.name for p in landed) or 'none'))
    say(f'  conflicts ({len(conflicts)}):' + ('' if conflicts else ' none'))
    for p, msg in conflicts:
        say(f'    {p.file}\n      Reason: {p.reason}\n      Upstream-Status: {p.status}')
        for l in msg.splitlines(): say('      | ' + l)


def write_series(root, wt, applied, landed, patches):
    """Rewrite patches/ from the rebased commits: the kept patches refreshed, the landed ones deleted."""
    pd = root / 'patches'
    for p, commit in applied:
        text = git('format-patch', '--binary', '--zero-commit', '--no-signature', '--no-numbered', '--stdout', '-1', commit, cwd=wt, binary=True).stdout
        p.path.write_bytes(text)
    for p in landed: p.path.unlink()
    keep = {p.file for p, _ in applied}
    lines = [l for l in (pd / 'series').read_text().splitlines()]
    out = [l for l in lines if l.split('#', 1)[0].strip() == '' or l.split('#', 1)[0].strip() in keep]
    (pd / 'series').write_text('\n'.join(out) + '\n')


def slug(s):
    return re.sub(r'[^a-z0-9]+', '-', s.lower()).strip('-')[:48].strip('-') or 'patch'


def cmd_status(a):
    patches = load(a.root)
    rows = [('patch', 'upstream status', 'reason', 'age')]
    for p in patches:
        age = p.age_days()
        rows.append((p.name, p.status, p.reason, f'{age}d' if age >= 0 else '?'))
    w = [max(len(r[0]) for r in rows), 42]
    for i, r in enumerate(rows):
        st = r[1] if len(r[1]) <= 42 else r[1][:39] + '...'
        reason = r[2] if len(r[2]) <= 70 else r[2][:67] + '...'
        say(f'{r[0]:<{w[0]}}  {st:<42}  {r[3]:>5}  {reason}')
        if i == 0: say('-' * (sum(w) + 12))
    c = {k: sum(1 for p in patches if p.kind == k) for k in KINDS}
    say(f'\n{len(patches)} patches: ' + ', '.join(f'{v} {k}' for k, v in c.items()))
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--repo', default=str(REPO), help='the checkout (default: this script\'s)')
    sub = ap.add_subparsers(dest='cmd', required=True)
    sub.add_parser('status').set_defaults(f=cmd_status)
    a = ap.parse_args(argv)
    a.root = Path(a.repo).resolve()
    try:
        return a.f(a)
    except Fail as e:
        print(f'patches.py: {e}', file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
