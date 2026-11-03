#!/usr/bin/env python3
"""A game engine archive (.nxgame): one game's support, taken from an nxnative engine repository, for the Mac launcher to build a game
its own engine does not support yet.

The archive is a ZIP:
  manifest.json                     the game (title ID, name, registered update versions), the engine it was made against, the commits,
                                    the SHA-256 of every other file
  engine.patch                      the game's changes to shared engine files (git diff --binary), absent when there are none
  game/dm/games/<TitleID>/...       the game's folder at HEAD

Where the changes come from: the commits of the current branch of the engine repository (engine/ of this clone, or --engine PATH) that
are on no remote branch and not on `main` or `nx2apple` (the branch `tools/engine.py sync` builds). The commit they sit on is the base.
Docs, tests and the files sync generates are left out: a player's build reads none of them. The diff may not touch another game's
folder: an archive holds one game.

Usage (Python 3.9+, stdlib and git):
  python3 tools/game_archive.py <TitleID> [--engine PATH] [--out FILE] [--name TEXT] [--author TEXT] [--notes TEXT] [--allow-dirty]
  python3 tools/game_archive.py --show FILE      print the manifest of an archive and check its files
"""
import argparse
import hashlib
import importlib
import json
import os
import re
import stat
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
E = importlib.import_module('engine')   # tools/engine.py: the pin, the stamp, engine_id, ZIP_TIME
P = E.P                                 # tools/patches.py: clean_env, GENERATED

REPO = E.REPO
FORMAT = 1
EXTENSION = '.nxgame'
EXCLUDED_BRANCHES = ('main', 'nx2apple')    # never the game's branch, and their commits are never the game's
GENERATED_FILES = tuple(out for out, _ in P.GENERATED) + ('dm/fork_patches.txt',)   # what sync writes in its last commit
TITLE_ID = re.compile(r'[0-9A-F]{16}')


Fail = P.Fail


def say(msg=''):
    print(msg, flush=True)


def git(*a, cwd, check=True, binary=False):
    r = subprocess.run(['git', *a], cwd=cwd, capture_output=True, text=not binary, env=P.clean_env())
    if check and r.returncode:
        err = r.stderr if not binary else r.stderr.decode(errors='replace')
        raise Fail(f'git {" ".join(a)} failed: {err.strip()[-1500:]}')
    return r


def out(*a, cwd):
    return git(*a, cwd=cwd).stdout.strip()


# ---- the repository ----

def normalize_url(url):
    """github.com/owner/repo in lower case from the https, ssh and scp forms, without .git or a trailing /. Other URLs as they are,
    trimmed the same way."""
    u = url.strip().rstrip('/')
    if u.endswith('.git'): u = u[:-4]
    m = re.match(r'^(?:[a-z+]+://)?(?:[^@/]+@)?([^/:]+)[:/](.+)$', u, re.I)
    if not m: return u
    return f'{m.group(1).lower()}/{m.group(2)}'


def remote_urls(repo):
    """{remote name: normalized fetch URL} of a repository."""
    r = git('remote', '-v', cwd=repo, check=False)
    urls = {}
    for line in r.stdout.splitlines():
        parts = line.split()
        if len(parts) >= 3 and parts[2] == '(fetch)': urls[parts[0]] = normalize_url(parts[1])
    return urls


def reference_urls():
    """The remotes an nxnative repository shares with this clone's engine/, upstream's URL among them."""
    urls = {normalize_url(E.UPSTREAM_URL)}
    eng = E.engine_dir(REPO)
    if (eng / '.git').exists(): urls |= set(remote_urls(eng).values())
    return urls


def check_nxnative(eng):
    """The remote of `eng` that this clone's engine/ has too. Stops when `eng` is not an nxnative repository."""
    if not eng.is_dir(): raise Fail(f'{eng} is not a folder')
    top = git('rev-parse', '--show-toplevel', cwd=eng, check=False)
    if top.returncode or Path(top.stdout.strip()).resolve() != eng:
        raise Fail(f'{eng} is not the root of a git repository')
    missing = [n for n in ('dm', 'scripts', 'AGENTS.md') if not (eng / n).exists()]
    if missing: raise Fail(f'not an nxnative repository: {eng} has no {", ".join(missing)}')
    refs = reference_urls()
    shared = [name for name, url in sorted(remote_urls(eng).items()) if url in refs]
    if not shared:
        raise Fail(f'not an nxnative repository: none of the remotes of {eng} is one of this clone\'s engine/ '
                   f'({", ".join(sorted(refs))}). Add one, e.g. git -C "{eng}" remote add upstream {E.UPSTREAM_URL}')
    return shared[0]


def current_branch(eng):
    r = git('symbolic-ref', '--short', '-q', 'HEAD', cwd=eng, check=False)
    b = r.stdout.strip()
    if r.returncode or not b: raise Fail('HEAD is detached: check out a branch made for the game\'s commits (git switch -c <name>)')
    if b in EXCLUDED_BRANCHES:
        raise Fail(f'the current branch is {b}: make a branch for the game\'s commits (git switch -c <name>) and commit them there')
    return b


def dirty_files(eng):
    return [l[3:] for l in git('status', '--porcelain', '--untracked-files=all', cwd=eng).stdout.splitlines() if l.strip()]


def game_commits(eng):
    """(base, [(hash, subject)] oldest first): the commits of HEAD on no remote branch and not on main or nx2apple, and the one they sit on."""
    excl = [f'refs/heads/{b}' for b in EXCLUDED_BRANCHES if git('rev-parse', '--verify', '-q', f'refs/heads/{b}', cwd=eng, check=False).returncode == 0]
    lines = out('rev-list', '--reverse', '--parents', 'HEAD', '--not', *excl, '--remotes', cwd=eng).splitlines()
    if not lines: return None, []
    rows = [l.split() for l in lines]
    if any(len(r) != 2 for r in rows):
        raise Fail('the branch has a merge commit or a root commit among the game\'s commits: rebase them onto one commit (git rebase)')
    ids = {r[0] for r in rows}
    base = rows[0][1]
    for r in rows[1:]:
        if r[1] not in ids: raise Fail('the game\'s commits do not follow one another: rebase them onto one commit (git rebase)')
    commits = [(h, out('log', '-1', '--format=%s', h, cwd=eng)) for h, _ in rows]
    return base, commits


# ---- what goes where ----

def classify(path, tid):
    """'game', 'patch', or why the file is left out ('generated', 'docs', 'tests'). Stops on another game's folder."""
    if path.startswith(f'dm/games/{tid}/'): return 'game'
    m = re.match(r'dm/games/([^/]+)/', path)
    if m:
        raise Fail(f'the commits change another game\'s folder ({path}): an archive holds one game. '
                   f'Move that change to its own branch, or drop it from these commits')
    if path in GENERATED_FILES: return 'generated'
    parts = path.split('/')
    if parts[0] in ('docs', 'ref') or path.endswith('.md'): return 'docs'
    if 'tests' in parts[:-1] or (parts[-1].startswith('test_') and parts[-1].endswith('.py')): return 'tests'
    return 'patch'


def changed_files(eng, base):
    """[(status, path)] of base..HEAD, renames as a delete and an add."""
    rows = []
    for line in out('diff', '--name-status', '--no-renames', base, 'HEAD', cwd=eng).splitlines():
        st, _, path = line.partition('\t')
        if path: rows.append((st, path))
    return rows


def game_files(eng, tid):
    """{path under dm/games/<tid>/: bytes} at HEAD, with the executable ones marked."""
    files = {}
    for line in git('ls-tree', '-r', '-z', 'HEAD', '--', f'dm/games/{tid}/', cwd=eng, binary=True).stdout.split(b'\0'):
        if not line: continue
        meta, path = line.split(b'\t', 1)
        mode, kind, obj = meta.decode().split()
        if kind != 'blob': continue
        data = git('cat-file', 'blob', obj, cwd=eng, binary=True).stdout
        files[path.decode()] = (data, mode == '100755')
    return files


def registered_updates(game_tsv):
    """The update versions game.tsv registers (`build\\tv<N>\\t...` lines)."""
    vs = []
    for line in game_tsv.splitlines():
        cols = line.split('\t')
        if len(cols) >= 2 and cols[0] == 'build':
            m = re.fullmatch(r'v(\d+)', cols[1])
            if m: vs.append(int(m.group(1)))
    return sorted(set(vs))


def tsv_value(game_tsv, key):
    for line in game_tsv.splitlines():
        cols = line.split('\t')
        if len(cols) >= 2 and cols[0] == key: return cols[1].strip()
    return ''


# ---- the base ----

def base_identity(eng, base, shared_remote):
    """What the launcher compares with its engine: engine_id when the base is the synced engine/ of this clone (exactly its
    tree), and the upstream commit the base contains: the newest of this clone's pin (.upstream-ref) and the shared remote's
    branches that is an ancestor of the base."""
    ident = {'commit': base, 'remote': remote_urls(eng).get(shared_remote, '')}
    try:
        pin, key = E.pin(REPO), E.stamp_key(REPO)
    except Fail:
        pin, key = '', ''
    if eng == E.engine_dir(REPO).resolve():
        st = E.read_stamp(eng)
        if key and st.get('head') == base and st.get('key') == key: ident['engine_id'] = E.engine_id(REPO)
    def contains(c): return git('merge-base', '--is-ancestor', c, base, cwd=eng, check=False).returncode == 0
    candidates = [pin] if pin and contains(pin) else []
    for ref in out('for-each-ref', '--format=%(refname)', f'refs/remotes/{shared_remote}/', cwd=eng).splitlines():
        r = git('merge-base', base, ref, cwd=eng, check=False)
        if r.returncode == 0 and r.stdout.strip(): candidates.append(r.stdout.strip())
    best = ''
    for c in candidates:
        if not best or (c != best and git('merge-base', '--is-ancestor', best, c, cwd=eng, check=False).returncode == 0): best = c
    if best: ident['pin'] = best
    return ident


# ---- writing ----

def sha256(data):
    return hashlib.sha256(data).hexdigest()


def slug(text):
    s = re.sub(r'[^A-Za-z0-9]+', '-', text).strip('-')
    return s[:60] or 'game'


def write_archive(path, manifest, entries):
    """entries: {archive path: (bytes, executable)}. manifest.json first, then the rest sorted; fixed times, so the same commits make the same bytes."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + '.part')
    with zipfile.ZipFile(tmp, 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as z:
        def put(name, data, exe=False):
            zi = zipfile.ZipInfo(name, E.ZIP_TIME)
            zi.create_system = 3
            zi.compress_type = zipfile.ZIP_DEFLATED
            zi.external_attr = (stat.S_IFREG | (0o755 if exe else 0o644)) << 16
            z.writestr(zi, data, compresslevel=6)
        put('manifest.json', (json.dumps(manifest, indent=2, ensure_ascii=False) + '\n').encode())
        for name in sorted(entries):
            data, exe = entries[name]
            put(name, data, exe)
    os.replace(tmp, path)


def make(a):
    tid = a.title_id.upper()
    if not TITLE_ID.fullmatch(tid): raise Fail(f'{a.title_id} is not a title ID (16 hexadecimal digits)')
    eng = Path(a.engine).expanduser().resolve() if a.engine else E.engine_dir(REPO).resolve()
    say(f'Engine repository: {eng}')
    say('  The game\'s changes are read from the commits of this repository (nxnative), not from NX2Apple: commit them there, on a branch of their own.')
    shared = check_nxnative(eng)
    branch = current_branch(eng)
    say(f'  nxnative: yes (remote {shared}). Branch: {branch}')

    dirty = dirty_files(eng)
    if dirty:
        listing = '\n'.join(f'    {f}' for f in dirty[:20]) + (f'\n    … and {len(dirty) - 20} more' if len(dirty) > 20 else '')
        if not a.allow_dirty:
            raise Fail(f'uncommitted changes in {eng}; they would not be in the archive:\n{listing}\n'
                       f'Commit them on {branch}, or pass --allow-dirty to leave them out')
        say(f'warning: uncommitted changes, left out of the archive:\n{listing}')

    if git('cat-file', '-e', f'HEAD:dm/games/{tid}', cwd=eng, check=False).returncode:
        raise Fail(f'dm/games/{tid}/ is not in HEAD of {eng}: commit the game\'s folder first')

    base, commits = game_commits(eng)
    if not commits:
        raise Fail(f'no commits of the game on {branch}: every commit of HEAD is on a remote branch or on {" or ".join(EXCLUDED_BRANCHES)}. '
                   f'Commit the game\'s changes in {eng} first')
    say(f'\nCommits ({len(commits)}, on {base[:12]}):')
    for h, s in commits: say(f'  {h[:12]} {s}')

    patch_paths, left_out = [], []
    for st, path in changed_files(eng, base):
        kind = classify(path, tid)
        if kind == 'patch': patch_paths.append(path)
        elif kind != 'game': left_out.append((kind, path))

    patch = git('diff', '--binary', '--no-renames', '--full-index', base, 'HEAD', '--', *patch_paths, cwd=eng, binary=True).stdout if patch_paths else b''
    files = game_files(eng, tid)
    game_tsv = files.get(f'dm/games/{tid}/game.tsv', (b'', False))[0].decode(errors='replace')
    if not game_tsv: say(f'warning: dm/games/{tid}/game.tsv is missing: the archive registers no update version')

    entries = {f'game/{p}': v for p, v in files.items()}
    if patch: entries['engine.patch'] = (patch, False)
    head_date = out('log', '-1', '--format=%cI', 'HEAD', cwd=eng)
    name = a.name or tsv_value(game_tsv, 'name') or tid
    manifest = {
        'format': FORMAT,
        'title_id': tid,
        'name': name,
        'updates': registered_updates(game_tsv),
        'base': base_identity(eng, base, shared),
        'head': out('rev-parse', 'HEAD', cwd=eng),
        'branch': branch,
        'commits': [{'hash': h, 'subject': s} for h, s in commits],
        'patched': patch_paths,
        'author': a.author or out('log', '-1', '--format=%an', 'HEAD', cwd=eng),
        'notes': a.notes or '',
        'created': head_date,
        'tool': 'tools/game_archive.py',
        'files': {p: sha256(d) for p, (d, _) in sorted(entries.items())},
    }

    say(f'\nGame folder: dm/games/{tid}/ ({len(files)} files)')
    if patch_paths:
        say(f'Shared engine files in engine.patch ({len(patch_paths)}):')
        for p in patch_paths: say(f'  {p}')
    else:
        say('Shared engine files: none (the archive holds the game\'s folder only)')
    if left_out:
        say(f'Left out ({len(left_out)}, a player\'s build reads none of them):')
        for kind, p in left_out: say(f'  {p} ({kind})')
    b = manifest['base']
    if 'engine_id' in b: say(f'Base engine: {b["engine_id"]} (the synced engine of this clone)')
    elif 'pin' in b: say(f'Base engine: upstream commit {b["pin"][:12]} (no engine_id: the launcher compares the upstream commit only)')
    else: say('warning: the base contains no commit of the shared remote: the launcher will always warn about the engine version')
    if not manifest['updates']: say('warning: game.tsv registers no update version')

    dest = Path(a.out) if a.out else Path.cwd() / f'{tid}-{slug(name)}{EXTENSION}'
    write_archive(dest, manifest, entries)
    say(f'\nWrote {dest} ({dest.stat().st_size:,} bytes, sha256 {sha256(dest.read_bytes())})')
    return 0


# ---- reading ----

def read_archive(path):
    """(manifest, problems): the problems are what the launcher would refuse."""
    problems = []
    with zipfile.ZipFile(path) as z:
        names = set(z.namelist())
        if 'manifest.json' not in names: return None, ['no manifest.json']
        m = json.loads(z.read('manifest.json'))
        if m.get('format') != FORMAT: problems.append(f'format {m.get("format")!r}, this tool reads {FORMAT}')
        if not TITLE_ID.fullmatch(str(m.get('title_id', ''))): problems.append(f'title_id {m.get("title_id")!r} is not a title ID')
        listed = m.get('files', {})
        for name, digest in listed.items():
            if name not in names: problems.append(f'{name}: listed, missing'); continue
            if sha256(z.read(name)) != digest: problems.append(f'{name}: SHA-256 does not match')
        for name in sorted(names - set(listed) - {'manifest.json'}):
            if not name.endswith('/'): problems.append(f'{name}: not listed in the manifest')
        prefix = f'game/dm/games/{m.get("title_id")}/'
        for name in listed:
            if name != 'engine.patch' and not name.startswith(prefix): problems.append(f'{name}: outside the game\'s folder')
    return m, problems


def show(path):
    m, problems = read_archive(path)
    if m is not None:
        b = m.get('base', {})
        say(f'{m.get("name")} ({m.get("title_id")}), format {m.get("format")}')
        say(f'  updates: {", ".join("v" + str(v) for v in m.get("updates", [])) or "none registered"}')
        say(f'  base: {b.get("engine_id") or b.get("pin") or "?"} (commit {b.get("commit", "?")[:12]})')
        say(f'  author: {m.get("author")}, made {m.get("created")}')
        say(f'  commits: {len(m.get("commits", []))}; patched files: {", ".join(m.get("patched", [])) or "none"}')
    for p in problems: say(f'problem: {p}')
    return 1 if problems else 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0], formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__)
    ap.add_argument('title_id', nargs='?', help='the base game\'s title ID, e.g. 0100DCD01F306000')
    ap.add_argument('--engine', help='the nxnative repository to read (default: engine/ of this clone)')
    ap.add_argument('--out', help=f'the archive to write (default: ./<TitleID>-<name>{EXTENSION})')
    ap.add_argument('--name', help='the game\'s name (default: `name` of its game.tsv)')
    ap.add_argument('--author', help='who made it (default: the author of HEAD)')
    ap.add_argument('--notes', help='a line for the player: what was tested')
    ap.add_argument('--allow-dirty', action='store_true', help='make the archive although the repository has uncommitted changes (they are left out)')
    ap.add_argument('--show', metavar='FILE', help='print the manifest of an archive and check its files')
    a = ap.parse_args(argv)
    try:
        if a.show: return show(a.show)
        if not a.title_id: ap.error('a title ID is needed')
        return make(a)
    except Fail as e:
        print(f'error: {e}', file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
