#!/usr/bin/env python3
"""The nxbuild release the app bundles (frontend/nxbuild.pin, LNPANDY/NX2Apple#749).
  nxbuild.py fetch <Resources dir> <work dir>   download the pinned zip, check its SHA-256 before anything is unpacked, put nxb into <Resources>/nxbuild/
                                                and sign it ad hoc (the app's codesign --deep does not reach code in Resources). A placeholder digest
                                                bundles nothing and says so (exit 0): the launcher's setting then needs a chosen nxb.
  nxbuild.py bump <version>                     pin a new release: its digest from the release's SHA256SUMS
  nxbuild.py check <engine dir>                 whether the pinned release's rewriter takes this engine: the SHA-256 its rewrite.rs pins for each dm/tools
                                                file against the engine's (#942). Exit code 1 lists the files that differ: `nxb build` stops at the
                                                rewrite with such an engine, and the launcher builds with the NSP script instead.
Nothing here runs nxb: a zip whose digest differs is deleted and the step fails."""
import hashlib, os, re, subprocess, sys, time, urllib.error, urllib.request, zipfile
from pathlib import Path

PIN = Path(__file__).resolve().parents[1] / 'nxbuild.pin'


def read(pin=PIN):
    """{'version', 'sha256', 'url'} with the version put into the URL; 'sha256' is None for a placeholder"""
    kv = dict(ln.split('\t', 1) for ln in pin.read_text().splitlines() if ln.strip() and not ln.startswith('#'))
    if set(kv) != {'version', 'sha256', 'url'} or not re.fullmatch(r'\d+\.\d+\.\d+', kv['version']):
        raise SystemExit(f'{pin}: needs version (x.y.z), sha256 and url lines')
    sha = kv['sha256'].strip().lower()
    return {'version': kv['version'], 'url': kv['url'].replace('{version}', kv['version']), 'sha256': sha if re.fullmatch(r'[0-9a-f]{64}', sha) else None}


def download(url, tries=5, wait=10):
    """The bytes at url. A GitHub release download can answer 502 to 504 for minutes: a server error or a lost connection is tried again, a 404 is not"""
    for n in range(1, tries + 1):
        try:
            with urllib.request.urlopen(url, timeout=120) as r: return r.read()
        except urllib.error.HTTPError as e:
            if e.code < 500 or n == tries: raise
        except (urllib.error.URLError, TimeoutError, ConnectionError):
            if n == tries: raise
        print(f'{url}: try {n} of {tries} failed, again in {wait * n} s', file=sys.stderr)
        time.sleep(wait * n)


def digest(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for b in iter(lambda: f.read(1 << 20), b''): h.update(b)
    return h.hexdigest()


DATA = ('rewrite-rules', 'own-front')   # folders of the release that nxb finds next to its own file


def unpack(zip_path, expected, dest):
    """Check the zip against expected, then copy its nxb (wherever it sits in the zip) to dest/nxb, and the data folders beside it. Returns the path of nxb"""
    got = digest(zip_path)
    if got != expected:
        os.unlink(zip_path)
        raise SystemExit(f'[RED] nxbuild zip has SHA-256 {got}, the pin says {expected}: not bundled')
    with zipfile.ZipFile(zip_path) as z:
        names = [n for n in z.namelist() if Path(n).name == 'nxb' and not n.endswith('/')]
        if len(names) != 1: raise SystemExit(f'[RED] nxbuild zip holds {len(names)} files named nxb, expected one')
        dest.mkdir(parents=True, exist_ok=True)
        out = dest / 'nxb'
        out.write_bytes(z.read(names[0]))
        # The data nxb reads from beside its own file (the rewrite rules, the own front end's verdicts), as the release lays them out next to nxb
        root = Path(names[0]).parent
        for n in z.namelist():
            rel = Path(n).relative_to(root) if Path(n).is_relative_to(root) else None
            if rel is None or n.endswith('/') or rel.parts[0] not in DATA or '..' in rel.parts: continue
            (dest / rel).parent.mkdir(parents=True, exist_ok=True)
            (dest / rel).write_bytes(z.read(n))
    out.chmod(0o755)
    return out


def fetch(resources, work):
    pin = read()
    if not pin['sha256']:
        print(f'nxbuild {pin["version"]}: no digest pinned yet (PLACEHOLDER in {PIN.name}), the app bundles no nxb')
        return None
    work.mkdir(parents=True, exist_ok=True)
    z = work / Path(pin['url']).name
    z.write_bytes(download(pin['url']))
    nxb = unpack(z, pin['sha256'], resources / 'nxbuild')
    subprocess.run(['codesign', '--force', '--sign', '-', str(nxb)], check=True)
    print(f'nxbuild {pin["version"]}: {nxb} ({pin["sha256"]})')
    return nxb


def sums_digest(text, name):   # the digest of name in a SHA256SUMS text ("<hex>  <name>" lines, a '*' before binary names)
    for ln in text.splitlines():
        m = re.fullmatch(r'([0-9a-fA-F]{64})\s+\*?(\S+)', ln.strip())
        if m and Path(m[2]).name == name: return m[1].lower()
    raise SystemExit(f'SHA256SUMS lists no {name}')


def bump(version, pin=PIN):
    old = pin.read_text()
    url = read(pin)['url'].replace(read(pin)['version'], version)
    sums = download(url.rsplit('/', 1)[0] + '/SHA256SUMS').decode()
    sha = sums_digest(sums, Path(url).name)
    new = re.sub(r'^version\t.*$', f'version\t{version}', old, flags=re.M)
    pin.write_text(re.sub(r'^sha256\t.*$', f'sha256\t{sha}', new, flags=re.M))
    print(f'pinned nxbuild {version}: {sha}')


REWRITE_RS = 'crates/nxb-build/src/rewrite.rs'   # nxkit's rewriter step: its PINNED table is what `nxb build` checks the engine's dm/tools against


def rewrite_source(pin):
    """The raw URL of the pinned release's rewrite.rs: the tag of the release download, in the same repository"""
    m = re.match(r'https://github\.com/([^/]+/[^/]+)/releases/download/([^/]+)/', pin['url'])
    if not m: raise SystemExit(f'{PIN.name}: the url is not a GitHub release download, so its rewrite.rs cannot be found')
    return f'https://raw.githubusercontent.com/{m[1]}/{m[2]}/{REWRITE_RS}'


def pins(rust):
    """[(file, sha256)] of the PINNED table in rewrite.rs, in its order"""
    m = re.search(r'const PINNED: \[\(&str, &str\); (\d+)\] = \[(.*?)\n\];', rust, re.S)
    if not m: raise SystemExit(f'{REWRITE_RS} has no PINNED table')
    found = re.findall(r'\(\s*"([^"]+)",\s*"([0-9a-f]{64})",?\s*\)', m[2])
    if len(found) != int(m[1]): raise SystemExit(f'{REWRITE_RS}: PINNED declares {m[1]} entries, {len(found)} read')
    return found


def mismatches(pinned, tools):
    """[(file, pinned sha256, engine sha256 or None when the file is missing)] for each pinned file of tools that differs"""
    return [(name, want, have) for name, want in pinned
            if (have := digest(tools / name) if (tools / name).is_file() else None) != want]


def check(engine):
    pin = read()
    url = rewrite_source(pin)
    rust = download(url).decode()
    pinned = pins(rust)
    bad = mismatches(pinned, Path(engine) / 'dm' / 'tools')
    if not bad:
        print(f'nxb {pin["version"]}: the {len(pinned)} dm/tools files its rewriter pins are the engine\'s')
        return 0
    print(f'nxb {pin["version"]}: its rewriter pins other dm/tools files than this engine has, so `nxb build` stops at the rewrite '
          f'and the launcher builds with the NSP script (#942). A release of nxkit checked against this engine is needed ({url}):')
    for name, want, have in bad:
        print(f'  {name}: nxb pins {want}, the engine has {have or "no such file"}')
    return 1


if __name__ == '__main__':
    a = sys.argv[1:]
    if a[:1] == ['fetch'] and len(a) == 3: fetch(Path(a[1]), Path(a[2]))
    elif a[:1] == ['bump'] and len(a) == 2: bump(a[1])
    elif a[:1] == ['check'] and len(a) == 2: sys.exit(check(Path(a[1])))
    else: raise SystemExit(__doc__)
