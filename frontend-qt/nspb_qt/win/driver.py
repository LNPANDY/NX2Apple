"""Run the upstream NSP→IPA pipeline on Windows without editing it.

`scripts/build_ipa_from_nsp.py` is an upstream file that the daily sync overwrites, so patching
it in place is not an option, and a PATH-only shim cannot work: the script imports `pwd` (a
POSIX-only module) at load time, and its app-build step shells out to a 187-line bash script
that calls `xcodegen`, `xcodebuild`, `sips`, `plutil`, `codesign` and `xattr`.

So this module loads the upstream file **as a module** and replaces the handful of functions
that assume a Mac, then calls its own `cli()`. Everything else — argument parsing, the NSP
handling, `nx_extract`, `patch_nso`, the shader split, the tables, the progress display, the
error reporting — runs exactly as on a Mac, which is what keeps the two platforms from drifting.

What gets replaced, and why:

========================  ==========================================================
`check_prereqs`           Xcode/xcodegen/make are absent; the Windows toolchain is checked
                          instead, with the same "what is missing and how to get it" shape.
`build_nx_extract`        use the packaged extractor, or build the Windows executable from source
`can_clone`               no APFS: plain copies (`nx_extract` spends the disk, not the build)
`apple_silicon`           no `sysctl`
`heap_check`              boots the game in the Mac host; replaced by an estimate
`build_mac_host`          points decoder tool-mode steps (`DM_OODLE_SERVE` / `DM_OODLE_JOB`) at
                          `oodle_emu.py` (native x64 Oodle DLL passthrough or emulated ARM64)
`toolchain`               the shader cache key needs the Windows Metal compiler's version
`capture_shaders`         reuses existing `gl_capture` / `vk_capture` folders, reconstructs
                          LÖVE (`love_shaders.py`) and GameMaker (`gm_shaders.py`) OpenGL
                          shaders offline, and refuses other uncaptured run-time shaders
`capture_glslc`           reuses existing `glslc_capture` folders or compiles embedded GLSL
                          sources offline through the game's own `GLSLC` NSO (`glslc_emu.py`)
`capture_jit` /           reuses `jit/jit.img` or packs existing `jit_capture/` dumps via
`capture_nro`             `jit_capture.py`, and refuses missing runtime JIT or NRO captures
`mac_app` / `mac_run`     Mac platforms: refused
`build_ipa.sh`            replaced by `build_app.py` (through the shim, which also has to cover
                          the child processes the pipeline starts)
========================  ==========================================================
"""
from __future__ import annotations

import importlib.util
import os
import re
import shutil
import sys
import time
from pathlib import Path
from types import ModuleType

if __package__:
    from . import toolchain as tc
else:                                       # pragma: no cover - script mode
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
    from nspb_qt.win import toolchain as tc

#: The upstream `run()`, captured by `patch()` before the name is replaced.
_UPSTREAM_RUN = None

#: Options that exist upstream but cannot work on Windows, with the reason shown to the user.
REFUSED_OPTIONS = {
    '--prepare-xcode': 'generates an Xcode project, which needs Xcode and xcodegen (macOS only)',
    '--platform': 'only "--platform ios" builds on Windows: the mac platforms run the game in '
                  'the Mac host, which boots the game\'s arm64 code',
}


def repo_dir() -> Path:
    """The engine's folder: NSPB_REPO when set, else the checkout's or bundled engine/."""
    if env_repo := os.environ.get('NSPB_REPO'):
        p = Path(env_repo)
        if p.is_dir():
            return p
    from .. import engine
    here = Path(__file__).resolve()
    for depth in (3, 4):
        if len(here.parents) > depth:
            cand = Path(engine.engine_root(str(here.parents[depth])))
            if (cand / 'scripts' / 'build_ipa_from_nsp.py').is_file():
                return cand
    return Path(engine.engine_root(str(here.parents[3])))


def load_upstream(repo: Path) -> ModuleType:
    """Load `scripts/build_ipa_from_nsp.py` as a module.

    Before executing it, `pwd` is given a Windows stand-in: the file imports it at module level
    and the only use is recovering HOME when the environment lacks one. The stand-in is
    installed by the shim's `sitecustomize`, so importing this module after `shim.install` has
    run is enough; when that did not happen, a minimal stub is registered here so the loader
    never fails on an import the rest of the file does not need.
    """
    if 'pwd' not in sys.modules:
        _install_pwd_stub()
    if 'fcntl' not in sys.modules:
        _install_fcntl_stub()
    if not hasattr(os, 'getuid'):
        os.getuid = lambda: 0  # type: ignore[attr-defined]
    path = repo / 'scripts' / 'build_ipa_from_nsp.py'
    if not path.is_file():
        raise SystemExit(f'no engine: {path} is missing. Run `python3 tools/engine.py sync` in the checkout first.')
    spec = importlib.util.spec_from_file_location('nspb_upstream_build_ipa_from_nsp', path)
    if spec is None or spec.loader is None:
        raise SystemExit(f'cannot load {path}')
    mod = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = mod
    started = time.time()
    spec.loader.exec_module(mod)
    del started
    if hasattr(mod, 'tree_tar'):
        mod.tree_tar._lock = lambda folder, say=None: True
        mod.tree_tar._unlock = lambda folder: None
    if hasattr(mod, 'gamemod'):
        gm = mod.gamemod
        _Path = getattr(gm, 'Path', Path)

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

        gm.extra_dirs = lambda: [_Path(p) for p in _split_games_dir(os.environ.get('DM_GAMES_DIR', ''))]
    return mod


def _install_pwd_stub() -> None:
    import types

    pwd = types.ModuleType('pwd')

    class struct_passwd(tuple):
        __slots__ = ()

        @property
        def pw_dir(self):
            return self[5]

    def getpwuid(uid):
        home = os.environ.get('USERPROFILE') or os.path.expanduser('~')
        name = os.environ.get('USERNAME') or 'user'
        return struct_passwd((name, 'x', uid if uid is not None else 0, 0, '', home, ''))

    pwd.struct_passwd = struct_passwd
    pwd.getpwuid = getpwuid
    pwd.getpwnam = lambda name: getpwuid(0)
    sys.modules['pwd'] = pwd


def _install_fcntl_stub() -> None:
    import types

    fcntl = types.ModuleType('fcntl')
    fcntl.LOCK_SH = 1
    fcntl.LOCK_EX = 2
    fcntl.LOCK_NB = 4
    fcntl.LOCK_UN = 8
    fcntl.F_GETFD = 1
    fcntl.F_SETFD = 2
    fcntl.F_GETFL = 3
    fcntl.F_SETFL = 4
    fcntl.FD_CLOEXEC = 1
    fcntl.flock = lambda fd, op: None
    fcntl.lockf = lambda fd, cmd, len=0, start=0, whence=0: None
    fcntl.fcntl = lambda fd, cmd, arg=0: 0
    fcntl.ioctl = lambda fd, req, arg=0, mutate_flag=True: 0
    sys.modules['fcntl'] = fcntl


def _option_value(argv: list[str], name: str) -> str | None:
    for i, a in enumerate(argv):
        if a == name and i + 1 < len(argv):
            return argv[i + 1]
        if a.startswith(name + '='):
            return a.split('=', 1)[1]
    return None


def check_cli(argv: list[str]) -> None:
    """Refuse Mac-only options before any work starts, and say what to do instead."""
    for opt in REFUSED_OPTIONS:
        if opt in argv or any(a.startswith(opt + '=') for a in argv):
            if opt == '--platform':
                val = _option_value(argv, '--platform')
                if val in (None, 'ios'):
                    continue
                raise SystemExit(f'nspb: --platform {val} needs macOS with Xcode: {REFUSED_OPTIONS[opt]}')
            raise SystemExit(f'nspb: {opt} {REFUSED_OPTIONS[opt]}')


def patch(mod: ModuleType, repo: Path, *, j: int | None = None) -> None:
    """Replace the upstream functions that assume a Mac."""
    BuildError = mod.BuildError
    say = mod.say

    # The upstream `run()` is captured once, so `run_ipa` below can call it after replacing the
    # name. Capturing only the first time matters: a second `patch()` call (a re-patch, or a
    # test) would otherwise wrap `run_ipa` in itself and recurse until the stack dies.
    global _UPSTREAM_RUN
    if _UPSTREAM_RUN is None:
        _UPSTREAM_RUN = mod.run

    # ---------------------------------------------------------------- prereqs
    def check_prereqs(env, xlate, mac=False, *a, **kw):
        if mac:
            raise BuildError('the Mac platforms need a Mac: only iOS builds run on Windows')
        bad = [p for p in tc.check_all(deep=True) if p.required and not p.ok]
        if bad:
            lines = [f'{p.name}: {p.state}'
                     + (f' ({p.detail})' if p.detail else '')
                     + (f' — get it: {p.hint}' if p.hint else '')
                     for p in bad]
            raise BuildError('missing on this PC:\n  ' + '\n  '.join(lines)
                             + '\n(the Dependencies panel in the app lists and fixes these)')
        if not Path(xlate).parent.is_dir():
            raise BuildError(f'the shader translator is missing from the repository: {xlate}')
    mod.check_prereqs = check_prereqs

    # ---------------------------------------------------------------- nx_extract
    def build_nx_extract(repo_: Path, work: Path, logs: Path, env, *a, **kw):
        """Use the executable shipped with this engine, or build it for a source checkout."""
        bundled = repo_ / 'dm/tools/nx_extract_bin/nx_extract.exe'
        if bundled.is_file():
            return bundled

        import tempfile
        nx = work / 'tools/nx_extract/nx_extract'
        # An absolute path: `dotnet` by name relies on PATH, and a toolchain this app downloaded
        # lives in its own folder (the shim's PATH has it, but not every caller goes through it).
        dn = tc.dotnet_dir()
        dotnet = str(dn / 'dotnet.exe') if dn else 'dotnet'
        with tempfile.TemporaryDirectory(prefix='nx_extract_') as td:
            mod.run([dotnet, 'build', repo_ / 'dm/tools/nx_extract', '-c', 'Release',
                     '-o', td, '-v', 'quiet', '-nologo'],
                    logs / 'nx_extract_build.log', env=env)
            exe = Path(td) / 'nx_extract.exe'
            if not exe.exists():
                raise BuildError(f'nx_extract built without nx_extract.exe (see '
                                 f'{logs / "nx_extract_build.log"})')
            mod.rmtree(nx.parent)
            shutil.copytree(td, nx.parent)
        return nx
    mod.build_nx_extract = build_nx_extract

    # ---------------------------------------------------------------- APFS clones
    mod.can_clone = lambda *a, **kw: False
    if hasattr(mod, 'pack_dump'):
        mod.pack_dump.clone = shutil.copy2
    mod.apple_silicon = lambda *a, **kw: True     # only the heap estimate below asks
    mod.ALLOW_OTHER_METAL = True                  # Windows Metal Tools version differs from Xcode's

    # ---------------------------------------------------------------- the Mac host
    _in_oodle_host_lookup = False

    def build_mac_host(repo_, out, env, logs, g, *a, **kw):
        if _in_oodle_host_lookup:
            return Path(__file__).resolve().parent / 'oodle_emu.py'
        raise BuildError(
            'this step boots the game\'s own arm64 code in a Mac host, which no Windows PC can '
            'run. It is needed only for a game whose shaders appear at run time (GLSLC / Vulkan / '
            'GL capture), an Unreal or Oodle-packed game, or a heap check. Games whose shaders '
            'are in the RomFS (Mario Wonder, Odyssey, Mario Kart 8 Deluxe, the Zelda games, …) '
            'do not need it.')
    mod.build_mac_host = build_mac_host
    if hasattr(mod, 'UE_DECODE_SECS') and isinstance(mod.UE_DECODE_SECS, (int, float)):
        mod.UE_DECODE_SECS = max(int(mod.UE_DECODE_SECS) * 3, 900)

    if not hasattr(mod, '_nspb_orig_decode_ue_shaders') and hasattr(mod, 'decode_ue_shaders'):
        mod._nspb_orig_decode_ue_shaders = mod.decode_ue_shaders

    if hasattr(mod, '_nspb_orig_decode_ue_shaders'):
        _orig_decode_ue_shaders = mod._nspb_orig_decode_ue_shaders

        def decode_ue_shaders(repo_, dirs, pkg_ver, patched, work, env, logs, g, *a, **kw):
            nonlocal _in_oodle_host_lookup
            prev = _in_oodle_host_lookup
            _in_oodle_host_lookup = True
            try:
                return _orig_decode_ue_shaders(
                    repo_, dirs, pkg_ver, patched, work, env, logs, g, *a, **kw
                )
            finally:
                _in_oodle_host_lookup = prev

        mod.decode_ue_shaders = decode_ue_shaders

    def heap_check(repo_, d, patched, work, env, logs, g, *a, **kw):
        """The heap check without the Mac host.

        Upstream boots the game for a few seconds to read its heap request. Without that, a game
        with virtual address memory (an NPDM system resource) whose `nninitStartup` hands
        `pool - used` to StandardAllocator gets a 2 GB pool: the size that was measured to work
        with Unity titles, and small enough to leave the alias region room for the game's own
        allocations. The profile is stamped the same way upstream stamps it, so later builds
        keep the result instead of estimating again.
        """
        mod.PROG.stage('heap estimate (no Mac host)')
        sig = {}
        try:
            pool = int(g.get('app_pool', '0') or '0', 0)
            sysres = int(g.get('sys_resource', '0') or '0', 0)
        except ValueError:
            pool = sysres = 0
        if sysres and pool > 0x80000000:
            sig['app_pool'] = ('0x80000000',
                               'virtual address memory and no heap check on Windows: a 2 GB '
                               'pool, so StandardAllocator\'s region leaves the alias region '
                               'room for the game\'s own allocations')
        for k, (v, why) in sig.items():
            say(f'heap estimate: {k} {v}: {why}')
        if sig:
            g = mod.set_keys(g, sig, 'Heap estimate on Windows (no Mac host)')
        p = Path(g.dir) / 'game.tsv'
        p.write_text(p.read_text(encoding='utf-8')
                     + f'\n# heap check: {time.strftime("%Y-%m-%d")}, estimated on Windows '
                       'without booting the game'
                     + (f'; set {", ".join(sig)}' if sig else '') + '\n', encoding='utf-8')
        mod.PROG.end('set ' + ', '.join(sig) if sig else 'guessed keys kept')
        return type(g)(g.dir)
    mod.heap_check = heap_check

    def region_skip(repo_, d, patched, work, env, logs, g, *a, **kw):
        """The address-region check without the Mac host.

        Upstream boots the game in the Mac host to report where its address regions reach against
        the profile's alias region. Skipped on Windows and stamped with the rewrite ID so later
        builds do not ask again.
        """
        mod.PROG.stage('address regions (no Mac host)')
        say('no address region check: it boots the game in the Mac host, which needs a Mac; '
            'the profile keeps its address-region keys')
        p = Path(g.dir) / 'game.tsv'
        old = [ln for ln in p.read_text(encoding='utf-8').rstrip('\n').split('\n')
               if not ln.startswith('# address regions: ')]
        rid = mod.rewrite_id(patched) if hasattr(mod, 'rewrite_id') else 'windows'
        p.write_text('\n'.join(old).rstrip('\n')
                     + f'\n\n# address regions: {time.strftime("%Y-%m-%d")}, '
                       f'not checked (no Mac host on this PC) (rewrite {rid})\n',
                     encoding='utf-8')
        mod.PROG.end('skipped: needs the Mac host')
        return type(g)(g.dir)
    mod.region_check = region_skip

    # ---------------------------------------------------------------- derived romfs_marker & auto SDK cuts
    if not hasattr(mod, '_nspb_orig_derive_profile') and hasattr(mod, 'derive_profile'):
        mod._nspb_orig_derive_profile = mod.derive_profile

    if hasattr(mod, '_nspb_orig_derive_profile'):
        _orig_derive = mod._nspb_orig_derive_profile

        def derive_profile(g, pdir, ver, d, mods, *rest, **kw):
            disp = _orig_derive(g, pdir, ver, d, mods, *rest, **kw)
            tsv = Path(pdir) / 'game.tsv'
            lines = tsv.read_text(encoding='utf-8').splitlines()
            old = next((ln.split('\t', 1)[1] for ln in lines if ln.startswith('romfs_marker\t')), None)
            romfs = mod.rfs.source(d)
            if old and not (romfs / old).exists():
                files = [p for p in romfs.rglob('*') if p.is_file()]
                new = ('main.lua' if (romfs / 'main.lua').exists()
                       else os.path.relpath(max(files, key=lambda p: p.stat().st_size),
                                            romfs).replace('\\', '/') if files else None)
                if new:
                    tsv.write_text(
                        '\n'.join(f'romfs_marker\t{new}' if ln.startswith('romfs_marker\t') else ln
                                  for ln in lines) + '\n',
                        encoding='utf-8')
                    say(f'romfs_marker: {old} is not in {ver}\'s RomFS; the derived profile uses {new}')
            return disp
        mod.derive_profile = derive_profile

    if not hasattr(mod, '_nspb_orig_rewrite') and hasattr(mod, 'rewrite'):
        mod._nspb_orig_rewrite = mod.rewrite
        mod._nspb_orig_patch_files = mod.patch_files

    if hasattr(mod, '_nspb_orig_rewrite'):
        _orig_rewrite = mod._nspb_orig_rewrite
        _orig_patch_files = mod._nspb_orig_patch_files

        def rewrite(py_, repo_, exe_dir, out, env, logs, g, provisional=False, *a, **kw):
            import json
            from . import sdk_auto_cuts
            sdk_nso = Path(exe_dir) / 'sdk'
            jf = Path(out).with_name(Path(out).name + '.auto_sdk_cuts.json')
            if jf.exists():
                jf.unlink()
            try:
                sysres = int(g.get('sys_resource', '0') or '0', 0)
            except ValueError:
                sysres = 0
            if sdk_nso.is_file() and sysres:
                tools_dir = str(Path(repo_) / 'dm' / 'tools')
                if tools_dir not in sys.path:
                    sys.path.insert(0, tools_dir)
                try:
                    import importlib
                    registered = importlib.import_module('sdk_patches').CUTS
                    bid = mod.build_id(sdk_nso)
                    if bid not in registered:
                        _, cuts = sdk_auto_cuts.for_nso(sdk_nso, log=say, repo=repo_)
                        if cuts:
                            jf.parent.mkdir(parents=True, exist_ok=True)
                            jf.write_text(json.dumps({bid: [list(c) for c in cuts]}, indent=1),
                                          encoding='utf-8')
                            say(f'sdk {bid[:12]} is not in dm/tools/sdk_patches.py: '
                                f'{len(cuts)} address-region cut(s) found in its code')
                except Exception:
                    pass
            if jf.exists():
                os.environ['NSPB_AUTO_SDK_CUTS'] = env['NSPB_AUTO_SDK_CUTS'] = str(jf)
            else:
                os.environ.pop('NSPB_AUTO_SDK_CUTS', None)
                env.pop('NSPB_AUTO_SDK_CUTS', None)
            return _orig_rewrite(py_, repo_, exe_dir, out, env, logs, g, provisional, *a, **kw)

        def patch_files(repo_, exe_dir, mods, game_id=None, *a, **kw):
            f = _orig_patch_files(repo_, exe_dir, mods, game_id, *a, **kw)
            j = os.environ.get('NSPB_AUTO_SDK_CUTS')
            return f + ([Path(j)] if j and Path(j).exists() else [])

        mod.rewrite = rewrite
        mod.patch_files = patch_files

    # ---------------------------------------------------------------- the shader cache key
    def toolchain_probe(repo_=None, env=None, *a, **kw):
        """What the shader-stage cache keys record as "the compilers".

        Upstream records `xcodebuild -version` and fingerprints the SPIRV-Cross
        executable returned by `spirv_cross(repo, env)`. Here the Metal compiler's
        own version is what actually changes the output, so it is recorded instead;
        a Metal Tools upgrade then invalidates the cache, which is the behaviour
        we want. The SPIRV-Cross entry uses the upstream resolver as well, so the
        cache follows `SPIRV_CROSS` (an explicit path or an executable on PATH),
        not whichever `spirv-cross` happens to be found by a separate lookup.
        """
        xc = [sys.executable, str(Path(__file__).resolve().parent / 'xcrun_shim.py')]
        probes = [('cmd', [*xc, '-sdk', 'iphoneos', 'metal', '--version'])]
        if os.environ.get('NSPB_MAC_METAL'):
            probes.append(('cmd', [*xc, '-sdk', 'macosx', 'metal', '--version']))
        if repo_ is None:
            repo_ = Path(__file__).resolve().parents[3]
        probes.append(('files', [mod.spirv_cross(repo_, env)]))
        return tuple(probes)
    mod.toolchain = toolchain_probe

    # ---------------------------------------------------------------- run-time capture
    def _refuse_capture(what: str):
        def fn(*a, **k):
            raise BuildError(
                f'{what} compiles its shaders at run time, and upstream captures them by '
                'booting the game in the Mac host — which needs a Mac, or a Mac virtual '
                'machine on this PC. The game\'s files are extracted, so a Mac can finish the '
                'build from the same work folder (its shader/ and extract/ are reused).')
        return fn
    def capture_glslc(repo_=None, dirs=None, pkg_ver=None, patched=None, work=None,
                      env=None, logs=None, g=None, *a, **kw):
        """Reuse existing `glslc_capture` folders or compile embedded GLSL shaders offline."""
        if isinstance(dirs, dict) and dirs and hasattr(mod, 'glslc_done'):
            want = (
                mod.glslc_wanted(g)
                if (g is not None and hasattr(mod, 'glslc_wanted'))
                else None
            )
            todo = [
                v for v, d in dirs.items()
                if not (
                    mod.glslc_done(Path(d) / 'glslc_capture') >= want
                    if want
                    else mod.glslc_done(Path(d) / 'glslc_capture')
                )
            ]
            if not todo:
                mod.PROG.stage('GLSLC capture')
                say(
                    'reusing the captured run-time shaders: '
                    + ', '.join(str(Path(d) / 'glslc_capture') for d in dirs.values())
                )
                mod.PROG.end('reused')
                return None

            from . import glslc_emu
            mod.PROG.stage('GLSLC capture')
            t0 = time.time()
            all_ok = True
            total_got = 0
            for ver in todo:
                d_path = Path(dirs[ver])
                cap = d_path / 'glslc_capture.partial'
                mod.rmtree(cap)
                nro_cands: list[Path] = []
                if patched is not None:
                    p_path = Path(patched)
                    nro_cands.append(
                        p_path.with_name('nro_' + p_path.name.removeprefix('patched_'))
                    )
                if work is not None:
                    nro_cands.append(Path(work) / f'nro_{ver}')
                mod.PROG.set(
                    step='compiling run-time shaders offline',
                    done=0,
                    total=len(want) if want else None,
                    unit='shaders',
                )
                say(f'compiling run-time GLSLC shaders offline → {d_path / "glslc_capture"}')
                try:
                    glslc_emu.compile_for_version(
                        d_path,
                        cap,
                        nro_dirs=nro_cands,
                        wanted=want,
                        say=say,
                        progress=lambda n: mod.PROG.set(done=n),
                    )
                except Exception as exc:
                    say(f'offline GLSLC compilation failed ({exc})')
                    mod.rmtree(cap)
                    all_ok = False
                    break
                got = mod.glslc_done(cap)
                if want and got >= want or (not want and got):
                    mod.swap_in(cap, d_path / 'glslc_capture')
                    total_got += len(got)
                else:
                    if want:
                        say(f'offline GLSLC compilation incomplete: got {len(got & want)}/{len(want)} shader(s)')
                    mod.rmtree(cap)
                    all_ok = False
                    break
            if all_ok:
                dt = time.time() - t0
                end_msg = (
                    f'{total_got} shaders in {mod.hms(dt)}'
                    if hasattr(mod, 'hms')
                    else f'{total_got} shaders'
                )
                mod.PROG.end(end_msg)
                return None
            mod.PROG.end(ok=False)

        return _refuse_capture('this game')(
            repo_, dirs, pkg_ver, patched, work, env, logs, g, *a, **kw
        )

    mod.capture_glslc = capture_glslc

    def capture_shaders(repo_=None, d=None, patched=None, work=None, env=None,
                        logs=None, g=None, api='gl', *a, **kw):
        """Reuse existing `gl_capture`/`vk_capture` or reconstruct LÖVE / GameMaker GL shaders offline."""
        if d is not None:
            d_path = Path(d)
            out = d_path / f'{api}_capture'
            want = (
                mod.capture_wanted(g, api)
                if (g is not None and hasattr(mod, 'capture_wanted'))
                else None
            )
            if want and hasattr(mod, 'capture_done') and mod.capture_done(out, api) >= want:
                c_name = (
                    mod.CAPTURES[api]['name']
                    if (hasattr(mod, 'CAPTURES') and api in mod.CAPTURES)
                    else ('Vulkan' if api == 'vk' else api.upper())
                )
                mod.PROG.stage(f'{c_name} shader capture')
                say(f'reusing the captured run-time shaders: {out}')
                mod.PROG.end('reused')
                return out
            if api == 'gl':
                main_nso = d_path / 'ExeFS' / 'main'
                if main_nso.is_file():
                    from . import gm_shaders, love_shaders
                    part = d_path / 'gl_capture.partial'
                    table = None
                    if g is not None and hasattr(mod, 'CAPTURES'):
                        try:
                            table = g.table(mod.CAPTURES['gl']['table'])
                        except Exception:
                            table = None
                    rom_src = (
                        mod.rfs.source(d_path)
                        if hasattr(mod, 'rfs')
                        else (d_path / 'RomFS')
                    )
                    for eng_label, sh_mod, err_cls in (
                        ('LÖVE', love_shaders, love_shaders.LoveShaderError),
                        ('GameMaker', gm_shaders, gm_shaders.GMShaderError),
                    ):
                        mod.rmtree(part)
                        try:
                            res = sh_mod.generate(
                                main_nso,
                                rom_src,
                                part,
                                table,
                                log=say,
                                repo=repo_,
                                require_table=True,
                            )
                        except (err_cls, ValueError) as e:
                            mod.rmtree(part)
                            raise BuildError(str(e)) from e
                        if res is not None:
                            mod.PROG.stage(f'GL shader reconstruction ({eng_label})')
                            if hasattr(mod, 'swap_in'):
                                mod.swap_in(part, out)
                            else:
                                mod.rmtree(out)
                                part.rename(out)
                            mod.PROG.end(f'{len(res[0])} shaders')
                            return out
                        mod.rmtree(part)
        return _refuse_capture('this game')(
            repo_, d, patched, work, env, logs, g, api, *a, **kw
        )

    mod.capture_shaders = capture_shaders

    def capture_jit(py_=None, repo_=None, d=None, patched=None, work=None,
                    env=None, logs=None, g=None, *a, **kw):
        """Reuse `jit/jit.img` or pack existing `jit_capture/` dumps via `jit_capture.py`."""
        if d is not None:
            d_path = Path(d)
            out = d_path / 'jit'
            if (out / 'jit.img').is_file():
                say(f'reusing the captured JIT image: {out / "jit.img"}')
                return out
            caps = d_path / 'jit_capture'
            if caps.is_dir():
                stamp_ok = True
                if patched is not None and g is not None and hasattr(mod, 'jit_stamp'):
                    sf = caps / 'stamp.json'
                    stamp_ok = (
                        sf.is_file()
                        and sf.read_text(encoding='utf-8', errors='replace') == mod.jit_stamp(patched, g)
                    )
                route = (
                    g.get('jit_route', '')
                    if (g is not None and hasattr(g, 'get'))
                    else ''
                )
                req = ('boot1', 'boot2') + (('route',) if route else ())
                if stamp_ok and all(any((caps / n).glob('*.jit')) for n in req):
                    mod.PROG.stage('JIT capture', step='image')
                    tmp = d_path / 'jit.partial'
                    mod.rmtree(tmp)
                    log_path = (Path(logs) / 'jit_capture.log') if logs is not None else None
                    dirs_arg = sorted(
                        str(x) for x in caps.iterdir()
                        if x.is_dir() and not x.name.endswith('.partial')
                    )
                    gid = getattr(g, 'id', '') if g is not None else ''
                    mod.run(
                        [py_ or sys.executable, Path(repo_) / 'dm/tools/jit_capture.py', '--profile', gid]
                        + dirs_arg
                        + [tmp],
                        log_path,
                        env=env,
                    )
                    if hasattr(mod, 'swap_in'):
                        mod.swap_in(tmp, out)
                    else:
                        mod.rmtree(out)
                        tmp.rename(out)
                    summary = 'reused captures'
                    if log_path is not None and log_path.is_file():
                        lines = log_path.read_text(encoding='utf-8', errors='replace').strip().splitlines()
                        if lines:
                            summary = lines[-1][:120]
                    mod.PROG.end(summary)
                    return out
        _refuse_capture('this game (nn::jit)')()

    mod.capture_jit = capture_jit

    def capture_nro(py_=None, repo_=None, exe_dir=None, out=None, nro_dir=None,
                    env=None, logs=None, g=None, provisional=False, *a, **kw):
        """Return `g` when no runtime NRO is missing, decode `nxboot` NROs offline, or refuse."""
        if nro_dir is not None:
            missing = Path(nro_dir) / 'missing.tsv'
            if not missing.is_file():
                return g
            want = dict(
                line.split('\t', 1)
                for line in missing.read_text(encoding='utf-8', errors='replace').splitlines()
                if line and '\t' in line
            )
            if not want:
                return g
            if exe_dir is not None and (Path(exe_dir) / 'main').is_file():
                from . import nro_emu
                if hasattr(mod.PROG, 'add'):
                    mod.PROG.add(2)
                mod.PROG.stage('NRO capture')
                mod.PROG.set(step='decoding runtime NRO offline')
                try:
                    captured = nro_emu.capture_missing_nros(exe_dir, nro_dir, say=say)
                except Exception as exc:
                    say(f'offline NRO decode failed ({exc})')
                    captured = []
                rem = (
                    [
                        ln
                        for ln in missing.read_text(encoding='utf-8', errors='replace').splitlines()
                        if ln and '\t' in ln
                    ]
                    if missing.is_file()
                    else []
                )
                if captured and not rem:
                    name, _sha, sz = captured[-1]
                    mod.PROG.end(f'{name}, {sz / 2**20:.1f} MB')
                    if hasattr(mod, 'rewrite') and out is not None:
                        return mod.rewrite(py_, repo_, exe_dir, out, env, logs, g, provisional)
                    return g
                mod.PROG.end(ok=False)
        _refuse_capture('this game (runtime NRO)')()

    mod.capture_nro = capture_nro

    # ---------------------------------------------------------------- Unreal inline & Oodle/LZ5 shaders
    pg = getattr(mod, 'pg', None)
    if pg is None:
        for sub in ('tools', 'games'):
            d = str(Path(repo) / 'dm' / sub)
            if d not in sys.path:
                sys.path.insert(0, d)
        try:
            import importlib
            pg = importlib.import_module('profile_guess')
            mod.pg = pg
        except Exception:
            pg = None

    if pg is not None:
        if not hasattr(pg, '_nspb_orig_build_sources') and hasattr(pg, 'build_sources'):
            pg._nspb_orig_build_sources = pg.build_sources
        if hasattr(pg, '_nspb_orig_build_sources'):
            _orig_build_sources = pg._nspb_orig_build_sources

            def build_sources(exefs, romfs, modules=('main',), *a, **kw):
                res = _orig_build_sources(exefs, romfs, modules, *a, **kw)
                if isinstance(res, dict) and 'oodle_packs' in res:
                    cache = getattr(mod, '_nspb_build_sources_oodle', None)
                    if not isinstance(cache, dict):
                        cache = {}
                        mod._nspb_build_sources_oodle = cache
                    cache[str(romfs)] = bool(res['oodle_packs'][0])
                return res

            pg.build_sources = build_sources

    def _rom_has_oodle_packs(pg_mod, romfs, main_path) -> bool:
        if pg_mod is None or main_path is None or not callable(getattr(pg_mod, 'build_sources', None)):
            return False
        mp = Path(main_path)
        if not mp.is_file():
            return False
        try:
            with open(mp, 'rb') as f:
                if f.read(4) != b'NSO0':
                    return False
            nso_fn = getattr(pg_mod, 'nso_files', None)
            mods = [p.name for p in nso_fn(mp.parent)] if callable(nso_fn) else [mp.name]
            res = pg_mod.build_sources(mp.parent, romfs, mods or [mp.name])
            if isinstance(res, dict) and 'oodle_packs' in res:
                return bool(res['oodle_packs'][0])
        except Exception:
            pass
        return False

    if not hasattr(mod, '_nspb_orig_split_shaders') and hasattr(mod, 'split_shaders'):
        mod._nspb_orig_split_shaders = mod.split_shaders

    if hasattr(mod, '_nspb_orig_split_shaders'):
        _orig_split_shaders = mod._nspb_orig_split_shaders

        def split_shaders(py_, repo_, roms, mains, pkg, env, logs, g,
                          provisional=False, oodle=None, *a, **kw):
            """Wire `oodle_emu.py` for Oodle/LZ5 games while keeping pure Zlib/LZ4 paks zero-overhead.

            When `oodle_packs` is empty and the game's `ExeFS/main` embeds no Oodle or LZ5 decoder
            (e.g., OCTOPATH TRAVELER I or Yoshi's Crafted World), `oodle` is cleared to `None` so
            `shader_split.py` runs purely in Python with zero child-process overhead. When the game
            does have Oodle packs or an embedded Oodle/LZ5 decoder, `oodle` resolves `DM_OODLE_HOST`
            to `oodle_emu.py`.
            """
            if oodle is not None:
                cur_pg = getattr(mod, 'pg', None) or pg
                cache = getattr(mod, '_nspb_build_sources_oodle', None)
                recorded = cache if isinstance(cache, dict) else {}
                pairs = [
                    (r, mains[i] if mains and i < len(mains) else None)
                    for i, r in enumerate(roms)
                ]
                has_oodle_packs = False
                for r, m in pairs:
                    key = str(r)
                    if key in recorded:
                        val = bool(recorded.pop(key))
                    else:
                        val = _rom_has_oodle_packs(cur_pg, r, m)
                    if val:
                        has_oodle_packs = True
                from . import oodle_emu
                if not has_oodle_packs and not oodle_emu.has_decoder(mains):
                    oodle = None
                    if env.get('DM_EXPERIMENTAL_BUILDER') == '1':
                        env = dict(env)
                        env.pop('DM_EXPERIMENTAL_BUILDER', None)
                else:
                    _orig_oodle = oodle

                    def _win_oodle():
                        nonlocal _in_oodle_host_lookup
                        prev = _in_oodle_host_lookup
                        _in_oodle_host_lookup = True
                        try:
                            return _orig_oodle()
                        finally:
                            _in_oodle_host_lookup = prev

                    oodle = _win_oodle
            return _orig_split_shaders(py_, repo_, roms, mains, pkg, env, logs, g,
                                       provisional, oodle, *a, **kw)

        mod.split_shaders = split_shaders

    # ---------------------------------------------------------------- Mac outputs
    def mac_app(*a, **k):
        raise BuildError('--platform mac-app packs a macOS app: it needs a Mac')
    mod.mac_app = mac_app

    def mac_run(*a, **k):
        raise BuildError('--platform mac is a development build for this Mac: it needs a Mac')
    mod.mac_run = mac_run

    # ---------------------------------------------------------------- the tool paths
    # TOOL_PATHS is a macOS list; on Windows it is replaced outright with the folders the shim
    # needs, so the upstream value must not survive (a macOS path on Windows is harmless but
    # confusing in logs, and `/opt/homebrew/bin` as a PATH entry is dead weight).
    extra = []
    if llvm := tc.llvm_dir():
        extra.append(str(llvm / 'bin'))
    for name in ('spirv-cross', 'zstd', 'glslangValidator'):
        if p := tc.find_exe(name):
            extra.append(str(p.parent))
    # The .NET root, wherever it actually is: `Program Files` is only one of the places
    # `dotnet_dir()` accepts, and the copy the app installs for itself is the one that matters on
    # a machine with no system SDK. Without this, `dotnet build` (called by name in
    # build_nx_extract) would not find it.
    if dn := tc.dotnet_dir():
        extra.append(str(dn))
    mod.TOOL_PATHS = extra

    # ---------------------------------------------------------------- the app build
    def run_ipa(cmd, log, *a, **kw):
        """Intercept the `bash dm/ios/tools/build_ipa.sh` call and run `build_app.py` instead.

        The signature forwards all positional and keyword arguments (`env`, `cwd`, `on_line`,
        `ok`, `fatal`, etc.) to upstream's `run()`, so the caller's logging, progress and error
        reporting are reused unchanged; only the command is swapped.
        """
        cmd = [str(c) for c in cmd]
        if (len(cmd) >= 2 and Path(cmd[0]).name in ('bash', 'sh')
                and cmd[1].replace('\\', '/').endswith('dm/ios/tools/build_ipa.sh')):
            if '--prepare-xcode' in cmd:
                raise BuildError('--prepare-xcode needs Xcode and xcodegen: drop it on Windows')
            cmd = [sys.executable, str(Path(__file__).resolve().parent / 'build_app.py'),
                   *cmd[2:]]
        res = _UPSTREAM_RUN(cmd, log, *a, **kw)
        if (len(cmd) >= 2 and cmd[1].replace('\\', '/').endswith('dm/gfx/tools/shader_split.py')
                and log is not None and Path(log).is_file()):
            text = Path(log).read_text(encoding='utf-8', errors='replace')
            if ('Oodle- or LZ5-compressed game files: set DM_OODLE_HOST' in text
                    or 'the game\'s decoder in the Mac host' in text):
                if len(cmd) >= 5 and Path(cmd[4]).parent.name.endswith('.partial'):
                    mod.rmtree(Path(cmd[4]).parent)
                m = re.search(r'^\[RED\] (.+)$', text, re.M)
                detail = f'{m.group(1)}\n' if m else ''
                raise BuildError(
                    f'{detail}this game\'s shader archives use Oodle or LZ5 compression, which '
                    'must be decoded by booting the game\'s own arm64 code in a Mac host '
                    f'(each file in {log})')
        return res

    mod.run = run_ipa


def main(argv: list[str] | None = None) -> int:
    """Entry point: check the CLI, build the environment, patch, and run upstream."""
    argv = list(sys.argv[1:] if argv is None else argv)
    check_cli(argv)
    repo = repo_dir()
    if os.name != 'nt' and not os.environ.get('NSPB_ALLOW_NON_WINDOWS'):
        raise SystemExit('nspb_qt.win.driver runs the Windows build; on macOS use '
                         'scripts/build_ipa_from_nsp.py')

    from . import shim
    env = shim.build_env(python_exe=sys.executable)
    os.environ.clear()
    os.environ.update(env)
    sdir = str(shim.shim_dir())
    if sdir not in sys.path:
        sys.path.insert(0, sdir)
    if 'sitecustomize' not in sys.modules:
        try:
            import sitecustomize  # noqa: F401
        except Exception:
            pass

    mod = load_upstream(repo)
    patch(mod, repo)
    sys.argv[0] = str(repo / 'scripts' / 'build_ipa_from_nsp.py')
    return mod.cli(argv)


if __name__ == '__main__':
    raise SystemExit(main())
