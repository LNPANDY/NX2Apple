"""`xcrun` for Windows: the subset of the interface the pipeline actually uses.

Mapped calls, and why each needs translating rather than just forwarding:

``xcrun -sdk iphoneos metal ...``
    Metal Developer Tools for Windows' `metal.exe`. Xcode's `-mios-version-min=X` is not
    understood there; the Windows compiler wants an explicit `-target air64-apple-iosX`, so the
    flag is rewritten. A macOS compile with no target gets `air64-apple-macos<version>`.
``xcrun -sdk ... metallib ...``
    `metallib.exe` of the matching toolchain.
``xcrun -sdk iphoneos clang ...``
    LLVM clang with `-target arm64-apple-ios<deployment> -isysroot <SDK>`. `/dev/null` becomes
    `NUL`, because `compile_check.py` uses `-o /dev/null`.
``xcrun [-sdk ...] --show-sdk-version | --show-sdk-build-version | --show-sdk-path``
    Read from the SDK's `SDKSettings.json` / `SystemVersion.plist`.
``xcrun -f <tool>``
    The path of the mapped tool, or exit 1.

Anything else exits 127 with a message naming the call, so an unmapped step shows up in the
build log as a missing tool instead of silently producing a wrong result.

`metal-tt` is deliberately absent: the Windows Metal tools do not ship it, and pretending it
works would produce a half-written pipeline archive.
"""
from __future__ import annotations

import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

# Importable both as `nspb_qt.win.xcrun_shim` and as a plain script (the `.cmd` stand-in runs it
# by path, where there is no package context).
if __package__:
    from . import toolchain as tc
    from . import IOS_DEPLOYMENT as _IOS_DEPLOYMENT
else:                                        # pragma: no cover - script mode
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
    from nspb_qt.win import toolchain as tc
    from nspb_qt.win import IOS_DEPLOYMENT as _IOS_DEPLOYMENT

#: Metal targets used when the caller gave none. The iOS one matches what upstream passes as
#: `-mios-version-min=18.0` (a Metal language version, not the app's deployment target).
METAL_IOS_TARGET = '18.0'
METAL_MACOS_TARGET = '15.0'


def metal_args(sdk: str, args: list[str]) -> list[str]:
    """Translate Xcode's Metal flags into what the Windows Metal compiler accepts.

    The important one is the target: the Windows `metal.exe` has no implicit OS, so a compile
    without `-target` produces AIR for the host and `metallib` then refuses to link it.
    """
    out: list[str] = []
    has_target = False
    for a in args:
        if a.startswith('-mios-version-min='):
            out += ['-target', f'air64-apple-ios{a.split("=", 1)[1]}']
            has_target = True
            continue
        if a.startswith(('-mmacosx-version-min=', '-mmacos-version-min=')):
            out += ['-target', f'air64-apple-macos{a.split("=", 1)[1]}']
            has_target = True
            continue
        if a in ('-target', '--target') or a.startswith(('-target=', '--target=')):
            has_target = True
        out.append(a)
    if not has_target and not any(a in ('--version', '-v', '--help', '-version') for a in args):
        tgt = (f'air64-apple-ios{tc.setting("metal_ios_target", METAL_IOS_TARGET)}'
               if sdk.startswith('iphone')
               else f'air64-apple-macos{tc.setting("metal_macos_target", METAL_MACOS_TARGET)}')
        out = ['-target', tgt] + out
    return out


def clang_args(args: list[str]) -> list[str]:
    sdk = tc.ios_sdk()
    if not sdk:
        _die('no iPhoneOS SDK (download one in the app, or set "ios_sdk" in toolchain.json)')
    fixed = ['NUL' if a == '/dev/null' else a for a in args]
    dep = tc.setting('ios_deployment', _IOS_DEPLOYMENT)
    return ['-target', f'arm64-apple-ios{dep}', '-isysroot', str(sdk)] + fixed


def _sdk_info(sdk: str, what: str) -> str:
    if sdk.startswith('iphone'):
        p = tc.ios_sdk()
        if not p:
            _die(f'no iPhoneOS SDK for {what}')
        ver, build = tc.sdk_version(p)
        table = {'--show-sdk-path': str(p), '--show-sdk-version': ver,
                 '--show-sdk-build-version': build}
        if what in table:
            return table[what]
        _die(f'unsupported query {what}')
    # macOS: there is no macOS SDK here. The Metal tools' own folder name identifies the
    # toolchain for the caches that key on it.
    root = tc.metal_dir()
    if what == '--show-sdk-path':
        return str(root or '')
    if what == '--show-sdk-version':
        return 'windows-metal-tools'
    if what == '--show-sdk-build-version':
        return root.name if root else 'missing'
    _die(f'unsupported query {what}')


TOOL_MAP = {
    'strip': 'llvm-strip', 'nm': 'llvm-nm', 'otool': 'llvm-otool', 'lipo': 'llvm-lipo',
    'objdump': 'llvm-objdump', 'ar': 'llvm-ar', 'libtool': 'llvm-ar', 'ranlib': 'llvm-ranlib',
    'dsymutil': 'llvm-dsymutil',
}


def find(sdk: str, tool: str) -> Path | None:
    """The Windows executable standing in for one xcrun tool."""
    if tool in ('metal', 'metallib', 'metal-objdump', 'metal-ar'):
        return tc.metal_tool(tool, sdk)
    if tool in ('clang', 'clang++'):
        return tc.llvm_tool('clang')
    if tool in ('ld', 'ld64', 'ld64.lld'):
        lld, _note = tc.ensure_ld64_lld()
        return lld
    if tool == 'swiftc':
        return None            # no Swift toolchain: win/ios/Launcher.m replaces Launcher.swift
    if tool == 'actool':
        return None            # the asset catalog is replaced by loose PNGs
    if tool == 'metal-tt':
        return None            # not shipped by Apple's Windows Metal tools
    if tool in TOOL_MAP:
        return tc.llvm_tool(TOOL_MAP[tool])
    return tc.llvm_tool(tool)


def _die(msg: str, code: int = 127) -> None:
    print(f'xcrun (Windows): {msg}', file=sys.stderr)
    raise SystemExit(code)


def _needs_staging(arg: str) -> bool:
    """Whether `arg` contains spaces or non-ASCII characters that break `metal.exe` / `metallib.exe`."""
    return ' ' in arg or not arg.isascii()


def _safe_suffix(p: Path, default: str) -> str:
    name = p.name
    for ext in ('.metallib', '.air', '.pch', '.metal', '.dia', '.h'):
        if name.endswith(ext) or f'{ext}.' in name:
            return ext
    sfx = p.suffix
    return sfx if (sfx and not _needs_staging(sfx)) else default


def _run_metal_staged(sdk: str, tool: str, exe: Path, rest: list[str]) -> int:
    """Run `metal.exe` or `metallib.exe` in a pure-ASCII, space-free staging directory.

    Apple's Windows `metal.exe` and `metallib.exe` split input paths on spaces when forwarding
    them to their internal frontend and fail with `LLVM ERROR: Error opening '<path>'` when any
    input or output path contains non-ASCII characters (such as Chinese folder names). Staging
    inputs and outputs in a pure-ASCII `cwd` with plain filenames (`in_0.metal`, `out.air`,
    `out.metallib`) keeps every argument passed to `metal.exe` and `metallib.exe` completely
    ASCII and space-free.
    """
    idx = rest.index('-o')
    out_target = Path(rest[idx + 1]).resolve()
    compile_and_link = (tool == 'metal' and '-c' not in rest)
    with tc.ascii_temp_dir('nspb-metal-') as td:
        td_path = Path(td)
        staged: list[str] = []
        in_idx = 0
        i = 0
        while i < len(rest):
            if i == idx:
                i += 2  # skip '-o' and its output path; added back below with a local name
                continue
            a = rest[i]
            if a == '-include-pch' and i + 1 < len(rest):
                pch_arg = rest[i + 1]
                pch_p = Path(pch_arg)
                if not _needs_staging(pch_arg) and pch_p.is_absolute():
                    staged.extend(['-include-pch', pch_arg])
                else:
                    local_pch = pch_p.name if not _needs_staging(pch_p.name) else f'in_{in_idx}.pch'
                    in_idx += 1
                    if pch_p.is_file():
                        shutil.copyfile(pch_p, td_path / local_pch)
                        for hdr in pch_p.parent.glob('*.h'):
                            if not _needs_staging(hdr.name):
                                shutil.copyfile(hdr, td_path / hdr.name)
                    staged.extend(['-include-pch', local_pch])
                i += 2
                continue
            if not a.startswith('-') and (a.endswith(('.metal', '.air', '.dia', '.pch', '.h'))
                                          or (_needs_staging(a) and Path(a).is_file())):
                src_p = Path(a)
                if src_p.suffix == '.h' and not _needs_staging(src_p.name) and not (td_path / src_p.name).exists():
                    local_name = src_p.name
                else:
                    local_name = f'in_{in_idx}{_safe_suffix(src_p, ".in")}'
                in_idx += 1
                if src_p.is_file():
                    shutil.copyfile(src_p, td_path / local_name)
                staged.append(local_name)
            else:
                staged.append(a)
            i += 1
        try:
            if compile_and_link and out_target.suffix == '.metallib':
                ml_exe = find(sdk, 'metallib')
                if not ml_exe:
                    _die(f'no Windows tool for `xcrun -sdk {sdk} metallib`')
                r1 = subprocess.run([str(exe), *staged, '-c', '-o', 'out.air'], cwd=td)
                if r1.returncode != 0:
                    return r1.returncode
                r2 = subprocess.run([str(ml_exe), 'out.air', '-o', 'out.metallib'], cwd=td)
                if r2.returncode != 0:
                    return r2.returncode
                out_local = td_path / 'out.metallib'
            else:
                local_out_name = 'out' + _safe_suffix(out_target, '.out')
                r = subprocess.run([str(exe), *staged, '-o', local_out_name], cwd=td)
                if r.returncode != 0:
                    return r.returncode
                out_local = td_path / local_out_name
            if out_local.is_file():
                out_target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(out_local, out_target)
            return 0
        except OSError as e:
            _die(f'cannot start {exe}: {e}')


def main(argv: list[str] | None = None) -> int:
    sdk = 'macosx'
    a = list(sys.argv[1:] if argv is None else argv)
    while a and a[0].startswith('-'):
        if a[0] in ('-sdk', '--sdk') and len(a) > 1:
            sdk = a[1]
            a = a[2:]
        elif a[0] in ('--show-sdk-version', '--show-sdk-build-version', '--show-sdk-path'):
            print(_sdk_info(sdk, a[0]))
            return 0
        elif a[0] in ('-r', '--run'):
            a = a[1:]
        elif a[0] in ('-f', '--find'):
            if len(a) < 2:
                _die('-f needs a tool name')
            t = find(sdk, a[1])
            print(t or '')
            return 0 if t else 1
        elif a[0] == '--version':
            print('xcrun (nspb Windows shim)')
            return 0
        else:
            _die('unsupported option ' + a[0])
    if not a:
        _die('no tool named')
    tool, rest = a[0], a[1:]
    exe = find(sdk, tool)
    if not exe:
        _die(f'no Windows tool for `xcrun -sdk {sdk} {tool}`'
             + (' (the Windows Metal tools do not ship metal-tt)' if tool == 'metal-tt' else
                ' (the app is built with clang + ld64.lld, not Swift or actool)'
                if tool in ('swiftc', 'actool') else
                ' (see the Windows build section of frontend-qt/README.md)'))
    if tool == 'metal':
        rest = metal_args(sdk, rest)
        if '-o' in rest and ('-c' not in rest or any(_needs_staging(x) for x in rest)):
            return _run_metal_staged(sdk, tool, exe, rest)
    elif tool == 'metallib':
        if '-o' in rest and any(_needs_staging(x) for x in rest):
            return _run_metal_staged(sdk, tool, exe, rest)
    elif tool == 'clang':
        rest = clang_args(rest)
    try:
        return subprocess.run([str(exe)] + rest).returncode
    except OSError as e:
        _die(f'cannot start {exe}: {e}')


if __name__ == '__main__':
    raise SystemExit(main())
