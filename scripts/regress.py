#!/usr/bin/env python3
# A regression harness for changes to the translation chain, the host or the tools, run on every game this Mac has a build of (GitHub issue #272: one chain and one host serve every
# profile, each contributor owns only some games, and CI has no game files and no Metal 4). It compares a BASELINE revision with a CANDIDATE and writes a report that holds only numbers,
# hashes, shader keys, normalized [RED] texts and timings (no screenshots, game data or keys), so it can go into a pull request.
#
# Usage: python3 scripts/regress.py check    [--baseline REV] [--candidate REV|worktree] [--quick] [--games ID,...] [--no-smoke] [--out DIR]
#        python3 scripts/regress.py baseline [--rev REV] [--quick] [--games ID,...] [--runs N]
#        python3 scripts/regress.py chain    [--baseline REV] [--candidate REV|worktree] [--games ID,...]          (the static checks only, no game runs)
#        python3 scripts/regress.py usage    [--rev REV] [--games ID,...] [--write]                            (a game's usage manifest, dm/games/<id>/usage.tsv: dm/tools/usage.py)
#        python3 scripts/regress.py impact   <base>..<head> | <commit>                                         (the games whose manifests hold what the change touches)
#        python3 scripts/regress.py list                                                                       (the games found, their routes, stored baselines and last green chain)
#        python3 scripts/regress.py capture  [--rev REV] [--games ID,...] [--repeat N]                     (each route's capture frame, and its replay noise)
#        python3 scripts/regress.py replay   [--baseline REV] [--candidate REV|worktree] [--games ID,...] [--repeat N]   (those captures replayed by two revisions)
#   check / baseline --record: for each repository profile with status PASS or CHANGED and successful boot runs (no run_failures, even known ones) write dm/games/<id>/validated.tsv of
#   this checkout: the chain it was last green on, one row per mode (quick, full), the latest of each. `key <TAB> value` rows under a comment header; the value is `field=value` words:
#     quick <TAB> chain=157e1b96c8da commit=4f2a9c01d3+dirty date=2026-10-27 machine=Mac14,6 macos=26.1
#   chain = DMSH_CHAIN of the candidate (dm/gfx/nvn/dmsh_chain.h; for `baseline`, of the revision recorded), commit = its short SHA (+dirty: uncommitted changes in the worktree), date = UTC day,
#   machine / macos = report.json's machine. No game data, paths, keys or hashes of game content. A red game keeps its row (it shows the last green chain), a game without a route or a run with
#   --no-smoke writes nothing. Derived build profiles do not validate repository profiles. Without --record nothing in dm/games changes. `list` prints the rows and whether the chain is the current one.
#   The report is saved before recording, so a metadata write failure leaves the test evidence intact. Commit the file with the pull request.
#   REV: any git revision of this repository; worktree = this checkout as it is, uncommitted and untracked files included. check: baseline = the merge base of HEAD and main,
#   candidate = worktree; baseline: --rev main. Each revision is checked out once into <root>/trees/<id> (git worktree), and the chain, host and rewriter come from there.
#   --root (REGRESS_ROOT; no default, required except for impact): source trees and public reports; game-derived files stay in <NSP folder>/<id>-work/regress/.
#   --games-dir (REGRESS_GAMES; no default, required except for impact): the NSP folders "<name> [<title ID>]", each with the
#   <id>_build of scripts/build_ipa_from_nsp.py --platform mac. A game takes part when it has that build and, for the runs, a route dm/games/<id>/smoke.tsv (read from this checkout).
#   REGRESS_SKIP=ID,...: games left out unless --games names them (a game another agent works on).
#   --lock FILE (DM_MEASURE_LOCK): the measuring lock bench.py --lock shares, held only while a game runs.
#
# What it checks, per game:
# 1. Chain (static): the game's shaders translated by each revision's chain (dmsh_build.py through own_compilers.py; a Vulkan game: vk_shaders.py), compared shader by shader: built or failed
#    (newly failing by the rule of dm/gfx/tools/shader_regressions.py, which the NSP script applies to one game's previous build; a new shader that fails is listed apart),
#    the SHA-256 of the MSL (<key>_b.metal), of the reflection (<key>_b.json without its chain fields) and of the variant libraries (_bf, _bv, _bp, _bg*). A build is kept per chain version,
#    shader package, profile inputs and compilers (<NSP folder>/<id>-work/regress/chain/<key>/), so a revision whose chain did not change costs nothing, and dmsh_build.py uses the build's own shader cache (DMSH_CAS), so MSL
#    that did not change is not compiled again. Then the vertex / pixel interface of every pipeline base pso_offline.py would put into the pipeline archive (shader_pairs.tsv and
#    pso_pairs.tsv): a pixel shader input [[user(locnN)]] the vertex shader does not write, or writes with another type, makes metal-tt refuse the whole archive (GitHub issue #283).
# 2. Smoke (runtime): the game in the Mac host (window, no audio), from a copy of the route's save, with the route's buttons, under a watchdog: the frame it must reach, crash (exit status,
#    the host's CRASH line, a DiagnosticReports file), hang (no frame for `hang` seconds once frames came; before stopping the host the harness asks for its state dump, DM_CTL
#    "dump", into the log and samples every host thread into the run folder's hang_sample.txt), the prepare step's time, [RED] lines (numbers, addresses and paths normalized; a shader
#    the chain build does not hold counts as one kind, MISSING_LIB, whatever its name) that the baseline did not print, frame times (bench.py's DM_NVN_TSV rows; a Vulkan / GL game: presents counted from the log), peak memory footprint, and perceptual hashes of
#    screenshots at fixed times. The full mode first runs the pipeline prebuild (the host's DM_PSO_PREBUILD=tool, the step the Mac app's "Preparing pipelines" runs) under a watchdog
#    and starts the game on its archive; --quick runs the chain checks and a 60 s boot without the prebuild (DM_PSO_PREBUILD=0).
#    A route, dm/games/<id>/smoke.tsv, key <TAB> value lines: save (a folder relative to the NSP folder, `run` = <id>_build/run/save, `new` = empty), keys (DM_KEYS), secs (full run),
#    quick (quick run, default 60), reach (<frame>@<seconds>: the frame number the game must have presented by then), window (<start> <TAB> <length>: the frame-time window),
#    shots (comma-separated seconds), hang (seconds without a frame, default 20), prebuild (on / off: the full mode's prebuild, default on for an NVN game), capture (the frame `capture` records).
# 4. Replay (`replay`, an NVN game with a capture; GPU, no game run): the game's current capture (DM_NVN_CAPTURE, made by `capture` from the route's `capture` frame with the wall clock,
#    DM_PSO_HYBRID=0 and no prebuild) replayed --repeat times by each revision's dm/gfx/tests/nvn_replay, with that revision's shader libraries (DM_MSL_DIR, DM_NVN_SHMAP on the replayer's
#    command line, so a capture made on another chain still replays while every program's bindings match). `capture` stores the frame's noise beside it in
#    <NSP folder>/<id>-work/regress/captures/ (<tree>-f<frame>.nvncap and .json, current.json names the one in use): the most pixels any of --repeat fresh replays differs from the live frame.
#    A candidate replay beyond the tolerance (TOL replay_noise_x times the noise; none for an exact capture) while the baseline's stay within it is a REGRESSION, a capture a revision cannot replay
#    (record layout or shader bindings changed: nvn_replay exits 2) is an ERROR asking for a new capture. report.json: games.<id>.replay = {"capture": {frame, tree, chain, noise_px, date},
#    "baseline" / "candidate": {"exit", "secs", "busy", "red", "replays": [{"digest" (16 hex), "same", "pixels", "largest", "box"}]}}; capture: games.<id>.capture.
# 3. Baselines: `baseline` records the runs of a revision in <NSP folder>/<id>-work/regress/baselines/<commit>/; `check` compares with the one of the baseline revision and records it first when there is none.
#
# report.json (beside report.md, in --out, default <root>/reports/<date-time>-<command>/):
#   {"schema": "nxnative-regress/1", "command", "mode": "quick"|"full", "status", "exit", "started", "secs", "machine": {model, gpu, macos, xcode},
#    "baseline": {"rev", "sha"}, "candidate": {"rev", "sha", "dirty"},
#    "games": {<title ID>: {"name", "status", "reasons": [text], "known": [text], "secs": {"chain", "smoke"},
#       "chain": {"kind": "nvn"|"vk", "baseline": BUILD, "candidate": BUILD, "newly_failing": [{"key", "status", "error"}], "added_failing": [same],
#                 "newly_passing": [key],
#                 "changed": {"msl", "reflection", "variants", "shaders", "keys": [key, at most 200]}, "added": n, "removed": n,
#                 "interface": {"baseline": n, "candidate": n, "new": [PAIR], "known": [PAIR, at most 50]}},
#       "smoke": {"route": {...}, "baseline": [RUN], "candidate": [RUN], "diff": {"new_red": [{"text", "count"}], "missing_libs": [baseline, candidate median per run], "shots": {<s>: {"dhash_bits", "rgb_diff", "baseline_noise"}},
#                 "fps_p50_change_pct", "frame_p99_change_pct", "peak_footprint_change_pct", "prepare_change_s", "prebuild_change_s"}}}}}
#   BUILD = {"key", "chain", "inputs", "total", "ok", "failed", "secs" (the build's time, 0 when reused), "failed_by_status": {status: n}}
#   PAIR = {"vs", "entry", "ps", "missing": [locnN], "type": ["locnN vs-type/ps-type"]}
#   RUN = {"exit": code or -signal or null (stopped by the harness), "crash": {"line", "type", "signal"} or null, "hang_at_s", "hang_sample" (file name or null), "hang_dump" (the log holds the host's state dump), "first_frame_s", "max_frame", "reached",
#          "prepare_s", "prebuild": {"secs", "pairs", "built", "archived", "failed", "done", "hang"}, "fps", "frame_p50", "frame_p99", "frame_max", "dropped", "over_budget",
#          "peak_footprint_mb", "red": {normalized text: count}, "shots": {<s>: {"dhash"}}, "secs", "modules", "host"}
#   status per game, worst first: ERROR (the harness could not check it), NEW-FAIL (something that worked in the baseline fails: a shader, the interface check, a crash, a hang, the frame
#   not reached), REGRESSION (new [RED] lines, a screenshot beyond the tolerance, frame time, memory or prepare time worse beyond it), CHANGED (MSL or numbers differ, nothing worse),
#   PASS. "known" lists failures the baseline has too (they do not fail the check).
# Exit status: 0 = no regression, 1 = a regression (NEW-FAIL or REGRESSION) in some game, 2 = a harness error (and no regression found).
import argparse, collections, concurrent.futures as cf, ctypes, datetime, fcntl, hashlib, importlib.util, json, os, re, shutil, signal, struct, subprocess, sys, time, traceback
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent


def load_module(name, path):   # a module from a file (another script, or a tool of a revision's tree)
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None: raise ImportError(f'cannot load {path}')
    mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
    return mod


bench = load_module('bench', REPO / 'scripts/bench.py')
shader_regressions = load_module('shader_regressions', REPO / 'dm/gfx/tools/shader_regressions.py')
usage = load_module('usage', REPO / 'dm/tools/usage.py')   # usage manifests and change impact (regress.py usage / impact)
# Where they are depends on the machine (a drive with room for the trees and the games' NSP folders): set with --root / --games-dir or REGRESS_ROOT / REGRESS_GAMES, checked in main
ROOT = Path(os.environ.get('REGRESS_ROOT', ''))
GAMES = Path(os.environ.get('REGRESS_GAMES', ''))
HOST_DIRS = ('dm/host', 'dm/gfx', 'dm/gfx/nvn', 'dm/gfx/nvn/include', 'dm/gfx/tex', 'dm/gfx/vk', 'dm/gfx/gl')   # as build_ipa_from_nsp.py: the host's sources and headers
REWRITER = ('dm/tools/patch_nso.py', 'dm/tools/nso.py', 'dm/tools/nso_code.py', 'dm/tools/nso_asm.py', 'dm/tools/nso_match.py', 'dm/tools/sdk_patches.py', 'dm/tools/ue_cvar.py', 'dm/tools/ue_malloc.py', 'dm/tools/ue_region.py', 'dm/tools/loader_census.py')
HEAVY_EXE = {'clang', 'make', 'xcodebuild', 'ld', 'ld64', 'swift-frontend', 'dotnet', 'metal', 'metal-tt', 'air-tt', 'applegpu-nt', 'dmsh_xlate', 'spirv-cross'}   # jobs that skew a measurement
HEAVY_PY = r'(dmsh_build|shader_split|own_compilers|patch_nso|vk_shaders)\.py'   # (the shared measuring rule)
# Tolerances, from runs of one revision against itself (docs/development.md, The regression harness)
TOL = {'fps_pct': 10.0, 'p99_pct': 30.0, 'p99_ms': 4.0, 'footprint_pct': 15.0, 'footprint_mb': 300.0, 'prepare_s': 10.0, 'prepare_x': 1.5, 'prebuild_x': 1.5, 'prebuild_s': 30.0,
       'dhash_bits': 12, 'rgb_diff': 12.0,
       'replay_noise_x': 2.0,
       'missing_libs_x': 2.0, 'missing_libs': 500}   # a replay may differ from the live frame in this many times the pixels capture measured (a few replays see less than the whole spread: Breath of the Wild 154, then 157)


class HarnessError(Exception):
    pass


VALIDATED = 'validated.tsv'
VALIDATED_HEAD = ('# The chain this game was last green on in scripts/regress.py check / baseline --record (one row per mode, the latest of each). Written by the harness, committed with the pull request.\n'
                  '# mode <TAB> chain=<DMSH_CHAIN> commit=<short SHA>[+dirty] date=<UTC day> machine=<model> macos=<version>. No game data.\n')
GREEN = ('PASS', 'CHANGED')   # the statuses of a game that did not get worse (finish: no regression exit for them)


def chain_version(root=None):   # DMSH_CHAIN of a checkout (dm/gfx/nvn/dmsh_chain.h)
    m = re.search(r'#define\s+DMSH_CHAIN\s+"([^"]+)"', (Path(root or REPO) / 'dm/gfx/nvn/dmsh_chain.h').read_text())
    return m.group(1) if m else None


def read_validated(f):   # {mode: {field: value}}
    out = {}
    if Path(f).is_file():
        for line in Path(f).read_text().splitlines():
            if not line.strip() or line.startswith('#') or '\t' not in line: continue
            mode, val = line.split('\t', 1)
            out[mode] = dict(w.split('=', 1) for w in val.split() if '=' in w)
    return out


def record_validated(a, rep, tree, games):
    """--record: a game that is green after a boot run gets its row for the report's mode in dm/games/<id>/validated.tsv of this checkout; every other game keeps what it had"""
    mode = rep.get('mode')
    if not getattr(a, 'record', False) or mode not in ('quick', 'full'): return []
    v, hw = chain_version(tree.path), rep.get('machine') or {}
    row = {'chain': v, 'commit': tree.commit[:10] + ('+dirty' if tree.dirty else ''), 'date': datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%d'),
           'machine': (hw.get('model') or 'unknown').replace(' ', '_'), 'macos': (hw.get('macos') or 'unknown').replace(' ', '_')}
    written = []
    profiles = {g.id for g in games if not g.derived}
    for gid, gr in rep['games'].items():
        d = REPO / 'dm/games' / gid
        sm = gr.get('smoke') or {}
        runs = sm.get('candidate' if rep['command'] == 'check' else 'baseline') or []
        # PASS means no new regression: a crash or missed frame shared with the baseline is still a failed boot.
        if gr['status'] not in GREEN or not runs or any(run_failures(r, sm['route']) for r in runs): continue
        if gid not in profiles or not d.is_dir(): continue
        rows = read_validated(d / VALIDATED); rows[mode] = row
        try:
            (d / VALIDATED).write_text(VALIDATED_HEAD + ''.join(f'{m}\t' + ' '.join(f'{k}={x}' for k, x in rows[m].items()) + '\n' for m in ('quick', 'full') if m in rows))
        except OSError as e:
            raise HarnessError(f'{gid}: could not record {VALIDATED} (the regression report was saved): {e}') from e
        written.append(gid); say(f'  {gid}: recorded green on chain {v} ({mode}) in dm/games/{gid}/{VALIDATED}')
    return written


def say(msg):
    print(msg, flush=True)


def sh(cmd, **kw):
    kw.setdefault('capture_output', True); kw.setdefault('text', True)
    return subprocess.run([str(c) for c in cmd], **kw)


def git(*a, cwd=REPO):
    r = sh(['git', *a], cwd=cwd)
    if r.returncode: raise HarnessError(f'git {" ".join(a)}: {r.stderr.strip()[-300:]}')
    return r.stdout.strip()


def sha256_file(p, h=None):
    h = h or hashlib.sha256()
    with open(p, 'rb') as f:
        while chunk := f.read(1 << 20): h.update(chunk)
    return h


def digest(paths, extra=b'', root=None):   # path-independent names and bytes; use relative names when a tree's directory layout matters
    h = hashlib.sha256(extra)
    for p in paths:
        h.update((Path(p).relative_to(root).as_posix() if root else Path(p).name).encode() + b'\0')
        if Path(p).is_file(): sha256_file(p, h)
        else: h.update(b'missing')
        h.update(b'\0')
    return h.hexdigest()


def disk_free_gb(path='/System/Volumes/Data'):
    st = os.statvfs(path); return st.f_bavail * st.f_frsize / 1e9


def clean_metal_cache():   # Metal's idle build folders, which every host run adds to the internal disk (scripts/clean_metal_cache.py)
    m = load_module('clean_metal_cache', REPO / 'scripts/clean_metal_cache.py')
    try: n, size, _, _ = m.clean(say=say)
    except OSError as e: say(f'[RED] Metal build folders not cleaned: {e}'); return
    if n: say(f'Metal build folders: {n} idle ones removed, {size / 1e9:.1f} GB')


def check_disk(min_gb, clean=False):
    """clean: remove Metal's idle build folders first (at the start of a run); they are removed anyway when the disk is under the limit"""
    free = disk_free_gb()
    if clean or free < min_gb: clean_metal_cache(); free = disk_free_gb()
    if free < min_gb: raise HarnessError(f'the internal disk has {free:.1f} GB free, under {min_gb} GB (Metal caches land there): stopped')
    return free


# ---------------------------------------------------------------- revisions

class Tree:
    """One revision checked out into <root>/trees/<id>: a commit, or this checkout's working tree (a stash commit of its tracked changes, its untracked files copied over)"""
    def __init__(self, rev):
        self.rev, self.dirty, untracked = rev, False, []
        if rev == 'worktree':
            head = git('rev-parse', 'HEAD')
            status = git('status', '--porcelain', '--untracked-files=all')
            self.sha = (git('stash', 'create') or head) if status else head
            untracked = [u for u in git('ls-files', '--others', '--exclude-standard', '-z').split('\0') if u]
            self.dirty = bool(status)
            self.id = self.sha[:12] + ('-u' + digest([REPO / u for u in untracked], root=REPO)[:8] if untracked else '')
            self.commit = head
        else:
            self.sha = git('rev-parse', '--verify', rev + '^{commit}'); self.id = self.sha[:12]; self.commit = self.sha
        self.path = ROOT / 'trees' / self.id
        if not (self.path / '.git').exists():
            shutil.rmtree(self.path, ignore_errors=True); self.path.parent.mkdir(parents=True, exist_ok=True)
            sh(['git', 'worktree', 'prune'], cwd=REPO)
            git('worktree', 'add', '--detach', str(self.path), self.sha)
            for u in untracked:
                (self.path / u).parent.mkdir(parents=True, exist_ok=True); shutil.copy2(REPO / u, self.path / u)

    def py(self, code, env):   # a Python snippet run in the tree (its own modules)
        r = sh([sys.executable, '-c', code], cwd=self.path, env=env)
        if r.returncode: raise HarnessError(f'{self.id}: {r.stderr.strip()[-400:]}')
        return r.stdout.strip()

    def describe(self):
        return {'rev': self.rev, 'sha': self.commit, **({'dirty': True, 'snapshot': self.sha} if self.dirty else {})}


# ---------------------------------------------------------------- games

def game_root(g):
    return g.folder / f'{g.id}-work' / 'regress'


class Game:
    def __init__(self, folder, build):
        self.folder, self.build, self.id = folder, build, build.name[:16].upper()
        self.name = re.sub(r'\s*\[[0-9A-Fa-f]{16}\]\s*$', '', folder.name)
        self.patched = bench.newest(build.glob('patched_v*'))
        self.ver = self.patched.name.removeprefix('patched_') if self.patched else None
        self.kind = 'nvn' if (build / 'shader/pkg').is_dir() else 'vk' if (build / 'shader/vk').is_dir() else 'gl' if (build / 'shader/gl').is_dir() else None
        # The build's own profile runs instead of dm/games' only when it is derived (the NSP script's <id>.derived.key beside it: a version the game's profile was not brought up
        # on) or the game has no profile here (a provisional one). A provisional profile the NSP script left from before the game's profile was added would test its guesses
        own = build / 'profile' / self.id
        self.derived = (own / 'game.tsv').is_file() and ((build / 'profile' / f'{self.id}.derived.key').is_file() or not (REPO / 'dm/games' / self.id / 'game.tsv').is_file())

    def romfs(self):
        r = bench.rfs.source(self.build / 'extract' / self.ver)
        return r if r.is_dir() else bench.rfs.source(bench.newest(self.build.glob('extract/v*')))

    def route(self):
        f = REPO / 'dm/games' / self.id / 'smoke.tsv'
        return read_route(f) if f.is_file() else None

    def env(self, tree):   # shader tools write profile tables: use a copy in the game's work folder, keeping the revision tree and the player's build untouched
        env = dict(os.environ, DM_GAME=self.id)
        prof = self.profile_dir(tree)
        env.update(DM_GAMES_DIR=str(prof.parent), DM_GAMES_FIRST='1')
        if self.kind == 'nvn' and not (prof / 'pso_pairs.tsv').is_file():
            pairs = self.build / 'shader/pso_pairs.tsv'
            if pairs.is_file(): env['DM_PSO_PAIRS'] = str(pairs)
        return env

    def profile_dir(self, tree):
        src = (self.build / 'profile' if self.derived else tree.path / 'dm/games') / self.id
        key = digest(sorted(p for p in src.glob('*') if p.is_file() and p.name != VALIDATED))[:16]   # validated.tsv records a result about the profile, it is not an input of it
        dst = game_root(self) / 'profiles' / key / self.id
        if not (dst / 'game.tsv').is_file(): shutil.copytree(src, dst, ignore=shutil.ignore_patterns(VALIDATED))
        return dst

    def shader_roots(self):
        roots = [self.romfs()]
        capture = self.build / 'extract' / self.ver / 'vk_capture'
        if capture.is_dir(): roots.append(capture)
        return roots


def read_route(f):
    r = {'save': 'run', 'keys': '', 'secs': 90.0, 'quick': 60.0, 'reach': None, 'window': None, 'shots': [], 'hang': 20.0, 'prebuild': 'on', 'capture': None}
    for ln in f.read_text().splitlines():
        if not ln.strip() or ln.startswith('#'): continue
        c = ln.split('\t'); k, v = c[0].strip(), [x.strip() for x in c[1:]]
        if not v: raise HarnessError(f'{f}: {k} has no value')
        if k in ('secs', 'quick', 'hang'): r[k] = float(v[0])
        elif k == 'reach': n, _, t = v[0].partition('@'); r[k] = (int(n), float(t))
        elif k == 'window': r[k] = (float(v[0]), float(v[1]))
        elif k == 'shots': r[k] = sorted(float(x) for x in v[0].split(',') if x)
        elif k == 'capture': r[k] = int(v[0])
        elif k in ('save', 'keys', 'prebuild'): r[k] = v[0]
        else: raise HarnessError(f'{f}: unknown key {k!r}')
    return r


def find_games(want=None):
    found = {}
    for folder in sorted(GAMES.iterdir()) if GAMES.is_dir() else []:
        if not folder.is_dir(): continue
        for b in folder.glob('*_build'):
            if re.fullmatch(r'[0-9A-Fa-f]{16}_build', b.name) and (b / 'tools/dmhost').is_file():
                g = Game(folder, b)
                if g.patched and g.kind: found[g.id] = g
    for s in [x.strip().upper() for x in os.environ.get('REGRESS_SKIP', '').split(',') if x.strip()]:
        if not want or s not in [w.upper() for w in want]: found.pop(s, None)
    if want:
        missing = [w for w in want if w.upper() not in found]
        if missing: raise HarnessError(f'no Mac build of {", ".join(missing)} under {GAMES} (found: {", ".join(found) or "none"})')
        return [found[w.upper()] for w in want]
    return list(found.values())


# ---------------------------------------------------------------- chain: build and manifest

def dotnet_env(env):
    if env.get('DOTNET_ROOT'): return env
    for d in (GAMES.parent / 'tools/dotnet', Path('/usr/local/share/dotnet'), Path.home() / '.dotnet', Path('/opt/homebrew/opt/dotnet/libexec')):
        if (d / 'dotnet').exists(): return dict(env, DOTNET_ROOT=str(d), PATH=f'{d}{os.pathsep}{env.get("PATH", "")}')
    return env


def toolchain_fp():
    out = []
    for cmd in (['spirv-cross', '--version'], ['xcrun', '-sdk', 'macosx', 'metal', '--version'], ['xcrun', '-sdk', 'macosx', '--show-sdk-build-version']):
        try: r = sh(cmd); out.append(r.stdout + r.stderr)
        except FileNotFoundError: out.append('missing')   # spirv-cross on PATH: only revisions before the in-repo build (dm/gfx/tools/spirv_cross_bin) run it; a tree's own is in its chain key
    return hashlib.sha256('\0'.join(out).encode()).hexdigest()


def chain_key(tree, g, tools):
    if g.kind == 'nvn':
        v, inp = json.loads(tree.py("import sys, json; sys.path.insert(0, 'dm/gfx/tools'); import dmsh_chain as c; g = c.load_game(); print(json.dumps([c.version(), c.inputs(g)]))", g.env(tree)))
        side = digest([tree.path / 'dm/gfx/tools' / f for f in ('c1_guard.py', 'cb_extent.py', 'dmsh_mtlcache.py', 'own_compilers.py', 'tool_lock.py')] + [tree.path / 'dm/games/game.py'])
        pkg = g.build / 'shader/pkg'
        sources = digest(sorted(p for p in pkg.rglob('*') if p.is_file()), root=pkg)
        pairs = g.profile_dir(tree) / 'pso_pairs.tsv'
        if not pairs.is_file(): pairs = g.build / 'shader/pso_pairs.tsv'
        side += digest([pairs])
    elif g.kind == 'vk':
        v, inp = digest([tree.path / 'dm/gfx/tools/vk_shaders.py'])[:12], g.ver
        side = ''
        vk = load_module('regress_vk_sources', REPO / 'dm/gfx/tools/vk_shaders.py')
        sources = digest(sorted(Path(p) for root in g.shader_roots() for p in vk.spirv_files(root)), root=g.build)
    else: raise HarnessError(f'{g.id}: the chain check does not cover {g.kind} games yet')
    sc = tree.path / 'dm/gfx/tools/spirv_cross_bin/spirv-cross'
    if sc.is_file():   # earlier revisions use PATH, already covered by tools; pinned revisions also honor SPIRV_CROSS
        env = dotnet_env(g.env(tree))
        selected = env.get('SPIRV_CROSS', str(sc))
        side += digest([Path(shutil.which(selected, path=env.get('PATH')) or selected)])
    return v, inp, f'{g.kind}-{v}-{inp}-{hashlib.sha256((tools + side + sources).encode()).hexdigest()[:16]}'


def chain_build(tree, g, a):
    """The game's shaders built into its NSP work folder's regress/chain/<key>/ (reused when its manifest is there): → manifest"""
    v, inp, key = chain_key(tree, g, a.tools_fp)
    out = game_root(g) / 'chain' / key
    out.parent.mkdir(parents=True, exist_ok=True)
    with open(out.parent / f'{key}.lock', 'w') as lk:   # one build per chain key: another regress.py building the same one (another session, the same game) is waited for, then reused
        try: fcntl.flock(lk, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            say(f'  {g.id}: another process is building chain {key}: waiting for it'); fcntl.flock(lk, fcntl.LOCK_EX)
        return chain_build_locked(tree, g, a, v, inp, key, out)


def chain_build_locked(tree, g, a, v, inp, key, out):
    jobs = a.jobs
    mf = out / 'manifest.json'
    if mf.is_file():
        m = json.loads(mf.read_text()); m['secs'] = 0
        # The archive planner and depth mode can change without changing the translation chain.
        if g.kind == 'nvn': m['interface'] = interface_check(tree, g, out)
        return m, out
    out.mkdir(parents=True, exist_ok=True); tmp = game_root(g) / 'tmp'; tmp.mkdir(exist_ok=True)
    env = dotnet_env(g.env(tree)); env.update(WORK=str(tmp), TMPDIR=str(tmp) + '/', J=str(jobs))
    t0 = time.time(); log = out / 'build.log'
    done = (out / 'built.ok').is_file()   # a build whose outputs are complete (a run stopped while hashing, or a build made by hand); its manifest is made again
    if g.kind == 'nvn':
        tools_dir = tree.path / 'dm/gfx/tools'
        cas = g.build / 'shader/cache/cas'
        env.update(XLATE=str(tools_dir / 'dmsh_xlate_bin/dmsh_xlate'), DMSH_CAS=str(cas if cas.is_dir() else game_root(g) / 'cas'))
        entry = tools_dir / ('own_compilers.py' if (tools_dir / 'own_compilers.py').is_file() else 'dmsh_build.py')
        lib = out / f'b-{v}'
        if not done:
            say(f'  {g.id}: chain {v} (inputs {inp}) of {tree.id}: translating the shaders ({jobs} workers) → {out}')
            rc, paused = run_heavy([sys.executable, entry, g.build / 'shader/pkg', out], log, tree.path, env, a, f'{g.id} shader build'); t0 += paused
            if rc or not (lib / '_b_build.json').is_file():
                raise HarnessError(f'{g.id}: dmsh_build.py of {tree.id} failed (exit {rc}); last lines of {log}:\n' + ''.join(collections.deque(open(log, errors='replace'), maxlen=8)))
            prof = out / 'profile'; prof.mkdir(exist_ok=True)   # the tables the host reads beside the shader map, as this build made them
            for src in g.profile_dir(tree).glob('*.tsv'): shutil.copyfile(src, prof / src.name)
            (out / 'built.ok').write_text(f'{tree.id}\n')
        say(f'  {g.id}: hashing the outputs of chain {v}')
        shaders = nvn_manifest(lib, jobs)
    else:
        say(f'  {g.id}: vk_shaders.py {v} of {tree.id} → {out}')
        msl = out / 'msl'; shutil.rmtree(msl, ignore_errors=True); msl.mkdir()
        # vk_shaders.py writes its MSL into a temporary folder; this keeps it (the script itself is unchanged)
        wrap = ('import sys, runpy, tempfile, contextlib\n'
                f'@contextlib.contextmanager\ndef keep(*a, **k): yield {str(msl)!r}\n'
                'tempfile.TemporaryDirectory = keep\n'
                f'sys.argv = {[str(tree.path / "dm/gfx/tools/vk_shaders.py"), *map(str, g.shader_roots()), str(out)]!r}\n'
                'runpy.run_path(sys.argv[0], run_name="__main__")\n')
        rc, paused = run_heavy([sys.executable, '-c', wrap], log, tree.path, env, a, f'{g.id} shader build'); t0 += paused
        shaders = vk_manifest(msl, out / 'vk/vk_shaders.tsv', rc == 0, log)
    st = collections.Counter(s['st'] for s in shaders.values())
    m = {'key': key, 'kind': g.kind, 'chain': v, 'inputs': inp, 'tree': tree.id, 'game': g.id, 'total': len(shaders), 'ok': st['ok'], 'failed': len(shaders) - st['ok'],
         'failed_by_status': {k: n for k, n in st.items() if k != 'ok'}, 'build_secs': round(time.time() - t0, 1), 'shaders': shaders}
    if g.kind == 'vk': m['build_failed'] = rc != 0
    if g.kind == 'nvn': m['interface'] = interface_check(tree, g, out)
    mf.write_text(json.dumps(m, indent=0))
    m['secs'] = m['build_secs']
    return m, out


def refl_hash(p):
    try: j = json.loads(Path(p).read_bytes())
    except (OSError, ValueError): return None
    for k in ('chain', 'chain_metal', 'chain_compiler'): j.pop(k, None)
    return hashlib.sha256(json.dumps(j, sort_keys=True).encode()).hexdigest()[:16]


def nvn_manifest(lib, jobs):
    """{key: {st, err, msl, refl, var}} from dmsh_build.py's report and outputs"""
    files = collections.defaultdict(list)
    for n in os.listdir(lib):
        m = re.match(r'([0-9a-f]{16})_b', n)
        if m: files[m.group(1)].append(n)
    rows = json.loads((lib / '_b_build.json').read_text())
    def one(r):
        k = r['key']; names = sorted(files.get(k, ()))
        e = {'st': r['st'], **({'err': r['err'][:160]} if r['st'] != 'ok' else {})}
        if (lib / f'{k}_b.metal').is_file(): e['msl'] = sha256_file(lib / f'{k}_b.metal').hexdigest()[:16]
        if (lib / f'{k}_b.json').is_file(): e['refl'] = refl_hash(lib / f'{k}_b.json')
        var = [n for n in names if n not in (f'{k}_b.metal', f'{k}_b.json', f'{k}_b.metallib')]
        if var:
            h = hashlib.sha256()
            for n in var: h.update(n[16:].encode()); sha256_file(lib / n, h)
            e['var'] = h.hexdigest()[:16]
        return k, e
    with cf.ThreadPoolExecutor(max(2, jobs)) as ex: return dict(ex.map(one, rows))


def vk_manifest(msl, table, ok, log):
    keys = {}
    for p in sorted(msl.glob('*.metal')):
        keys[p.stem] = {'st': 'ok' if ok else 'library failed', 'msl': sha256_file(p).hexdigest()[:16]}
        if not ok: keys[p.stem]['err'] = (list(collections.deque(open(log, errors='replace'), maxlen=1)) or [''])[0].strip()[:160]
    if table.is_file():
        for ln in table.read_text().splitlines():
            c = ln.split('\t')
            if len(c) >= 3 and c[0] in keys: keys[c[0]]['refl'] = hashlib.sha256(ln.encode()).hexdigest()[:16]
    return keys


# ---------------------------------------------------------------- the vertex / pixel interface of the archive's pipeline bases (GitHub issue #283)

STRUCT = re.compile(r'struct\s+(\w+)\s*\{(.*?)\n\};', re.S)
FIELD = re.compile(r'([\w:<>, ]+?)\s+(\w+)(?:\s*\[\d+\])?\s*\[\[([^\]]*)\]\]\s*;')


def msl_io(src, entry, stage):
    """{locnN: type} of an entry point's [[user(locnN)]] outputs (vertex: its return struct) or stage inputs (fragment: its [[stage_in]] struct); None when the entry is not found"""
    m = re.search(r'\b(vertex|fragment)\s+(\w+)\s+' + re.escape(entry) + r'\s*\(', src)
    if not m: return None
    if stage == 'vs': name = m.group(2)
    else:
        sig = src[m.end():src.find('\n{', m.end())]
        n = re.search(r'(\w+)\s+\w+\s*\[\[stage_in\]\]', sig)
        name = n.group(1) if n else 'void'
    if name == 'void': return {}
    body = next((b for n, b in STRUCT.findall(src) if n == name), '')
    out = {}
    for ty, _, attrs in FIELD.findall(body):
        u = re.search(r'user\((locn\d+)\)', attrs)
        if u: out[u.group(1)] = ty.strip()
    return out


def interface_check(tree, g, out):
    """The shader pairs of shader_pairs.tsv and pso_pairs.tsv whose pixel shader reads a [[user(locnN)]] input that the vertex shader does not write, or writes with another type,
    among the pipeline bases pso_offline.py would put into the archive (the tree's pso_offline.plan, run on those pairs only: it reads every library): metal-tt refuses such a
    pipeline, and one refused pipeline fails the whole archive (GitHub issue #283). The entry points are pso_offline's: the reflection's entry (entry_z for a near = 0 game)"""
    lib = next(out.glob('b-*')); chain = lib.name[2:]
    prof = g.profile_dir(tree)
    pairs = [prof / 'shader_pairs.tsv', prof / 'pso_pairs.tsv' if (prof / 'pso_pairs.tsv').is_file() else g.build / 'shader/pso_pairs.tsv']
    po = tree.path / 'dm/gfx/tools/pso_offline.py'
    if not po.is_file(): return {'checked': 0, 'note': 'no pso_offline.py in this revision', 'bad': []}
    mod = load_module('pso_offline_' + tree.id.replace('-', '_'), po)
    todo = mod.read_pairs(mod.pair_text([p for p in pairs if p.is_file()]))
    zero = depth_zero(g, tree)
    keys = {k for pr in todo for k in pr}
    def load(k):
        try: return k, json.loads((lib / f'{k}_b.json').read_bytes()), (lib / f'{k}_b.metal').read_text(errors='replace')
        except (OSError, ValueError): return k, None, None
    with cf.ThreadPoolExecutor(8) as ex: got = {k: (j, src) for k, j, src in ex.map(load, keys)}
    cache, suspects = {}, {}
    def io(k, entry, stage):
        if (k, entry) not in cache: cache[k, entry] = msl_io(got[k][1], entry, stage) if got[k][1] else None
        return cache[k, entry]
    checked = 0
    for vk, fk in todo:
        vj, fj = got[vk][0], got[fk][0]
        if not vj or not fj or vj.get('chain') != chain or fj.get('chain') != chain: continue
        ve = vj['entry_z'] if zero and vj.get('entry_z') else vj.get('entry'); fe = fj.get('entry') or 'main0'
        vo, fi = io(vk, ve, 'vs'), io(fk, fe, 'ps'); checked += 1
        if vo is None or fi is None: continue
        miss = sorted((l for l in fi if l not in vo), key=lambda l: int(l[4:]))
        ty = [f'{l} {vo[l]}/{fi[l]}' for l in sorted(fi, key=lambda l: int(l[4:])) if l in vo and vo[l] != fi[l]]
        if miss or ty: suspects[vk, fk] = {'vs': vk, 'entry': ve, 'ps': fk, 'missing': miss, 'type': ty}
    bases, _, _ = mod.plan(lib, chain, list(suspects), zero) if suspects else ([], [], {})
    planned = {(vl[:16], fl[:16]) for vl, _, fl, _ in bases}
    return {'checked': checked, 'bad': [x for pr, x in suspects.items() if pr in planned], 'not_in_archive': len(suspects) - len(planned & suspects.keys())}


def chain_diff(b, c):
    bs, cs = b['shaders'], c['shaders']
    common = bs.keys() & cs.keys()
    rows = lambda m: [{'key': k, 'st': v['st'], 'err': v.get('err', '')} for k, v in sorted(m.items())]
    # the rule of shader_regressions.py, which the NSP script runs after each shader build of one game: ok in the earlier build, not ok now; a new key does not count there
    nf = [{'key': k, 'status': st, 'error': err} for k, st, err in shader_regressions.lost(rows(bs), rows(cs))]
    af = [{'key': k, 'status': cs[k]['st'], 'error': cs[k].get('err', '')} for k in sorted(cs.keys() - bs.keys()) if cs[k]['st'] != 'ok']
    npass = [k for k in sorted(common) if bs[k]['st'] != 'ok' and cs[k]['st'] == 'ok']
    ch = collections.Counter(); keys = []
    for k in sorted(common):
        if bs[k]['st'] != 'ok' or cs[k]['st'] != 'ok': continue
        d = [f for f, label in (('msl', 'msl'), ('refl', 'reflection'), ('var', 'variants')) if bs[k].get(f) != cs[k].get(f)]
        for f in d: ch[{'msl': 'msl', 'refl': 'reflection', 'var': 'variants'}[f]] += 1
        if d: keys.append(k)
    out = {'newly_failing': nf, 'added_failing': af, 'newly_passing': npass, 'changed': {'msl': ch['msl'], 'reflection': ch['reflection'], 'variants': ch['variants'], 'shaders': len(keys), 'keys': keys[:200]},
           'added': len(cs.keys() - bs.keys()), 'removed': len(bs.keys() - cs.keys())}
    bi, ci = b.get('interface'), c.get('interface')
    if bi is not None or ci is not None:
        sig = lambda x: (x['vs'], x['entry'], x['ps'])
        old = {sig(x) for x in (bi or {}).get('bad', [])}
        cb = (ci or {}).get('bad', [])
        out['interface'] = {'baseline': len((bi or {}).get('bad', [])), 'candidate': len(cb), 'checked': (ci or {}).get('checked'),
                            'new': [x for x in cb if sig(x) not in old], 'known': [x for x in cb if sig(x) in old][:50]}
    return out


def build_summary(m):
    return {k: m.get(k) for k in ('key', 'chain', 'inputs', 'total', 'ok', 'failed', 'failed_by_status', 'build_failed')} | {'secs': m.get('secs', 0)}


# ---------------------------------------------------------------- host and rewritten modules of a revision

def host_for(tree, g, jobs):
    srcs = [p for d in HOST_DIRS for p in sorted((tree.path / d).iterdir()) if p.is_file() and p.suffix in ('.c', '.m', '.h', '.S', '.inc')]
    key = digest(srcs + [tree.path / 'dm/host/Makefile', g.profile_dir(tree) / 'game.tsv', tree.path / 'dm/games/game.py'], g.id.encode())[:16]
    dst = game_root(g) / 'host' / key / 'dmhost'
    if dst.is_file(): return dst, key, 0
    t0 = time.time(); env = g.env(tree); hd = tree.path / 'dm/host'
    say(f'  {g.id}: building the host of {tree.id}')
    log = game_root(g) / 'tmp' / f'host-{tree.id}-{g.id}.log'; log.parent.mkdir(parents=True, exist_ok=True)
    with open(log, 'w') as f:
        for target in (['gen/vpx/libvpx.a', f'-j{jobs}'], ['dmhost']):
            r = subprocess.run(['make', f'GAME={g.id}', *target], cwd=hd, env=env, stdout=f, stderr=subprocess.STDOUT)
            if r.returncode: raise HarnessError(f'{g.id}: the host of {tree.id} does not build (see {log})')
    dst.parent.mkdir(parents=True, exist_ok=True)
    if sh(['cp', '-c', hd / 'dmhost', dst]).returncode: shutil.copy2(hd / 'dmhost', dst)
    return dst, key, round(time.time() - t0, 1)


def rewriter_key(tree):
    return digest([tree.path / f for f in REWRITER] + sorted((tree.path / 'dm/games').glob('*/patches.py')))[:16]


def modules_for(tree, g, rewrite, jobs):
    """The rewritten modules a run takes: the build's (rewrite False), or the tree's patch_nso.py on the build's extracted modules, cached by the rewriter's files"""
    if not rewrite: return g.patched, 'build'
    key = rewriter_key(tree)
    dst = game_root(g) / 'patched' / key / g.patched.name
    if (dst / '.done').is_file(): return dst, key
    mods = g.env(tree)
    if not g.derived:
        # Registered builds rewrite with this revision's original profile. The
        # shader-table copy also contains patches.py; exposing both registers
        # each build's cuts twice. Provisional profiles still need their path.
        mods.pop('DM_GAMES_DIR', None)
        mods.pop('DM_GAMES_FIRST', None)
    names = tree.py(f"import sys; sys.path.insert(0, 'dm/games'); import game; print(' '.join(game.load({g.id!r}).words('modules')))", mods).split()
    src = {m: g.build / 'extract' / g.ver / 'ExeFS' / m for m in names}
    nro = g.build / f'nro_{g.ver}' / 'nro.tsv'
    if nro.is_file():
        for ln in nro.read_text().splitlines():
            c = ln.split('\t')
            if ln and not ln.startswith(('#', 'refused\t')): src[c[0]] = nro.parent / (c[0] + '.nro')
    shutil.rmtree(dst, ignore_errors=True); dst.mkdir(parents=True)
    if nro.is_file(): shutil.copyfile(nro, dst / 'nro.tsv')
    say(f'  {g.id}: rewriting {len(src)} modules with the rewriter of {tree.id}')
    procs, todo = {}, list(src)
    while todo or procs:
        while todo and len(procs) < jobs:
            m = todo.pop(0); f = open(dst / f'rewrite_{m}.log', 'w')
            procs[m] = (subprocess.Popen([sys.executable, str(tree.path / 'dm/tools/patch_nso.py'), str(src[m]), str(dst), m], env=mods, stdout=f, stderr=subprocess.STDOUT), f)
        for m in [m for m, (p, _) in procs.items() if p.poll() is not None]:
            p, f = procs.pop(m); f.close()
            if p.returncode: raise HarnessError(f'{g.id}: patch_nso.py of {tree.id} failed on {m} (see {dst / f"rewrite_{m}.log"})')
        time.sleep(0.2)
    (dst / '.done').write_text('')
    return dst, key


# ---------------------------------------------------------------- the measuring lock and the Mac's load

def pid_alive(pid):
    try: os.kill(pid, 0); return True
    except ProcessLookupError: return False
    except PermissionError: return True


def own_tree():
    me, kids = os.getpid(), set()
    r = sh(['ps', '-axo', 'pid=,ppid='])
    par = collections.defaultdict(list)
    for ln in r.stdout.splitlines():
        a = ln.split()
        if len(a) == 2: par[int(a[1])].append(int(a[0]))
    todo = [me]
    while todo:
        p = todo.pop(); kids.add(p); todo += par.get(p, [])
    return kids


def heavy_jobs():   # other builds now running: not this process's, not stopped, not another regress.py's (whose builds pause while the measuring lock is held)
    r = sh(['ps', '-axo', 'pid=,ppid=,stat=,command=']); out = []; rows = {}
    for ln in r.stdout.splitlines():
        pid, ppid, stat, cmd = (ln.split(None, 3) + ['', '', ''])[:4]
        if pid.isdigit() and ppid.isdigit(): rows[int(pid)] = (int(ppid), stat, cmd)
    def managed(pid):
        seen, cooperative = set(), False
        while pid in rows and pid not in seen:
            seen.add(pid)
            parent, _, command = rows[pid]
            if pid == os.getpid(): return True
            if re.search(r'(?:dmsh_build|own_compilers|vk_shaders)\.py', command): cooperative = True
            if re.search(r'(?:^|[/\s])regress\.py(?:\s|$)', command): return cooperative
            pid = parent
        return False
    for pid, (_, stat, cmd) in rows.items():
        exe = os.path.basename(cmd.split(' ')[0]) if cmd else ''
        if managed(pid) or stat.startswith('T') or not (exe in HEAVY_EXE or re.search(HEAVY_PY, cmd)): continue
        out.append(f'{pid} {cmd}')
    return out


def wait_idle(limit):   # the shared rule: measure only while no build or other heavy job runs
    t0, said = time.time(), False
    while time.time() - t0 < limit:
        jobs = heavy_jobs()
        if not jobs: return True
        if not said: say(f'    waiting for other jobs to end ({len(jobs)}: {", ".join(j.split(None, 1)[1][:40] for j in jobs[:3])})'); said = True
        time.sleep(5)
    say('    other jobs still run: measuring anyway (marked busy)'); return False


def take_lock(lock, what):
    if not lock: return
    say(f'    taking the measuring lock {lock}') if lock.exists() else None
    bench.wait_lock(lock, f'regress.py {what}')


def run_heavy(cmd, log, cwd, env, a, what):
    """A heavy job (a shader build) in its own process group, stopped (SIGSTOP) while another process holds the measuring lock and resumed when it is free, so it never
    skews someone else's measurement (the shared rule: heavy jobs wait for the lock). → (exit status, seconds paused)"""
    with open(log, 'w') as f: p = subprocess.Popen([str(c) for c in cmd], cwd=cwd, env=env, stdout=f, stderr=subprocess.STDOUT, start_new_session=True)
    paused, t_pause = 0.0, None
    try:
        while p.poll() is None:
            held = bench.lock_holder(a.pause_lock) if a.pause_lock else None
            if held is not None and t_pause is None:
                os.killpg(p.pid, signal.SIGSTOP); t_pause = time.time(); say(f'    {what}: paused while process {held} holds the measuring lock')
            elif held is None and t_pause is not None:
                os.killpg(p.pid, signal.SIGCONT); paused += time.time() - t_pause; t_pause = None; say(f'    {what}: resumed')
            time.sleep(2)
    finally:
        if p.poll() is None:
            try: os.killpg(p.pid, signal.SIGCONT); os.killpg(p.pid, signal.SIGTERM); p.wait(10)
            except (ProcessLookupError, subprocess.TimeoutExpired): p.kill()
    return p.returncode, round(paused)


# ---------------------------------------------------------------- one game run

_libproc = ctypes.CDLL('/usr/lib/libproc.dylib')


def footprint(pid):   # (current, lifetime peak) physical footprint in bytes (proc_pid_rusage, RUSAGE_INFO_V4)
    buf = ctypes.create_string_buffer(512)
    if _libproc.proc_pid_rusage(pid, 4, buf) != 0: return None
    v = struct.unpack_from('<16x35Q', buf.raw)
    return v[7], v[28]


# A shader the run asked for that the chain build does not hold (the harness builds part of a game's shaders, and which ones a run asks for depends on its timing: about 2,000 per
# Tears of the Kingdom run, different names each run, baseline too): one kind, counted, not one kind per name. A library Metal could not load ("failed to load shader <key>_b: <Metal's
# error>") stays a kind of its own. The patterns also read the kinds older baselines stored, whose keys normalize_red had cut into "#" fragments.
MISSING_LIB = 'shader library missing from the chain build'
MISSING_RE = re.compile(r'failed to load shader [^\s:]*(: (cannot open|no reflection json)|$)|shader [^\s:]* \(\w+\) failed to load: build the shaders'
                        r'|pulling library of [^\s:]* not usable \(no library: cannot open')


def red_messages(line):
    """The [RED] messages of one log line: in logs of hosts before LOG held the stream lock (dm/host/dm.h), another thread's message could land before a line's newline, so two
    messages share a line ("…_b.metallib[dm] [nvn-mtl] [RED] failed to load shader …")"""
    return ['[RED] ' + re.sub(r'\[dm\](\s*\[[\w-]+\])*\s*$', '', m).strip() for m in line.split('[RED]')[1:]]


def normalize_red(line):
    s = line.split('[RED]', 1)[1].strip()
    s = re.sub(r'(/[^\s:;,()\'"]+)(\s+\S*/[^\s:;,()\'"]+)*', '<path>', s)   # a path, also one with spaces in its folder names
    s = re.sub(r'\b0x[0-9a-fA-F]+\b', '#', s)   # a hex number is a number as a decimal one is: a value printed with %#x reads 0 when it is zero ("x1=0" against "x1=0x1")
    s = re.sub(r'(?<![0-9a-fA-F])[0-9a-f]{16}(?![0-9a-fA-F])', '<key>', s)   # also one with a suffix ("c41c950044f80287_b": no word boundary before the "_")
    s = re.sub(r'\d+(\.\d+)?', '#', s)
    return MISSING_LIB if MISSING_RE.match(s) else s[:200]


def cut_missing(m):   # the last message of a stored kind normalize_red cut at 200 characters, when it reads as a missing library as far as it goes ("failed to load shader #a#_b: no refle")
    k = re.match(r'failed to load shader [^\s:]*', m)
    if not k: return 'failed to load shader'.startswith(m)
    rest = m[k.end():]
    return any(x.startswith(rest) for x in (': cannot open', ': no reflection json'))


def red_kinds(k):
    """The [RED] kinds, as normalize_red makes them now, of a kind a stored baseline holds: hex numbers before they became "#" read "0x#", a key with a suffix was cut into
    "#" fragments ("#c#f#dce#a_b"), fused messages (red_messages) were one kind, cut at 200 characters"""
    out, ms = [], k.replace('0x#', '#').split('[RED]')
    for i, m in enumerate(ms):
        m = re.sub(r'\[dm\](\s*\[[\w-]+\])*\s*$', '', m).strip()
        m = re.sub(r'(?<![\w#<])[0-9a-f#]*#[0-9a-f#]*(?=_[a-z]+\b)', '<key>', m)
        if not m: continue
        out.append(MISSING_LIB if MISSING_RE.match(m) or (i == len(ms) - 1 and len(k) >= 200 and cut_missing(m)) else m)
    return out or [k]


def red_counts(r):   # a run's [RED] kinds and their counts, stored ones read as red_kinds does
    c = collections.Counter()
    for k, n in r.get('red', {}).items():
        for x in red_kinds(k): c[x] += n
    return c


def read_log(text):
    red = collections.Counter(normalize_red(m) for l in text.splitlines() if '[RED]' in l for m in red_messages(l))
    crash = next((l.strip()[:160] for l in text.splitlines() if 'CRASH sig=' in l), None)
    m = re.findall(r'pipeline prepare: \d+ lines .*? in ([\d.]+) s on', text)
    pb = None
    d = re.findall(r'pipeline prebuild done: (\d+) pairs, (\d+) bases built, (\d+) already archived, (\d+) left to the draws, (\d+) failed, ([\d.]+) s', text)
    if d: pb = dict(zip(('pairs', 'built', 'archived', 'left', 'failed', 'secs'), map(float, d[-1]))) | {'done': True}
    else:
        p = re.findall(r'pipeline prebuild: (\d+) of (\d+) pairs, (\d+) built, (\d+) already archived, (\d+) left to the draws, (\d+) failed, ([\d.]+) s', text)
        if p: pb = {'pairs': float(p[-1][1]), 'built': float(p[-1][2]), 'archived': float(p[-1][3]), 'failed': float(p[-1][5]), 'secs': float(p[-1][6]), 'done': False, 'at': float(p[-1][0])}
    return red, crash, float(m[-1]) if m else None, pb


def crash_report(t0):
    d = Path.home() / 'Library/Logs/DiagnosticReports'
    for p in sorted(d.glob('dmhost*.ips'), key=lambda p: p.stat().st_mtime, reverse=True) if d.is_dir() else []:
        if p.stat().st_mtime < t0: break
        try:
            body = json.loads(p.read_text(errors='replace').split('\n', 1)[1])
            e = body.get('exception', {}); return {'type': e.get('type'), 'signal': e.get('signal'), 'report': p.name}
        except (ValueError, IndexError): return {'report': p.name}
    return None


def thumb(png, w, h):   # w × h RGB pixels of a PNG, resampled by sips (no Python imaging package needed)
    bmp = png.with_name(f'{png.stem}.{w}x{h}.bmp')
    r = sh(['sips', '-s', 'format', 'bmp', '-z', h, w, png, '--out', bmp])
    if r.returncode or not bmp.is_file(): return None
    b = bmp.read_bytes(); bmp.unlink()
    off, bw, bh, bpp = struct.unpack_from('<I', b, 10)[0], *struct.unpack_from('<iiHH', b, 18)[:2], struct.unpack_from('<H', b, 28)[0]
    bpx, stride = bpp // 8, (bw * bpp // 8 + 3) & ~3
    px = []
    for y in range(abs(bh)):
        row = off + ((abs(bh) - 1 - y) if bh > 0 else y) * stride
        px += [(b[row + x * bpx + 2], b[row + x * bpx + 1], b[row + x * bpx]) for x in range(bw)]
    return px


def shot_hashes(png):
    """dHash (64 bits: brightness gradients of a 9 × 8 thumbnail, hex) and a 16 × 16 RGB thumbnail (hex, kept in the baseline, not the report)"""
    a, t = thumb(png, 9, 8), thumb(png, 16, 16)
    if not a or not t: return None
    g = [0.299 * r + 0.587 * gg + 0.114 * bb for r, gg, bb in a]
    bits = ''.join('1' if g[y * 9 + x] > g[y * 9 + x + 1] else '0' for y in range(8) for x in range(8))
    return {'dhash': f'{int(bits, 2):016x}', 'rgb16': bytes(c for p in t for c in p).hex()}


def shot_distance(a, b):
    bits = bin(int(a['dhash'], 16) ^ int(b['dhash'], 16)).count('1')
    x, y = bytes.fromhex(a['rgb16']), bytes.fromhex(b['rgb16'])
    return bits, round(sum(abs(p - q) for p, q in zip(x, y)) / len(x), 2)


def save_source(g, route):
    """The save a run starts from: a folder of the NSP folder (fixed saves, never written), none for `new`, and for `run` a copy of <id>_build/run/save frozen at its first
    use in <NSP folder>/<id>-work/regress/save-run (the build's own save changes whenever someone plays)"""
    if route['save'] == 'new': return None
    if route['save'] != 'run': return g.folder / route['save']
    frozen = game_root(g) / 'save-run'
    if not frozen.is_dir():
        shutil.copytree(g.build / 'run/save', frozen.with_name('save-run.partial'), symlinks=True, dirs_exist_ok=True); frozen.with_name('save-run.partial').rename(frozen)
    return frozen


def save_digest(d):
    return digest(sorted(p for p in Path(d).rglob('*') if p.is_file()), root=d)[:16] if d else 'new'


def smoke_context(g, art, route, a, hardware):
    """Reuse a baseline only for the same route, save bytes, build artifacts, machine and run settings. Old records without this context are recorded again."""
    env = {k: v for k, v in os.environ.items() if k.startswith(('DM_', 'DMSH_', 'XLATE_'))}
    return json.loads(json.dumps({'route': route, 'save': save_digest(save_source(g, route)), 'host': art['host_key'], 'modules': art['modules_key'], 'chain': art['manifest']['key'],
                                 'profile': digest(sorted(art['profile'].glob('*.tsv'))), 'machine': hardware, 'tools': a.tools_fp, 'env': env, 'overrides': a.env,
                                 'no_hud': a.no_hud, 'runs': a.runs, 'prebuild_limit': a.prebuild_limit, 'prebuild_hang': a.prebuild_hang}))


def run_env(g, art, route, outdir, a):
    """A fresh run folder (a copy of the route's save, an empty temp) and the host's environment for it → (env, the save it started from)"""
    lib, prof = art['lib'], art['profile']
    shutil.rmtree(outdir, ignore_errors=True); outdir.mkdir(parents=True)
    save, temp = outdir / 'save', outdir / 'temp'
    src_save = save_source(g, route)
    if src_save and not src_save.is_dir(): raise HarnessError(f'the route\'s save {src_save} does not exist (dm/games/{g.id}/smoke.tsv, save)')
    if src_save: shutil.copytree(src_save, save, symlinks=True)
    else: save.mkdir()
    temp.mkdir()
    env = dict(os.environ, DM_ROOT=str(g.build), DM_ROMFS=str(g.romfs()), DM_SAVE=str(save), DM_TEMP=str(temp), DM_MSL_DIR=str(lib), DM_FONT_DIR=str(g.build / 'font'),
               DM_WINDOW='1', DM_WINDOW_TOP='1', DM_AUDIO='0', DM_METAL_HUD='0' if a.no_hud else '1', DM_CTL=str(outdir / 'ctl'), TMPDIR=str(game_root(g) / 'tmp') + '/')
    if g.kind == 'nvn':
        env.update(DM_NVN_SHMAP=str(prof / 'shader_map.tsv'), DM_NVN_TSV=str(outdir / 'frames.tsv'), DM_NVN_TSV_CALLS='0')
        if not (prof / 'pso_pairs.tsv').is_file() and (g.build / 'shader/pso_pairs.tsv').is_file(): env['DM_PSO_PAIRS'] = str(g.build / 'shader/pso_pairs.tsv')
    if (g.build / 'aoc').is_dir(): env['DM_AOC_DIR'] = str(g.build / 'aoc')
    for kv in a.env: k, _, v = kv.partition('='); env[k] = v
    return env, src_save


def smoke_run(g, tree, art, route, quick, outdir, a):
    """One run of the route: the prebuild (full mode), then the game, under the watchdog → RUN (see the header)"""
    host, modules = art['host'], art['modules']
    secs = route['quick'] if quick else route['secs']
    env, src_save = run_env(g, art, route, outdir, a)
    res = {'secs': secs, 'host': art['host_key'], 'modules': art['modules_key'], 'save': save_digest(src_save)}
    prebuild = g.kind == 'nvn' and not quick and route['prebuild'] == 'on'
    if prebuild:   # the pipeline prebuild into <run>/pso_archive, as the NSP script's Mac build and the Mac app's prepare step run it
        penv = dict(env, DM_PSO_PREBUILD='tool'); penv.pop('DM_WINDOW', None)
        if g.get_depth_zero: penv['DM_PSO_PREBUILD_DEPTH'] = 'zero'
        r = run_watched([host], penv, outdir, outdir / 'prebuild.log', a, limit=a.prebuild_limit, hang=a.prebuild_hang, kind='prebuild', what=f'{g.id} prebuild')
        _, _, _, pb = read_log((outdir / 'prebuild.log').read_text(errors='replace'))
        res['prebuild'] = (pb or {}) | {'wall_s': r['wall'], 'exit': r['exit'], 'hang': r['hang_at_s'] is not None, 'hang_sample': r['hang_sample']}
    env['DM_KEYS'] = route['keys']
    if not prebuild and g.kind == 'nvn': env['DM_PSO_PREBUILD'] = '0'
    shots = [t for t in route['shots'] if t < secs - 1]
    r = run_watched([host, modules], env, outdir, outdir / 'log.txt', a, limit=secs, hang=route['hang'], kind=g.kind, what=f'{g.id} smoke', shots=shots,
                    frames=outdir / 'frames.tsv' if g.kind == 'nvn' else None)
    text = (outdir / 'log.txt').read_text(errors='replace')
    red, crash_line, prep, _ = read_log(text)
    res.update(exit=r['exit'], hang_at_s=r['hang_at_s'], hang_sample=r['hang_sample'], hang_dump='state dump (DM_CTL dump)' in text, first_frame_s=r['first_frame_s'], max_frame=r['max_frame'], peak_footprint_mb=r['peak_mb'], busy=r['busy'],
               prepare_s=prep, red=dict(red), crash=None, covered=text.count('front end: window covered'))
    if crash_line or (r['exit'] not in (None, 0)):
        res['crash'] = {'line': normalize_red('[RED] ' + crash_line) if crash_line else None, **(crash_report(r['t0']) or {})}
    if route['reach']:
        n, t = route['reach']
        res['reached'] = (r['frame_at'](t) >= n) if t <= secs else None
    else: res['reached'] = r['max_frame'] > 0
    if g.kind == 'nvn' and (outdir / 'frames.tsv').is_file():
        w0, wl = route['window'] or (secs / 2, secs / 2 - 2)
        w1 = min(w0 + wl, secs - 1)
        if w1 > w0:
            s = bench.summary(*bench.frames(outdir / 'frames.tsv', w0, w1), w1 - w0, 1000.0 / 60)
            res.update({k: s.get(k) for k in ('fps', 'frame_p50', 'frame_p99', 'frame_max', 'dropped', 'over_budget')}, window=[w0, w1])
    elif r['presents']:
        w0, wl = route['window'] or (secs / 2, secs / 2 - 2)
        pts = [(t, n) for t, n in r['presents'] if w0 <= t <= w0 + wl]
        if len(pts) >= 2: res['fps'] = round((pts[-1][1] - pts[0][1]) / (pts[-1][0] - pts[0][0]), 1)
    res['shots'] = {}
    for t in shots:
        p = outdir / f'shot_{t:g}s.png'
        h = shot_hashes(p) if p.is_file() else None
        if h: res['shots'][f'{t:g}'] = h
    return res


def hang_evidence(p, cwd):
    """Before the watchdog stops a hung host: its own state dump into the log (DM_CTL "dump": what each guest thread waits on, the graphics wait points; a host from before
    the command reads the line as a press of no button) and every host thread's stack (macOS sample) → the sample's file name in the run folder, None without one"""
    with open(cwd / 'ctl', 'a') as c: c.write('dump\n')
    time.sleep(1.5)   # the host polls DM_CTL every 100 ms
    out = cwd / 'hang_sample.txt'
    try: r = subprocess.run(['sample', str(p.pid), '3', '-file', str(out)], capture_output=True, timeout=120)
    except (OSError, subprocess.TimeoutExpired): return None
    return out.name if r.returncode == 0 and out.is_file() else None


def run_watched(cmd, env, cwd, log, a, limit, hang, kind, what, shots=(), frames=None, until=None):
    """Runs one host process under the watchdog, holding the measuring lock and keeping the display on; stops it after limit seconds, or once its log has a line matching until"""
    check_disk(a.min_free_gb)
    busy = not wait_idle(a.wait_idle)
    take_lock(a.lock, what)
    p = caf = None; t0w = time.time(); t0 = time.monotonic()
    st = {'max_frame': -1, 'first': None, 'last_new': None, 'hang': None, 'peak': 0, 'presents': [], 'pos': 0, 'logpos': 0, 'frame_t': [], 'upos': 0, 'until': None, 'sample': None}
    try:
        (cwd / 'ctl').write_text('')
        with open(log, 'w') as lf: p = subprocess.Popen([str(c) for c in cmd], cwd=cwd, env=env, stdout=lf, stderr=subprocess.STDOUT)
        caf = subprocess.Popen(['caffeinate', '-d', '-i', '-w', str(p.pid)])
        todo = list(shots); last_fp = 0
        while p.poll() is None:
            el = time.monotonic() - t0
            if el >= limit: break
            if until and log.is_file():
                with open(log, errors='replace') as fh:
                    fh.seek(st['upos']); chunk = fh.read(); cut = chunk.rfind('\n') + 1; st['upos'] += len(chunk[:cut].encode())
                m = re.search(until, chunk[:cut])
                if m: st['until'] = m.group(0); break
            while todo and el >= todo[0]:
                with open(cwd / 'ctl', 'a') as c: c.write(f'shot {cwd}/shot_{todo.pop(0):g}s.png\n')
            new = False
            if frames is not None and frames.is_file():
                with open(frames, errors='replace') as fh:
                    fh.seek(st['pos']); chunk = fh.read(); cut = chunk.rfind('\n') + 1; st['pos'] += len(chunk[:cut].encode())
                for ln in chunk[:cut].splitlines():
                    c = ln.split('\t')
                    if len(c) == 3 and c[1] == '@t_s' and c[0].isdigit() and int(c[0]) > st['max_frame']: st['max_frame'] = int(c[0]); new = True
            elif kind not in ('prebuild', 'nvn'):
                with open(log, errors='replace') as fh:
                    fh.seek(st['logpos']); chunk = fh.read(); cut = chunk.rfind('\n') + 1; st['logpos'] += len(chunk[:cut].encode())
                for m in re.finditer(r'presents (\d+)', chunk[:cut]):
                    n = int(m.group(1))
                    if n > st['max_frame']: st['max_frame'] = n; new = True; st['presents'].append((el, n))
            elif kind == 'prebuild':
                sz = log.stat().st_size if log.is_file() else 0
                if sz != st['logpos']: st['logpos'] = sz; new = True
            if new:
                st['last_new'] = el; st['frame_t'].append((el, st['max_frame']))
                if st['first'] is None and kind != 'prebuild': st['first'] = el
            if (st['first'] is not None or kind == 'prebuild') and st['last_new'] is not None and el - st['last_new'] > hang:
                st['hang'] = round(st['last_new'], 1); break
            if el - last_fp >= 1:
                fp = footprint(p.pid); last_fp = el
                if fp: st['peak'] = max(st['peak'], fp[0], fp[1])
            time.sleep(0.25)
        if p.poll() is None:
            fp = footprint(p.pid)
            if fp: st['peak'] = max(st['peak'], fp[0], fp[1])
            if st['hang'] is not None: st['sample'] = hang_evidence(p, cwd)
    finally:
        if p is not None and p.poll() is None:
            p.send_signal(signal.SIGTERM)
            try: p.wait(10)
            except subprocess.TimeoutExpired: p.kill(); p.wait()
            stopped = True
        else: stopped = False
        if caf is not None and caf.poll() is None: caf.terminate()
        if a.lock and bench.lock_holder(a.lock) == os.getpid(): a.lock.unlink(missing_ok=True)   # only a lock this process holds
    rc = None if stopped or p is None else p.returncode
    ft = st['frame_t']
    def frame_at(t):
        best = -1
        for e, n in ft:
            if e <= t: best = n
        return best
    return {'exit': rc, 'hang_at_s': st['hang'], 'first_frame_s': round(st['first'], 1) if st['first'] is not None else None, 'max_frame': st['max_frame'],
            'peak_mb': round(st['peak'] / 1048576) if st['peak'] else None, 'presents': st['presents'], 'frame_at': frame_at, 't0': t0w, 'wall': round(time.monotonic() - t0, 1), 'busy': busy,
            'until': st['until'], 'hang_sample': st['sample']}


# ---------------------------------------------------------------- comparing runs

def med(xs):
    xs = [x for x in xs if x is not None]
    return sorted(xs)[len(xs) // 2] if xs else None


def run_failures(r, route):
    f = []
    if r.get('crash'): f.append('crash' + (f" ({r['crash'].get('signal') or r['crash'].get('type') or r['crash'].get('line') or ''})"))
    elif r.get('exit') is not None: f.append(f"exited before the end of the route (exit {r['exit']})")
    if r.get('hang_at_s') is not None: f.append(f"hang (no frame after {r['hang_at_s']} s)")
    if r.get('reached') is False and route.get('reach'): f.append(f"frame {route['reach'][0]} not reached by {route['reach'][1]:g} s (max {r.get('max_frame')})")
    if r.get('max_frame', -1) < 0: f.append('no frame')
    pb = r.get('prebuild')
    if pb:
        if pb.get('exit') != 0: f.append(f"prebuild did not exit successfully (exit {pb.get('exit')})")
        if pb.get('hang') or (pb.get('done') is False): f.append(f"prebuild did not finish ({pb.get('at', '?')} of {pb.get('pairs', '?')} pairs)")
        if pb.get('failed'): f.append(f"prebuild: {pb['failed']:g} pairs failed")
    for t in route.get('shots', []):
        if t < r.get('secs', float('inf')) - 1 and f'{t:g}' not in r.get('shots', {}): f.append(f'screenshot at {t:g} s missing')
    return f


def smoke_diff(base, cand, route):
    """→ (status reasons by level, known failures, diff numbers)"""
    newfail, regress, changed, known = [], [], [], []
    # a failure is matched by its kind: the numbers in its parentheses are each run's own (the reach's max frame, a hang's second, the prebuild's pairs), so one the
    # baseline had too stays known (Pikmin 4's route missed its reach in every baseline run, "(max 4797)", and in a candidate run, "(max 4774)"); the words stay, so a crash
    # with another signal ("(SIGSEGV)" against "(SIGABRT)") or an exit with another status is new
    kind = lambda x: re.sub(r'\(([^)]*)\)', lambda m: '(' + re.sub(r'(?<!exit )(?<![\w-])-?\d+(\.\d+)?(?![\w])', '#', m.group(1)) + ')', x)
    bf = set(kind(x) for r in base for x in run_failures(r, route)); cf_ = [x for r in cand for x in run_failures(r, route)]
    for x in dict.fromkeys(cf_):
        (known if kind(x) in bf else newfail).append(x)
    d = {}
    bc, cc = [red_counts(r) for r in base], [red_counts(r) for r in cand]
    bred = set(k for c in bc for k in c)
    nr = collections.Counter()
    for c in cc:
        for k, n in c.items():
            if k not in bred: nr[k] += n
    d['new_red'] = [{'text': k, 'count': n} for k, n in nr.most_common(30)]
    if nr: regress.append(f'{len(nr)} new [RED] line kinds')
    gone = bred - set(k for c in cc for k in c) if cand else set()
    if gone: changed.append(f'{len(gone)} [RED] line kinds gone'); d['gone_red'] = sorted(gone)[:30]
    b, c = med(x[MISSING_LIB] for x in bc), med(x[MISSING_LIB] for x in cc)   # the missing libraries' count moves by hundreds from run to run (TotK 1641 to 2303): only a jump is news
    d['missing_libs'] = [b, c]
    if b is not None and c is not None and MISSING_LIB in bred and c > b * TOL['missing_libs_x'] and c - b > TOL['missing_libs']: changed.append(f'missing shader libraries {b:g} → {c:g} per run')
    def pct(k, invert=False):
        b, c = med(r.get(k) for r in base), med(r.get(k) for r in cand)
        if b in (None, 0) or c is None: return None, b, c
        return round((c - b) / b * 100, 1), b, c
    p, b, c = pct('fps'); d['fps_p50_change_pct'] = p
    if p is not None and p < -TOL['fps_pct']: regress.append(f'fps {b:g} → {c:g} ({p:+g} %)')
    elif p is not None and abs(p) > TOL['fps_pct']: changed.append(f'fps {b:g} → {c:g} ({p:+g} %)')
    p, b, c = pct('frame_p99'); d['frame_p99_change_pct'] = p
    if p is not None and b is not None and c is not None and p > TOL['p99_pct'] and c - b > TOL['p99_ms']: regress.append(f'frame p99 {b:g} → {c:g} ms ({p:+g} %)')
    p, b, c = pct('peak_footprint_mb'); d['peak_footprint_change_pct'] = p
    if p is not None and b is not None and c is not None and p > TOL['footprint_pct'] and c - b > TOL['footprint_mb']: regress.append(f'peak footprint {b:g} → {c:g} MB ({p:+g} %)')
    b, c = med(r.get('prepare_s') for r in base), med(r.get('prepare_s') for r in cand)
    d['prepare_change_s'] = round(c - b, 2) if b is not None and c is not None else None
    if b is not None and c is not None and c > b * TOL['prepare_x'] and c - b > TOL['prepare_s']: regress.append(f'prepare step {b:g} → {c:g} s')
    b, c = med((r.get('prebuild') or {}).get('wall_s') for r in base), med((r.get('prebuild') or {}).get('wall_s') for r in cand)
    d['prebuild_change_s'] = round(c - b, 1) if b is not None and c is not None else None
    if b and c and c > b * TOL['prebuild_x'] and c - b > TOL['prebuild_s']: regress.append(f'prebuild {b:g} → {c:g} s')
    d['shots'] = {}
    for t in sorted({t for r in cand for t in r.get('shots', {})}, key=float):
        bs = [r['shots'][t] for r in base if t in r.get('shots', {})]; cs = [r['shots'][t] for r in cand if t in r.get('shots', {})]
        if not bs or not cs: continue
        noise = max([shot_distance(x, y)[1] for i, x in enumerate(bs) for y in bs[i + 1:]] or [0])
        nearest = [(min((shot_distance(x, y) for x in bs), key=lambda v: v[1]), y) for y in cs]
        (bits, diff), shot = max(nearest, key=lambda v: v[0][1])
        d['shots'][t] = {'dhash_bits': bits, 'rgb_diff': diff, 'baseline_noise': noise, 'dhash': shot['dhash']}
        if diff > max(TOL['rgb_diff'], 2 * noise) and bits > TOL['dhash_bits'] // 2 or bits > TOL['dhash_bits'] and diff > TOL['rgb_diff'] / 2: regress.append(f'screenshot at {t} s differs (dHash {bits} bits, RGB {diff})')
        elif diff > TOL['rgb_diff'] / 2: changed.append(f'screenshot at {t} s moved (RGB {diff})')
    return {'NEW-FAIL': newfail, 'REGRESSION': regress, 'CHANGED': changed}, known, d


LEVELS = ['ERROR', 'NEW-FAIL', 'REGRESSION', 'CHANGED', 'PASS']


def worst(*levels):
    return min(levels, key=LEVELS.index) if levels else 'PASS'


# ---------------------------------------------------------------- the commands

def baseline_dir(tree, g):
    return game_root(g) / 'baselines' / tree.id


def artifacts(tree, g, a, rewrite):
    m, out = chain_build(tree, g, a)
    host, hkey, _ = host_for(tree, g, a.jobs)
    mods, mkey = modules_for(tree, g, rewrite, a.jobs)
    return {'manifest': m, 'lib': out, 'profile': profile_tables(tree, g, m, out), 'host': host, 'host_key': hkey, 'modules': mods, 'modules_key': mkey}


def profile_tables(tree, g, m, out):
    """The tables the host reads beside the shader map (pso_manifest.tsv, the pair lists, ...): the tree's, with c1_full.tsv and cb_extent.tsv as the chain build made them"""
    prof = game_root(g) / 'profile' / f'{tree.id}-{m["key"]}'
    if not (prof / '.done').is_file():
        prof.mkdir(parents=True, exist_ok=True)
        for f in g.profile_dir(tree).glob('*.tsv'): shutil.copyfile(f, prof / f.name)
        for f in (out / 'profile').glob('*.tsv') if g.kind == 'nvn' else []:
            if f.name in ('c1_full.tsv', 'cb_extent.tsv'): shutil.copyfile(f, prof / f.name)
        (prof / '.done').write_text('')
    return prof


def depth_zero(g, tree):
    return sh([sys.executable, str(tree.path / 'dm/games/game.py'), g.id, 'depth_mode', 'gl'], env=g.env(tree)).stdout.strip() == 'zero'


def smoke_series(g, tree, art, route, quick, label, a, runs):
    g.get_depth_zero = depth_zero(g, tree)
    out = []
    for i in range(runs):
        d = game_root(g) / 'runs' / f'{datetime.datetime.now():%Y%m%d-%H%M%S}-{label}-{"quick" if quick else "full"}-{i + 1}'
        say(f'  {g.id}: {label} run {i + 1}/{runs} ({"quick" if quick else "full"}, {route["quick"] if quick else route["secs"]:g} s) → {d}')
        r = smoke_run(g, tree, art, route, quick, d, a); r['dir'] = str(d)
        if r.get('covered'):   # another window covered the game's (a covered window's display link fires about once a second): its frame times measure nothing, so once more
            say(f'    the window was covered during the run ({d / "log.txt"}): once more')
            d = d.with_name(d.name + '-again'); r = smoke_run(g, tree, art, route, quick, d, a); r['dir'] = str(d)
        out.append(r)
        say(f'    exit {r["exit"]}, max frame {r["max_frame"]}, first frame {r["first_frame_s"]} s, prepare {r["prepare_s"]} s, fps {r.get("fps")}, p99 {r.get("frame_p99")} ms, '
            f'peak {r["peak_footprint_mb"]} MB, RED kinds {len(r["red"])}' + (', window covered' if r.get('covered') else '') + (f', prebuild {r["prebuild"].get("wall_s")} s' if r.get('prebuild') else '')
            + (f', FAIL: {"; ".join(run_failures(r, route))}' if run_failures(r, route) else '')
            + ''.join(f', thread stacks {d / x}' for x in (r.get('hang_sample'), (r.get('prebuild') or {}).get('hang_sample')) if x))
    return out


def public_run(r):   # what a run contributes to the report: no thumbnails, no paths
    x = {k: v for k, v in r.items() if k not in ('shots', 'dir')}
    x['shots'] = {t: {'dhash': h['dhash']} for t, h in r.get('shots', {}).items()}
    return x


def cmd_baseline(a):
    tree = Tree(a.rev); games = select(a, smoke=not a.no_smoke)
    rep = new_report(a, 'baseline', baseline=tree, candidate=None)
    for g in games:
        t0 = time.time(); gr = rep['games'][g.id] = {'name': g.name, 'status': 'PASS', 'reasons': [], 'known': [], 'secs': {}}
        try:
            route = g.route() if not a.no_smoke else None
            art = artifacts(tree, g, a, rewrite=a.rewrite) if route else None
            m = art['manifest'] if art else chain_build(tree, g, a)[0]
            gr['secs']['chain'] = round(time.time() - t0, 1)
            bd = baseline_dir(tree, g); bd.mkdir(parents=True, exist_ok=True)
            (bd / 'chain.json').write_text(json.dumps({'key': m['key']}))
            gr['chain'] = {'kind': m['kind'], 'baseline': build_summary(m)}
            if m['failed']: gr['known'].append(f"{m['failed']} of {m['total']} shaders do not build")
            if m.get('build_failed'): gr['known'].append('Vulkan shader build failed')
            if m.get('interface', {}).get('bad'):
                bad = m['interface']['bad']; gr['chain']['interface'] = {'baseline': len(bad), 'checked': m['interface']['checked'], 'known': bad[:50]}
                gr['status'] = 'NEW-FAIL'; gr['reasons'].append(f'{len(bad)} pipeline bases whose pixel shader reads an output the vertex shader does not write (metal-tt refuses the archive)')
            if route:
                t1 = time.time()
                runs = smoke_series(g, tree, art, route, a.quick, 'baseline', a, a.runs)
                (bd / f'smoke-{"quick" if a.quick else "full"}.json').write_text(json.dumps({'route': route, 'runs': runs, 'tree': tree.id,
                                                                                        'context': smoke_context(g, art, route, a, rep['machine'])}, indent=1))
                gr['smoke'] = {'route': route, 'baseline': [public_run(r) for r in runs]}
                fails = [x for r in runs for x in run_failures(r, route)]
                if fails: gr['status'] = 'NEW-FAIL'; gr['reasons'] += list(dict.fromkeys(fails))
                if len(runs) > 1:
                    _, _, d = smoke_diff(runs[:1], runs[1:], route); gr['smoke']['noise'] = d
                gr['secs']['smoke'] = round(time.time() - t1, 1)
        except HarnessError as e:
            gr['status'] = 'ERROR'; gr['reasons'].append(str(e)); say(f'  {g.id}: [RED] {e}')
        say(f'  {g.id}: {gr["status"]} ' + '; '.join(gr['reasons']))
    result = finish(rep, a)
    record_validated(a, rep, tree, games)
    return result


def cmd_check(a, smoke=True):
    smoke = smoke and not a.no_smoke
    base = Tree(a.baseline or git('merge-base', 'HEAD', 'main')); cand = Tree(a.candidate)
    games = select(a, smoke=smoke and not a.no_smoke)
    rep = new_report(a, 'check' if smoke else 'chain', baseline=base, candidate=cand)
    rewrite = a.rewrite or rewriter_key(base) != rewriter_key(cand)
    if rewrite and smoke and not a.no_smoke: say('the rewriter differs between the revisions: both rewrite the modules')
    for g in games:
        t0 = time.time(); gr = rep['games'][g.id] = {'name': g.name, 'status': 'PASS', 'reasons': [], 'known': [], 'secs': {}}
        levels = collections.defaultdict(list)
        try:
            route = g.route() if smoke else None
            bart = artifacts(base, g, a, rewrite) if route else None
            bm = bart['manifest'] if bart else chain_build(base, g, a)[0]
            cart = artifacts(cand, g, a, rewrite) if route else None
            cm = cart['manifest'] if cart else chain_build(cand, g, a)[0]
            gr['secs']['chain'] = round(time.time() - t0, 1)
            cd = chain_diff(bm, cm)
            gr['chain'] = {'kind': cm['kind'], 'baseline': build_summary(bm), 'candidate': build_summary(cm), **cd}
            if cm.get('build_failed'):
                (gr['known'] if bm.get('build_failed') else levels['NEW-FAIL']).append('Vulkan shader build failed')
            if cd['newly_failing']: levels['NEW-FAIL'].append(f"{len(cd['newly_failing'])} shaders newly fail to build (shader_regressions.py's rule)")
            if cd['added_failing']: levels['NEW-FAIL'].append(f"{len(cd['added_failing'])} shaders new in the candidate fail to build")
            both = cm['failed'] - len(cd['newly_failing']) - len(cd['added_failing'])
            if both: gr['known'].append(f"{both} shaders fail in both")
            if cd['newly_passing']: levels['CHANGED'].append(f"{len(cd['newly_passing'])} shaders newly build")
            if cd['changed']['shaders']: levels['CHANGED'].append(f"{cd['changed']['shaders']} shaders changed (MSL {cd['changed']['msl']}, reflection {cd['changed']['reflection']}, variants {cd['changed']['variants']})")
            if cd['added'] or cd['removed']: levels['CHANGED'].append(f"shaders added {cd['added']}, removed {cd['removed']}")
            itf = cd.get('interface')
            if itf and itf['new']: levels['NEW-FAIL'].append(f"{len(itf['new'])} new pipeline bases with a pixel input the vertex shader does not write (metal-tt refuses the archive)")
            if itf and itf['known']: gr['known'].append(f"{itf['candidate'] - len(itf['new'])} pipeline bases with a pixel input the vertex shader does not write (as in the baseline: GitHub issue #283)")
            if route:
                t1 = time.time(); mode = 'quick' if a.quick else 'full'
                bf = baseline_dir(base, g) / f'smoke-{mode}.json'
                context = smoke_context(g, bart, route, a, rep['machine'])
                if bf.is_file() and json.loads(bf.read_text()).get('context') != context:
                    say(f'  {g.id}: the stored {mode} baseline of {base.id} has different inputs or run settings: recording it again'); bf.unlink()
                if not bf.is_file():
                    say(f'  {g.id}: no stored {mode} baseline for {base.id}: recording it')
                    runs = smoke_series(g, base, bart, route, a.quick, 'baseline', a, a.runs)
                    bf.parent.mkdir(parents=True, exist_ok=True); bf.write_text(json.dumps({'route': route, 'runs': runs, 'tree': base.id, 'context': context}, indent=1))
                bruns = json.loads(bf.read_text())['runs']
                cruns = smoke_series(g, cand, cart, route, a.quick, 'candidate', a, a.runs)
                lv, known, d = smoke_diff(bruns, cruns, route)
                for k, v in lv.items(): levels[k] += v
                gr['known'] += known
                gr['smoke'] = {'route': route, 'baseline': [public_run(r) for r in bruns], 'candidate': [public_run(r) for r in cruns], 'diff': d}
                gr['secs']['smoke'] = round(time.time() - t1, 1)
        except HarnessError as e:
            levels['ERROR'].append(str(e)); say(f'  {g.id}: [RED] {e}')
        except Exception as e:   # a bug in the harness: reported as an error of this game, the others go on
            levels['ERROR'].append(f'{type(e).__name__}: {e}'); traceback.print_exc()
        gr['status'] = worst(*[k for k, v in levels.items() if v]) if any(levels.values()) else 'PASS'
        gr['reasons'] = [f'{k}: {x}' for k in LEVELS for x in levels.get(k, [])]
        say(f'  {g.id}: {gr["status"]}' + (' — ' + '; '.join(gr['reasons']) if gr['reasons'] else ''))
    result = finish(rep, a)
    record_validated(a, rep, cand, games)
    return result


# ---------------------------------------------------------------- frame capture and replay (DM_NVN_CAPTURE, dm/gfx/tests/nvn_replay)

def capture_dir(g):
    return game_root(g) / 'captures'


def replayer_for(tree, g, a):
    """dm/gfx/tests/nvn_replay of a revision, built for this game (it includes the tree's replay layer and profile header)"""
    dst = game_root(g) / 'replayer' / tree.id / 'nvn_replay'
    if dst.is_file(): return dst
    say(f'  {g.id}: building the replayer of {tree.id}')
    logs = game_root(g) / 'tmp'; logs.mkdir(parents=True, exist_ok=True); env = g.env(tree)
    (tree.path / 'dm/gfx/tests/nvn_replay').unlink(missing_ok=True)   # one binary per tree but one header per game: make would keep another game's binary, newer than this game's header
    for d, target in (('dm/host', 'game_profile'), ('dm/gfx/tests', 'nvn_replay')):   # the profile header first: the tests' rule keeps a stale one
        log = logs / f'replayer-{tree.id}-{g.id}-{target}.log'
        rc, _ = run_heavy(['make', '-C', tree.path / d, f'GAME={g.id}', target], log, tree.path, env, a, f'{g.id} {target}')
        if rc: raise HarnessError(f'{g.id}: the replayer of {tree.id} does not build (see {log})')
    dst.parent.mkdir(parents=True, exist_ok=True); shutil.copy2(tree.path / 'dm/gfx/tests/nvn_replay', dst)
    return dst


REPLAY_DIGEST = re.compile(r'^replay (\d+): digest ([0-9a-f]{64}) (==|!=) live ([0-9a-f]{64})', re.M)
REPLAY_PIXELS = re.compile(r'^replay (\d+): (\d+) pixels differ from the live frame \(largest byte difference (\d+), x (\d+)-(\d+) y (\d+)-(\d+)\)', re.M)


def parse_replays(text):
    """nvn_replay's output → [{index, digest, same, live, pixels, largest, box}] (pixels None: a replay that equals the live frame, or a capture without the live pixels)"""
    px = {int(m[1]): (int(m[2]), int(m[3]), [int(m[4]), int(m[5]), int(m[6]), int(m[7])]) for m in REPLAY_PIXELS.finditer(text)}
    out = []
    for m in REPLAY_DIGEST.finditer(text):
        k = int(m[1]); p = px.get(k)
        out.append({'index': k, 'digest': m[2], 'same': m[3] == '==', 'live': m[4], 'pixels': 0 if m[3] == '==' else p[0] if p else None,
                    'largest': p[1] if p else 0, 'box': p[2] if p else None})
    return out


def replay_runs(binary, cap, lib, prof, n, maxpx, g, a, what):
    """n fresh replays of a capture against a revision's replay layer and its shader libraries (given on the command line, they win over the capture's own settings)"""
    env = dict(os.environ, DM_MSL_DIR=str(lib), DM_NVN_SHMAP=str(prof / 'shader_map.tsv'), TMPDIR=str(game_root(g) / 'tmp') + '/')
    check_disk(a.min_free_gb)
    busy = not wait_idle(a.wait_idle)
    take_lock(a.lock, what)
    log = game_root(g) / 'tmp' / f'replay-{Path(binary).parent.name}-{g.id}.log'
    try:
        t0 = time.monotonic()
        r = subprocess.run([str(binary), str(cap), '--repeat', str(n), '--max-pixels', str(maxpx)], cwd=cap.parent, env=env, capture_output=True, text=True, errors='replace')
        secs = round(time.monotonic() - t0, 1)
    finally:
        if a.lock and bench.lock_holder(a.lock) == os.getpid(): a.lock.unlink(missing_ok=True)
    text = r.stdout + r.stderr; log.write_text(text)
    red = list(dict.fromkeys(normalize_red(ln[ln.index('[RED]'):]) for ln in text.splitlines() if '[RED] nvn_replay' in ln))
    return {'exit': r.returncode, 'replays': parse_replays(text), 'red': red, 'secs': secs, 'busy': busy, 'log': str(log)}


def replay_ok(res, noise):   # every replay equals the live frame or differs in at most noise pixels
    return res['exit'] in (0, 1) and len(res['replays']) > 0 and all(x['same'] or (x['pixels'] is not None and x['pixels'] <= noise) for x in res['replays'])


def public_replay(res):   # numbers and digests only (no paths)
    return {'exit': res['exit'], 'secs': res['secs'], 'busy': res['busy'], 'red': res['red'],
            'replays': [{'digest': x['digest'][:16], 'same': x['same'], 'pixels': x['pixels'], 'largest': x['largest'], 'box': x['box']} for x in res['replays']]}


def replay_tolerance(noise):   # pixels a replay may differ from the live frame: none for a capture whose replays all equal it, else a margin over the measured noise
    return int(noise * TOL['replay_noise_x'])


def replay_grade(base, cand, noise):
    """→ ({level: [reason]}, [known]) for the candidate's replays of one capture, against the live frame within the tolerance of the capture's noise (a capture that replays exactly
    has none); which of the frames within it a noisy capture gives is chance, so they are not compared with the baseline's"""
    tol = replay_tolerance(noise)
    lv, known = collections.defaultdict(list), []
    worst_px = lambda r: max((x['pixels'] or 0 for x in r['replays']), default=0)
    if cand['exit'] == 2 or base['exit'] == 2:
        who = 'candidate' if cand['exit'] == 2 else 'baseline'
        why = ((cand if who == 'candidate' else base)['red'] or ['exit status 2'])[0]
        lv['ERROR'].append(f'the {who} cannot replay the capture ({why}): record a new one with regress.py capture')
        return lv, known
    if cand['exit'] not in (0, 1) or not cand['replays']:
        (known if base['exit'] not in (0, 1) else lv['NEW-FAIL']).append(f"the candidate's replay stopped (exit {cand['exit']}, {len(cand['replays'])} replays)")
        return lv, known
    cok, bok = replay_ok(cand, tol), replay_ok(base, tol)
    if not cok:
        x = max(cand['replays'], key=lambda x: x['pixels'] or 0)
        text = f"{x['pixels']} pixels differ from the live frame (largest byte difference {x['largest']}, box {x['box']}); the capture's noise is {noise}, the tolerance {tol}"
        if bok: lv['REGRESSION'].append(text)
        else: known.append(f'the baseline differs beyond the tolerance too ({worst_px(base)} pixels)'); lv['CHANGED'].append(text)

    return lv, known


def capture_meta(g):
    cur = capture_dir(g) / 'current.json'
    if not cur.is_file(): return None
    name = json.loads(cur.read_text())['name']
    meta = json.loads((capture_dir(g) / f'{name}.json').read_text())
    return meta | {'path': capture_dir(g) / f'{name}.nvncap'}


def cmd_capture(a):
    tree = Tree(a.rev); games = select(a, smoke=True)
    rep = new_report(a, 'capture', baseline=tree, candidate=None)
    for g in games:
        t0 = time.time(); gr = rep['games'][g.id] = {'name': g.name, 'status': 'PASS', 'reasons': [], 'known': [], 'secs': {}}
        try:
            route = g.route()
            if g.kind != 'nvn' or not route or not route.get('capture'):
                gr['known'].append('nothing to capture: an NVN game whose route (dm/games/<id>/smoke.tsv) has a capture frame'); continue
            art = artifacts(tree, g, a, rewrite=a.rewrite)
            frame = route['capture']; cd = capture_dir(g); cd.mkdir(parents=True, exist_ok=True)
            name = f'{tree.id}-f{frame}'; cap = cd / f'{name}.nvncap'; cap.unlink(missing_ok=True)
            outdir = game_root(g) / 'runs' / f'{datetime.datetime.now():%Y%m%d-%H%M%S}-capture'
            env, _ = run_env(g, art, route, outdir, a)
            # the wall clock (DM_DETCLOCK stops some games, waiting for guest time); no pipeline prebuild, and no stand-in pipelines, whose draws would differ from the replay's
            env.update(DM_KEYS=route['keys'], DM_PSO_PREBUILD='0', DM_PSO_HYBRID='0', DM_NVN_CAPTURE=f'{frame}:1:{cap}')
            say(f'  {g.id}: capturing frame {frame} with {tree.id} → {cap}')
            # the capture step itself shows no frame until it ends (reading back the textures and compressing the pools: about 2 minutes for Breath of the Wild), so only the
            # capture limit bounds it
            r = run_watched([art['host'], art['modules']], env, outdir, outdir / 'log.txt', a, limit=a.capture_limit, hang=max(route['hang'], a.capture_limit), kind='nvn',
                            what=f'{g.id} capture', frames=outdir / 'frames.tsv', until=r'DM_NVN_CAPTURE: frame \d+: [^\n]*')
            if not r['until'] or not cap.is_file():
                raise HarnessError(f'frame {frame} was not captured within {a.capture_limit:g} s (the game reached frame {r["max_frame"]}; see {outdir / "log.txt"})')
            gr['secs']['capture'] = round(time.time() - t0, 1); t1 = time.time()
            res = replay_runs(replayer_for(tree, g, a), cap, art['lib'], art['profile'], a.repeat, 1 << 40, g, a, f'{g.id} replay')
            if res['exit'] != 0 or len(res['replays']) != a.repeat or any(x['pixels'] is None for x in res['replays']):
                raise HarnessError(f"the new capture does not replay ({(res['red'] or ['exit ' + str(res['exit'])])[0]}; see {res['log']})")
            noise = max(x['pixels'] for x in res['replays'])
            meta = {'frame': frame, 'tree': tree.id, 'commit': tree.commit, 'chain': chain_version(tree.path), 'repeat': a.repeat, 'noise_px': noise,
                    'matches': sum(x['same'] for x in res['replays']), 'live': res['replays'][0]['live'][:16], 'date': datetime.date.today().isoformat()}
            (cd / f'{name}.json').write_text(json.dumps(meta, indent=1)); (cd / 'current.json').write_text(json.dumps({'name': name}))
            gr['capture'] = meta | {'replays': public_replay(res)['replays']}; gr['secs']['replay'] = round(time.time() - t1, 1)
            say(f"  {g.id}: frame {frame} captured; {meta['matches']} of {a.repeat} fresh replays equal the live frame, noise {noise} pixels")
        except HarnessError as e:
            gr['status'] = 'ERROR'; gr['reasons'].append(str(e)); say(f'  {g.id}: [RED] {e}')
        except Exception as e:   # a bug in the harness: reported as an error of this game, the others go on
            gr['status'] = 'ERROR'; gr['reasons'].append(f'{type(e).__name__}: {e}'); traceback.print_exc()
    return finish(rep, a)


def cmd_replay(a):
    base = Tree(a.baseline or git('merge-base', 'HEAD', 'main')); cand = Tree(a.candidate)
    games = select(a, smoke=False)
    if not a.games: games = [g for g in games if capture_meta(g)]   # named games without a capture are reported as errors
    rep = new_report(a, 'replay', baseline=base, candidate=cand)
    for g in games:
        t0 = time.time(); gr = rep['games'][g.id] = {'name': g.name, 'status': 'PASS', 'reasons': [], 'known': [], 'secs': {}}
        levels = collections.defaultdict(list)
        try:
            meta = capture_meta(g)
            if not meta: raise HarnessError('no capture: regress.py capture records one (its route needs a capture frame)')
            out = {}
            for label, tree in (('baseline', base), ('candidate', cand)):
                m, lib = chain_build(tree, g, a)
                out[label] = replay_runs(replayer_for(tree, g, a), meta['path'], lib, profile_tables(tree, g, m, lib), a.repeat, replay_tolerance(meta['noise_px']), g, a, f'{g.id} replay {label}')
            lv, known = replay_grade(out['baseline'], out['candidate'], meta['noise_px'])
            for k, v in lv.items(): levels[k] += v
            gr['known'] += known
            gr['replay'] = {'capture': {k: meta[k] for k in ('frame', 'tree', 'chain', 'noise_px', 'date')}, 'baseline': public_replay(out['baseline']), 'candidate': public_replay(out['candidate'])}
            gr['secs']['replay'] = round(time.time() - t0, 1)
        except HarnessError as e:
            levels['ERROR'].append(str(e)); say(f'  {g.id}: [RED] {e}')
        except Exception as e:
            levels['ERROR'].append(f'{type(e).__name__}: {e}'); traceback.print_exc()
        gr['status'] = worst(*[k for k, v in levels.items() if v]) if any(levels.values()) else 'PASS'
        gr['reasons'] = [f'{k}: {x}' for k in LEVELS for x in levels.get(k, [])]
        say(f'  {g.id}: {gr["status"]}' + (' — ' + '; '.join(gr['reasons']) if gr['reasons'] else ''))
    return finish(rep, a)


def cmd_usage(a):
    """The usage manifest of each game (dm/tools/usage.py): shader features of the revision's chain build, and what one run of the route's quick part calls"""
    tree = Tree(a.rev); games = select(a, smoke=True)
    for g in games:
        art = artifacts(tree, g, a, rewrite=a.rewrite)
        rows = collections.Counter()
        if g.kind == 'nvn':
            ff = art['lib'] / 'features.json'
            if not ff.is_file(): say(f'  {g.id}: shader features of chain {art["manifest"]["chain"]}'); ff.write_text(json.dumps(usage.shader_features(next(art['lib'].glob('b-*')))))
            for k, n in json.loads(ff.read_text()).items(): rows['shader', k] = n
        for ln in (g.profile_dir(tree) / 'game.tsv').read_text().splitlines():
            if ln and not ln.startswith('#') and '\t' in ln: rows['key', ln.split('\t')[0]] = 1
        route = g.route()
        if route and not a.no_smoke:
            g.get_depth_zero = depth_zero(g, tree)
            r2 = dict(route, shots=[])
            d = game_root(g) / 'runs' / f'{datetime.datetime.now():%Y%m%d-%H%M%S}-usage'   # the run's logs stay in the NSP folder, as check's runs
            a.env = list(a.env) + ['DM_HLECOUNT=hlecount.tsv', 'DM_NVN_TSV_CALLS=1']
            say(f'  {g.id}: usage run ({route["quick"]:g} s) → {d}')
            res = smoke_run(g, tree, art, r2, True, d, a)
            a.env = a.env[:-2]
            if run_failures(res, route): say(f'    [RED] the run failed ({"; ".join(run_failures(res, route))}): its usage rows are incomplete')
            rows.update(usage.runtime_usage(d, g.kind if g.kind != 'vk' else 'vulkan'))
        else: rows['api', g.kind if g.kind != 'vk' else 'vulkan'] = 1
        out = ROOT / g.id / 'usage' / f'{tree.id}.tsv'; out.parent.mkdir(parents=True, exist_ok=True)
        head = f'{g.name} ({g.id}), revision {tree.commit[:12]}, chain {art["manifest"]["chain"]}, ' + (f'route smoke.tsv quick ({route["quick"]:g} s)' if route and not a.no_smoke else 'no run')
        usage.write_manifest(out, rows, head)
        kinds = collections.Counter(k for k, _ in rows)
        say(f'  {g.id}: {", ".join(f"{k} {n}" for k, n in sorted(kinds.items()))} → {out}')
        if a.write:
            dst = REPO / 'dm/games' / g.id / 'usage.tsv'; shutil.copyfile(out, dst); say(f'    written to {dst}')
    return 0


def cmd_impact(a):
    """The games a git range can affect (dm/tools/usage.py impact), from the usage manifests of this checkout's profiles"""
    rng = a.range if '..' in a.range else f'{a.range}^..{a.range}'
    for rev in rng.split('..'):   # read from git only: no checkout and no harness root, as a contributor without the games has neither
        if sh(['git', 'rev-parse', '--verify', '--quiet', (rev or 'HEAD') + '^{commit}'], cwd=REPO).returncode: raise HarnessError(f'impact: {rev} is not a revision of this repository')
    manifests = {}
    for d in sorted((REPO / 'dm/games').iterdir()):
        if (d / 'game.tsv').is_file(): manifests[d.name] = usage.read_manifest(d / 'usage.tsv') if (d / 'usage.tsv').is_file() else None
    for extra in a.manifest:   # a manifest from <root>/<id>/usage/ that is not committed yet
        manifests[Path(extra).parent.parent.name] = usage.read_manifest(extra)
    r = usage.impact(rng, manifests)
    names = {d.name: (d / 'README.md').read_text(errors='replace').split('\n', 1)[0].lstrip('# ').split(' (`')[0] if (d / 'README.md').is_file() else d.name for d in (REPO / 'dm/games').iterdir() if d.is_dir()}
    st = collections.Counter(v['status'] for v in r['games'].values())
    L = [f"## regress.py impact `{rng}`", '', f"{st['affected']} games use what the change touches, {st['broad']} only through a broad rule (every game of its API), {st['not affected']} not affected, {st['unknown']} unknown (no usage manifest); "
         f"{len(r['changed'])} files changed, {len(r['names'])} NVN / HLE entry points reached through the host's callers, {len(r['patterns'])} rules of dm/tools/impact_map.tsv", '',
         '| game | status | what it uses of the change (kind: name ×count; for broad, the broad rows) |', '|---|---|---|']
    order = {'affected': 0, 'broad': 1, 'not affected': 2, 'unknown': 3}
    for gid, v in sorted(r['games'].items(), key=lambda x: (order[x[1]['status']], x[0])):
        if v['status'] == 'unknown' and not a.all: continue
        ms = v.get('narrow') or v['matches']
        top = ', '.join(f'{k}: {n} ×{c}' for k, n, c, _ in ms[:6]) + (f' … ({len(ms)} in all)' if len(ms) > 6 else '')
        L.append(f"| {names.get(gid, gid)} `{gid}` | {v['status']} | {top} |")
    if st['unknown'] and not a.all: L += ['', f"Unknown (no usage.tsv): {st['unknown']} profiles (--all lists them)."]
    L += ['', '### Why', ''] + [f'- `{p}` ← {w}' for p, w in r['patterns']] + [f'- `{k}:{n}` ← {w}' for k, n, w in r['names'][:30]] + (['- … more entry points'] if len(r['names']) > 30 else [])
    if r['unmapped']: L += ['', 'Changed files no rule maps (add them to dm/tools/impact_map.tsv): ' + ', '.join(f'`{f}`' for f in r['unmapped'])]
    md = '\n'.join(L) + '\n'
    out = Path(a.out) if a.out else ROOT / 'reports' / f'{datetime.datetime.now():%Y%m%d-%H%M%S}-impact' if a.root and ROOT.is_dir() else None   # without a harness root, the report is only printed
    if out:
        out.mkdir(parents=True, exist_ok=True)
        (out / 'impact.json').write_text(json.dumps({'schema': 'nxnative-impact/1', 'range': rng, **r}, indent=1, default=list)); (out / 'impact.md').write_text(md)
    say(md + (f'\nreport: {out / "impact.md"}' if out else ''))
    return 0


def select(a, smoke):
    games = find_games(a.games.split(',') if a.games else None)
    if not games: raise HarnessError(f'no game with a Mac build under {GAMES}')
    say('games: ' + ', '.join(f"{g.id} ({g.name}, {g.kind}{', route' if g.route() else ''}{', the build profile' if g.derived else ''})" for g in games))
    return games


def machine():
    hw = sh(['sysctl', '-n', 'hw.model']).stdout.strip(); cpu = sh(['sysctl', '-n', 'machdep.cpu.brand_string']).stdout.strip()
    return {'model': hw, 'chip': cpu, 'macos': sh(['sw_vers', '-productVersion']).stdout.strip(), 'xcode': sh(['xcodebuild', '-version']).stdout.split('\n')[0].strip()}


def new_report(a, command, baseline, candidate):
    return {'schema': 'nxnative-regress/1', 'command': command, 'mode': 'static' if command == 'chain' else 'quick' if a.quick else 'full', 'started': datetime.datetime.now().isoformat(timespec='seconds'),
            't0': time.time(), 'machine': machine(), 'baseline': baseline.describe() if baseline else None, 'candidate': candidate.describe() if candidate else None,
            'tolerances': TOL, 'games': {}}


def finish(rep, a):
    rep['secs'] = round(time.time() - rep.pop('t0'), 1)
    st = [g['status'] for g in rep['games'].values()]
    rep['status'] = worst(*st) if st else 'ERROR'
    regress = any(s in ('NEW-FAIL', 'REGRESSION') for s in st) and rep['command'] != 'baseline'
    rep['exit'] = 1 if regress else 2 if 'ERROR' in st or not st else 0
    out = Path(a.out) if a.out else ROOT / 'reports' / f'{datetime.datetime.now():%Y%m%d-%H%M%S}-{rep["command"]}'
    out.mkdir(parents=True, exist_ok=True)
    (out / 'report.json').write_text(json.dumps(rep, indent=1))
    md = report_md(rep); (out / 'report.md').write_text(md)
    say('\n' + md + f'\nreport: {out / "report.json"}, {out / "report.md"}')
    return rep['exit']


def report_md(rep):
    b, c = rep.get('baseline'), rep.get('candidate')
    rev = lambda t: f"`{t['rev']}` {t['sha'][:12]}" + (' (+ uncommitted changes)' if t.get('dirty') else '') if t else '–'
    L = [f"## regress.py {rep['command']} ({rep['mode']}): {rep['status']}", '',
         f"Baseline {rev(b)}" + (f", candidate {rev(c)}" if c else '') + f"; {rep['machine']['chip']}, macOS {rep['machine']['macos']}, {rep['machine']['xcode']}; {rep['secs']:g} s", '',
         '| game | status | shaders (base → cand) | newly failing | newly building | changed MSL | interface (new / known) | boot | fps p50 | frame p99 ms | peak MB | prepare s | new RED |',
         '|---|---|---|---|---|---|---|---|---|---|---|---|---|']
    for gid, g in rep['games'].items():
        ch = g.get('chain', {}); sm = g.get('smoke', {})
        bb, cb = ch.get('baseline') or {}, ch.get('candidate') or {}
        shaders = f"{bb.get('ok', '–')}/{bb.get('total', '–')}" + (f" → {cb.get('ok')}/{cb.get('total')}" if cb else '')
        itf = ch.get('interface') or {}
        itf_s = f"{len(itf.get('new', []))} / {len(itf.get('known', []))}" if 'new' in itf else (f"{itf.get('baseline')} bad" if itf else '–')
        runs = sm.get('candidate') or sm.get('baseline') or []
        boot = ('ok' if runs and not any(run_failures(r, sm['route']) for r in runs) else 'FAIL') if runs else '–'
        def mv(k, sm=sm):
            bv = med((r.get(k) for r in sm.get('baseline', []))); cv = med((r.get(k) for r in sm.get('candidate', [])))
            if 'candidate' in sm: return f'{bv} → {cv}'
            return str(bv) if bv is not None else '–'
        nr = len((sm.get('diff') or {}).get('new_red', [])) if 'diff' in sm else '–'
        L.append(f"| {g['name']} `{gid}` | **{g['status']}** | {shaders} | {len(ch.get('newly_failing', [])) if cb else '–'} | {len(ch.get('newly_passing', [])) if cb else '–'} | "
                 f"{(ch.get('changed') or {}).get('msl', '–') if cb else '–'} | {itf_s} | {boot} | {mv('fps')} | {mv('frame_p99')} | {mv('peak_footprint_mb')} | {mv('prepare_s')} | {nr} |")
    for gid, g in rep['games'].items():
        L += ['', f"### {g['name']} `{gid}`: {g['status']}"]
        L += [f'- {x}' for x in g['reasons']] + [f'- known (baseline too): {x}' for x in g['known']]
        ch = g.get('chain', {})
        for x in ch.get('newly_failing', [])[:30]: L.append(f"  - newly failing `{x['key']}` {x['status']}: {x['error'][:120]}")
        for x in ch.get('added_failing', [])[:30]: L.append(f"  - new shader failing `{x['key']}` {x['status']}: {x['error'][:120]}")
        if ch.get('changed', {}).get('keys'): L.append('  - changed shaders: ' + ', '.join(f'`{k}`' for k in ch['changed']['keys'][:40]) + (' …' if ch['changed']['shaders'] > 40 else ''))
        itf = ch.get('interface') or {}
        for x in (itf.get('new', []) + itf.get('known', []))[:20]:
            L.append(f"  - {'new' if x in itf.get('new', []) else 'known'} interface: vs `{x['vs']}` {x['entry']} → ps `{x['ps']}`: " + ', '.join(f'{l} not written' for l in x['missing']) + ', '.join(x['type']))
        d = (g.get('smoke') or {}).get('diff') or {}
        for x in d.get('new_red', [])[:15]: L.append(f"  - new RED ×{x['count']}: `{x['text']}`")
        if d.get('shots'): L.append('  - screenshots (s: dHash bits / RGB diff / baseline noise): ' + ', '.join(f"{t}: {v['dhash_bits']}/{v['rgb_diff']}/{v['baseline_noise']}" for t, v in d['shots'].items()))
        sm = g.get('smoke') or {}
        for label in ('baseline', 'candidate'):
            for r in sm.get(label, []):
                pb = r.get('prebuild') or {}
                L.append(f"  - {label}: exit {r.get('exit')}, first frame {r.get('first_frame_s')} s, max frame {r.get('max_frame')}, reached {r.get('reached')}, prepare {r.get('prepare_s')} s"
                         + (f", prebuild {pb.get('wall_s')} s ({pb.get('built', 0):g} built, {pb.get('failed', 0):g} failed)" if pb else '')
                         + f", fps {r.get('fps')}, p50/p99 {r.get('frame_p50')}/{r.get('frame_p99')} ms, peak {r.get('peak_footprint_mb')} MB" + (', busy Mac' if r.get('busy') else '') + (', window covered' if r.get('covered') else '')
                         + (f", missing shader libraries {red_counts(r)[MISSING_LIB]}" if red_counts(r)[MISSING_LIB] else '')
                         + (', hang: state dump in log.txt' if r.get('hang_dump') else '') + (f", thread stacks {r['hang_sample']}" if r.get('hang_sample') else ''))
        rp = g.get('replay')
        if rp:
            c = rp['capture']; L.append(f"  - replay of frame {c['frame']} (captured with {c['tree']}, chain {c['chain']}, {c['date']}; noise {c['noise_px']} pixels, tolerance {replay_tolerance(c['noise_px'])})")
            for label in ('baseline', 'candidate'):
                r = rp[label]; xs = r['replays']
                L.append(f"  - {label}: exit {r['exit']}, {sum(x['same'] for x in xs)} of {len(xs)} equal the live frame, at most {max((x['pixels'] or 0 for x in xs), default=0)} pixels differ, {r['secs']} s"
                         + (', busy Mac' if r.get('busy') else '') + ''.join(f"; `{t}`" for t in r['red'][:3]))
        cp = g.get('capture')
        if cp: L.append(f"  - capture: frame {cp['frame']}, chain {cp['chain']}; {cp['matches']} of {cp['repeat']} fresh replays equal the live frame, noise {cp['noise_px']} pixels")
        if g.get('secs'): L.append("  - time: " + ', '.join(f'{k} {v:g} s' for k, v in g['secs'].items()))
    return '\n'.join(L) + '\n'


def validated_text(gid):   # the last green chain per mode, and whether it is the current one
    rows, cur = read_validated(REPO / 'dm/games' / gid / VALIDATED), chain_version()
    return '; '.join(f"{m} chain {r.get('chain', '?')} ({'current' if r.get('chain') == cur else 'old, now ' + str(cur)}) {r.get('date', '?')} {r.get('commit', '?')}" for m, r in rows.items()) or 'never recorded'


def cmd_list(a):
    for g in find_games():
        r = g.route()
        bl = sorted(p.parent.name + '/' + p.stem for p in (game_root(g) / 'baselines').glob('*/smoke-*.json'))
        say(f'{g.id}  {g.name}  {g.kind}  build {g.ver}  route: {"yes" if r else "no (dm/games/" + g.id + "/smoke.tsv)"}  baselines: {", ".join(bl) or "none"}  green: {validated_text(g.id)}')
    return 0


def main():
    global ROOT, GAMES
    ap = argparse.ArgumentParser(description='Regression harness: chain diff, interface check and boot smoke over the local games (see the comment at the top of this file).')
    ap.add_argument('--root', default=os.environ.get('REGRESS_ROOT', ''), help='source trees and reports (REGRESS_ROOT); before the command')
    ap.add_argument('--games-dir', default=os.environ.get('REGRESS_GAMES', ''), help='the NSP folders with their Mac builds (REGRESS_GAMES); before the command')
    sub = ap.add_subparsers(dest='cmd', required=True)
    def common(p, smoke=True):
        p.add_argument('--games', help='title IDs, comma-separated (default: every game with a Mac build, and for the runs a smoke route)')
        p.add_argument('--jobs', type=int, help='workers for the shader builds (default: the cores; a build pauses while another process holds the measuring lock)')
        p.add_argument('--out', help='the report folder (default <root>/reports/<date-time>-<command>)')
        p.add_argument('--min-free-gb', type=float, default=3.0, help='stop when the internal disk has less free once Metal\'s idle build folders are removed (scripts/clean_metal_cache.py; default 3)')
        p.add_argument('--lock', default=os.environ.get('DM_MEASURE_LOCK', ''), help='the measuring lock shared with bench.py --lock (DM_MEASURE_LOCK): held while a game runs; shader builds pause while another process holds it')
        if smoke:
            p.add_argument('--quick', action='store_true', help='the chain checks and a short boot (the route\'s quick seconds, no prebuild)')
            p.add_argument('--no-smoke', action='store_true', help='no game runs')
            p.add_argument('--record', action='store_true', help='write dm/games/<id>/validated.tsv for each game that is green after a boot run (chain, commit, mode, date, machine)')
            p.add_argument('--runs', type=int, default=1, help='runs per revision (default 1)')
            p.add_argument('--wait-idle', type=float, default=900, help='seconds to wait for other builds to end before a run (default 900)')
            p.add_argument('--rewrite', action='store_true', help='rewrite the modules with each revision\'s rewriter (default only when the rewriters differ)')
            p.add_argument('--no-hud', action='store_true', help='no Metal performance HUD')
            p.add_argument('--env', action='append', default=[], help='KEY=VALUE for every run (repeatable)')
            p.add_argument('--prebuild-limit', type=float, default=1200, help='the longest pipeline prebuild (default 1200 s)')
            p.add_argument('--prebuild-hang', type=float, default=120, help='seconds without prebuild progress that count as a hang (default 120)')
    p = sub.add_parser('baseline', help='record the runs of a revision'); p.add_argument('--rev', default='main'); common(p)
    p = sub.add_parser('check', help='compare a candidate with the stored baseline'); p.add_argument('--baseline'); p.add_argument('--candidate', default='worktree'); common(p)
    p = sub.add_parser('chain', help='the static checks only'); p.add_argument('--baseline'); p.add_argument('--candidate', default='worktree'); common(p, smoke=False)
    p = sub.add_parser('capture', help='capture one frame per game (the route\'s capture frame) and measure its replay noise'); p.add_argument('--rev', default='main')
    p.add_argument('--repeat', type=int, default=8, help='fresh replays that measure the capture\'s noise (default 8)')
    p.add_argument('--capture-limit', type=float, default=600, help='seconds the game may take to reach the frame and write it (default 600: a covered window runs at a third of the rate)'); common(p)
    p = sub.add_parser('replay', help='replay each game\'s capture against a baseline and a candidate'); p.add_argument('--baseline'); p.add_argument('--candidate', default='worktree')
    p.add_argument('--repeat', type=int, default=3, help='fresh replays per revision (default 3)')
    p.add_argument('--wait-idle', type=float, default=900, help='seconds to wait for other builds to end before replaying (default 900)'); common(p, smoke=False)
    p = sub.add_parser('usage', help='write each game\'s usage manifest (names and counts)'); p.add_argument('--rev', default='worktree'); common(p)
    p.add_argument('--write', action='store_true', help='also write it to dm/games/<id>/usage.tsv of this checkout')
    p = sub.add_parser('impact', help='the games a change can affect'); p.add_argument('range', help='<base>..<head>, or one commit')
    p.add_argument('--manifest', action='append', default=[], help='a usage.tsv not in the profiles yet (<root>/<id>/usage/<tree>.tsv)')
    p.add_argument('--all', action='store_true', help='list the games without a manifest too'); p.add_argument('--out')
    sub.add_parser('list', help='the games, routes and baselines')
    a = ap.parse_args()
    missing = [o for o, v in (('--root (REGRESS_ROOT)', a.root), ('--games-dir (REGRESS_GAMES)', a.games_dir)) if not v]
    if missing and a.cmd != 'impact': ap.error(f'set {" and ".join(missing)}: where the harness keeps its trees and reports, and the folder of the games\' NSP folders, for example '
                         f'regress.py --root <drive>/harness --games-dir <drive>/nsp {a.cmd} ... (the options go before the command)')
    ROOT, GAMES = Path(a.root), Path(a.games_dir)
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))   # a stop runs the finally blocks: a game or a shader build in its own process group is stopped too
    try:
        if a.cmd == 'list': return cmd_list(a)
        if a.cmd == 'impact': return cmd_impact(a)
        ROOT.mkdir(parents=True, exist_ok=True); (ROOT / 'tmp').mkdir(exist_ok=True)
        if a.cmd == 'chain': a.quick = False; a.no_smoke = True; a.rewrite = False
        if a.cmd == 'replay': a.quick = False
        a.lock = a.pause_lock = Path(a.lock) if a.lock else None
        a.jobs = a.jobs or os.cpu_count() or 8
        a.tools_fp = toolchain_fp()
        free = check_disk(a.min_free_gb, clean=True); say(f'internal disk: {free:.1f} GB free; root {ROOT}; {a.jobs} workers')
        return {'baseline': cmd_baseline, 'check': cmd_check, 'usage': cmd_usage, 'chain': lambda a: cmd_check(a, smoke=False), 'capture': cmd_capture, 'replay': cmd_replay}[a.cmd](a)
    except HarnessError as e:
        print(f'[RED] regress.py: {e}', file=sys.stderr); return 2


if __name__ == '__main__':
    sys.exit(main())
