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


if __name__ == '__main__':
    unittest.main()
