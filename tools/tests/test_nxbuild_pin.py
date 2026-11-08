"""frontend/tools/nxbuild.py and frontend/nxbuild.pin (LNPANDY/NX2Apple#749): the pin's form, the digest check before anything is unpacked, and a
release's SHA256SUMS. No network: zips are made in a temporary folder."""
import hashlib, importlib.util, tempfile, unittest, zipfile
from pathlib import Path

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

    def test_the_data_folders_of_the_release_go_beside_nxb(self):
        with tempfile.TemporaryDirectory() as t:
            z = self.zip(t, {'nxb-v0.5.1/nxb': b'binary', 'nxb-v0.5.1/rewrite-rules/a.toml': b'rule', 'nxb-v0.5.1/own-front/x/y.tsv': b'v',
                             'nxb-v0.5.1/README': b'r', 'nxb-v0.5.1/other/z': b'z', 'nxb-v0.5.1/rewrite-rules/../../evil': b'e'})
            out = nxbuild.unpack(z, hashlib.sha256(z.read_bytes()).hexdigest(), Path(t, 'res/nxbuild'))
            self.assertEqual(Path(t, 'res/nxbuild/rewrite-rules/a.toml').read_bytes(), b'rule')
            self.assertEqual(Path(t, 'res/nxbuild/own-front/x/y.tsv').read_bytes(), b'v')
            self.assertFalse(Path(t, 'res/nxbuild/other').exists() or Path(t, 'res/nxbuild/README').exists())
            self.assertFalse(Path(t, 'res/evil').exists() or Path(t, 'evil').exists())
            self.assertEqual(out.read_bytes(), b'binary')

    def test_the_digest_is_checked_before_unpacking(self):
        with tempfile.TemporaryDirectory() as t:
            z = self.zip(t, {'nxb-v0.1.0/nxb': b'binary', 'nxb-v0.1.0/README': b'r'})
            good = hashlib.sha256(z.read_bytes()).hexdigest()
            out = nxbuild.unpack(z, good, Path(t, 'res/nxbuild'))
            self.assertEqual(out.read_bytes(), b'binary')
            self.assertTrue(out.stat().st_mode & 0o111)
            z = self.zip(t, {'nxb': b'other'})
            with self.assertRaises(SystemExit) as e: nxbuild.unpack(z, good, Path(t, 'res2'))
            self.assertIn('not bundled', str(e.exception))
            self.assertFalse(z.exists(), 'a zip whose digest differs is deleted')
            self.assertFalse(Path(t, 'res2').exists(), 'nothing is unpacked')

    def test_sha256sums(self):
        text = f'{"a" * 64}  nxb-v0.1.0-macos-arm64.zip\n{"B" * 64} *other.zip\n'
        self.assertEqual(nxbuild.sums_digest(text, 'nxb-v0.1.0-macos-arm64.zip'), 'a' * 64)
        self.assertEqual(nxbuild.sums_digest(text, 'other.zip'), 'b' * 64)
        with self.assertRaises(SystemExit): nxbuild.sums_digest(text, 'missing.zip')


if __name__ == '__main__':
    unittest.main()
