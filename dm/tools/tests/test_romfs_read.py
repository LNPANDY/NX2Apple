"""Direct image extraction, bounded archive reads and the build tools' image inputs."""
import hashlib
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

REPO = Path(__file__).resolve().parents[3]
sys.path[:0] = [str(REPO / 'dm/tools'), str(REPO / 'dm/gfx/tools')]
import romfs
import romfs_image


class ReadImage(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.src = self.root / 'files'; self.src.mkdir()
        (self.src / 'data/empty').mkdir(parents=True)
        (self.src / 'a').write_bytes(b'prefix!')
        self.data = b'\x03\x02\x23\x07' + b'ABC\0' * 20000
        (self.src / 'data/archive').write_bytes(self.data)
        (self.src / 'data/zero').touch()
        (self.src / 'data/test.vert').write_text('#version 320 es\nvoid main() {}')
        with zipfile.ZipFile(self.src / 'data/game.zip', 'w') as z: z.writestr('member', b'archive member')
        self.image = self.root / 'RomFS.img'; romfs_image.pack(self.src, self.image)
        self.virtual = romfs.Path(self.image)

    def test_metadata_paths_and_normal_output_paths(self):
        self.assertTrue(self.virtual.is_dir()); self.assertFalse(self.virtual.is_file())
        self.assertEqual((self.virtual / 'data/archive').read_bytes(), self.data)
        self.assertEqual((self.virtual / 'data/test.vert').read_text(), '#version 320 es\nvoid main() {}')
        actual = sorted((p.relative_to(self.src).as_posix(), p.is_dir(), p.stat().st_size if p.is_file() else 0) for p in self.src.rglob('*'))
        virtual = sorted((p.relative_to(self.virtual).as_posix(), p.is_dir(), p.stat().st_size if p.is_file() else 0) for p in self.virtual.rglob('*'))
        self.assertEqual(virtual, actual)
        self.assertFalse((self.virtual / 'missing').exists())
        with self.assertRaises(FileNotFoundError): (self.virtual / 'missing').read_bytes()
        with self.assertRaises(OSError): (self.virtual / 'data/archive').open('wb')
        with romfs.open(self.root / 'output', 'wb') as f: f.write(b'normal output')
        self.assertEqual((self.root / 'output').read_bytes(), b'normal output')

    def test_seek_read_and_mmap_cannot_cross_an_entry_boundary(self):
        with romfs.open(self.virtual / 'data/archive', 'rb') as f:
            f.seek(-5, 2); self.assertEqual(f.read(100), self.data[-5:])
            f.seek(len(self.data) + 10); self.assertEqual(f.read(), b'')
            with romfs.mmap.mmap(f.fileno(), 0, access=romfs.mmap.ACCESS_READ) as m:
                self.assertEqual(len(m), len(self.data)); self.assertEqual(m[:], self.data)
                self.assertEqual(struct.unpack_from('<I', m)[0], 0x07230203)
                found = re.search(b'ABC', m); assert found is not None; self.assertEqual(found.start(), 4)
                self.assertEqual(hashlib.sha256(m).digest(), hashlib.sha256(self.data).digest())
                self.assertEqual(m.find(b'ABC'), 4); self.assertEqual(m.rfind(b'ABC'), len(self.data) - 4)
                self.assertEqual(m.find(b'archive member'), -1)
        with romfs.open(self.virtual / 'data/zero', 'rb') as f: self.assertEqual(f.read(), b'')
        with romfs.open(self.virtual / 'data/game.zip', 'rb') as f, zipfile.ZipFile(f) as z:
            self.assertEqual(z.read('member'), b'archive member')

    def test_build_scanners_discover_the_same_inputs_from_image_and_folder(self):
        import gl_shaders
        import vk_shaders
        with patch.dict(os.environ, DM_GAME='010020D01AD24000'):
            import shader_split
        self.assertEqual(list(gl_shaders.sources([str(self.virtual)])), list(gl_shaders.sources([str(self.src)])))
        self.assertEqual([Path(p).relative_to(self.virtual) for p in vk_shaders.spirv_files(str(self.virtual))],
                         [Path(p).relative_to(self.src) for p in vk_shaders.spirv_files(str(self.src))])
        jobs, paths = shader_split.zip_jobs([(str(self.virtual / 'data/game.zip'), 'data/game.zip')])
        self.assertEqual(paths, {str(self.virtual / 'data/game.zip')})
        self.assertEqual(jobs[0][2][1], ('member',))
        self.assertEqual(shader_split.scan_file(jobs[0])[1], {})
        # Image replacement must invalidate the process's cached index.
        (self.src / 'new').write_text('new entry'); romfs_image.pack(self.src, self.image)
        self.assertEqual((self.virtual / 'new').read_text(), 'new entry')

    @unittest.skipUnless(shutil.which('zstd'), 'zstd command required')
    def test_zstd_file_inside_an_image(self):
        # Mario Wonder's .zs files: the zstd command cannot open a path inside the image, so unzs feeds it the bytes.
        with patch.dict(os.environ, DM_GAME='010020D01AD24000'):
            import shader_split
        (self.src / 'data/table.byml.zs').write_bytes(subprocess.run(['zstd', '-c', '-q'], input=self.data, capture_output=True, check=True).stdout)
        romfs_image.pack(self.src, self.image)
        self.assertEqual(shader_split.unzs(str(self.virtual / 'data/table.byml.zs')), self.data)

    def test_ipa_packer_keeps_image_as_one_file_and_reuses_it(self):
        out = self.root / 'game.ipa'
        cmd = [sys.executable, str(REPO / 'dm/ios/tools/pack_ipa.py'), str(out), f'Payload/Game.app/romfs.img={self.image}']
        for _ in range(2):
            subprocess.run(cmd, check=True, capture_output=True)
            with zipfile.ZipFile(out) as z:
                self.assertEqual(z.namelist(), ['Payload/', 'Payload/Game.app/', 'Payload/Game.app/romfs.img'])
                self.assertEqual(z.read('Payload/Game.app/romfs.img'), self.image.read_bytes())


@unittest.skipUnless(shutil.which('dotnet'), '.NET SDK required')
class ExtractImage(unittest.TestCase):
    def test_extractor_streams_populated_and_empty_filesystems(self):
        # Exercise the actual LibHac writer without an NSP or keys, including empty
        # directories and a file larger than its streaming buffer.
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); src = root / 'files'; (src / 'data/empty').mkdir(parents=True)
            data = b'\x00\x01\x02\xff' * (2 << 20)
            (src / 'data/large').write_bytes(data); (src / 'zero').touch()
            project = root / 'fixture.csproj'
            project.write_text('<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><OutputType>Exe</OutputType><TargetFramework>net10.0</TargetFramework>'
                               '<StartupObject>Fixture</StartupObject><AllowUnsafeBlocks>true</AllowUnsafeBlocks></PropertyGroup><ItemGroup>'
                               f'<Compile Include="{REPO}/dm/tools/nx_extract/Program.cs" Link="Extractor.cs" />'
                               '<PackageReference Include="LibHac" Version="0.19.0" /></ItemGroup></Project>')
            (root / 'Fixture.cs').write_text('using System.Reflection; using LibHac.FsSystem; class Fixture { static void Main(string[] a) {'
                'var write = typeof(P).GetMethod("WriteImage", BindingFlags.NonPublic | BindingFlags.Static);'
                'using var fs = new LocalFileSystem(a[0]); write.Invoke(null, new object[]{fs, a[1]});'
                'write.Invoke(null, new object[]{null, a[2]}); }}')
            image, empty = root / 'RomFS.img', root / 'empty.img'
            result = subprocess.run(['dotnet', 'run', '--project', str(project), '--', str(src), str(image), str(empty)], capture_output=True, text=True, timeout=120)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            shutil.rmtree(src)
            virtual = romfs.Path(image)
            self.assertEqual((virtual / 'data/large').read_bytes(), data)
            self.assertTrue((virtual / 'data/empty').is_dir()); self.assertEqual((virtual / 'zero').read_bytes(), b'')
            self.assertEqual(list(romfs.Path(empty).iterdir()), [])
            self.assertFalse((root / 'RomFS').exists()); self.assertFalse(Path(str(image) + '.part').exists())


if __name__ == '__main__': unittest.main()
