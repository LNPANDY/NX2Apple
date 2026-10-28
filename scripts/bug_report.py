#!/usr/bin/env python3
"""Collect what the bug report form asks for into one zip file to attach to an issue, and never any game data.

    python3 scripts/bug_report.py <title ID | path to the .app | NSP folder> [--ios-log FILE] [--out FILE]

The zip holds report.md (one section per field of the bug form, filled in where the script can know it) and the text files below.
ALLOWED is the whole list of what can go in; nothing else is read. Every text file is redacted (home folder -> ~, lines that look like key material dropped) and cut to a size cap.
Exit code: 0 done, 1 the file could not be written, 2 the target was not understood."""
import argparse
import datetime
import os
import plistlib
import re
import subprocess
import sys
import zipfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
CHAIN_H = 'dm/gfx/nvn/dmsh_chain.h'
TOTAL_CAP = 20 * 1024 * 1024    # the zip's text content, before compression
FILE_CAP = 4 * 1024 * 1024      # one file: longer ones keep the first and last half of this
CRASH_MAX, CRASH_DAYS = 3, 7

# The allow-list: the only things this script reads into the bundle. Anything else (RomFS, NSO, NSP, NCA, .metallib, .metal, shader .json, saves, pso_*, screenshots, keys)
# is not on it, so it cannot get in by a new file type turning up.
ALLOWED = (
    '~/Library/Logs/nxnative/<title ID>.log and .prev.log (the Mac app\'s log)',
    '~/Library/Application Support/nxnative/<title ID>/env.txt (the player\'s settings file)',
    'Contents/Resources/dm/env.txt of the app (settings baked in with --env-file)',
    'the app\'s saved choices: launcher.* keys and dataFolder of its preferences domain',
    '<NSP folder>/<title ID>_build/logs/*.log and *.txt (the NSP script\'s step logs; regular text files directly in logs/, nothing else under the NSP folder)',
    'the file given with --ios-log (a text file other than .keys)',
    '~/Library/Logs/DiagnosticReports/ crash reports (.ips, .crash) of dmhost or the app, the newest 3 of the last 7 days',
    'Info.plist of the app (a few keys), game.tsv of the profile (name and build rows), dm/gfx/nvn/dmsh_chain.h, the names of the b-<V> folders in the app\'s Contents/Resources/msl/ or the build\'s shader/, shader/cache/ and shader/ios/',
)

HEX = r'[0-9a-fA-F]'
# "key" (title_key, master_key_00, prod.keys line "aes_kek_generation_source = ...") followed by only separators and then 32 or more hex characters
KEY_LINE = re.compile(rf'(?i)key\w*[\s=:"\'\[\],]*{HEX}{{32,}}')
KEY_LINE2 = re.compile(rf'(?i)(?:title|master|prod|common|aes|kek|rights)[\w ]*[=:]\s*"?{HEX}{{32,}}\b')   # "titlekek_source = <hex>" and the like
SECRET_NAME = re.compile(r'(?i)(key|secret|token|password)')


def redact(text, home):
    """text with the home folder written as ~ and the lines that look like key material dropped; (text, number of dropped lines)"""
    homes = {h for h in (home, os.path.realpath(home)) if h and h != '/'}
    out, dropped = [], 0
    for line in text.splitlines(keepends=True):
        if KEY_LINE.search(line) or KEY_LINE2.search(line):
            dropped += 1; continue
        for h in sorted(homes, key=len, reverse=True): line = line.replace(h, '~')
        out.append(line)
    if dropped: out.append(f'[bug_report: {dropped} line(s) that look like key material were removed]\n')
    return ''.join(out), dropped


def cut(text, cap):
    """Text of at most cap UTF-8 bytes, including the truncation marker."""
    b = text.encode('utf-8', 'replace')
    if len(b) <= cap: return text, False
    mid = b'\n[bug_report: bytes cut here; the first and last parts are kept]\n'
    if cap <= len(mid): return mid[:cap].decode('utf-8'), True
    h = (cap - len(mid)) // 2
    return b[:h].decode('utf-8', 'ignore') + mid.decode('utf-8') + (b[-h:].decode('utf-8', 'ignore') if h else ''), True


def read_text(path):
    """A regular text file's content (over FILE_CAP: both ends only), or None (a .keys file, a symlink, nonregular or binary)."""
    p = Path(path)
    if p.suffix.lower() == '.keys' or p.is_symlink() or not p.is_file(): return None
    with open(p, 'rb') as f:
        if b'\0' in f.read(4096): return None
        f.seek(0, 2); size = f.tell(); f.seek(0)
        if size <= FILE_CAP: return f.read().decode('utf-8', 'replace')
        a = f.read(FILE_CAP // 2); f.seek(size - FILE_CAP // 2)
        return a.decode('utf-8', 'replace') + f'\n[bug_report: {size - FILE_CAP} bytes cut here]\n' + f.read().decode('utf-8', 'replace')


def run_out(cmd, timeout=20):
    try: r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.SubprocessError): return ''
    return r.stdout.strip() if r.returncode == 0 else ''


def read_prefs(bundle_id):
    """the app's saved choices (launcher.* and dataFolder only) from its preferences domain; {} when it has none or defaults is missing"""
    try: r = subprocess.run(['defaults', 'export', bundle_id, '-'], capture_output=True, timeout=20)
    except (OSError, subprocess.SubprocessError): return {}
    if r.returncode: return {}
    try: d = plistlib.loads(r.stdout)
    except Exception: return {}
    return {k: v for k, v in sorted(d.items()) if k.startswith('launcher.') or k == 'dataFolder'}


def resolve(target, base=None):
    """the target as {title_id, app, nsp, build}; None when it is none of a title ID, an .app or an NSP folder"""
    t: dict = {'title_id': None, 'app': None, 'nsp': None, 'build': None}
    if re.fullmatch(r'(?i)[0-9a-f]{16}', target):
        t['title_id'] = target.upper(); return t
    p = Path(target).expanduser()
    if p.is_dir() and p.suffix == '.app':
        try: plist = plistlib.loads((p / 'Contents/Info.plist').read_bytes())
        except Exception: return None
        tid = str(plist.get('DMTitleID', '')).upper()
        if not re.fullmatch(r'[0-9A-F]{16}', tid): return None
        t.update(title_id=tid, app=p); return t
    if p.is_dir():
        builds = sorted(d for d in p.iterdir() if d.is_dir() and re.fullmatch(r'(?i)[0-9a-f]{16}_build', d.name))
        if p.name.endswith('_build') and re.fullmatch(r'(?i)[0-9a-f]{16}_build', p.name): builds, p = [p], p.parent
        if len(builds) != 1: return None
        t.update(title_id=builds[0].name[:16].upper(), nsp=p, build=builds[0]); return t
    return None


def tsv_rows(path):
    try: lines = Path(path).read_text(errors='replace').splitlines()
    except OSError: return []
    return [l.split('\t') for l in lines if l and not l.startswith('#')]


def profile_info(tid, build):
    """(name, [(version, display version)]) from the profile's game.tsv: the repository's, else the NSP script's provisional one"""
    for g in (REPO / 'dm/games' / tid / 'game.tsv', *( [build / 'profile' / tid / 'game.tsv'] if build else [])):
        rows = tsv_rows(g)
        if rows:
            name = next((r[1] for r in rows if r[0] == 'name' and len(r) > 1), None)
            return name, [(r[1], r[2]) for r in rows if r[0] == 'build' and len(r) > 2]
    return None, []


def chain_version():
    try: m = re.search(r'#define DMSH_CHAIN "(.*)"', (REPO / CHAIN_H).read_text())
    except OSError: return None
    return m.group(1) if m else None


def shader_dirs(app, build):
    """Available library folder names only; a build may retain several old chains, so none establishes the chain the player ran."""
    root = app if app else build
    dirs = [app / 'Contents/Resources/msl'] if app else [build / s for s in ('shader', 'shader/cache', 'shader/ios')] if build else []
    found = []
    for d in dirs:
        if d.is_symlink() or not d.is_dir(): continue
        found.extend(p.relative_to(root).as_posix() for p in d.iterdir()
                     if not p.is_symlink() and p.is_dir() and re.fullmatch(r'b-[0-9a-f]+', p.name))
    return sorted(found)


def git_state():
    c = run_out(['git', '-C', str(REPO), 'rev-parse', '--short', 'HEAD'])
    if not c: return None
    return c + (' (modified)' if run_out(['git', '-C', str(REPO), 'status', '--porcelain', '--untracked-files=no']) else '')


def device():
    d = {'Mac': run_out(['sysctl', '-n', 'hw.model']), 'Chip': run_out(['sysctl', '-n', 'machdep.cpu.brand_string']),
         'macOS': run_out(['sw_vers', '-productVersion']), 'Xcode': ' '.join(run_out(['xcodebuild', '-version']).split('\n')[:2]),
         'Metal compiler': (run_out(['xcrun', '-sdk', 'macosx', 'metal', '--version']).split('\n') or [''])[0]}
    return {k: v or 'unknown' for k, v in d.items()}


class Bundle:
    def __init__(self, home, total_cap=TOTAL_CAP, file_cap=FILE_CAP):
        self.home, self.total_cap, self.file_cap = home, total_cap, file_cap
        self.files, self.notes, self.used = {}, [], 0

    def add(self, arc, text, what):
        """add a text file: redacted, cut to the file cap, and refused when the total cap would be passed"""
        text, dropped = redact(text, self.home)
        text, was_cut = cut(text, self.file_cap)
        n = len(text.encode('utf-8', 'replace'))
        if self.used + n > self.total_cap:
            self.notes.append(f'{what}: left out, the 20 MB cap of the bundle is reached'); return
        self.used += n; self.files[arc] = text
        extra = ([f'{dropped} key-like line(s) removed'] if dropped else []) + (['cut to the first and last part'] if was_cut else [])
        self.notes.append(f'{what}: included ({n // 1024} KiB){"; " + "; ".join(extra) if extra else ""}')

    def add_file(self, arc, path, what):
        t = read_text(path) if Path(path).exists() else None
        if t is None: self.notes.append(f'{what}: not found or not a text file ({self.short(path)})')
        else: self.add(arc, t, what)

    def short(self, p): return redact(str(p), self.home)[0]


def crash_reports(home, names, now=None):
    d = Path(home) / 'Library/Logs/DiagnosticReports'
    now = now or datetime.datetime.now().timestamp()
    try: items = [p for p in d.iterdir() if p.suffix in ('.ips', '.crash') and any(p.name.startswith(n) for n in names) and p.is_file() and not p.is_symlink()]
    except OSError: return []
    items = [p for p in items if now - p.stat().st_mtime <= CRASH_DAYS * 86400]
    return sorted(items, key=lambda p: p.stat().st_mtime, reverse=True)[:CRASH_MAX]


def collect(target, ios_log=None, home=None, total_cap=TOTAL_CAP, file_cap=FILE_CAP):
    """the bundle for target: (Bundle, report.md text)"""
    home = home or str(Path.home())
    b = Bundle(home, total_cap, file_cap)
    # report.md contains settings and preferences too. Reserve its maximum size before admitting logs, then account for its actual bytes below.
    report_cap = min(file_cap, total_cap)
    b.used = report_cap
    tid, app, build = target['title_id'], target['app'], target['build']
    plist = {}
    if app:
        try: plist = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        except Exception: b.notes.append('Info.plist: cannot be read')
    bundle_id = plist.get('CFBundleIdentifier') or f'org.nxnative.{tid.lower()}'
    pname, builds = profile_info(tid, build)
    name = plist.get('CFBundleDisplayName') or plist.get('CFBundleName') or pname or 'unknown'
    version = plist.get('CFBundleShortVersionString') or plist.get('CFBundleVersion')
    vtxt = version or (', '.join(f'{dv} ({v})' for v, dv in builds) + ' (the profile\'s builds; the one you packed is not recorded)' if builds else 'unknown')

    # logs
    lg = Path(home) / 'Library/Logs/nxnative'
    b.add_file(f'logs/mac-app/{tid}.log', lg / f'{tid}.log', 'Mac app log')
    b.add_file(f'logs/mac-app/{tid}.prev.log', lg / f'{tid}.prev.log', 'Mac app previous log')
    env = Path(home) / 'Library/Application Support/nxnative' / tid / 'env.txt'
    env_text = read_text(env) if env.exists() else None
    bundled_env = read_text(app / 'Contents/Resources/dm/env.txt') if app else None
    if ios_log: b.add_file('logs/ios/' + (Path(ios_log).name or 'log.txt'), ios_log, 'iPhone log (--ios-log)')
    if build:
        ld = build / 'logs'
        names = sorted(p.name for p in ld.iterdir() if p.suffix in ('.log', '.txt') and p.is_file() and not p.is_symlink()) if ld.is_dir() else []
        if not names: b.notes.append(f'NSP script logs: none found in {b.short(ld)}')
        for n in names: b.add_file(f'logs/build/{n}', ld / n, f'build log {n}')
    else:
        b.notes.append('NSP script logs: skipped, no NSP folder given')
    exe = [plist.get('CFBundleExecutable') or '', 'dmhost']
    cr = crash_reports(home, [e for e in exe if e])
    if not cr: b.notes.append('Crash reports: none of dmhost or the app in the last 7 days')
    for p in cr: b.add_file(f'crash/{p.name}', p, f'crash report {p.name}')

    # settings
    prefs = read_prefs(bundle_id)
    pl = [f'{k} = {v}' for k, v in prefs.items()]
    dm_env = [f'{k}={v}' for k, v in sorted(os.environ.items()) if k.startswith('DM_') and not SECRET_NAME.search(k)]
    bdirs = shader_dirs(app, build)
    source = 'app' if app else 'build' if build else 'target'
    commit = plist.get('DMCommit') or f'unknown (not recorded by the {source})'
    # The collector's checkout need not be the checkout that built this app. A packaged app's sole b-<V> directory is its actual library chain.
    chain = plist.get('DMChain') or (Path(bdirs[0]).name[2:] if app and len(bdirs) == 1 else None)
    chain_text = chain or f'unknown (not recorded by the {source})'
    if bdirs: chain_text += '\n\nAvailable shader folder(s): ' + ', '.join(bdirs)
    collector = f'Collector checkout: {git_state() or "unknown"}; shader chain: {chain_version() or "unknown"} (collector only; does not identify the build that ran).'
    dev = device()

    def block(lines): return '```\n' + '\n'.join(lines) + '\n```' if lines else 'none'
    kind = 'Mac app (--platform mac-app)' if app else None
    r = ['# nxnative bug report data', '',
         f'Made by scripts/bug_report.py on {datetime.date.today().isoformat()}. Paste the sections into the bug form; attach this file.', '',
         '## Game, title ID and version', f'{name}, {tid}, {vtxt}', '',
         '## nxnative commit', commit, '',
         '## Shader chain version', chain_text, '', collector, '',
         '## How it was built and run', kind or 'fill in', '',
         '## Device and OS'] + [f'{k}: {v}' for k, v in dev.items()] + ['', '## Settings and environment overrides',
         'Player env.txt (Application Support):', block(env_text.splitlines() if env_text else []),
         'Bundled env.txt (Contents/Resources/dm/env.txt):', block(bundled_env.splitlines() if bundled_env else []),
         'Saved choices:', block(pl), 'DM_* in the terminal this script ran in:', block(dm_env), '',
         '## Logs and files included'] + [f'- {n}' for n in b.notes] + ['', 'Nothing here contains game files or keys.', '']
    text = '\n'.join(r)
    # env.txt and report.md go through the same redaction as the files
    text, _ = redact(text, home)
    text, _ = cut(text, report_cap)
    b.used += len(text.encode('utf-8')) - report_cap
    return b, text


def write_zip(out, b, report):
    with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as z:
        z.writestr('report.md', report)
        for arc, t in b.files.items(): z.writestr(arc, t)


def main(argv=None):
    ap = argparse.ArgumentParser(description='Collect logs, versions and settings into one zip to attach to a bug report. Never includes game files or keys.')
    ap.add_argument('target', help='title ID (16 hex digits), path to the .app, or the NSP folder (or its <title ID>_build folder)')
    ap.add_argument('--ios-log', metavar='FILE', help='log.txt from the iPhone or iPad (Files app)')
    ap.add_argument('--out', metavar='FILE', help='output zip (default nxnative-report-<title ID>-<date>.zip here)')
    a = ap.parse_args(argv)
    t = resolve(a.target)
    if not t:
        print('bug_report: the target is not a title ID, a Mac .app made by the NSP script, or an NSP folder with one <title ID>_build folder', file=sys.stderr); return 2
    b, report = collect(t, a.ios_log)
    out = Path(a.out) if a.out else Path(f'nxnative-report-{t["title_id"]}-{datetime.date.today().isoformat()}.zip')
    try: write_zip(out, b, report)
    except OSError as e:
        print(f'bug_report: cannot write {out}: {e}', file=sys.stderr); return 1
    print('Included:\n' + '\n'.join(f'  {n}' for n in b.notes))
    print(f'\n{out.resolve()} ({out.stat().st_size / 1024:.0f} KiB)')
    print('Attach this file to the bug report; it contains no game files')
    return 0


if __name__ == '__main__':
    sys.exit(main())
