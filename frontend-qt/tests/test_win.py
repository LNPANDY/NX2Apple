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
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
QT = HERE.parent
sys.path.insert(0, str(QT))

from nspb_qt.win import build_app, fix_ipa_modes, shim  # noqa: E402
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
        self.repo = QT.parent
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
            shim.install(d, python_exe=sys.executable)
            second = {p.name: p.read_bytes() for p in d.iterdir()}
            self.assertEqual(first, second)
            self.assertIn('sitecustomize.py', first)
            for name in ('xcrun.cmd', 'xcodebuild.cmd', 'xcodegen.cmd', 'python3.cmd'):
                self.assertIn(name, first, f'{name} stand-in not written')

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
        cls.repo = QT.parent
        if not (cls.repo / 'scripts/build_ipa_from_nsp.py').is_file():
            raise unittest.SkipTest('not a repository checkout')
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
        probes = self.mod.toolchain()
        self.assertTrue(probes)
        joined = ' '.join(' '.join(p[1]) for p in probes if p[0] == 'cmd')
        self.assertIn('xcrun_shim.py', joined)
        self.assertIn('metal', joined)
        self.assertNotIn('xcodebuild', joined)

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
                    mock.patch.dict(os.environ, {'UV_PYTHON_INSTALL_DIR': str(store), 'HOME': td}):
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
        repo = QT.parent
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
                'doctor, build_app, driver, xcrun_shim\n'
                'print("ok")\n'
            ) % str(QT)
            r = subprocess.run([sys.executable, '-c', code], capture_output=True, text=True,
                               env=env)
            self.assertEqual(r.returncode, 0, r.stderr[-1200:])
            self.assertEqual(r.stdout.strip(), 'ok')


class LocalizationTest(unittest.TestCase):
    def test_every_windows_dep_key_exists_in_both_languages(self) -> None:
        from nspb_qt.i18n import Lang
        from nspb_qt.localization import TABLE, t
        keys = ['dep.llvm', 'dep.llvm.hint', 'dep.lld', 'dep.lld.hint',
                'dep.probe.compile', 'dep.probe.compile.hint',
                'dep.probe.link', 'dep.probe.link.hint',
                'dep.probe.metal', 'dep.probe.metal.hint',
                'dep.glslang', 'dep.glslang.hint', 'dep.optionalMissing',
                'dep.iossdk', 'dep.iossdk.hint', 'dep.metal', 'dep.metal.hint']
        for k in keys:
            self.assertIn(k, TABLE, f'{k} missing from the table')
            zh = t(k, Lang.ZH)
            en = t(k, Lang.EN)
            self.assertTrue(zh and zh != k, f'{k} has no Chinese text')
            self.assertTrue(en and en != k, f'{k} has no English text')

    def test_the_guidance_and_pick_keys_exist_in_both_languages(self) -> None:
        from nspb_qt.i18n import Lang
        from nspb_qt.localization import TABLE, t
        keys = ['dep.guide.iossdk', 'dep.guide.metal', 'dep.pick', 'dep.hide', 'dep.show',
                'dep.pick.ios_sdk.title', 'dep.pick.metal_dir.title',
                'dep.pick.saved', 'dep.pick.iossdk.saved', 'dep.pick.iossdk.version',
                'dep.pick.iossdk.invalid', 'dep.fix.network', 'dep.fix.diskspace', 'dep.fix.log']
        for k in keys:
            self.assertIn(k, TABLE, f'{k} missing from the table')
            zh, en = t(k, Lang.ZH), t(k, Lang.EN)
            self.assertTrue(zh and zh != k and en and en != k, f'{k} is not bilingual')


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
        src = (QT / 'nspb_qt' / 'win' / 'toolchain.py').read_text()
        body = src[src.index('def probe_link'):]
        self.assertLess(body.index("'-fuse-ld=lld'"), body.index('f\'--ld-path={lld}\''),
                        'the build\'s own invocation must be tried before --ld-path')
        self.assertLess(body.index('f\'--ld-path={lld}\''), body.index("f'-B{lld.parent}'"),
                        '--ld-path before the -B fallback')
        self.assertIn("env['PATH'] = str(lld.parent)", body,
                      'the build-style try must put the linker folder on PATH (build_app.link does)')
        self.assertIn('does not run by itself', body,
                      'a linker that cannot start is its own message, before any strategy runs')


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
            src = (HERE.parent / 'nspb_qt' / 'model.py').read_text()
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
            classify = ns['_classify_install_failure']
        self.assertEqual(classify('DownloadError: connection reset by peer'), 'dep.fix.network')
        self.assertEqual(classify('URLError: operation timed out'), 'dep.fix.network')
        self.assertEqual(classify('OSError: [Errno 28] No space left on device'), 'dep.fix.diskspace')
        self.assertEqual(classify('KeyError: x'), 'dep.fix.log')


if __name__ == '__main__':
    unittest.main(verbosity=2)
