#!/usr/bin/env python3
"""The fork's patch queue on a pinned upstream (LNPANDY/NX2Apple#123).

The vendored paths (dm/ scripts/ docs/ ref/ AGENTS.md) are generated, not hand-edited: seedds/nxnative at the commit
in .upstream-ref, plus the patches in patches/ applied in the order of patches/series with `git am -3`. Each patch is a
`git format-patch` file whose message carries a header:

    Upstream-Status: forwarded seedds/nxnative#475 | pending | fork-only | backport <sha>
    Reason: <one line>
    Issue: <repo>#<n>

Subcommands (Python 3.9+, stdlib and git):
  apply [--ref SHA]     build the vendored tree from upstream at the ref plus the series (a temporary worktree), regenerate
                        the generated indexes (GENERATED), copy it into the checkout, and write dm/fork_patches.txt
  bump --to SHA         move the pin: re-apply the series on SHA, drop the patches that come out empty (upstream has them)
                        and report them, refresh the rest; on a conflict stop, naming the patch, its Reason and its
                        Upstream-Status, and leave the conflict in a worktree for a human. --dry changes nothing and
                        reports every patch that would conflict
  export <commit|range> turn local commits on the vendored tree into patches with the header template
  absorb [paths...]     fold changes made directly to vendored files into the patch that already touches each file (a new
                        file goes to a patch only when the choice is unambiguous, else name it with --into), then run check
  status                a table of the patches: Upstream-Status, Reason, age
  check                 the headers are valid, no patch touches the shader chain, the series applies to the pinned ref and
                        reproduces the vendored tree of the checkout byte for byte (after
                        the generated indexes are regenerated on it)

Scratch worktrees go under $PATCHES_TMP (or --tmp), else the system temporary folder.
"""
import argparse, fnmatch, os, re, shutil, subprocess, sys, tempfile, time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
VENDORED = ('dm', 'scripts', 'docs', 'AGENTS.md', 'ref')
# Inside the vendored paths but not part of the generated tree: the tool, its test, and the list it writes.
OWN = ('scripts/patches.py', 'scripts/tests/test_patches.py', 'dm/fork_patches.txt')
FORK_PATCHES = 'dm/fork_patches.txt'
# Generated files inside the vendored paths: upstream's tests require each to equal what its tool writes from the tree
# (test_docs.py), and the tree differs from upstream's once the series is in, so a patch cannot carry them (they would
# conflict on every bump). apply, bump and check run the tools on the patched tree and commit the result; export and check
# keep patches away from these paths.
GENERATED = (('docs/agents/game-patches.md', 'dm/tools/docs_patches.py'),
             ('docs/agents/symptoms.md', 'dm/tools/docs_symptoms.py'))
KINDS = ('forwarded', 'pending', 'fork-only', 'backport')
# The shader chain and the tool pins (AGENTS.md: the DMSH_CHAIN paragraph names them; chain_paths() reads it).
# Used only when AGENTS.md has no such paragraph.
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
    """The globs of the shader chain, read from AGENTS.md's chain paragraph (the one naming DMSH_CHAIN)."""
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

def resolve(ref, root):
    r = git('rev-parse', '--verify', '--quiet', f'{ref}^{{commit}}', cwd=root, check=False)
    if r.returncode:
        raise Fail(f'{ref} is not a commit in this repository: fetch it first (git fetch seedds {ref})')
    return r.stdout.strip()


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


def generate(wt):
    """Run the generators of GENERATED on the patched tree and commit what they changed (no commit when nothing changed)."""
    for out, tool in GENERATED:
        if not (wt / tool).is_file(): continue
        r = subprocess.run([sys.executable, str(wt / tool)], cwd=wt, capture_output=True, text=True)
        if r.returncode:
            raise Fail(f'{tool} failed on the patched tree: {(r.stderr.strip().splitlines() or [str(r.returncode)])[-1]}')
    if git('status', '--porcelain', '--', *(o for o, _ in GENERATED), cwd=wt).stdout.strip():
        git('add', '--', *(o for o, _ in GENERATED), cwd=wt)
        git('-c', 'user.name=patches.py', '-c', 'user.email=patches@localhost', '-c', 'commit.gpgsign=false',
            'commit', '-q', '-m', 'Regenerated indexes: ' + ', '.join(o for o, _ in GENERATED), cwd=wt)


def tree_files(wt):
    """{path: (mode, blob)} of the vendored paths at HEAD of a worktree, without the tool's own files."""
    out = git('ls-tree', '-r', '-z', 'HEAD', '--', *VENDORED, cwd=wt).stdout
    files = {}
    for rec in out.split('\0'):
        if not rec: continue
        meta, path = rec.split('\t', 1)
        mode, _, blob = meta.split()
        if path not in OWN: files[path] = (mode, blob)
    return files


def fork_patch_list(patches):
    return ''.join(p.name + '\n' for p in patches)


def local_files(root):
    """{path: (mode, blob)} of the checkout's working tree under the vendored paths: tracked files that still exist plus
    untracked ones git does not ignore, without the tool's own files."""
    r = git('ls-files', '-z', '--cached', '--others', '--exclude-standard', '--', *VENDORED, cwd=root).stdout
    paths = sorted({p for p in r.split('\0') if p and p not in OWN and (root / p).is_file()})
    files = {}
    if paths:
        blobs = git('hash-object', '--stdin-paths', cwd=root, inp='\n'.join(paths) + '\n').stdout.split()
        for p, b in zip(paths, blobs):
            files[p] = ('100755' if os.access(root / p, os.X_OK) else '100644', b)
    return files


def diff_trees(want, have):
    out = []
    for p in sorted(set(want) | set(have)):
        if p not in have: out.append(f'  missing in the checkout: {p}')
        elif p not in want: out.append(f'  not produced by the series: {p}')
        elif want[p] != have[p]:
            what = 'mode' if want[p][1] == have[p][1] else 'content'
            out.append(f'  differs ({what}): {p}')
    return out


def install(root, wt, patches):
    """Copy the generated vendored tree into the checkout: delete tracked vendored files it no longer has, write the rest."""
    want = tree_files(wt)
    for p in git('ls-files', '-z', '--', *VENDORED, cwd=root).stdout.split('\0'):
        if p and p not in want and p not in OWN and (root / p).exists(): (root / p).unlink()
    for p, (mode, blob) in want.items():
        dest = root / p
        dest.parent.mkdir(parents=True, exist_ok=True)
        if dest.is_symlink(): dest.unlink()
        dest.write_bytes((wt / p).read_bytes())
        dest.chmod(0o755 if mode == '100755' else 0o644)
    (root / FORK_PATCHES).write_text(fork_patch_list(patches))


def fix_hint(diff, patches):
    """What a failing author runs. diff = the lines of diff_trees (plus the fork_patches.txt line)."""
    gen = {o for o, _ in GENERATED}
    paths = [m.group(1) for l in diff for m in [re.search(r': (\S+)$', l)] if m and not l.rstrip().endswith('(run patches.py apply)')]
    absorbable = [p for p in paths if p not in gen]
    lines = ['']
    for l in diff:
        m = re.search(r': (\S+)$', l)
        if not m or l.rstrip().endswith('(run patches.py apply)'): continue
        f = m.group(1)
        if f in gen: lines.append(f'{f} is generated: run `python3 scripts/patches.py apply`')
        else: lines.append(f'{f} differs from pin+patches: run `python3 scripts/patches.py absorb {f}` and commit patches/')
    if absorbable:
        lines.append('To fold all of them at once: `python3 scripts/patches.py absorb`, then commit patches/ (and dm/fork_patches.txt if it changed).')
        lines.append('A new file goes to the patch that owns its folder; if that is ambiguous, absorb stops and asks for `--into <patch>` (see `scripts/patches.py status`).')
        lines.append('A change that deserves its own patch (new Upstream-Status, Reason, Issue): commit it, then `python3 scripts/patches.py export <commit>`. See patches/README.md.')
    else:
        lines.append('Run `python3 scripts/patches.py apply` to rewrite the generated files, then commit. See patches/README.md.')
    return '\n'.join(lines)


# ---- subcommands ----

def cmd_check(a):
    root = a.root
    patches = load(root)
    bad = []
    pd = root / 'patches'
    stray = sorted(f.name for f in pd.glob('*.patch') if f.name not in {p.file for p in patches})
    if stray: bad.append('patch files not in patches/series: ' + ', '.join(stray))
    for p in patches:
        for m in p.problems(): bad.append(f'{p.file}: {m}')
        gen = sorted(f for f in p.files if f in {o for o, _ in GENERATED})
        if gen: bad.append(f'{p.file}: touches generated files ({", ".join(gen)}); apply, bump and check regenerate them, so a patch must not carry them')
        hits = chain_hits(p.files, root)
        if hits: bad.append(f'{p.file}: touches the shader chain or the tool pins, which patches must not change ({", ".join(hits)}); see patches/README.md, Patch policy')
    if bad:
        say('patch queue: invalid\n  ' + '\n  '.join(bad)); return 1
    ref = (root / '.upstream-ref').read_text().strip()
    sha = resolve(ref, root)
    with Scratch(root, sha, a.tmp) as s:
        applied, landed, conflicts = apply_series(s.dir, patches)
        if conflicts:
            p, msg = conflicts[0]
            say(f'patch queue: {p.file} does not apply to the pinned upstream {sha[:12]}\n  Reason: {p.reason}\n  Upstream-Status: {p.status}\n  {msg}'); return 1
        if landed:
            say('patch queue: patches that are empty on the pinned upstream (it has them already; run bump to drop them): ' + ', '.join(p.file for p in landed)); return 1
        generate(s.dir)
        want = tree_files(s.dir)
    diff = diff_trees(want, local_files(root))
    expect = fork_patch_list(patches)
    have_list = (root / FORK_PATCHES).read_text() if (root / FORK_PATCHES).exists() else None
    if have_list != expect: diff.append(f'  {FORK_PATCHES} is not the list of the series (run patches.py apply)')
    if diff:
        say(f'patch queue: the vendored tree is not upstream {sha[:12]} plus the series ({len(diff)} differences):')
        say('\n'.join(diff[:40]) + ('\n  ...' if len(diff) > 40 else ''))
        say(fix_hint(diff, patches))
        return 1
    say(f'patch queue: ok. {len(patches)} patches apply to upstream {sha[:12]} and give the committed vendored tree ({len(want)} files)')
    return 0


def cmd_apply(a):
    root = a.root
    patches = load(root)
    ref = a.ref or (root / '.upstream-ref').read_text().strip()
    sha = resolve(ref, root)
    with Scratch(root, sha, a.tmp) as s:
        applied, landed, conflicts = apply_series(s.dir, patches)
        if conflicts:
            p, msg = conflicts[0]
            raise Fail(f'{p.file} does not apply to {sha[:12]}\n  Reason: {p.reason}\n  Upstream-Status: {p.status}\n  {msg}')
        generate(s.dir)
        install(root, s.dir, [p for p, _ in applied])
    if landed: say('empty at this ref (upstream has them): ' + ', '.join(p.file for p in landed) + ' (patches.py bump drops them)')
    say(f'applied {len(applied)} patches to upstream {sha[:12]}; the vendored tree is written')
    return 0


def cmd_bump(a):
    root = a.root
    patches = load(root)
    old = (root / '.upstream-ref').read_text().strip() if (root / '.upstream-ref').exists() else '?'
    sha = resolve(a.to, root)
    keep = not a.dry
    s = Scratch(root, sha, a.tmp, keep=keep)
    try:
        applied, landed, conflicts = apply_series(s.dir, patches, stop=not a.dry)
        report(old, sha, applied, landed, conflicts)
        if conflicts:
            if a.dry:
                s.close(); return 1
            p = conflicts[0][0]
            say(f'\nStopped at {p.file}. The conflict is left in {s.dir}:\n'
                f'  resolve it there, `git am --continue`, apply the rest with `git am -3 <patches>`, then run\n'
                f'  scripts/patches.py refresh {s.dir} --to {sha[:12]}')
            return 1
        if a.dry:
            return 0
        write_series(root, s.dir, applied, landed, patches)
        (root / '.upstream-ref').write_text(sha + '\n')
        generate(s.dir)
        install(root, s.dir, [p for p, _ in applied])
        s.close()
        return 0
    except BaseException:
        s.close()
        raise


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


def cmd_refresh(a):
    """After a human resolved a bump: the worktree's commits (upstream..HEAD) become the series."""
    root, wt = a.root, Path(a.worktree)
    sha = resolve(a.to, root)
    old = load(root)
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
    write_series(root, wt, applied, landed, old)
    (root / '.upstream-ref').write_text(sha + '\n')
    generate(wt)
    install(root, wt, [p for p, _ in applied])
    return 0


def slug(s):
    return re.sub(r'[^a-z0-9]+', '-', s.lower()).strip('-')[:48].strip('-') or 'patch'


def cmd_export(a):
    root = a.root
    spec = a.rev if '..' in a.rev else f'{a.rev}^..{a.rev}'
    existing = load(root) if (root / 'patches/series').exists() else []
    pd = root / 'patches'; pd.mkdir(exist_ok=True)
    n = max([int(re.match(r'(\d+)-', p.file).group(1)) for p in existing if re.match(r'(\d+)-', p.file)] or [0])
    commits = git('rev-list', '--reverse', spec, cwd=root).stdout.split()
    if not commits: raise Fail(f'no commits in {spec}')
    series = (pd / 'series').read_text() if (pd / 'series').exists() else ''
    if series and not series.endswith('\n'): series += '\n'
    made = []
    for c in commits:
        text = git('format-patch', '--binary', '--zero-commit', '--no-signature', '--no-numbered', '--stdout', f'{c}^..{c}', '--', *VENDORED,
                   *(f':(exclude){o}' for o in (*OWN, *(g for g, _ in GENERATED))), cwd=root, binary=True).stdout.decode(errors='surrogateescape')
        if not re.search(r'(?m)^diff --git ', text):
            say(f'skipped {c[:10]}: no change under the vendored paths'); continue
        files = sorted({f for m in re.finditer(r'(?m)^diff --git a/(\S+) b/(\S+)$', text) for f in m.groups()})
        hits = chain_hits(files, root)
        if hits:
            raise Fail(f'{c[:10]} touches the shader chain or the tool pins ({", ".join(hits)}): patches must not change them (patches/README.md, Patch policy)')
        head, sep, rest = text.partition('\n---\n')
        add = []
        for key, val in (('Upstream-Status', a.status), ('Reason', a.reason), ('Issue', a.issue)):
            if not re.search(r'(?m)^' + key + ':', head): add.append(f'{key}: {val}')
        if add: head = head.rstrip('\n') + '\n\n' + '\n'.join(add) + '\n'
        text = head + sep + rest
        subj = re.search(r'(?m)^Subject: (?:\[PATCH[^\]]*\] )?(.*)$', text).group(1)
        n += 1
        name = f'{n:04d}-{slug(subj)}.patch'
        (pd / name).write_bytes(text.encode(errors='surrogateescape'))
        series += name + '\n'; made.append(name)
    (pd / 'series').write_text(series)
    if made: (root / FORK_PATCHES).write_text(fork_patch_list(load(root)))   # the new patch is carried from now on
    for m in made: say('wrote patches/' + m)
    if made and any('TODO' in x for x in (a.reason, a.issue)):
        say('Fill in Reason and Issue in the new patch headers, then run scripts/patches.py check.')
    return 0


def resolve_patch(patches, spec):
    hits = [i for i, p in enumerate(patches) if spec in (p.name, p.file) or p.file.startswith(spec + '-')]
    if len(hits) != 1: raise Fail(f'--into {spec}: {"no such patch" if not hits else "ambiguous"} (patches.py status lists them)')
    return hits[0]


def owner_of(path, patches, into):
    """Index of the patch that takes a changed file, or a reason string. A file some patch touches goes to the last one that
    does (later patches then apply on top of it unchanged); a file no patch touches goes to the one patch that touches files
    in its nearest folder, if there is exactly one."""
    if into is not None: return into
    own = [i for i, p in enumerate(patches) if path in p.files]
    if own: return own[-1]
    d = os.path.dirname(path)
    while d:
        near = sorted({i for i, p in enumerate(patches) if any(os.path.dirname(f) == d for f in p.files)})
        if len(near) == 1: return near[0]
        if near: return 'ambiguous: patches ' + ', '.join(patches[i].name for i in near) + f' all touch {d}/'
        d = os.path.dirname(d)
    return 'no patch touches its folder'


def cmd_absorb(a):
    root = a.root
    patches = load(root)
    sha = resolve((root / '.upstream-ref').read_text().strip(), root)
    into = resolve_patch(patches, a.into) if a.into else None
    gen = {o for o, _ in GENERATED}
    with Scratch(root, sha, a.tmp) as s:
        applied, landed, conflicts = apply_series(s.dir, patches)
        if conflicts or landed: raise Fail('the series does not apply cleanly to the pin; run `patches.py check` first')
        generate(s.dir)
        want = tree_files(s.dir)
    have = local_files(root)
    changed = [p for p in sorted(set(want) | set(have)) if want.get(p) != have.get(p)]
    sel = []
    for x in a.paths:
        rel = os.path.relpath(os.path.realpath(x), root).replace(os.sep, '/')
        if rel == '..' or rel.startswith('../'): raise Fail(f'{x} is outside the checkout')
        sel.append('' if rel == '.' else rel)
    if '' in sel: sel = []   # "." is the whole tree
    if sel: changed = [p for p in changed if any(p == x or p.startswith(x + '/') for x in sel)]
    changed = [p for p in changed if p not in gen]
    if not changed:
        say('absorb: nothing to fold in (the vendored files match pin + series)')
        return cmd_check(a)
    chain = chain_hits(changed, root)
    if chain: raise Fail(f'{", ".join(chain)}: patches must not change the shader chain or the tool pins (patches/README.md, Patch policy)')
    plan, unclear = {}, []
    for f in changed:
        o = owner_of(f, patches, into)
        if isinstance(o, str): unclear.append(f'  {f}: {o}')
        else: plan.setdefault(o, []).append(f)
    if unclear:
        raise Fail('cannot tell which patch takes:\n' + '\n'.join(unclear) + '\nname it with `absorb --into <patch> <paths>` (patches.py status lists the patches)')
    ident = ('-c', 'user.name=patches.py', '-c', 'user.email=patches@localhost', '-c', 'commit.gpgsign=false', '-c', 'core.autocrlf=false')
    with Scratch(root, sha, a.tmp) as s:
        wt, new = s.dir, {}
        for i, p in enumerate(patches):
            before = git('rev-parse', 'HEAD^{tree}', cwd=wt).stdout
            r = am(wt, p)
            if r.returncode:
                raise Fail(f'{p.file} no longer applies after absorbing into an earlier patch ({(r.stderr or r.stdout).strip()[-300:]}); name a later patch with --into')
            if git('rev-parse', 'HEAD^{tree}', cwd=wt).stdout == before:
                raise Fail(f'{p.file} would be empty after absorbing into an earlier patch (its change is already there); name that patch with --into. No patch was changed')
            if i not in plan: continue
            for f in plan[i]:
                if f in have:
                    (wt / f).parent.mkdir(parents=True, exist_ok=True)
                    (wt / f).write_bytes((root / f).read_bytes()); (wt / f).chmod(0o755 if have[f][0] == '100755' else 0o644)
                    git('add', '--', f, cwd=wt)
                else: git('rm', '-q', '-f', '--', f, cwd=wt)
            git(*ident, 'commit', '-q', '--amend', '--no-edit', '--allow-empty', cwd=wt)
            if git('diff', '--quiet', 'HEAD^', 'HEAD', cwd=wt, check=False).returncode == 0:
                raise Fail(f'absorbing {", ".join(plan[i])} would leave {p.file} empty (a full revert of that patch); delete the patch and its line in patches/series instead. No patch was changed')
            new[i] = git('format-patch', '--binary', '--zero-commit', '--no-signature', '--no-numbered', '--stdout', '-1', 'HEAD', cwd=wt, binary=True).stdout
    for i, text in new.items():
        patches[i].path.write_bytes(text)
        say(f'{patches[i].file}: absorbed ' + ', '.join(plan[i]))
    return cmd_check(a)


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
    ap.add_argument('--tmp', help='folder for the scratch worktree (default $PATCHES_TMP, else the system temporary folder)')
    sub = ap.add_subparsers(dest='cmd', required=True)
    s = sub.add_parser('apply'); s.add_argument('--ref', help='upstream commit (default: .upstream-ref)'); s.set_defaults(f=cmd_apply)
    s = sub.add_parser('bump'); s.add_argument('--to', required=True, help='the new upstream commit'); s.add_argument('--dry', action='store_true', help='change nothing, report every conflict'); s.set_defaults(f=cmd_bump)
    s = sub.add_parser('refresh'); s.add_argument('worktree'); s.add_argument('--to', required=True); s.set_defaults(f=cmd_refresh)
    s = sub.add_parser('export'); s.add_argument('rev', help='a commit or a range')
    s.add_argument('--status', default='pending'); s.add_argument('--reason', default='TODO: why the fork carries this'); s.add_argument('--issue', default='TODO: LNPANDY/NX2Apple#<n>'); s.set_defaults(f=cmd_export)
    s = sub.add_parser('absorb', help='fold direct edits of vendored files into the patches that touch them')
    s.add_argument('paths', nargs='*', help='files or folders to fold in (default: every difference)')
    s.add_argument('--into', help='the patch that takes new files no patch touches yet (name or number)'); s.set_defaults(f=cmd_absorb)
    sub.add_parser('status').set_defaults(f=cmd_status)
    sub.add_parser('check').set_defaults(f=cmd_check)
    a = ap.parse_args(argv)
    a.root = Path(a.repo).resolve()
    try:
        return a.f(a)
    except Fail as e:
        print(f'patches.py: {e}', file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
