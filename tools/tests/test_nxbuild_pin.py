"""frontend/tools/nxbuild.py and frontend/nxbuild.pin (LNPANDY/NX2Apple#1460): the pin's form, the digest checks before anything is bundled (pin, SHA256SUMS,
MANIFEST.json), the pair nxb and nxkit-host, and a release's SHA256SUMS. No network: zips are made in a temporary folder."""
import hashlib, importlib.util, io, json, tempfile, unittest, urllib.error, zipfile
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('nxbuild', ROOT / 'frontend/tools/nxbuild.py')
nxbuild = importlib.util.module_from_spec(spec); spec.loader.exec_module(nxbuild)


class Pin(unittest.TestCase):
    def test_the_repository_pin_reads(self):
        pin = nxbuild.read()
        self.assertRegex(pin['version'], r'^\d+\.\d+\.\d+$')
        self.assertTrue(pin['url'].startswith('https://github.com/v0lumehi/nxkit/releases/download/v' + pin['version'] + '/'))
        self.assertTrue(pin['url'].endswith('-macos-arm64.zip'))
        self.assertTrue(pin['sha256'] is None or len(pin['sha256']) == 64)

    def test_a_placeholder_bundles_nothing(self):
        with tempfile.TemporaryDirectory() as t:
            p = Path(t, 'pin'); p.write_text('# c\nversion\t0.1.0\nsha256\tPLACEHOLDER\nurl\thttps://x/v{version}/nxb-v{version}.zip\n')
            self.assertEqual(nxbuild.read(p), {'version': '0.1.0', 'sha256': None, 'url': 'https://x/v0.1.0/nxb-v0.1.0.zip'})
            p.write_text('version\t0.1\nsha256\tx\nurl\tu\n')
            with self.assertRaises(SystemExit): nxbuild.read(p)

    def zip(self, t, files):
        z = Path(t, 'nxb.zip')
        with zipfile.ZipFile(z, 'w') as f:
            for n, b in files.items(): f.writestr(n, b)
        return z

    def release(self, t, files=None, manifest=None, drop=()):
        """A zip laid out as an nxkit release (one folder with nxb, nxkit-host and MANIFEST.json) and its SHA256SUMS text"""
        files = files or {'nxb': b'nxb-binary', 'nxkit-host': b'host-binary'}
        root = 'nxb-v0.1.0-macos-arm64'
        m = manifest or {'format': 1, 'version': '0.1.0', 'platform': 'macos', 'arch': 'arm64', 'macos_min': '26.0',
                         'files': {n: hashlib.sha256(b).hexdigest() for n, b in files.items()}}
        entries = {f'{root}/{n}': b for n, b in files.items() if n not in drop}
        entries[f'{root}/MANIFEST.json'] = json.dumps(m).encode()
        entries[f'{root}/LICENSE'] = b'license'
        entries[f'{root}/THIRD_PARTY.md'] = b'third'
        z = Path(t, f'{root}.zip')
        with zipfile.ZipFile(z, 'w') as f:
            for n, b in entries.items(): f.writestr(n, b)
        zsha = hashlib.sha256(z.read_bytes()).hexdigest()
        sums = f'{zsha}  {z.name}\n' + ''.join(f'{hashlib.sha256(b).hexdigest()}  {root}/{n}\n' for n, b in files.items())
        return z, zsha, sums

    def test_a_good_release_bundles_nxb_and_nxkit_host_with_its_manifest(self):
        with tempfile.TemporaryDirectory() as t:
            z, sha, sums = self.release(t)
            out = nxbuild.unpack(z, sha, Path(t, 'res/nxbuild'), sums)
            self.assertEqual([p.name for p in out], ['nxb', 'nxkit-host'])
            self.assertEqual(Path(t, 'res/nxbuild/nxb').read_bytes(), b'nxb-binary')
            self.assertEqual(Path(t, 'res/nxbuild/nxkit-host').read_bytes(), b'host-binary')
            for n in ('MANIFEST.json', 'LICENSE', 'THIRD_PARTY.md'): self.assertTrue(Path(t, 'res/nxbuild', n).is_file(), n)
            for p in out: self.assertTrue(p.stat().st_mode & 0o111)

    def test_the_digest_is_checked_before_unpacking(self):
        with tempfile.TemporaryDirectory() as t:
            z, sha, sums = self.release(t)
            with self.assertRaises(SystemExit) as e: nxbuild.unpack(z, 'f' * 64, Path(t, 'res'), sums)
            self.assertIn('not bundled', str(e.exception))
            self.assertFalse(z.exists(), 'a zip whose digest differs is deleted')
            self.assertFalse(Path(t, 'res').exists(), 'nothing is unpacked')

    def test_sha256sums_must_list_the_pinned_zip(self):
        with tempfile.TemporaryDirectory() as t:
            z, sha, sums = self.release(t)
            bad = sums.replace(sha, 'e' * 64)
            with self.assertRaises(SystemExit) as e: nxbuild.unpack(z, sha, Path(t, 'res'), bad)
            self.assertIn('SHA256SUMS', str(e.exception))
            self.assertFalse(Path(t, 'res').exists())

    def test_a_program_that_differs_from_the_manifest_or_the_sums_is_not_bundled(self):
        with tempfile.TemporaryDirectory() as t:
            files = {'nxb': b'nxb-binary', 'nxkit-host': b'host-binary'}
            m = {'format': 1, 'arch': 'arm64', 'files': {'nxb': hashlib.sha256(b'nxb-binary').hexdigest(), 'nxkit-host': 'a' * 64}}
            z, sha, sums = self.release(t, files, manifest=m)
            with self.assertRaises(SystemExit) as e: nxbuild.unpack(z, sha, Path(t, 'res'), sums)
            self.assertIn('MANIFEST.json', str(e.exception))
            self.assertFalse(Path(t, 'res').exists())
        with tempfile.TemporaryDirectory() as t:
            z, sha, sums = self.release(t)
            host_line = next(l for l in sums.splitlines() if l.endswith('/nxkit-host'))
            bad = sums.replace(host_line, 'c' * 64 + '  ' + host_line.split('  ')[1])
            with self.assertRaises(SystemExit) as e: nxbuild.unpack(z, sha, Path(t, 'res'), bad)
            self.assertIn('SHA256SUMS says', str(e.exception))

    def test_a_release_without_nxkit_host_is_not_bundled(self):
        with tempfile.TemporaryDirectory() as t:
            z, sha, sums = self.release(t, drop=('nxkit-host',))
            with self.assertRaises(SystemExit) as e: nxbuild.unpack(z, sha, Path(t, 'res'), sums)
            self.assertIn('no nxkit-host', str(e.exception))
            self.assertFalse(Path(t, 'res').exists())

    def test_an_unknown_manifest_format_or_arch_is_not_bundled(self):
        with tempfile.TemporaryDirectory() as t:
            files = {'nxb': b'a', 'nxkit-host': b'b'}
            fs = {n: hashlib.sha256(b).hexdigest() for n, b in files.items()}
            for m in ({'format': 2, 'arch': 'arm64', 'files': fs}, {'format': 1, 'arch': 'x86_64', 'files': fs}):
                z, sha, sums = self.release(t, files, manifest=m)
                with self.assertRaises(SystemExit): nxbuild.unpack(z, sha, Path(t, 'res'), sums)

    def test_the_repository_pin_is_0_10_2_or_later(self):
        v = tuple(int(x) for x in nxbuild.read()['version'].split('.'))
        self.assertGreaterEqual(v, (0, 10, 2), 'the first release with nxkit-host and MANIFEST.json')

    def test_sha256sums(self):
        text = f'{"a" * 64}  nxb-v0.1.0-macos-arm64.zip\n{"B" * 64} *other.zip\n'
        self.assertEqual(nxbuild.sums_digest(text, 'nxb-v0.1.0-macos-arm64.zip'), 'a' * 64)
        self.assertEqual(nxbuild.sums_digest(text, 'other.zip'), 'b' * 64)
        with self.assertRaises(SystemExit): nxbuild.sums_digest(text, 'missing.zip')

    def test_download_retries_transient_gateway_errors(self):
        err504 = urllib.error.HTTPError('https://x/nxb.zip', 504, 'Gateway Time-out', {}, None)
        err404 = urllib.error.HTTPError('https://x/nxb.zip', 404, 'Not Found', {}, None)
        with tempfile.TemporaryDirectory() as t:
            dest = Path(t, 'nxb.zip')
            with mock.patch('urllib.request.urlopen', side_effect=[err504, urllib.error.URLError('reset'), io.BytesIO(b'zip-bytes')]) as m:
                data = nxbuild.download('https://x/nxb.zip', dest, retries=4, delay=0)
            self.assertEqual(m.call_count, 3)
            self.assertEqual(data, b'zip-bytes')
            self.assertEqual(dest.read_bytes(), b'zip-bytes')
            self.assertFalse(Path(f'{dest}.part').exists())
            with mock.patch('urllib.request.urlopen', side_effect=[err404]) as m:
                with self.assertRaises(urllib.error.HTTPError):
                    nxbuild.download('https://x/nxb.zip', dest, retries=4, delay=0)
            self.assertEqual(m.call_count, 1)
            with mock.patch('urllib.request.urlopen', side_effect=[err504, err504]) as m:
                with self.assertRaises(urllib.error.HTTPError):
                    nxbuild.download('https://x/nxb.zip', dest, retries=2, delay=0)
            self.assertEqual(m.call_count, 2)
            # A GitHub release URL uses `gh release download` when available and falls back to urlopen otherwise
            gh_url = 'https://github.com/v0lumehi/nxkit/releases/download/v0.9.1/nxb-v0.9.1-macos-arm64.zip'
            def fake_run(cmd, **_):
                Path(cmd[cmd.index('-O') + 1]).write_bytes(b'from-gh')
                return mock.Mock(returncode=0)
            with mock.patch.object(nxbuild.shutil, 'which', return_value='/usr/bin/gh'), \
                 mock.patch.object(nxbuild.subprocess, 'run', side_effect=fake_run) as run_mock, \
                 mock.patch('urllib.request.urlopen') as url_mock:
                data = nxbuild.download(gh_url, dest, retries=2, delay=0)
            self.assertEqual(data, b'from-gh')
            self.assertEqual(dest.read_bytes(), b'from-gh')
            self.assertEqual(run_mock.call_count, 1)
            self.assertEqual(url_mock.call_count, 0)


class Signature(unittest.TestCase):
    """SHA256SUMS.sig: the key is the launcher's, a good signature passes, a changed SHA256SUMS or a missing swift fails, an unsigned release
    is checked against its checksums only. The fixture is nxkit 0.10.3's own SHA256SUMS and signature."""
    SUMS = (b'b33ea345b7fa87ff030fed96cadd2ba93aa45a4fb698f5a2627be1de6e232e2a  nxb-v0.10.3-macos-arm64.zip\n'
            b'39714b211b833e8ae52d5238023b95e849987dfbaaa34cb58a2c30b04978c49b  nxb-v0.10.3-macos-arm64/nxb\n'
            b'5d4951458aaaa209a886444294c513c935b4b113c19ebf3a9d0cf8f136d84356  nxb-v0.10.3-macos-arm64/nxkit-host\n'
            b'608f27fa32f5e72dd5832530375643db89593b8f95fc638a25a640ffa7045c60  nxb-v0.10.3-macos-arm64/MANIFEST.json\n')
    SIG = b'CLchW16dXzSRviRCR+jAgusqh2R0KZbaqFTYLNoSCfb5FoZN/nacOWushmH4onO3zRSUkFkpiJAPOEvSu7StBQ==\n'

    def test_the_key_is_the_launchers(self):
        self.assertEqual(nxbuild.public_key(), '9FKs7HGStVtytRbhJN38vwPyBmXjWs70Mn1hqKrug7M=')

    @unittest.skipUnless(nxbuild.shutil.which('swift'), 'needs swift (CryptoKit)')
    def test_a_good_signature_verifies_and_a_changed_file_does_not(self):
        with tempfile.TemporaryDirectory() as t:
            sums, sig = Path(t, 'SHA256SUMS'), Path(t, 'SHA256SUMS.sig')
            sums.write_bytes(self.SUMS); sig.write_bytes(self.SIG)
            self.assertTrue(nxbuild.verify_signature(sums, sig))
            sums.write_bytes(self.SUMS.replace(b'b33e', b'b33f'))
            self.assertFalse(nxbuild.verify_signature(sums, sig))

    def test_signed_sums_fails_on_a_bad_signature_and_accepts_an_unsigned_release(self):
        err404 = urllib.error.HTTPError('https://x/SHA256SUMS.sig', 404, 'Not Found', {}, None)
        def fake_download(url, dest=None, **_):
            if url.endswith('.sig'):
                if unsigned: raise err404
                Path(dest).write_bytes(self.SIG)
                return self.SIG
            Path(dest).write_bytes(self.SUMS)
            return self.SUMS
        with tempfile.TemporaryDirectory() as t, mock.patch.object(nxbuild, 'download', side_effect=fake_download):
            unsigned = True
            self.assertEqual(nxbuild.signed_sums('https://x', Path(t)), self.SUMS.decode())
            unsigned = False
            with mock.patch.object(nxbuild, 'verify_signature', return_value=False):
                with self.assertRaises(SystemExit): nxbuild.signed_sums('https://x', Path(t))
            with mock.patch.object(nxbuild, 'verify_signature', return_value=True):
                self.assertEqual(nxbuild.signed_sums('https://x', Path(t)), self.SUMS.decode())
            with mock.patch.object(nxbuild.shutil, 'which', return_value=None):
                with self.assertRaises(SystemExit): nxbuild.verify_signature(Path(t, 'SHA256SUMS'), Path(t, 'SHA256SUMS.sig'))


if __name__ == '__main__':
    unittest.main()
