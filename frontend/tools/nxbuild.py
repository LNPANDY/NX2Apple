#!/usr/bin/env python3
"""The nxkit release the app bundles as its build engine "nxkit (Beta)" (frontend/nxbuild.pin, LNPANDY/NX2Apple#1460).
  nxbuild.py fetch <Resources dir> <work dir>   download the pinned zip and the release's SHA256SUMS, check the zip's SHA-256 against the pin and
                                                SHA256SUMS before anything is unpacked, put nxb and nxkit-host (with MANIFEST.json, LICENSE and
                                                THIRD_PARTY.md) into <Resources>/nxbuild/, check both programs against MANIFEST.json and SHA256SUMS,
                                                and sign both ad hoc (the app's codesign --deep does not reach code in Resources). A placeholder
                                                digest bundles nothing and says so (exit 0).
  nxbuild.py bump <version>                     pin a new release: its digest from the release's SHA256SUMS
Nothing here runs nxb: a zip whose digest differs is deleted and the step fails, a program whose digest differs is not bundled."""
import hashlib, json, os, re, shutil, subprocess, sys, time, urllib.error, urllib.request, zipfile
from pathlib import Path

PIN = Path(__file__).resolve().parents[1] / 'nxbuild.pin'
RETRY_HTTP = {408, 429, 500, 502, 503, 504}
GH_RELEASE_RE = re.compile(r'^https://github\.com/([^/]+/[^/]+)/releases/download/([^/]+)/([^/]+)$')
PROGRAMS = ('nxb', 'nxkit-host')                       # both are checked and signed, the app needs the pair
EXTRAS = ('MANIFEST.json', 'LICENSE', 'THIRD_PARTY.md')   # copied beside them when the release has them, MANIFEST.json is required
MANIFEST_FORMATS = {1}


def _gh_release_download(url, part):
    m = GH_RELEASE_RE.match(url)
    if not m or not shutil.which('gh'):
        return False
    repo, tag, asset = m.groups()
    r = subprocess.run(['gh', 'release', 'download', tag, '-R', repo, '-p', asset, '-O', str(part), '--clobber'])
    return r.returncode == 0 and part.is_file() and part.stat().st_size > 0


def download(url, dest=None, retries=5, delay=10):
    """Read url (and write dest atomically via dest.part when given), retrying transient HTTP 5xx/429 and network errors."""
    part = Path(f'{dest}.part') if dest is not None else None
    if part is not None and _gh_release_download(url, part):
        part.replace(dest)
        return Path(dest).read_bytes()
    for attempt in range(1, retries + 1):
        try:
            with urllib.request.urlopen(url, timeout=60) as r:
                data = r.read()
            if part is not None:
                part.write_bytes(data)
                part.replace(dest)
            return data
        except urllib.error.HTTPError as e:
            if e.code not in RETRY_HTTP or attempt == retries:
                raise
        except (urllib.error.URLError, TimeoutError, ConnectionError):
            if attempt == retries:
                raise
        time.sleep(delay)


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


def sums_table(text):
    """SHA256SUMS as {listed path: digest} ("<hex>  <path>" lines, a '*' before binary names)"""
    out = {}
    for ln in text.splitlines():
        m = re.fullmatch(r'([0-9a-fA-F]{64})\s+\*?(\S+)', ln.strip())
        if m: out[m[2]] = m[1].lower()
    return out


def sums_digest(text, name):   # the digest of name in a SHA256SUMS text: its listed path, else the one entry with that file name
    table = sums_table(text)
    if name in table: return table[name]
    hits = [v for k, v in table.items() if Path(k).name == name]
    if len(hits) == 1: return hits[0]
    raise SystemExit(f'SHA256SUMS lists no {name}')


def unpack(zip_path, expected, dest, sums_text):
    """Check the zip against the pin and SHA256SUMS, then copy nxb and nxkit-host (and the extras) from the zip's one release folder
    into dest, each program checked against MANIFEST.json and SHA256SUMS. Returns the paths of the programs. Nothing stays in dest on a failure."""
    got = digest(zip_path)
    if got != expected:
        os.unlink(zip_path)
        raise SystemExit(f'[RED] nxkit zip has SHA-256 {got}, the pin says {expected}: not bundled')
    listed = sums_digest(sums_text, Path(zip_path).name)
    if listed != expected:
        os.unlink(zip_path)
        raise SystemExit(f'[RED] SHA256SUMS lists {listed} for {Path(zip_path).name}, the pin says {expected}: not bundled')
    with zipfile.ZipFile(zip_path) as z:
        files = [n for n in z.namelist() if not n.endswith('/')]
        nxbs = [n for n in files if Path(n).name == 'nxb']
        if len(nxbs) != 1: raise SystemExit(f'[RED] nxkit zip holds {len(nxbs)} files named nxb, expected one')
        root = Path(nxbs[0]).parent
        def member(name):
            n = (root / name).as_posix()
            return n if n in files else None
        for name in PROGRAMS + ('MANIFEST.json',):
            if member(name) is None: raise SystemExit(f'[RED] nxkit zip has no {name} beside nxb: not bundled')
        manifest = json.loads(z.read(member('MANIFEST.json')))
        if manifest.get('format') not in MANIFEST_FORMATS:
            raise SystemExit(f'[RED] MANIFEST.json format {manifest.get("format")} is not one this launcher reads')
        if manifest.get('arch') != 'arm64': raise SystemExit(f'[RED] MANIFEST.json arch is {manifest.get("arch")}, not arm64')
        blobs = {}
        for name in PROGRAMS:
            data = z.read(member(name))
            have = hashlib.sha256(data).hexdigest()
            want = (manifest.get('files') or {}).get(name)
            if have != want: raise SystemExit(f'[RED] {name} has SHA-256 {have}, MANIFEST.json says {want}: not bundled')
            listed = sums_table(sums_text).get(member(name))
            if have != listed: raise SystemExit(f'[RED] {name} has SHA-256 {have}, SHA256SUMS says {listed}: not bundled')
            blobs[name] = data
        for name in EXTRAS:
            if member(name): blobs[name] = z.read(member(name))
    if dest.exists(): shutil.rmtree(dest)
    dest.mkdir(parents=True)
    for name, data in blobs.items():
        (dest / name).write_bytes(data)
    for name in PROGRAMS:
        (dest / name).chmod(0o755)
    return [dest / name for name in PROGRAMS]


def fetch(resources, work):
    pin = read()
    if not pin['sha256']:
        print(f'nxkit {pin["version"]}: no digest pinned yet (PLACEHOLDER in {PIN.name}), the app bundles no nxkit')
        return None
    work.mkdir(parents=True, exist_ok=True)
    z = work / Path(pin['url']).name
    download(pin['url'], z)
    sums = download(pin['url'].rsplit('/', 1)[0] + '/SHA256SUMS').decode()
    programs = unpack(z, pin['sha256'], resources / 'nxbuild', sums)
    for p in programs:
        subprocess.run(['codesign', '--force', '--sign', '-', str(p)], check=True)
    print(f'nxkit {pin["version"]}: {", ".join(str(p) for p in programs)} ({pin["sha256"]})')
    return programs


def bump(version, pin=PIN):
    old = pin.read_text()
    url = read(pin)['url'].replace(read(pin)['version'], version)
    sums = download(url.rsplit('/', 1)[0] + '/SHA256SUMS').decode()
    sha = sums_digest(sums, Path(url).name)
    new = re.sub(r'^version\t.*$', f'version\t{version}', old, flags=re.M)
    pin.write_text(re.sub(r'^sha256\t.*$', f'sha256\t{sha}', new, flags=re.M))
    print(f'pinned nxkit {version}: {sha}')


if __name__ == '__main__':
    a = sys.argv[1:]
    if a[:1] == ['fetch'] and len(a) == 3: fetch(Path(a[1]), Path(a[2]))
    elif a[:1] == ['bump'] and len(a) == 2: bump(a[1])
    else: raise SystemExit(__doc__)
