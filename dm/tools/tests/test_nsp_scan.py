"""NSP script: scan_nsps takes a file as a game package only when its header is one nx_extract opens (PFS0 at 0, or an XCI's HEAD at 0x100), whatever its name says: title_of falls
back to the name's [title ID], so a tagged file that is not a package would count as one. No game files or keys needed."""
import importlib.util
from pathlib import Path
import shutil
import struct
import tempfile
import unittest
from unittest import mock

REPO = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('build_ipa_from_nsp', REPO / 'scripts/build_ipa_from_nsp.py')
if spec is None or spec.loader is None: raise ImportError('scripts/build_ipa_from_nsp.py')
nsp = importlib.util.module_from_spec(spec); spec.loader.exec_module(nsp)

APP = 0x010020D01AD24000


def pfs0(path, names):   # a PFS0 holding empty files with these names (enough for title_of)
    strs = b''.join(n.encode() + b'\0' for n in names); ent, o = b'', 0
    for n in names: ent += struct.pack('<QQII', 0, 0, o, 0); o += len(n) + 1
    path.write_bytes(b'PFS0' + struct.pack('<III', len(names), len(strs), 0) + ent + strs)


class Scan(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp()); self.addCleanup(shutil.rmtree, self.tmp)
        self.said = []
        cm = mock.patch.object(nsp, 'say', self.said.append); cm.__enter__(); self.addCleanup(cm.__exit__, None, None, None)

    def test_only_packages_count(self):
        base = self.tmp / f'Game [{APP:016X}][v0].xci'; base.write_bytes(bytes(0x100) + b'HEAD' + bytes(0x100))   # a cartridge dump: no ticket, the name's tag
        upd = self.tmp / f'Update [{APP | 0x800:016X}].nsp'; pfs0(upd, [])
        page = self.tmp / f'Update [{APP | 0x800:016X}] (1).nsp'; page.write_bytes(b'<!DOCTYPE html><title>404</title>')   # a failed download saved under the game's name
        short = self.tmp / f'DLC [{APP + 0x1001:016X}].xci'; short.write_bytes(b'\0' * 0x80)   # cut off before the card header
        app, fam = nsp.scan_nsps(self.tmp)
        self.assertEqual(app, APP)
        self.assertEqual(fam['base'], base)
        self.assertEqual([p for _, p in fam['updates']], [upd])   # with the page the untagged update was one of two and left out
        self.assertEqual(fam['dlc'], [])
        self.assertEqual(sorted(m.split(':')[0] for m in self.said), sorted(f'skipping {p.name}' for p in (page, short)))

    def test_appledouble_skipped_quietly(self):
        base = self.tmp / f'Game [{APP:016X}][v0].nsp'; pfs0(base, [f'{APP:016x}0000000000000011.tik'])
        (self.tmp / ('._' + base.name)).write_bytes(b'\0\x05\x16\x07' + b'\0' * 4092)
        self.assertEqual(nsp.scan_nsps(self.tmp)[1]['base'], base)
        self.assertEqual(self.said, [])


class TitleFromPackage(unittest.TestCase):
    """A package with neither a ticket nor a [title ID] in its name (a standard-crypto dump, a repack: LNPANDY/NX2Apple#177) is asked for its title ID. The reader itself (nx_extract --title,
    the meta NCA's header under the keys' header_key) needs real keys and is not run here: its boundary is stubbed and its command line and output are checked"""
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp()); self.addCleanup(shutil.rmtree, self.tmp)
        cm = mock.patch.object(nsp, 'say', lambda *_: None); cm.__enter__(); self.addCleanup(cm.__exit__, None, None, None)

    def test_precedence_and_cost(self):
        def never(_): raise AssertionError('the package was read although a ticket or a tag names it')
        tik = self.tmp / 'a.nsp'; pfs0(tik, [f'{APP:016x}0000000000000011.tik'])
        self.assertEqual(nsp.title_of(tik, never), APP)
        tag = self.tmp / f'Game [{APP | 0x800:016X}].nsp'; pfs0(tag, ['x.nca'])
        self.assertEqual(nsp.title_of(tag, never), APP | 0x800)
        bare = self.tmp / 'Game.nsp'; pfs0(bare, ['x.nca'])
        self.assertIsNone(nsp.title_of(bare))
        self.assertEqual(nsp.title_of(bare, lambda p: APP | 0x800 if p == bare else None), APP | 0x800)

    def test_scan_uses_the_reader_for_untagged_ticketless_packages(self):
        ids = {}
        for name, tid in (('base.nsp', APP), ('upd.nsp', APP | 0x800), ('dlc.nsp', APP + 0x1001)):
            pfs0(self.tmp / name, ['x.cnmt.nca']); ids[self.tmp / name] = tid
        app, fam = nsp.scan_nsps(self.tmp, ids.get)
        self.assertEqual((app, fam['base'], [p for _, p in fam['updates']], [t for t, _, _ in fam['dlc']]), (APP, self.tmp / 'base.nsp', [self.tmp / 'upd.nsp'], [APP + 0x1001]))

    def test_scan_still_stops_when_nothing_reads(self):
        pfs0(self.tmp / 'a.nsp', ['x.nca']); pfs0(self.tmp / 'b.nsp', ['y.nca'])
        for reader in (None, lambda p: None):
            with self.assertRaisesRegex(nsp.BuildError, 'no NSP with a readable title ID'): nsp.scan_nsps(self.tmp, reader)

    def test_reader_runs_nx_extract_title_mode(self):
        keys, pkg, calls = self.tmp / 'prod.keys', self.tmp / 'a.nsp', []
        def fake_run(cmd, log, env=None, cwd=None, on_line=None, ok=()):
            calls.append((cmd, ok)); log.parent.mkdir(parents=True, exist_ok=True)
            log.write_text(self.out)
            if self.broken: raise nsp.BuildError('nx_extract exit code 1')
        with mock.patch.object(nsp, 'build_nx_extract', lambda *a: 'nx'), mock.patch.object(nsp, 'run', fake_run), nsp.package_title_reader(REPO, keys, {}) as read:
            self.out, self.broken = f'title {APP:016x}\n', False
            self.assertEqual(read(pkg), APP)
            self.assertEqual(calls[0][0], ['nx', keys, '--title', pkg]); self.assertIn(5, calls[0][1])
            self.out = '[RED] no meta NCA in a.nsp\n'
            self.assertIsNone(read(pkg))
            self.out, self.broken = '', True
            self.assertIsNone(read(pkg))

    def test_reader_without_dotnet_says_what_to_do(self):
        with mock.patch.object(nsp.shutil, 'which', lambda *a, **k: None), nsp.package_title_reader(REPO, self.tmp / 'prod.keys', {}) as read:
            with self.assertRaisesRegex(nsp.BuildError, r'needs dotnet .* add the title ID to the name'): read(self.tmp / 'Game.nsp')


if __name__ == '__main__':
    unittest.main()
