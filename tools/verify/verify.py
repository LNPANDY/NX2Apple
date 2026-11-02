#!/usr/bin/env python3
"""Check that every feature still behaves as written down (tools/verify/README.md).

The expectations are one Markdown file per feature in tools/verify/expectations/. Each is one line with an ID:

    - cloud-saves-04: Given ..., when ..., then ...
    - cloud-saves-02: The Mac launcher shows ... (gap: #499)
    - cloud-saves-09: A save made on the iPhone reaches the Mac ... (manual)

A test binds to an ID with a comment on the line(s) above it: `// expects: cloud-saves-04` in Swift, `# expects: ...` in Python.
The checks of the real Mac below (`step_...`) bind the same way.

Commands (Python 3.9+, stdlib only):
  list                   every expectation with its state (holds, gap, manual) and what checks it
  lint                   the rules of tools/tests/test_verify.py: every expectation is checked or marked, every marker names one
  auto                   run the test suites (frontend, frontend-ios, Qt, tools) and tools/engine.py check, report per expectation
  local                  run the checks of this Mac and its installed NX2Apple (same as --target installed)
  manual                 ask the manual expectations one by one (y, n or s for skip)
  all                    auto, local and manual

Options:
  --target repo|installed  repo is auto, installed is local
  --only PREFIX          only the expectations whose ID starts with PREFIX (auto then runs only their tests)
  --home DIR             read this folder as the home folder (local). The checks of the machine itself are skipped
  --fixture NAME         like --home, with tools/verify/fixtures/NAME.json unpacked into a temporary home
  --candidate DIR        the folder `tools/try-pr vX.Y.Z-rcN --dir DIR` made, for engine-07
  --out DIR              where the Markdown report goes. Default tools/verify/out (git-ignored)

Exit status: 1 when a check fails or a gap check passes (the gap may be closed), 2 when the expectations themselves are wrong.
"""
import argparse
import datetime
import json
import os
import platform
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
EXPECTATIONS = HERE / 'expectations'

LINE = re.compile(r'^- ([a-z0-9]+(?:-[a-z0-9]+)*-\d{2}): (.+?)(?:\s+\((gap: #\d+|manual)\))?\s*$')
MARKER = re.compile(r'(?://|#)\s*expects:\s*([a-z0-9, -]+?)\s*$')

# Where tests live, and the suite that runs them.
SOURCES = [
    ('frontend', 'frontend/Tests', '.swift'),
    ('frontend-ios', 'frontend-ios/Tests', '.swift'),
    ('qt', 'frontend-qt/tests', '.py'),
    ('tools', 'tools/tests', '.py'),
    ('step', 'tools/verify/verify.py', '.py'),
]
SWIFT_TEST = re.compile(r'^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:private|static|nonisolated)\s+)*func\s+(\w+)\s*\(')
PY_TEST = re.compile(r'^\s*def\s+((?:test|step)_\w+)\s*\(')
SWIFT_CLASS = re.compile(r'^(?:@\w+(?:\([^)]*\))?\s+)*(?:final\s+)?(?:class|struct)\s+(\w+Tests)\b')   # a test type, by name
PY_CLASS = re.compile(r'^class\s+(\w+)')
EXPECTED_FAIL = ('XCTExpectFailure', 'expectedFailure')


# ---- expectations and markers ----

def load_expectations(root=ROOT):
    """ID -> dict(id, text, feature, gap, manual, file, line). A malformed line or a repeated ID is a problem."""
    found, problems = {}, []
    for path in sorted((Path(root) / 'tools/verify/expectations').glob('*.md')):
        for n, raw in enumerate(path.read_text(encoding='utf-8').splitlines(), 1):
            if not raw.startswith('- '):
                continue
            m = LINE.match(raw)
            if not m:
                problems.append(f'{path.name}:{n}: not "- <feature>-NN: <sentence>": {raw}')
                continue
            ident, text, mark = m.groups()
            if not ident.startswith(path.stem + '-'):
                problems.append(f'{path.name}:{n}: {ident} does not start with the file name {path.stem}-')
            if ident in found:
                problems.append(f'{path.name}:{n}: {ident} is there twice')
            found[ident] = dict(id=ident, text=text, feature=path.stem, file=path.name, line=n,
                                gap=mark[5:] if mark and mark.startswith('gap') else None, manual=mark == 'manual')
    return found, problems


def _files(root, where, ext):
    p = Path(root) / where
    return [p] if p.is_file() else sorted(f for f in p.rglob('*' + ext) if '.build' not in f.parts)


def scan_markers(root=ROOT):
    """Every `expects:` marker with the test (or step) under it: dict(id, suite, file, line, cls, test, expected_fail)."""
    out = []
    for suite, where, ext in SOURCES:
        for f in _files(root, where, ext):
            lines = f.read_text(encoding='utf-8').splitlines()
            pattern, klass = (SWIFT_TEST, SWIFT_CLASS) if ext == '.swift' else (PY_TEST, PY_CLASS)
            starts = [i for i, l in enumerate(lines) if pattern.match(l)]
            cls = None
            for i, l in enumerate(lines):
                c = klass.match(l)
                if c:
                    cls = c.group(1)
                m = MARKER.search(l)
                if not m:
                    continue
                nxt = next((s for s in starts if s > i), None)
                test = pattern.match(lines[nxt]).group(1) if nxt is not None else None
                end = next((s for s in starts if s > nxt), len(lines)) if nxt is not None else i
                body = '\n'.join(lines[i:end])
                for ident in filter(None, (x.strip() for x in m.group(1).split(','))):
                    out.append(dict(id=ident, suite=suite, file=str(f.relative_to(root)), line=i + 1, cls=cls, test=test,
                                    expected_fail=any(w in body for w in EXPECTED_FAIL)))
    return out


def lint(root=ROOT):
    """The three rules, plus the form of the files. Returns the problems, empty when all is well."""
    exps, problems = load_expectations(root)
    marks = scan_markers(root)
    bound = {}
    for m in marks:
        where = f"{m['file']}:{m['line']}"
        if m['test'] is None:
            problems.append(f"{where}: the marker for {m['id']} has no test under it")
        if m['id'] not in exps:
            problems.append(f"{where}: {m['id']} is not an expectation in tools/verify/expectations")
            continue
        bound.setdefault(m['id'], []).append(m)
    for e in exps.values():
        ms = bound.get(e['id'], [])
        if e['manual']:
            if ms:
                problems.append(f"{e['file']}:{e['line']}: {e['id']} is manual but a test checks it: drop (manual)")
        elif e['gap']:
            for m in ms:
                if not m['expected_fail']:
                    problems.append(f"{m['file']}:{m['line']}: {e['id']} is a gap ({e['gap']}), so its test must expect the "
                                    "failure (XCTExpectFailure, @unittest.expectedFailure). If the gap is closed, drop the gap mark")
        elif not ms:
            problems.append(f"{e['file']}:{e['line']}: {e['id']} has no test. Add `expects: {e['id']}` above one, "
                            "or mark the line (gap: #issue) or (manual)")
        else:
            for m in ms:
                if m['expected_fail']:
                    problems.append(f"{m['file']}:{m['line']}: {e['id']} holds, but its test expects a failure: "
                                    "mark the line (gap: #issue) or drop the expected failure")
    return problems


def state(e):
    return 'manual' if e['manual'] else ('gap' if e['gap'] else 'holds')


# ---- the suites ----

def _suites(only_tests):
    """name -> (cwd, [commands]). only_tests: suite -> [marker] to run only those tests, or None for everything."""
    def swift(suite):
        cmd = ['swift', 'test']
        if only_tests is not None:
            names = [f"{m['cls']}/{m['test']}" if suite == 'frontend' else m['test'] for m in only_tests.get(suite, [])]
            cmd += ['--filter', '|'.join(re.escape(n) for n in names)]
        return cmd

    def py(start, suite):
        cmd = [sys.executable, '-m', 'unittest', 'discover', '-v', '-s', start]
        for m in (only_tests or {}).get(suite, []):
            cmd += ['-k', m['test']]
        return cmd

    return {
        'frontend': ('frontend', [[sys.executable, '../tools/engine.py', '-q', 'sync'], ['swift', 'build'], swift('frontend')]),
        'frontend-ios': ('frontend-ios', [swift('frontend-ios')]),
        'qt': ('.', [py('frontend-qt/tests', 'qt')]),
        'tools': ('.', [py('tools/tests', 'tools')]),
    }


def parse_results(text):
    """Test results in swift test (XCTest and Swift Testing) and unittest -v output: key -> 'pass' or 'fail'.
    XCTest keys are Class.test, Swift Testing keys *.name, unittest keys Class.test_name."""
    res = {}
    for cls, test, outcome in re.findall(r"Test Case '-\[[\w.]*?(\w+) (\w+)\]' (passed|failed)", text):
        res[f'{cls}.{test}'] = 'pass' if outcome == 'passed' else 'fail'
    for mark, name, outcome in re.findall(r'^\S*\s*([✔✘]) Test (\w+)\([^)\n]*\)[^\n]*? (passed|failed) after', text, re.M):
        res[f'*.{name}'] = 'pass' if outcome == 'passed' else 'fail'
    # unittest -v: the header, then the status at the end of that line or of a later one (a docstring or what the test printed
    # comes between), before the next header
    lines = text.splitlines()
    header = re.compile(r'^(test_\w+) \(([\w.]+)\)')
    status = re.compile(r'(?:^|\.\.\. )(ok|FAIL|ERROR|expected failure|unexpected success|skipped\b.*)$')
    for i, l in enumerate(lines):
        m = header.match(l)
        if not m:
            continue
        parts = m.group(2).split('.')
        cls = parts[-2] if parts[-1] == m.group(1) and len(parts) > 1 else parts[-1]
        for j in range(i, min(i + 200, len(lines))):
            if j > i and header.match(lines[j]):
                break
            s = status.search(lines[j])
            if s:
                word = s.group(1).split()[0] if s.group(1).startswith('skipped') else s.group(1)
                res[f'{cls}.{m.group(1)}'] = {'ok': 'pass', 'expected failure': 'pass', 'skipped': 'skip'}.get(word, 'fail')
                break
    return res


def run_suites(names, only_tests, logdir):
    """Run each suite, its log in logdir. Returns (results, suite -> 'pass'|'fail'|'skip: why')."""
    results, outcome = {}, {}
    suites = _suites(only_tests)
    for name in names:
        cwd, cmds = suites[name]
        if cmds[-1][0] == 'swift' and not shutil.which('swift'):
            outcome[name] = 'skip: no swift on this machine'
            continue
        if only_tests is not None and not only_tests.get(name):
            outcome[name] = 'skip: no selected test in it'
            continue
        print(f'verify: running {name} ...', flush=True)
        log, ok = [], True
        for cmd in cmds:
            p = subprocess.run(cmd, cwd=ROOT / cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors='replace')
            log.append(f'$ {" ".join(cmd)}\n{p.stdout}')
            if p.returncode != 0:
                ok = False
                break
        text = '\n'.join(log)
        (logdir / f'{name}.log').write_text(text, encoding='utf-8')
        results.update(parse_results(text))
        failed = sorted(k for k, v in parse_results(text).items() if v == 'fail')
        outcome[name] = 'pass' if ok else 'fail' + (f" ({', '.join(failed[:8])})" if failed else '')
    return results, outcome


def marker_result(m, results, outcome):
    s = outcome.get(m['suite'], 'skip')
    if s.startswith('skip'):
        return 'skip'
    key = f"{m['cls']}.{m['test']}" if m['suite'] in ('frontend', 'qt', 'tools') else f"*.{m['test']}"
    if m['suite'] == 'frontend-ios' and key not in results:
        key = f"{m['cls']}.{m['test']}"   # an XCTest case in the iPhone package
    return results.get(key, 'fail' if s.startswith('fail') else 'missing')


# ---- the checks of this Mac and its installed NX2Apple ----

class Machine:
    def __init__(self, home=None, candidate=None):
        self.real = home is None
        self.home = Path(home) if home else Path.home()
        self.candidate = Path(candidate) if candidate else None

    @property
    def support(self):
        return self.home / 'Library/Application Support'

    @property
    def drive(self):
        return self.home / 'Library/Mobile Documents/com~apple~CloudDocs'

    def domain(self, name):
        """A preferences domain as a dict: `defaults export` on the real home (cfprefsd has the current values), the plist file
        under Library/Preferences otherwise."""
        if self.real and shutil.which('defaults'):
            p = subprocess.run(['defaults', 'export', name, '-'], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
            if p.returncode == 0 and p.stdout:
                return plistlib.loads(p.stdout)
        f = self.home / 'Library/Preferences' / f'{name}.plist'
        return plistlib.loads(f.read_bytes()) if f.is_file() else {}

    def games(self):
        """(title ID, env.txt lines as dict, first line of a key wins) for every game folder under nxnative."""
        base = self.support / 'nxnative'
        for d in sorted(base.iterdir()) if base.is_dir() else []:
            env = d / 'env.txt'
            if d.is_dir() and env.is_file():
                yield d.name.upper(), read_env(env.read_text(encoding='utf-8', errors='replace'))

    def sync_folder(self, title, env):
        """The folder a Mac game syncs its save through, as dm/host/save_sync.c resolves DM_SAVE_SYNC, and where the value came
        from. env.txt first, then the saved choice cloudSaves.folder of the game's own domain (dm/mac/launcher.c)."""
        value, source = env.get('DM_SAVE_SYNC'), 'env.txt'
        if value is None:
            value = self.domain(f'org.nxnative.{title.lower()}').get('cloudSaves.folder')
            source = 'saved choice'
        if not value or value == '0':
            return None, source
        folder = self.drive / 'nxnative Saves' if value == 'icloud' else Path(value)
        return folder, source


def read_env(text):
    """env.txt as dm/mac/launcher.c reads it: KEY=VALUE, # starts a comment, spaces around the key dropped, first line wins."""
    out = {}
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith('#') or '=' not in line or line.startswith('='):
            continue
        k, v = line.split('=', 1)
        out.setdefault(k.strip(), v.rstrip('\r').strip())
    return out


def save_file(folder, title):
    """<folder>/<title ID>/save.dmsync, or the folder itself when it is the game's own folder (save_sync.c)."""
    base = folder if folder.name.upper() == title else folder / title
    for name in ('save.dmsync', '.save.dmsync.icloud'):   # the second is iCloud's placeholder for a file not downloaded yet
        if (base / name).exists():
            return base / name
    return None


# expects: cloud-saves-08
def step_icloud_drive(m):
    return ('pass', str(m.drive)) if m.drive.is_dir() else ('fail', f'no {m.drive}: iCloud Drive is off for this Mac')


# expects: cloud-saves-01
def step_cloud_sync_folders(m):
    seen, bad = 0, []
    for title, env in m.games():
        folder, source = m.sync_folder(title, env)
        if folder is None:
            continue
        seen += 1
        if not folder.is_dir():
            bad.append(f'{title}: {folder} ({source}) does not exist')
        elif not save_file(folder, title):
            bad.append(f'{title}: {folder} ({source}) holds no {title}/save.dmsync')
    if not seen:
        return 'skip', 'no game syncs its save on this Mac'
    return ('fail', '; '.join(bad)) if bad else ('pass', f'{seen} game(s) sync through a folder that holds their save')


# expects: cloud-saves-03
def step_one_sync_folder_per_game(m):
    if not m.drive.is_dir():
        return 'skip', 'iCloud Drive is off'
    seen, bad = 0, []
    for title, env in m.games():
        folder, _ = m.sync_folder(title, env)
        if folder is None:
            continue
        seen += 1
        ours = save_file(folder, title)
        mine = ours.stat().st_mtime if ours else 0
        for other in sorted(m.drive.iterdir()):
            if not other.is_dir() or other.resolve() == folder.resolve():
                continue
            theirs = save_file(other, title)
            if theirs and theirs.stat().st_mtime > mine:
                when = datetime.datetime.fromtimestamp(theirs.stat().st_mtime).isoformat(timespec='minutes')
                bad.append(f'{title}: this Mac syncs through {folder}, but {other} holds a newer save ({when}). '
                           'The iPhone or another Mac uses that folder')
    if not seen:
        return 'skip', 'no game syncs its save on this Mac'
    return ('fail', '; '.join(bad)) if bad else ('pass', f'{seen} game(s), no newer save in another folder')


# expects: saves-06
def step_env_dm_save(m):
    bad = [f"{t}: DM_SAVE={env['DM_SAVE']}" for t, env in m.games() if env.get('DM_SAVE')]
    return ('fail', '; '.join(bad) + '. The Saves sheet copies to another folder (#490)') if bad else ('pass', 'no env.txt sets DM_SAVE')


# expects: settings-06
def step_env_hides_saved_choice(m):
    bad = []
    for title, env in m.games():
        prefs = m.domain(f'org.nxnative.{title.lower()}')
        hidden = sorted(k for k in env if f'launcher.{k}' in prefs)
        if hidden:
            bad.append(f"{title}: {', '.join(hidden)} in env.txt hide the saved choice")
    return ('fail', '; '.join(bad)) if bad else ('pass', 'no env.txt line hides a saved choice')


# expects: settings-07
def step_preferences_paths(m):
    prefs = m.domain('org.nxnative.NSPortBuilder')
    if not prefs:
        return 'skip', 'no preferences of org.nxnative.NSPortBuilder (the launcher never ran here)'
    bad = []
    for key in ('repoPath', 'shellRoot'):
        v = prefs.get(key)
        if v and not Path(v).is_dir():
            bad.append(f'{key}={v} does not exist')
    root = prefs.get('shellRoot')
    if root and (Path(root).parent == Path(root) or re.fullmatch(r'/Volumes/[^/]+/?', root)):
        bad.append(f'shellRoot={root} is the root of a volume (#492)')
    return ('fail', '; '.join(bad)) if bad else ('pass', 'repoPath and shellRoot exist')


# expects: engine-06
def step_engine_store(m):
    ident = m.domain('org.nxnative.NSPortBuilder').get('engineID')
    if not ident:
        return 'skip', 'no engineID in the preferences (a checkout build, or the launcher never ran)'
    tree = m.support / 'NX2Apple/engine' / ident
    got = (tree / '.engine-id').read_text().strip() if (tree / '.engine-id').is_file() else None
    return ('pass', ident) if got == ident else ('fail', f'engineID {ident}, but {tree}/.engine-id is {got}')


# expects: engine-07
def step_candidate_engine(m):
    if not m.candidate:
        return 'skip', 'no --candidate DIR (the folder tools/try-pr vX.Y.Z-rcN --dir DIR made)'
    bundled = m.candidate / 'NX2Apple.app/Contents/Resources/engine/.engine-id'
    if not bundled.is_file():
        return 'fail', f'no {bundled}'
    ident = bundled.read_text().strip()
    manifest = m.candidate / 'download/latest.json'
    if manifest.is_file():
        want = json.loads(manifest.read_text()).get('engine_id')
        if want != ident:
            return 'fail', f'the app carries {ident}, latest.json names {want}'
    used = m.domain('org.nxnative.NSPortBuilder').get('engineID')
    if used != ident:
        return 'fail', f'the launcher uses {used}, the candidate carries {ident}: start the candidate once, then run this again'
    return 'pass', ident + (' (no latest.json: not a tag)' if not manifest.is_file() else '')


def _minimum_xcode():
    text = (ROOT / 'frontend/Sources/NX2Apple/OnboardingState.swift').read_text(encoding='utf-8')
    return [int(x) for x in re.search(r'minimumXcode\s*=\s*\[([\d, ]+)\]', text).group(1).split(',')]


# expects: setup-04
def step_xcode_version(m):
    if not shutil.which('xcodebuild'):
        return 'fail', 'no xcodebuild'
    p = subprocess.run(['xcodebuild', '-version'], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    v = re.search(r'^Xcode ([\d.]+)', p.stdout, re.M)
    if not v:
        return 'fail', p.stdout.strip().splitlines()[-1] if p.stdout.strip() else 'xcodebuild -version said nothing'
    have, want = [int(x) for x in v.group(1).split('.')], _minimum_xcode()
    have += [0] * (len(want) - len(have))
    ok = have[:len(want)] >= want
    return ('pass' if ok else 'fail', f"Xcode {v.group(1)}, NVN games need {'.'.join(map(str, want))}")


# expects: setup-05
def step_ios_sdk(m):
    p = subprocess.run(['xcrun', '--sdk', 'iphoneos', '--show-sdk-version'], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    return ('pass', 'iOS SDK ' + p.stdout.strip()) if p.returncode == 0 else ('fail', p.stdout.strip() or 'no iOS SDK')


# expects: install-05
def step_devicectl_list(m):
    """Read-only: `devicectl list devices`. Nothing is installed, copied or launched."""
    with tempfile.TemporaryDirectory() as tmp:
        out = Path(tmp) / 'devices.json'
        try:
            p = subprocess.run(['xcrun', 'devicectl', 'list', 'devices', '--json-output', str(out)],
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=90)
        except (OSError, subprocess.TimeoutExpired) as e:
            return 'fail', f'devicectl did not answer: {e}'
        if not out.is_file():
            return 'fail', (p.stdout.strip().splitlines() or ['no JSON'])[-1]
        devices = (json.loads(out.read_text()).get('result') or {}).get('devices')
    if not isinstance(devices, list):
        return 'fail', 'the JSON has no result.devices'
    without = [d.get('deviceProperties', {}).get('name', '?') for d in devices
               if 'reality' not in (d.get('hardwareProperties') or {})]
    note = f", without hardwareProperties.reality: {', '.join(without)} (#488)" if without else ''
    return 'pass', f'{len(devices)} device(s){note}'


# expects: engine-01
def step_engine_check(m):
    p = subprocess.run([sys.executable, 'tools/engine.py', 'check'], cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    return ('pass' if p.returncode == 0 else 'fail', (p.stdout.strip().splitlines() or [''])[-1])


MACHINE_WIDE = {'step_xcode_version', 'step_ios_sdk', 'step_devicectl_list'}   # skipped with --home or --fixture
AUTO_STEPS = {'step_engine_check'}                                               # part of auto, not of local


def unpack_fixture(name, into):
    """tools/verify/fixtures/NAME.json -> a home folder: files (text, $HOME replaced), mtimes, preference plists."""
    spec = json.loads((HERE / 'fixtures' / f'{name}.json').read_text(encoding='utf-8'))
    home = Path(into)
    for rel, text in spec.get('files', {}).items():
        f = home / rel
        f.parent.mkdir(parents=True, exist_ok=True)
        f.write_text(text.replace('$HOME', str(home)), encoding='utf-8')
    for rel in spec.get('folders', []):
        (home / rel).mkdir(parents=True, exist_ok=True)
    for rel, when in spec.get('mtimes', {}).items():
        t = datetime.datetime.fromisoformat(when).timestamp()
        os.utime(home / rel, (t, t))
    for domain, values in spec.get('preferences', {}).items():
        f = home / 'Library/Preferences' / f'{domain}.plist'
        f.parent.mkdir(parents=True, exist_ok=True)
        f.write_bytes(plistlib.dumps({k: (v.replace('$HOME', str(home)) if isinstance(v, str) else v) for k, v in values.items()}))
    return spec


# ---- running and reporting ----

def run_step(name, machine):
    if not machine.real and name in MACHINE_WIDE:
        return 'skip', 'a check of the machine itself, not of the home folder given'
    try:
        result, note = globals()[name](machine)
        return result, note.replace(str(machine.home), '~')
    except Exception as e:   # a check that breaks is a failed check, with the reason
        return 'fail', f'{type(e).__name__}: {e}'


def evaluate(e, results):
    """One expectation from the results of its checks: holds, gap, FAIL, skip or manual, and a note."""
    if e['manual']:
        return 'manual', ''
    rs = results.get(e['id'], [])
    if not rs:
        return ('gap', f"{e['gap']}, no test yet") if e['gap'] else ('skip', 'not run')
    if any(r == 'fail' or r == 'missing' for r, _ in rs):
        notes = '; '.join(n for r, n in rs if r in ('fail', 'missing'))
        if e['gap']:
            return 'FAIL', f"gap {e['gap']}: its expected failure did not happen, the gap may be closed. Drop the gap mark and the expected failure. {notes}"
        return 'FAIL', notes
    if all(r == 'skip' for r, _ in rs):
        return 'skip', '; '.join(n for _, n in rs)
    return ('gap', e['gap']) if e['gap'] else ('holds', '; '.join(n for _, n in rs if n))


def versions(machine):
    def out(cmd, cwd=ROOT):
        try:
            return subprocess.run(cmd, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, timeout=30).stdout.strip()
        except (OSError, subprocess.TimeoutExpired):
            return ''
    app = re.search(r'appVersion = "([^"]+)"', (ROOT / 'frontend/Sources/NX2Apple/ContentView.swift').read_text(encoding='utf-8'))
    try:
        sys.path.insert(0, str(ROOT / 'tools'))
        import engine   # tools/engine.py: the engine_id this checkout's pin and series make
        engine_id = engine.engine_id(ROOT)
    except Exception as e:
        engine_id = f'? ({e})'
    rows = [
        ('Date', datetime.datetime.now().astimezone().isoformat(timespec='seconds')),
        ('Checkout', f"{out(['git', 'rev-parse', '--short', 'HEAD'])} on {out(['git', 'rev-parse', '--abbrev-ref', 'HEAD'])}"
                     + (' (local changes)' if out(['git', 'status', '--porcelain']) else '')),
        ('App version', app.group(1) if app else '?'),
        ('Engine pin', (ROOT / '.upstream-ref').read_text().strip()[:12] if (ROOT / '.upstream-ref').is_file() else '?'),
        ('Checkout engine_id', engine_id),
        ('macOS', out(['sw_vers', '-productVersion']) or platform.platform()),
        ('Xcode', out(['xcodebuild', '-version']).replace('\n', ', ') or 'none'),
        ('Python', platform.python_version()),
        ('Home read', str(machine.home) + ('' if machine.real else ' (not this Mac)')),
    ]
    if machine.real:
        prefs = machine.domain('org.nxnative.NSPortBuilder')
        rows.append(('Installed launcher engine', f"{prefs.get('engineChannel', '?')} {prefs.get('engineID', 'none')}"))
    return rows


def ask_manual(exps):
    answers = {}
    if not sys.stdin.isatty():
        print('verify: no terminal, the manual expectations are skipped')
        return {e['id']: ('skip', 'no terminal') for e in exps}
    for e in exps:
        while True:
            a = input(f"\n{e['id']}: {e['text']}\n  holds? [y]es, [n]o, [s]kip: ").strip().lower()[:1]
            if a in ('y', 'n', 's'):
                break
        note = input('  what happened: ').strip() if a == 'n' else ''
        answers[e['id']] = {'y': ('holds', ''), 'n': ('FAIL', note), 's': ('skip', 'skipped')}[a]
    return answers


def main(argv=None):
    ap = argparse.ArgumentParser(prog='tools/verify', description=__doc__.split('\n')[0])
    ap.add_argument('command', nargs='?', choices=['list', 'lint', 'auto', 'local', 'manual', 'all'])
    ap.add_argument('--target', choices=['repo', 'installed'])
    ap.add_argument('--only', default='')
    ap.add_argument('--home')
    ap.add_argument('--fixture')
    ap.add_argument('--candidate')
    ap.add_argument('--out', default=str(HERE / 'out'))
    a = ap.parse_args(argv)
    command = a.command or {'repo': 'auto', 'installed': 'local', None: 'list'}[a.target]

    problems = lint()
    exps, _ = load_expectations()
    marks = scan_markers()
    if problems:
        print('verify: the expectations and their markers do not match:', *problems, sep='\n  ')
        if command != 'list':
            return 2
    selected = [e for e in exps.values() if e['id'].startswith(a.only)]
    by_id = {}
    for m in marks:
        by_id.setdefault(m['id'], []).append(m)

    if command in ('list', 'lint'):
        if command == 'list':
            for e in selected:
                checks = ', '.join(f"{m['cls'] + '.' if m['cls'] and m['suite'] != 'step' else ''}{m['test']}" for m in by_id.get(e['id'], []))
                print(f"{state(e):7} {e['id']:18} {e['text']}" + (f'\n{"":27}checked by {checks}' if checks else ''))
        counts = {s: sum(state(e) == s for e in selected) for s in ('holds', 'gap', 'manual')}
        print(f"verify: {len(selected)} expectations: {counts['holds']} hold, {counts['gap']} gap, {counts['manual']} manual"
              + (', no problems' if not problems else f', {len(problems)} problems'))
        return 1 if problems else 0

    home_dir = None
    if a.fixture:
        home_dir = tempfile.mkdtemp(prefix=f'verify-{a.fixture}-')
        unpack_fixture(a.fixture, home_dir)
    machine = Machine(home=home_dir or a.home, candidate=a.candidate)
    out = Path(a.out)
    stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
    logdir = out / f'verify-{stamp}'
    logdir.mkdir(parents=True, exist_ok=True)

    results, suite_outcome = {}, {}
    sel_ids = {e['id'] for e in selected}
    if command in ('auto', 'all'):
        only = None
        if a.only:
            only = {}
            for m in marks:
                if m['id'] in sel_ids and m['suite'] != 'step':
                    only.setdefault(m['suite'], []).append(m)
        res, suite_outcome = run_suites(['tools', 'qt', 'frontend-ios', 'frontend'], only, logdir)
        for m in marks:
            if m['id'] in sel_ids and m['suite'] != 'step':
                r = marker_result(m, res, suite_outcome)
                results.setdefault(m['id'], []).append((r, '' if r == 'pass' else f"{m['cls']}.{m['test']} {r}"))
    steps = []
    if command in ('auto', 'all'):
        steps += [m for m in marks if m['suite'] == 'step' and m['test'] in AUTO_STEPS]
    if command in ('local', 'all'):
        steps += [m for m in marks if m['suite'] == 'step' and m['test'] not in AUTO_STEPS]
    for m in steps:
        if m['id'] in sel_ids:
            r, note = run_step(m['test'], machine)
            results.setdefault(m['id'], []).append((r, note))
    manual = {}
    if command in ('manual', 'all'):
        manual = ask_manual([e for e in selected if e['manual']])

    ran = set(results) | set(manual)
    rows = []
    for e in selected:
        if e['id'] in manual:
            st, note = manual[e['id']]
        elif e['id'] in ran or (command in ('auto', 'all') and e['gap'] and not by_id.get(e['id'])):
            st, note = evaluate(e, results)
        else:
            continue
        rows.append((e, st, note))

    width = max([len(e['id']) for e, _, _ in rows] + [10])
    for e, st, note in rows:
        print(f"  {st:6} {e['id']:{width}}  {e['text']}" + (f"\n  {'':6} {'':{width}}  {note}" if note and st != 'holds' else ''))
    counts = {s: sum(st == s for _, st, _ in rows) for s in ('holds', 'FAIL', 'gap', 'skip', 'manual')}
    summary = (f"{counts['holds']} hold, {counts['FAIL']} failed, {counts['gap']} known gaps, {counts['skip']} skipped"
               + (f", {counts['manual']} manual not asked" if counts['manual'] else ''))
    for name, s in suite_outcome.items():
        print(f'  suite {name}: {s}')
    report = out / f'verify-{stamp}.md'
    lines = [f'# tools/verify {command}' + (f' --only {a.only}' if a.only else '') + (f' (fixture {a.fixture})' if a.fixture else ''), '',
             '| | |', '|---|---|'] + [f'| {k} | {v} |' for k, v in versions(machine)] + ['', f'**{summary}**', '']
    if suite_outcome:
        lines += ['| Suite | Result |', '|---|---|'] + [f'| {k} | {v} |' for k, v in suite_outcome.items()] + ['']
    lines += ['| Result | ID | Expectation | Note |', '|---|---|---|---|']
    lines += [f"| {st} | {e['id']} | {e['text']} | {note.replace('|', '/')} |" for e, st, note in rows]
    lines += ['', f'Logs: {logdir}']
    report.write_text('\n'.join(lines) + '\n', encoding='utf-8')
    print(f'verify: {summary}\nverify: report {report}')
    if home_dir:
        shutil.rmtree(home_dir, ignore_errors=True)
    return 1 if counts['FAIL'] else 0


if __name__ == '__main__':
    sys.exit(main())
