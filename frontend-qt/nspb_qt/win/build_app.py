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
    from . import macho_sign
    from . import IOS_CPU, IOS_DEPLOYMENT
else:                                       # pragma: no cover - script mode
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
    from nspb_qt.win import toolchain as tc
    from nspb_qt.win import fix_ipa_modes
    from nspb_qt.win import macho_sign
    from nspb_qt.win import IOS_CPU, IOS_DEPLOYMENT

HERE = Path(__file__).resolve().parent


def _engine_root() -> str:
    """The engine's folder when NSPB_REPO is unset: the checkout's or bundled engine/."""
    from nspb_qt import engine
    for depth in (3, 4):
        if len(HERE.parents) > depth:
            cand = engine.engine_root(str(HERE.parents[depth]))
            if (Path(cand) / 'scripts' / 'build_ipa_from_nsp.py').is_file():
                return cand
    return engine.engine_root(str(HERE.parents[2]))

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


#: Paths the pack step drops from the base app (a full IPA maps its RomFS back in as `romfs` or `romfs.img`).
PACK_SKIPS = ('Payload/DmIOS.app/msl', 'Payload/DmIOS.app/aoc',
              'Payload/DmIOS.app/romfs', 'Payload/DmIOS.app/romfs.img',
              'Payload/DmIOS.app/romfs.id', 'Payload/DmIOS.app/html',
              'Payload/DmIOS.app/jit')


def _shader_lib_module(repo: Path):
    """Load `dm/tools/shader_lib.py` when present (engine >= 1.2 packs `b-<chain>/` into `b-<chain>.img`)."""
    tools = Path(repo) / 'dm' / 'tools'
    if not (tools / 'shader_lib.py').is_file():
        return None
    if str(tools) not in sys.path:
        sys.path.insert(0, str(tools))
    import shader_lib
    return shader_lib


def shader_lib_has(repo: Path, lib: Path) -> bool:
    """Whether `lib` (`b-<chain>` folder or `b-<chain>.img` image) holds compiled `*_b.metallib` files."""
    slib = _shader_lib_module(repo)
    if slib is not None:
        return bool(slib.has_library(lib))
    return bool(list(Path(lib).glob('*_b.metallib')))


def shader_lib_stamp_lines(repo: Path, lib: Path) -> list[str]:
    """Lines of `inputs.tsv` from `b-<chain>` (folder or `.img`), or `[]` when absent."""
    slib = _shader_lib_module(repo)
    if slib is not None:
        try:
            return (slib.view(lib) / 'inputs.tsv').read_text(encoding='utf-8').splitlines()
        except OSError:
            return []
    stamp = Path(lib) / 'inputs.tsv'
    return stamp.read_text(encoding='utf-8').splitlines() if stamp.exists() else []


def romfs_has(repo, romfs, marker: str) -> bool:
    """Whether the RomFS (a folder or an image file) holds `marker`, read through the engine's `romfs.Path`."""
    tools = str(Path(repo) / 'dm' / 'tools')
    if tools not in sys.path:
        sys.path.insert(0, tools)
    from romfs import Path as RomFSPath
    return (RomFSPath(romfs) / marker).exists()


def romfs_resource(romfs) -> str:
    """The name a full IPA gives the RomFS: an image file is `romfs.img`, a folder is `romfs`."""
    return 'romfs.img' if Path(romfs).is_file() else 'romfs'


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
            'haptics_apple.m $(sort $(wildcard hle_*.c)) front_mac.m controllers_mac.m web_apple.m entry.S')
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
    src += [host / 'front_mac.m', host / 'controllers_mac.m', host / 'web_apple.m', host / 'entry.S']
    gfx: list[Path] = []
    for pat in _GFX_PATS:
        d, g = pat.rsplit('/', 1)
        gfx += list((host / d).glob(g))
    # make's $(sort) orders words as text, which for these relative paths is plain string order
    gfx.sort(key=lambda p: os.path.relpath(p, host).replace('\\', '/'))

    vpx = repo / 'dm' / 'third_party' / 'libvpx'
    vpx_src = sorted(vpx.rglob('*.c'), key=lambda p: p.as_posix())

    dav1d = repo / 'dm' / 'third_party' / 'dav1d'
    dav1d_src: list[Path] = []
    if dav1d.is_dir():
        dav1d_src = sorted(
            [p for p in (dav1d / 'src').glob('*.c') if not p.name.endswith('_tmpl.c')]
            + ([dav1d / 'src' / 'arm' / 'cpu.c'] if (dav1d / 'src' / 'arm' / 'cpu.c').is_file() else [])
            + list((dav1d / 'config' / 'tmpl').glob('*.c'))
            + [p for p in (dav1d / 'src' / 'arm' / '64').glob('*.S')
               if not p.name.endswith('_tmpl.S') and p.name != 'util.S'],
            key=lambda p: p.as_posix(),
        )

    incs = [repo / 'dm' / 'gfx' / 'nvn' / 'include',
            repo / 'dm' / 'third_party' / 'vulkan-headers' / 'include',
            game_h_dir, vpx, repo / 'dm' / 'third_party' / 'stb_vorbis', vpx / 'config']
    if dav1d.is_dir():
        incs += [dav1d / 'include', dav1d, dav1d / 'config']

    ios_sources = (repo / 'dm' / 'ios' / 'Sources').resolve()
    files: list[Path] = []
    for s in src + gfx + vpx_src + dav1d_src:
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


SDK_COMPAT = HERE / 'ios' / 'sdk_compat'


def common_flags(sdk: Path, incs: list[Path], deployment: str) -> list[str]:
    compat = [f'-I{SDK_COMPAT}'] if SDK_COMPAT.is_dir() else []
    return ['-target', f'arm64-apple-ios{deployment}', '-isysroot', str(sdk),
            '-Os', f'-mcpu={IOS_CPU}', '-w', '-fno-common', '-DNS_BLOCK_ASSERTIONS=1',
            *compat, *[f'-I{i}' for i in incs]]


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
         lld_dir: Path, bundle_id: str = 'org.nxnative.app') -> None:
    """Link the app, then prove the result is an arm64 iOS executable and sign its entitlements."""
    entitle = os.environ.get('NSPB_ENTITLEMENTS', '1') != '0'
    args = [str(clang), '-target', f'arm64-apple-ios{deployment}', '-isysroot', str(sdk),
            '-fuse-ld=lld', '-fobjc-arc', '-o', str(out), *map(str, objs),
            '-Wl,-rpath,@executable_path/Frameworks', '-lobjc', '-lSystem',
            *(('-Wl,-adhoc_codesign',) if entitle else ()),
            *[x for fw in frameworks for x in ('-framework', fw)], *embed_flags]
    if rt_obj:
        args.append(str(rt_obj))
    env = dict(os.environ)
    env['PATH'] = str(lld_dir) + os.pathsep + env.get('PATH', '')
    t(f'link: {len(objs)} objects, {len(frameworks)} frameworks (ld64.lld)')
    r = subprocess.run(args, capture_output=True, text=True, errors='replace', env=env)
    if r.returncode:
        print((r.stderr or r.stdout)[-6000:], file=sys.stderr)
        die('link failed (see the linker output above)')
    check_executable(out)
    if entitle:
        ents = {'com.apple.developer.kernel.increased-memory-limit': True}
        sig_n = macho_sign.sign(out, bundle_id, ents)
        t(f'sign: ad-hoc with Increased Memory Limit entitlement ({sig_n} B)')


# What the shell dlsym()s out of a game framework, by the names the engine itself defines:
# `dmgame_image_marker` is DmGameMarker.m (FrameworkBootstrap.h finds it through
# DM_FRAMEWORK_MARKER), `dm_glue_version` / `dm_glue_start_game` / `dm_glue_present_game` /
# `dm_glue_focus_event` are ShellGlue.m (ShellMain.m checks all four), `dm_game_menu` is
# Launcher.m, and `dm_main` / `dm_show_launcher` are the host entry point and the framework's own
# launcher stub.
REQUIRED_DYLIB_SYMBOLS = (
    '_dmgame_image_marker',
    '_dm_main',
    '_dm_show_launcher',
    '_dm_game_menu',
    '_dm_glue_version',
    '_dm_glue_start_game',
    '_dm_glue_present_game',
    '_dm_glue_focus_event',
)


def link_framework(clang: Path, sdk: Path, objs: list[Path], frameworks: list[str], out: Path,
                   fw_name: str, deployment: str, embed_flags: list[str], rt_obj: Path | None,
                   lld_dir: Path, bundle_id: str = 'org.nxnative.app.DmGame') -> None:
    """Link the game's `DmGame<title ID>.framework` dylib and sign it ad-hoc without entitlements."""
    args = [str(clang), '-target', f'arm64-apple-ios{deployment}', '-isysroot', str(sdk),
            '-fuse-ld=lld', '-dynamiclib',
            f'-Wl,-install_name,@rpath/{fw_name}.framework/{fw_name}',
            '-Wl,-rpath,@executable_path/Frameworks',
            '-fobjc-arc', '-o', str(out), *map(str, objs),
            '-lobjc', '-lSystem', '-Wl,-adhoc_codesign',
            *[x for fw in frameworks for x in ('-framework', fw)], *embed_flags]
    if rt_obj:
        args.append(str(rt_obj))
    env = dict(os.environ)
    env['PATH'] = str(lld_dir) + os.pathsep + env.get('PATH', '')
    t(f'link framework: {len(objs)} objects, {len(frameworks)} frameworks (ld64.lld)')
    r = subprocess.run(args, capture_output=True, text=True, errors='replace', env=env)
    if r.returncode:
        print((r.stderr or r.stdout)[-6000:], file=sys.stderr)
        die('framework link failed (see the linker output above)')
    check_dylib(out)
    sig_n = macho_sign.sign(out, bundle_id, None)
    t(f'sign framework: ad-hoc, no entitlements ({sig_n} B)')


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


def check_dylib(path: Path) -> None:
    """Reject a framework link output that is not a 64-bit arm64 iOS dylib with the required exports."""
    import struct
    data = path.read_bytes()
    if len(data) < 32:
        die(f'{path.name} is truncated ({len(data)} B)')
    magic, cputype, _sub, filetype, ncmds, sizeofcmds, _flags, _res = struct.unpack_from('<IIIIIIII', data, 0)
    if magic != tc.MACHO_MAGIC_64:
        die(f'{path.name} is not 64-bit Mach-O (magic 0x{magic:08x})')
    if cputype != tc.CPU_TYPE_ARM64:
        die(f'{path.name} is not arm64 (cputype 0x{cputype:08x})')
    if filetype != tc.MH_DYLIB:
        die(f'{path.name} is not a dynamic library (filetype {filetype})')
    plat = tc.macho_platform(data)
    if plat is not None and plat != tc.PLATFORM_IOS:
        die(f'{path.name} targets platform {plat}, not iOS')

    end_cmds = min(len(data), 32 + sizeofcmds)
    off = 32
    exported: set[str] = set()
    undef: set[str] = set()
    saw_symtab = False
    for _ in range(ncmds):
        if off + 8 > end_cmds:
            break
        cmd, cmdsize = struct.unpack_from('<II', data, off)
        if cmdsize < 8 or off + cmdsize > end_cmds:
            break
        if cmd == 0x2 and cmdsize >= 24:  # LC_SYMTAB
            _, _, symoff, nsyms, stroff, strsize = struct.unpack_from('<IIIIII', data, off)
            if symoff > len(data) or nsyms > (len(data) - symoff) // 16:
                die(f'{path.name} has an out-of-bounds LC_SYMTAB symbol table')
            if stroff > len(data) or strsize > len(data) - stroff:
                die(f'{path.name} has an out-of-bounds LC_SYMTAB string table')
            saw_symtab = True
            str_end = stroff + strsize
            for i in range(nsyms):
                n_strx, n_type, _sect, _desc, _val = struct.unpack_from('<IBBHQ', data, symoff + i * 16)
                if n_type & 0xe0:  # N_STAB debug entry
                    continue
                if n_strx >= strsize:
                    continue
                pos = stroff + n_strx
                nul = data.find(b'\x00', pos, str_end)
                name = data[pos:(nul if nul != -1 else str_end)].decode('utf-8', 'replace')
                if (n_type & 0x0e) == 0:  # N_UNDF
                    undef.add(name)
                elif (n_type & 0x01) and not (n_type & 0x10):  # N_EXT and not N_PEXT
                    exported.add(name)
        off += cmdsize

    if not saw_symtab:
        die(f'{path.name} has no LC_SYMTAB symbol table')
    if '___mh_execute_header' in undef or '__mh_execute_header' in undef:
        die(f'{path.name} references undefined __mh_execute_header')
    missing = [s for s in REQUIRED_DYLIB_SYMBOLS if s not in exported]
    if missing:
        die(f'{path.name} is missing required exported symbol(s): {", ".join(missing)}')


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


def make_framework_icon(src: Path, dst: Path) -> bool:
    """Scale the game's icon to a 512x512 PNG at `<framework>/icon.png` (as `build_ipa.sh` does)."""
    try:
        from PIL import Image
        im = Image.open(src).convert('RGB')
        im.resize((512, 512), Image.LANCZOS).save(dst, 'PNG')
        return True
    except Exception as e:
        t(f'no framework icon: cannot convert {src} ({e})')
        return False


def framework_info_plist(*, bundle_id: str, fw_name: str, display_name: str, version: str,
                         sdk_ver: str, sdk_build: str, deployment: str) -> dict:
    """`Info.plist` for `DmGame<title ID>.framework` (`project-framework.yml` `DmShellGame`)."""
    return {
        'CFBundleDevelopmentRegion': 'en',
        'CFBundleExecutable': fw_name,
        'CFBundleIdentifier': bundle_id,
        'CFBundleInfoDictionaryVersion': '6.0',
        'CFBundleName': fw_name,
        'CFBundleDisplayName': display_name,
        'CFBundlePackageType': 'FMWK',
        'CFBundleShortVersionString': version,
        'CFBundleVersion': version,
        'CFBundleSupportedPlatforms': ['iPhoneOS'],
        'DTPlatformName': 'iphoneos',
        'DTPlatformVersion': sdk_ver,
        'DTSDKName': f'iphoneos{sdk_ver}',
        'DTSDKBuild': sdk_build,
        'MinimumOSVersion': deployment,
        'UIDeviceFamily': [1, 2],
    }


def shader_lib_real_path(repo: Path, lib: Path) -> Path:
    """Path to the shader library folder or `.img` file, via `dm/tools/shader_lib.py` when present."""
    slib = _shader_lib_module(repo)
    if slib is not None and hasattr(slib, 'view'):
        return Path(slib.view(lib))
    img = lib.parent / f'{lib.name}.img'
    return img if img.is_file() and not (lib / 'inputs.tsv').is_file() else lib


def build_pso_archive(repo: Path, w: Path, game: str, gd: Path, gp, gfx: str,
                      msl_ios: Path, v: str, env) -> Path | None:
    """Run `dm/gfx/tools/pso_offline.py` when the game profile or `DM_PSO_GPUS` requests an archive."""
    if gfx != 'nvn' or not (gd / 'shader_pairs.tsv').is_file():
        return None
    try:
        p4 = gp('pso_mtl4', 'off') or 'off'
    except (KeyError, SystemExit, TypeError):
        p4 = 'off'
    try:
        pg = gp('pso_gpu', '') or ''
    except (KeyError, SystemExit, TypeError):
        pg = ''
    pg_words = pg.split()
    pgk = 'g18p'
    if p4 == 'on' and 1 <= len(pg_words) <= 4 and all(
        w_ != 'none' and re.sub(r'^applegpu_', '', w_).isalnum() for w_ in pg_words
    ):
        pgk = ','.join(pg_words)
    if 'DM_PSO_GPUS' in env:
        gpus = env.get('DM_PSO_GPUS') or ''
    elif p4 == 'on':
        gpus = pgk
    else:
        gpus = 'none'
    if not gpus or gpus == 'none':
        return None
    pso = w / 'build/ios/pso/bundle'
    t(f'pipeline archive for {gpus} (metal-tt; minutes when its inputs changed)')
    cmd = [
        sys.executable, str(repo / 'dm/gfx/tools/pso_offline.py'),
        '--game', game,
        '--msl', str(msl_ios / f'b-{v}'),
        '--out', str(pso),
        '--work', str(w / 'build/ios/pso/work'),
        '--gpu', gpus,
    ]
    if env.get('DM_PSO_IOS_MIN'):
        cmd += ['--os-min', env['DM_PSO_IOS_MIN']]
    r = subprocess.run(cmd, env=dict(env), capture_output=True, text=True, errors='replace')
    for ln in (r.stdout + '\n' + r.stderr).splitlines():
        if ln.strip():
            t(ln)
    if r.returncode != 0 or not pso.is_dir():
        t('[RED] pipeline archive: pso_offline.py failed; building without one')
        shutil.rmtree(pso, ignore_errors=True)
        return None
    return pso


# ---------------------------------------------------------------- main

def main(argv: list[str] | None = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    if '--prepare-xcode' in args:
        die('--prepare-xcode generates an Xcode project, which needs a Mac with Xcode and '
            'xcodegen; on Windows the IPA is packed directly (drop the option)')
    env = os.environ
    repo = Path(env.get('NSPB_REPO') or _engine_root())

    game = env.get('GAME') or die('GAME is not set (the game profile ID)')
    w = Path(env.get('W') or die('W is not set (the work folder)'))
    sys.path.insert(0, str(repo / 'dm' / 'games'))
    try:
        import game as gm  # noqa: N813  (the upstream module name)
    except ImportError as e:
        die(f'cannot import dm/games/game.py from {repo}: {e}')
    if not getattr(gm, '_nspb_patched', False):
        def _split_games_dir(raw: str) -> list[str]:
            out: list[str] = []
            for semi in str(raw or '').split(';'):
                parts = semi.split(':')
                i = 0
                while i < len(parts):
                    cur = parts[i]
                    if len(cur) == 1 and cur.isalpha() and i + 1 < len(parts) and parts[i + 1][:1] in ('\\', '/'):
                        out.append(cur + ':' + parts[i + 1])
                        i += 2
                    else:
                        if cur:
                            out.append(cur)
                        i += 1
            return out

        gm.extra_dirs = lambda: [Path(p) for p in _split_games_dir(os.environ.get('DM_GAMES_DIR', ''))]
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
    default_romfs = (w / f'data/{pkg}/RomFS.img'
                     if (w / f'data/{pkg}/RomFS.img').is_file() else w / f'data/{pkg}/RomFS')
    romfs = Path(env.get('ROMFS') or default_romfs)
    msl_ios = Path(env.get('MSL_IOS') or w / 'build/ios/dmsh_b')
    aoc = Path(env['AOC']) if env.get('AOC') else (None if 'AOC' in env else w / 'data/aoc')
    out_ipa = Path(args[0]) if args and not args[0].startswith('-') else \
        w.parent / gp('ipa')

    mods = (prof.modules_in(patched)
            if hasattr(prof, 'modules_in') and prof.modules_in(patched)
            else gp('modules').split())
    marker = gp('romfs_marker')

    # --- inputs, checked with the same wording as build_ipa.sh
    for m in mods:
        if not ((patched / f'{m}.patched.bin').exists() and (patched / f'{m}.fixups.tsv').exists()):
            die(f'no rewritten module {patched}/{m} (the rewrite step must run first)')
    if not romfs_has(repo, romfs, marker):
        die(f'no RomFS at {romfs} (missing {marker})')

    nacp = Path(env['CONTROL']) if env.get('CONTROL') else (w / 'data/v0/control.nacp')
    if not nacp.exists():
        nacp = romfs.parent / 'control.nacp'
    name = env.get('DM_DISPLAY_NAME') or ''
    if not name:
        try:
            name = py(repo / 'dm/tools/nacp.py', nacp)
        except SystemExit:
            die(f'no game name in {nacp} (set DM_DISPLAY_NAME)')
    version = env.get('DM_APP_VERSION') or '1.0'
    bundle_id = env.get('DM_BUNDLE_ID') or f'org.nxnative.{game.lower()}'
    show_fps = env.get('DM_SHOW_FPS', '0') in ('1', 'YES', 'yes', 'TRUE', 'true')
    lang = env.get('DM_LANG') or 'en-US'
    try:
        category = gp('app_category', 'public.app-category.games') or 'public.app-category.games'
    except (KeyError, SystemExit, TypeError):
        category = 'public.app-category.games'

    # --- graphics API, exactly as build_ipa.sh decides it without GFXAPI
    hdr = (repo / 'dm/gfx/nvn/dmsh_chain.h').read_text(encoding='utf-8')
    m = re.search(r'^#define DMSH_CHAIN "(.*)"', hdr, re.M)
    if not m:
        die('no DMSH_CHAIN in dm/gfx/nvn/dmsh_chain.h')
    v = m.group(1)
    gfx = env.get('GFXAPI') or ''
    if gfx not in ('nvn', 'vulkan', 'gl'):
        if shader_lib_has(repo, msl_ios / f'b-{v}'):
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
        if not shader_lib_has(repo, msl_ios / msldir):
            die(f'no iOS shader libraries at {msl_ios}/{msldir} (the shader step must run first)')
        # The stamp `dmsh_build.py` writes names the game and the digest of its profile's
        # shader inputs. `build_ipa.sh` compares both and refuses libraries from another
        # profile state; without the comparison a stale library set would be packed silently.
        inputs = py(repo / 'dm/gfx/tools/dmsh_chain.py', '--inputs',
                    env=dict(env, DM_GAME=game))
        if inputs:
            lines = shader_lib_stamp_lines(repo, msl_ios / msldir)
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
    shutil.rmtree(app, ignore_errors=True)
    (gen / 'profile').mkdir(parents=True, exist_ok=True)
    app.mkdir(parents=True)

    def _replace_if_changed(tmp_p: Path, dst_p: Path) -> None:
        if dst_p.is_file():
            try:
                if dst_p.read_bytes() == tmp_p.read_bytes():
                    tmp_p.unlink(missing_ok=True)
                    return
            except OSError:
                pass
        os.replace(tmp_p, dst_p)

    # --- generate Gen/ (the same generators build_ipa.sh calls, preserving mtime when unchanged)
    t('generate Gen/ (profile header, embedded modules, tables)')
    gp_h = gen / 'profile/game_profile.h'
    gp_h_tmp = gen / 'profile/game_profile.h.tmp'
    py(repo / 'dm/games/game.py', 'header', gd, gp_h_tmp)
    _replace_if_changed(gp_h_tmp, gp_h)

    msl_srcs = sorted((repo / 'dm/gfx/msl').glob('*.metal'))
    if msl_srcs:
        msl_min = tc.setting('metal_ios_target', '18.0')
        msl_h = gen / 'profile/host_msl_gen.h'
        msl_key_file = gen / 'profile/host_msl.sha256'
        h_msl = hashlib.sha256(msl_min.encode())
        for ms in msl_srcs + [repo / 'dm/gfx/tools/host_msl.py']:
            try:
                h_msl.update(ms.name.encode() + b'\0' + ms.read_bytes())
            except OSError:
                pass
        msl_digest = h_msl.hexdigest()
        if not (msl_h.is_file() and msl_key_file.is_file()
                and msl_key_file.read_text(encoding='utf-8', errors='replace').strip() == msl_digest):
            msl_h_tmp = gen / 'profile/host_msl_gen.h.tmp'
            py(repo / 'dm/gfx/tools/host_msl.py', '--sdk', 'iphoneos',
               '--min', msl_min, msl_h_tmp, *msl_srcs)
            _replace_if_changed(msl_h_tmp, msl_h)
            msl_key_file.write_text(msl_digest + '\n', encoding='utf-8')

    es = gen / 'embed.S'
    es_tmp = gen / 'embed.S.tmp'
    jit_img = romfs.parent / 'jit' / 'jit.img'
    jit_args = ['--jit', jit_img] if jit_img.is_file() else []
    flags = py(repo / 'dm/ios/tools/gen_embed.py', *jit_args, patched, es_tmp, *mods)
    bin_meta = []
    for m_name in mods:
        bp = patched / f'{m_name}.patched.bin'
        if bp.is_file():
            st = bp.stat()
            bin_meta.append(f'{m_name}:{st.st_size}:{st.st_mtime_ns}')
    if jit_img.is_file():
        st = jit_img.stat()
        bin_meta.append(f'{jit_img.name}:{st.st_size}:{st.st_mtime_ns}')
    # the assembler treats '\' as an escape in .incbin paths
    es_body = re.sub(r'\.incbin "([^"]*)"',
                     lambda mm: '.incbin "' + mm.group(1).replace('\\', '/') + '"',
                     es_tmp.read_text(encoding='utf-8'))
    es_tmp.write_text(es_body + f'\n// inputs: {" ".join(bin_meta)}\n', encoding='utf-8')
    _replace_if_changed(es_tmp, es)

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

    launcher = py(repo / 'dm/games/settings.py', gd, patched, nacp,
                  gen / 'launcher.json', env=dict(env, GFXAPI=gfx))
    shutil.copy2(gen / 'launcher.json', dmres / 'launcher.json')
    if not env.get('DM_LANG'):
        try:
            import json
            lang = json.loads((gen / 'launcher.json').read_text(encoding='utf-8')).get('language') or lang
        except Exception:
            pass
    t(f'launcher: {launcher}')
    if env.get('DM_ENV_FILE'):
        shutil.copy2(env['DM_ENV_FILE'], dmres / 'env.txt')

    framework_only = env.get('DM_FRAMEWORK_ONLY') or ''
    pso = build_pso_archive(repo, w, game, gd, gp, gfx, msl_ios, v, env)

    if not framework_only:
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
    if framework_only:
        shell_ios_files = [
            repo / 'dm/ios/framework/DmGameMarker.m',
            repo / 'dm/ios/framework/ShellGlue.m',
            repo / 'dm/ios/Sources/front_ios.m',
            repo / 'dm/ios/Sources/DmGamepad.m',
            repo / 'dm/ios/Sources/CloudSaves.m',
            repo / 'dm/ios/Sources/SaveSync.m',
            repo / 'dm/ios/Sources/DataBookmark.m',
            HERE / 'ios/Launcher.m',
            es,
        ]
        for p in shell_ios_files:
            if not p.is_file():
                die(f'missing framework source: {p}')
            files.append(p.resolve())
        for extra_inc in (repo / 'dm/ios/Sources', repo / 'dm/ios/Shell', repo / 'dm/ios/framework'):
            ri = extra_inc.resolve()
            if ri not in incs:
                incs.append(ri)
    else:
        ios_sources = sorted((repo / 'dm/ios/Sources').glob('*.m'))
        files += [p.resolve() for p in ios_sources]
        files.append((HERE / 'ios/Launcher.m').resolve())
        files.append(es.resolve())
    # our Launcher.m replaces Launcher.swift / GameMenu.swift and adds no Swift file
    frameworks = framework_list(sdk, files)
    if framework_only:
        for req_fw in ('UIKit', 'UserNotifications'):
            if req_fw not in frameworks and (sdk / 'System/Library/Frameworks' / f'{req_fw}.framework').is_dir():
                frameworks.append(req_fw)

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

    obj_subdir = base / ('obj_fw' if framework_only else 'obj')
    extra_cflags = ['-DDM_SHELL_FRAMEWORK=1'] if framework_only else None
    objs = compile_all(clang, sdk, files, incs, obj_subdir, deployment, extra=extra_cflags)

    icon = Path(env.get('DM_ICON') or '')
    if not icon.is_file():
        icon = romfs.parent / 'icon.jpg'

    if framework_only:
        fw_name = f'DmGame{game.upper()}'
        out_fw = Path(framework_only) / f'{fw_name}.framework'
        out_fw.mkdir(parents=True, exist_ok=True)
        for child in list(out_fw.iterdir()):
            if child.name in ('msl', 'pso', 'icon.png') or child.name.startswith('banner.'):
                continue
            if child.is_dir():
                shutil.rmtree(child, ignore_errors=True)
            else:
                child.unlink(missing_ok=True)

        link_framework(clang, sdk, objs, frameworks, out_fw / fw_name, fw_name, deployment,
                       flags.split() if flags else [], rt_obj, lld_dir,
                       bundle_id=f'{bundle_id}.DmGame')
        shutil.copytree(dmres, out_fw / 'dm')
        py(repo / 'dm/games/game.py', 'profile', gd, out_fw / 'profile.tsv')

        romfs_id = ''
        if romfs.is_file() and not env.get('DM_FULL_ROMFS'):
            r_id = subprocess.run([sys.executable, str(repo / 'dm/tools/romfs_image.py'),
                                   '--identity', str(romfs), str(game), str(version),
                                   str(pkg or '')], capture_output=True, text=True, errors='replace')
            if r_id.returncode != 0 or not r_id.stdout.strip():
                die(f'identity of {romfs}: {r_id.stderr.strip() or r_id.stdout.strip()}')
            romfs_id = r_id.stdout.strip()

        manifest_args = [
            repo / 'dm/ios/tools/gen_manifest.py',
            out_fw / 'game.manifest.json',
            '--game', game,
            '--name', name,
            '--display-version', version,
            '--package-version', pkg or '',
            '--modules', ' '.join(mods),
            '--chain', f'b-{v}',
            '--romfs-marker', marker,
            '--romfs-identity', romfs_id,
            '--framework-name', fw_name,
            '--loader', 'FH',
        ]
        if (patched / 'nro.tsv').is_file():
            manifest_args += ['--nro-table', patched / 'nro.tsv']
        py(*manifest_args)

        with open(out_fw / 'Info.plist', 'wb') as f:
            plistlib.dump(framework_info_plist(bundle_id=f'{bundle_id}.DmGame', fw_name=fw_name,
                                               display_name=name, version=version,
                                               sdk_ver=sdk_ver, sdk_build=sdk_build,
                                               deployment=deployment),
                          f, fmt=plistlib.FMT_BINARY)

        lib_src = shader_lib_real_path(repo, msl_ios / msldir)
        msl_dst = out_fw / 'msl'
        msl_dst.mkdir(parents=True, exist_ok=True)
        if lib_src.is_file():
            shutil.rmtree(msl_dst / msldir, ignore_errors=True)
            target_img = msl_dst / f'{msldir}.img'
            if not (target_img.is_file()
                    and target_img.stat().st_size == lib_src.stat().st_size
                    and abs(target_img.stat().st_mtime - lib_src.stat().st_mtime) < 1):
                shutil.copy2(lib_src, target_img)
            keep_name = f'{msldir}.img'
        else:
            (msl_dst / f'{msldir}.img').unlink(missing_ok=True)
            target_dir = msl_dst / msldir
            shutil.rmtree(target_dir, ignore_errors=True)
            shutil.copytree(lib_src, target_dir)
            keep_name = msldir
        for old in list(msl_dst.iterdir()):
            if old.name != keep_name:
                if old.is_dir():
                    shutil.rmtree(old, ignore_errors=True)
                else:
                    old.unlink(missing_ok=True)

        if pso and pso.is_dir():
            shutil.rmtree(out_fw / 'pso', ignore_errors=True)
            shutil.copytree(pso, out_fw / 'pso')
        else:
            shutil.rmtree(out_fw / 'pso', ignore_errors=True)

        if icon.is_file():
            make_framework_icon(icon, out_fw / 'icon.png')
        else:
            (out_fw / 'icon.png').unlink(missing_ok=True)

        t(f'done: {out_fw} (build_shell.sh embeds it in the shell)')
        return 0

    link(clang, sdk, objs, frameworks, app / 'DmIOS', deployment,
         flags.split() if flags else [], rt_obj, lld_dir, bundle_id=bundle_id)

    # --- icon + Info.plist
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
    if (romfs.parent / 'html').is_dir():
        maps.append(f'Payload/DmIOS.app/html={romfs.parent / "html"}')
    if (romfs.parent / 'jit').is_dir():
        maps.append(f'Payload/DmIOS.app/jit={romfs.parent / "jit"}')
    full = bool(env.get('DM_FULL_ROMFS'))
    if aoc and aoc.is_dir() and any(aoc.iterdir()):
        if full:
            maps.append(f'Payload/DmIOS.app/aoc={aoc}')
            t('add-on content packed into the IPA: ' + ' '.join(sorted(p.name for p in aoc.iterdir())))
        else:
            t('add-on content alongside the game data (DM_FULL_ROMFS=1 packs it): '
              + ' '.join(sorted(p.name for p in aoc.iterdir())))
    if pso and pso.is_dir() and any(pso.iterdir()):
        maps.append(f'Payload/DmIOS.app/pso={pso}')
    if full:
        resource = romfs_resource(romfs)
        maps.append(f'Payload/DmIOS.app/{resource}={romfs}')
        t('packing the full IPA with the RomFS (only sensible for small games)')
    else:
        if romfs.is_file():
            rid_file = base / 'romfs.id'
            r_id = subprocess.run([sys.executable, str(repo / 'dm/tools/romfs_image.py'),
                                   '--identity', str(romfs), str(game), str(version),
                                   str(pkg or '')], capture_output=True)
            if r_id.returncode == 0 and r_id.stdout:
                rid_file.write_bytes(r_id.stdout)
                maps.append(f'Payload/DmIOS.app/romfs.id={rid_file}')
        t('packing a slim IPA without the RomFS (the game files come from Documents/romfs)')
    try:
        store = gp('zip_store', '') or ''
    except (KeyError, SystemExit, TypeError):
        store = ''
    t('pack IPA')
    pack = [sys.executable, str(repo / 'dm/ios/tools/pack_ipa.py'), str(out_ipa)]
    if store:
        pack += ['--store', ':'.join(store.split(':'))]
    for skip in PACK_SKIPS:
        pack += ['--skip', skip]
    prof_h = (gen / 'profile/game_profile.h').read_text(encoding='utf-8', errors='replace')
    if not pso and '#define DM_GAME_PSO_MTL4 1' not in prof_h:
        pack += ['--skip-suffix', '_bp.metallib']
    pack += maps
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
