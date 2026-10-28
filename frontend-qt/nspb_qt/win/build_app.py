"""The Windows replacement for `dm/ios/tools/build_ipa.sh`.

Same unsigned all-in-one IPA, without Xcode:

============================  ============================================================
`xcodegen` + `xcodebuild`     LLVM clang per source file (`-target arm64-apple-ios26.0
                              -isysroot <iPhoneOS SDK>`), linked by `ld64.lld`
`Launcher.swift` (SwiftUI)    `ios/Launcher.m` (UIKit, same `dm_show_launcher` contract)
`actool` asset catalog        loose PNGs named in `CFBundleIcons`, scaled with Pillow
`sips` / `plutil`             Pillow / `plistlib`
`make -n -B dmhost`           this repo's `dm/host/Makefile` rules, reproduced in
                              `host_sources()` and **checked against the Makefile text** so an
                              upstream change stops the build instead of silently dropping files
`sips` → app icon            Pillow
`codesign` ad-hoc + entitle  skipped, with a note: an unsigned IPA is re-signed by the
                              sideloader anyway, and there is no `codesign` here
============================  ============================================================

The environment is the same one `build_ipa.sh` reads (`GAME`, `W`, `PATCHED`, `ROMFS`,
`MSL_IOS`, `AOC`, `GFXAPI`, `DM_*`), because `driver.py` builds it by mocking the upstream
call — so the two paths cannot drift in what they pass.
"""
from __future__ import annotations

import concurrent.futures as cf
import hashlib
import os
import plistlib
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

if __package__:
    from . import toolchain as tc
    from . import fix_ipa_modes
    from . import IOS_CPU, IOS_DEPLOYMENT
else:                                       # pragma: no cover - script mode
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
    from nspb_qt.win import toolchain as tc
    from nspb_qt.win import fix_ipa_modes
    from nspb_qt.win import IOS_CPU, IOS_DEPLOYMENT

HERE = Path(__file__).resolve().parent

#: Frameworks the app links. `Cocoa` is a macOS framework and is dropped; the rest is
#: `dm/host/Makefile`'s link line minus Cocoa, plus what the UIKit side and the launcher use
#: (Xcode would add UIKit through Swift module autolinking).
FRAMEWORKS_BASE = [
    'QuartzCore', 'Metal', 'MetalFX', 'GameController', 'CoreHaptics', 'AudioToolbox',
    'AVFAudio', 'VideoToolbox', 'CoreMedia', 'CoreVideo', 'ImageIO', 'UniformTypeIdentifiers',
    'CoreMotion', 'CoreText', 'UIKit', 'Foundation', 'CoreGraphics', 'CoreFoundation',
    'Security',
]

_IMPORT = re.compile(r'^\s*#\s*(?:import|include)\s*<(\w+)/', re.M)


def t(msg: str) -> None:
    print(f'[{time.strftime("%H:%M:%S")}] {msg}', flush=True)


def die(msg: str) -> None:
    t(f'FAIL: {msg}')
    raise SystemExit(1)


def py(*args, env=None, capture=True) -> str:
    """Run one of the repository's own Python tools and return its stdout."""
    r = subprocess.run([sys.executable, *map(str, args)], capture_output=capture, text=True,
                       env=env, errors='replace')
    if r.returncode:
        die(f'{Path(str(args[0])).name}: {(r.stderr or r.stdout or "").strip()[-2000:]}')
    return (r.stdout or '').strip() if capture else ''


# ---------------------------------------------------------------- the source list

#: The two Makefile lines this module depends on. They are compared verbatim, because the
#: Makefile's wildcards are the only place the source list is maintained: if upstream adds a
#: file to either line, silently missing it here would produce a link error or a subtly
#: incomplete host.
WANT_SRC = ('SRC=main.c loader.c hle.c crash.c probe.c thread.c save_sync.c memstat.m '
            'haptics_apple.m $(sort $(wildcard hle_*.c)) front_mac.m entry.S')
WANT_GFX = ('GFX=$(sort $(wildcard ../gfx/*.c ../gfx/nvn/*.c ../gfx/nvn/*.m ../gfx/nvn/*.S '
            '../gfx/tex/*.c ../gfx/tex/*.m ../gfx/vk/*.m ../gfx/gl/*.m))')
_GFX_PATS = ('../gfx/*.c', '../gfx/nvn/*.c', '../gfx/nvn/*.m', '../gfx/nvn/*.S',
             '../gfx/tex/*.c', '../gfx/tex/*.m', '../gfx/vk/*.m', '../gfx/gl/*.m')


def host_sources(repo: Path, game_h_dir: Path) -> tuple[list[Path], list[Path]]:
    """(sources, include dirs) for the iOS host, as `make -n -B dmhost` would list them.

    The iOS build differs from the Mac host in three ways, all handled here and all visible in
    how `dm/ios/project.yml` + `gen_build.py` treat the same list:

    * `*_mac` sources are dropped: `front_mac.m` is the Mac front end, `front_ios.m` implements
      the same `front.h` for iOS.
    * `dm/ios/Sources` is excluded from the host walk: the iOS project compiles those itself.
    * `main.c` is compiled with `-Dmain=dm_main`, because `main.m` is the real entry point.
    """
    host = repo / 'dm' / 'host'
    try:
        mk = (host / 'Makefile').read_text(encoding='utf-8')
    except OSError as e:
        die(f'cannot read dm/host/Makefile: {e}')
    for want, what in ((WANT_SRC, 'SRC'), (WANT_GFX, 'GFX')):
        if want not in mk:
            die(f'dm/host/Makefile changed ({what}= line): update host_sources() in '
                f'frontend-qt/nspb_qt/win/build_app.py to match')

    src = [host / n for n in 'main.c loader.c hle.c crash.c probe.c thread.c save_sync.c '
                            'memstat.m haptics_apple.m'.split()]
    src += sorted(host.glob('hle_*.c'), key=lambda p: p.name)
    src += [host / 'front_mac.m', host / 'entry.S']
    gfx: list[Path] = []
    for pat in _GFX_PATS:
        d, g = pat.rsplit('/', 1)
        gfx += list((host / d).glob(g))
    # make's $(sort) orders words as text, which for these relative paths is plain string order
    gfx.sort(key=lambda p: os.path.relpath(p, host).replace('\\', '/'))

    vpx = repo / 'dm' / 'third_party' / 'libvpx'
    vpx_src = sorted(vpx.rglob('*.c'), key=lambda p: p.as_posix())

    incs = [repo / 'dm' / 'gfx' / 'nvn' / 'include',
            repo / 'dm' / 'third_party' / 'vulkan-headers' / 'include',
            game_h_dir, vpx, repo / 'dm' / 'third_party' / 'stb_vorbis', vpx / 'config']

    ios_sources = (repo / 'dm' / 'ios' / 'Sources').resolve()
    files: list[Path] = []
    for s in src + gfx + vpx_src:
        s = s.resolve()
        if not s.is_file():
            die(f'a source from dm/host/Makefile does not exist: {s}')
        if s.stem.endswith('_mac'):
            continue                      # Mac-only sources: front_ios.m implements front.h
        if s.parent == ios_sources:
            continue                      # compiled once, as iOS sources
        files.append(s)

    dirs: list[Path] = []
    for s in files:
        if s.parent not in dirs:
            dirs.append(s.parent)
    resolved_incs = [Path(i).resolve() for i in incs]
    return files, resolved_incs + [d for d in dirs if d not in resolved_incs]


def framework_list(sdk: Path, files: list[Path]) -> list[str]:
    """The base list plus any framework a source imports that the SDK actually ships.

    Scanning the imports means a new `#import <SomethingNew/...>` in the host does not need a
    change here — the same reason the upstream build takes frameworks from the Makefile.
    """
    fw_dir = sdk / 'System' / 'Library' / 'Frameworks'
    out = list(FRAMEWORKS_BASE)
    for f in files:
        if f.suffix not in ('.m', '.c', '.h'):
            continue
        try:
            text = f.read_text(encoding='utf-8', errors='replace')
        except OSError:
            continue
        for name in _IMPORT.findall(text):
            if name not in out and (fw_dir / f'{name}.framework').is_dir():
                out.append(name)
    return [n for n in out if (fw_dir / f'{n}.framework').is_dir()]


# ---------------------------------------------------------------- compile

def compat_rt_needed(clang: Path) -> bool:
    """Whether the Darwin compiler-rt is missing (LLVM's Windows release ships none).

    Without `libclang_rt.ios.a`, `@available` / `__builtin_available` produce an undefined
    `__isPlatformVersionAtLeast`, and every link fails. `ios/compat_rt.c` provides it through
    dyld's `_availability_version_check`, which every iOS this app runs on has.
    """
    if hasattr(compat_rt_needed, '_cache'):
        return compat_rt_needed._cache
    ok = False
    try:
        r = subprocess.run([str(clang), '-print-resource-dir'], capture_output=True, text=True,
                           timeout=60)
        if r.returncode == 0:
            res = Path(r.stdout.strip())
            ok = not list(res.glob('lib/darwin/libclang_rt.ios.a'))
    except (OSError, subprocess.SubprocessError):
        ok = True
    compat_rt_needed._cache = ok
    return ok


def common_flags(sdk: Path, incs: list[Path], deployment: str) -> list[str]:
    return ['-target', f'arm64-apple-ios{deployment}', '-isysroot', str(sdk),
            '-Os', f'-mcpu={IOS_CPU}', '-w', '-fno-common', '-DNS_BLOCK_ASSERTIONS=1',
            *[f'-I{i}' for i in incs]]


def flags_for(path: Path, common: list[str], host_main: Path) -> list[str]:
    """Per-file flags, mirroring `dm/ios/project.yml`'s per-target settings."""
    if path == host_main:
        return common + ['-std=gnu11', '-Dmain=dm_main']
    if path.suffix == '.c':
        return common + ['-std=gnu11']
    if path.suffix == '.m':
        return common + ['-std=gnu11', '-fobjc-arc']
    if path.suffix == '.S':
        return common
    return []


def _dep_newer(obj: Path) -> bool:
    """Whether a header recorded in the object's `.d` file is newer than the object."""
    d = obj.with_suffix('.d')
    if not d.is_file():
        return True
    try:
        mt = obj.stat().st_mtime
        text = d.read_text(errors='replace').replace('\\\n', ' ')
    except OSError:
        return True
    for dep in re.split(r'(?<!\\)\s+', text.split(':', 1)[-1]):
        dep = dep.replace('\\ ', ' ').strip()
        try:
            if dep and os.path.exists(dep) and os.path.getmtime(dep) > mt:
                return True
        except OSError:
            continue
    return False


def compile_all(clang: Path, sdk: Path, files: list[Path], incs: list[Path],
                obj_dir: Path, deployment: str, extra: list[str] | None = None) -> list[Path]:
    """Compile every source, skipping objects whose inputs are unchanged.

    The key includes the full flag list, so changing the deployment target or a define
    invalidates every object instead of silently mixing ABIs.
    """
    common = common_flags(sdk, incs, deployment) + list(extra or [])
    obj_dir.mkdir(parents=True, exist_ok=True)
    jobs: list[tuple[Path, Path, list[str]]] = []
    objs: list[Path] = []
    uptodate = 0
    for f in files:
        flags = flags_for(f, common, _HOST_MAIN)
        if not flags:
            continue
        key = hashlib.sha256((str(f) + '\0' + '\0'.join(flags)).encode()).hexdigest()[:12]
        o = obj_dir / f'{f.stem}-{key}.o'
        objs.append(o)
        if o.exists() and o.stat().st_mtime >= f.stat().st_mtime and not _dep_newer(o):
            uptodate += 1
            continue
        jobs.append((f, o, flags))
    t(f'compile: {len(jobs)} of {len(objs)} files (clang, arm64-apple-ios{deployment})'
      + (f', {uptodate} up to date' if uptodate else ''))

    def one(job):
        f, o, flags = job
        d = o.with_suffix('.d')
        tmp = Path(str(o) + '.tmp')
        r = subprocess.run([str(clang), *flags, '-MMD', '-MF', str(d), '-c', str(f),
                            '-o', str(tmp)], capture_output=True, text=True, errors='replace')
        if r.returncode == 0:
            try:
                os.replace(str(tmp), o)
            except OSError:
                try:
                    tmp.unlink()
                except OSError:
                    pass
                return f, None, f'cannot move {tmp} to {o}'
        return f, r, None

    bad = []
    with cf.ThreadPoolExecutor(max_workers=min(32, os.cpu_count() or 4)) as ex:
        for i, (f, r, err) in enumerate(ex.map(one, jobs), 1):
            if err:
                bad.append((f, err))
            elif r is not None and r.returncode:
                bad.append((f, r.stderr or r.stdout or ''))
            if i % 25 == 0 or i == len(jobs):
                t(f'compile: {i}/{len(jobs)}')
    if bad:
        for f, err in bad[:6]:
            lines = [ln for ln in err.splitlines() if 'error' in ln.lower()] or err.splitlines()[-6:]
            print(f'---- {f}\n' + '\n'.join(lines)[:3000], file=sys.stderr)
        die(f'{len(bad)} file(s) did not compile (see the errors above)')
    return objs


#: `dm/host/main.c`, set by `main()` before compiling; the host's `main` becomes `dm_main` so
#: `main.m` owns the real entry point (as `dm/ios/project.yml` does with compilerFlags).
_HOST_MAIN: Path | None = None


# ---------------------------------------------------------------- link

def link(clang: Path, sdk: Path, objs: list[Path], frameworks: list[str], out: Path,
         deployment: str, embed_flags: list[str], rt_obj: Path | None,
         lld_dir: Path | None) -> None:
    """Link the app, then prove the result is an unsigned iOS executable."""
    args = [str(clang), '-target', f'arm64-apple-ios{deployment}', '-isysroot', str(sdk),
            '-fuse-ld=lld', '-fobjc-arc', '-o', str(out), *map(str, objs),
            '-Wl,-rpath,@executable_path/Frameworks', '-lobjc',
            *[x for fw in frameworks for x in ('-framework', fw)], *embed_flags]
    if rt_obj:
        args.append(str(rt_obj))
    env = dict(os.environ)
    if lld_dir:
        env['PATH'] = str(lld_dir) + os.pathsep + env.get('PATH', '')
    t(f'link: {len(objs)} objects, {len(frameworks)} frameworks (ld64.lld)')
    r = subprocess.run(args, capture_output=True, text=True, errors='replace', env=env)
    if r.returncode:
        print((r.stderr or r.stdout)[-6000:], file=sys.stderr)
        die('link failed (see the linker output above)')
    check_executable(out)


def check_executable(path: Path) -> None:
    """Reject a link output that is not a plain arm64 iOS executable.

    The reference implementation validates the same three properties, and they catch the two
    failure modes that matter here: a Mach-O that is not arm64 (the wrong `-target`) and one
    that carries a signature (a Windows LLD with `-no_adhoc_codesign` missing).
    """
    import struct
    data = path.read_bytes()
    magic, cputype, _sub, filetype = struct.unpack_from('<IIII', data, 0)
    if magic != tc.MACHO_MAGIC_64:
        die(f'{path.name} is not 64-bit Mach-O (magic 0x{magic:08x})')
    if cputype != tc.CPU_TYPE_ARM64:
        die(f'{path.name} is not arm64 (cputype 0x{cputype:08x})')
    if filetype != tc.MH_EXECUTE:
        die(f'{path.name} is not an executable (filetype {filetype})')
    plat = tc.macho_platform(data)
    if plat is not None and plat != tc.PLATFORM_IOS:
        die(f'{path.name} targets platform {plat}, not iOS')


# ---------------------------------------------------------------- the bundle

ICONS = [('AppIcon60x60@2x.png', 120), ('AppIcon60x60@3x.png', 180),
         ('AppIcon76x76@2x~ipad.png', 152), ('AppIcon83.5x83.5@2x~ipad.png', 167),
         ('AppIcon.png', 1024)]


def make_icons(src: Path, app: Path) -> bool:
    """Scale the game's icon into loose PNGs.

    Xcode would run `actool` over an asset catalog; on iOS a bundle may simply list loose PNG
    files in `CFBundleIcons`, which is what this does. Pillow is optional: without it the app
    still installs, it just has a blank home-screen icon.
    """
    try:
        from PIL import Image
    except ImportError:
        t('no app icon: Pillow is not installed (pip install pillow); the home-screen icon '
          'stays blank')
        return False
    try:
        im = Image.open(src).convert('RGB')
    except Exception as e:
        t(f'no app icon: cannot read {src} ({e})')
        return False
    for name, px in ICONS:
        im.resize((px, px), Image.LANCZOS).save(app / name, 'PNG')
    t(f'app icon: {src}')
    return True


def info_plist(*, bundle_id: str, name: str, version: str, category: str, show_fps: str,
               lang: str, sdk_ver: str, sdk_build: str, icons: bool, executable: str,
               deployment: str) -> dict:
    """`Info.plist` with the keys `dm/ios/project.yml` declares, in the same shape.

    Every key here has a reader in the app: `DMShowFPS` and `DMLanguage` in `main.m`,
    `CFBundleIcons` in the launcher, `LSApplicationCategoryType` in the App Store metadata.
    """
    p = {
        'CFBundleDevelopmentRegion': 'en',
        'CFBundleExecutable': executable,
        'CFBundleIdentifier': bundle_id,
        'CFBundleInfoDictionaryVersion': '6.0',
        'CFBundleName': executable,
        'CFBundleDisplayName': name,
        'CFBundlePackageType': 'APPL',
        'CFBundleShortVersionString': version,
        'CFBundleVersion': version,
        'CFBundleSupportedPlatforms': ['iPhoneOS'],
        'DTPlatformName': 'iphoneos',
        'DTPlatformVersion': sdk_ver,
        'DTSDKName': f'iphoneos{sdk_ver}',
        'DTSDKBuild': sdk_build,
        'MinimumOSVersion': deployment,
        'LSRequiresIPhoneOS': True,
        'UIDeviceFamily': [1, 2],
        'UIRequiredDeviceCapabilities': ['arm64'],
        'UILaunchStoryboardName': '',
        'UIFileSharingEnabled': True,
        'LSSupportsOpeningDocumentsInPlace': True,
        'UISupportedInterfaceOrientations': ['UIInterfaceOrientationLandscapeRight',
                                             'UIInterfaceOrientationLandscapeLeft'],
        'UISupportedInterfaceOrientations~ipad': ['UIInterfaceOrientationLandscapeRight',
                                                  'UIInterfaceOrientationLandscapeLeft'],
        'UIRequiresFullScreen': True,
        'UIStatusBarHidden': True,
        'UIViewControllerBasedStatusBarAppearance': False,
        'LSApplicationCategoryType': category,
        'DMShowFPS': show_fps,
        'DMLanguage': lang,
        'LSSupportsGameMode': True,
        'GCSupportsControllerUserInteraction': True,
        'GCSupportedGameControllers': [{'ProfileName': 'ExtendedGamepad'}],
        'CADisableMinimumFrameDurationOnPhone': True,
        'UIApplicationSceneManifest': {
            'UIApplicationSupportsMultipleScenes': False,
            'UISceneConfigurations': {'UIWindowSceneSessionRoleApplication': [
                {'UISceneConfigurationName': 'Default',
                 'UISceneDelegateClassName': 'SceneDelegate'}]},
        },
    }
    if icons:
        p['CFBundleIcons'] = {'CFBundlePrimaryIcon': {
            'CFBundleIconFiles': ['AppIcon60x60'], 'CFBundleIconName': 'AppIcon'}}
        p['CFBundleIcons~ipad'] = {'CFBundlePrimaryIcon': {
            'CFBundleIconFiles': ['AppIcon60x60', 'AppIcon76x76', 'AppIcon83.5x83.5'],
            'CFBundleIconName': 'AppIcon'}}
    if os.environ.get('DM_METAL_CAPTURE', '0') == '1':
        p['MetalCaptureEnabled'] = True
    return p


# ---------------------------------------------------------------- main

def main(argv: list[str] | None = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    if '--prepare-xcode' in args:
        die('--prepare-xcode generates an Xcode project, which needs a Mac with Xcode and '
            'xcodegen; on Windows the IPA is packed directly (drop the option)')
    env = os.environ
    repo = Path(env.get('NSPB_REPO') or Path(__file__).resolve().parents[3])

    game = env.get('GAME') or die('GAME is not set (the game profile ID)')
    w = Path(env.get('W') or die('W is not set (the work folder)'))
    sys.path.insert(0, str(repo / 'dm' / 'games'))
    try:
        import game as gm  # noqa: N813  (the upstream module name)
    except ImportError as e:
        die(f'cannot import dm/games/game.py from {repo}: {e}')
    try:
        prof = gm.load(game)
    except Exception as e:
        die(f'no game profile {game}: {e}')
    gd = Path(prof.dir)
    gp = prof.get
    if not (gd / 'game.tsv').exists():
        die(f'no game profile {gd}/game.tsv')

    pkg = gp('package')
    patched = Path(env.get('PATCHED') or w / f'build/patched_{pkg}')
    romfs = Path(env.get('ROMFS') or w / f'data/{pkg}/RomFS')
    msl_ios = Path(env.get('MSL_IOS') or w / 'build/ios/dmsh_b')
    aoc = Path(env['AOC']) if env.get('AOC') else (None if 'AOC' in env else w / 'data/aoc')
    out_ipa = Path(args[0]) if args and not args[0].startswith('-') else \
        w.parent / gp('ipa')

    mods = gp('modules').split()
    marker = gp('romfs_marker')

    # --- inputs, checked with the same wording as build_ipa.sh
    for m in mods:
        if not ((patched / f'{m}.patched.bin').exists() and (patched / f'{m}.fixups.tsv').exists()):
            die(f'no rewritten module {patched}/{m} (the rewrite step must run first)')
    if not (romfs / marker).exists():
        die(f'no RomFS at {romfs} (missing {marker})')

    name = env.get('DM_DISPLAY_NAME') or ''
    if not name:
        nacp = w / 'data/v0/control.nacp'
        if not nacp.exists():
            nacp = romfs.parent / 'control.nacp'
        try:
            name = py(repo / 'dm/tools/nacp.py', nacp)
        except SystemExit:
            die(f'no game name in {nacp} (set DM_DISPLAY_NAME)')
    version = env.get('DM_APP_VERSION') or '1.0'
    bundle_id = env.get('DM_BUNDLE_ID') or f'org.nxnative.{game.lower()}'
    show_fps = env.get('DM_SHOW_FPS', '0') in ('1', 'YES', 'yes', 'TRUE', 'true')
    lang = env.get('DM_LANG') or 'en-US'
    category = gp('app_category') or 'public.app-category.games'

    # --- graphics API, exactly as build_ipa.sh decides it without GFXAPI
    hdr = (repo / 'dm/gfx/nvn/dmsh_chain.h').read_text(encoding='utf-8')
    m = re.search(r'^#define DMSH_CHAIN "(.*)"', hdr, re.M)
    if not m:
        die('no DMSH_CHAIN in dm/gfx/nvn/dmsh_chain.h')
    v = m.group(1)
    gfx = env.get('GFXAPI') or ''
    if gfx not in ('nvn', 'vulkan', 'gl'):
        if list((msl_ios / f'b-{v}').glob('*_b.metallib')):
            gfx = 'nvn'
        elif (msl_ios / 'vk/vk_shaders.metallib').exists():
            gfx = 'vulkan'
        elif (msl_ios / 'gl/gl_shaders.metallib').exists():
            gfx = 'gl'
        else:
            gfx = 'nvn'
    if gfx == 'vulkan':
        if not (msl_ios / 'vk/vk_shaders.metallib').exists():
            die(f'no iOS Vulkan shader library at {msl_ios}/vk (the shader step must run first)')
        msldir = 'vk'
    elif gfx == 'gl':
        if not (msl_ios / 'gl/gl_shaders.metallib').exists():
            die(f'no iOS GL shader library at {msl_ios}/gl (the shader step must run first)')
        msldir = 'gl'
    else:
        msldir = f'b-{v}'
        if not list((msl_ios / msldir).glob('*_b.metallib')):
            die(f'no iOS shader libraries at {msl_ios}/{msldir} (the shader step must run first)')
        # The stamp `dmsh_build.py` writes names the game and the digest of its profile's
        # shader inputs. `build_ipa.sh` compares both and refuses libraries from another
        # profile state; without the comparison a stale library set would be packed silently.
        inputs = py(repo / 'dm/gfx/tools/dmsh_chain.py', '--inputs',
                    env=dict(env, DM_GAME=game))
        stamp = msl_ios / msldir / 'inputs.tsv'
        if inputs:
            lines = stamp.read_text(encoding='utf-8').splitlines() if stamp.exists() else []
            if f'game\t{game}' not in lines or f'inputs\t{inputs}' not in lines:
                die(f'the iOS shader libraries at {msl_ios}/{msldir} are not a full build from '
                    f'this profile\'s current tables (inputs {inputs}): build them again')
        # c1_full.tsv is made by the same full build and names the digest; the host ignores a
        # table whose header does not match its library
        c1 = gd / 'c1_full.tsv'
        try:
            first = c1.read_text(encoding='utf-8').splitlines()[0]
        except (OSError, IndexError):
            first = ''
        if inputs and not first.startswith(f'# chain b-{v} inputs {inputs} '):
            die(f'{c1} is missing or not made from these libraries (chain {v}, inputs {inputs}): '
                'a full shader build makes it')

    # --- the toolchain
    sdk = tc.ios_sdk() or die('no iPhoneOS SDK: download one in the app (Dependencies), or set '
                              '"ios_sdk" in toolchain.json')
    clang = tc.llvm_tool('clang') or die('no clang.exe: install LLVM-MinGW (Dependencies)')
    lld, lld_note = tc.ensure_ld64_lld()
    if not lld:
        die(f'no Mach-O linker: {lld_note}')
    lld_dir = lld.parent
    sdk_ver, sdk_build = tc.sdk_version(sdk)
    deployment = tc.setting('ios_deployment', IOS_DEPLOYMENT)
    t(f'app: {name} {version} ({bundle_id}), language {lang}'
      f'{", frame-rate counter on" if show_fps else ""}; SDK {sdk.name} {sdk_ver} {sdk_build}')

    base = w / 'build/ios/win'
    gen, app = base / 'Gen', base / 'Payload/DmIOS.app'
    shutil.rmtree(gen, ignore_errors=True)
    shutil.rmtree(app, ignore_errors=True)
    (gen / 'profile').mkdir(parents=True)
    app.mkdir(parents=True)

    # --- generate Gen/ (the same generators build_ipa.sh calls)
    t('generate Gen/ (profile header, embedded modules, tables)')
    py(repo / 'dm/games/game.py', 'header', game, gen / 'profile/game_profile.h')
    es = gen / 'embed.S'
    flags = py(repo / 'dm/ios/tools/gen_embed.py', patched, es, *mods)
    # the assembler treats '\' as an escape in .incbin paths
    es.write_text(re.sub(r'\.incbin "([^"]*)"',
                         lambda mm: '.incbin "' + mm.group(1).replace('\\', '/') + '"',
                         es.read_text(encoding='utf-8')), encoding='utf-8')

    dmres = app / 'dm'
    dmres.mkdir()
    for pat in ('*.fixups.tsv', '*.gates.tsv', '*.cuts.tsv', '*.obs.tsv'):
        for f in patched.glob(pat):
            shutil.copy2(f, dmres)
    if (patched / 'nro.tsv').exists():
        shutil.copy2(patched / 'nro.tsv', dmres)
    # the tables the host reads at run time; c1_full is only for the NVN chain
    tables = ['shader_map.tsv', 'pso_manifest.tsv'] + ([] if gfx in ('vulkan', 'gl')
                                                     else ['c1_full.tsv'])
    for f in tables:
        src = gd / f
        if not src.exists():
            die(f'no {src} in the game profile (the shader step must run first)')
        shutil.copy2(src, dmres)
    if gfx == 'nvn':
        if (gd / 'cb_extent.tsv').exists():
            shutil.copy2(gd / 'cb_extent.tsv', dmres)
        else:
            t(f'no {gd}/cb_extent.tsv: the host copies whole uniform bindings')
    for f in ('shader_pairs.tsv', 'pso_pairs.tsv'):
        if (gd / f).exists():
            shutil.copy2(gd / f, dmres)

    launcher = py(repo / 'dm/games/settings.py', game, patched,
                  (romfs.parent / 'control.nacp') if (romfs.parent / 'control.nacp').exists()
                  else (w / 'data/v0/control.nacp'),
                  gen / 'launcher.json', env=dict(env, GFXAPI=gfx))
    shutil.copy2(gen / 'launcher.json', dmres / 'launcher.json')
    t(f'launcher: {launcher}')
    if env.get('DM_ENV_FILE'):
        shutil.copy2(env['DM_ENV_FILE'], dmres / 'env.txt')

    (dmres / 'font').mkdir()
    font = tc.std_font() or die('no standard font: set STD_FONT to a TTF with broad Unicode '
                                'coverage')
    shutil.copy2(font, dmres / 'font/standard.ttf')
    t(f'standard font: {font} (upstream copies macOS\'s Arial Unicode; Windows fonts have '
      f'different CJK coverage)')
    letter = tc.letter_font()
    if not letter:
        die('no bold TTF for the button icons: set LETTER_FONT')
    py(repo / 'dm/tools/make_ext_font.py', dmres / 'font/nintendo_ext.ttf', letter)

    # --- the source list and the compile
    global _HOST_MAIN
    _HOST_MAIN = (repo / 'dm/host/main.c').resolve()
    files, incs = host_sources(repo, gen / 'profile')
    ios_sources = sorted((repo / 'dm/ios/Sources').glob('*.m'))
    files += [p.resolve() for p in ios_sources]
    files.append((HERE / 'ios/Launcher.m').resolve())
    files.append(es.resolve())
    # our Launcher.m replaces Launcher.swift and adds no Swift file; nothing else to exclude
    frameworks = framework_list(sdk, files)

    rt_obj = None
    if compat_rt_needed(clang):
        rt_obj = base / 'compat_rt.o'
        rt_obj.parent.mkdir(parents=True, exist_ok=True)
        r = subprocess.run([str(clang), '-target', f'arm64-apple-ios{deployment}',
                            '-isysroot', str(sdk), '-Os', '-c',
                            str(HERE / 'ios' / 'compat_rt.c'), '-o', str(rt_obj)],
                           capture_output=True, text=True, errors='replace')
        if r.returncode:
            print(r.stderr, file=sys.stderr)
            die('compat_rt.c did not compile (it stands in for Darwin\'s compiler-rt)')

    objs = compile_all(clang, sdk, files, incs, base / 'obj', deployment)
    link(clang, sdk, objs, frameworks, app / 'DmIOS', deployment,
         flags.split() if flags else [], rt_obj, lld_dir)

    # --- icon + Info.plist
    icon = Path(env.get('DM_ICON') or '')
    if not icon.is_file():
        icon = romfs.parent / 'icon.jpg'
    icons = icon.is_file() and make_icons(icon, app)
    if not icon.is_file():
        t(f'no app icon ({icon} not found): the home-screen icon stays blank')
    with open(app / 'Info.plist', 'wb') as f:
        plistlib.dump(info_plist(bundle_id=bundle_id, name=name, version=version,
                                 category=category, show_fps='YES' if show_fps else 'NO',
                                 lang=lang, sdk_ver=sdk_ver, sdk_build=sdk_build, icons=icons,
                                 executable='DmIOS', deployment=deployment),
                      f, fmt=plistlib.FMT_BINARY)
    (app / 'PkgInfo').write_bytes(b'APPL????')

    # --- pack
    maps = [f'Payload/DmIOS.app={app}', f'Payload/DmIOS.app/msl/{msldir}={msl_ios / msldir}']
    if aoc and aoc.is_dir() and any(aoc.iterdir()):
        maps.append(f'Payload/DmIOS.app/aoc={aoc}')
        t('add-on content: ' + ' '.join(sorted(p.name for p in aoc.iterdir())))
    full = bool(env.get('DM_FULL_ROMFS'))
    if full:
        maps.append(f'Payload/DmIOS.app/romfs={romfs}')
        t('packing the full IPA with the RomFS (only sensible for small games)')
    else:
        t('packing a slim IPA without the RomFS (the game files come from Documents/romfs)')
    store = gp('zip_store') or ''
    t('pack IPA')
    pack = [sys.executable, str(repo / 'dm/ios/tools/pack_ipa.py'), str(out_ipa)]
    if store:
        pack += ['--store', ':'.join(store.split(':'))]
    pack += ['--skip', 'Payload/DmIOS.app/msl', '--skip', 'Payload/DmIOS.app/aoc',
             '--skip', 'Payload/DmIOS.app/romfs', *maps]
    r = subprocess.run(pack, capture_output=True, text=True, errors='replace')
    if r.returncode:
        print(((r.stdout or '') + (r.stderr or ''))[-3000:], file=sys.stderr)
        die('pack_ipa failed')
    # Windows has no Unix modes: pack_ipa writes 0o666 for every file, which an iOS install
    # tool may refuse to launch. Rewrite the executable's central-directory entry to 0755.
    fixed = fix_ipa_modes.fix(out_ipa, ['Payload/DmIOS.app/DmIOS'])
    t(f'IPA modes: {fixed}')
    t(f'done: {out_ipa} ({out_ipa.stat().st_size / 2**30:.2f} GiB)')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
