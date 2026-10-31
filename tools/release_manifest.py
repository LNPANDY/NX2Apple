#!/usr/bin/env python3
"""latest.json for the engine, signed when a key is set (LNPANDY/NX2Apple#227): what the launcher reads to update the engine without an app release.

The manifest has the shape of EngineManifest.Manifest (frontend/Sources/NSPortBuilder/EngineManifest.swift), plus `engine_id`:

  {"version": "0.8.0", "pin": "<seedds commit>", "engine_id": "<pin>-<12 hex of the series digest>", "channel": "stable",
   "built": "2026-10-31T02:00:00Z",
   "engine": {"asset": "NX2Apple-engine.zip", "sha256": "<64 hex>", "size": 91553652},
   "app": {"asset": "NX2Apple-macOS-arm64.zip", "sha256": "...", "size": 1234},          (stable only, optional)
   "sources": ["https://github.com/LNPANDY/NX2Apple/releases/download/v0.8.0/"]}

`pin` and `engine_id` come from the engine zip itself (its .upstream-ref and .engine-id, written by `tools/engine.py tree`), so the
manifest cannot disagree with the asset it describes. The signature is a detached Ed25519 signature over the exact bytes of
latest.json, base64, in latest.json.sig next to it (EngineManifest.verify(manifest:signature:publicKey:)).

The private key is the repository secret ENGINE_SIGNING_KEY: base64 of the 32 raw bytes. Signing is optional for now. When the secret is
set, `publish` signs, and its public key must equal the one in frontend/engine-signing.pub, which the launcher compiles in: a key that
does not belong to that file stops the release. When the secret is not set, `publish` writes and uploads latest.json without a signature
and prints a warning (a GitHub annotation in CI). Signing becomes mandatory before any download source other than GitHub is added
(LNPANDY/NX2Apple#268, Cloudflare R2): `publish --source` already refuses to run without a key.

Subcommands (Python 3.9+, `pip install -r tools/requirements-release.txt`):
  keygen                       print a new key pair (private base64 for the secret, public base64 for engine-signing.pub)
  check-key [--pub FILE]       exit 0 when $ENGINE_SIGNING_KEY is unset (warning: releases go out unsigned) or set and matching the
                               public key file, exit 2 when it is set and malformed or not the key of the file
  publish --engine-zip Z --version V --channel stable|experimental --tag T --out DIR [--app-zip A] [--upload]
                               write latest.json and, when a key is set, latest.json.sig (and copies of the zips) to DIR and verify them. With --upload,
                               put the zip, latest.json and (when signed) latest.json.sig on the GitHub release TAG (gh). Without it
                               nothing is uploaded: that is the dry run. --ephemeral-key signs with a throwaway key (dry runs only,
                               never uploads)
  verify --manifest F [--sig F] [--pub FILE] [--require-signature]
                               check a signature the way the launcher does. A missing signature file is accepted with a warning while
                               ENGINE_SIGNING_KEY is not set, and is an error when the key is set or --require-signature is given
  check-rc --manifest F --version V --engine-zip Z --app-zip A --built-engine-zip B
                               before a final tag ships the files of its release candidate (RELEASING.md): exit 0 only when the
                               candidate's latest.json is the stable manifest of version V, names exactly the engine zip Z and the app zip A
                               (SHA-256, size, pin, engine_id), and the engine zip B that the final tag's commit builds holds the same
                               files as Z (the same bytes, or the same files compressed differently, which it notes)
"""
import argparse
import base64
import datetime
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
PUB_FILE = REPO / 'frontend' / 'engine-signing.pub'
KEY_ENV = 'ENGINE_SIGNING_KEY'
MANIFEST = 'latest.json'
SIGNATURE = 'latest.json.sig'
GITHUB_REPO = 'LNPANDY/NX2Apple'
EXPERIMENTAL_TAG = 'engine-experimental'
ENGINE_ID = re.compile(r'[0-9a-f]{40}-[0-9a-f]{12}')


class Fail(Exception):
    pass


def say(*a):
    print(*a, flush=True)


def warn(msg):
    """A warning that stands out in the CI log (a workflow annotation) and reads fine in a terminal."""
    if os.environ.get('GITHUB_ACTIONS') == 'true': print(f'::warning title=Engine is not signed::{msg}', flush=True)
    else: print(f'WARNING: {msg}', flush=True)


def unsigned_warning():
    warn(f'{KEY_ENV} is not set, so latest.json is published without a signature. Signing becomes mandatory before any download '
         f'source other than GitHub is added (LNPANDY/NX2Apple#268).')


def ed25519():
    try:
        from cryptography.hazmat.primitives.asymmetric import ed25519
        from cryptography.exceptions import InvalidSignature
    except ImportError:
        raise Fail('the Python package `cryptography` is missing: python3 -m pip install -r tools/requirements-release.txt')
    return ed25519, InvalidSignature


def raw32(b64, what):
    try: data = base64.b64decode(b64.strip(), validate=True)
    except Exception: raise Fail(f'{what} is not base64')
    if len(data) != 32: raise Fail(f'{what} must be the base64 of 32 raw bytes (is {len(data)} bytes)')
    return data


def private_key(b64):
    return ed25519()[0].Ed25519PrivateKey.from_private_bytes(raw32(b64, KEY_ENV))


def public_b64(priv):
    from cryptography.hazmat.primitives import serialization
    raw = priv.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
    return base64.b64encode(raw).decode()


def read_pub(path):
    """The first line of the file that is not blank and not a comment."""
    path = Path(path)
    if not path.is_file(): raise Fail(f'{path} is missing: it holds the public key the launcher compiles in')
    for line in path.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith('#'):
            raw32(line, str(path))
            return line
    raise Fail(f'{path} holds no public key yet: generate a key pair (`python3 tools/release_manifest.py keygen`), store the private '
               f'half as the repository secret {KEY_ENV}, put the public half in this file and compile the same value into the launcher')


def signing_key(pub_file, ephemeral=False):
    """The private key to sign with, after checking it belongs to the committed public key: (key, its public base64).
    (None, None) when signing is off, which is when the secret is not set."""
    if ephemeral:
        ed, _ = ed25519()
        k = ed.Ed25519PrivateKey.generate()
        return k, public_b64(k)
    secret = os.environ.get(KEY_ENV, '').strip()
    if not secret: return None, None
    key = private_key(secret)
    want = read_pub(pub_file)
    have = public_b64(key)
    if have != want:
        raise Fail(f'{KEY_ENV} does not belong to the public key in {pub_file} (its public key is {have}, the file has {want}): '
                   f'the launcher would reject every manifest')
    return key, have


def verify_signature(manifest_bytes, sig_text, pub_b64):
    ed, Invalid = ed25519()
    key = ed.Ed25519PublicKey.from_public_bytes(raw32(pub_b64, 'the public key'))
    try: sig = base64.b64decode(sig_text.strip(), validate=True)
    except Exception: return False
    try: key.verify(sig, manifest_bytes)
    except Invalid: return False
    return True


# ---- the manifest ----

def sha256_file(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''): h.update(chunk)
    return h.hexdigest()


def asset(path):
    path = Path(path)
    if not path.is_file(): raise Fail(f'{path} is missing')
    return {'asset': path.name, 'sha256': sha256_file(path), 'size': path.stat().st_size}


def engine_identity(zip_path):
    """(pin, engine_id) as the engine zip itself says."""
    try:
        with zipfile.ZipFile(zip_path) as z:
            eid = z.read('.engine-id').decode().strip()
            pin = z.read('.upstream-ref').decode().strip()
    except (KeyError, zipfile.BadZipFile, OSError) as e:
        raise Fail(f'{zip_path} is not an engine tree zip from `tools/engine.py tree` (.engine-id or .upstream-ref missing: {e})')
    if not ENGINE_ID.fullmatch(eid): raise Fail(f'.engine-id in {zip_path} is not <pin>-<12 hex>: {eid!r}')
    if eid[:40] != pin: raise Fail(f'.engine-id ({eid}) and .upstream-ref ({pin}) in {zip_path} disagree about the pin')
    return pin, eid


def build_manifest(engine_zip, version, channel, tag, app_zip=None, repo=GITHUB_REPO, built=None, extra_sources=()):
    if channel not in ('stable', 'experimental'): raise Fail(f'channel must be stable or experimental, not {channel!r}')
    if not version.strip(): raise Fail('--version is empty')
    pin, eid = engine_identity(engine_zip)
    built = built or datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    m = {'version': version, 'pin': pin, 'engine_id': eid, 'channel': channel, 'built': built, 'engine': asset(engine_zip)}
    if app_zip: m['app'] = asset(app_zip)
    m['sources'] = [f'https://github.com/{repo}/releases/download/{tag}/', *extra_sources]
    return (json.dumps(m, indent=2) + '\n').encode()


# ---- publishing ----

def gh(*a, check=True):
    r = subprocess.run(['gh', *a], capture_output=True, text=True)
    if check and r.returncode: raise Fail(f'gh {" ".join(a[:3])} failed: {(r.stderr or r.stdout).strip()[-600:]}')
    return r


def upload(files, tag, repo, channel, notes):
    """Engine zip first, the manifest and its signature last, so a launcher that reads the new manifest finds its zip.
    Without a signature among the files, an older latest.json.sig on the release is removed first: it would not match the new manifest."""
    exists = gh('release', 'view', tag, '-R', repo, check=False).returncode == 0
    if channel == 'experimental':
        # A pre-release under a fixed tag, never "latest", so it never becomes what the app's own update looks at.
        if exists: gh('release', 'edit', tag, '-R', repo, '--prerelease', '--latest=false', '--notes', notes)
        else: gh('release', 'create', tag, '-R', repo, '--prerelease', '--latest=false', '--title', 'Engine (experimental)', '--notes', notes)
    elif not exists:
        raise Fail(f'the release {tag} does not exist: the release workflow creates it before it publishes the engine')
    if SIGNATURE not in [Path(f).name for f in files]:
        gh('release', 'delete-asset', tag, SIGNATURE, '-R', repo, '--yes', check=False)
    for f in files:
        gh('release', 'upload', tag, str(f), '-R', repo, '--clobber')
        say(f'uploaded {Path(f).name} to {repo} {tag}')


def cmd_publish(a):
    if a.upload and a.ephemeral_key: raise Fail('--ephemeral-key signs with a throwaway key: it never uploads')
    key, pub = signing_key(a.pub, a.ephemeral_key)
    if key is None and a.source:
        raise Fail(f'--source adds a download source other than GitHub, which needs a signature: set {KEY_ENV}')
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    zsrc = Path(a.engine_zip)
    data = build_manifest(zsrc, a.version, a.channel, a.tag, a.app_zip, a.repo, a.built, a.source or ())
    files = [out / zsrc.name, out / MANIFEST]
    if zsrc.resolve() != files[0].resolve(): shutil.copyfile(zsrc, files[0])
    files[1].write_bytes(data)
    sigfile = out / SIGNATURE
    if key is not None:
        files.append(sigfile)
        sigfile.write_text(base64.b64encode(key.sign(data)).decode())   # no newline: Data(base64Encoded:) rejects one
        if not verify_signature(files[1].read_bytes(), sigfile.read_text(), pub): raise Fail('the signature just made does not verify')
    elif sigfile.exists():
        sigfile.unlink()   # a signature left in --out by an earlier run does not belong to this manifest
    m = json.loads(data)
    how = f'signed ({"ephemeral key" if a.ephemeral_key else KEY_ENV})' if key is not None else 'not signed'
    say(f'{MANIFEST}: {m["channel"]} {m["version"]} engine_id {m["engine_id"]} built {m["built"]}, {how}')
    if key is None: unsigned_warning()
    if a.upload:
        notes = (f'Engine {m["engine_id"]} (seedds/nxnative {m["pin"][:12]} + the patch series), built {m["built"]}. '
                 + ('Experimental: built by the nightly sync and checked by CI only, not played on hardware. The launcher offers it as a manual, opt-in update.'
                    if a.channel == 'experimental' else 'The engine of this release.'))
        upload(files, a.tag, a.repo, a.channel, notes)
    else:
        say(f'dry run: nothing uploaded; the files are in {out}')
    return 0


def cmd_check_key(a):
    key, pub = signing_key(a.pub)
    if key is None:
        unsigned_warning()
        return 0
    say(f'{KEY_ENV} matches {a.pub} ({pub})')
    return 0


def cmd_verify(a):
    sig = Path(a.sig) if a.sig else Path(a.manifest).with_name(SIGNATURE)
    if not sig.is_file():
        if a.require_signature or os.environ.get(KEY_ENV, '').strip():
            say(f'signature MISSING: {sig} does not exist')
            return 1
        warn(f'{sig} does not exist and {KEY_ENV} is not set: the manifest is accepted without a signature.')
        return 0
    pub = read_pub(a.pub)
    ok = verify_signature(Path(a.manifest).read_bytes(), sig.read_text(), pub)
    say('signature valid' if ok else 'signature INVALID')
    return 0 if ok else 1


def check_rc(manifest, version, engine_zip, app_zip, built_engine_zip):
    """The reasons the release candidate's files are not the release `version` (empty when they are)."""
    try: m = json.loads(Path(manifest).read_bytes())
    except (OSError, ValueError) as e: return [f'{manifest} is not readable JSON: {e}']
    bad = []
    if m.get('channel') != 'stable': bad.append(f'the candidate\'s manifest has channel {m.get("channel")!r}, not stable')
    if m.get('version') != version: bad.append(f'the candidate\'s manifest is for version {m.get("version")!r}, not {version!r}')
    for key, path in (('engine', engine_zip), ('app', app_zip)):
        want = m.get(key) or {}
        got = asset(path)
        for field in ('asset', 'sha256', 'size'):
            if want.get(field) != got[field]:
                bad.append(f'{key} {field}: the manifest says {want.get(field)!r}, the candidate\'s {Path(path).name} has {got[field]!r}')
    pin, eid = engine_identity(engine_zip)
    if (m.get('pin'), m.get('engine_id')) != (pin, eid):
        bad.append(f'the manifest names pin {m.get("pin")} engine_id {m.get("engine_id")}, the candidate\'s engine zip is {eid}')
    _, beid = engine_identity(built_engine_zip)
    if beid != eid:
        bad.append(f'this commit builds engine {beid}, the candidate carries {eid}')
    elif sha256_file(built_engine_zip) != sha256_file(engine_zip):
        # The zip is reproducible, so the bytes normally match. Another zlib on the runner could compress the same files differently:
        # that is still the tested engine (the release ships the candidate's zip in any case). Different files are not.
        diff = sorted(set(zip_files(built_engine_zip)) ^ set(zip_files(engine_zip)))
        if diff:
            names = sorted({n for n, _, _ in diff})
            bad.append(f'this commit builds an engine zip with other files than the candidate\'s: {", ".join(names[:5])}'
                       + (f' and {len(names) - 5} more' if len(names) > 5 else ''))
        else:
            say(f'note: the engine zip this commit builds has the same files as the candidate\'s, compressed differently '
                f'(SHA-256 {sha256_file(built_engine_zip)}). The release ships the candidate\'s zip')
    return bad


def zip_files(path):
    """Each file of a zip as (name, CRC-32, size): what it holds, whatever the compression."""
    with zipfile.ZipFile(path) as z:
        return [(i.filename, i.CRC, i.file_size) for i in z.infolist()]


def cmd_check_rc(a):
    bad = check_rc(a.manifest, a.version, a.engine_zip, a.app_zip, a.built_engine_zip)
    for b in bad: say(f'::error title=Not the tested build::{b}' if os.environ.get('GITHUB_ACTIONS') == 'true' else f'error: {b}')
    if bad:
        say('the final release would not ship the build of its release candidate: nothing is published')
        return 1
    m = json.loads(Path(a.manifest).read_bytes())
    say(f'same build as the release candidate: {m["version"]} engine_id {m["engine_id"]}, engine SHA-256 {m["engine"]["sha256"]}, '
        f'app SHA-256 {m["app"]["sha256"]}')
    return 0


def cmd_keygen(a):
    ed, _ = ed25519()
    from cryptography.hazmat.primitives import serialization
    k = ed.Ed25519PrivateKey.generate()
    raw = k.private_bytes(serialization.Encoding.Raw, serialization.PrivateFormat.Raw, serialization.NoEncryption())
    say(f'private (the repository secret {KEY_ENV}, keep it out of the repository): {base64.b64encode(raw).decode()}')
    say(f'public (frontend/engine-signing.pub and the launcher): {public_b64(k)}')
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)
    sub.add_parser('keygen').set_defaults(f=cmd_keygen)
    s = sub.add_parser('check-key'); s.add_argument('--pub', default=str(PUB_FILE)); s.set_defaults(f=cmd_check_key)
    s = sub.add_parser('verify'); s.add_argument('--manifest', required=True); s.add_argument('--sig', help='default: latest.json.sig next to the manifest'); s.add_argument('--pub', default=str(PUB_FILE))
    s.add_argument('--require-signature', action='store_true'); s.set_defaults(f=cmd_verify)
    s = sub.add_parser('check-rc')
    for o in ('--manifest', '--version', '--engine-zip', '--app-zip', '--built-engine-zip'): s.add_argument(o, required=True)
    s.set_defaults(f=cmd_check_rc)
    s = sub.add_parser('publish')
    s.add_argument('--engine-zip', required=True); s.add_argument('--app-zip'); s.add_argument('--version', required=True)
    s.add_argument('--channel', required=True, choices=('stable', 'experimental')); s.add_argument('--tag', required=True)
    s.add_argument('--out', required=True); s.add_argument('--repo', default=os.environ.get('GITHUB_REPOSITORY') or GITHUB_REPO)
    s.add_argument('--built', help='UTC timestamp, 2026-10-31T02:00:00Z (default: now)'); s.add_argument('--source', action='append', help='another base URL for the assets (a mirror), tried after GitHub')
    s.add_argument('--pub', default=str(PUB_FILE)); s.add_argument('--upload', action='store_true'); s.add_argument('--ephemeral-key', action='store_true')
    s.set_defaults(f=cmd_publish)
    a = ap.parse_args(argv)
    try:
        return a.f(a)
    except Fail as e:
        print(f'release_manifest.py: {e}', file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
