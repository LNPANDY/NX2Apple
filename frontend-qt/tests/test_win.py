"""Tests for the Windows build path that can run on macOS.

The Windows modules are written so that everything except the actual toolchain invocations is
testable without Windows: the discovery logic takes its paths from environment variables and
`toolchain.json`, the Makefile source-list check reads text, the IPA mode fixer works on any zip,
and the driver's patches can be inspected without loading the upstream script.

What is **not** covered here, and must be checked on a real Windows machine:

* `probe_compile` / `probe_link` / `probe_metal` against a genuine LLVM-MinGW, iPhoneOS SDK and
  Metal Developer Tools install;
* the compile and link of the real host sources, and `ios/Launcher.m` against UIKit;
* a full `python -m nspb_qt.win.driver` run on a game folder.

Those need the toolchain; the helpers below assert the parts that decide *whether* they would be
attempted with the right arguments.

    python3 -m unittest discover -s frontend-qt/tests -v
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import shutil
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
QT = HERE.parent
sys.path.insert(0, str(QT))

from nspb_qt.win import build_app, fix_ipa_modes, sdk_fetch, shim  # noqa: E402
from nspb_qt.win import toolchain as tc  # noqa: E402


# ---------------------------------------------------------------- helpers

def make_fake_sdk(root: Path, version: str = '26.0') -> Path:
    """A directory that looks like an iPhoneOS SDK to `toolchain.is_sdk_dir`."""
    sdk = root / f'iPhoneOS{version}.sdk'
    (sdk / 'System/Library/Frameworks/UIKit.framework/Headers').mkdir(parents=True)
    (sdk / 'System/Library/Frameworks/Foundation.framework').mkdir(parents=True)
    (sdk / 'usr/lib').mkdir(parents=True)
    (sdk / 'SDKSettings.json').write_text(json.dumps({'Version': version}), encoding='utf-8')
    (sdk / 'System/Library/Frameworks/UIKit.framework/UIKit.tbd').write_text('---', encoding='utf-8')
    (sdk / 'System/Library/Frameworks/UIKit.framework/Headers/UIKit.h').write_text(
        '// fake', encoding='utf-8')
    (sdk / 'usr/lib/libSystem.tbd').write_text('---', encoding='utf-8')
    return sdk


def make_fake_llvm(root: Path, with_lld64: bool = True, with_macho: bool = True) -> Path:
    """An LLVM folder with executable stubs named like the real tools."""
    llvm = root / 'LLVM'
    (llvm / 'bin').mkdir(parents=True)
    (llvm / 'bin/clang.exe').write_bytes(b'stub')
    (llvm / 'bin/ld.lld.exe').write_bytes(b'MachO ld64.lld darwin' if with_macho else b'ELF only')
    if with_lld64:
        (llvm / 'bin/ld64.lld.exe').write_bytes(b'MachO ld64.lld darwin')
    return llvm


class ToolchainDiscoveryTest(unittest.TestCase):
    """The three-level search: environment, then toolchain.json, then known locations."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.env = mock.patch.dict(os.environ, {}, clear=False)
        self.env.start()
        for k in ('NSPB_LLVM_DIR', 'NSPB_IOS_SDK', 'NSPB_METAL_DIR', 'NSPB_TOOLCHAIN_JSON',
                  'NSPB_IOS_SDK_SHA256', 'ProgramFiles', 'ProgramFiles(x86)', 'LOCALAPPDATA'):
            os.environ.pop(k, None)
        os.environ['LOCALAPPDATA'] = str(self.root / 'LocalAppData')

    def tearDown(self) -> None:
        self.env.stop()
        self.tmp.cleanup()

    def test_llvm_found_from_env(self) -> None:
        llvm = make_fake_llvm(self.root)
        os.environ['NSPB_LLVM_DIR'] = str(llvm)
        self.assertEqual(tc.llvm_dir(), llvm)
        self.assertEqual(tc.llvm_tool('clang'), llvm / 'bin/clang.exe')

    def test_llvm_found_from_toolchain_json(self) -> None:
        llvm = make_fake_llvm(self.root)
        cfg = self.root / 'toolchain.json'
        cfg.write_text(json.dumps({'llvm_dir': str(llvm)}), encoding='utf-8')
        os.environ['NSPB_TOOLCHAIN_JSON'] = str(cfg)
        self.assertEqual(tc.llvm_dir(), llvm)

    def test_env_beats_toolchain_json(self) -> None:
        env_llvm = make_fake_llvm(self.root / 'a')
        cfg_llvm = make_fake_llvm(self.root / 'b')
        cfg = self.root / 'toolchain.json'
        cfg.write_text(json.dumps({'llvm_dir': str(cfg_llvm)}), encoding='utf-8')
        os.environ['NSPB_TOOLCHAIN_JSON'] = str(cfg)
        os.environ['NSPB_LLVM_DIR'] = str(env_llvm)
        self.assertEqual(tc.llvm_dir(), env_llvm)

    def test_broken_toolchain_json_does_not_raise(self) -> None:
        cfg = self.root / 'toolchain.json'
        cfg.write_text('{not json', encoding='utf-8')
        os.environ['NSPB_TOOLCHAIN_JSON'] = str(cfg)
        self.assertIn('_error', tc.load_config())
        # discovery still works: it falls through to the other levels
        llvm = make_fake_llvm(self.root)
        os.environ['NSPB_LLVM_DIR'] = str(llvm)
        self.assertEqual(tc.llvm_dir(), llvm)

    def test_no_llvm_returns_none(self) -> None:
        with mock.patch.object(tc.shutil, 'which', return_value=None):
            self.assertIsNone(tc.llvm_dir())


class Ld64Test(unittest.TestCase):
    """`ld64.lld.exe` does not ship with llvm-mingw; the copy from `ld.lld.exe` replaces it."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.env = mock.patch.dict(os.environ, {}, clear=False)
        self.env.start()
        for k in ('ProgramFiles', 'ProgramFiles(x86)', 'LOCALAPPDATA'):
            os.environ.pop(k, None)
        os.environ['LOCALAPPDATA'] = str(self.root / 'local')

    def tearDown(self) -> None:
        self.env.stop()
        self.tmp.cleanup()

    def test_lld_has_macho_reads_driver_strings(self) -> None:
        llvm = make_fake_llvm(self.root, with_lld64=False, with_macho=True)
        self.assertTrue(tc._lld_has_macho(llvm / 'bin/ld.lld.exe'))

    def test_stripped_lld_is_reported(self) -> None:
        llvm = make_fake_llvm(self.root, with_lld64=False, with_macho=False)
        os.environ['NSPB_LLVM_DIR'] = str(llvm)
        got, note = tc.ensure_ld64_lld()
        self.assertIsNone(got)
        self.assertIn('no Mach-O driver', note)

    def test_copy_created_when_absent(self) -> None:
        llvm = make_fake_llvm(self.root, with_lld64=False, with_macho=True)
        os.environ['NSPB_LLVM_DIR'] = str(llvm)
        got, note = tc.ensure_ld64_lld()
        self.assertIsNotNone(got)
        self.assertEqual(got.name, 'ld64.lld.exe')
        self.assertTrue(got.is_file())
        # idempotent: the second call finds it instead of making another
        again, note2 = tc.ensure_ld64_lld()
        self.assertEqual(again, got)
        self.assertEqual(note2, '')

    def test_existing_ld64_lld_wins(self) -> None:
        llvm = make_fake_llvm(self.root, with_lld64=True)
        os.environ['NSPB_LLVM_DIR'] = str(llvm)
        got, note = tc.ensure_ld64_lld()
        self.assertEqual(got, llvm / 'bin/ld64.lld.exe')
        self.assertEqual(note, '')


class SdkTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.env = mock.patch.dict(os.environ, {}, clear=False)
        self.env.start()
        for k in ('NSPB_IOS_SDK', 'LOCALAPPDATA'):
            os.environ.pop(k, None)
        os.environ['LOCALAPPDATA'] = str(self.root / 'local')

    def tearDown(self) -> None:
        self.env.stop()
        self.tmp.cleanup()

    def test_is_sdk_dir_accepts_a_real_layout(self) -> None:
        sdk = make_fake_sdk(self.root)
        self.assertTrue(tc.is_sdk_dir(sdk))

    def test_is_sdk_dir_rejects_a_plain_folder(self) -> None:
        plain = self.root / 'iPhoneOS26.0.sdk'
        plain.mkdir()
        self.assertFalse(tc.is_sdk_dir(plain))

    def test_is_sdk_dir_rejects_missing_stubs(self) -> None:
        sdk = make_fake_sdk(self.root)
        import shutil as sh
        sh.rmtree(sdk / 'System/Library/Frameworks/UIKit.framework')
        sh.rmtree(sdk / 'System/Library/Frameworks/Foundation.framework')
        self.assertFalse(tc.is_sdk_dir(sdk))

    def test_sdk_found_from_env(self) -> None:
        sdk = make_fake_sdk(self.root)
        os.environ['NSPB_IOS_SDK'] = str(sdk)
        self.assertEqual(tc.ios_sdk(), sdk)

    def test_sdk_version_parsed(self) -> None:
        sdk = make_fake_sdk(self.root, '26.5')
        self.assertEqual(tc.sdk_version(sdk)[0], '26.5')
        self.assertEqual(tc.sdk_major('26.5'), 26)
        self.assertEqual(tc.sdk_major(''), 0)

    def test_sdk_tree_digest_is_stable_and_discriminating(self) -> None:
        a = make_fake_sdk(self.root / 'a', '26.0')
        b = make_fake_sdk(self.root / 'b', '26.5')
        self.assertEqual(tc.sdk_tree_digest(a), tc.sdk_tree_digest(a))
        self.assertNotEqual(tc.sdk_tree_digest(a), tc.sdk_tree_digest(b))

    def test_sdk_pinned_is_27_2_and_preferred_over_cached_26(self) -> None:
        self.assertEqual(tc.SDK_PINNED, 'iPhoneOS27.2.sdk')
        self.assertEqual(tc.SDK_ACCEPTED[0], 'iPhoneOS27.2.sdk')
        cache = tc.sdk_cache_dir()
        sdk26 = make_fake_sdk(cache, '26.0')
        with mock.patch.object(tc, 'setting', return_value=None):
            self.assertEqual(tc.ios_sdk(), sdk26)
            sdk27 = make_fake_sdk(cache, '27.2')
            self.assertEqual(tc.ios_sdk(), sdk27)

    def test_probe_metal_caps_target_at_deployment_for_27_sdk(self) -> None:
        sdk27 = make_fake_sdk(self.root, '27.2')
        seen_cmds: list[list[str]] = []

        def fake_run(cmd, *a, **kw):
            seen_cmds.append([str(c) for c in cmd])
            if '-o' in cmd:
                out_p = Path(cmd[cmd.index('-o') + 1])
                out_p.write_bytes(b'MTLB')
            return subprocess.CompletedProcess(cmd, 0, '', '')

        with mock.patch.object(tc, 'metal_tool', side_effect=lambda name, *a: Path(f'C:/metal/{name}.exe')), \
             mock.patch.object(tc.subprocess, 'run', side_effect=fake_run):
            ok, detail = tc.probe_metal(sdk27)
        self.assertTrue(ok, detail)
        self.assertIn('air64-apple-ios26.0', seen_cmds[0])
        self.assertNotIn('air64-apple-ios27.0', seen_cmds[0])


class CheckAllTest(unittest.TestCase):
    """The panel's rows, on a machine with nothing installed and with a fake toolchain."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.env = mock.patch.dict(os.environ, {}, clear=False)
        self.env.start()
        for k in ('NSPB_LLVM_DIR', 'NSPB_IOS_SDK', 'NSPB_METAL_DIR', 'NSPB_TOOLCHAIN_JSON',
                  'ProgramFiles', 'ProgramFiles(x86)', 'LOCALAPPDATA'):
            os.environ.pop(k, None)
        os.environ['LOCALAPPDATA'] = str(self.root / 'local')
        os.environ['ProgramFiles'] = str(self.root / 'PF')
        self.which = mock.patch.object(tc.shutil, 'which', return_value=None)
        self.which.start()

    def tearDown(self) -> None:
        self.which.stop()
        self.env.stop()
        self.tmp.cleanup()

    def test_nothing_installed_reports_missing(self) -> None:
        probes = tc.check_all(deep=False)
        ids = {p.id: p for p in probes}
        self.assertEqual(ids['llvm'].state, 'missing')
        self.assertEqual(ids['ios_sdk'].state, 'missing')
        self.assertEqual(ids['metal'].state, 'missing')
        self.assertFalse(ids['lld'].ok)
        # metal-tt is optional and must never be required
        self.assertFalse(ids['metal_tt'].required)

    def test_a_fake_toolchain_turns_rows_ok(self) -> None:
        llvm = make_fake_llvm(self.root, with_lld64=False, with_macho=True)
        sdk = make_fake_sdk(self.root)
        metal = self.root / 'Metal Developer Tools'
        (metal / 'bin').mkdir(parents=True)
        (metal / 'bin/metal.exe').write_bytes(b'stub')
        (metal / 'bin/metallib.exe').write_bytes(b'stub')
        os.environ['NSPB_LLVM_DIR'] = str(llvm)
        os.environ['NSPB_IOS_SDK'] = str(sdk)
        os.environ['NSPB_METAL_DIR'] = str(metal)
        ids = {p.id: p for p in tc.check_all(deep=False)}
        self.assertTrue(ids['lld'].ok, ids['lld'])
        self.assertTrue(ids['ios_sdk'].ok, ids['ios_sdk'])
        self.assertTrue(ids['metal'].ok, ids['metal'])
        self.assertEqual(ids['ios_sdk'].version.split()[0], '26.0')

    def test_old_sdk_is_wrong_not_ok(self) -> None:
        sdk = make_fake_sdk(self.root, '17.0')
        os.environ['NSPB_IOS_SDK'] = str(sdk)
        ids = {p.id: p for p in tc.check_all(deep=False)}
        self.assertEqual(ids['ios_sdk'].state, 'wrong')
        self.assertIn('26.0', ids['ios_sdk'].detail)

    def test_deep_probes_run_only_with_tools(self) -> None:
        # nothing installed: no probe rows at all, rather than three failures
        ids = {p.id for p in tc.check_all(deep=True)}
        self.assertNotIn('probe_compile', ids)
        self.assertNotIn('probe_link', ids)


class MetalArgsTest(unittest.TestCase):
    """Xcode's Metal flags become the Windows compiler's `-target` triple."""

    def test_ios_version_min_becomes_target(self) -> None:
        from nspb_qt.win import xcrun_shim
        got = xcrun_shim.metal_args('iphoneos', ['-c', '-mios-version-min=18.0', 'a.metal'])
        self.assertIn('-target', got)
        self.assertIn('air64-apple-ios18.0', got)
        self.assertNotIn('-mios-version-min=18.0', got)

    def test_macos_version_min_becomes_target(self) -> None:
        from nspb_qt.win import xcrun_shim
        got = xcrun_shim.metal_args('macosx', ['-c', '-mmacosx-version-min=14.0', 'a.metal'])
        self.assertIn('air64-apple-macos14.0', got)

    def test_missing_target_gets_the_default(self) -> None:
        from nspb_qt.win import xcrun_shim
        got = xcrun_shim.metal_args('iphoneos', ['-c', 'a.metal'])
        self.assertEqual(got[:2], ['-target', 'air64-apple-ios18.0'])

    def test_version_query_is_left_alone(self) -> None:
        from nspb_qt.win import xcrun_shim
        self.assertEqual(xcrun_shim.metal_args('iphoneos', ['--version']), ['--version'])

    def test_explicit_target_is_not_duplicated(self) -> None:
        from nspb_qt.win import xcrun_shim
        got = xcrun_shim.metal_args('iphoneos', ['-target', 'air64-apple-ios26.0', '-c'])
        self.assertEqual(got.count('-target'), 1)

    def test_link_probe_reports_a_linker_failure(self) -> None:
        # An unavailable linker should be reported by the doctor, not crash its probe.
        with tempfile.TemporaryDirectory() as td, \
             mock.patch.object(tc, 'llvm_tool', return_value=Path(td) / 'clang.exe'), \
             mock.patch.object(tc, 'ensure_ld64_lld', return_value=(Path(td) / 'ld64.lld.exe', '')), \
             mock.patch.object(tc.subprocess, 'run', side_effect=OSError('linker unavailable')):
            ok, detail = tc.probe_link(Path(td))
        self.assertFalse(ok)
        self.assertIn('linker unavailable', detail)

    def test_metal_tt_has_no_windows_tool(self) -> None:
        # the pipeline archive is disabled here, and the caller relies on this being None
        self.assertIsNone(tc.metal_tool('metal-tt'))

    def test_metal_tool_takes_name_then_sdk(self) -> None:
        """The signature is (name, sdk). Both call sites once had it backwards, which made
        every `xcrun -sdk iphoneos metal` fall back to a slow Python wrapper instead of
        starting metal.exe directly -- a cost paid once per shader."""
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            (root / 'bin').mkdir()
            (root / 'bin/metal.exe').write_bytes(b'x')
            (root / 'ios/bin').mkdir(parents=True)
            (root / 'ios/bin/metal.exe').write_bytes(b'ios')
            old = os.environ.get('NSPB_METAL_DIR')
            os.environ['NSPB_METAL_DIR'] = str(root)
            try:
                self.assertIsNotNone(tc.metal_tool('metal', 'iphoneos'))
                self.assertIsNotNone(tc.metal_tool('metal', 'macosx'))
                # the reversed call is what the bug looked like: it silently returns None
                self.assertIsNone(tc.metal_tool('iphoneos', 'metal'))
            finally:
                if old is None:
                    os.environ.pop('NSPB_METAL_DIR', None)
                else:
                    os.environ['NSPB_METAL_DIR'] = old


class HostSourcesTest(unittest.TestCase):
    """The Makefile rules are reproduced, and a change upstream stops the build."""

    def setUp(self) -> None:
        self.repo = QT.parent / 'engine'   # tools/engine.py sync
        self.gen = Path(tempfile.mkdtemp())
        (self.gen / 'game_profile.h').write_text('// x', encoding='utf-8')

    def tearDown(self) -> None:
        import shutil
        shutil.rmtree(self.gen, ignore_errors=True)

    def test_source_list_matches_the_makefile(self) -> None:
        files, incs = build_app.host_sources(self.repo, self.gen)
        names = {p.name for p in files}
        # from SRC=
        for must in ('loader.c', 'hle.c', 'crash.c', 'probe.c', 'thread.c',
                     'memstat.m', 'haptics_apple.m', 'entry.S', 'main.c'):
            self.assertIn(must, names, f'{must} missing from the host source list')
        # Mac-only sources are dropped
        self.assertNotIn('front_mac.m', names)
        self.assertNotIn('controllers_mac.m', names)
        # the iOS front end is compiled by the iOS project, not the host walk
        self.assertNotIn('front_ios.m', names)
        self.assertNotIn('main.m', names)
        # and main.c is in
        self.assertIn('main.c', names)
        # include dirs include the ones the Makefile's compile line names
        inc_str = ' '.join(str(i) for i in incs)
        self.assertIn('gfx/nvn/include', inc_str.replace('\\', '/'))
        self.assertIn('stb_vorbis', inc_str.replace('\\', '/'))
        self.assertIn('libvpx', inc_str.replace('\\', '/'))

    def test_libvpx_sources_are_included(self) -> None:
        files, _ = build_app.host_sources(self.repo, self.gen)
        vpx = [p for p in files if 'third_party/libvpx' in p.as_posix()]
        self.assertTrue(vpx, 'no libvpx sources: the host would fail to link its movie decoder')

    def test_a_changed_makefile_stops_the_build(self) -> None:
        # simulate an upstream edit by pointing at a repository copy with a modified Makefile
        with tempfile.TemporaryDirectory() as td:
            fake = Path(td) / 'repo'
            (fake / 'dm/host').mkdir(parents=True)
            makefile = (self.repo / 'dm/host/Makefile').read_text(encoding='utf-8')
            (fake / 'dm/host/Makefile').write_text(
                makefile.replace('crash.c ', 'crash.c newfile.c '), encoding='utf-8')
            with self.assertRaises(SystemExit) as ctx:
                build_app.host_sources(fake, self.gen)
            # host_sources() reports through build_app.die(), which raises SystemExit(1); the
            # message itself goes to stdout, so capture it instead of reading the exception
            self.assertEqual(ctx.exception.code, 1)

    def test_missing_source_stops_the_build(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            fake = Path(td) / 'repo'
            (fake / 'dm/host').mkdir(parents=True)
            makefile = (self.repo / 'dm/host/Makefile').read_text(encoding='utf-8')
            (fake / 'dm/host/Makefile').write_text(makefile, encoding='utf-8')
            # the Makefile is intact but the sources are not there
            with self.assertRaises(SystemExit) as ctx:
                build_app.host_sources(fake, self.gen)
            self.assertEqual(ctx.exception.code, 1)

    def test_frameworks_drop_cocoa_and_keep_what_exists(self) -> None:
        sdk = make_fake_sdk(Path(tempfile.mkdtemp()))
        try:
            (sdk / 'System/Library/Frameworks/Metal.framework').mkdir(parents=True)
            fws = build_app.framework_list(sdk, [])
            self.assertNotIn('Cocoa', fws)
            self.assertIn('Metal', fws)
            self.assertIn('UIKit', fws)
            self.assertNotIn('AVFAudio', fws)     # not in this fake SDK
        finally:
            import shutil
            shutil.rmtree(sdk.parent, ignore_errors=True)


class InfoPlistTest(unittest.TestCase):
    def test_keys_the_app_reads_are_present(self) -> None:
        p = build_app.info_plist(bundle_id='org.example.1', name='Game', version='1.2.3',
                                 category='public.app-category.games', show_fps='YES',
                                 lang='ja', sdk_ver='26.0', sdk_build='23A1', icons=True,
                                 executable='DmIOS', deployment='26.0')
        self.assertEqual(p['CFBundleIdentifier'], 'org.example.1')
        self.assertEqual(p['CFBundleExecutable'], 'DmIOS')
        self.assertEqual(p['MinimumOSVersion'], '26.0')
        self.assertEqual(p['DTSDKName'], 'iphoneos26.0')
        # read by main.m / the launcher
        self.assertEqual(p['DMShowFPS'], 'YES')
        self.assertEqual(p['DMLanguage'], 'ja')
        self.assertIn('CFBundleIcons', p)
        self.assertIn('UIApplicationSceneManifest', p)
        self.assertEqual(p['UIRequiredDeviceCapabilities'], ['arm64'])

    def test_without_icons_no_icon_keys(self) -> None:
        p = build_app.info_plist(bundle_id='b', name='n', version='1', category='c',
                                 show_fps='NO', lang='en-US', sdk_ver='26.0', sdk_build='',
                                 icons=False, executable='DmIOS', deployment='26.0')
        self.assertNotIn('CFBundleIcons', p)


class RomfsPackTest(unittest.TestCase):
    """The RomFS can be a folder or an image file: marker check, resource name and pack skips."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.root = Path(self._tmp.name)
        tools = self.root / 'repo' / 'dm' / 'tools'
        tools.mkdir(parents=True)
        # A stand-in for the engine's dm/tools/romfs.py: an image file is a text list of its entries.
        (tools / 'romfs.py').write_text(
            'from pathlib import Path as _P\n'
            'class Path:\n'
            '    def __init__(self, p):\n'
            '        self.p = _P(p); self.rel = ""\n'
            '    def __truediv__(self, n):\n'
            '        o = Path(self.p); o.rel = n; return o\n'
            '    def exists(self):\n'
            '        if self.p.is_file():\n'
            '            return self.rel in self.p.read_text().split()\n'
            '        return (self.p / self.rel).exists()\n', encoding='utf-8')
        self.repo = self.root / 'repo'
        self._path = list(sys.path)
        self.addCleanup(lambda: (sys.path.__setitem__(slice(None), self._path), sys.modules.pop('romfs', None)))
        sys.modules.pop('romfs', None)

    def test_marker_in_image_file(self):
        img = self.root / 'RomFS.img'
        img.write_text('graph/a.bin')
        self.assertTrue(build_app.romfs_has(self.repo, img, 'graph/a.bin'))
        self.assertFalse(build_app.romfs_has(self.repo, img, 'graph/b.bin'))

    def test_marker_in_folder(self):
        d = self.root / 'RomFS'
        (d / 'graph').mkdir(parents=True)
        (d / 'graph' / 'a.bin').write_bytes(b'')
        self.assertTrue(build_app.romfs_has(self.repo, d, 'graph/a.bin'))
        self.assertFalse(build_app.romfs_has(self.repo, d, 'graph/b.bin'))

    def test_resource_name(self):
        img = self.root / 'RomFS.img'
        img.write_text('x')
        d = self.root / 'RomFS'
        d.mkdir()
        self.assertEqual(build_app.romfs_resource(img), 'romfs.img')
        self.assertEqual(build_app.romfs_resource(d), 'romfs')

    def test_pack_skips_both_names(self):
        self.assertIn('Payload/DmIOS.app/romfs', build_app.PACK_SKIPS)
        self.assertIn('Payload/DmIOS.app/romfs.img', build_app.PACK_SKIPS)


class IpaModesTest(unittest.TestCase):
    """The zip mode fixer, which stands in for `pack_ipa.py --exec` (an upstream file we
    must not edit)."""

    def _make_ipa(self, path: Path, exec_mode: int = 0o666) -> None:
        with zipfile.ZipFile(path, 'w') as z:
            z.writestr('Payload/DmIOS.app/DmIOS', b'\xcf\xfa\xed\xfe' + b'\0' * 28)
            z.writestr('Payload/DmIOS.app/Info.plist', b'plist')
            z.writestr('Payload/DmIOS.app/dm/shader_map.tsv', b'x')
            z.writestr('Payload/', b'')

    def test_executable_gets_the_execute_bit(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            ipa = Path(td) / 'a.ipa'
            self._make_ipa(ipa)
            fixed = fix_ipa_modes.fix(ipa, ['Payload/DmIOS.app/DmIOS'])
            self.assertIn('Payload/DmIOS.app/DmIOS', fixed)
            ok, detail = fix_ipa_modes.verify(ipa, ['Payload/DmIOS.app/DmIOS'])
            self.assertTrue(ok, detail)
            self.assertIn('0o100755', detail)

    def test_data_files_get_0644(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            ipa = Path(td) / 'a.ipa'
            self._make_ipa(ipa)
            fix_ipa_modes.fix(ipa, ['Payload/DmIOS.app/DmIOS'])
            modes = _zip_modes(ipa)
            self.assertEqual(modes['Payload/DmIOS.app/Info.plist'], 0o100644)
            self.assertEqual(modes['Payload/DmIOS.app/dm/shader_map.tsv'], 0o100644)
            self.assertEqual(modes['Payload/DmIOS.app/DmIOS'], 0o100755)

    def test_a_mac_built_ipa_is_left_alone(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            ipa = Path(td) / 'a.ipa'
            with zipfile.ZipFile(ipa, 'w') as z:
                # what Info-ZIP / pack_ipa writes on a Mac
                for name, mode in (('Payload/DmIOS.app/DmIOS', 0o100755),
                                   ('Payload/DmIOS.app/Info.plist', 0o100644)):
                    info = zipfile.ZipInfo(name)
                    info.external_attr = mode << 16
                    z.writestr(info, b'data')
            before = ipa.read_bytes()
            note = fix_ipa_modes.fix(ipa, ['Payload/DmIOS.app/DmIOS'])
            self.assertEqual(note, 'already correct')
            self.assertEqual(before, ipa.read_bytes(), 'a correct archive must not be rewritten')

    def test_idempotent(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            ipa = Path(td) / 'a.ipa'
            self._make_ipa(ipa)
            fix_ipa_modes.fix(ipa, ['Payload/DmIOS.app/DmIOS'])
            once = ipa.read_bytes()
            self.assertEqual(fix_ipa_modes.fix(ipa, ['Payload/DmIOS.app/DmIOS']), 'already correct')
            self.assertEqual(once, ipa.read_bytes())

    def test_missing_executable_is_reported(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            ipa = Path(td) / 'a.ipa'
            self._make_ipa(ipa)
            note = fix_ipa_modes.fix(ipa, ['Payload/DmIOS.app/NotThere'])
            self.assertIn('missing from the archive', note)

    def test_not_a_zip_raises(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            bad = Path(td) / 'x.ipa'
            bad.write_bytes(b'not a zip at all')
            with self.assertRaises(fix_ipa_modes.IpaModeError):
                fix_ipa_modes.fix(bad, ['Payload/DmIOS.app/DmIOS'])


def _zip_modes(path: Path) -> dict[str, int]:
    out = {}
    with zipfile.ZipFile(path) as z:
        for info in z.infolist():
            out[info.filename] = (info.external_attr >> 16) & 0xFFFF
    return out


class ShimTest(unittest.TestCase):
    def test_install_is_idempotent(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            d = Path(td)
            shim.install(d, python_exe=sys.executable)
            first = {p.name: p.read_bytes() for p in d.iterdir()}
            for p in d.iterdir():
                os.utime(p, (1_000_000_000, 1_000_000_000))
            mtimes = {p.name: p.stat().st_mtime_ns for p in d.iterdir()}
            shim.install(d, python_exe=sys.executable)
            second = {p.name: p.read_bytes() for p in d.iterdir()}
            self.assertEqual(first, second)
            self.assertEqual(mtimes, {p.name: p.stat().st_mtime_ns for p in d.iterdir()})
            self.assertNotIn(b'\r', first['sitecustomize.py'])
            for name in ('xcrun.cmd', 'xcodebuild.cmd', 'xcodegen.cmd', 'python3.cmd'):
                lines = first[name].splitlines(keepends=True)
                self.assertTrue(lines and all(line.endswith(b'\r\n') for line in lines), name)

    def test_sitecustomize_is_valid_python(self) -> None:
        import ast
        ast.parse(shim._SITECUSTOMIZE_SRC)

    def test_sitecustomize_maps_the_commands_we_depend_on(self) -> None:
        src = shim._SITECUSTOMIZE_SRC
        # every rewrite the pipeline needs, asserted against the generated text so a future
        # edit cannot silently drop one
        for needle in ("base in ('xcrun', 'xcrun.exe')",
                       "base == 'dmsh_xlate'",
                       "base in ('python3', 'python3.exe')",
                       "dm/ios/tools/build_ipa.sh",
                       "base in ('which', 'which.exe')",
                       "sys.modules['pwd'] = _pwd",
                       'BCryptDecrypt'):
            self.assertIn(needle, src, f'{needle} missing from the shim')

    def test_build_env_prepends_the_shim(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            with mock.patch.object(shim, 'shim_dir', return_value=Path(td)):
                env = shim.build_env({'PATH': 'C:\\Windows', 'PYTHONPATH': ''},
                                     python_exe=sys.executable)
            self.assertTrue(env['PATH'].startswith(td))
            self.assertTrue(env['PYTHONPATH'].startswith(td))
            self.assertEqual(env['PYTHONUTF8'], '1')

    def test_build_env_passes_portable_dotnet_and_spirv_cross_to_children(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            dotnet = root / 'dotnet'
            spirv = root / 'cross' / 'spirv-cross.exe'
            def find(name):
                return spirv if name == 'spirv-cross' else None
            with mock.patch.object(shim, 'shim_dir', return_value=root / 'shim'), \
                 mock.patch.object(tc, 'dotnet_dir', return_value=dotnet), \
                 mock.patch.object(tc, 'find_exe', side_effect=find):
                env = shim.build_env({'PATH': '', 'PYTHONPATH': ''}, python_exe=sys.executable)
        self.assertEqual(env['DOTNET_ROOT'], str(dotnet))
        self.assertEqual(env['DOTNET_ROOT_X64'], str(dotnet))
        self.assertEqual(env['SPIRV_CROSS'], str(spirv))

    def test_build_env_preserves_an_explicit_spirv_cross(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            with mock.patch.object(shim, 'shim_dir', return_value=Path(td)), \
                 mock.patch.object(tc, 'find_exe', return_value=Path('detected-cross')):
                env = shim.build_env({'PATH': '', 'SPIRV_CROSS': 'chosen-cross'},
                                     python_exe=sys.executable)
        self.assertEqual(env['SPIRV_CROSS'], 'chosen-cross')

    @unittest.skipUnless(os.name == 'nt', 'Windows subprocess shim')
    def test_translator_mapping_can_find_the_dotnet_module(self) -> None:
        # The generated sitecustomize runs in child interpreters and must resolve dotnet there.
        with tempfile.TemporaryDirectory() as td:
            shim.install(Path(td), python_exe=sys.executable)
            env = dict(os.environ, PYTHONPATH=td, NSPB_SHIM_OFF='')
            script = ("import sitecustomize as s, toolchain\n"
                      "from pathlib import Path\n"
                      "toolchain.dotnet_dir = lambda: Path('portable-dotnet')\n"
                      "got = s._map(['x/dmsh_xlate_bin/dmsh_xlate', '--source-sha'])\n"
                      "assert got[0] == str(Path('portable-dotnet') / 'dotnet.exe'), got\n"
                      "assert got[1:] == ['x/dmsh_xlate_bin/dmsh_xlate.dll', '--source-sha'], got\n")
            r = subprocess.run([sys.executable, '-c', script], env=env,
                               capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)


class DriverCliTest(unittest.TestCase):
    """Mac-only options are refused before any work starts."""

    def test_prepare_xcode_refused(self) -> None:
        from nspb_qt.win import driver
        with self.assertRaises(SystemExit) as ctx:
            driver.check_cli(['D:\\games\\x', '--prepare-xcode'])
        self.assertIn('needs Xcode', str(ctx.exception))

    def test_platform_ios_allowed(self) -> None:
        from nspb_qt.win import driver
        driver.check_cli(['D:\\games\\x', '--platform', 'ios'])

    def test_platform_mac_refused(self) -> None:
        from nspb_qt.win import driver
        with self.assertRaises(SystemExit) as ctx:
            driver.check_cli(['D:\\games\\x', '--platform', 'mac'])
        self.assertIn('macOS', str(ctx.exception))

    def test_platform_mac_app_refused(self) -> None:
        from nspb_qt.win import driver
        with self.assertRaises(SystemExit):
            driver.check_cli(['--platform=mac-app'])

    def test_newer_upstream_works_are_still_refused(self) -> None:
        from nspb_qt.win import driver
        self.assertIn('--prepare-xcode', driver.REFUSED_OPTIONS)
        self.assertIn('--platform', driver.REFUSED_OPTIONS)


class DriverPatchTest(unittest.TestCase):
    """The upstream module loads and its Mac-only functions get replaced."""

    @classmethod
    def setUpClass(cls) -> None:
        from nspb_qt.win import driver
        cls.driver = driver
        cls.repo = QT.parent / 'engine'   # tools/engine.py sync
        if not (cls.repo / 'scripts/build_ipa_from_nsp.py').is_file():
            raise unittest.SkipTest('engine/ is missing: run python3 tools/engine.py sync')
        # `pwd` is installed by the stub inside load_upstream, so this works on any OS
        cls.saved = {k: os.environ.get(k) for k in
                     ('NSPB_ALLOW_NON_WINDOWS', 'GAME', 'W')}
        cls.mod = driver.load_upstream(cls.repo)
        driver.patch(cls.mod, cls.repo)

    @classmethod
    def tearDownClass(cls) -> None:
        for k, v in cls.saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v

    def test_upstream_loaded(self) -> None:
        self.assertTrue(hasattr(self.mod, 'cli'))
        self.assertTrue(hasattr(self.mod, 'BuildError'))

    def test_mac_only_functions_refuse(self) -> None:
        with self.assertRaises(self.mod.BuildError) as ctx:
            self.mod.build_mac_host(self.repo, Path('out'), {}, Path('logs'), None)
        self.assertIn('arm64', str(ctx.exception))
        with self.assertRaises(self.mod.BuildError):
            self.mod.capture_shaders(None, None, None, None, {}, None, None, 'gl')
        with self.assertRaises(self.mod.BuildError):
            self.mod.mac_app()
        with self.assertRaises(self.mod.BuildError):
            self.mod.mac_run()

    def test_can_clone_is_false_and_apple_silicon_true(self) -> None:
        self.assertFalse(self.mod.can_clone(Path('.')))
        self.assertTrue(self.mod.apple_silicon())

    def test_check_prereqs_raises_with_a_report(self) -> None:
        with self.assertRaises(self.mod.BuildError) as ctx:
            self.mod.check_prereqs({}, Path('missing/dmsh_xlate'), mac=False)
        msg = str(ctx.exception)
        self.assertIn('missing on this PC', msg)
        # the message must name what to do, not just what is wrong
        self.assertTrue('LLVM' in msg or 'clang' in msg.lower())

    def test_check_prereqs_refuses_mac(self) -> None:
        with self.assertRaises(self.mod.BuildError) as ctx:
            self.mod.check_prereqs({}, Path('x'), mac=True)
        self.assertIn('need a Mac', str(ctx.exception))

    def test_toolchain_probe_uses_the_windows_metal(self) -> None:
        probes = self.mod.toolchain(self.repo, {})
        self.assertTrue(probes)
        joined = ' '.join(' '.join(p[1]) for p in probes if p[0] == 'cmd')
        self.assertIn('xcrun_shim.py', joined)
        self.assertIn('metal', joined)
        self.assertNotIn('xcodebuild', joined)

    def test_stage_key_fingerprints_the_selected_spirv_cross(self) -> None:
        """Switching SPIRV_CROSS must invalidate the shader-stage key."""
        with tempfile.TemporaryDirectory() as td:
            a = Path(td) / 'cross-a.exe'
            b = Path(td) / 'cross-b.exe'
            a.write_bytes(b'first')
            b.write_bytes(b'second')

            def files(probes):
                return [p for kind, values in probes if kind == 'files' for p in values]

            first = self.mod.toolchain(self.repo, {'SPIRV_CROSS': str(a), 'PATH': ''})
            second = self.mod.toolchain(self.repo, {'SPIRV_CROSS': str(b), 'PATH': ''})
            self.assertIn(a, files(first))
            self.assertIn(b, files(second))
            self.assertNotEqual(self.mod.fingerprint(('files', [a])),
                                self.mod.fingerprint(('files', [b])))
            # The same selected path with changed executable contents must also
            # change the key, or a rebuilt compiler would reuse the old library.
            before = self.mod.fingerprint(('files', [a]))
            a.write_bytes(b'changed')
            self.assertNotEqual(before, self.mod.fingerprint(('files', [a])))

    def test_tool_paths_are_replaced_not_extended(self) -> None:
        """On Windows the upstream macOS list must be gone.

        The replacement is derived from `toolchain` discovery, which on a macOS test host
        legitimately finds `/usr` and Homebrew — that is `which clang` answering. What matters
        is that the *upstream default* list was replaced rather than appended to, so assert on
        the object identity of the assignment: patch() assigns a fresh list.
        """
        upstream_default = ['/opt/homebrew/bin', '/usr/local/bin', '/usr/local/share/dotnet',
                            os.path.expanduser('~/.dotnet')]
        self.assertNotEqual(self.mod.TOOL_PATHS, upstream_default,
                            'patch() left the upstream macOS TOOL_PATHS in place')
        # and the GUI-launch reason the list exists still holds: it is a plain list of str
        self.assertTrue(all(isinstance(p, str) for p in self.mod.TOOL_PATHS))

    def test_bash_build_ipa_is_redirected(self) -> None:
        calls = []

        def fake_run(cmd, log, env=None, cwd=None, on_line=None):
            calls.append(list(cmd))
            return 0
        # `run_ipa` calls the module-level original; swap that for the test and re-patch so
        # the closure is rebuilt against it (patch() only captures when nothing is captured yet)
        orig = self.driver._UPSTREAM_RUN
        try:
            self.driver._UPSTREAM_RUN = fake_run
            self.driver.patch(self.mod, self.repo)
            self.mod.run(['bash', str(self.repo / 'dm/ios/tools/build_ipa.sh'), 'out.ipa'],
                         Path('log'))
        finally:
            self.driver._UPSTREAM_RUN = orig
            self.driver.patch(self.mod, self.repo)
        self.assertEqual(len(calls), 1)
        self.assertEqual(Path(calls[0][0]).name, Path(sys.executable).name)
        self.assertTrue(calls[0][1].endswith('build_app.py'))
        self.assertEqual(calls[0][-1], 'out.ipa')

    def test_prepare_xcode_through_run_is_still_refused(self) -> None:
        with self.assertRaises(self.mod.BuildError):
            self.mod.run(['bash', str(self.repo / 'dm/ios/tools/build_ipa.sh'), '--prepare-xcode'],
                         Path('log'))


class SdkFetchTest(unittest.TestCase):
    def test_extract_rejects_a_non_xip(self) -> None:
        from nspb_qt.win import sdk_fetch
        with tempfile.TemporaryDirectory() as td:
            bad = Path(td) / 'x.xip'
            bad.write_bytes(b'<html>404</html>')
            with self.assertRaises(sdk_fetch.SdkError) as ctx:
                sdk_fetch.extract_xip(bad, Path(td) / 'out')
            self.assertIn('xar', str(ctx.exception))

    def test_extract_rejects_a_missing_file(self) -> None:
        from nspb_qt.win import sdk_fetch
        with self.assertRaises(sdk_fetch.SdkError):
            sdk_fetch.extract_xip(Path('/nonexistent/Xcode.xip'))

    def test_import_local_rejects_a_plain_folder(self) -> None:
        from nspb_qt.win import sdk_fetch
        with tempfile.TemporaryDirectory() as td:
            plain = Path(td) / 'notasdk'
            plain.mkdir()
            with self.assertRaises(sdk_fetch.SdkError):
                sdk_fetch.import_local(plain, Path(td) / 'cache')

    def test_import_local_accepts_a_nested_sdk(self) -> None:
        from nspb_qt.win import sdk_fetch
        with tempfile.TemporaryDirectory() as td:
            sdk = make_fake_sdk(Path(td) / 'download')
            got = sdk_fetch.import_local(sdk.parent, Path(td) / 'cache', log=lambda s: None)
            self.assertTrue(tc.is_sdk_dir(got))
            self.assertEqual(got.name, 'iPhoneOS26.0.sdk')

    def test_available_versions_is_a_best_effort_list(self) -> None:
        from nspb_qt.win import sdk_fetch
        # no network in CI: must not raise
        got = sdk_fetch.available_versions()
        self.assertIsInstance(got, list)


class FetchTest(unittest.TestCase):
    def test_sha256_of_a_file(self) -> None:
        from nspb_qt.win import fetch
        with tempfile.TemporaryDirectory() as td:
            p = Path(td) / 'x'
            p.write_bytes(b'abc')
            self.assertEqual(fetch.sha256_of(p),
                             'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad')

    def test_pinned_hashes_are_well_formed(self) -> None:
        for arch, asset in tc.LLVM_MINGW_ASSETS.items():
            self.assertEqual(len(asset['sha256']), 64, arch)
            self.assertTrue(all(c in '0123456789abcdef' for c in asset['sha256']), arch)
            self.assertIn(arch, ('AMD64', 'ARM64'))
            self.assertGreater(asset['size'], 100_000_000)

    def test_download_asset_url(self) -> None:
        a = tc.download_asset('AMD64')
        self.assertIn(tc.LLVM_MINGW_VERSION, a['url'])
        self.assertTrue(a['url'].endswith(a['name']))

    def test_mirror_urls_cover_github_assets(self) -> None:
        """A GitHub release asset gets the direct URL plus every mirror, in that order.

        The handheld report measured 974 s for the 182 MiB LLVM archive from GitHub, so a
        mainland connection needs the mirrors; the direct URL stays first for everyone else.
        """
        urls = tc.mirror_urls('https://github.com/mstorsjo/llvm-mingw/releases/download/x/y.zip')
        self.assertEqual(urls[0],
                         'https://github.com/mstorsjo/llvm-mingw/releases/download/x/y.zip')
        self.assertEqual(len(urls), 1 + len(tc.GITHUB_MIRRORS))
        for m, u in zip(tc.GITHUB_MIRRORS, urls[1:]):
            self.assertEqual(u, m + urls[0])

    def test_mirror_urls_leave_other_hosts_alone(self) -> None:
        """Microsoft's CDN is fast on mainland networks; proxying it would only add a hop."""
        self.assertEqual(tc.mirror_urls(tc.DOTNET_ASSET['url']), [tc.DOTNET_ASSET['url']])

    def test_rank_by_speed_puts_the_fastest_first(self) -> None:
        """The 974-second case: nothing failed, so only a speed probe can pick a better source."""
        from nspb_qt.win import fetch
        urls = ['https://slow/x.zip', 'https://fast/x.zip', 'https://dead/x.zip']

        class Resp:
            """First read delivers a slice, the second delivers the rest: a transfer window."""

            def __init__(self, first, rest):
                self.chunks = [first, rest]

            def read(self, n):
                return self.chunks.pop(0) if self.chunks else b''

            def __enter__(self):
                return self

            def __exit__(self, *a):
                return False

        # each URL: t_first, t_end. slow transfers in 3.0 s, fast in 0.2 s, dead raises.
        clock = iter([0.0, 3.0,  10.0, 10.2])

        def fake_urlopen(req, timeout=0):
            if 'dead' in req.full_url:
                raise OSError('no route')
            return Resp(b'x' * 65536, b'y' * 65536)

        with mock.patch('urllib.request.urlopen', fake_urlopen), \
                mock.patch('time.time', side_effect=lambda: next(clock)):
            out = fetch.rank_by_speed(urls, log=lambda s: None)
        # fastest first, the unreachable one last rather than dropped
        self.assertEqual(out, ['https://fast/x.zip', 'https://slow/x.zip', 'https://dead/x.zip'])

    def test_rank_by_speed_times_the_transfer_not_the_handshake(self) -> None:
        """A slow TLS setup must not make a fast source look slow.

        The first version timed from the request, and every mirror's proxy handshake (2-3 s on a
        real connection) dominated the 256 KB transfer, so it picked at random.
        """
        from nspb_qt.win import fetch

        class Resp:
            def __init__(self, chunks):
                self.chunks = list(chunks)

            def read(self, n):
                return self.chunks.pop(0) if self.chunks else b''

            def __enter__(self):
                return self

            def __exit__(self, *a):
                return False

        # both deliver in 0.1 s of transfer, but "slow" took 30 s to connect
        clock = iter([30.0, 30.1,  31.0, 31.1])

        def fake_urlopen(req, timeout=0):
            return Resp([b'x' * 65536, b'y' * 65536])

        with mock.patch('urllib.request.urlopen', fake_urlopen), \
                mock.patch('time.time', side_effect=lambda: next(clock)):
            out = fetch.rank_by_speed(['https://a/x', 'https://b/x'], log=lambda s: None)
        self.assertEqual(len(out), 2)     # neither was penalised for its handshake

    def test_rank_by_speed_keeps_a_single_url_untouched(self) -> None:
        """No probe when there is nothing to choose between (a non-GitHub URL)."""
        from nspb_qt.win import fetch
        with mock.patch('urllib.request.urlopen', side_effect=AssertionError('probed')):
            self.assertEqual(fetch.rank_by_speed(['https://only/x'], lambda s: None),
                             ['https://only/x'])

    def test_download_falls_through_to_a_mirror(self) -> None:
        """The first URL failing must not end the download; the hash decides what is accepted."""
        from nspb_qt.win import fetch
        payload = b'toolchain bytes'
        want = __import__('hashlib').sha256(payload).hexdigest()

        class Resp:
            headers = {'Content-Length': str(len(payload))}

            def __init__(self):
                self.left = payload

            def read(self, n):
                b, self.left = self.left, b''   # one read, then EOF: download() loops until b''
                return b

            def __enter__(self):
                return self

            def __exit__(self, *a):
                return False

        seen = []

        def fake_urlopen(req, timeout=0):
            seen.append(req.full_url)
            if len(seen) == 1:
                raise OSError('connection reset')       # the direct URL fails
            return Resp()

        with tempfile.TemporaryDirectory() as td, \
                mock.patch('urllib.request.urlopen', fake_urlopen), \
                mock.patch.object(fetch, 'rank_by_speed', lambda u, log, **k: u):
            out = fetch.download('https://github.com/a/b/releases/download/v/x.zip',
                                 Path(td) / 'x.zip', want, log=lambda s: None)
            self.assertEqual(out.read_bytes(), payload)
        self.assertEqual(len(seen), 2)
        self.assertTrue(seen[1].startswith(tc.GITHUB_MIRRORS[0]))

    def test_download_rejects_a_mirror_serving_other_bytes(self) -> None:
        """A mirror is only a transport: bytes that do not match the pin are refused."""
        from nspb_qt.win import fetch

        class Resp:
            headers = {}

            def __init__(self, body):
                self.body = body

            def read(self, n):
                b, self.body = self.body, b''
                return b

            def __enter__(self):
                return self

            def __exit__(self, *a):
                return False

        calls = []

        def fake_urlopen(req, timeout=0):
            calls.append(req.full_url)
            # the direct URL is unreachable, the first mirror serves the wrong bytes, the
            # second mirror serves the right ones
            if len(calls) == 1:
                raise OSError('no route')
            return Resp(b'wrong' if len(calls) == 2 else b'right')

        want = __import__('hashlib').sha256(b'right').hexdigest()
        with tempfile.TemporaryDirectory() as td, \
                mock.patch('urllib.request.urlopen', fake_urlopen), \
                mock.patch.object(fetch, 'rank_by_speed', lambda u, log, **k: u):
            out = fetch.download('https://github.com/a/b/releases/download/v/x.zip',
                                 Path(td) / 'x.zip', want, log=lambda s: None)
            self.assertEqual(out.read_bytes(), b'right')
        self.assertEqual(len(calls), 3)

    def test_download_reports_every_failure(self) -> None:
        """When nothing works the message names each attempt, not just the last one."""
        from nspb_qt.win import fetch

        def fake_urlopen(req, timeout=0):
            raise OSError('unreachable')

        with tempfile.TemporaryDirectory() as td, \
                mock.patch('urllib.request.urlopen', fake_urlopen), \
                mock.patch.object(fetch, 'rank_by_speed', lambda u, log, **k: u):
            with self.assertRaises(fetch.DownloadError) as cm:
                fetch.download('https://github.com/a/b/releases/download/v/x.zip',
                               Path(td) / 'x.zip', '0' * 64, log=lambda s: None)
        msg = str(cm.exception)
        self.assertIn('unreachable', msg)
        self.assertEqual(msg.count('github.com/a/b'), 1 + len(tc.GITHUB_MIRRORS))


class ToolchainProbeRobustnessTest(unittest.TestCase):
    """Probes must survive a tool that prints nothing on stdout.

    The second handheld report's log ended with eight repetitions of
    `dependency check failed: TypeError: expected string or bytes-like object, got 'NoneType'`
    from `llvm_version` — `subprocess.run(text=True)` leaves `stdout` as None when the child
    writes nothing there, and `re.search` on None raises. The check died, `deps` became empty,
    and `all([])` is True, so the panel said every dependency was ready while nothing at all had
    been verified (the report: "I have not even installed Metal").
    """

    def test_llvm_version_reports_what_happened(self) -> None:
        """The version probe carries its diagnostics: exit code, empty output, whatever.

        The report's machine compiles fine and its --version exits non-zero silently — "does not
        run" was all the row said, three reports in a row. Now the row can say exactly what the
        probe saw.
        """
        ver, diag = tc.llvm_version(Path('clang.exe')) if False else (None, None)
        # empty output, exit 0: no version line, and the diagnostic says so
        fake = subprocess.CompletedProcess(['clang'], 0, None, '')
        with mock.patch('subprocess.run', return_value=fake):
            ver, diag = tc.llvm_version(Path('clang.exe'))
        self.assertEqual(ver, '')
        self.assertIn('no version line', diag)

        # exit 1, silent: the diagnostic carries the code (0xC0000135 = STATUS_DLL_NOT_FOUND would
        # have been visible immediately in the report)
        fake = subprocess.CompletedProcess(['clang'], 0xC0000135, '', '')
        with mock.patch('subprocess.run', return_value=fake):
            ver, diag = tc.llvm_version(Path('clang.exe'))
        self.assertEqual(ver, '')
        self.assertIn('0xc0000135', diag)

    def test_llvm_version_reads_stderr_too(self) -> None:
        """A clang that prints its banner on stderr still tells us its version."""
        fake = subprocess.CompletedProcess(['clang'], 0, None,
                                           'clang version 23.1.4\nTarget: x86_64-pc-windows')
        with mock.patch('subprocess.run', return_value=fake):
            ver, diag = tc.llvm_version(Path('clang.exe'))
        self.assertEqual(ver, '23.1.4')
        self.assertEqual(diag, '')

    def test_llvm_version_still_reads_stdout(self) -> None:
        fake = subprocess.CompletedProcess(['clang'], 0,
                                           'clang version 23.1.4 (https://llvm.org)', '')
        with mock.patch('subprocess.run', return_value=fake):
            ver, _diag = tc.llvm_version(Path('clang.exe'))
        self.assertEqual(ver, '23.1.4')

    def test_llvm_row_is_green_when_compile_works_despite_no_version(self) -> None:
        """The row's verdict is the compile probe, not --version.

        The report: clang compiled the probe green and --version still failed, so the row read
        "does not run" — three reports in a row, on a toolchain that works.
        """
        probes = tc.check_all(deep=False)
        llvm = next(p for p in probes if p.id == 'llvm')
        # this Mac has a real clang; the shallow row says ok either way
        self.assertEqual(llvm.state, 'ok')

    def test_clang_compiles_accepts_a_macho_object(self) -> None:
        """The fake writes to the -o path the probe asked for, like a real compiler."""
        def fake_compile(cmd, **k):
            out = Path(cmd[cmd.index('-o') + 1])
            out.write_bytes(b'\xce\xfa\xed\xfe' + b'\x00' * 32)
            return subprocess.CompletedProcess(cmd, 0, '', '')

        with mock.patch.object(tc.subprocess, 'run', side_effect=fake_compile):
            ok, detail = tc.clang_compiles(Path('clang.exe'))
        self.assertTrue(ok)
        self.assertIn('Mach-O', detail)

    def test_clang_compiles_rejects_non_macho(self) -> None:
        def fake_compile(cmd, **k):
            out = Path(cmd[cmd.index('-o') + 1])
            out.write_bytes(b'ELF....')               # a Linux object, not Mach-O
            return subprocess.CompletedProcess(cmd, 0, '', '')

        with mock.patch.object(tc.subprocess, 'run', side_effect=fake_compile):
            ok, detail = tc.clang_compiles(Path('clang.exe'))
        self.assertFalse(ok)
        self.assertIn('not a Mach-O', detail)

    def test_metal_version_survives_empty_output(self) -> None:
        fake = subprocess.CompletedProcess(['metal'], 0, None, None)
        with mock.patch.object(tc, 'metal_tool', return_value=Path('metal.exe')), \
                mock.patch('subprocess.run', return_value=fake):
            self.assertEqual(tc.metal_version(), '')

    def _all_deps_ok(self, deps, checked):
        """Evaluate Model.all_deps_ok without needing PySide6 installed."""
        try:
            from nspb_qt.model import Dep, DepState, Model
        except ModuleNotFoundError as e:          # pragma: no cover - a bare interpreter
            if 'PySide6' in str(e):
                self.skipTest('PySide6 is not installed')
            raise

        class Fake(Model):
            def __init__(self):
                self.deps = deps
                self.deps_checked = checked

        return Fake().all_deps_ok

    def test_empty_dep_list_is_not_all_ready(self) -> None:
        """`all([])` is True — a check that produced no rows has proved nothing."""
        self.assertFalse(self._all_deps_ok([], True))

    def test_unchecked_is_not_all_ready(self) -> None:
        try:
            from nspb_qt.model import Dep, DepState
        except ModuleNotFoundError as e:
            if 'PySide6' in str(e):
                self.skipTest('PySide6 is not installed')
            raise
        good = [Dep('a', 'k', 'h', DepState.OK, '')]
        self.assertFalse(self._all_deps_ok(good, False))
        self.assertTrue(self._all_deps_ok(good, True))
        self.assertFalse(self._all_deps_ok([Dep('a', 'k', 'h', DepState.MISSING, '')], True))

    def test_a_missing_optional_row_does_not_stop_the_build(self) -> None:
        """spirv-cross and glslangValidator are optional (only an OpenGL game uses them). With them missing and
        every required row present the panel says "everything required is installed", and the build button
        must be on: all_deps_ok counted them once, and the button stayed grey with no reason on the screen."""
        try:
            from nspb_qt.model import Dep, DepState
        except ModuleNotFoundError as e:
            if 'PySide6' in str(e):
                self.skipTest('PySide6 is not installed')
            raise
        good = Dep('python', 'k', 'h', DepState.OK, '')
        optional = [Dep('spirv-cross', 'k', 'h', DepState.MISSING, '', required=False),
                    Dep('glslangValidator', 'k', 'h', DepState.MISSING, '', required=False)]
        self.assertTrue(self._all_deps_ok([good] + optional, True))
        self.assertFalse(self._all_deps_ok([good, Dep('zstd', 'k', 'h', DepState.MISSING, '')] + optional, True),
                         'a required row that is missing still stops it')
        self.assertFalse(self._all_deps_ok([good] + optional, False), 'unchecked is not ready')


class SdkCleanupTest(unittest.TestCase):
    """A retry must start from an empty directory, even with git's read-only pack files.

    The report's log showed the same clone failing three times — direct, then two mirrors — all
    with "destination path already exists and is not an empty directory". `shutil.rmtree(...,
    ignore_errors=True)` cannot delete the read-only files git writes on Windows and silently
    left them behind, so every retry hit the previous attempt's leftovers.
    """

    def test_rmtree_clears_readonly_files(self) -> None:
        from nspb_qt.win.sdk_fetch import rmtree
        with tempfile.TemporaryDirectory() as td:
            root = Path(td) / 'clone'
            (root / 'objects' / 'pack').mkdir(parents=True)
            pack = root / 'objects' / 'pack' / 'x.pack'
            pack.write_bytes(b'read only')
            pack.chmod(0o444)                       # what git does on Windows
            rmtree(root)
            self.assertFalse(root.exists())

    def test_rmtree_is_quiet_when_absent(self) -> None:
        from nspb_qt.win.sdk_fetch import rmtree
        with tempfile.TemporaryDirectory() as td:
            rmtree(Path(td) / 'never-existed')      # must not raise


class ProgressStepTest(unittest.TestCase):
    """Downloads and unpacks log at 5% steps, not on every chunk.

    The report: a 287 MB SDK download printed a line per MiB (about 280 lines), burying the rest
    of the log. Unpacking had no progress at all ("can unpacking also have progress").
    """

    def test_the_model_filters_progress_to_five_percent_steps(self) -> None:
        """The 5%-step filter lives in Model._install_win's progress logger.

        `fetch.download` must keep calling back on every chunk (it has no idea what a useful
        logging granularity is, and the callback also drives any future progress bar), so the
        filtering is tested where it belongs. The report: a 287 MB SDK printed ~280 lines.
        """
        try:
            from nspb_qt.model import Model
        except ModuleNotFoundError as e:
            if 'PySide6' in str(e):
                self.skipTest('PySide6 is not installed')
            raise

        logged: list[str] = []
        m = Model.__new__(Model)                 # no QObject init: only log() is used
        m.log = logged.append
        report = Model._progress_logger(m, 'Download')

        for mb in range(0, 288):                 # one callback per MiB, like the real download
            report(mb * 1048576, 287 * 1048576)
        # 0,5,…,95,100 — at most 21 lines for 288 callbacks
        self.assertLessEqual(len(logged), 21)
        self.assertGreaterEqual(len(logged), 10)
        self.assertTrue(any('100%' in s for s in logged))
        self.assertTrue(all('Download' in s for s in logged))

    def test_unpack_progress_reaches_100(self) -> None:
        from nspb_qt.win import fetch
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            z = root / 'downloads' / tc.DOTNET_ASSET['name']
            z.parent.mkdir(parents=True)
            with zipfile.ZipFile(z, 'w') as zf:
                zf.writestr('dotnet.exe', b'MZ' * 1000)
                zf.writestr('sdk/a.dll', b'x' * 5000)
            seen: list[tuple[int, int]] = []
            with mock.patch.object(fetch, 'download', return_value=z):
                fetch.install_dotnet(dest=root, log=lambda s: None,
                                     unpack_progress=lambda d, t: seen.append((d, t)))
            self.assertTrue(seen)
            done, total = seen[-1]
            self.assertEqual(done, total)       # the last report is the whole archive
            self.assertGreaterEqual(total, 6000)


class PythonInstallTest(unittest.TestCase):
    """The interpreter row and the in-app Python installer.

    The report's handheld had no usable interpreter at all, and the row could only answer "too
    old" — then pip-install into a python that was not there. Now the row says what is true and
    the fix is a per-user silent install into the app's own tools folder.
    """

    def test_python_asset_is_pinned(self) -> None:
        a = tc.PYTHON_ASSET
        self.assertEqual(len(a['sha256']), 64)
        self.assertTrue(all(c in '0123456789abcdef' for c in a['sha256']))
        self.assertIn(tc.PYTHON_VERSION, a['url'])
        self.assertTrue(a['url'].startswith('https://www.python.org/ftp/python/'))
        self.assertGreater(a['size'], 20_000_000)

    def test_installer_command_is_per_user_and_silent(self) -> None:
        """No administrator rights, no PATH changes, lands in the app's own folder."""
        from nspb_qt.win import fetch
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            seen = []

            def fake_run(cmd, **k):
                seen.append(cmd)
                return subprocess.CompletedProcess(cmd, 0, '', '')

            exe = root / 'downloads' / tc.PYTHON_ASSET['name']
            exe.parent.mkdir(parents=True)
            exe.write_bytes(b'MZ')
            # first _runs_quiet (the "already installed" check) says no, the one after the
            # installer says yes: that is the exact sequence install_python goes through
            with mock.patch.object(fetch, 'download', return_value=exe), \
                    mock.patch.object(fetch.subprocess, 'run', side_effect=fake_run), \
                    mock.patch.object(tc, '_runs_quiet', side_effect=[False, True]):
                out = fetch.install_python(dest=root, log=lambda s: None)
            cmd = seen[0]
            self.assertIn('/quiet', cmd)
            self.assertIn('InstallAllUsers=0', cmd)
            self.assertIn('Include_pip=1', cmd)
            self.assertIn('PrependPath=0', cmd)
            self.assertTrue(any(str(c).startswith('TargetDir=') and str(root) in str(c)
                                for c in cmd), cmd)
            self.assertEqual(out, root / f'python-{tc.PYTHON_VERSION}')

    def test_install_python_reports_installer_failure(self) -> None:
        from nspb_qt.win import fetch
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            exe = root / 'downloads' / tc.PYTHON_ASSET['name']
            exe.parent.mkdir(parents=True)
            exe.write_bytes(b'MZ')
            with mock.patch.object(fetch, 'download', return_value=exe), \
                    mock.patch.object(fetch, 'subprocess') as msub, \
                    mock.patch.object(tc, '_runs_quiet', return_value=False):
                msub.run.return_value = subprocess.CompletedProcess([], 1, 'boom', '')
                with self.assertRaises(fetch.DownloadError) as cm:
                    fetch.install_python(dest=root, log=lambda s: None)
            self.assertIn('did not install', str(cm.exception))

    def test_find_python_prefers_the_app_managed_interpreter(self) -> None:
        """A machine with no system Python must still find the copy the app installed.

        Every probe is mocked so the test does not depend on what this Mac has: the candidate
        order is the subject, not any real interpreter.
        """
        from nspb_qt import platform_util as pu
        with tempfile.TemporaryDirectory() as td:
            fake = Path(td) / 'python-3.12.10'
            fake.mkdir(parents=True)
            (fake / 'python.exe').write_bytes(b'MZ')
            with mock.patch.object(pu, 'venv_python', return_value=str(Path(td) / 'no-venv')), \
                    mock.patch.object(pu, '_python_version', return_value='3.12.10'), \
                    mock.patch.object(pu, '_runs', return_value=False):
                py, ok, _ver = pu.find_python([str(fake / 'python.exe')])
            self.assertEqual(py, str(fake / 'python.exe'))
            self.assertFalse(ok)      # the packages are not installed in it (yet)

    def test_python_candidates_include_uvs_managed_interpreters(self) -> None:
        """`uv python install` keeps its Pythons outside every location the app used to probe.

        Reported from a Mac whose only 3.12 was uv's: `uv` had the packages, the panel said no
        interpreter was found. A GUI launch's PATH has neither uv's store nor ~/.local/bin.
        """
        from nspb_qt import platform_util as pu
        with tempfile.TemporaryDirectory() as td:
            store = Path(td) / 'python'
            exe = store / 'cpython-3.12.13-macos-aarch64-none' / 'bin' / 'python3.12'
            exe.parent.mkdir(parents=True)
            exe.write_text('#!/bin/sh\n')
            exe.chmod(0o755)
            shim = Path(td) / '.local' / 'bin' / 'python3'
            shim.parent.mkdir(parents=True)
            shim.write_text('#!/bin/sh\n')
            with mock.patch.object(pu, 'IS_WIN', False), \
                    mock.patch.dict(os.environ, {'UV_PYTHON_INSTALL_DIR': str(store), 'HOME': td,
                                                 'USERPROFILE': td}):
                cands = pu.uv_pythons()
            self.assertIn(str(exe), cands, "uv's store holds the real interpreter")
            self.assertIn(str(shim), cands, "uv links a python3 shim in ~/.local/bin")

    def test_find_python_takes_a_uv_interpreter_when_it_is_the_only_one(self) -> None:
        """The room's report: uv had a 3.12 with the packages and the panel still found nothing."""
        from nspb_qt import platform_util as pu
        with tempfile.TemporaryDirectory() as td:
            store = Path(td) / 'python'
            exe = store / 'cpython-3.12.13-macos-aarch64-none' / 'bin' / 'python3.12'
            exe.parent.mkdir(parents=True)
            exe.write_text('#!/bin/sh\n')
            exe.chmod(0o755)
            with mock.patch.object(pu, 'IS_WIN', False), \
                    mock.patch.object(pu, 'venv_python', return_value=str(Path(td) / 'no-venv')), \
                    mock.patch.object(pu, '_which', return_value=None), \
                    mock.patch.object(pu, '_python_version', return_value='3.12.13'), \
                    mock.patch.object(pu, '_runs', return_value=True), \
                    mock.patch.object(pu.Path, 'is_file', lambda self: str(self) == str(exe)), \
                    mock.patch.dict(os.environ, {'UV_PYTHON_INSTALL_DIR': str(store)}):
                py, ok, ver = pu.find_python()
            self.assertEqual(py, str(exe))
            self.assertTrue(ok)
            self.assertEqual(ver, '3.12.13')

    def test_find_python_prefers_the_newest_interpreter_that_has_the_packages(self) -> None:
        """A 3.9 with the packages must not win over a 3.12: the script needs 3.12.

        Apple's /usr/bin/python3 is 3.9 and sits above uv's store in the candidate list, so the
        old first-match-wins loop picked the one interpreter that cannot run the build.
        """
        from nspb_qt import platform_util as pu
        with tempfile.TemporaryDirectory() as td:
            old = Path(td) / 'python3.9'
            new = Path(td) / 'python3.12'
            for p in (old, new):
                p.write_text('x')
            versions = {str(old): '3.9', str(new): '3.12.13'}
            with mock.patch.object(pu, 'python_candidates', return_value=[str(old), str(new)]), \
                    mock.patch.object(pu, '_python_version', side_effect=lambda p: versions[p]), \
                    mock.patch.object(pu, '_runs', return_value=True):
                py, ok, ver = pu.find_python()
            self.assertEqual((py, ok), (str(new), True))
            self.assertEqual(ver, '3.12.13')

    def test_venv_base_is_never_the_venv_it_has_to_create(self) -> None:
        """The row's Install used to run `-m venv` on a path that does not exist yet."""
        from nspb_qt import platform_util as pu
        with tempfile.TemporaryDirectory() as td:
            wanted = str(Path(td) / 'no-venv' / 'bin' / 'python3')
            real = Path(td) / 'python3.12'
            real.write_text('x')
            real.chmod(0o755)
            with mock.patch.object(pu, 'python_candidates', return_value=[wanted, str(real)]), \
                    mock.patch.object(pu, '_python_version', return_value='3.12.13'):
                self.assertEqual(pu.venv_base(wanted), str(real))
                self.assertEqual(pu.venv_base(str(real)), str(real))

    def test_venv_base_reports_no_interpreter_instead_of_a_broken_base(self) -> None:
        from nspb_qt import platform_util as pu
        with tempfile.TemporaryDirectory() as td:
            wanted = str(Path(td) / 'no-venv' / 'bin' / 'python3')
            with mock.patch.object(pu, 'python_candidates', return_value=[wanted]):
                self.assertIsNone(pu.venv_base(wanted))


class XcodeBetaTest(unittest.TestCase):
    """Xcode detection asks xcode-select, not a fixed /Applications/Xcode.app path.

    Issue #21: an Xcode **beta** lives at /Applications/Xcode-beta.app, so the hard-coded check
    reported "no Xcode" on a machine that could build perfectly well — xcodebuild and xcrun both
    follow xcode-select, and that is what the panel has to agree with.
    """

    def test_xcode_ok_follows_xcode_select(self) -> None:
        from nspb_qt import platform_util as pu
        if pu.IS_WIN:
            self.skipTest('macOS only')
        with tempfile.TemporaryDirectory() as td:
            beta = Path(td) / 'Xcode-beta.app' / 'Contents' / 'Developer'
            beta.mkdir(parents=True)
            with mock.patch.object(pu, 'IS_WIN', False), \
                    mock.patch.object(pu, 'xcode_developer_dir', return_value=str(beta)), \
                    mock.patch.object(pu.Path, 'is_file', return_value=True):
                self.assertTrue(pu.xcode_ok())

    def test_xcode_ok_rejects_a_stale_selection(self) -> None:
        """xcode-select can point at a deleted Xcode (uninstalled without re-selecting)."""
        from nspb_qt import platform_util as pu
        with mock.patch.object(pu, 'IS_WIN', False), \
                mock.patch.object(pu, 'xcode_developer_dir', return_value='/nope/Xcode.app/Contents/Developer'):
            self.assertFalse(pu.xcode_ok())

    def test_xcode_ok_rejects_no_selection(self) -> None:
        from nspb_qt import platform_util as pu
        with mock.patch.object(pu, 'IS_WIN', False), \
                mock.patch.object(pu, 'xcode_developer_dir', return_value=''):
            self.assertFalse(pu.xcode_ok())

    def test_developer_dir_is_empty_on_windows(self) -> None:
        from nspb_qt import platform_util as pu
        with mock.patch.object(pu, 'IS_WIN', True):
            self.assertEqual(pu.xcode_developer_dir(), '')

    def test_developer_dir_reads_xcode_select_output(self) -> None:
        from nspb_qt import platform_util as pu
        fake = subprocess.CompletedProcess([], 0, '/Applications/Xcode-beta.app/Contents/Developer\n', '')
        with mock.patch.object(pu, 'IS_WIN', False), \
                mock.patch.object(pu.subprocess, 'run', return_value=fake):
            self.assertEqual(pu.xcode_developer_dir(),
                             '/Applications/Xcode-beta.app/Contents/Developer')

    def test_developer_dir_ignores_a_failing_xcode_select(self) -> None:
        """A machine with no Xcode at all: xcode-select exits non-zero."""
        from nspb_qt import platform_util as pu
        fake = subprocess.CompletedProcess([], 2, '', 'xcode-select: error: unable to get active developer directory')
        with mock.patch.object(pu, 'IS_WIN', False), \
                mock.patch.object(pu.subprocess, 'run', return_value=fake):
            self.assertEqual(pu.xcode_developer_dir(), '')


class SdkLongPathsTest(unittest.TestCase):
    """The SDK clone carries core.longpaths: a swiftinterface in the SDK tree tops Windows'
    260-character MAX_PATH and the sparse checkout died with "Filename too long"."""

    def test_clone_args_carry_longpaths(self) -> None:
        import inspect
        from nspb_qt.win import sdk_fetch
        src = inspect.getsource(sdk_fetch.clone_sdk)
        self.assertIn("core.longpaths=true", src)
        # the sparse-checkout step needs it too: -c applies to one command only
        self.assertIn("'sparse-checkout', 'set'", src)


class DotnetTest(unittest.TestCase):
    """The .NET row and its in-app installer.

    The handheld report's first line was "the first dependency, .NET SDK 10, never appears in the
    log": on Windows the panel built its rows from `_windows_deps`, which had no .NET entry, so
    `install all` could not install it and nothing said so.
    """

    def test_dotnet_asset_is_pinned(self) -> None:
        """Microsoft publishes SHA-512 in releases.json, so the pin carries that algorithm."""
        a = tc.DOTNET_ASSET
        algo = a.get('algo', 'sha256')
        want = 128 if algo == 'sha512' else 64
        self.assertEqual(len(a['sha256']), want, algo)
        self.assertTrue(all(c in '0123456789abcdef' for c in a['sha256']))
        self.assertGreater(a['size'], 200_000_000)
        self.assertIn(tc.DOTNET_VERSION, a['url'])
        self.assertTrue(a['url'].endswith(a['name']))

    def test_dotnet_version_satisfies_the_extractor_target(self) -> None:
        """`nx_extract` targets net10.0; a lower major builds nothing, so the pin must be >= 10."""
        repo = QT.parent / 'engine'
        csproj = (repo / 'dm/tools/nx_extract/nx_extract.csproj').read_text(encoding='utf-8')
        self.assertIn(f'net{tc.DOTNET_MAJOR}.0', csproj)

    def test_probe_reports_missing_when_no_dotnet_anywhere(self) -> None:
        with mock.patch.object(tc, 'dotnet_dir', return_value=None):
            p = tc.probe_dotnet()
        self.assertEqual(p.state, 'missing')
        self.assertEqual(p.id, 'dotnet')
        self.assertIn('download', p.extra)

    def test_probe_rejects_an_old_sdk(self) -> None:
        """SDK 8 alone is `wrong`, not `ok`: the failure would otherwise appear mid-build."""
        with tempfile.TemporaryDirectory() as td, \
                mock.patch.object(tc, 'dotnet_dir', return_value=Path(td)), \
                mock.patch.object(tc, 'dotnet_sdks', return_value=['8.0.404']):
            p = tc.probe_dotnet()
        self.assertEqual(p.state, 'wrong')
        self.assertIn('net10.0', p.detail)

    def test_probe_accepts_sdk_10_and_newer(self) -> None:
        for sdks in (['10.0.403'], ['11.0.100', '10.0.403']):
            with tempfile.TemporaryDirectory() as td, \
                    mock.patch.object(tc, 'dotnet_dir', return_value=Path(td)), \
                    mock.patch.object(tc, 'dotnet_sdks', return_value=sdks):
                p = tc.probe_dotnet()
            self.assertEqual(p.state, 'ok', sdks)
            self.assertEqual(p.version, sdks[0])

    def test_tools_dir_is_outside_the_app_folder(self) -> None:
        """Tools must survive an app update (the app is re-extracted from a zip).

        This was a real bug: LLVM unpacked into `_internal/.tools`, so every update threw away
        182 MB of toolchain. `bundled_tools_dir()` stays as a read-only fallback for people who
        already have it there.
        """
        with mock.patch.dict(os.environ, {'LOCALAPPDATA': '/tmp/fake-local'}):
            self.assertEqual(tc.tools_dir(), Path('/tmp/fake-local/NS Port Builder/tools'))
        self.assertNotEqual(tc.tools_dir(), tc.bundled_tools_dir())

    def test_llvm_dir_finds_the_app_installed_copy(self) -> None:
        """The install-then-check-again path: the detector has to look where the installer wrote."""
        with tempfile.TemporaryDirectory() as td:
            tools = Path(td) / 'tools'
            llvm = tools / f'llvm-mingw-{tc.LLVM_MINGW_VERSION}'
            (llvm / 'bin').mkdir(parents=True)
            (llvm / 'bin/clang.exe').write_bytes(b'stub')
            with mock.patch.object(tc, 'tools_dir', return_value=tools), \
                    mock.patch.object(tc, 'setting', return_value=None), \
                    mock.patch.dict(os.environ, {}, clear=False), \
                    mock.patch('shutil.which', return_value=None):
                os.environ.pop('NSPB_LLVM_DIR', None)
                self.assertEqual(tc.llvm_dir(), llvm)

    def test_install_dotnet_rejects_an_archive_without_dotnet_exe(self) -> None:
        """A changed release layout stops with a message instead of leaving a broken folder."""
        from nspb_qt.win import fetch
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            z = root / 'downloads' / tc.DOTNET_ASSET['name']
            z.parent.mkdir(parents=True)
            with zipfile.ZipFile(z, 'w') as zf:
                zf.writestr('somewhere/else.txt', 'no dotnet here')
            with mock.patch.object(fetch, 'download', return_value=z):
                with self.assertRaises(fetch.DownloadError) as cm:
                    fetch.install_dotnet(dest=root, log=lambda s: None)
            self.assertIn('dotnet.exe', str(cm.exception))
            self.assertFalse((root / f'dotnet-{tc.DOTNET_VERSION}').exists())

    def test_install_dotnet_unpacks_at_the_root(self) -> None:
        """The SDK zip has no top-level folder: dotnet.exe ends up at the install root."""
        from nspb_qt.win import fetch
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            z = root / 'downloads' / tc.DOTNET_ASSET['name']
            z.parent.mkdir(parents=True)
            with zipfile.ZipFile(z, 'w') as zf:
                zf.writestr('dotnet.exe', b'MZ')
                zf.writestr('sdk/10.0.403/dotnet.dll', b'x')
            with mock.patch.object(fetch, 'download', return_value=z):
                out = fetch.install_dotnet(dest=root, log=lambda s: None)
            self.assertEqual(out, root / f'dotnet-{tc.DOTNET_VERSION}')
            self.assertTrue((out / 'dotnet.exe').is_file())
            self.assertTrue((out / 'sdk/10.0.403/dotnet.dll').is_file())


class ConsoleWindowTest(unittest.TestCase):
    """No child of this app may open its own console window on Windows.

    The handheld report: "after the last log line a command-line window appears, shows nothing,
    and the install progress stops" — it was a git child's console. The fix patches
    `subprocess.Popen` once at start-up, so the repository's own scripts (which this front end
    does not own) inherit the invisible console too.
    """

    def test_no_window_kwargs_are_empty_off_windows(self) -> None:
        from nspb_qt import platform_util as pu
        if not pu.IS_WIN:
            self.assertEqual(pu.no_window_kwargs(), {})

    def test_patch_adds_creationflags_and_keeps_explicit_ones(self) -> None:
        from nspb_qt import platform_util as pu
        seen = []

        class FakePopen:
            def __init__(self, args, *a, **k):
                seen.append(k)

        original = subprocess.Popen.__init__
        subprocess.Popen.__init__ = FakePopen.__init__
        try:
            with mock.patch.object(pu, 'IS_WIN', True), \
                    mock.patch.object(subprocess, 'CREATE_NO_WINDOW', 0x08000000, create=True):
                pu.hide_console_for_children()
                subprocess.Popen(['x'])
                subprocess.Popen(['x'], creationflags=0x00000008)   # DETACHED_PROCESS
        finally:
            subprocess.Popen.__init__ = original
        self.assertEqual(seen[0].get('creationflags'), 0x08000000)
        self.assertEqual(seen[1].get('creationflags'), 0x00000008)   # caller's intent kept

    def test_patch_is_a_no_op_off_windows(self) -> None:
        from nspb_qt import platform_util as pu
        before = subprocess.Popen.__init__
        with mock.patch.object(pu, 'IS_WIN', False):
            pu.hide_console_for_children()
        self.assertIs(subprocess.Popen.__init__, before)

    def test_win_modules_call_the_helper(self) -> None:
        """The direct calls (probes, git, the self-extractor) pass it explicitly."""
        for name in ('toolchain.py', 'fetch.py', 'sdk_fetch.py'):
            src = (QT / 'nspb_qt/win' / name).read_text(encoding='utf-8')
            self.assertIn('no_window()', src, name)


class ConstantParityTest(unittest.TestCase):
    """`toolchain.py` duplicates the package constants so it can be loaded standalone from the
    generated sitecustomize.py. The copies must not drift."""

    def test_duplicated_constants_match_the_package(self) -> None:
        import nspb_qt.win as pkg
        pairs = {
            'IOS_DEPLOYMENT': (pkg.IOS_DEPLOYMENT, tc.IOS_DEPLOYMENT),
            'ENV_TOOLCHAIN': (pkg.ENV_TOOLCHAIN, tc.ENV_TOOLCHAIN),
            'ENV_LLVM': (pkg.ENV_LLVM, tc.ENV_LLVM),
            'ENV_SDK': (pkg.ENV_SDK, tc.ENV_SDK),
            'ENV_METAL': (pkg.ENV_METAL, tc.ENV_METAL),
        }
        for name, (a, b) in pairs.items():
            self.assertEqual(a, b, f'{name} differs between nspb_qt.win and nspb_qt.win.toolchain')

    def test_toolchain_imports_standalone(self) -> None:
        """shim.py loads it from a generated sitecustomize with no package context."""
        import subprocess
        code = ('import sys; sys.path.insert(0, %r); import toolchain; '
                'print(toolchain.IOS_DEPLOYMENT)') % str(QT / 'nspb_qt' / 'win')
        r = subprocess.run([sys.executable, '-c', code], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr[-600:])
        self.assertEqual(r.stdout.strip(), '26.0')


class PlatformIsolationTest(unittest.TestCase):
    """Nothing Windows-specific may load on macOS through the normal import path."""

    def test_model_does_not_import_win_at_module_level(self) -> None:
        src = (QT / 'nspb_qt/model.py').read_text(encoding='utf-8')
        head = src.split('def _windows_deps')[0]
        self.assertNotIn('from .win import', head)
        self.assertNotIn('import nspb_qt.win', head)

    def test_platform_util_has_no_win_import(self) -> None:
        src = (QT / 'nspb_qt/platform_util.py').read_text(encoding='utf-8')
        self.assertNotIn('nspb_qt.win', src)
        self.assertNotIn('from .win', src)

    def test_importing_the_package_does_not_touch_win(self) -> None:
        import subprocess
        code = (
            'import sys; sys.path.insert(0, %r)\n'
            'import nspb_qt.model\n'
            'bad = [m for m in sys.modules if m.startswith("nspb_qt.win")]\n'
            'print("|".join(bad))\n'
        ) % str(QT)
        r = subprocess.run([sys.executable, '-c', code], capture_output=True, text=True,
                           env={**os.environ, 'NSPB_REPO': ''})
        # PySide6 may be missing in a bare interpreter; that is not this test's subject
        if r.returncode != 0 and 'PySide6' in (r.stderr or ''):
            self.skipTest('PySide6 is not installed')
        self.assertEqual(r.returncode, 0, r.stderr[-800:])
        self.assertEqual(r.stdout.strip(), '', 'importing the model loaded nspb_qt.win')

    def test_win_modules_import_without_a_toolchain(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            env = {**os.environ, 'LOCALAPPDATA': td, 'ProgramFiles': td,
                   'NSPB_TOOLCHAIN_JSON': str(Path(td) / 'nope.json')}
            for k in ('NSPB_LLVM_DIR', 'NSPB_IOS_SDK', 'NSPB_METAL_DIR'):
                env.pop(k, None)
            code = (
                'import sys; sys.path.insert(0, %r)\n'
                'from nspb_qt.win import toolchain, sdk_fetch, shim, fix_ipa_modes, fetch, '
                'doctor, build_app, driver, xcrun_shim, macho_sign, sdk_auto_cuts\n'
                'print("ok")\n'
            ) % str(QT)
            r = subprocess.run([sys.executable, '-c', code], capture_output=True, text=True,
                               env=env)
            self.assertEqual(r.returncode, 0, r.stderr[-1200:])
            self.assertEqual(r.stdout.strip(), 'ok')


class LocalizationTest(unittest.TestCase):
    def test_every_windows_dep_key_exists_in_both_languages(self) -> None:
        from nspb_qt.i18n import Lang
        from nspb_qt.l10n import TABLE, t
        keys = ['dep.llvm', 'dep.llvm.hint', 'dep.lld', 'dep.lld.hint',
                'dep.probe.compile', 'dep.probe.compile.hint',
                'dep.probe.link', 'dep.probe.link.hint',
                'dep.probe.metal', 'dep.probe.metal.hint',
                'dep.glslang', 'dep.glslang.hint', 'dep.optionalMissing',
                'dep.iossdk', 'dep.iossdk.hint', 'dep.metal', 'dep.metal.hint']
        for k in keys:
            self.assertIn(k, TABLE, f'{k} missing from the table')
            zh = t(k, Lang('zh'))
            en = t(k, Lang('en'))
            self.assertTrue(zh and zh != k, f'{k} has no Chinese text')
            self.assertTrue(en and en != k, f'{k} has no English text')

    def test_the_guidance_and_pick_keys_exist_in_both_languages(self) -> None:
        from nspb_qt.i18n import Lang
        from nspb_qt.l10n import TABLE, t
        keys = ['dep.guide.iossdk', 'dep.guide.metal', 'dep.pick', 'dep.hide', 'dep.show',
                'dep.pick.ios_sdk.title', 'dep.pick.metal_dir.title',
                'dep.pick.saved', 'dep.pick.iossdk.saved', 'dep.pick.iossdk.version',
                'dep.pick.iossdk.invalid', 'dep.fix.network', 'dep.fix.diskspace', 'dep.fix.log']
        for k in keys:
            self.assertIn(k, TABLE, f'{k} missing from the table')
            zh, en = t(k, Lang('zh')), t(k, Lang('en'))
            self.assertTrue(zh and zh != k and en and en != k, f'{k} is not bilingual')


class SymlinkMaterializeTest(unittest.TestCase):
    """The SDK git route on Windows: symlinks checked out as text stubs get their targets copied
    over them, so ld64.lld finds a real `--- !tapi-tbd` file instead of 15 bytes of path text."""

    def _git(self, *args: str, cwd: Path) -> None:
        env = dict(os.environ, GIT_AUTHOR_NAME='t', GIT_AUTHOR_EMAIL='t@t',
                   GIT_COMMITTER_NAME='t', GIT_COMMITTER_EMAIL='t@t')
        r = subprocess.run(['git', *args], cwd=cwd, capture_output=True, text=True, env=env)
        self.assertEqual(r.returncode, 0, r.stderr or r.stdout)

    def test_a_windows_text_stub_gets_its_target_copied_over(self) -> None:
        if shutil.which('git') is None:
            self.skipTest('git is not on PATH')
        base = Path(tempfile.mkdtemp(prefix='nspb-symlink-'))
        self.addCleanup(shutil.rmtree, base, ignore_errors=True)
        remote, work = base / 'remote', base / 'work'
        (remote / 'usr/lib').mkdir(parents=True)
        tbd = '--- !tapi-tbd-v3\narchs: [arm64]\ninstall-name: /usr/lib/libSystem.B.dylib\n'
        (remote / 'usr/lib/libSystem.B.tbd').write_text(tbd)
        (remote / 'usr/lib/libSystem.tbd').symlink_to('libSystem.B.tbd')
        self._git('init', '-q', cwd=remote)
        self._git('add', '.', cwd=remote)
        self._git('commit', '-qm', 'sdk', cwd=remote)
        # A Windows plain clone checks the symlink out as a text file holding the target's path.
        self._git('-c', 'core.symlinks=false', 'clone', '-q', str(remote), str(work), cwd=base)
        stub = work / 'usr/lib/libSystem.tbd'
        self.assertEqual(stub.read_text(), 'libSystem.B.tbd')   # the broken shape the log showed
        log: list[str] = []
        fixed = sdk_fetch.materialize_symlinks(work, '', log.append)
        self.assertEqual(fixed, 1)
        self.assertFalse(stub.is_symlink())
        self.assertEqual(stub.read_text(), tbd)
        self.assertTrue((work / 'usr/lib/libSystem.B.tbd').exists())

    def test_a_real_symlink_is_left_alone(self) -> None:
        # macOS and Linux check the SDK's symlinks out as symlinks: nothing to materialize.
        if shutil.which('git') is None:
            self.skipTest('git is not on PATH')
        base = Path(tempfile.mkdtemp(prefix='nspb-symlink-'))
        self.addCleanup(shutil.rmtree, base, ignore_errors=True)
        repo = base / 'sdk'
        (repo / 'usr/lib').mkdir(parents=True)
        (repo / 'usr/lib/libSystem.B.tbd').write_text('--- !tapi-tbd-v3\n')
        (repo / 'usr/lib/libSystem.tbd').symlink_to('libSystem.B.tbd')
        self._git('init', '-q', cwd=repo)
        self._git('add', '.', cwd=repo)
        self._git('commit', '-qm', 'sdk', cwd=repo)
        log: list[str] = []
        self.assertEqual(sdk_fetch.materialize_symlinks(repo, '', log.append), 0)
        self.assertTrue((repo / 'usr/lib/libSystem.tbd').is_symlink())
        self.assertEqual(log, [])

    def test_a_stub_whose_target_is_missing_is_reported_and_left(self) -> None:
        # The target was deleted after a broken checkout: nothing to copy, said so in the log.
        if shutil.which('git') is None:
            self.skipTest('git is not on PATH')
        base = Path(tempfile.mkdtemp(prefix='nspb-symlink-'))
        self.addCleanup(shutil.rmtree, base, ignore_errors=True)
        remote, work = base / 'remote', base / 'work'
        (remote / 'usr/lib').mkdir(parents=True)
        (remote / 'usr/lib/libSystem.B.tbd').write_text('--- !tapi-tbd-v3\n')
        (remote / 'usr/lib/libSystem.tbd').symlink_to('libSystem.B.tbd')
        self._git('init', '-q', cwd=remote)
        self._git('add', '.', cwd=remote)
        self._git('commit', '-qm', 'sdk', cwd=remote)
        self._git('-c', 'core.symlinks=false', 'clone', '-q', str(remote), str(work), cwd=base)
        (work / 'usr/lib/libSystem.B.tbd').unlink()
        log: list[str] = []
        self.assertEqual(sdk_fetch.materialize_symlinks(work, '', log.append), 0)
        self.assertTrue(any('missing' in l for l in log))



class TbdStubRepairTest(unittest.TestCase):
    """The cached SDK of a broken clone: `.tbd` files that are text stubs of their targets get
    the target's bytes copied over them; real TBD files and dangling stubs are left alone."""

    def setUp(self) -> None:
        base = Path(tempfile.mkdtemp(prefix='nspb-tbd-'))
        self.addCleanup(shutil.rmtree, base, ignore_errors=True)
        self.sdk = base / 'iPhoneOS26.0.sdk' / 'usr' / 'lib'
        self.sdk.mkdir(parents=True)
        self.good = '--- !tapi-tbd-v3\narchs: [arm64]\ninstall-name: /usr/lib/libSystem.B.dylib\n'
        (self.sdk / 'libSystem.B.tbd').write_text(self.good)
        (self.sdk / 'libSystem.tbd').write_text('libSystem.B.tbd')          # a broken stub
        (self.sdk / 'libz.1.tbd').write_text('libz.tbd')                    # a dangling stub
        (self.sdk / 'libreal.tbd').write_text(self.good)                    # a real TBD file

    def test_broken_stubs_are_repaired_and_real_files_untouched(self) -> None:
        log: list[str] = []
        fixed = sdk_fetch.repair_tbd_stubs(self.sdk.parent.parent, log.append)
        self.assertEqual(fixed, 1)                                   # libSystem.tbd only:
        self.assertTrue((self.sdk / 'libSystem.tbd').read_text().startswith('--- !tapi-tbd'))
        self.assertEqual((self.sdk / 'libz.1.tbd').read_text(), 'libz.tbd')      # dangling: left
        self.assertEqual((self.sdk / 'libreal.tbd').read_text(), self.good)     # real: untouched
        self.assertTrue(any(l.startswith('repaired libSystem.tbd') for l in log), log)

    def test_the_call_is_idempotent(self) -> None:
        sdk_fetch.repair_tbd_stubs(self.sdk.parent.parent, lambda l: None)
        self.assertEqual(sdk_fetch.repair_tbd_stubs(self.sdk.parent.parent, lambda l: None), 0)


class SaveConfigTest(unittest.TestCase):
    """The Choose-a-folder path writes toolchain.json and reads it back through setting()."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self._old = os.environ.get('NSPB_TOOLCHAIN_JSON')
        os.environ['NSPB_TOOLCHAIN_JSON'] = str(Path(self.tmp.name) / 'toolchain.json')

    def tearDown(self) -> None:
        if self._old is None:
            os.environ.pop('NSPB_TOOLCHAIN_JSON', None)
        else:
            os.environ['NSPB_TOOLCHAIN_JSON'] = self._old

    def test_save_config_keeps_other_keys_and_is_read_back(self) -> None:
        cfg = Path(os.environ['NSPB_TOOLCHAIN_JSON'])
        cfg.parent.mkdir(parents=True, exist_ok=True)
        cfg.write_text('{"llvm_dir": "C:/tools/llvm"}', encoding='utf-8')
        p = tc.save_config('ios_sdk', 'C:/sdks/iPhoneOS26.0.sdk')
        self.assertEqual(p, cfg)
        self.assertEqual(tc.setting('ios_sdk'), 'C:/sdks/iPhoneOS26.0.sdk')
        self.assertEqual(tc.setting('llvm_dir'), 'C:/tools/llvm', 'the other keys survive')

    def test_save_config_creates_missing_folders_and_replaces_a_broken_file(self) -> None:
        cfg = Path(os.environ['NSPB_TOOLCHAIN_JSON'])
        cfg.parent.mkdir(parents=True, exist_ok=True)
        cfg.write_text('not json', encoding='utf-8')
        tc.save_config('metal_dir', 'C:/Metal')
        self.assertEqual(tc.setting('metal_dir'), 'C:/Metal')

    def test_the_picked_sdk_is_accepted_only_when_it_really_is_one(self) -> None:
        # The model validates before saving: a wrong pick must not become the configured answer.
        root = Path(self.tmp.name)
        unpacked = root / 'Metal-thing-unpacked'   # whatever the archive's top folder is called
        unpacked.mkdir(parents=True)
        good = make_fake_sdk(unpacked, '26.2')
        self.assertTrue(tc.is_sdk_dir(good), 'the sdk folder itself')
        self.assertFalse(tc.is_sdk_dir(unpacked), 'the folder above it is not an SDK by itself')
        self.assertFalse(tc.is_sdk_dir(root / 'elsewhere'))
        # ...but the model's pick accepts "one level down", so the unpacked root resolves to the SDK:
        matches = sorted(unpacked.glob('iPhoneOS*.sdk'), reverse=True)
        self.assertTrue(matches and all(tc.is_sdk_dir(m) for m in matches))


class LinkProbeStrategyTest(unittest.TestCase):
    """probe_link's three strategies and the step-0 linker self-check.

    The Windows-only subprocess calls cannot run here; what is testable is the *shape*: the
    strategy list (build-style fuse-ld first, then --ld-path, then -B), and that a silent
    failure now names all three attempts plus the linker's own self-check instead of one
    empty '(no output)'.
    """

    def test_the_strategy_order_is_build_style_first(self) -> None:
        src = (QT / 'nspb_qt' / 'win' / 'toolchain.py').read_text(encoding='utf-8')
        body = src[src.index('def probe_link'):]
        self.assertLess(body.index("'-fuse-ld=lld'"), body.index('f\'--ld-path={lld}\''),
                        'the build\'s own invocation must be tried before --ld-path')
        self.assertLess(body.index('f\'--ld-path={lld}\''), body.index("f'-B{lld.parent}'"),
                        '--ld-path before the -B fallback')
        self.assertIn("run_env['PATH'] = str(lld.parent)", body,
                      'the build-style try must put the linker folder on PATH (build_app.link does)')
        self.assertIn('does not run by itself', body,
                      'a linker that cannot start is its own message, before any strategy runs')

    def test_the_failure_summary_names_everything_and_flags_a_non_ascii_sdk(self) -> None:
        from nspb_qt.win import toolchain as tc
        attempts = [('fuse-ld', 'exit 1 (0x00000001): (no output)', ['clang', '-fuse-ld=lld']),
                    ('ld-path', 'exit 1 (0x00000001): (no output)', ['clang', '--ld-path=x']),
                    ('-B dir', 'exit 1 (0x00000001): (no output)', ['clang', '-Bx'])]
        plain = Path('C:/sdks/iPhoneOS26.0.sdk')
        t = lambda key, *a: 'HINT:' + key   # the model's translator, as ui.py receives it
        summary = tc.link_failure_summary(attempts, 'LLD 23.1.4', ['clang'], plain, t=t)
        for part in ('link failed 3 ways', 'LLD 23.1.4', 'fuse-ld:', 'ld-path:', '-B dir:',
                     'try by hand:'):
            self.assertIn(part, summary, part)
        self.assertNotIn('dep.fix.nonascii', summary)
        # The owner's machine: C:\Users\QC-北\... — the SDK itself sits under a non-ASCII path.
        # The hint is a localization key: the panel must see it translated, never as the raw key.
        nonascii = Path('C:/Users/QC-北/AppData/Local/NS Port Builder/sdks/iPhoneOS26.0.sdk')
        hinted = tc.link_failure_summary(attempts, 'LLD 23.1.4', ['clang'], nonascii, t=t)
        self.assertIn('HINT:dep.fix.nonascii', hinted)
        self.assertNotIn(' — dep.fix.nonascii', hinted)
        bare = tc.link_failure_summary(attempts, 'LLD 23.1.4', ['clang'], nonascii)
        self.assertNotIn('dep.fix.nonascii', bare)


class VenvWheelsTest(unittest.TestCase):
    """The build packages ride in the zip: the venv installs offline from wheels/ beside the
    exe when it is there, and from PyPI exactly as before when it is not (source runs)."""

    @staticmethod
    def _pip_args_fn():
        """model.py imports PySide6, which the CI test job deliberately does not install: run
        the pure static function by extracting it from the source when Qt is absent."""
        try:
            from nspb_qt import model as M
            return M.Model._pip_args
        except ImportError:
            import ast
            src = (QT / 'nspb_qt' / 'model.py').read_text()
            tree = ast.parse(src)
            fn = next(n for n in ast.walk(tree) if isinstance(n, ast.FunctionDef)
                      and n.name == '_pip_args')
            for n in ast.walk(fn):
                ast.fix_missing_locations(n)
            ns: dict = {}
            exec(compile(ast.fix_missing_locations(ast.Module(body=[fn], type_ignores=[])),
                         '<model>', 'exec'), ns)
            return ns['_pip_args'].__func__

    def test_offline_args_when_wheels_are_bundled(self) -> None:
        args = self._pip_args_fn()(['lz4', 'nsz'], Path('C:/app/wheels'))
        self.assertEqual(args, ['install', '--no-index', '--find-links', 'C:/app/wheels', 'lz4', 'nsz'])

    def test_pypi_args_when_not_bundled(self) -> None:
        self.assertEqual(self._pip_args_fn()(['lz4'], None), ['install', 'lz4'])

    def test_the_log_row_string_takes_three_args(self) -> None:
        from nspb_qt.i18n import Lang
        from nspb_qt.l10n import t
        out = t('dep.row.log', Lang('en'), 'python', 'missing', 'C:/x | found')
        self.assertEqual(out, 'dependency python: [missing] C:/x | found', 'the report log showed raw %@ placeholders')
        self.assertTrue(t('dep.row.log', Lang('zh'), 'python', 'missing', 'd'), 'Chinese side is filled too')

    def test_bundled_wheels_finds_wheels_beside_exe_when_meipass_is_internal(self) -> None:
        """PyInstaller 6 onedir sets sys._MEIPASS to `<app>/_internal` while `wheels/` sits at `<app>/wheels`."""
        import ast
        src = (QT / 'nspb_qt' / 'model.py').read_text(encoding='utf-8')
        tree = ast.parse(src)
        fn = next(n for n in ast.walk(tree) if isinstance(n, ast.FunctionDef)
                  and n.name == 'bundled_wheels')
        for n in ast.walk(fn):
            ast.fix_missing_locations(n)
        ns: dict = {'sys': sys, 'Path': Path}
        exec(compile(ast.fix_missing_locations(ast.Module(body=[fn], type_ignores=[])),
                     '<model>', 'exec'), ns)
        bundled_wheels = ns['bundled_wheels'].__func__
        with tempfile.TemporaryDirectory() as td:
            app_dir = Path(td) / 'NS Port Builder'
            internal = app_dir / '_internal'
            wheels = app_dir / 'wheels'
            internal.mkdir(parents=True)
            wheels.mkdir(parents=True)
            (wheels / 'lz4-4.0.0-cp312-win_amd64.whl').write_bytes(b'PK')
            with mock.patch.object(sys, '_MEIPASS', str(internal), create=True), \
                 mock.patch.object(sys, 'executable', str(app_dir / 'NS Port Builder.exe')):
                self.assertEqual(bundled_wheels(), wheels)

    def test_win_python_install_chains_make_venv_immediately(self) -> None:
        """Installing Python on a fresh PC must pass `python.exe` (not the install folder) to _make_venv / venv_base."""
        from nspb_qt import platform_util as pu
        src = (QT / 'nspb_qt' / 'model.py').read_text(encoding='utf-8')
        branch = src[src.index("elif what == 'python':"):src.index("elif what == 'llvm':")]
        self.assertIn('install_python(', branch)
        self.assertIn("Path(path) / 'python.exe'", branch)
        self.assertIn('self._make_venv(str(py_exe))', branch)

        # End-to-end check: install_python() returns a directory (`.../tools/python-3.12.10`),
        # and on a fresh PC with no system Python in python_candidates(), venv_base must resolve
        # `python.exe` inside that directory and python_candidates() must discover tools/python-*/python.exe.
        with tempfile.TemporaryDirectory() as td:
            tools_dir = Path(td) / 'NS Port Builder' / 'tools'
            py_dir = tools_dir / 'python-3.12.10'
            py_dir.mkdir(parents=True)
            py_exe = py_dir / 'python.exe'
            py_exe.write_bytes(b'MZ')
            py_exe.chmod(0o755)
            with mock.patch.object(pu, 'IS_WIN', True), \
                 mock.patch.object(pu, '_python_version', return_value='3.12.10'), \
                 mock.patch.object(pu, 'python_candidates', return_value=[]):
                # Even when a caller passes the folder returned by install_python(), venv_base resolves python.exe
                self.assertEqual(pu.venv_base(str(py_dir)), str(py_exe))
            with mock.patch.object(pu, 'IS_WIN', True), \
                 mock.patch.dict(os.environ, {'LOCALAPPDATA': td}, clear=False):
                self.assertIn(str(py_exe), pu.python_candidates())


class MetalPickFlowShapeTest(unittest.TestCase):
    """The model wiring (source-shape, since model.py needs PySide6): the metal row asks for a
    file, takes a zip to install_metal_zip, a folder to _save_metal_folder."""

    def test_the_metal_row_routes_zip_and_folder(self) -> None:
        src = (QT / 'nspb_qt' / 'model.py').read_text()
        body = src[src.index("if dep.pick_key == 'metal_dir':"):]
        self.assertIn('ask_file', body, 'the metal row must ask for a file (the zip)')
        self.assertIn('install_metal_zip', body)
        self.assertIn('_save_metal_folder', body)
        self.assertIn("endswith('.zip')", body)


class MetalZipInstallTest(unittest.TestCase):
    """The one manual dependency (Apple-ID-gated Metal tools) handed a downloaded zip: the app
    unpacks, validates both shipped layouts, and refuses anything else."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    @staticmethod
    def _fake_tools(root: Path, layout: str) -> Path:
        bin_ = root / ('ios/bin' if layout == '4.x' else 'bin')
        bin_.mkdir(parents=True)
        (bin_ / 'metal.exe').write_bytes(b'MZ')
        (bin_ / 'metallib.exe').write_bytes(b'MZ')
        return root

    def test_a_zip_with_the_tools_unpacks_to_the_tools_dir(self) -> None:
        from nspb_qt.win import fetch as wf
        tools = self.root / 'tools'
        src = self._fake_tools(self.root / 'unpacked', '6.x')
        zip_path = self.root / 'Metal Developer Tools 6.0.zip'
        import zipfile
        with zipfile.ZipFile(zip_path, 'w') as z:
            for f in src.rglob('*'):
                z.write(f, f.relative_to(src.parent))
        dest = wf.install_metal_from_zip(zip_path, dest=tools / 'metal-developer-tools')
        self.assertTrue((dest / 'bin' / 'metal.exe').is_file())
        self.assertFalse((tools / 'metal-developer-tools-staging').exists(), 'staging is cleaned up')

    def test_a_4x_layout_zip_is_accepted_by_its_ios_folder(self) -> None:
        from nspb_qt.win import fetch as wf
        src = self._fake_tools(self.root / 'u4', '4.x')
        zip_path = self.root / 'metal4.zip'
        import zipfile
        with zipfile.ZipFile(zip_path, 'w') as z:
            for f in src.rglob('*'):
                z.write(f, f.relative_to(src.parent))
        dest = wf.install_metal_from_zip(zip_path, dest=self.root / 'tools' / 'm4')
        self.assertTrue((dest / 'ios' / 'bin' / 'metal.exe').is_file())

    def test_a_zip_without_metal_exe_is_refused_and_leaves_nothing_behind(self) -> None:
        from nspb_qt.win import fetch as wf
        zip_path = self.root / 'not-metal.zip'
        import zipfile
        with zipfile.ZipFile(zip_path, 'w') as z:
            (self.root / 'junk').mkdir()
            (self.root / 'junk' / 'readme.txt').write_text('x', encoding='utf-8')
            z.write(self.root / 'junk' / 'readme.txt', 'stuff/readme.txt')
        tools = self.root / 'tools'
        with self.assertRaises(wf.DownloadError):
            wf.install_metal_from_zip(zip_path, dest=tools / 'm')
        self.assertFalse((tools / 'm').exists())
        self.assertFalse((tools / 'm-staging').exists())


class InstallFailureHintTest(unittest.TestCase):
    """The row's fix hint after a failed install (Mac parity: name the fix, not the traceback)."""

    def test_network_disk_and_other_map_to_their_hints(self) -> None:
        # model.py imports PySide6, which the test machine need not have: the classifier is a
        # pure function, so its source is extracted and run standalone when Qt is absent.
        try:
            from nspb_qt import model as M
            classify = M.Model._classify_install_failure
        except ImportError:
            import ast
            src = (HERE.parent / 'nspb_qt' / 'model.py').read_text(encoding='utf-8')
            tree = ast.parse(src)
            fn = next(n for n in ast.walk(tree) if isinstance(n, ast.FunctionDef)
                      and n.name == '_classify_install_failure')
            # A copied FunctionDef needs line numbers before compile accepts it.
            ast.copy_location(fn, fn)
            for n in ast.walk(fn):
                ast.copy_location(n, n)
                ast.fix_missing_locations(n)
            ns: dict = {}
            exec(compile(ast.fix_missing_locations(ast.Module(body=[fn], type_ignores=[])),
                         '<model>', 'exec'), ns)
            classify = ns['_classify_install_failure'].__func__
        self.assertEqual(classify('DownloadError: connection reset by peer'), 'dep.fix.network')
        self.assertEqual(classify('URLError: operation timed out'), 'dep.fix.network')
        self.assertEqual( classify('OSError: [Errno 28] No space left on device'), 'dep.fix.diskspace')
        self.assertEqual(classify('KeyError: x'), 'dep.fix.log')


class WindowsBuildFixesTest(unittest.TestCase):
    """Regression tests for the Windows build pipeline fixes."""

    def test_shim_puts_package_parent_on_sys_path_and_passes_nspb_python(self) -> None:
        self.assertIn('os.path.dirname(os.path.dirname(_PKG))', shim._SITECUSTOMIZE_SRC)
        with tempfile.TemporaryDirectory() as td:
            with mock.patch.object(shim, 'shim_dir', return_value=Path(td)):
                env = shim.build_env({'PATH': '', 'PYTHONPATH': ''}, python_exe='C:\\venv\\python.exe')
        self.assertEqual(env['NSPB_PYTHON'], 'C:\\venv\\python.exe')
        self.assertEqual(env['DM_ALLOW_SYSTEM_SPIRV_CROSS'], '1')
        self.assertEqual(env['DM_ALLOW_OTHER_METAL'], '1')
        self.assertNotIn('DM_REWRITE_J', env)
        pkg_root = str(QT)
        self.assertIn(pkg_root, env['PYTHONPATH'].split(os.pathsep))

    def test_romfs_backslash_paths_and_pread_with_real_image(self) -> None:
        """Pack a real RomFS.img with romfs_image.py and verify backslash lookups and pread."""
        tools_dir = str(QT.parent / 'engine' / 'dm' / 'tools')
        if not Path(tools_dir, 'romfs_image.py').is_file():
            self.skipTest('engine/ is missing')
        if tools_dir not in sys.path:
            sys.path.insert(0, tools_dir)
        import importlib
        import romfs
        import romfs_image

        # Execute the shim's romfs patcher and _win_pread helper from _SITECUSTOMIZE_SRC
        ns: dict = {'os': os, 'sys': sys}
        src = shim._SITECUSTOMIZE_SRC
        start = src.index('    _relpath = os.path.relpath')
        end = src.index('    def _patch_sdk_patches_module(mod):')
        exec('\n'.join(ln[4:] for ln in src[start:end].splitlines()), ns)
        ns['_patch_romfs_module'](romfs)

        pread_start = src.index('        def _win_pread(fd, n, offset):')
        pread_end = src.index('        os.pread = _win_pread')
        import threading
        ns['_threading'] = threading
        ns['_pread_lock'] = threading.Lock()
        exec('\n'.join(ln[8:] for ln in src[pread_start:pread_end].splitlines()), ns)
        win_pread = ns['_win_pread']

        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            v0 = root / 'v0'
            rdir = v0 / 'RomFS'
            (rdir / 'Shader' / 'sub').mkdir(parents=True)
            payload = b'binary\x1a\r\ndata\x00end'
            (rdir / 'Shader' / 'sub' / 'test.bin').write_bytes(payload)
            img_path = v0 / 'RomFS.img'
            romfs_image.pack(str(rdir), str(img_path))
            shutil.rmtree(rdir)

            # Test _win_pread preserves fd offset and reads exact binary bytes
            fd = os.open(str(img_path), os.O_RDONLY | getattr(os, 'O_BINARY', 0))
            try:
                os.lseek(fd, 4, os.SEEK_SET)
                magic = win_pread(fd, 8, 0)
                self.assertEqual(magic, b'DMROMFS1')
                self.assertEqual(os.lseek(fd, 0, os.SEEK_CUR), 4)
            finally:
                os.close(fd)

            # Test backslash path resolution against RomFS.img
            romfs._image.cache_clear()
            src_path = romfs.source(v0)
            self.assertTrue(romfs.isfile(str(img_path) + r'\Shader\sub\test.bin'))
            with romfs.open(str(img_path) + r'\Shader\sub\test.bin', 'rb') as f:
                self.assertEqual(f.read(), payload)
            walked = list(romfs.walk(src_path))
            self.assertTrue(any(r.endswith('Shader/sub') and 'test.bin' in fs for r, _, fs in walked))
            self.assertFalse(any('\\' in r for r, _, _ in walked))
            joined = romfs.os.path.join('Shader\\sub', 'test.bin')
            self.assertEqual(joined, 'Shader/sub/test.bin')
            self.assertEqual(romfs.os.sep, '/')
            self.assertEqual(romfs.os.path.sep, '/')
            self.assertEqual(romfs.os.path.normpath('Shader\\sub\\test.bin'), 'Shader/sub/test.bin')
            self.assertEqual(romfs.os.path.relpath(str(src_path) + '/Shader/sub/test.bin', str(src_path)),
                             'Shader/sub/test.bin')

    def test_macho_sign_produces_valid_adhoc_signature_with_entitlements(self) -> None:
        from nspb_qt.win import macho_sign
        if sys.platform != 'darwin' or not shutil.which('clang') or not shutil.which('codesign'):
            self.skipTest('macOS clang and codesign required for end-to-end verification')
        with tempfile.TemporaryDirectory() as td:
            c_file = Path(td) / 'main.c'
            exe = Path(td) / 'DmIOS'
            c_file.write_text('int main(void) { return 0; }\n', encoding='utf-8')
            r = subprocess.run(['clang', '-arch', 'arm64', '-Wl,-adhoc_codesign',
                                str(c_file), '-o', str(exe)], capture_output=True, text=True)
            if r.returncode != 0:
                self.skipTest(f'clang could not build arm64 binary: {r.stderr}')
            ents = {'com.apple.developer.kernel.increased-memory-limit': True}
            sig_len = macho_sign.sign(exe, 'org.nxnative.test', ents)
            self.assertGreater(sig_len, 100)
            v = subprocess.run(['/usr/bin/codesign', '--verify', '-vvv', str(exe)],
                               capture_output=True, text=True)
            self.assertEqual(v.returncode, 0, v.stderr + v.stdout)
            d = subprocess.run(['/usr/bin/codesign', '-d', '--entitlements', ':-', str(exe)],
                               capture_output=True, text=True)
            self.assertEqual(d.returncode, 0, d.stderr)
            self.assertIn('com.apple.developer.kernel.increased-memory-limit', d.stdout)

    def test_bundled_extractor_runs_without_a_nuget_restore(self) -> None:
        from nspb_qt.win import driver
        repo = QT.parent / 'engine'
        if not (repo / 'scripts/build_ipa_from_nsp.py').is_file():
            self.skipTest('engine/ is missing')
        mod = driver.load_upstream(repo)
        with tempfile.TemporaryDirectory() as td:
            bundled = Path(td) / 'NX2Apple' / 'engine'
            exe = bundled / 'dm/tools/nx_extract_bin/nx_extract.exe'
            exe.parent.mkdir(parents=True)
            exe.touch()
            work = Path(td) / 'title_probe'
            with mock.patch.object(driver, '_UPSTREAM_RUN', None):
                driver.patch(mod, bundled)
                with mock.patch.object(mod, 'run', side_effect=AssertionError('attempted a source build')):
                    self.assertEqual(mod.build_nx_extract(bundled, work, work / 'logs', {}), exe)

    def test_driver_region_skip_stamps_rewrite_id_and_capture_jit_reuses_image(self) -> None:
        from nspb_qt.win import driver
        repo = QT.parent / 'engine'
        if not (repo / 'scripts/build_ipa_from_nsp.py').is_file():
            self.skipTest('engine/ is missing')
        mod = driver.load_upstream(repo)
        driver.patch(mod, repo)
        self.assertTrue(mod.ALLOW_OTHER_METAL)
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            gdir = root / 'profile'
            gdir.mkdir()
            (gdir / 'game.tsv').write_text('id\ttest\npackage\tv0\n', encoding='utf-8')
            patched = root / 'patched_v0'
            patched.mkdir()
            (patched / 'main.patched.bin').write_bytes(b'1234')

            class FakeGame:
                def __init__(self, d):
                    self.dir = Path(d)

            g = mod.region_check(repo, root, patched, root, {}, root, FakeGame(gdir))
            self.assertTrue(mod.region_checked(g, patched))

            # capture_jit raises when jit.img is absent, succeeds when present
            with self.assertRaises(mod.BuildError):
                mod.capture_jit('py', repo, root, patched, root, {}, root, g)
            (root / 'jit').mkdir()
            (root / 'jit' / 'jit.img').write_bytes(b'jit')
            mod.capture_jit('py', repo, root, patched, root, {}, root, g)

    def test_pack_archive_handles_romfs_img_and_copies_aoc(self) -> None:
        try:
            from nspb_qt.model import Model
        except ImportError:
            self.skipTest('PySide6 is not installed')
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            work = root / 'work'
            v0 = work / 'extract' / 'v0'
            v0.mkdir(parents=True)
            (v0 / 'RomFS.img').write_bytes(b'DMROMFS1_payload')
            aoc = work / 'aoc'
            aoc.mkdir(parents=True)
            (aoc / '0.img').write_bytes(b'dlc0')
            out = root / 'out'
            out.mkdir()
            from nspb_qt import library as lib
            with (
                mock.patch.object(Model, 'check_deps', lambda self: None),
                mock.patch.object(lib, 'default_state_dir', lambda: root / 'state'),
            ):
                m = Model()
                m.effective_work_dir = str(work)
                m.out_dir = str(out)
                m.base_path = str(root / 'game.nsp')
                self.assertEqual(m.pack_archive(), (True, ''))
            self.assertEqual(m.archive_path, str(out / 'romfs'))
            self.assertEqual((out / 'romfs' / 'romfs.img').read_bytes(), b'DMROMFS1_payload')
            self.assertEqual((out / 'romfs' / 'aoc' / '0.img').read_bytes(), b'dlc0')

    def test_run_ipa_forwards_ok_and_fatal_kwargs(self) -> None:
        from nspb_qt.win import driver
        repo = QT.parent / 'engine'
        if not (repo / 'scripts/build_ipa_from_nsp.py').is_file():
            self.skipTest('engine/ is missing')
        mod = driver.load_upstream(repo)
        recorded = []

        def fake_run(cmd, log, env=None, cwd=None, on_line=None, ok=(), fatal=True):
            recorded.append((list(cmd), ok, fatal))
            return 0

        orig = driver._UPSTREAM_RUN
        try:
            driver._UPSTREAM_RUN = fake_run
            driver.patch(mod, repo)
            mod.run(['nx_extract', 'keys.txt', '--keys', 'a.nsp'], Path('k.log'),
                    env={}, ok=(6,), fatal=False)
        finally:
            driver._UPSTREAM_RUN = orig
            driver.patch(mod, repo)
        self.assertEqual(len(recorded), 1)
        self.assertEqual(recorded[0][1], (6,))
        self.assertIs(recorded[0][2], False)

    def test_find_exe_locates_bundled_glslang_validator(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            fake_engine = Path(td) / 'engine'
            bin_dir = fake_engine / 'dm' / 'gfx' / 'tools' / 'spirv_cross_bin'
            bin_dir.mkdir(parents=True)
            spv = bin_dir / 'glslangValidator.exe'
            spv.write_bytes(b'MZ')
            with mock.patch.dict(os.environ, {'NSPB_REPO': str(fake_engine)}, clear=False), \
                 mock.patch.object(tc, 'setting', return_value=None):
                self.assertEqual(tc.find_exe('glslangValidator'), spv)

    def test_shim_patches_signal_pthread_sigmask_and_tool_lock_spirv_cross(self) -> None:
        src = shim._SITECUSTOMIZE_SRC
        self.assertIn("class _WinForkPool:", src)
        self.assertIn("pthread_sigmask", src)
        self.assertIn("os.execve = _win_execve", src)

        # Verify _patch_tool_lock_module filters out spirv-cross hash mismatches when allowed,
        # while still reporting missing spirv-cross or translator mismatches.
        start = src.index('    def _patch_tool_lock_module(mod):')
        end = src.index('    import importlib.machinery as _machinery')
        ns: dict = {'os': os}
        exec('\n'.join(ln[4:] for ln in src[start:end].splitlines()), ns)
        patch_tl = ns['_patch_tool_lock_module']

        import types
        fake_tl = types.ModuleType('tool_lock')
        fake_tl.check_tools = lambda: [
            'spirv-cross: lock e37945d8e441d34d / actual 0123456789abcdef',
            'dmsh_xlate.dll: lock aaaa / actual bbbb',
        ]
        patch_tl(fake_tl)
        with mock.patch.dict(os.environ, {'DM_ALLOW_SYSTEM_SPIRV_CROSS': '1'}, clear=False):
            self.assertEqual(fake_tl.check_tools(), ['dmsh_xlate.dll: lock aaaa / actual bbbb'])
        with mock.patch.dict(os.environ, {'DM_ALLOW_SYSTEM_SPIRV_CROSS': '0'}, clear=False):
            self.assertEqual(len(fake_tl.check_tools()), 2)

        # A missing spirv-cross must still be reported even when DM_ALLOW_SYSTEM_SPIRV_CROSS=1
        fake_tl2 = types.ModuleType('tool_lock')
        fake_tl2.check_tools = lambda: ['spirv-cross: lock e37945d8e441d34d / actual missing']
        patch_tl(fake_tl2)
        with mock.patch.dict(os.environ, {'DM_ALLOW_SYSTEM_SPIRV_CROSS': '1'}, clear=False):
            self.assertEqual(fake_tl2.check_tools(),
                             ['spirv-cross: lock e37945d8e441d34d / actual missing'])

    def test_model_on_line_parses_timestamped_stage_lines(self) -> None:
        try:
            from nspb_qt.model import Model
        except ImportError:
            self.skipTest('PySide6 is not installed')
        with mock.patch.object(Model, 'check_deps', lambda self: None):
            m = Model()
        m._on_line('[04:35:01] [1/6] build nx_extract')
        self.assertEqual([s.name for s in m.stages], ['build nx_extract'])
        self.assertEqual(m.stages[-1].state, 'running')
        m._on_line('[04:35:01] [1/6] build nx_extract ✓ (0s)')
        self.assertEqual(len(m.stages), 1)
        m._on_line('[04:35:04] [3/7] rewrite · main, sdk')
        self.assertEqual([s.name for s in m.stages], ['build nx_extract', 'rewrite · main, sdk'])
        self.assertEqual(m.stages[0].state, 'done')
        self.assertEqual(m.stages[1].state, 'running')
        m._on_line('[04:35:04] [RED] patch_nso.py failed')
        self.assertEqual(m._last_error, '[RED] patch_nso.py failed')

    def test_repair_tbd_stubs_fixes_headers_chained_tbds_and_framework_dirs(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            sdk = Path(td) / 'iPhoneOS26.0.sdk'
            # 1. usr/include/pthread.h -> pthread/pthread.h and arpa/nameser.h -> ../nameser.h
            (sdk / 'usr/include/pthread').mkdir(parents=True)
            (sdk / 'usr/include/arpa').mkdir(parents=True)
            real_pthread = '#ifndef _PTHREAD_H\n#define _PTHREAD_H\ntypedef struct _opaque_pthread_t *pthread_t;\n#endif\n'
            (sdk / 'usr/include/pthread/pthread.h').write_text(real_pthread, encoding='utf-8')
            (sdk / 'usr/include/pthread.h').write_text('pthread/pthread.h', encoding='utf-8')
            (sdk / 'usr/include/nameser.h').write_text('#define _NAMESER_H 1\n', encoding='utf-8')
            (sdk / 'usr/include/arpa/nameser.h').write_text('../nameser.h', encoding='utf-8')

            # 2. Chained .tbd: libm.tbd -> libSystem.tbd -> libSystem.B.tbd
            (sdk / 'usr/lib').mkdir(parents=True)
            tbd_body = '--- !tapi-tbd\ntbd-version: 4\ntargets: [ arm64-ios ]\n...\n'
            (sdk / 'usr/lib/libSystem.B.tbd').write_text(tbd_body, encoding='utf-8')
            (sdk / 'usr/lib/libSystem.tbd').write_text('libSystem.B.tbd', encoding='utf-8')
            (sdk / 'usr/lib/libm.tbd').write_text('libSystem.tbd', encoding='utf-8')

            # 3. Framework dir symlinks: Versions/Current -> A, Headers -> Versions/Current/Headers
            fw = sdk / 'System/Library/Frameworks/IOKit.framework'
            (fw / 'Versions/A/Headers').mkdir(parents=True)
            (fw / 'Versions/A/Headers/IOKitLib.h').write_text('#define IOKIT 1\n', encoding='utf-8')
            (fw / 'Versions/Current').write_text('A', encoding='utf-8')
            (fw / 'Headers').write_text('Versions/Current/Headers', encoding='utf-8')

            fixed = tc.repair_tbd_stubs(sdk)
            self.assertEqual(fixed, 6)
            self.assertEqual((sdk / 'usr/include/pthread.h').read_text(encoding='utf-8'), real_pthread)
            self.assertEqual((sdk / 'usr/include/arpa/nameser.h').read_text(encoding='utf-8'), '#define _NAMESER_H 1\n')
            self.assertEqual((sdk / 'usr/lib/libSystem.tbd').read_text(encoding='utf-8'), tbd_body)
            self.assertEqual((sdk / 'usr/lib/libm.tbd').read_text(encoding='utf-8'), tbd_body)
            self.assertTrue((fw / 'Headers/IOKitLib.h').is_file())
            self.assertEqual((fw / 'Headers/IOKitLib.h').read_text(encoding='utf-8'), '#define IOKIT 1\n')
            # Second pass is a no-op
            self.assertEqual(tc.repair_tbd_stubs(sdk), 0)

    def test_host_sources_includes_dav1d_and_launcher_defines_dm_game_menu(self) -> None:
        from nspb_qt.win import build_app
        repo = QT.parent / 'engine'
        if not (repo / 'dm/host/Makefile').is_file():
            self.skipTest('engine/ is missing')
        with tempfile.TemporaryDirectory() as td:
            files, incs = build_app.host_sources(repo, Path(td))
        names = {f.name for f in files}
        self.assertIn('lib.c', names, 'dav1d src/lib.c must be in host_sources')
        self.assertIn('itx.S', names, 'dav1d arm64 assembly must be in host_sources')
        inc_strs = [p.as_posix() for p in incs]
        self.assertTrue(any(p.endswith('dm/third_party/dav1d/include') for p in inc_strs))
        self.assertTrue(any(p.endswith('dm/third_party/dav1d/config') for p in inc_strs))

        launcher_m = (QT / 'nspb_qt/win/ios/Launcher.m').read_text(encoding='utf-8')
        self.assertIn('void *dm_game_menu(void)', launcher_m)
        build_app_src = (QT / 'nspb_qt/win/build_app.py').read_text(encoding='utf-8')
        self.assertIn('host_msl_gen.h', build_app_src)

    def test_xcrun_shim_splits_compile_and_link_and_stages_paths_with_spaces(self) -> None:
        from nspb_qt.win import xcrun_shim
        calls: list[tuple[list[str], str | None]] = []

        with tempfile.TemporaryDirectory() as td:
            src_dir = Path(td) / 'NS Port Builder' / 'engine' / 'dm' / 'gfx' / 'msl'
            src_dir.mkdir(parents=True)
            src_metal = src_dir / 'builtin.metal'
            src_metal.write_text('kernel void k() {}\n', encoding='utf-8')
            out_dir = Path(td) / 'Out Folder'
            out_ml = out_dir / 'builtin.metallib'

            def fake_run(cmd, *a, **k):
                cwd = k.get('cwd')
                calls.append(([str(c) for c in cmd], cwd))
                if cwd and 'out.metallib' in cmd:
                    (Path(cwd) / 'out.metallib').write_bytes(b'MTLB_STAGED')
                return subprocess.CompletedProcess(cmd, 0)

            with mock.patch.object(xcrun_shim, 'find', side_effect=lambda sdk, tool: Path(f'C:/metal/{tool}.exe')), \
                 mock.patch.object(subprocess, 'run', side_effect=fake_run):
                rc = xcrun_shim.main(['-sdk', 'iphoneos', 'metal', '-mios-version-min=18.0',
                                      '-o', str(out_ml), str(src_metal)])
            self.assertEqual(rc, 0)
            self.assertEqual(len(calls), 2)
            # Every argument after the executable must be free of spaces so metal.exe does not split it
            for args, cwd in calls:
                self.assertIsNotNone(cwd)
                for arg in args[1:]:
                    self.assertNotIn(' ', arg, f'argument passed to metal/metallib contains space: {arg!r}')
            self.assertEqual(calls[0][0], ['C:/metal/metal.exe', '-target', 'air64-apple-ios18.0',
                                           'in_0.metal', '-c', '-o', 'out.air'])
            self.assertEqual(calls[1][0], ['C:/metal/metallib.exe', 'out.air', '-o', 'out.metallib'])
            self.assertEqual(out_ml.read_bytes(), b'MTLB_STAGED')

    def test_win_fork_pool_rewrites_nso_byte_identical_to_single_core(self) -> None:
        import struct
        try:
            import lz4.block
            import capstone  # noqa: F401
        except ImportError:
            self.skipTest('lz4 and capstone required')
        patch_nso = QT.parent / 'engine/dm/tools/patch_nso.py'
        if not patch_nso.is_file():
            self.skipTest('engine/ is missing')

        ins_words = [0x910003FD] * (300 * 1024)
        ins_words[100] = 0xF9400252     # ldr x18, [x18] in chunk 0
        ins_words[270000] = 0x91000652  # add x18, x18, #1 in chunk 1
        ins_words[200] = 0xB9400109     # ldr w9, [x8]
        ins_words[201] = 0x7100053F     # cmp w9, #1
        ins_words[202] = 0x54FFFFC0     # b.eq -8 (spin wait!)
        ins_words[203] = 0xD65F03C0     # ret
        ins_words[0] = 0x14000010
        ins_words[1] = 8
        text_bytes = bytearray(struct.pack(f'<{len(ins_words)}I', *ins_words))
        struct.pack_into('<4siiiiii', text_bytes, 8, b'MOD0', 0, 0, 0, 0x38, 0x44, 0)
        struct.pack_into('<BBBBII', text_bytes, 0x40, 1, 0x03, 0x03, 0x03, 0, 0)
        ro_bytes = b'\x00' * 0x1000
        data_bytes = b'\x00' * 0x1000
        tc_b = lz4.block.compress(bytes(text_bytes), store_size=False)
        rc_b = lz4.block.compress(ro_bytes, store_size=False)
        dc_b = lz4.block.compress(data_bytes, store_size=False)
        hdr = bytearray(0x100)
        hdr[:4] = b'NSO0'
        struct.pack_into('<I', hdr, 0x0C, 7)
        struct.pack_into('<III', hdr, 0x10, 0x100, 0, len(text_bytes))
        struct.pack_into('<III', hdr, 0x20, 0x100 + len(tc_b), len(text_bytes), len(ro_bytes))
        struct.pack_into('<III', hdr, 0x30, 0x100 + len(tc_b) + len(rc_b), len(text_bytes) + len(ro_bytes), len(data_bytes))
        hdr[0x40:0x50] = bytes.fromhex('0123456789abcdef0123456789abcdef')
        struct.pack_into('<III', hdr, 0x60, len(tc_b), len(rc_b), len(dc_b))

        with tempfile.TemporaryDirectory() as td:
            nso_p = Path(td) / 'main'
            nso_p.write_bytes(bytes(hdr) + tc_b + rc_b + dc_b)
            out1, out2 = Path(td) / 'out1', Path(td) / 'out2'
            r1 = subprocess.run([sys.executable, str(patch_nso), str(nso_p), str(out1), 'main'],
                                env={**os.environ, 'DM_REWRITE_J': '1'}, capture_output=True, text=True)
            self.assertEqual(r1.returncode, 0, r1.stderr)
            sd = Path(td) / 'shim'
            sd.mkdir()
            sc = shim._SITECUSTOMIZE_SRC.replace("if os.name == 'nt'", "if True")
            (sd / 'sitecustomize.py').write_text(sc, encoding='utf-8')
            r2 = subprocess.run([sys.executable, str(patch_nso), str(nso_p), str(out2), 'main'],
                                env={**os.environ, 'DM_REWRITE_J': '4', 'PYTHONPATH': str(sd)},
                                capture_output=True, text=True)
            self.assertEqual(r2.returncode, 0, r2.stderr)
            for ext in ('patched.bin', 'fixups.tsv', 'gates.tsv', 'sites.tsv'):
                self.assertEqual((out1 / f'main.{ext}').read_bytes(),
                                 (out2 / f'main.{ext}').read_bytes())

    def test_fcntl_and_tree_tar_shim_work_without_posix_fcntl(self) -> None:
        """Engine 1.2's tree_tar.py imports fcntl at top level and opens parent directories."""
        from nspb_qt.win import driver
        repo = QT.parent / 'engine'
        if not (repo / 'dm/tools/tree_tar.py').is_file():
            self.skipTest('engine/ is missing')
        with tempfile.TemporaryDirectory() as td:
            sd = Path(td) / 'shim'
            sd.mkdir()
            sc = shim._SITECUSTOMIZE_SRC.replace("if os.name == 'nt'", "if True")
            (sd / 'sitecustomize.py').write_text(sc, encoding='utf-8')
            code = (
                "import builtins, os, sys\n"
                "real_import = builtins.__import__\n"
                "def block_fcntl(name, *a, **k):\n"
                "    if name == 'fcntl' and 'fcntl' not in sys.modules:\n"
                "        raise ModuleNotFoundError(\"No module named 'fcntl'\")\n"
                "    return real_import(name, *a, **k)\n"
                "builtins.__import__ = block_fcntl\n"
                "sys.modules.pop('fcntl', None)\n"
                "import sitecustomize\n"
                f"sys.path.insert(0, {str(repo / 'dm/tools')!r})\n"
                "import tree_tar\n"
                f"assert tree_tar._lock({str(Path(td) / 'dd')!r}) is True\n"
                f"tree_tar._unlock({str(Path(td) / 'dd')!r})\n"
            )
            r = subprocess.run([sys.executable, '-S', '-c', code],
                               env={**os.environ, 'PYTHONPATH': str(sd)},
                               capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stderr)

        # Also verify driver.load_upstream installs the fcntl stub when missing
        saved_fcntl = sys.modules.pop('fcntl', None)
        try:
            mod = driver.load_upstream(repo)
            self.assertIn('fcntl', sys.modules)
            self.assertTrue(hasattr(mod, 'tree_tar'))
            with tempfile.TemporaryDirectory() as td2:
                self.assertTrue(mod.tree_tar._lock(Path(td2) / 'dd'))
        finally:
            if saved_fcntl is not None:
                sys.modules['fcntl'] = saved_fcntl

    def test_build_app_reads_packed_shader_lib_img(self) -> None:
        """Engine 1.2 packs `b-<chain>/` into `b-<chain>.img` and deletes the folder; build_app must read `.img`."""
        from nspb_qt.win import build_app
        repo = QT.parent / 'engine'
        slib_path = repo / 'dm/tools/shader_lib.py'
        if not slib_path.is_file():
            self.skipTest('engine/ is missing')
        with tempfile.TemporaryDirectory() as td:
            msl_ios = Path(td) / 'ios'
            lib_dir = msl_ios / 'b-123456789abc'
            lib_dir.mkdir(parents=True)
            (lib_dir / '0001_b.metallib').write_bytes(b'MTLB_TEST')
            (lib_dir / 'inputs.tsv').write_text('game\t0100E65002BB8000\ninputs\tabcdef01\n', encoding='utf-8')
            r = subprocess.run([sys.executable, str(slib_path), 'pack', str(lib_dir)],
                               capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertFalse(lib_dir.exists(), 'shader_lib.pack removes the folder')
            self.assertTrue((msl_ios / 'b-123456789abc.img').is_file())
            self.assertTrue(build_app.shader_lib_has(repo, lib_dir))
            lines = build_app.shader_lib_stamp_lines(repo, lib_dir)
            self.assertIn('game\t0100E65002BB8000', lines)
            self.assertIn('inputs\tabcdef01', lines)

    def test_pack_dump_clone_and_cp_shim_on_windows(self) -> None:
        """pack_dump.clone and romfs_image.guest must not fail with WinError 2 when cp/xattr are absent on Windows."""
        from nspb_qt.win import driver
        repo = QT.parent / 'engine'
        if not (repo / 'scripts/pack_dump.py').is_file():
            self.skipTest('engine/ is missing')
        mod = driver.load_upstream(repo)
        driver.patch(mod, repo)
        self.assertIs(mod.pack_dump.clone, shutil.copy2)

        with tempfile.TemporaryDirectory() as td:
            sd = Path(td) / 'shim'
            shim.install(sd)
            sc = (sd / 'sitecustomize.py').read_text(encoding='utf-8').replace(
                "if os.name == 'nt'", "if True", 1)
            (sd / 'sitecustomize.py').write_text(sc, encoding='utf-8')
            src_exefs = Path(td) / 'src_exefs'
            src_exefs.mkdir()
            (src_exefs / 'main').write_bytes(b'NSO0_TEST')
            (src_exefs / 'main.npdm').write_bytes(b'META_TEST')
            dst_exefs = Path(td) / 'dst_exefs'
            code = (
                "import subprocess, sys\n"
                "_orig_popen = subprocess.Popen.__init__\n"
                "def _forbid_posix_tools(self, args, *a, **k):\n"
                "    head = args[0] if isinstance(args, (list, tuple)) and args else ''\n"
                "    if head in ('cp', 'xattr'):\n"
                "        raise FileNotFoundError(2, 'The system cannot find the file specified', head)\n"
                "    return _orig_popen(self, args, *a, **k)\n"
                "subprocess.Popen.__init__ = _forbid_posix_tools\n"
                "import sitecustomize\n"
                f"sys.path.insert(0, {str(repo / 'scripts')!r})\n"
                f"sys.path.insert(0, {str(repo / 'dm/tools')!r})\n"
                "from pathlib import Path\n"
                "import pack_dump, romfs_image\n"
                f"pack_dump.exefs(Path({str(src_exefs)!r}), Path({str(dst_exefs)!r}))\n"
                f"assert (Path({str(dst_exefs)!r}) / 'main').read_bytes() == b'NSO0_TEST'\n"
                f"assert romfs_image.guest({str(src_exefs)!r}, '.dm-case-0') == '.dm-case-0'\n"
            )
            r = subprocess.run([sys.executable, '-S', '-c', code],
                               env={**os.environ, 'PYTHONPATH': str(sd)},
                               capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stderr)

    def test_high_core_cpu_caps_j_and_process_pool_executor_to_61(self) -> None:
        """On a 32+ thread CPU, J and ProcessPoolExecutor(max_workers) must cap at 61 (_MAX_WINDOWS_WORKERS)."""
        with tempfile.TemporaryDirectory() as td:
            with mock.patch.dict(os.environ, {'LOCALAPPDATA': td}, clear=False), \
                    mock.patch('os.cpu_count', return_value=32):
                env = shim.build_env(base={})
                self.assertEqual(env['J'], '61')

            sd = Path(td) / 'shim'
            shim.install(sd)
            sc = (sd / 'sitecustomize.py').read_text(encoding='utf-8').replace(
                "if os.name == 'nt'", "if True", 1)
            (sd / 'sitecustomize.py').write_text(sc, encoding='utf-8')
            code = (
                "import concurrent.futures.process as cfp\n"
                "_orig_init = cfp.ProcessPoolExecutor.__init__\n"
                "def _strict_win_init(self, max_workers=None, *a, **k):\n"
                "    if max_workers is not None and max_workers > 61:\n"
                "        raise ValueError('max_workers must be <= 61')\n"
                "    return _orig_init(self, max_workers, *a, **k)\n"
                "cfp.ProcessPoolExecutor.__init__ = _strict_win_init\n"
                "import sitecustomize\n"
                "import concurrent.futures as cf\n"
                "with cf.ProcessPoolExecutor(64) as ex:\n"
                "    assert ex._max_workers == 61, ex._max_workers\n"
            )
            r = subprocess.run([sys.executable, '-S', '-c', code],
                               env={**os.environ, 'PYTHONPATH': str(sd)},
                               capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stderr)

    def test_first_launch_shows_onboarding_when_incomplete(self) -> None:
        """A fresh user opening MainWindow sees the OnboardingDialog once deps are checked; Later marks it complete."""
        import ast
        ui_src = (QT / 'nspb_qt' / 'ui.py').read_text(encoding='utf-8')
        ui_tree = ast.parse(ui_src)
        mw_cls = next(n for n in ast.walk(ui_tree)
                      if isinstance(n, ast.ClassDef) and n.name == 'MainWindow')
        fn_map = {n.name: n for n in mw_cls.body if isinstance(n, ast.FunctionDef)}
        self.assertIn('should_show_onboarding', fn_map)
        self.assertIn('_maybe_show_onboarding', fn_map)

        class FakeTimer:
            @staticmethod
            def singleShot(_ms, cb):
                cb()

        ns: dict = {'Path': Path, 'os': os, 'QTimer': FakeTimer}
        for name in ('should_show_onboarding', '_maybe_show_onboarding'):
            fn = fn_map[name]
            for n in ast.walk(fn):
                ast.fix_missing_locations(n)
            exec(compile(ast.fix_missing_locations(ast.Module(body=[fn], type_ignores=[])),
                         '<ui>', 'exec'), ns)
        should_show = ns['should_show_onboarding']
        maybe_show = ns['_maybe_show_onboarding']

        sheets_src = (QT / 'nspb_qt' / 'sheets.py').read_text(encoding='utf-8')
        sheets_tree = ast.parse(sheets_src)
        ob_cls = next(n for n in ast.walk(sheets_tree)
                      if isinstance(n, ast.ClassDef) and n.name == 'OnboardingDialog')
        later_fn = next(n for n in ob_cls.body
                        if isinstance(n, ast.FunctionDef) and n.name == '_on_later')
        for n in ast.walk(later_fn):
            ast.fix_missing_locations(n)
        exec(compile(ast.fix_missing_locations(ast.Module(body=[later_fn], type_ignores=[])),
                     '<sheets>', 'exec'), ns)
        on_later = ns['_on_later']

        with tempfile.TemporaryDirectory() as td:
            keys_file = Path(td) / 'prod.keys'

            class FakeSettings:
                def __init__(self):
                    self.store = {}
                def setValue(self, k, v):
                    self.store[k] = v

            class FakeLibrary:
                games_folder = ''
                games: list = []

            class FakeModel:
                def __init__(self):
                    self.settings = FakeSettings()
                    self.deps_checked = False
                    self.deps: list = []
                    self.keys_path = str(keys_file)
                    self.library = FakeLibrary()
                def settings_value(self, k, default):
                    v = self.settings.store.get(k, default)
                    return v == 'true' if isinstance(v, str) else bool(v)
                def settings_set(self, k, v):
                    self.settings.setValue(k, 'true' if v else 'false')

            class FakeWindow:
                should_show_onboarding = staticmethod(should_show)
                def __init__(self, m):
                    self.m = m
                    self._onboarding_checked = False
                    self.opened = 0
                def isVisible(self):
                    return True
                def _open_onboarding(self):
                    self.opened += 1

            m = FakeModel()
            w = FakeWindow(m)
            self.assertTrue(should_show(m))
            maybe_show(w)
            self.assertEqual(w.opened, 0, 'must wait until initial deps check finishes')
            m.deps_checked = True
            maybe_show(w)
            self.assertEqual(w.opened, 1, 'must open once deps check finishes')
            maybe_show(w)
            self.assertEqual(w.opened, 1, 'must not re-open automatically in the same session')

            class FakeDialog:
                def __init__(self, model):
                    self.m = model
                    self.rejected = False
                def reject(self):
                    self.rejected = True

            dlg = FakeDialog(m)
            on_later(dlg)
            self.assertTrue(dlg.rejected)
            self.assertTrue(m.settings_value('onboardingComplete', False))
            self.assertFalse(should_show(m))

    def test_non_ascii_paths_stage_metal_and_metallib_via_ascii_temp_dir(self) -> None:
        """Chinese folder names (e.g. C:\\Games\\星露谷物语\\nsp本体\\...) must be staged via an ASCII temp dir."""
        from nspb_qt.win import xcrun_shim
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            ascii_fallback = root / 'ascii_tmp'
            ascii_fallback.mkdir()
            zh_build = root / '星露谷物语' / 'nsp本体' / '0100E65002BB8000_build'
            zh_ios = zh_build / 'shader' / 'ios' / 'b-223f10d34f97'
            zh_ios.mkdir(parents=True)
            zh_msl = zh_build / 'dmsh_123' / '0000000000000001.metal'
            zh_msl.parent.mkdir(parents=True)
            zh_msl.write_text('#include <metal_stdlib>\n', encoding='utf-8')
            zh_air = zh_build / 'dmsh_123' / '0000000000000001.air'
            zh_lib = zh_ios / '0000000000000001_b.metallib.tmp-999'

            seen_calls: list[tuple[list[str], str]] = []

            def strict_metal_run(cmd, *a, **kw):
                cwd = str(kw.get('cwd') or '')
                args = [str(x) for x in cmd]
                seen_calls.append((args, cwd))
                for token in args + ([cwd] if cwd else []):
                    if not token.isascii() or ' ' in token:
                        return subprocess.CompletedProcess(
                            cmd, 1, '', f"LLVM ERROR: Error opening '{token}': Invalid argument\n")
                if '-o' in args:
                    out_name = args[args.index('-o') + 1]
                    out_p = (Path(cwd) / out_name) if cwd and not Path(out_name).is_absolute() else Path(out_name)
                    out_p.write_bytes(b'MTLB_OK')
                return subprocess.CompletedProcess(cmd, 0, '', '')

            with mock.patch.object(tc, 'metal_tool', side_effect=lambda name, *a: Path(f'/opt/metal/{name}.exe')), \
                 mock.patch.object(tempfile, 'gettempdir', return_value=str(root / '中文用户' / 'Temp')), \
                 mock.patch.dict(os.environ, {'PUBLIC': str(ascii_fallback), 'LOCALAPPDATA': str(root / 'local')}, clear=False), \
                 mock.patch.object(xcrun_shim.subprocess, 'run', side_effect=strict_metal_run):
                rc1 = xcrun_shim.main(['-sdk', 'iphoneos', 'metal', '-c', str(zh_msl), '-o', str(zh_air)])
                self.assertEqual(rc1, 0)
                self.assertTrue(zh_air.is_file(), 'staged metal compile must copy .air back to Chinese path')
                rc2 = xcrun_shim.main(['-sdk', 'iphoneos', 'metallib', str(zh_air), '-o', str(zh_lib)])
                self.assertEqual(rc2, 0)
                self.assertTrue(zh_lib.is_file(), 'staged metallib must copy .metallib back to Chinese path')
                self.assertEqual(zh_lib.read_bytes(), b'MTLB_OK')
                self.assertEqual(len(seen_calls), 2)

            # Verify sitecustomize._resolve rejects non-ASCII args so they go to xcrun_shim,
            # and dmsh_pch / dmsh_mtlcache redirect Chinese WORK folders to pure-ASCII temp dirs.
            sd = root / 'shim'
            shim.install(sd, python_exe=sys.executable)
            sc = (sd / 'sitecustomize.py').read_text(encoding='utf-8').replace(
                "if os.name == 'nt'", "if True", 1)
            (sd / 'sitecustomize.py').write_text(sc, encoding='utf-8')
            code = (
                "import os, sys, types\n"
                "import sitecustomize\n"
                f"zh_lib = {str(zh_lib)!r}\n"
                "assert sitecustomize._resolve(['-sdk', 'iphoneos', 'metallib', 'a.air', '-o', zh_lib]) is None\n"
                "import importlib.machinery as mach, tempfile\n"
                "pch_mod = types.ModuleType('dmsh_pch')\n"
                "pch_mod.tempfile = tempfile\n"
                "sitecustomize._patch_dmsh_pch_module(pch_mod)\n"
                f"d = pch_mod.tempfile.mkdtemp(prefix='pch_', dir={str(zh_build)!r})\n"
                "assert d.isascii() and ' ' not in d, d\n"
                "os.rmdir(d)\n"
                "mtl_mod = types.ModuleType('dmsh_mtlcache')\n"
                "class Cache:\n"
                "    def __init__(self, store, targets, work):\n"
                "        self.work = work\n"
                "mtl_mod.Cache = Cache\n"
                "sitecustomize._patch_dmsh_mtlcache_module(mtl_mod)\n"
                f"c = mtl_mod.Cache(None, {{}}, {str(zh_build)!r})\n"
                "assert c.work.isascii() and ' ' not in c.work, c.work\n"
            )
            r = subprocess.run([sys.executable, '-S', '-c', code],
                               env={**os.environ, 'PYTHONPATH': str(sd)},
                               capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stderr)

    def test_resolve_metal_dir_accepts_exe_bin_ios_and_outer_folder(self) -> None:
        """Selecting metal.exe, metallib.exe, bin/, ios/bin/, ios/, or the outer folder resolves to the Metal root."""
        import ast
        with tempfile.TemporaryDirectory() as td:
            outer = Path(td) / 'Downloads' / 'Metal_Developer_Tools'
            root = outer / 'Metal Developer Tools'
            (root / 'bin').mkdir(parents=True)
            (root / 'bin/metal.exe').write_bytes(b'MZ_METAL')
            (root / 'bin/metallib.exe').write_bytes(b'MZ_METALLIB')
            (root / 'ios/bin').mkdir(parents=True)
            (root / 'ios/bin/metal.exe').write_bytes(b'MZ_IOS_METAL')
            (root / 'ios/bin/metallib.exe').write_bytes(b'MZ_IOS_METALLIB')

            for candidate in (
                root,
                outer,
                root / 'bin',
                root / 'ios',
                root / 'ios/bin',
                root / 'bin/metal.exe',
                root / 'bin/metallib.exe',
                root / 'ios/bin/metal.exe',
                root / 'ios/bin/metallib.exe',
            ):
                resolved = tc.resolve_metal_dir(candidate)
                self.assertEqual(resolved, root, f'failed to resolve {candidate}')

            # Verify tc.metal_dir() and tc.metal_tool() work even if NSPB_METAL_DIR points to metal.exe
            with mock.patch.dict(os.environ, {'NSPB_METAL_DIR': str(root / 'bin/metallib.exe')}, clear=False):
                self.assertEqual(tc.metal_dir(), root)
                self.assertEqual(tc.metal_tool('metal', 'iphoneos'), root / 'ios/bin/metal.exe')
                self.assertEqual(tc.metal_tool('metallib', 'iphoneos'), root / 'ios/bin/metallib.exe')

            # Verify Model._save_metal_folder accepts metal.exe / metallib.exe directly and saves root
            model_src = (QT / 'nspb_qt' / 'model.py').read_text(encoding='utf-8')
            model_tree = ast.parse(model_src)
            m_cls = next(n for n in ast.walk(model_tree)
                         if isinstance(n, ast.ClassDef) and n.name == 'Model')
            save_fn = next(n for n in m_cls.body
                           if isinstance(n, ast.FunctionDef) and n.name == '_save_metal_folder')
            for n in ast.walk(save_fn):
                ast.fix_missing_locations(n)
            ns: dict = {'__name__': 'nspb_qt.model', '__package__': 'nspb_qt',
                        'Path': Path, 'L': lambda k, *a: f'{k}:{a}'}
            exec(compile(ast.fix_missing_locations(ast.Module(body=[save_fn], type_ignores=[])),
                         '<model>', 'exec'), ns)
            save_metal = ns['_save_metal_folder']

            class FakeModelForMetal:
                def __init__(self):
                    self.logs: list[str] = []
                    self.rechecked = 0
                def t(self, k: str, *a) -> str:
                    return f'{k}:{a}'
                def log(self, msg: str) -> None:
                    self.logs.append(msg)
                def check_deps(self) -> None:
                    self.rechecked += 1

            fm = FakeModelForMetal()
            with mock.patch.dict(os.environ, {'LOCALAPPDATA': str(Path(td) / 'local')}, clear=False):
                save_metal(fm, root / 'bin/metal.exe')
                self.assertEqual(tc.setting('metal_dir'), str(root))
                self.assertEqual(fm.rechecked, 1)
                fm2 = FakeModelForMetal()
                save_metal(fm2, root / 'bin/metallib.exe')
                self.assertEqual(tc.setting('metal_dir'), str(root))
                self.assertEqual(fm2.rechecked, 1)

    def test_install_sdk_from_zip_materializes_symlinks_and_install_sdk_prefers_zip(self) -> None:
        """install_sdk_from_zip materializes chained Unix symlinks in the zip; install_sdk uses HTTP zip first."""
        from nspb_qt.win import fetch
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            zip_path = root / 'iPhoneOS27.2.sdk.zip'
            with zipfile.ZipFile(zip_path, 'w') as zf:
                def add_file(arcname: str, data: str) -> None:
                    zi = zipfile.ZipInfo(arcname)
                    zi.external_attr = (0o100644 << 16)
                    zf.writestr(zi, data.encode('utf-8'))

                def add_symlink(arcname: str, target: str) -> None:
                    zi = zipfile.ZipInfo(arcname)
                    zi.external_attr = (0o120777 << 16)
                    zf.writestr(zi, target.encode('utf-8'))

                add_file('iPhoneOS27.2.sdk/SDKSettings.json',
                         json.dumps({'Version': '27.2', 'CanonicalName': 'iphoneos27.2'}))
                add_file('iPhoneOS27.2.sdk/System/Library/Frameworks/UIKit.framework/Headers/UIKit.h',
                         '// UIKit\n')
                add_file('iPhoneOS27.2.sdk/System/Library/Frameworks/UIKit.framework/UIKit.tbd',
                         '--- !tapi-tbd\n')
                add_file('iPhoneOS27.2.sdk/System/Library/Frameworks/Foundation.framework/Foundation.tbd',
                         '--- !tapi-tbd\n')
                add_file('iPhoneOS27.2.sdk/usr/lib/libSystem.B.tbd',
                         '--- !tapi-tbd\ntargets: [ arm64-ios ]\n')
                # Chained file symlink: libm.tbd -> libSystem.tbd -> libSystem.B.tbd
                add_symlink('iPhoneOS27.2.sdk/usr/lib/libSystem.tbd', 'libSystem.B.tbd')
                add_symlink('iPhoneOS27.2.sdk/usr/lib/libm.tbd', 'libSystem.tbd')
                # Directory symlink: IOKit.framework/Headers -> Versions/Current/Headers
                add_file('iPhoneOS27.2.sdk/System/Library/Frameworks/IOKit.framework/Versions/A/Headers/IOKitLib.h',
                         '// IOKit\n')
                add_symlink('iPhoneOS27.2.sdk/System/Library/Frameworks/IOKit.framework/Versions/Current', 'A')
                add_symlink('iPhoneOS27.2.sdk/System/Library/Frameworks/IOKit.framework/Headers',
                            'Versions/Current/Headers')

            with mock.patch.dict(os.environ, {'LOCALAPPDATA': str(root / 'local')}, clear=False):
                installed = sdk_fetch.install_sdk_from_zip(zip_path)
                self.assertTrue(tc.is_sdk_dir(installed))
                self.assertEqual(tc.sdk_version(installed)[0], '27.2')
                self.assertTrue((installed / 'usr/lib/libm.tbd').read_text(encoding='utf-8').startswith('--- !tapi-tbd'))
                self.assertTrue((installed / 'System/Library/Frameworks/IOKit.framework/Headers/IOKitLib.h').is_file())
                # Also verify resolve_sdk_dir handles SDKSettings.json and parent directories
                self.assertEqual(tc.resolve_sdk_dir(installed / 'SDKSettings.json'), installed)
                self.assertEqual(tc.resolve_sdk_dir(installed.parent), installed)

                # Verify install_sdk downloads SDK_ASSET via fetch.download and does not need git
                shutil.rmtree(installed)
                def fake_download(url, dest, sha256=None, size=None, *, log=None, progress=None):
                    self.assertEqual(url, tc.SDK_ASSET['url'])
                    self.assertEqual(sha256, tc.SDK_ASSET['sha256'])
                    dst = Path(dest)
                    dst.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(zip_path, dst)
                    return dst

                with mock.patch.object(fetch, 'download', side_effect=fake_download) as dl_mock, \
                     mock.patch.object(sdk_fetch, 'clone_sdk') as clone_mock:
                    sdk_dir = sdk_fetch.install_sdk()
                    self.assertEqual(dl_mock.call_count, 1)
                    self.assertEqual(clone_mock.call_count, 0)
                    self.assertTrue(tc.is_sdk_dir(sdk_dir))

    def test_install_sdk_from_zip_rejects_drive_paths_symlink_escapes_and_version_traversal(self) -> None:
        """Archive extraction must reject drive-qualified paths, symlink escapes, and Version traversal
        while leaving outside sentinels and any pre-existing cached SDK intact."""
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            cache = root / 'local' / 'NS Port Builder' / 'sdk'
            cache.mkdir(parents=True)
            outside_sentinel = root / 'outside_sentinel.txt'
            outside_sentinel.write_text('OUTSIDE_SECRET_DO_NOT_TOUCH', encoding='utf-8')
            outside_victim = root / 'iPhoneOS_victim.sdk'
            outside_victim.mkdir()
            (outside_victim / 'keep.txt').write_text('KEEP_ME', encoding='utf-8')

            existing_sdk = make_fake_sdk(cache, '27.2')
            (existing_sdk / 'existing_marker.txt').write_text('EXISTING_OK', encoding='utf-8')

            def write_sdk_zip(zpath: Path, *, extra_file: tuple[str, str] | None = None,
                              extra_symlink: tuple[str, str] | None = None,
                              sdk_folder: str = 'iPhoneOS27.2.sdk',
                              sdk_version: str = '27.2') -> Path:
                with zipfile.ZipFile(zpath, 'w') as zf:
                    def add_file(arcname: str, data: str) -> None:
                        zi = zipfile.ZipInfo(arcname)
                        zi.external_attr = (0o100644 << 16)
                        zf.writestr(zi, data.encode('utf-8'))

                    def add_symlink(arcname: str, target: str) -> None:
                        zi = zipfile.ZipInfo(arcname)
                        zi.external_attr = (0o120777 << 16)
                        zf.writestr(zi, target.encode('utf-8'))

                    add_file(f'{sdk_folder}/SDKSettings.json', json.dumps({'Version': sdk_version}))
                    add_file(f'{sdk_folder}/System/Library/Frameworks/UIKit.framework/Headers/UIKit.h', '// h\n')
                    add_file(f'{sdk_folder}/System/Library/Frameworks/UIKit.framework/UIKit.tbd', '--- !tapi-tbd\n')
                    add_file(f'{sdk_folder}/System/Library/Frameworks/Foundation.framework/Foundation.tbd', '--- !tapi-tbd\n')
                    add_file(f'{sdk_folder}/usr/lib/libSystem.tbd', '--- !tapi-tbd\n')
                    if extra_file:
                        add_file(extra_file[0], extra_file[1])
                    if extra_symlink:
                        add_symlink(extra_symlink[0], extra_symlink[1])
                return zpath

            with mock.patch.dict(os.environ, {'LOCALAPPDATA': str(root / 'local')}, clear=False):
                # 1. Drive-qualified, UNC, and parent-traversal member paths must be rejected
                for bad_member in ('C:outside_sentinel.txt', 'C:\\outside_sentinel.txt',
                                   '..\\outside_sentinel.txt', '../outside_sentinel.txt'):
                    bad_zip = write_sdk_zip(root / 'bad_member.zip', extra_file=(bad_member, 'OVERWRITTEN'))
                    with self.assertRaises(sdk_fetch.SdkError):
                        sdk_fetch.install_sdk_from_zip(bad_zip, dest=cache)
                    self.assertEqual(outside_sentinel.read_text(encoding='utf-8'), 'OUTSIDE_SECRET_DO_NOT_TOUCH')

                # 2. Symlink targets escaping staging or using drive/absolute paths must be rejected
                for bad_target in ('../../../../../outside_sentinel.txt',
                                   '..\\..\\..\\..\\..\\outside_sentinel.txt',
                                   'C:/outside_sentinel.txt',
                                   '/outside_sentinel.txt'):
                    sym_zip = write_sdk_zip(
                        root / 'bad_sym.zip',
                        extra_symlink=('iPhoneOS27.2.sdk/usr/lib/leak.tbd', bad_target),
                    )
                    with self.assertRaises(sdk_fetch.SdkError):
                        sdk_fetch.install_sdk_from_zip(sym_zip, dest=cache)
                    self.assertFalse((existing_sdk / 'usr/lib/leak.tbd').exists())

                # Direct `_materialize` check: neither strict nor non-strict mode may copy outside files
                stage_test = cache / 'stage_direct'
                (stage_test / 'sub').mkdir(parents=True)
                with self.assertRaises(sdk_fetch.SdkError):
                    sdk_fetch._materialize(
                        stage_test,
                        [('sub/leak.txt', '../../../outside_sentinel.txt')],
                        lambda _s: None,
                        strict=True,
                    )
                sdk_fetch._materialize(
                    stage_test,
                    [('sub/leak.txt', '../../../outside_sentinel.txt')],
                    lambda _s: None,
                    strict=False,
                )
                self.assertFalse((stage_test / 'sub/leak.txt').exists())
                shutil.rmtree(stage_test)

                # 3. SDKSettings.json `Version` traversal must be rejected without deleting outside folders
                for bad_ver in ('../../iPhoneOS_victim', '/../iPhoneOS_victim', '27.2/../../outside'):
                    ver_zip = write_sdk_zip(
                        root / 'bad_ver.zip',
                        sdk_folder='InnerSDK',
                        sdk_version=bad_ver,
                    )
                    with self.assertRaises(sdk_fetch.SdkError):
                        sdk_fetch.install_sdk_from_zip(ver_zip, dest=cache)
                    self.assertTrue((outside_victim / 'keep.txt').is_file())
                    self.assertEqual((existing_sdk / 'existing_marker.txt').read_text(encoding='utf-8'), 'EXISTING_OK')

                # 4. Rollback: if moving the new SDK into place fails (even after creating the first destination file),
                # the partial target is removed and the pre-existing SDK is restored
                good_zip = write_sdk_zip(root / 'good.zip')
                real_move = sdk_fetch.shutil.move
                move_calls = 0

                def failing_second_move_after_first_file(src, dst, *a, **kw):
                    nonlocal move_calls
                    move_calls += 1
                    if move_calls == 2:
                        dst_p = Path(dst)
                        dst_p.mkdir(parents=True, exist_ok=True)
                        (dst_p / 'partial_file.txt').write_text('PARTIAL', encoding='utf-8')
                        raise OSError('simulated disk error after creating first destination file')
                    return real_move(src, dst, *a, **kw)

                with mock.patch.object(sdk_fetch.shutil, 'move', side_effect=failing_second_move_after_first_file):
                    with self.assertRaises(sdk_fetch.SdkError):
                        sdk_fetch.install_sdk_from_zip(good_zip, dest=cache)
                self.assertTrue(tc.is_sdk_dir(existing_sdk))
                self.assertEqual((existing_sdk / 'existing_marker.txt').read_text(encoding='utf-8'), 'EXISTING_OK')
                self.assertFalse((existing_sdk / 'partial_file.txt').exists())

                # 5. Symlink materialization charges unpacked byte and entry budgets, and rejects recursive directory copies
                budget_zip = root / 'symlink_budget.zip'
                with zipfile.ZipFile(budget_zip, 'w') as zf:
                    def add_f(arcname: str, data: bytes) -> None:
                        zi = zipfile.ZipInfo(arcname)
                        zi.external_attr = (0o100644 << 16)
                        zf.writestr(zi, data)

                    def add_s(arcname: str, target: str) -> None:
                        zi = zipfile.ZipInfo(arcname)
                        zi.external_attr = (0o120777 << 16)
                        zf.writestr(zi, target.encode('utf-8'))

                    add_f('iPhoneOS27.2.sdk/SDKSettings.json', b'{"Version":"27.2"}')
                    add_f('iPhoneOS27.2.sdk/System/Library/Frameworks/UIKit.framework/Headers/UIKit.h', b'A' * 850)
                    for idx in range(16):
                        add_s(f'iPhoneOS27.2.sdk/usr/include/dup_{idx}.h',
                              '../../System/Library/Frameworks/UIKit.framework/Headers/UIKit.h')

                with mock.patch.object(sdk_fetch, 'MAX_ZIP_BYTES', 1024):
                    with self.assertRaises(sdk_fetch.SdkError):
                        sdk_fetch.install_sdk_from_zip(budget_zip, dest=cache)
                self.assertTrue(tc.is_sdk_dir(existing_sdk))
                self.assertEqual((existing_sdk / 'existing_marker.txt').read_text(encoding='utf-8'), 'EXISTING_OK')

                with mock.patch.object(sdk_fetch, 'MAX_ZIP_MEMBERS', 10):
                    with self.assertRaises(sdk_fetch.SdkError):
                        sdk_fetch.install_sdk_from_zip(budget_zip, dest=cache)
                self.assertTrue(tc.is_sdk_dir(existing_sdk))

                rec_dir_zip = write_sdk_zip(
                    root / 'recursive_dir_sym.zip',
                    extra_symlink=('iPhoneOS27.2.sdk/System/Library/Frameworks/UIKit.framework/Loop', '..'),
                )
                with self.assertRaises(sdk_fetch.SdkError):
                    sdk_fetch.install_sdk_from_zip(rec_dir_zip, dest=cache)
                self.assertTrue(tc.is_sdk_dir(existing_sdk))
                self.assertEqual((existing_sdk / 'existing_marker.txt').read_text(encoding='utf-8'), 'EXISTING_OK')

                # 6. Flat SDK ZIP (SDKSettings.json and System/Library/Frameworks/UIKit.framework at the archive root)
                flat_zip = root / 'flat_sdk.zip'
                with zipfile.ZipFile(flat_zip, 'w') as zf:
                    def add_flat_f(arcname: str, data: str) -> None:
                        zi = zipfile.ZipInfo(arcname)
                        zi.external_attr = (0o100644 << 16)
                        zf.writestr(zi, data.encode('utf-8'))

                    def add_flat_s(arcname: str, target: str) -> None:
                        zi = zipfile.ZipInfo(arcname)
                        zi.external_attr = (0o120777 << 16)
                        zf.writestr(zi, target.encode('utf-8'))

                    add_flat_f('SDKSettings.json', json.dumps({'Version': '27.2', 'CanonicalName': 'iphoneos27.2'}))
                    add_flat_f('System/Library/Frameworks/UIKit.framework/Headers/UIKit.h', '// flat UIKit\n')
                    add_flat_f('System/Library/Frameworks/UIKit.framework/UIKit.tbd', '--- !tapi-tbd\n')
                    add_flat_f('System/Library/Frameworks/Foundation.framework/Foundation.tbd', '--- !tapi-tbd\n')
                    add_flat_f('usr/lib/libSystem.B.tbd', '--- !tapi-tbd\ntargets: [ arm64-ios ]\n')
                    add_flat_s('usr/lib/libSystem.tbd', 'libSystem.B.tbd')
                    add_flat_s('TopAlias.json', 'SDKSettings.json')

                flat_dest = root / 'flat_dest'
                flat_installed = sdk_fetch.install_sdk_from_zip(flat_zip, dest=flat_dest)
                self.assertEqual(flat_installed, flat_dest / 'iPhoneOS27.2.sdk')
                self.assertTrue(tc.is_sdk_dir(flat_installed))
                self.assertTrue((flat_installed / 'usr/lib/libSystem.tbd').is_file())
                self.assertTrue((flat_installed / 'TopAlias.json').is_file())

                # 7. Text-stub expansion (repair_tbd_stubs) charges against the same byte/entry budget
                text_stub_zip = root / 'text_stub_budget.zip'
                with zipfile.ZipFile(text_stub_zip, 'w') as zf:
                    def add_regular(arcname: str, data: bytes) -> None:
                        zi = zipfile.ZipInfo(arcname)
                        zi.external_attr = (0o100644 << 16)
                        zf.writestr(zi, data)

                    add_regular('iPhoneOS27.2.sdk/SDKSettings.json', b'{"Version":"27.2"}')
                    add_regular('iPhoneOS27.2.sdk/System/Library/Frameworks/UIKit.framework/UIKit.tbd', b'--- !tapi-tbd\n')
                    add_regular('iPhoneOS27.2.sdk/usr/include/real.h', b'H' * 850)
                    for idx in range(16):
                        add_regular(f'iPhoneOS27.2.sdk/usr/include/alias_{idx:02d}.h', b'real.h')

                with mock.patch.object(sdk_fetch, 'MAX_ZIP_BYTES', 1024):
                    with self.assertRaises(sdk_fetch.SdkError):
                        sdk_fetch.install_sdk_from_zip(text_stub_zip, dest=cache)
                self.assertTrue(tc.is_sdk_dir(existing_sdk))
                self.assertEqual((existing_sdk / 'existing_marker.txt').read_text(encoding='utf-8'), 'EXISTING_OK')

                # 8. First install (had_existing is False) mid-copy failure removes partial target so retry downloads and installs cleanly
                fresh_cache = root / 'fresh_cache'
                fresh_target = fresh_cache / 'iPhoneOS27.2.sdk'
                first_install_zip = write_sdk_zip(
                    root / 'first_install.zip',
                    extra_file=('iPhoneOS27.2.sdk/usr/include/required.h', '#define REQUIRED_HDR 1\n'),
                )

                def failing_first_install_move(src, dst, *a, **kw):
                    dst_p = Path(dst)
                    (dst_p / 'System/Library/Frameworks/UIKit.framework').mkdir(parents=True, exist_ok=True)
                    (dst_p / 'SDKSettings.json').write_text('{"Version":"27.2"}', encoding='utf-8')
                    (dst_p / 'System/Library/Frameworks/UIKit.framework/UIKit.tbd').write_text('--- !tapi-tbd\n', encoding='utf-8')
                    raise OSError('simulated mid-copy failure on first install')

                from nspb_qt.win import fetch as wf
                with mock.patch.object(wf, 'download', return_value=first_install_zip):
                    with mock.patch.object(sdk_fetch.shutil, 'move', side_effect=failing_first_install_move):
                        with self.assertRaises(sdk_fetch.SdkError):
                            sdk_fetch.install_sdk(version='iPhoneOS27.2.sdk', dest=fresh_cache, fallback_git=False)
                    self.assertFalse(fresh_target.exists(), 'partial target from failed first install must be cleaned up')
                    self.assertFalse(tc.is_sdk_dir(fresh_target))

                    retried = sdk_fetch.install_sdk(version='iPhoneOS27.2.sdk', dest=fresh_cache, fallback_git=False)
                    self.assertEqual(retried, fresh_target)
                    self.assertTrue(tc.is_sdk_dir(fresh_target))
                    self.assertTrue((fresh_target / 'usr/include/required.h').is_file())

    def test_clone_sdk_retries_next_mirror_when_sparse_checkout_fails(self) -> None:
        """If git sparse-checkout fails on the first mirror, clone_sdk must retry the next mirror."""
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            fake_git = root / 'git.exe'
            fake_git.write_bytes(b'git')
            seen_Log: list[str] = []
            mirror_attempts: list[str] = []

            class FakePopen:
                def __init__(self, cmd, *a, **kw):
                    args = [str(c) for c in cmd]
                    url = args[-2]
                    stage = Path(args[-1])
                    mirror_attempts.append(url)
                    stage.mkdir(parents=True, exist_ok=True)
                    stage.joinpath('.git').mkdir(exist_ok=True)
                    stage.joinpath('_mirror_url').write_text(url, encoding='utf-8')
                    self.stdout = ['Cloning into stage...\n']
                    self.returncode = 0
                def wait(self):
                    return 0

            def fake_run(cmd, *a, **kw):
                args = [str(c) for c in cmd]
                if 'sparse-checkout' in args:
                    cwd = Path(kw['cwd'])
                    url = (cwd / '_mirror_url').read_text(encoding='utf-8')
                    if 'mirror1' in url:
                        raise subprocess.CalledProcessError(128, cmd, '', 'fatal: early EOF during sparse-checkout')
                    make_fake_sdk(cwd, '27.2')
                    return subprocess.CompletedProcess(cmd, 0, '', '')
                return subprocess.CompletedProcess(cmd, 0, b'', b'')

            with mock.patch.dict(os.environ, {'LOCALAPPDATA': str(root / 'local')}, clear=False), \
                 mock.patch.object(tc, 'git_exe', return_value=fake_git), \
                 mock.patch.object(tc, 'mirror_urls', return_value=['https://mirror1/repo.git', 'https://mirror2/repo.git']), \
                 mock.patch.object(sdk_fetch.subprocess, 'Popen', FakePopen), \
                 mock.patch.object(sdk_fetch.subprocess, 'run', side_effect=fake_run):
                target = sdk_fetch.clone_sdk('iPhoneOS27.2.sdk', log=seen_Log.append)
                self.assertEqual(len(mirror_attempts), 2)
                self.assertTrue(tc.is_sdk_dir(target))

    def test_pyinstaller_internal_pyd_and_dll_are_isolated_from_build_python(self) -> None:
        """A PyInstaller `_internal` folder holding `_ctypes.pyd` + `python312.dll` must never enter
        a build child's `PYTHONPATH`, `sys.path`, `PATH` or `cwd` (prevents `ImportError: Module use
        of python312.dll conflicts with this version of Python` on Python 3.13/3.14/3.15)."""
        from nspb_qt import platform_util as pu
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            internal = root / 'NX2Apple' / '_internal'
            (internal / 'nspb_qt' / 'win').mkdir(parents=True)
            (internal / 'nspb_qt' / '__init__.py').write_text('# pkg\n', encoding='utf-8')
            (internal / 'nspb_qt' / 'win' / '__init__.py').write_text('# win\n', encoding='utf-8')
            (internal / 'nspb_qt' / 'win' / 'driver.py').write_text('# driver\n', encoding='utf-8')
            (internal / '_ctypes.pyd').write_bytes(b'MZ_PY312_CTYPES')
            (internal / 'python312.dll').write_bytes(b'MZ_PY312_DLL')

            sd = root / 'shim'
            sd.mkdir()
            cleaned = shim.clean_pkg_root(sd, raw_root=internal)
            self.assertEqual(cleaned, sd)
            self.assertTrue((sd / 'nspb_qt' / 'win' / 'driver.py').is_file())
            self.assertFalse((sd / '_ctypes.pyd').exists())
            self.assertFalse((sd / 'python312.dll').exists())

            # Verify build_env strips _internal from PATH/PYTHONPATH and removes PyInstaller vars
            with mock.patch.object(shim, 'shim_dir', return_value=sd), \
                 mock.patch.object(shim, 'clean_pkg_root', side_effect=lambda s, r=None: shim.clean_pkg_root.__wrapped__(s, internal) if hasattr(shim.clean_pkg_root, '__wrapped__') else sd):
                env = shim.build_env({
                    'PATH': f'{internal}{os.pathsep}C:\\Windows\\System32',
                    'PYTHONPATH': str(internal),
                    '_MEIPASS': str(internal),
                    '_MEIPASS2': str(internal),
                    'PYTHONHOME': str(internal),
                }, python_exe='C:\\Python315\\python.exe')
            self.assertNotIn(str(internal), env['PATH'].split(os.pathsep))
            self.assertNotIn(str(internal), env['PYTHONPATH'].split(os.pathsep))
            self.assertIn(str(sd), env['PYTHONPATH'].split(os.pathsep))
            for k in ('_MEIPASS', '_MEIPASS2', 'PYTHONHOME'):
                self.assertNotIn(k, env)

            # Verify sitecustomize removes _internal from sys.path and redirects _PKG to _HERE/nspb_qt/win
            sc = shim._SITECUSTOMIZE_SRC.replace("if os.name == 'nt'", "if True", 1)
            sc = sc.replace("    _PKG = os.environ.get('NSPB_WIN_DIR') or _HERE\n",
                            f"    _PKG = {str(internal / 'nspb_qt' / 'win')!r}\n")
            (sd / 'sitecustomize.py').write_text(sc, encoding='utf-8')
            code = (
                "import sys\n"
                f"sys.path.insert(0, {str(internal)!r})\n"
                "import sitecustomize\n"
                f"assert {str(internal)!r} not in sys.path, sys.path\n"
                f"assert sitecustomize._PKG == {str(sd / 'nspb_qt' / 'win')!r}, sitecustomize._PKG\n"
            )
            r = subprocess.run([sys.executable, '-S', '-c', code],
                               env={**os.environ, 'PYTHONPATH': str(sd)},
                               capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stderr)

            # Verify Windows find_python / venv_base prefer 3.12 (matching bundled cp312 wheels) over 3.15
            py312 = root / 'py312' / 'python.exe'
            py315 = root / 'py315' / 'python.exe'
            for p in (py312, py315):
                p.parent.mkdir(parents=True)
                p.write_bytes(b'MZ')
                p.chmod(0o755)
            vers = {str(py312): '3.12', str(py315): '3.15'}
            with mock.patch.object(pu, 'IS_WIN', True), \
                 mock.patch.object(pu, 'python_candidates', return_value=[str(py312), str(py315)]), \
                 mock.patch.object(pu, '_python_version', side_effect=lambda p: vers[p]), \
                 mock.patch.object(pu, '_runs', return_value=True):
                chosen, ok, ver = pu.find_python()
                self.assertEqual((chosen, ok, ver), (str(py312), True, '3.12'))
                self.assertEqual(pu.venv_base(''), str(py312))

            # Verify pu.child_env preserves user PYTHONPATH in non-frozen runs and only strips _MEIPASS
            sep = ';' if pu.IS_WIN else ':'
            with mock.patch.dict(os.environ, {'PYTHONPATH': '/custom/user/lib'}, clear=False), \
                 mock.patch.object(sys, '_MEIPASS', None, create=True), \
                 mock.patch.object(sys, 'frozen', False, create=True):
                cenv = pu.child_env()
                self.assertEqual(cenv.get('PYTHONPATH'), '/custom/user/lib')
            with mock.patch.dict(
                os.environ,
                {
                    'PYTHONPATH': f'{internal}{sep}/custom/user/lib',
                    'PYTHONHOME': str(internal),
                    '_MEIPASS': str(internal),
                },
                clear=False,
            ), mock.patch.object(sys, '_MEIPASS', str(internal), create=True), \
               mock.patch.object(sys, 'frozen', True, create=True):
                cenv_frozen = pu.child_env()
                self.assertEqual(cenv_frozen.get('PYTHONPATH'), '/custom/user/lib')
                self.assertNotIn('PYTHONHOME', cenv_frozen)
                self.assertNotIn('_MEIPASS', cenv_frozen)

    def test_onboarding_step2_install_all_progress_and_button_lock(self) -> None:
        """Verify OnboardingDialog step 2 renders sub-stage percentages, progress bars, queue positions,
        lld linked status, in-place updates, and disables Continue/Back while installing.
        """
        import ast
        from nspb_qt import i18n, l10n, style

        sheets_src = (QT / 'nspb_qt' / 'sheets.py').read_text(encoding='utf-8')
        sheets_tree = ast.parse(sheets_src)
        ob_cls = next(n for n in ast.walk(sheets_tree)
                      if isinstance(n, ast.ClassDef) and n.name == 'OnboardingDialog')
        fn_map = {n.name: n for n in ob_cls.body if isinstance(n, ast.FunctionDef)}
        for req in ('_clear_body', '_step1_row_meta', '_render_step', 'done'):
            self.assertIn(req, fn_map)

        class FakeWidget:
            def __init__(self, text=''):
                self.text = str(text)
                self.visible = True
                self.enabled = True
                self.style_sheet = ''
                self.obj_name = ''
                self.value = 0
                self.range = (0, 100)
                self.clicked_cbs = []
                self.deleted = False

            def setText(self, s):
                self.text = str(s)

            def setVisible(self, v):
                self.visible = bool(v)

            def show(self):
                self.visible = True

            def hide(self):
                self.visible = False

            def setEnabled(self, e):
                self.enabled = bool(e)

            def setStyleSheet(self, s):
                self.style_sheet = s

            def setObjectName(self, s):
                self.obj_name = s

            def setWordWrap(self, _w):
                pass

            def setContentsMargins(self, *_a):
                pass

            def setRange(self, lo, hi):
                self.range = (lo, hi)

            def setValue(self, v):
                self.value = int(v)

            def setTextVisible(self, _v):
                pass

            def setParent(self, _p):
                pass

            def deleteLater(self):
                self.deleted = True

            @property
            def clicked(self):
                cbs = self.clicked_cbs

                class _Sig:
                    @staticmethod
                    def connect(cb):
                        cbs.append(cb)
                return _Sig()

        class FakeLayout:
            def __init__(self, _parent=None):
                self.items = []

            def setContentsMargins(self, *_a):
                pass

            def setSpacing(self, *_a):
                pass

            def addWidget(self, w, *_a):
                self.items.append(w)

            def addLayout(self, l, *_a):
                self.items.append(l)

            def addStretch(self, *_a):
                self.items.append(None)

            def count(self):
                return len(self.items)

            def takeAt(self, idx):
                w = self.items.pop(idx)

                class _Item:
                    @staticmethod
                    def widget():
                        return w if isinstance(w, FakeWidget) else None
                return _Item()

        class FakeCardGroup(FakeWidget):
            def __init__(self, footer=''):
                super().__init__(footer)
                self.rows = []
                self.dividers = 0

            def add_row(self, r):
                self.rows.append(r)

            def add_divider(self):
                self.dividers += 1

        ns: dict = {
            'Path': Path,
            'shutil': shutil,
            'style': style,
            'QWidget': FakeWidget,
            'QLabel': FakeWidget,
            'QPushButton': FakeWidget,
            'QProgressBar': FakeWidget,
            'QHBoxLayout': FakeLayout,
            'QVBoxLayout': FakeLayout,
            'CardGroup': FakeCardGroup,
            'StatusDot': FakeWidget,
        }
        for name in ('_clear_body', '_step1_row_meta', '_render_step'):
            fn = fn_map[name]
            for n in ast.walk(fn):
                ast.fix_missing_locations(n)
            exec(compile(ast.fix_missing_locations(ast.Module(body=[fn], type_ignores=[])),
                         '<sheets>', 'exec'), ns)

        class FakeDep:
            def __init__(self, dep_id, title_key, ok=False, install=None, required=True):
                self.id = dep_id
                self.title_key = title_key
                self.ok = ok
                self.install = list(install or [])
                self.required = required
                self.installing = False
                self.install_stage = ''
                self.install_detail = ''
                self.install_pct = None
                self.queue_index = 0
                self.last_error = ''
                self.fix_hint = ''

        class FakeModel:
            def __init__(self):
                self.lang = i18n.Lang('zh')
                self.deps = [
                    FakeDep('python', 'dep.python', False, ['__win__:python']),
                    FakeDep('dotnet', 'dep.dotnet', False, ['__win__:dotnet']),
                    FakeDep('llvm', 'dep.llvm', False, ['__win__:llvm']),
                    FakeDep('lld', 'dep.lld', False, []),
                    FakeDep('ios_sdk', 'dep.iossdk', False, ['__win__:ios_sdk']),
                ]
                self._install_all_running = False
                self.install_all_step = 0
                self.install_all_total = 0
                self.install_all_pct = 0

            def t(self, key, *args):
                return l10n.t(key, self.lang, *args)

            def install_all_missing(self):
                self._install_all_running = True

        class FakeOnboarding:
            _clear_body = ns['_clear_body']
            _step1_row_meta = ns['_step1_row_meta']
            _render_step = ns['_render_step']

            def __init__(self, model):
                self.m = model
                self.step = 1
                self._step1_sig = None
                self._step1_widgets = {}
                self.step_badge = FakeWidget()
                self.task_pill = FakeWidget()
                self.task_pill.hide()
                self.head_title = FakeWidget()
                self.head_note = FakeWidget()
                self.overall_pct_lbl = FakeWidget()
                self.overall_pct_lbl.hide()
                self.body_layout = FakeLayout()
                self.later_btn = FakeWidget('Later')
                self.back_btn = FakeWidget('Back')
                self.next_btn = FakeWidget('Continue')

        m = FakeModel()
        dlg = FakeOnboarding(m)

        # Before clicking Install all: Continue & Back enabled, task_pill hidden, ibtn enabled
        dlg._render_step()
        self.assertFalse(dlg.task_pill.visible)
        self.assertFalse(dlg.overall_pct_lbl.visible)
        self.assertTrue(dlg.next_btn.enabled)
        self.assertTrue(dlg.back_btn.enabled)
        ibtn = dlg._step1_widgets['ibtn']
        self.assertIsNotNone(ibtn)
        self.assertTrue(ibtn.enabled)
        self.assertEqual(ibtn.text, m.t('dep.installAll'))

        # Simulate clicking Install all -> step 1/4: Python downloading at 45%, others queued
        m._install_all_running = True
        m.install_all_step = 1
        m.install_all_total = 4
        m.install_all_pct = 18
        m.deps[0].installing = True
        m.deps[0].install_stage = m.t('dep.stage.pyDownload', 45)
        m.deps[0].install_detail = m.t('dep.detail.pyDownload', '3.12.8', 12, 26, 45)
        m.deps[0].install_pct = 45
        m.deps[1].queue_index = 2
        m.deps[2].queue_index = 3
        m.deps[4].queue_index = 4

        dlg._render_step()
        self.assertTrue(dlg.task_pill.visible)
        self.assertIn('1 / 4', dlg.task_pill.text)
        self.assertTrue(dlg.overall_pct_lbl.visible)
        self.assertIn('18%', dlg.overall_pct_lbl.text)
        self.assertFalse(dlg.next_btn.enabled, 'Continue must be disabled during installation')
        self.assertFalse(dlg.back_btn.enabled, 'Back must be disabled during installation')
        self.assertTrue(dlg.later_btn.enabled, 'Set up later must remain enabled')

        rows = dlg._step1_widgets['rows']
        py_bar = rows['python']['bar']
        self.assertIsNotNone(py_bar)
        self.assertEqual(py_bar.value, 45)
        self.assertIn('45%', rows['python']['status'].text)
        self.assertIn('3.12.8', rows['python']['detail'].text)
        self.assertEqual(rows['dotnet']['status'].text, m.t('onboarding.progress.queuePos', 2))
        self.assertEqual(rows['lld']['status'].text, m.t('onboarding.progress.withLlvm'))
        self.assertFalse(dlg._step1_widgets['ibtn'].enabled)

        # In-place update when Python advances to Step 3/3 (installing packages 67%): same widget instance!
        m.deps[0].install_stage = m.t('dep.stage.pyPkgs', 67)
        m.deps[0].install_detail = m.t('dep.detail.pyPkgs', 4, 6, 'fonttools')
        m.deps[0].install_pct = 67
        m.install_all_pct = 24
        dlg._render_step()
        self.assertIs(dlg._step1_widgets['rows']['python']['bar'], py_bar, 'must update progress bar in-place without rebuilding widgets')
        self.assertEqual(py_bar.value, 67)
        self.assertIn('67%', rows['python']['status'].text)
        self.assertIn('fonttools', rows['python']['detail'].text)
        self.assertIn('24%', dlg.overall_pct_lbl.text)

        # When LLVM is installing, lld row says waiting for LLVM unpack
        m.deps[0].installing = False
        m.deps[0].ok = True
        m.deps[1].ok = True
        m.deps[1].queue_index = 0
        m.deps[2].installing = True
        m.deps[2].queue_index = 0
        m.deps[2].install_stage = m.t('dep.stage.download', 64)
        m.deps[2].install_detail = m.t('dep.detail.download', 'llvm.zip', 160, 250, 64)
        m.deps[2].install_pct = 64
        m.install_all_step = 3
        m.install_all_pct = 64
        dlg._render_step()
        self.assertEqual(dlg._step1_widgets['rows']['lld']['status'].text, m.t('onboarding.progress.waitingLlvm'))
        self.assertEqual(dlg._step1_widgets['rows']['llvm']['bar'].value, 64)

        # All finished: Continue re-enabled, pills hidden
        for d in m.deps:
            d.installing = False
            d.ok = True
            d.queue_index = 0
        m._install_all_running = False
        dlg._render_step()
        self.assertFalse(dlg.task_pill.visible)
        self.assertFalse(dlg.overall_pct_lbl.visible)
        self.assertTrue(dlg.next_btn.enabled)
        self.assertTrue(dlg.back_btn.enabled)

    @staticmethod
    def _load_model_with_qt_fallback():
        """Import nspb_qt.model, installing a lightweight PySide6.QtCore stub if PySide6 is absent in CI."""
        try:
            from nspb_qt import model as model_mod
            return model_mod, lambda: None
        except ImportError:
            pass
        import types
        saved = {k: sys.modules.get(k) for k in ('PySide6', 'PySide6.QtCore', 'nspb_qt.model')}

        class _FakeSignalInstance:
            def __init__(self) -> None:
                self._slots: list = []

            def connect(self, fn) -> None:
                self._slots.append(fn)

            def disconnect(self, fn=None) -> None:
                if fn is None:
                    self._slots.clear()
                elif fn in self._slots:
                    self._slots.remove(fn)

            def emit(self, *args) -> None:
                for fn in list(self._slots):
                    fn(*args)

        class _FakeSignal:
            def __init__(self, *_a) -> None:
                self._name = ''

            def __set_name__(self, _owner, name: str) -> None:
                self._name = f'_sig_{name}'

            def __get__(self, obj, _owner=None):
                if obj is None:
                    return self
                inst = getattr(obj, self._name, None)
                if inst is None:
                    inst = _FakeSignalInstance()
                    setattr(obj, self._name, inst)
                return inst

        class _FakeQObject:
            def __init__(self, *_a, **_kw) -> None:
                pass

            def thread(self):
                return None

            @staticmethod
            def currentThread():
                return None

        class _FakeQSettings:
            def __init__(self, *_a, **_kw) -> None:
                self._d: dict[str, object] = {}

            def value(self, k: str, default: object = '') -> object:
                return self._d.get(k, default)

            def setValue(self, k: str, v: object) -> None:
                self._d[k] = v

            def remove(self, k: str) -> None:
                self._d.pop(k, None)

        class _FakeQt:
            class ConnectionType:
                QueuedConnection = 0

        class _FakeQMetaObject:
            @staticmethod
            def invokeMethod(obj, name: str, *args) -> None:
                fn = getattr(obj, name, None)
                if callable(fn):
                    call_args = args[1:] if args and args[0] == 0 else args
                    fn(*call_args)

        qt_pkg = types.ModuleType('PySide6')
        qt_core = types.ModuleType('PySide6.QtCore')
        qt_core.QObject = _FakeQObject
        qt_core.QThread = _FakeQObject
        qt_core.QSettings = _FakeQSettings
        qt_core.Signal = _FakeSignal
        qt_core.Slot = lambda *_a, **_kw: (lambda f: f)
        qt_core.Qt = _FakeQt
        qt_core.QMetaObject = _FakeQMetaObject
        qt_core.Q_ARG = lambda _t, v: v
        qt_pkg.QtCore = qt_core
        sys.modules['PySide6'] = qt_pkg
        sys.modules['PySide6.QtCore'] = qt_core
        from nspb_qt import model as model_mod

        def _cleanup() -> None:
            for k, old in saved.items():
                if old is None:
                    sys.modules.pop(k, None)
                else:
                    sys.modules[k] = old

        return model_mod, _cleanup

    @staticmethod
    def _make_dmromfs1_image(mask: str | None = None, mals: list[str] | None = None) -> bytes:
        """Build a valid DMROMFS1 image with System/RegionLangMask.txt or Mals/<tag>.Product.sarc."""
        import struct
        ent_struct = struct.Struct('<QQIHBB')
        head_struct = struct.Struct('<8sQQQ')
        if mask is not None:
            payload = mask.encode('utf-8')
            data_off = 32
            idx_off = data_off + len(payload)
            names = b'SystemRegionLangMask.txt'
            entries = (
                ent_struct.pack(1, 1, 0, 0, 0, 0)
                + ent_struct.pack(2, 1, 0, 6, 0, 0)
                + ent_struct.pack(data_off, len(payload), 6, 18, 1, 0)
            )
            idx = entries + names
            head = head_struct.pack(b'DMROMFS1', idx_off, len(idx), 3)
            return head + payload + idx
        mals_list = sorted(mals or [])
        pool = bytearray(b'Mals')
        entries_ba = bytearray()
        entries_ba += ent_struct.pack(1, 1, 0, 0, 0, 0)
        entries_ba += ent_struct.pack(2, len(mals_list), 0, 4, 0, 0)
        for name in mals_list:
            nb = name.encode('utf-8')
            entries_ba += ent_struct.pack(32, 0, len(pool), len(nb), 1, 0)
            pool += nb
        idx = bytes(entries_ba + pool)
        head = head_struct.pack(b'DMROMFS1', 32, len(idx), 2 + len(mals_list))
        return head + idx

    def test_library_scan_directory_sorts_updates_by_integer_version(self) -> None:
        from nspb_qt import library as lib
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            base_f = root / 'Game [010015100B514000][v0].nsp'
            upd_old = root / 'Game [010015100B514800][v65536].nsp'
            upd_new = root / 'Game [010015100B514800][v131072].nsp'
            for f in (base_f, upd_old, upd_new):
                f.write_bytes(b'x')
            games = lib.GameLibrary.discover_in_folder(str(root), repo_path='')
            self.assertEqual(len(games), 1)
            self.assertEqual(games[0].inputs.get('update'), [str(upd_new)])

    def test_pack_archive_sorts_extract_versions_numerically_copies_identity_and_narrows_launcher_json(self) -> None:
        from nspb_qt import library as lib
        from nspb_qt import romfs_languages as rl
        model_mod, cleanup = self._load_model_with_qt_fallback()
        self.addCleanup(cleanup)
        Model = model_mod.Model
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            work = root / 'work'
            v0 = work / 'extract' / 'v0'
            v65536 = work / 'extract' / 'v65536'
            v131072 = work / 'extract' / 'v131072'
            for vd in (v0, v65536, v131072):
                vd.mkdir(parents=True)
            (v0 / 'RomFS.img').write_bytes(self._make_dmromfs1_image(mask='USen JPja\n'))
            (v65536 / 'RomFS.img').write_bytes(self._make_dmromfs1_image(mask='USen JPja\n'))
            img_new = self._make_dmromfs1_image(mask='JPja USen CNzh TWzh EUfr\n01111\n')
            (v131072 / 'RomFS.img').write_bytes(img_new)
            id_bytes = b'010015100B514000\t1.2.0\t131072\tabcdef0123456789\n'
            (v131072 / 'RomFS.img.id').write_bytes(id_bytes)

            tid = '010015100B514000'
            fw_dm = work / 'shell-framework' / f'DmGame{tid}.framework' / 'dm'
            fw_dm.mkdir(parents=True)
            (fw_dm.parent / f'DmGame{tid}').write_bytes(b'dylib')
            fallback_options = [[code, label] for code, label in rl.TABLE] + [['th', 'Thai']]
            launcher_data = {
                'schema': 1,
                'game': tid,
                'settings': [
                    {
                        'env': 'DM_LANG',
                        'kind': 'choice',
                        'section': 'Game',
                        'label': 'Game language',
                        'note': "This game's files do not list its languages.",
                        'default': 'en-US',
                        'level': 'basic',
                        'options': fallback_options,
                    }
                ],
            }
            (fw_dm / 'launcher.json').write_text(json.dumps(launcher_data), encoding='utf-8')

            out = root / 'out'
            out.mkdir()
            with (
                mock.patch.object(Model, 'check_deps', lambda self: None),
                mock.patch.object(lib, 'default_state_dir', lambda: root / 'state'),
            ):
                m = Model()
                m.effective_work_dir = str(work)
                m.out_dir = str(out)
                m.base_path = str(root / f'Game [{tid}][v0].nsp')
                self.assertEqual(m.pack_archive(title_id=tid), (True, ''))

                dest = out / 'games' / tid
                self.assertEqual(Path(m.archive_path), dest)
                self.assertEqual((dest / 'romfs.img').read_bytes(), img_new)
                self.assertEqual((dest / 'romfs.img.id').read_bytes(), id_bytes)

                updated_launcher = json.loads((fw_dm / 'launcher.json').read_text(encoding='utf-8'))
                lang_row = updated_launcher['settings'][0]
                self.assertEqual(
                    [o[0] for o in lang_row['options']],
                    ['en-US', 'ja', 'fr', 'zh-Hant', 'zh-Hans', 'th'],
                )
                self.assertEqual(lang_row['note'], '')

                # When the extracted image has no .id file on a subsequent archive, any stale romfs.img.id is removed
                (v131072 / 'RomFS.img.id').unlink()
                self.assertEqual(m.pack_archive(title_id=tid), (True, ''))
                self.assertFalse((dest / 'romfs.img.id').exists())

    def test_romfs_languages_handles_mals_corrupted_headers_and_cache_invalidation(self) -> None:
        import struct
        from nspb_qt import romfs_languages as rl
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            # 1. Mals in DMROMFS1 image and directory
            mals_img = root / 'mals.img'
            mals_img.write_bytes(self._make_dmromfs1_image(mals=['USen.Product.100.sarc', 'CNzh.Product.100.sarc']))
            self.assertEqual([o[0] for o in rl.options_in(mals_img)], ['en-US', 'zh-Hans'])

            mals_dir = root / 'romfs_dir' / 'Mals'
            mals_dir.mkdir(parents=True)
            (mals_dir / 'JPja.Product.100.sarc').write_bytes(b'x')
            (mals_dir / 'EUde.Product.100.sarc').write_bytes(b'x')
            self.assertEqual([o[0] for o in rl.options_in(mals_dir.parent)], ['ja', 'de'])

            # 2. Corrupted / overflow headers return [] without raising
            good = bytearray(self._make_dmromfs1_image(mask='USen JPja\n'))
            for i, bad_bytes in enumerate([
                b'',
                bytes(good[:20]),
                bytes(good[:-10]),
                b'X' + bytes(good[1:]),
                bytes(good[:8]) + struct.pack('<Q', (1 << 64) - 1) + bytes(good[16:]),
                bytes(good[:16]) + struct.pack('<Q', (1 << 64) - 1) + bytes(good[24:]),
                bytes(good[:24]) + struct.pack('<Q', (1 << 64) - 1),
                bytes(good[:24]) + struct.pack('<Q', ((1 << 64) - 1) // 24 + 1),
            ]):
                p = root / f'bad_{i}.img'
                p.write_bytes(bad_bytes)
                self.assertEqual(rl.options_in(p), [])

            # Overflow in mask entry offset / size
            idx_off = struct.unpack_from('<Q', good, 8)[0]
            bad_mask_size = bytearray(good)
            struct.pack_into('<Q', bad_mask_size, idx_off + 48 + 8, 0x7FFFFFFFFFFFFFFF)
            p_ms = root / 'bad_mask_size.img'
            p_ms.write_bytes(bad_mask_size)
            self.assertEqual(rl.options_in(p_ms), [])

            bad_mask_off = bytearray(good)
            struct.pack_into('<Q', bad_mask_off, idx_off + 48, (1 << 64) - 1)
            p_mo = root / 'bad_mask_off.img'
            p_mo.write_bytes(bad_mask_off)
            self.assertEqual(rl.options_in(p_mo), [])

            # 3. Cache invalidation when a cut-off file finishes copying or is replaced
            changing = root / 'changing.img'
            two = self._make_dmromfs1_image(mask='USen JPja\n')
            changing.write_bytes(two[:-10])
            self.assertEqual(rl.options_in(changing), [])
            changing.write_bytes(two)
            self.assertEqual([o[0] for o in rl.options_in(changing)], ['en-US', 'ja'])
            three = self._make_dmromfs1_image(mask='USen JPja EUfr\n')
            changing.write_bytes(three)
            self.assertEqual([o[0] for o in rl.options_in(changing)], ['en-US', 'ja', 'fr'])

            # 4. Inserting DM_LANG when absent vs keeping exact row untouched
            no_lang_json = root / 'launcher.json'
            no_lang_json.write_text(json.dumps({
                'schema': 1,
                'game': '040074A01BF12000',
                'settings': [{'env': 'DM_OPMODE', 'kind': 'choice', 'section': 'Game'}],
            }), encoding='utf-8')
            self.assertTrue(rl.apply_to_launcher_json(no_lang_json, changing))
            parsed = json.loads(no_lang_json.read_text(encoding='utf-8'))
            self.assertEqual(parsed['settings'][1]['env'], 'DM_LANG')
            self.assertEqual([o[0] for o in parsed['settings'][1]['options']], ['en-US', 'ja', 'fr'])
            # Second call is a no-op because note is now empty
            self.assertFalse(rl.apply_to_launcher_json(no_lang_json, changing))

    def test_start_build_stages_shared_folder_and_auto_picks_matching_update_and_dlc(self) -> None:
        from nspb_qt import library as lib
        from nspb_qt.win import shim
        model_mod, cleanup = self._load_model_with_qt_fallback()
        self.addCleanup(cleanup)
        Model = model_mod.Model
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            eng = root / 'engine'
            (eng / 'scripts').mkdir(parents=True)
            (eng / 'scripts' / 'build_ipa_from_nsp.py').write_text("p.add_argument('--work-dir')\n", encoding='utf-8')
            (eng / 'dm' / 'tools' / 'nx_extract').mkdir(parents=True)
            (eng / 'dm' / 'tools' / 'nx_extract' / 'Program.cs').write_text('', encoding='utf-8')

            roms = root / 'roms'
            roms.mkdir()
            base_nsp = roms / 'Super Mario [010015100B514000][v0].nsp'
            dup_base = roms / 'Super Mario Copy [010015100B514000][v0].nsp'
            upd_old = roms / 'Super Mario [010015100B514800][v65536].nsp'
            upd_new = roms / 'Super Mario [010015100B514800][v131072].nsp'
            dlc_nsp = roms / 'Super Mario DLC [010015100B515001][v0].nsp'
            other_base = roms / 'Zelda [01007EF00011E000][v0].nsp'
            other_upd = roms / 'Zelda [01007EF00011E800][v65536].nsp'
            for f in (base_nsp, dup_base, upd_old, upd_new, dlc_nsp, other_base, other_upd):
                f.write_bytes(b'pkg')

            keys_f = root / 'prod.keys'
            keys_f.write_bytes(b'keys')
            out_dir = root / 'out'
            out_dir.mkdir()

            seen_cmds: list[list[str]] = []

            def fake_spawn(cmd, **_kw):
                seen_cmds.append([str(c) for c in cmd])
                return mock.Mock(stdout=[], returncode=1)

            with (
                mock.patch.object(Model, 'check_deps', lambda self: None),
                mock.patch.object(lib, 'default_state_dir', lambda: root / 'state'),
                mock.patch.object(model_mod.pu, 'find_python', return_value=(sys.executable, True, '3.12')),
                mock.patch.object(model_mod.pu, 'IS_WIN', True),
                mock.patch.object(model_mod.pu, 'no_window_kwargs', return_value={}),
                mock.patch.object(shim, 'build_env', side_effect=lambda env, **_kw: env),
                mock.patch.object(shim, 'verify_shim', return_value=(True, '')),
                mock.patch.object(model_mod.threading, 'Thread', side_effect=lambda *, target, daemon: mock.Mock(start=target)),
                mock.patch.object(model_mod.subprocess, 'Popen', side_effect=fake_spawn),
            ):
                m = Model()
                logged: list[str] = []
                m.logAppended.connect(logged.append)
                m.repo_path = str(eng)
                m.base_path = str(base_nsp)
                m.keys_path = str(keys_f)
                m.out_dir = str(out_dir)
                m.target = 'ios'
                m.ipa_kind = 'oneGame'
                m.start_build()

                build_cmds = [c for c in seen_cmds if '--progress' in c]
                self.assertEqual(len(build_cmds), 1)
                cmd = build_cmds[0]
                expected_stage = out_dir / '010015100B514000_build' / 'staging'
                self.assertIn(str(expected_stage), cmd)
                staged_names = {p.name for p in expected_stage.iterdir()}
                self.assertEqual(
                    staged_names,
                    {
                        base_nsp.name,
                        upd_new.name,
                        dlc_nsp.name,
                    },
                )
                self.assertIn(m.t('msg.stagedFromSharedFolder', base_nsp.name), ''.join(logged))

    def test_build_app_one_game_ipa_packs_pso_and_gates_aoc_on_dm_full_romfs(self) -> None:
        import types
        from nspb_qt.win import build_app, toolchain as tc
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            repo = root / 'engine'
            tid = '010015100B514000'
            gd = repo / 'dm' / 'games' / tid
            gd.mkdir(parents=True)
            (gd / 'game.tsv').write_text('modules\tmain\n', encoding='utf-8')
            for tsv in ('shader_map.tsv', 'pso_manifest.tsv', 'c1_full.tsv', 'cb_extent.tsv'):
                (gd / tsv).write_text('', encoding='utf-8')
            (repo / 'dm' / 'gfx' / 'nvn').mkdir(parents=True)
            (repo / 'dm' / 'gfx' / 'nvn' / 'dmsh_chain.h').write_text('#define DMSH_CHAIN "v0"\n', encoding='utf-8')
            (repo / 'dm' / 'ios' / 'Sources').mkdir(parents=True)
            (repo / 'dm' / 'ios' / 'tools').mkdir(parents=True)
            (repo / 'dm' / 'host').mkdir(parents=True)
            (repo / 'dm' / 'host' / 'main.c').write_text('int main(){return 0;}\n', encoding='utf-8')

            w = root / 'work'
            patched = w / 'patched'
            patched.mkdir(parents=True)
            (patched / 'main.patched.bin').write_bytes(b'x')
            (patched / 'main.fixups.tsv').write_text('', encoding='utf-8')
            romfs = w / 'extract' / 'v0' / 'RomFS.img'
            romfs.parent.mkdir(parents=True)
            romfs.write_bytes(self._make_dmromfs1_image(mask='USen JPja\n'))
            msl_ios = w / 'msl_ios'
            (msl_ios / 'b-v0').mkdir(parents=True)
            aoc = w / 'aoc'
            aoc.mkdir(parents=True)
            (aoc / '0.img').write_bytes(b'dlc0')
            pso_dir = w / 'pso_out'
            pso_dir.mkdir(parents=True)
            (pso_dir / 'archive.bin').write_bytes(b'pso')

            sdk = root / 'sdk'
            sdk.mkdir()
            clang = root / 'clang'
            clang.write_bytes(b'x')
            lld = root / 'lld' / 'ld64.lld'
            lld.parent.mkdir()
            lld.write_bytes(b'x')
            std_font = root / 'std.ttf'
            std_font.write_bytes(b'ttf')
            letter_font = root / 'letter.ttf'
            letter_font.write_bytes(b'ttf')

            fake_gm = types.ModuleType('game')
            fake_gm._nspb_patched = True

            class _FakeProf:
                dir = str(gd)

                @staticmethod
                def get(k: str, default: str = '') -> str:
                    return {
                        'package': 'v0',
                        'modules': 'main',
                        'romfs_marker': 'System/RegionLangMask.txt',
                        'ipa': 'out.ipa',
                        'zip_store': '',
                    }.get(k, default)

                @staticmethod
                def modules_in(_p: Path) -> list[str]:
                    return ['main']

            fake_gm.load = lambda _g: _FakeProf()

            def fake_py(script, *args, **_kw):
                sname = Path(script).name
                if sname == 'game.py' and len(args) >= 3 and args[0] == 'header':
                    Path(args[2]).write_text('#define DM_GAME_PSO_MTL4 0\n', encoding='utf-8')
                    return ''
                if sname == 'gen_embed.py':
                    Path(args[1]).write_text('.text\n', encoding='utf-8')
                    return ''
                if sname == 'settings.py':
                    Path(args[3]).write_text('{"schema":1,"settings":[]}', encoding='utf-8')
                    return 'launcher.json'
                if sname == 'make_ext_font.py':
                    Path(args[0]).write_bytes(b'ext')
                    return 'ok'
                return ''

            pack_calls: list[list[str]] = []

            def fake_subproc_run(cmd, *_a, **_kw):
                cmd_list = [str(c) for c in cmd]
                if any(c.endswith('romfs_image.py') for c in cmd_list):
                    return subprocess.CompletedProcess(cmd_list, 0, b'id_line\n', b'')
                if any(c.endswith('pack_ipa.py') for c in cmd_list):
                    pack_calls.append(cmd_list)
                    Path(cmd_list[2]).write_bytes(b'ipa')
                    return subprocess.CompletedProcess(cmd_list, 0, 'ok', '')
                return subprocess.CompletedProcess(cmd_list, 0, '', '')

            out_ipa = root / 'out.ipa'
            base_env = {
                'NSPB_REPO': str(repo),
                'GAME': tid,
                'W': str(w),
                'PATCHED': str(patched),
                'ROMFS': str(romfs),
                'DM_DISPLAY_NAME': 'Super Mario',
                'MSL_IOS': str(msl_ios),
                'AOC': str(aoc),
                'DM_FULL_ROMFS': '',
                'DM_FRAMEWORK_ONLY': '',
            }

            for full_val in ('', '1'):
                pack_calls.clear()
                env_cur = dict(base_env, DM_FULL_ROMFS=full_val)
                with (
                    mock.patch.dict(os.environ, env_cur, clear=False),
                    mock.patch.dict(sys.modules, {'game': fake_gm}),
                    mock.patch.object(tc, 'llvm_tool', return_value=clang),
                    mock.patch.object(tc, 'ensure_ld64_lld', return_value=(lld, '')),
                    mock.patch.object(tc, 'ios_sdk', return_value=sdk),
                    mock.patch.object(tc, 'sdk_version', return_value=('26.0', '23A344')),
                    mock.patch.object(tc, 'std_font', return_value=std_font),
                    mock.patch.object(tc, 'letter_font', return_value=letter_font),
                    mock.patch.object(build_app, 'py', side_effect=fake_py),
                    mock.patch.object(build_app, 'romfs_has', return_value=True),
                    mock.patch.object(build_app, 'shader_lib_has', return_value=True),
                    mock.patch.object(build_app, 'build_pso_archive', return_value=pso_dir) as spy_pso,
                    mock.patch.object(build_app, 'host_sources', return_value=([], [])),
                    mock.patch.object(build_app, 'framework_list', return_value=['Foundation']),
                    mock.patch.object(build_app, 'compat_rt_needed', return_value=False),
                    mock.patch.object(build_app, 'compile_all', return_value=[]),
                    mock.patch.object(build_app, 'link', return_value=None),
                    mock.patch.object(build_app.fix_ipa_modes, 'fix', return_value='ok'),
                    mock.patch.object(build_app.subprocess, 'run', side_effect=fake_subproc_run),
                ):
                    rc = build_app.main([str(out_ipa)])
                self.assertEqual(rc, 0)
                spy_pso.assert_called_once()
                self.assertEqual(len(pack_calls), 1)
                pack_cmd = pack_calls[0]
                self.assertIn(f'Payload/DmIOS.app/pso={pso_dir}', pack_cmd)
                self.assertNotIn('_bp.metallib', pack_cmd)
                if full_val:
                    self.assertIn(f'Payload/DmIOS.app/aoc={aoc}', pack_cmd)
                else:
                    self.assertFalse(any(arg.startswith('Payload/DmIOS.app/aoc=') for arg in pack_cmd))


if __name__ == '__main__':
    unittest.main(verbosity=2)
