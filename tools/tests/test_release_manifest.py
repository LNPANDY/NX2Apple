"""tools/release_manifest.py (LNPANDY/NX2Apple#227): latest.json has the shape EngineManifest.Manifest decodes, the signature is a
detached Ed25519 signature over its exact bytes, a key that is set but wrong stops the release, no key means an unsigned release with
a warning, and uploads go in the right order with a fake `gh`. The keys are generated here: nothing secret is used and nothing touches the network."""
import base64
import hashlib
import importlib
import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

TOOLS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOLS))
R = importlib.import_module('release_manifest')

try:
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric import ed25519
except ImportError:
    ed25519 = None

PIN = 'ee6648cb2bb46c19255c1d04f88e9c40d36ef6b4'
EID = PIN + '-d4abe1fa2485'


def new_key():
    k = ed25519.Ed25519PrivateKey.generate()
    raw = k.private_bytes(serialization.Encoding.Raw, serialization.PrivateFormat.Raw, serialization.NoEncryption())
    return k, base64.b64encode(raw).decode(), R.public_b64(k)


@unittest.skipIf(ed25519 is None, 'needs `cryptography` (tools/requirements-release.txt)')
class Manifest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix='test-manifest-'))
        self.addCleanup(__import__('shutil').rmtree, self.tmp, True)
        self.key, self.secret, self.pub = new_key()
        self.pubfile = self.tmp / 'engine-signing.pub'
        self.pubfile.write_text(f'# comment\n\n{self.pub}\n')
        self.engine = self.zip('NX2Apple-engine.zip', {'.engine-id': EID + '\n', '.upstream-ref': PIN + '\n', 'dm/a.c': 'x'})
        self.app = self.tmp / 'NX2Apple-macOS-arm64.zip'; self.app.write_bytes(b'app bytes')
        self.env = dict(os.environ, **{R.KEY_ENV: self.secret})
        self.old_env = dict(os.environ)
        os.environ[R.KEY_ENV] = self.secret
        self.addCleanup(self.restore)

    def restore(self):
        os.environ.clear(); os.environ.update(self.old_env)

    def zip(self, name, files):
        p = self.tmp / name
        with zipfile.ZipFile(p, 'w') as z:
            for n, t in files.items(): z.writestr(n, t)
        return p

    def publish(self, *extra, channel='stable', tag='v0.8.0', out='out', expect=0):
        args = ['publish', '--engine-zip', str(self.engine), '--version', '0.8.0', '--channel', channel, '--tag', tag,
                '--out', str(self.tmp / out), '--pub', str(self.pubfile), '--built', '2026-10-31T02:00:00Z', *extra]
        self.assertEqual(R.main(args), expect)
        return self.tmp / out

    # ---- the shape the launcher decodes ----

    def test_the_manifest_has_every_field_the_launcher_decodes(self):
        out = self.publish('--app-zip', str(self.app))
        m = json.loads((out / 'latest.json').read_text())
        self.assertEqual(m['version'], '0.8.0'); self.assertEqual(m['pin'], PIN); self.assertEqual(m['engine_id'], EID)
        self.assertEqual(m['channel'], 'stable'); self.assertEqual(m['built'], '2026-10-31T02:00:00Z')
        self.assertEqual(m['sources'], ['https://github.com/LNPANDY/NX2Apple/releases/download/v0.8.0/'])
        self.assertEqual(set(m['engine']), {'asset', 'sha256', 'size'})
        self.assertEqual(m['engine']['asset'], 'NX2Apple-engine.zip')
        self.assertEqual(m['engine']['sha256'], hashlib.sha256(self.engine.read_bytes()).hexdigest())
        self.assertEqual(m['engine']['size'], self.engine.stat().st_size)
        self.assertEqual(m['app'], {'asset': 'NX2Apple-macOS-arm64.zip', 'sha256': hashlib.sha256(b'app bytes').hexdigest(), 'size': 9})
        for a in (m['engine'], m['app']): self.assertRegex(a['sha256'], r'^[0-9a-f]{64}$')   # EngineManifest.isDigest
        self.assertRegex(m['engine_id'], r'^[0-9a-f]{40}-[0-9a-f]{12}$')

    def test_the_experimental_channel_has_no_app_and_its_own_source(self):
        out = self.publish(channel='experimental', tag='engine-experimental')
        m = json.loads((out / 'latest.json').read_text())
        self.assertEqual(m['channel'], 'experimental'); self.assertNotIn('app', m)
        self.assertEqual(m['sources'], ['https://github.com/LNPANDY/NX2Apple/releases/download/engine-experimental/'])

    def test_the_manifest_bytes_are_the_same_for_the_same_input(self):
        a = (self.publish(out='a') / 'latest.json').read_bytes(); b = (self.publish(out='b') / 'latest.json').read_bytes()
        self.assertEqual(a, b)

    def test_a_mirror_is_added_as_a_source_after_github(self):
        out = self.publish('--source', 'https://mirror.example/engine/')
        self.assertEqual(json.loads((out / 'latest.json').read_text())['sources'][1], 'https://mirror.example/engine/')

    def test_a_zip_that_is_not_an_engine_tree_is_refused(self):
        self.engine = self.zip('bad.zip', {'dm/a.c': 'x'})
        self.publish(expect=2)
        self.engine = self.zip('bad2.zip', {'.engine-id': 'ABC\n', '.upstream-ref': PIN + '\n'})
        self.publish(expect=2)
        self.engine = self.zip('bad3.zip', {'.engine-id': PIN[:-1] + '0-d4abe1fa2485\n', '.upstream-ref': PIN + '\n'})
        self.publish(expect=2)

    # ---- the signature ----

    def test_the_signature_is_detached_ed25519_over_the_exact_bytes(self):
        out = self.publish()
        data = (out / 'latest.json').read_bytes(); sig = (out / 'latest.json.sig').read_text()
        self.assertFalse(sig.endswith('\n'))                           # Data(base64Encoded:) rejects a newline
        raw = base64.b64decode(sig, validate=True); self.assertEqual(len(raw), 64)
        self.key.public_key().verify(raw, data)                       # what CryptoKit's isValidSignature checks
        self.assertTrue(R.verify_signature(data, sig, self.pub))
        self.assertFalse(R.verify_signature(data + b' ', sig, self.pub))   # one byte more: invalid
        self.assertFalse(R.verify_signature(data.replace(b'0.8.0', b'0.8.1'), sig, self.pub))
        other = new_key()[2]
        self.assertFalse(R.verify_signature(data, sig, other))
        self.assertFalse(R.verify_signature(data, 'not base64!', self.pub))

    def test_verify_subcommand(self):
        out = self.publish()
        args = ['verify', '--manifest', str(out / 'latest.json'), '--sig', str(out / 'latest.json.sig'), '--pub', str(self.pubfile)]
        self.assertEqual(R.main(args), 0)
        self.assertEqual(R.main(['verify', '--manifest', str(out / 'latest.json'), '--pub', str(self.pubfile)]), 0)   # the .sig next to it
        (out / 'latest.json').write_bytes((out / 'latest.json').read_bytes().replace(b'stable', b'rolling'))
        self.assertEqual(R.main(args), 1)

    def test_verify_fails_for_a_missing_signature_while_the_key_is_set(self):
        out = self.publish()
        (out / 'latest.json.sig').unlink()
        self.assertEqual(R.main(['verify', '--manifest', str(out / 'latest.json'), '--pub', str(self.pubfile)]), 1)

    # ---- the key check ----

    def test_without_the_secret_the_key_check_passes_with_a_warning(self):
        import contextlib, io
        del os.environ[R.KEY_ENV]
        os.environ.pop('GITHUB_ACTIONS', None)   # in CI the warning is an annotation, the plain text is the local one
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf): self.assertEqual(R.main(['check-key', '--pub', str(self.pubfile)]), 0)
        self.assertIn('ENGINE_SIGNING_KEY is not set', buf.getvalue()); self.assertIn('WARNING', buf.getvalue())
        os.environ[R.KEY_ENV] = '   '
        self.assertEqual(R.main(['check-key', '--pub', str(self.pubfile)]), 0)

    def test_a_release_fails_when_the_key_is_not_the_one_in_the_repository(self):
        os.environ[R.KEY_ENV] = new_key()[1]
        self.assertEqual(R.main(['check-key', '--pub', str(self.pubfile)]), 2)
        self.publish(expect=2)
        self.assertFalse((self.tmp / 'out' / 'latest.json').exists())

    def test_a_set_key_fails_while_the_repository_has_no_public_key(self):
        self.pubfile.write_text('# nothing yet\n')
        self.assertEqual(R.main(['check-key', '--pub', str(self.pubfile)]), 2)
        self.publish(expect=2)
        self.pubfile.unlink()
        self.assertEqual(R.main(['check-key', '--pub', str(self.pubfile)]), 2)

    def test_malformed_keys_are_refused(self):
        os.environ[R.KEY_ENV] = 'not base64!'
        self.assertEqual(R.main(['check-key', '--pub', str(self.pubfile)]), 2)
        os.environ[R.KEY_ENV] = base64.b64encode(b'short').decode()
        self.assertEqual(R.main(['check-key', '--pub', str(self.pubfile)]), 2)
        os.environ[R.KEY_ENV] = self.secret
        self.pubfile.write_text(base64.b64encode(b'short').decode() + '\n')
        self.assertEqual(R.main(['check-key', '--pub', str(self.pubfile)]), 2)

    def test_the_matching_key_passes(self):
        self.assertEqual(R.main(['check-key', '--pub', str(self.pubfile)]), 0)

    def test_a_dry_run_can_sign_with_a_throwaway_key_but_never_upload(self):
        del os.environ[R.KEY_ENV]
        self.pubfile.write_text('# none\n')
        out = self.publish('--ephemeral-key')
        data = (out / 'latest.json').read_bytes(); sig = (out / 'latest.json.sig').read_text()
        self.assertFalse(R.verify_signature(data, sig, self.pub))      # not the repository's key
        self.publish('--ephemeral-key', '--upload', out='out2', expect=2)

    def test_keygen_makes_a_pair_the_check_accepts(self):
        import contextlib, io
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf): self.assertEqual(R.main(['keygen']), 0)
        lines = buf.getvalue().splitlines()
        priv, pub = lines[0].rsplit(': ', 1)[1], lines[1].rsplit(': ', 1)[1]
        os.environ[R.KEY_ENV] = priv; self.pubfile.write_text(pub + '\n')
        self.assertEqual(R.main(['check-key', '--pub', str(self.pubfile)]), 0)

    # ---- upload, with a fake gh ----

    def fake_gh(self, exists):
        """A `gh` that logs its arguments and answers `release view` as asked."""
        d = self.tmp / 'bin'; d.mkdir(exist_ok=True)
        log = self.tmp / 'gh.log'
        gh = d / 'gh'
        gh.write_text(f'#!/bin/sh\necho "$@" >> "{log}"\n[ "$1 $2" = "release view" ] && exit {0 if exists else 1}\nexit 0\n')
        gh.chmod(gh.stat().st_mode | stat.S_IXUSR)
        os.environ['PATH'] = f'{d}:{os.environ["PATH"]}'
        return log

    def calls(self, log):
        return [l.split() for l in log.read_text().splitlines()]

    def test_the_stable_release_uploads_the_zip_first_and_the_signature_last(self):
        log = self.fake_gh(exists=True)
        self.publish('--app-zip', str(self.app), '--upload', '--repo', 'LNPANDY/NX2Apple')
        ups = [c for c in self.calls(log) if c[:2] == ['release', 'upload']]
        self.assertEqual([Path(c[3]).name for c in ups], ['NX2Apple-engine.zip', 'latest.json', 'latest.json.sig'])
        self.assertTrue(all(c[2] == 'v0.8.0' and '--clobber' in c and c[4:6] == ['-R', 'LNPANDY/NX2Apple'] for c in ups))
        self.assertFalse([c for c in self.calls(log) if c[:2] in (['release', 'create'], ['release', 'edit'])])

    def test_the_stable_release_needs_its_release_to_exist(self):
        log = self.fake_gh(exists=False)
        self.publish('--upload', expect=2)
        self.assertFalse([c for c in self.calls(log) if c[:2] == ['release', 'upload']])

    def test_the_experimental_tag_is_created_as_a_prerelease_that_is_never_latest(self):
        log = self.fake_gh(exists=False)
        self.publish('--upload', channel='experimental', tag='engine-experimental')
        create = [c for c in self.calls(log) if c[:2] == ['release', 'create']]
        self.assertEqual(len(create), 1)
        self.assertEqual(create[0][2], 'engine-experimental'); self.assertIn('--prerelease', create[0]); self.assertIn('--latest=false', create[0])
        self.assertEqual(len([c for c in self.calls(log) if c[:2] == ['release', 'upload']]), 3)

    def test_an_existing_experimental_release_is_kept_a_prerelease_and_its_assets_replaced(self):
        log = self.fake_gh(exists=True)
        self.publish('--upload', channel='experimental', tag='engine-experimental')
        edit = [c for c in self.calls(log) if c[:2] == ['release', 'edit']]
        self.assertEqual(len(edit), 1); self.assertIn('--prerelease', edit[0]); self.assertIn('--latest=false', edit[0])
        self.assertFalse([c for c in self.calls(log) if c[:2] == ['release', 'create']])
        self.assertTrue(all('--clobber' in c for c in self.calls(log) if c[:2] == ['release', 'upload']))

    def test_a_dry_run_calls_gh_never(self):
        log = self.fake_gh(exists=True)
        self.publish()
        self.assertFalse(log.exists())

    def test_a_signed_upload_does_not_delete_the_signature_asset(self):
        log = self.fake_gh(exists=True)
        self.publish('--upload')
        self.assertFalse([c for c in self.calls(log) if c[:2] == ['release', 'delete-asset']])


class Unsigned(unittest.TestCase):
    """No ENGINE_SIGNING_KEY: the engine is published without a signature and the log says so. Needs no `cryptography`."""
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix='test-manifest-unsigned-'))
        self.addCleanup(__import__('shutil').rmtree, self.tmp, True)
        self.pubfile = self.tmp / 'engine-signing.pub'
        self.pubfile.write_text('# no key yet\n')
        self.engine = self.tmp / 'NX2Apple-engine.zip'
        with zipfile.ZipFile(self.engine, 'w') as z:
            z.writestr('.engine-id', EID + '\n'); z.writestr('.upstream-ref', PIN + '\n'); z.writestr('dm/a.c', 'x')
        self.old_env = dict(os.environ)
        os.environ.pop(R.KEY_ENV, None); os.environ.pop('GITHUB_ACTIONS', None)
        self.addCleanup(self.restore)

    def restore(self):
        os.environ.clear(); os.environ.update(self.old_env)

    def publish(self, *extra, channel='stable', tag='v0.8.0', out='out', expect=0):
        import contextlib, io
        args = ['publish', '--engine-zip', str(self.engine), '--version', '0.8.0', '--channel', channel, '--tag', tag,
                '--out', str(self.tmp / out), '--pub', str(self.pubfile), '--built', '2026-10-31T02:00:00Z', *extra]
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf): self.assertEqual(R.main(args), expect)
        return self.tmp / out, buf.getvalue()

    def fake_gh(self):
        d = self.tmp / 'bin'; d.mkdir(exist_ok=True)
        log = self.tmp / 'gh.log'
        gh = d / 'gh'
        gh.write_text(f'#!/bin/sh\necho "$@" >> "{log}"\nexit 0\n')
        gh.chmod(gh.stat().st_mode | stat.S_IXUSR)
        os.environ['PATH'] = f'{d}:{os.environ["PATH"]}'
        return log

    def test_the_manifest_is_written_without_a_signature_and_with_a_warning(self):
        out, text = self.publish()
        self.assertTrue((out / 'latest.json').is_file()); self.assertFalse((out / 'latest.json.sig').exists())
        self.assertEqual(json.loads((out / 'latest.json').read_text())['engine_id'], EID)
        self.assertIn('not signed', text); self.assertIn('WARNING: ENGINE_SIGNING_KEY is not set', text)
        self.assertIn('LNPANDY/NX2Apple#268', text)

    def test_in_ci_the_warning_is_a_workflow_annotation(self):
        os.environ['GITHUB_ACTIONS'] = 'true'
        self.assertIn('::warning title=Engine is not signed::ENGINE_SIGNING_KEY is not set', self.publish()[1])

    def test_a_signature_left_in_the_output_folder_is_removed(self):
        (self.tmp / 'out').mkdir()
        (self.tmp / 'out' / 'latest.json.sig').write_text('stale')
        self.assertFalse((self.publish()[0] / 'latest.json.sig').exists())

    def test_the_upload_drops_an_older_signature_and_sends_no_new_one(self):
        log = self.fake_gh()
        self.publish('--upload', channel='experimental', tag='engine-experimental')
        calls = [l.split() for l in log.read_text().splitlines()]
        self.assertEqual([c[3] for c in calls if c[:2] == ['release', 'delete-asset']], ['latest.json.sig'])
        self.assertEqual([Path(c[3]).name for c in calls if c[:2] == ['release', 'upload']], ['NX2Apple-engine.zip', 'latest.json'])
        self.assertLess([c[:2] for c in calls].index(['release', 'delete-asset']), [c[:2] for c in calls].index(['release', 'upload']))

    def test_a_download_source_other_than_github_needs_a_key(self):
        out, _ = self.publish('--source', 'https://mirror.example/engine/', expect=2)
        self.assertFalse((out / 'latest.json').exists())

    def test_verify_accepts_an_unsigned_manifest_with_a_warning_unless_a_signature_is_required(self):
        out, _ = self.publish()
        args = ['verify', '--manifest', str(out / 'latest.json'), '--pub', str(self.pubfile)]
        self.assertEqual(R.main(args), 0)
        self.assertEqual(R.main([*args, '--require-signature']), 1)


if __name__ == '__main__':
    unittest.main()
