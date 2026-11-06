#!/usr/bin/env python3
"""The nxbuild release the app bundles (frontend/nxbuild.pin, LNPANDY/NX2Apple#749).
  nxbuild.py fetch <Resources dir> <work dir>   download the pinned zip, check its SHA-256 before anything is unpacked, put nxb into <Resources>/nxbuild/
                                                and sign it ad hoc (the app's codesign --deep does not reach code in Resources). A placeholder digest
                                                bundles nothing and says so (exit 0): the launcher's setting then needs a chosen nxb.
  nxbuild.py bump <version>                     pin a new release: its digest from the release's SHA256SUMS
Nothing here runs nxb: a zip whose digest differs is deleted and the step fails."""
import hashlib, os, re, subprocess, sys, urllib.request, zipfile
from pathlib import Path

PIN = Path(__file__).resolve().parents[1] / 'nxbuild.pin'


def read(pin=PIN):
    """{'version', 'sha256', 'url'} with the version put into the URL; 'sha256' is None for a placeholder"""
    kv = dict(ln.split('\t', 1) for ln in pin.read_text().splitlines() if ln.strip() and not ln.startswith('#'))
    if set(kv) != {'version', 'sha256', 'url'} or not re.fullmatch(r'\d+\.\d+\.\d+', kv['version']):
        raise SystemExit(f'{pin}: needs version (x.y.z), sha256 and url lines')
    sha = kv['sha256'].strip().lower()
    return {'version': kv['version'], 'url': kv['url'].replace('{version}', kv['version']), 'sha256': sha if re.fullmatch(r'[0-9a-f]{64}', sha) else None}


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
    urllib.request.urlretrieve(pin['url'], z)
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
    with urllib.request.urlopen(url.rsplit('/', 1)[0] + '/SHA256SUMS') as r: sums = r.read().decode()
    sha = sums_digest(sums, Path(url).name)
    new = re.sub(r'^version\t.*$', f'version\t{version}', old, flags=re.M)
    pin.write_text(re.sub(r'^sha256\t.*$', f'sha256\t{sha}', new, flags=re.M))
    print(f'pinned nxbuild {version}: {sha}')


if __name__ == '__main__':
    a = sys.argv[1:]
    if a[:1] == ['fetch'] and len(a) == 3: fetch(Path(a[1]), Path(a[2]))
    elif a[:1] == ['bump'] and len(a) == 2: bump(a[1])
    else: raise SystemExit(__doc__)
