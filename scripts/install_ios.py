#!/usr/bin/env python3
# Sign an IPA from build_ipa_from_nsp.py with the Mac's own Apple Development certificate and install it on a connected iPhone or iPad,
#   then copy the game files (the romfs/ archive folder) into the app's Documents/romfs and check them: the steps the README leaves to
#   AltStore / Sideloadly and the Files app, done over the cable with Xcode's own tools (devicectl, codesign, xcodebuild).
# Nothing about the account is stored here: the certificate comes from the login keychain (expired ones are skipped; --team / --identity
#   pick one when there are several), the provisioning profile from Xcode's automatic signing (a throwaway project with the IPA's bundle ID
#   and requested capabilities, built once for the device with -allowProvisioningUpdates, so Xcode must be signed in to that team), and the
#   device from devicectl (--device, or the only one connected).
# The profile carries what the app asks for (com.apple.developer.kernel.increased-memory-limit, which large games need) when the team can
#   have it; a team that cannot (a free Personal Team) gets the app without it, and the log says so.
# Reinstalling can leave the app's data container empty, so the save and the launcher's settings are copied to the Mac first
#   (~/Library/Application Support/NS Port Builder/device-backups/<bundle ID>/<time>/) and put back when the install lost them.
# The game files go only where they differ: each file's SHA-1 is kept beside the archive (.romfs_sums.json, cached by size and mtime) and on
#   the device after a complete copy, so a rebuilt archive sends only the shards that changed; the index goes last, and every size is checked.
# Usage: install_ios.py <app.ipa> [--romfs <folder>] [--device <UDID or name>] [--team <team ID>] [--identity <SHA-1>] [--progress lines]
#        install_ios.py --list   (JSON: devices, signing identities; for the front end)
import argparse, datetime, hashlib, json, os, plistlib, re, shutil, subprocess, sys, tempfile, time, zipfile
from pathlib import Path

CACHE = Path.home() / 'Library/Caches/NS Port Builder'
BACKUPS = Path.home() / 'Library/Application Support/NS Port Builder/device-backups'
SUMS = '.romfs_sums.json'
# capabilities copied from the IPA's request into the throwaway project; anything else in the app's signature is ignored
CAPS = ('com.apple.developer.kernel.increased-memory-limit', 'com.apple.developer.kernel.extended-virtual-addressing')


class InstallError(Exception): pass
class BundleIDTaken(InstallError): pass   # the App ID belongs to another developer team (App IDs are unique across all of Apple)


def clock(): return time.strftime('%H:%M:%S')
def say(msg): print(f'[{clock()}] {msg}', flush=True)


class Stages:   # the build script's "--progress lines" format, which the front end parses: [k/n] name …, ✓ [k/n] name (m:ss): detail
    def __init__(self, names, first=1): self.names, self.first, self.k, self.t0 = names, first, None, 0
    def start(self, i):
        self.k, self.t0 = i, time.time()
        say(f'[{self.first + i}/{self.first + len(self.names) - 1}] {self.names[i]} …')
    def pct(self, p, detail=''):
        say(f'[{self.first + self.k}/{self.first + len(self.names) - 1}] {self.names[self.k]}: {p:.0f}%' + (f', {detail}' if detail else ''))
    def end(self, detail='', ok=True):
        s = int(time.time() - self.t0)
        say(f'{"✓" if ok else "✗"} [{self.first + self.k}/{self.first + len(self.names) - 1}] {self.names[self.k]} ({s // 60}:{s % 60:02d})' + (f': {detail}' if detail else ''))


def run(cmd, check=True, **kw):
    r = subprocess.run([str(c) for c in cmd], capture_output=True, text=True, **kw)
    if check and r.returncode: raise InstallError(f'{Path(str(cmd[0])).name} {cmd[1] if len(cmd) > 1 else ""} failed ({r.returncode}): {(r.stderr or r.stdout).strip()[-600:]}')
    return r


def devicectl(*args, check=True):
    """devicectl with its JSON result (a temporary file: stdout mixes progress with the JSON)"""
    with tempfile.NamedTemporaryFile(suffix='.json', delete=False) as t: out = t.name
    try:
        r = run(['xcrun', 'devicectl', *args, '-j', out, '-q'], check=False)
        data = json.loads(Path(out).read_text() or '{}') if os.path.getsize(out) else {}
    finally: os.unlink(out)
    if check and r.returncode:
        err = data.get('error', {}).get('userInfo', {}).get('NSLocalizedDescription', {}).get('string') or (r.stderr or r.stdout).strip()[-400:]
        raise InstallError(f'devicectl {args[0]} {args[1] if len(args) > 1 else ""}: {err}')
    return data.get('result', {}) if not r.returncode else None


# ---- device and identity ----
def devices():
    res = devicectl('list', 'devices') or {}
    out = []
    for d in res.get('devices', []):
        hw, cp = d.get('hardwareProperties', {}), d.get('connectionProperties', {})
        if hw.get('reality') != 'physical' or hw.get('platform') not in ('iOS', 'iPadOS'): continue
        out.append({'udid': hw.get('udid'), 'name': d.get('deviceProperties', {}).get('name', ''), 'model': hw.get('marketingName', ''),
                    'paired': cp.get('pairingState') == 'paired', 'connected': bool(cp.get('transportType')) or cp.get('tunnelState') == 'connected',
                    'transport': cp.get('transportType', '')})
    return out


def pick_device(want):
    ds = devices()
    if want:
        hit = [d for d in ds if want in (d['udid'], d['name'])]
        if not hit: raise InstallError(f'no connected device {want!r}; connected: {", ".join(d["name"] for d in ds) or "none"}')
        return hit[0]
    ds = [d for d in ds if d['paired'] and d['connected']] or [d for d in ds if d['paired']]
    if not ds: raise InstallError('no iPhone or iPad is connected and paired: connect it with a cable, unlock it and tap Trust (Developer Mode must be on)')
    if len(ds) > 1: raise InstallError('several devices are connected, pick one with --device: ' + ', '.join(f'{d["name"]} ({d["udid"]})' for d in ds))
    return ds[0]


def identities():
    """Valid Apple Development identities: SHA-1, name, team ID (the certificate's OU), expiry"""
    out = []
    for sha, name in re.findall(r'\d+\) ([0-9A-F]{40}) "([^"]+)"', run(['security', 'find-identity', '-v', '-p', 'codesigning']).stdout):
        if not name.startswith(('Apple Development:', 'iPhone Developer:')): continue
        pem = run(['security', 'find-certificate', '-Z', '-a', '-c', name, '-p'], check=False).stdout
        for cert in re.findall(r'-----BEGIN CERTIFICATE-----.+?-----END CERTIFICATE-----', pem, re.S):
            r = run(['openssl', 'x509', '-noout', '-subject', '-enddate', '-fingerprint', '-sha1', '-nameopt', 'sep_multiline'], check=False, input=cert)
            if sha not in r.stdout.replace(':', ''): continue
            ou = re.search(r'OU=(\w+)', r.stdout); end = re.search(r'notAfter=(.+)', r.stdout)
            when = datetime.datetime.strptime(end.group(1).strip(), '%b %d %H:%M:%S %Y %Z') if end else None
            if when and when < datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None): continue   # find-identity -v still lists some expired ones
            out.append({'sha1': sha, 'name': name, 'team': ou.group(1) if ou else '', 'expires': when.strftime('%Y-%m-%d') if when else ''})
    return out


def pick_identity(team, sha):
    ids = identities()
    if sha: ids = [i for i in ids if i['sha1'] == sha.upper()]
    if team: ids = [i for i in ids if i['team'] == team]
    if not ids: raise InstallError('no valid Apple Development certificate' + (f' for team {team}' if team else '') + ': add your Apple ID in Xcode → Settings → Accounts and let it make one')
    if len({i['team'] for i in ids}) > 1: raise InstallError('certificates of several teams, pick one with --team: ' + ', '.join(sorted({i['team'] for i in ids})))
    return ids[0]


# ---- provisioning ----
def app_info(app):
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    r = run(['codesign', '-d', '--entitlements', ':-', app], check=False)
    ent = plistlib.loads(r.stdout.encode()) if r.stdout.strip().startswith('<?xml') else {}
    return info, {k: v for k, v in ent.items() if k in CAPS}


def profile_plist(path):
    return plistlib.loads(subprocess.run(['security', 'cms', '-D', '-i', str(path)], capture_output=True, check=True).stdout)


def profile_fits(path, team, bid, udid, cert_sha, caps):
    try: p = profile_plist(path)
    except Exception: return False
    ent = p.get('Entitlements', {})
    if ent.get('application-identifier') not in (f'{team}.{bid}',): return False
    if udid not in p.get('ProvisionedDevices', []): return False
    if p.get('ExpirationDate') and p['ExpirationDate'] < datetime.datetime.now() + datetime.timedelta(days=2): return False
    if cert_sha not in [hashlib.sha1(c).hexdigest().upper() for c in p.get('DeveloperCertificates', [])]: return False
    return all(k in ent for k in caps)


def make_profile(team, bid, udid, info, caps, work):
    """Let Xcode's automatic signing register the App ID (with the capabilities), the device and a development profile, through a
    throwaway project built once for the device; the profile is then taken out of the built app"""
    proj = work / 'stub'; (proj / 'Stub').mkdir(parents=True)
    (proj / 'Stub/main.m').write_text('int main(void) { return 0; }\n')
    (proj / 'Stub/Stub.entitlements').write_bytes(plistlib.dumps(caps))
    fam = ','.join(str(f) for f in info.get('UIDeviceFamily', [1, 2]))
    (proj / 'project.yml').write_text(f'''name: Stub
options: {{ deploymentTarget: {{ iOS: "{info.get("MinimumOSVersion", "16.0")}" }} }}
targets:
  Stub:
    type: application
    platform: iOS
    sources: [Stub]
    settings:
      PRODUCT_BUNDLE_IDENTIFIER: {bid}
      DEVELOPMENT_TEAM: {team}
      CODE_SIGN_STYLE: Automatic
      CODE_SIGN_ENTITLEMENTS: {"Stub/Stub.entitlements" if caps else '""'}
      GENERATE_INFOPLIST_FILE: YES
      TARGETED_DEVICE_FAMILY: "{fam}"
''')
    xcodegen = shutil.which('xcodegen', path='/opt/homebrew/bin:/usr/local/bin:' + os.environ.get('PATH', ''))
    if not xcodegen: raise InstallError('xcodegen is missing (brew install xcodegen)')
    run([xcodegen, '-q'], cwd=proj)
    r = run(['xcodebuild', '-project', 'Stub.xcodeproj', '-scheme', 'Stub', '-configuration', 'Debug', '-destination', f'id={udid}', '-derivedDataPath', 'dd',
             '-allowProvisioningUpdates', '-allowProvisioningDeviceRegistration', 'build'], check=False, cwd=proj)
    prof = proj / 'dd/Build/Products/Debug-iphoneos/Stub.app/embedded.mobileprovision'
    if r.returncode or not prof.is_file():
        err = '; '.join(sorted(set(re.findall(r'error: (.+)', r.stdout + r.stderr))))[:600]
        if 'cannot be registered to your development team because it is not available' in err: raise BundleIDTaken(f'{bid} is registered to another developer team')
        raise InstallError(f'Xcode could not make a development profile for {bid}: {err or "see xcodebuild"} (is Xcode signed in to this team in Settings → Accounts?)')
    return prof


def unique_bid(bid, team):
    return f'{bid}.u{hashlib.sha256(team.encode()).hexdigest()[:8]}'


def get_profile(team, bid, udid, cert_sha, info, caps, work):
    cached = CACHE / 'profiles' / team / f'{bid}.mobileprovision'
    if cached.is_file() and profile_fits(cached, team, bid, udid, cert_sha, caps): return cached, 'reused', caps
    try: prof = make_profile(team, bid, udid, info, caps, work)
    except BundleIDTaken: raise
    except InstallError as e:
        if not caps: raise
        say(f'the team cannot have {", ".join(caps)} ({e}); signing without it, so the app gets the standard memory limit')
        caps = {}; shutil.rmtree(work / 'stub', ignore_errors=True)
        prof = make_profile(team, bid, udid, info, caps, work)
    if not profile_fits(prof, team, bid, udid, cert_sha, caps): raise InstallError('the profile Xcode made does not cover this certificate and device')
    cached.parent.mkdir(parents=True, exist_ok=True); shutil.copyfile(prof, cached)
    return cached, 'made by Xcode', caps


# ---- signing ----
def sign(ipa, ident, prof, caps, bid, out_ipa, work):
    root = work / 'ipa'
    with zipfile.ZipFile(ipa) as z: z.extractall(root)
    for f in root.rglob('*'):   # zipfile drops the executable bit
        if f.is_file() and f.stat().st_size >= 4 and f.open('rb').read(4) in (b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe'): f.chmod(0o755)
    app = next((root / 'Payload').glob('*.app'))
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    if info['CFBundleIdentifier'] != bid:   # the team's own App ID (unique_bid)
        info['CFBundleIdentifier'] = bid; (app / 'Info.plist').write_bytes(plistlib.dumps(info, fmt=plistlib.FMT_BINARY))
    p = profile_plist(prof); pent = p['Entitlements']
    ent = {'application-identifier': pent['application-identifier'], 'com.apple.developer.team-identifier': pent['com.apple.developer.team-identifier'],
           'get-task-allow': pent.get('get-task-allow', True), **{k: v for k, v in caps.items() if k in pent}}
    (work / 'ent.plist').write_bytes(plistlib.dumps(ent))
    shutil.rmtree(app / '_CodeSignature', ignore_errors=True)
    shutil.copyfile(prof, app / 'embedded.mobileprovision')
    nested = sorted([*app.rglob('*.dylib'), *app.rglob('*.framework')], key=lambda q: -len(q.parts))   # innermost first
    for q in nested: run(['codesign', '-f', '-s', ident['sha1'], '--timestamp=none', q])
    run(['codesign', '-f', '-s', ident['sha1'], '--timestamp=none', '--entitlements', work / 'ent.plist', app])
    run(['codesign', '--verify', '--deep', '--strict', app])
    if out_ipa:
        tmp = out_ipa.with_suffix('.ipa.part')
        with zipfile.ZipFile(tmp, 'w', zipfile.ZIP_DEFLATED, compresslevel=1) as z:
            for f in sorted(root.rglob('*')):
                if f.is_file(): z.write(f, f.relative_to(root))
        tmp.replace(out_ipa)
    return app, ent


# ---- the app's data container ----
def remote_files(udid, bid, sub, tries=3):
    """{path relative to sub: size} of the files under sub in the app's container; None when it cannot be read (no such folder, or
    devicectl failed: over Wi-Fi a listing fails now and then, so it is tried again before giving up)"""
    for i in range(tries):
        res = devicectl('device', 'info', 'files', '--device', udid, '--domain-type', 'appDataContainer', '--domain-identifier', bid, '--subdirectory', sub, check=False)
        if res is not None:
            return {f.get('relativePath') or f['name']: f.get('metadata', {}).get('size', 0) for f in res.get('files', []) if not f.get('resources', {}).get('isDirectory')}
        if i + 1 < tries: time.sleep(2)
    return None


def installed(udid, bid):
    return bool((devicectl('device', 'info', 'apps', '--device', udid, '--bundle-id', bid) or {}).get('apps'))


def pull(udid, bid, src, dst):
    dst.parent.mkdir(parents=True, exist_ok=True)
    devicectl('device', 'copy', 'from', '--device', udid, '--domain-type', 'appDataContainer', '--domain-identifier', bid, '--source', src, '--destination', dst)


def push(udid, bid, src, dst):
    devicectl('device', 'copy', 'to', '--device', udid, '--domain-type', 'appDataContainer', '--domain-identifier', bid, '--source', src, '--destination', dst)


KEEP = {'Documents': ('save/', 'pso_user.tsv'), 'Library/Preferences': ('.plist',)}   # the save, the learned pipelines, the launcher's settings


def kept_files(udid, bid):
    """The files to keep across an install, or None when the app's Documents cannot be read"""
    out = []
    for base, keep in KEEP.items():
        files = remote_files(udid, bid, base)
        if files is None:
            if base == 'Documents': return None
            continue   # no Preferences yet: the launcher was never opened
        out += [f'{base}/{n}' for n in files if n.startswith(keep) or n.endswith(keep)]
    return out


def backup(udid, bid):
    if not installed(udid, bid): return None, []
    files = kept_files(udid, bid)
    if files is None: raise InstallError('could not read the app\'s data on the device to back up the save first, so nothing was installed; try again (a cable is steadier than Wi-Fi)')
    if not files: return None, []
    dest = BACKUPS / bid / time.strftime('%Y%m%d-%H%M%S')
    for f in files: pull(udid, bid, f, dest / f)
    return dest, files


# ---- game files ----
def local_sums(folder, st):
    """SHA-1 of each archive file, cached beside it by size and mtime"""
    cache_f = folder / SUMS
    try: cache = json.loads(cache_f.read_text())
    except Exception: cache = {}
    files = sorted(f for f in folder.iterdir() if f.is_file() and re.fullmatch(r'romfs\.(idx|\d+)', f.name))
    total = sum(f.stat().st_size for f in files) or 1; done = 0; out = {}; last = 0
    for f in files:
        s = f.stat(); key = [s.st_size, s.st_mtime_ns]
        c = cache.get(f.name)
        if c and c[:2] == key: out[f.name] = c
        else:
            h = hashlib.sha1()
            with f.open('rb') as fh:
                while b := fh.read(8 << 20):
                    h.update(b); done += len(b)
                    if time.time() - last > 2: st.pct(100 * done / total, 'checksums'); last = time.time()
            out[f.name] = key + [h.hexdigest()]
            continue
        done += s.st_size
    try: cache_f.write_text(json.dumps(out))
    except OSError: pass   # a read-only folder: the sums are made again next time
    return out


def sync_romfs(udid, bid, folder, st, work):
    sums = local_sums(folder, st)
    remote = remote_files(udid, bid, 'Documents/romfs') or {}
    rsums = {}
    if SUMS in remote:
        try: pull(udid, bid, f'Documents/romfs/{SUMS}', work / 'rsums.json'); rsums = json.loads((work / 'rsums.json').read_text())
        except Exception: rsums = {}
    # a file goes over when its size differs, or when the device's sums (written after the last complete copy) name other content
    todo = [n for n, (size, _, sha) in sums.items() if remote.get(n) != size or (rsums.get(n) or [None, None, sha])[2] != sha]
    if not rsums and remote:   # no sums on the device (an archive copied by hand): same-size files are trusted only when the index is the same
        try:
            pull(udid, bid, 'Documents/romfs/romfs.idx', work / 'ridx')
            if (work / 'ridx').read_bytes() != (folder / 'romfs.idx').read_bytes(): todo = list(sums)
        except Exception: todo = list(sums)
    todo.sort(key=lambda n: (n == 'romfs.idx', n))   # the index last: the game never sees a new index over old shards
    nbytes = sum(sums[n][0] for n in todo) or 1; sent = 0; t0 = time.time()
    for i, n in enumerate(todo):
        push(udid, bid, folder / n, f'Documents/romfs/{n}'); sent += sums[n][0]
        rate = sent / max(time.time() - t0, 0.1)
        st.pct(100 * sent / nbytes, f'{i + 1}/{len(todo)} files, {sent / 2**30:.1f}/{nbytes / 2**30:.1f} GB, {rate / 2**20:.0f} MB/s')
    remote = remote_files(udid, bid, 'Documents/romfs') or {}
    bad = [n for n, (size, _, _) in sums.items() if remote.get(n) != size]
    if bad: raise InstallError(f'{len(bad)} game files did not arrive whole: {", ".join(bad[:5])}')
    (work / 'sums.json').write_text(json.dumps(sums)); push(udid, bid, work / 'sums.json', f'Documents/romfs/{SUMS}')
    return len(todo), nbytes if todo else 0, len(sums)


def main(argv=None):
    ap = argparse.ArgumentParser(description='sign an IPA with this Mac\'s development certificate, install it on a connected device and copy the game files')
    ap.add_argument('ipa', nargs='?'); ap.add_argument('--romfs', help='the romfs/ archive folder (romfs.idx + shards) to copy into Documents/romfs')
    ap.add_argument('--device'); ap.add_argument('--team'); ap.add_argument('--identity')
    ap.add_argument('--out', help='also write the signed IPA here')
    ap.add_argument('--progress', default='lines'); ap.add_argument('--first-stage', type=int, default=1, help='number of the first stage line (the front end appends these to the build\'s)')
    ap.add_argument('--list', action='store_true', help='print the connected devices and signing identities as JSON')
    a = ap.parse_args(argv)
    if a.list:
        print(json.dumps({'devices': devices(), 'identities': [{k: v for k, v in i.items()} for i in identities()]})); return 0
    if not a.ipa: ap.error('the IPA is needed')
    ipa = Path(a.ipa).expanduser().resolve(); romfs = Path(a.romfs).expanduser().resolve() if a.romfs else None
    if not ipa.is_file(): raise InstallError(f'no such IPA: {ipa}')
    if romfs and not (romfs / 'romfs.idx').is_file(): raise InstallError(f'no romfs.idx in {romfs}')
    st = Stages(['sign', 'install', 'game files'] if romfs else ['sign', 'install'], a.first_stage)
    with tempfile.TemporaryDirectory(prefix='nspb_install_') as w:
        work = Path(w)
        st.start(0)
        dev = pick_device(a.device); ident = pick_identity(a.team, a.identity)
        say(f'device: {dev["name"]} ({dev["model"]}, {dev["transport"] or "not connected"}); certificate: {ident["name"]}, team {ident["team"]}')
        with zipfile.ZipFile(ipa) as z:
            z.extractall(work / 'peek', [n for n in z.namelist() if re.fullmatch(r'Payload/[^/]+\.app/(Info\.plist|_CodeSignature/.*|[^/.]+)', n)])
        peek = next((work / 'peek/Payload').glob('*.app'))
        info, caps = app_info(peek); shutil.rmtree(work / 'peek')
        bids = CACHE / 'bundle_ids.json'
        try: bmap = json.loads(bids.read_text())
        except Exception: bmap = {}
        key = f'{ident["team"]}/{info["CFBundleIdentifier"]}'
        bid = bmap.get(key, info['CFBundleIdentifier'])
        try: prof, how, caps = get_profile(ident['team'], bid, dev['udid'], ident['sha1'], info, caps, work)
        except BundleIDTaken:
            # The default org.nxnative.<title ID> is the same for everyone who builds the game, and the first team to register it keeps it:
            # sign as this team's own variant instead, the same one every time (it is remembered, and derived from the team)
            bid = unique_bid(info['CFBundleIdentifier'], ident['team'])
            say(f'{info["CFBundleIdentifier"]} is taken by another developer team; signing as {bid} (an app of its own on the device)')
            shutil.rmtree(work / 'stub', ignore_errors=True)
            prof, how, caps = get_profile(ident['team'], bid, dev['udid'], ident['sha1'], info, caps, work)
            bmap[key] = bid; bids.parent.mkdir(parents=True, exist_ok=True); bids.write_text(json.dumps(bmap, indent=1))
        app, ent = sign(ipa, ident, prof, caps, bid, Path(a.out).expanduser().resolve() if a.out else None, work)
        st.end(f'{bid}, profile {how}' + (f', {", ".join(k.rsplit(".", 1)[-1] for k in caps)}' if caps else ''))

        st.start(1)
        saved, kept = backup(dev['udid'], bid)
        if saved: say(f'kept {len(kept)} files of the app\'s data on the Mac first: {saved}')
        pid = next((p.get('processIdentifier') for p in (devicectl('device', 'info', 'processes', '--device', dev['udid'], check=False) or {}).get('runningProcesses', [])
                    if f'/{app.name}/' in p.get('executable', '')), None)
        if pid: devicectl('device', 'process', 'terminate', '--device', dev['udid'], '--pid', str(pid), check=False)
        devicectl('device', 'install', 'app', '--device', dev['udid'], app)
        after = kept_files(dev['udid'], bid)
        if after is None: time.sleep(3); after = kept_files(dev['udid'], bid) or []   # the container can take a moment after an install
        lost = [f for f in kept if f not in set(after)]
        for f in lost: push(dev['udid'], bid, saved / f, f)
        st.end(f'{info.get("CFBundleShortVersionString", "")} on {dev["name"]}' + (f'; the install emptied the app\'s data, {len(lost)} files put back' if lost else ''))

        if romfs:
            st.start(2)
            n, nb, total = sync_romfs(dev['udid'], bid, romfs, st, work)
            st.end(f'{n} of {total} files sent, {nb / 2**30:.1f} GB' if n else f'all {total} files already on the device')
    say(f'done: open {info.get("CFBundleDisplayName") or info.get("CFBundleName")} on {dev["name"]}')
    return 0


if __name__ == '__main__':
    try: sys.exit(main())
    except InstallError as e: print(f'[RED] {e}', flush=True); sys.exit(1)
    except KeyboardInterrupt: sys.exit(130)
