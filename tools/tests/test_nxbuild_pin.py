"""frontend/tools/nxbuild.py and frontend/nxbuild.pin (LNPANDY/NX2Apple#749): the pin's form, the digest check before anything is unpacked, and a
release's SHA256SUMS. No network: zips are made in a temporary folder."""
import hashlib, importlib.util, io, tempfile, unittest, urllib.error, zipfile
from unittest import mock
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



class RewriterPins(unittest.TestCase):
    """nxbuild.py check (#942): the dm/tools files the pinned nxb's rewriter pins, against an engine's. No network: rewrite.rs is a string here."""
    RUST = 'const PINNED: [(&str, &str); 2] = [\n    (\n        "patch_nso.py",\n        "%s",\n    ),\n    ("nso.py", "%s"),\n];\n\nconst SOURCES: usize = 1;\n'

    def test_the_table_is_read_in_its_order(self):
        self.assertEqual(nxbuild.pins(self.RUST % ('a' * 64, 'b' * 64)), [('patch_nso.py', 'a' * 64), ('nso.py', 'b' * 64)])
        with self.assertRaises(SystemExit): nxbuild.pins('fn main() {}')
        with self.assertRaises(SystemExit): nxbuild.pins((self.RUST % ('a' * 64, 'b' * 64)).replace('; 2]', '; 3]'))

    def test_a_changed_or_missing_file_is_named(self):
        with tempfile.TemporaryDirectory() as t:
            tools = Path(t)
            (tools / 'patch_nso.py').write_bytes(b'new')
            (tools / 'nso.py').write_bytes(b'same')
            same = hashlib.sha256(b'same').hexdigest()
            pinned = nxbuild.pins(self.RUST % ('0' * 64, same))
            self.assertEqual(nxbuild.mismatches(pinned, tools), [('patch_nso.py', '0' * 64, hashlib.sha256(b'new').hexdigest())])
            (tools / 'nso.py').unlink()
            self.assertEqual([m[0] for m in nxbuild.mismatches(pinned, tools)], ['patch_nso.py', 'nso.py'])
            self.assertIsNone(nxbuild.mismatches(pinned, tools)[1][2])

    def test_the_source_is_the_release_tag(self):
        pin = {'version': '0.9.1', 'sha256': None, 'url': 'https://github.com/v0lumehi/nxkit/releases/download/v0.9.1/nxb-v0.9.1-macos-arm64.zip'}
        self.assertEqual(nxbuild.rewrite_source(pin), 'https://raw.githubusercontent.com/v0lumehi/nxkit/v0.9.1/crates/nxb-build/src/rewrite.rs')
        with self.assertRaises(SystemExit): nxbuild.rewrite_source(dict(pin, url='https://example.com/nxb.zip'))



class Download(unittest.TestCase):
    """A release download that answers a server error is tried again; a 404 is not. No network: urlopen is replaced."""
    def opener(self, answers):
        calls = []
        def urlopen(url, timeout=None):
            calls.append(url); a = answers.pop(0)
            if isinstance(a, Exception): raise a
            return io.BytesIO(a)
        return urlopen, calls

    def error(self, code): return urllib.error.HTTPError('u', code, 'x', None, None)

    def test_a_504_is_tried_again(self):
        urlopen, calls = self.opener([self.error(504), urllib.error.URLError('reset'), b'zip'])
        with mock.patch.object(nxbuild.urllib.request, 'urlopen', urlopen), mock.patch.object(nxbuild.time, 'sleep'):
            self.assertEqual(nxbuild.download('u'), b'zip')
        self.assertEqual(len(calls), 3)

    def test_a_404_and_the_last_try_raise(self):
        for answers, n in (([self.error(404)], 1), ([self.error(503)] * 5, 5)):
            urlopen, calls = self.opener(list(answers))
            with mock.patch.object(nxbuild.urllib.request, 'urlopen', urlopen), mock.patch.object(nxbuild.time, 'sleep'):
                with self.assertRaises(urllib.error.HTTPError): nxbuild.download('u')
            self.assertEqual(len(calls), n)


if __name__ == '__main__':
    unittest.main()
