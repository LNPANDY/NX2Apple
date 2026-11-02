#!/usr/bin/env python3
"""Pin bump: the upstream commits that probably change what the front ends and the players depend on (LNPANDY/NX2Apple#464).

nxnative has no releases and no changelog. A bump takes many commits in (53 for v1.0.1), and nobody says which of them move the
shader chain, change a script message that a failure row matches, or rewrite a setting the launcher shows. This module reads the
commits between two pins and prints the ones that touch something we depend on, as a Markdown table with an empty `Handled`
column. It is a list of candidates, not a verdict: a person reads those commits and writes "handled" or an issue number.

The output is two tables. The first, "Likely matters to the front ends", has the commits that match any rule below except the last one,
with consecutive commits that move the shader chain folded into one row (every sha, the chain value before and after, the other reasons).
The second, a collapsed list, has the commits whose only match is a file that one of our patches changes: bump and sync already apply the
patches and fail on a conflict. A commit of the first table is not repeated in the second.

A commit is a candidate when it
  - has a `Breaking:` line or a "For front ends" section in its message (listed first),
  - touches the shader chain (dmsh_chain.h, dmsh_chain.lock) or own_compilers.py (a chain move or a tool requirement),
  - changes a row of docs/env_switches.tsv (removed or rewritten, a new row alone is no candidate), flagged when the variable is a
    `launch.set.<VAR>` key of the launcher (frontend/Sources/NXCore/Localization.swift, dm/launcher.json),
  - touches scripts/build_ipa_from_nsp.py (an argument, the setting block, an exit or an error text), or adds or removes a line
    with `[RED]` or one of the texts that the failure rows of frontend/Sources/NX2Apple/BuildFailure.swift match,
  - touches docs/frontends.md or dm/launcher.json, or a line that writes a JSON progress event or game.manifest.json,
  - touches a binary layout without a version (romfs_image.h, romfs_image.py, romfs.py),
  - or touches a source file that one of our patches in patches/*.patch changes (read from the `diff --git` headers; documents, tests
    and makefiles do not count).

The matching (find_candidates) is pure: commits in, rows out, no network and no files. The commits come from fetch_commits: the
local engine/ repository when it holds both pins, else `gh api` (compare, then one call per commit for its files). A test gives
find_candidates a fixture.

  python3 tools/bump_candidates.py --from OLD --to NEW      (or: python3 tools/engine.py candidates --to NEW)
"""
import argparse, json, os, re, subprocess, sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
UPSTREAM = 'seedds/nxnative'
LOCALIZATION = 'frontend/Sources/NXCore/Localization.swift'
LAUNCHER_JSON = 'dm/launcher.json'                 # in the engine, read from engine/ when it is there
BUILD_FAILURE = 'frontend/Sources/NX2Apple/BuildFailure.swift'

CHAIN = ('dmsh_chain.h', 'dmsh_chain.lock')        # compared by file name: the header is in dm/gfx/nvn, the lock in dm/gfx/tools
OWN_COMPILERS = 'own_compilers.py'
ENV_TSV = 'docs/env_switches.tsv'
NSP_SCRIPT = 'scripts/build_ipa_from_nsp.py'
INTERFACE_DOCS = ('docs/frontends.md', LAUNCHER_JSON)
LAYOUTS = ('romfs_image.h', 'romfs_image.py', 'romfs.py')   # the RomFS.img entry has no version field
TOOL_DIRS = ('scripts/', 'dm/tools/', 'dm/gfx/tools/', 'dm/ios/tools/')

# Changed lines of the NSP script that matter to a front end.
SCRIPT_LINES = (('an argument', re.compile(r'add_argument\(')),
                ('the setting block', re.compile(r'^[A-Z][A-Z0-9_]* = ')),
                ('an exit or an error text', re.compile(r'sys\.exit|SystemExit|BuildError|\bdie\(')))
EVENT_LINE = re.compile(r"""['"]ev['"]\s*:|\.event\(|\b_json\(""")
HOOK = 'patched: '   # a file one of our patches changes; find_candidates folds these into one entry
MANIFEST_LINE = re.compile(r'game\.manifest\.json')


# ---- the commits: the only code that touches the network or git ----

def gh_api(path):
    """One read-only call of the GitHub API through gh. The one place the network is used."""
    r = subprocess.run(['gh', 'api', path], capture_output=True, text=True)
    if r.returncode: raise RuntimeError(f'gh api {path}: {(r.stderr or r.stdout).strip().splitlines()[-1:] or "failed"}')
    return json.loads(r.stdout)


def _git(eng, *a):
    return subprocess.run(['git', *a], cwd=eng, capture_output=True, text=True)


def local_commits(eng, old, new):
    """The commits old..new from a repository that holds both ends, oldest first, or None when it does not."""
    eng = Path(eng)
    if not (eng / '.git').exists(): return None
    for sha in (old, new):
        if _git(eng, 'cat-file', '-e', f'{sha}^{{commit}}').returncode: return None
    if _git(eng, 'merge-base', '--is-ancestor', old, new).returncode: return None   # a pin is fetched one commit deep: new has no parent here
    r = _git(eng, 'rev-list', '--reverse', f'{old}..{new}')
    if r.returncode: return None
    out = []
    for sha in r.stdout.split():
        msg = _git(eng, 'show', '-s', '--format=%B', sha).stdout
        d = _git(eng, 'show', '--format=', '--no-renames', '-U0', sha).stdout
        files = []
        for chunk in re.split(r'(?m)^diff --git ', d)[1:]:
            m = re.match(r'a/(\S+) b/(\S+)', chunk)
            if m: files.append({'filename': m.group(2), 'patch': chunk.split('\n@@', 1)[1] if '\n@@' in chunk else ''})
        out.append({'sha': sha, 'message': msg, 'files': files})
    return out


def api_commits(old, new, api=None):
    """The same from the GitHub API: the compare gives the commits, one call per commit gives its files and their diffs."""
    api = api or gh_api
    cmp = api(f'repos/{UPSTREAM}/compare/{old}...{new}?per_page=100')
    shas = [c['sha'] for c in cmp['commits']]
    if cmp.get('total_commits', len(shas)) > len(shas):
        raise RuntimeError(f'the compare lists {len(shas)} of {cmp["total_commits"]} commits: split the range')
    out = []
    for c in cmp['commits']:
        full = api(f'repos/{UPSTREAM}/commits/{c["sha"]}?per_page=100')
        out.append({'sha': c['sha'], 'message': c['commit']['message'],
                    'files': [{'filename': f['filename'], 'patch': f.get('patch', '')} for f in full.get('files', [])]})
    return out


def fetch_commits(old, new, eng=None, api=None):
    """Local git when engine/ holds both pins (the commits between them are rarely there: a pin is fetched one commit deep), else the API."""
    got = local_commits(eng, old, new) if eng else None
    return got if got is not None else api_commits(old, new, api or gh_api)


# ---- what we depend on, read from this checkout ----

def patch_paths(root):
    """{path: [patch numbers]} for every path that a patch in patches/ changes (the `diff --git` headers)."""
    paths = {}
    for f in sorted((Path(root) / 'patches').glob('*.patch')):
        for m in re.finditer(r'(?m)^diff --git a/(\S+) b/(\S+)$', f.read_text(errors='replace')):
            for name in set(m.groups()):
                if name != '/dev/null' and f.name[:4] not in paths.setdefault(name, []): paths[name].append(f.name[:4])
    return paths


def launch_vars(root):
    """The variables the launcher offers: `launch.set.<VAR>` in Localization.swift and in the engine's launcher.json."""
    found = set()
    for rel in (LOCALIZATION, 'engine/' + LAUNCHER_JSON):
        p = Path(root) / rel
        if p.is_file():
            found.update(re.findall(r'launch\.set\.([A-Z][A-Z0-9_]*)', p.read_text(errors='replace')))
    return found


def failure_fragments(root):
    """The texts that the failure rows match (the third field of each row in BuildFailure.swift), as compiled regexes."""
    p = Path(root) / BUILD_FAILURE
    if not p.is_file(): return []
    out = []
    for m in re.finditer(r'\(\s*"[\w.]+"\s*,\s*\.\w+\s*,\s*"((?:[^"\\]|\\.)*)"\s*\)', p.read_text(errors='replace')):
        raw = m.group(1).replace('\\\\', '\\')   # Swift's "\\[" is the regex \[
        try: out.append(re.compile(raw))
        except re.error: out.append(re.compile(re.escape(raw)))
    return out


def context(root):
    root = Path(root)
    return {'patch_paths': patch_paths(root), 'launch_vars': launch_vars(root), 'fragments': failure_fragments(root)}


# ---- the matching: pure ----

def changed_lines(patch):
    """(removed, added) lines of a diff, without the +++ and --- headers."""
    rem, add = [], []
    for l in (patch or '').splitlines():
        if l.startswith('---') or l.startswith('+++'): continue
        if l.startswith('-'): rem.append(l[1:])
        elif l.startswith('+'): add.append(l[1:])
    return rem, add


def _env_rows(lines):
    rows = {}
    for l in lines:
        name = l.split('\t', 1)[0].strip()
        if re.fullmatch(r'[A-Z][A-Z0-9_]*', name): rows[name] = l
    return rows


def env_changes(patch):
    """(removed, changed) variable names of an env_switches.tsv diff. A name only added is new, not a candidate."""
    rem, add = changed_lines(patch)
    old, new = _env_rows(rem), _env_rows(add)
    return sorted(set(old) - set(new)), sorted(n for n in old if n in new and old[n] != new[n])


def breaking(message):
    return bool(re.search(r'(?mi)^\s*Breaking:|^\s*#*\s*For front ends\b', message))


def _src(name):
    return not ('/tests/' in name or name.startswith('tests/') or name.endswith(('.md', '.tsv')))


def _hookable(name):
    """A file whose change can break a patch: not a document, a test or a makefile (those are in many patches and say little)."""
    return not (name.endswith(('.md', '.tsv', 'Makefile')) or '/tests/' in name)


def file_reasons(f, ctx):
    """[(why)] for one changed file of a commit."""
    name, patch = f['filename'], f.get('patch') or ''
    base = name.rsplit('/', 1)[-1]
    why = []
    if base in CHAIN: why.append(CHAIN_WHY)
    if base == OWN_COMPILERS: why.append('tool requirement or chain input (own_compilers.py): a new minimum, or a rebuild')
    if name == ENV_TSV:
        if not patch: why.append('env_switches.tsv changed (no diff to read)')
        removed, changed = env_changes(patch)
        shown = ctx['launch_vars']
        for kind, names in (('removed', removed), ('rewritten', changed)):
            if names: why.append(f'env row {kind}: ' + ', '.join(n + (' (launcher shows it)' if n in shown else '') for n in names))
    if name == NSP_SCRIPT:
        rem, add = changed_lines(patch)
        if not patch: why.append('NSP script changed (no diff to read)')
        for label, rx in SCRIPT_LINES:
            if any(rx.search(l) for l in rem + add): why.append(f'NSP script: {label}')
    if name in INTERFACE_DOCS: why.append(f'{name} changed: the interface the launchers read')
    if base in LAYOUTS: why.append(f'{base}: a binary layout without a version')
    if _hookable(name) and name in ctx['patch_paths']: why.append(HOOK + f'{base} ({", ".join(ctx["patch_paths"][name][:3])})')
    if patch and _src(name):
        rem, add = changed_lines(patch)
        both = rem + add
        if name != NSP_SCRIPT and any(EVENT_LINE.search(l) for l in both) and name.endswith('.py'): why.append('a JSON event is written or changed')
        if any(MANIFEST_LINE.search(l) for l in both): why.append('game.manifest.json is written or read here')
        if name != NSP_SCRIPT and name.startswith(TOOL_DIRS) and any('[RED]' in l for l in both): why.append('a [RED] message changed: a failure row may not match it')
        hits = [rx.pattern for rx in ctx['fragments'] if any(rx.search(l) for l in both)]
        if hits: why.append('text a failure row matches changed: ' + '; '.join(hits[:2]))
    return why


CHAIN_WHY = 'shader chain moves: every game built with the old chain is rebuilt (#449)'


def chain_values(files):
    """(before, after) of DMSH_CHAIN from the diff of dmsh_chain.h in a commit's files, or None."""
    for f in files:
        if f['filename'].rsplit('/', 1)[-1] == 'dmsh_chain.h':
            old = re.search(r'^-#define DMSH_CHAIN "([0-9a-f]+)"', f.get('patch') or '', re.M)
            new = re.search(r'^\+#define DMSH_CHAIN "([0-9a-f]+)"', f.get('patch') or '', re.M)
            if old and new: return old.group(1), new.group(1)
    return None


def find_candidates(commits, ctx):
    """One row per commit that touches something we depend on, in range order, the ones with a Breaking: line first:
    {sha, title, files, why, breaking, likely, patched, chain, chain_only (the chain moves)}. `likely` is false when the only match is a file one of our
    patches changes (`patched`: [file (patch numbers)]), the second table. Grouping into table rows is group_rows."""
    rows = []
    for c in commits:
        files, whys, patched = [], [], []
        for f in c['files']:
            w = file_reasons(f, ctx)
            hooks = [x[len(HOOK):] for x in w if x.startswith(HOOK)]
            rest = [x for x in w if not x.startswith(HOOK)]
            patched += hooks
            if rest:
                files.append(f['filename'])
                whys += [x for x in rest if x not in whys]
        brk = breaking(c['message'])
        if brk: whys.insert(0, 'the message says Breaking: or has a "For front ends" section')
        if files or brk or patched:
            rows.append({'sha': c['sha'], 'title': c['message'].splitlines()[0] if c['message'] else '', 'files': files, 'why': whys, 'breaking': brk,
                         'likely': bool(files or brk), 'patched': patched, 'chain': chain_values(c['files']),
                         'chain_only': CHAIN_WHY in whys and not brk})
    return sorted(rows, key=lambda r: not r['breaking'])   # sorted is stable


def group_rows(rows):
    """Table 1: the likely rows, where consecutive commits that move the shader chain become one row with every sha, the chain value before the
    first and after the last, the number of moves and the other reasons of the members."""
    out = []
    for r in (r for r in rows if r['likely']):
        r = dict(r, shas=[r['sha']])
        if r['chain_only'] and out and out[-1]['chain_only']:
            g = out[-1]
            g['shas'].append(r['sha'])
            g['files'] = sorted(set(g['files']) | set(r['files']))
            g['why'] += [w for w in r['why'] if w not in g['why']]
            g['chain'] = (g['chain'][0], r['chain'][1]) if g['chain'] and r['chain'] else None
        else:
            out.append(r)
    for g in out:
        if g['chain_only']:
            n = len(g['shas'])
            if n > 1: g['title'] = f'Shader chain moves {n} times'
            val = f' from `{g["chain"][0]}` to `{g["chain"][1]}`' if g['chain'] else ''
            g['why'] = [f'DMSH_CHAIN{val}: every game built with the old chain is rebuilt (#449)'] + [w for w in g['why'] if w != CHAIN_WHY]
    return out


# ---- the output ----

def _cell(s):
    return s.replace('|', '\\|').replace('\n', ' ')


def format_tables(rows, old, new, total):
    t1 = group_rows(rows)
    t2 = [r for r in rows if not r['likely']]
    n1 = sum(len(g['shas']) for g in t1)
    out = [f'## Candidate commits, `{old[:12]}...{new[:12]}`',
           '',
           f'This is a list of candidates, not a verdict. {n1 + len(t2)} of the {total} commits touch something the front ends or the players depend on. '
           f'A commit that is in neither table can still matter: read the compare when in doubt. Write "handled" or an issue number in the last column of the first table.',
           '',
           f'Upstream: https://github.com/{UPSTREAM}/compare/{old[:12]}...{new[:12]}',
           '',
           f'### Likely matters to the front ends ({len(t1)} rows, {n1} commits)',
           '']
    if t1:
        out += ['| Commit | Title | Files | Why | Handled |', '|---|---|---|---|---|']
        for r in t1:
            files = r['files'][:4]
            more = f' (+{len(r["files"]) - 4} more)' if len(r['files']) > 4 else ''
            shas = ', '.join(f'`{s[:8]}`' for s in r['shas'])
            out.append(f'| {shas} | {_cell(r["title"][:90])} | {_cell(", ".join("`" + f + "`" for f in files) + more)} | {_cell("; ".join(r["why"][:4]))} | |')
    else:
        out.append('No commit of the range matches.')
    out += ['', '<details>', f'<summary>Touches files our patches change ({len(t2)} commits)</summary>', '',
            '`tools/engine.py bump` and `sync` already apply the patches and fail on a conflict, so these need no reading, unless a patch did not conflict '
            'but its behavior might have shifted.', '']
    if t2:
        out += ['| Commit | Title | Patched file (patches) |', '|---|---|---|']
        for r in t2:
            p = r['patched']
            out.append(f'| `{r["sha"][:8]}` | {_cell(r["title"][:90])} | {_cell(", ".join(p[:3]) + (f" (+{len(p) - 3} more)" if len(p) > 3 else ""))} |')
    else:
        out.append('None.')
    return '\n'.join(out + ['', '</details>', ''])


def report(root, old, new, eng=None, api=None):
    """The whole table for old..new as text. Never raises for a missing network: the bump must not fail on it.
    NX2APPLE_NO_CANDIDATES=1 skips the lookup (the engine tests, which run on local upstreams)."""
    try:
        if os.environ.get('NX2APPLE_NO_CANDIDATES'): raise RuntimeError('NX2APPLE_NO_CANDIDATES is set')
        commits = fetch_commits(old, new, eng, api)
    except Exception as e:
        return f'## Candidate commits\n\nNot made: {e}\n\nRun `python3 tools/engine.py candidates --from {old[:12]} --to {new[:12]}` when `gh` can reach GitHub.\n'
    return format_tables(find_candidates(commits, context(root)), old, new, len(commits))


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--from', dest='old', help='the old pin (default: .upstream-ref)')
    ap.add_argument('--to', required=True, help='the new upstream commit (full id)')
    ap.add_argument('--repo', default=str(REPO))
    a = ap.parse_args(argv)
    root = Path(a.repo)
    old = a.old or (root / '.upstream-ref').read_text().strip()
    print(report(root, old, a.to, root / 'engine'))
    return 0


if __name__ == '__main__':
    sys.exit(main())
