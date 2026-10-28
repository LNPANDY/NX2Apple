"""Run the actual iOS RomFS locator on macOS/Foundation with private Documents/temp folders (no device or game files)."""
import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('romfs_image', REPO / 'dm/tools/romfs_image.py')
assert spec is not None and spec.loader is not None
image = importlib.util.module_from_spec(spec); spec.loader.exec_module(image)
import shutil


@unittest.skipUnless(sys.platform == 'darwin', 'Foundation required')
class Startup(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tools = tempfile.TemporaryDirectory(); cls.addClassCleanup(cls.tools.cleanup)
        root = Path(cls.tools.name)
        main = (REPO / 'dm/ios/Sources/main.m').read_text()
        locator = main[main.index('static int romfs_image_complete'):main.index('// Boot prerequisites')]
        source = root / 'locator.m'
        source.write_text('#import <Foundation/Foundation.h>\n#include <stdio.h>\n#include "romfs_image.h"\n#include "romfs_identity.h"\n'
                          'static NSString *fixture_doc, *fixture_tmp, *fixture_bundle;\n#define DM_GAME_ROMFS_MARKER "marker"\n'
                          'typedef struct { const char *id, *romfs_marker; } fixture_profile;   /* the fork reads both from the runtime profile */\nstatic const fixture_profile *dm_profile(void) { static const fixture_profile p = {"0100000000000000", "marker"}; return &p; }\n'
                          '@interface FixtureBundle : NSObject\n+ (instancetype)mainBundle;\n- (NSString *)resourcePath;\n@end\n'
                          '@implementation FixtureBundle\n+ (instancetype)mainBundle { return [self new]; }\n'
                          '- (NSString *)resourcePath { return fixture_bundle; }\n@end\n#define NSBundle FixtureBundle\n'
                          '#define NSSearchPathForDirectoriesInDomains(a,b,c) @[fixture_doc]\n#define NSTemporaryDirectory() fixture_tmp\n'
                          # The picked-location bookmark (DataBookmark.m): the fixture answers it from a
                          # variable, so a test can put the player's choice anywhere on disk.
                          'static NSString *fixture_picked;\n'
                          'NSString *dm_picked_data_path(BOOL *stale) { if (stale) *stale = NO; return fixture_picked; }\n' + locator +
                          '\nint main(int argc, char **argv) { @autoreleasepool { if (argc < 3) return 2;\n'
                          'fixture_doc = @(argv[1]); fixture_tmp = @(argv[2]); fixture_bundle = argc > 3 ? @(argv[3]) : @"/nonexistent-fixture";\n'
                          'if (argc > 4) fixture_picked = @(argv[4]);   // the location the player picked, when a test sets one\n'
                          'NSString *p = romfs_locate();\n'
                          'if (!p) return 1; puts(p.fileSystemRepresentation); return 0; }}\n')
        cls.locator = root / 'locator'
        subprocess.run(['clang', '-fobjc-arc', '-Wall', '-Werror', '-I', str(REPO / 'dm/host'),
                        str(source), '-framework', 'Foundation', '-o', str(cls.locator)], check=True)

    def test_invalid_image_preserves_working_folder_and_valid_image_replaces_it(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); doc = root / 'Documents'; folder = doc / 'romfs'; folder.mkdir(parents=True)
            (folder / 'marker').write_text('working files')
            tmp = root / 'temp'; tmp.mkdir()
            img = doc / 'romfs.img'
            img.write_bytes(image.HEAD.pack(image.MAGIC, 32, 0, 0))
            result = subprocess.run([str(self.locator), str(doc), str(tmp)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), str(folder))
            self.assertTrue((folder / 'marker').is_file()); self.assertEqual(list(tmp.iterdir()), [])
            image.pack(folder, img)
            result = subprocess.run([str(self.locator), str(doc), str(tmp)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), str(img)); self.assertFalse(folder.exists())

    def test_bundled_image_is_used_in_place_and_documents_can_override_it(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); doc = root / 'Documents'; doc.mkdir()
            tmp = root / 'temp'; tmp.mkdir(); bundle = root / 'App'; bundle.mkdir()
            source = root / 'source'; source.mkdir(); (source / 'marker').write_text('resource')
            image.pack(source, bundle / 'romfs.img')
            def locate():
                result = subprocess.run([str(self.locator), str(doc), str(tmp), str(bundle)], capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr); return result.stdout.strip()
            self.assertEqual(locate(), str(bundle / 'romfs.img'))
            self.assertEqual(list(doc.iterdir()), []); self.assertFalse((bundle / 'romfs').exists())
            folder = doc / 'romfs'; folder.mkdir(); (folder / 'marker').touch()
            self.assertEqual(locate(), str(folder))
            image.pack(source, doc / 'romfs.img'); self.assertEqual(locate(), str(doc / 'romfs.img'))

    def test_slim_build_uses_only_the_image_it_was_built_for(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); doc = root / 'Documents'; doc.mkdir()
            tmp = root / 'temp'; tmp.mkdir(); bundle = root / 'App'; bundle.mkdir()
            wanted, other = root / 'wanted', root / 'other'
            for folder, name in ((wanted, 'a'), (other, 'b')): folder.mkdir(); (folder / 'marker').write_text('x'); (folder / name).write_text(name * 100)
            image.pack(wanted, root / 'wanted.img'); image.pack(other, root / 'other.img')
            (bundle / 'romfs.id').write_text(image.identity(root / 'wanted.img', 'T', '1.0', 'v0') + '\n')
            def locate():
                return subprocess.run([str(self.locator), str(doc), str(tmp), str(bundle)], capture_output=True, text=True)
            self.assertEqual(locate().returncode, 1)   # slim build, no image yet
            shutil.copy(root / 'other.img', doc / 'romfs.img')
            result = locate(); self.assertEqual(result.returncode, 1, result.stdout)   # another version: never used
            self.assertIn('[RED]', result.stderr)
            folder = doc / 'romfs'; folder.mkdir(); (folder / 'marker').touch()
            result = locate()
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), str(folder))   # a rejected image preserves the existing folder fallback
            self.assertIn('[RED]', result.stderr)
            self.assertTrue(folder.is_dir()); self.assertEqual(list(tmp.iterdir()), [])
            shutil.copy(root / 'wanted.img', doc / 'romfs.img')
            result = locate(); self.assertEqual(result.returncode, 0, result.stderr); self.assertEqual(result.stdout.strip(), str(doc / 'romfs.img'))
            (bundle / 'romfs.id').unlink()   # the default build has no identity: any complete image
            shutil.copy(root / 'other.img', doc / 'romfs.img')
            self.assertEqual(locate().stdout.strip(), str(doc / 'romfs.img'))

    def test_the_location_the_player_picked_wins_over_everything(self):
        """The Files-app pick (DataBookmark): an image, a folder holding one, or a plain tree."""
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); doc = root / 'Documents'; doc.mkdir()
            tmp = root / 'temp'; tmp.mkdir(); bundle = root / 'App'; bundle.mkdir()
            source = root / 'source'; source.mkdir(); (source / 'marker').write_text('resource')
            image.pack(source, bundle / 'romfs.img')
            # something the app would otherwise use, so "wins" means something
            image.pack(source, doc / 'romfs.img')
            external = root / 'external'; external.mkdir()

            def locate(picked=None):
                argv = [str(self.locator), str(doc), str(tmp), str(bundle)] + ([str(picked)] if picked else [])
                result = subprocess.run(argv, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                return result.stdout.strip()

            # 1. the picked path IS the image
            image.pack(source, external / 'mine.img')
            self.assertEqual(locate(external / 'mine.img'), str(external / 'mine.img'))
            # 2. the picked path is a folder holding romfs.img
            image.pack(source, external / 'romfs.img')
            self.assertEqual(locate(external), str(external / 'romfs.img'))
            # 3. the picked path is a plain RomFS tree
            (external / 'romfs.img').unlink(); (external / 'marker').write_text('resource')
            self.assertEqual(locate(external), str(external))
            # 4. a picked path holding none of this game's data falls through to the app's own copy
            empty = root / 'empty'; empty.mkdir()
            self.assertEqual(locate(empty), str(doc / 'romfs.img'))


if __name__ == '__main__': unittest.main()
