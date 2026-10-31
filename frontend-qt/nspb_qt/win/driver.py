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
`build_nx_extract`        on Windows the .NET build emits `nx_extract.exe`, not `nx_extract`
`can_clone`               no APFS: plain copies (`nx_extract` spends the disk, not the build)
`apple_silicon`           no `sysctl`
`heap_check`              boots the game in the Mac host; replaced by an estimate
`build_mac_host`          the Mac host can never run here: refuses with a clear message
`toolchain`               the shader cache key needs the Windows Metal compiler's version
`capture_shaders` /       run-time shader capture boots the game in the Mac host: refused,
`capture_glslc`           with the device-capture workflow explained
`mac_app` / `mac_run`     Mac platforms: refused
`build_ipa.sh`            replaced by `build_app.py` (through the shim, which also has to cover
                          the child processes the pipeline starts)
========================  ==========================================================
"""
from __future__ import annotations

import importlib.util
import os
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
    """The engine's folder: the checkout's engine/ when synced, else its committed tree (LNPANDY/NX2Apple#214)."""
    from .. import engine
    return Path(engine.engine_root(str(Path(__file__).resolve().parents[3])))


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
    path = repo / 'scripts' / 'build_ipa_from_nsp.py'
    if not path.is_file():
        raise SystemExit(f'not a repository checkout: {path} is missing')
    spec = importlib.util.spec_from_file_location('nspb_upstream_build_ipa_from_nsp', path)
    if spec is None or spec.loader is None:
        raise SystemExit(f'cannot load {path}')
    mod = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = mod
    started = time.time()
    spec.loader.exec_module(mod)
    del started
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
    def check_prereqs(env, xlate, mac=False):
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
    def build_nx_extract(repo_: Path, work: Path, logs: Path, env):
        """The .NET build, but on Windows the output is `nx_extract.exe`."""
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
    mod.can_clone = lambda d: False
    mod.apple_silicon = lambda: True     # only the heap estimate below asks

    # ---------------------------------------------------------------- the Mac host
    def build_mac_host(repo_, out, env, logs, g):
        raise BuildError(
            'this step boots the game\'s own arm64 code in a Mac host, which no Windows PC can '
            'run. It is needed only for a game whose shaders appear at run time (GLSLC / Vulkan / '
            'GL capture), an Unreal or Oodle-packed game, or a heap check. Games whose shaders '
            'are in the RomFS (Mario Wonder, Odyssey, Mario Kart 8 Deluxe, the Zelda games, …) '
            'do not need it.')
    mod.build_mac_host = build_mac_host

    def heap_check(repo_, d, patched, work, env, logs, g):
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

    # ---------------------------------------------------------------- the shader cache key
    def toolchain_probe():
        """What the shader-stage cache keys record as "the compilers".

        Upstream records `xcodebuild -version` and `spirv-cross --revision`. Here the Metal
        compiler's own version is what actually changes the output, so it is recorded instead;
        a Metal Tools upgrade then invalidates the cache, which is the behaviour we want.
        """
        xc = [sys.executable, str(Path(__file__).resolve().parent / 'xcrun_shim.py')]
        probes = [('cmd', [*xc, '-sdk', 'iphoneos', 'metal', '--version'])]
        if os.environ.get('NSPB_MAC_METAL'):
            probes.append(('cmd', [*xc, '-sdk', 'macosx', 'metal', '--version']))
        probes.append(('cmd', ['spirv-cross', '--revision']))
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
    mod.capture_glslc = _refuse_capture('this game')
    mod.capture_shaders = _refuse_capture('this game')

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
    def run_ipa(cmd, log, env=None, cwd=None, on_line=None):
        """Intercept the `bash dm/ios/tools/build_ipa.sh` call and run `build_app.py` instead.

        The signature matches upstream's `run()`, so the caller's logging, progress and error
        reporting are reused unchanged; only the command is swapped.
        """
        cmd = [str(c) for c in cmd]
        if (len(cmd) >= 2 and Path(cmd[0]).name in ('bash', 'sh')
                and cmd[1].replace('\\', '/').endswith('dm/ios/tools/build_ipa.sh')):
            if '--prepare-xcode' in cmd:
                raise BuildError('--prepare-xcode needs Xcode and xcodegen: drop it on Windows')
            cmd = [sys.executable, str(Path(__file__).resolve().parent / 'build_app.py'),
                   *cmd[2:]]
        return _UPSTREAM_RUN(cmd, log, env=env, cwd=cwd, on_line=on_line)

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

    mod = load_upstream(repo)
    patch(mod, repo)
    sys.argv[0] = str(repo / 'scripts' / 'build_ipa_from_nsp.py')
    return mod.cli(argv)


if __name__ == '__main__':
    raise SystemExit(main())
