"""`python -m nspb_qt.win.doctor`: what the Windows build needs, and what is missing.

The app shows the same information in its Dependencies panel (`toolchain.check_all`); this
module is the command-line form, for a user who wants to check a machine before opening the GUI,
or to paste the result into a bug report.

Exit code 0 means every required component is present and its probe passed.

    python -m nspb_qt.win.doctor            # human-readable
    python -m nspb_qt.win.doctor --json     # machine-readable
    python -m nspb_qt.win.doctor --fix      # download the pinned LLVM-MinGW when it is missing
    python -m nspb_qt.win.doctor --sdk      # download the iPhoneOS SDK (git route)
    python -m nspb_qt.win.doctor --sdk-xip Xcode.xip
    python -m nspb_qt.win.doctor --import-sdk D:\\SDKs\\iPhoneOS26.0.sdk
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

if __package__:
    from . import fetch, sdk_fetch, shim
    from . import toolchain as tc
else:                                       # pragma: no cover - script mode
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
    from nspb_qt.win import fetch, sdk_fetch, shim
    from nspb_qt.win import toolchain as tc

MARK = {'ok': 'ok ', 'missing': 'MISSING', 'wrong': 'WRONG'}


def print_report(probes: list, as_json: bool) -> int:
    if as_json:
        print(json.dumps([{
            'id': p.id, 'name': p.name, 'state': p.state, 'detail': p.detail,
            'hint': p.hint, 'path': p.path, 'version': p.version, 'pinned': p.pinned,
            'required': p.required,
        } for p in probes], indent=1))
    else:
        width = max((len(p.name) for p in probes), default=20)
        for p in probes:
            mark = MARK.get(p.state, p.state) if p.required else \
                ('ok  ' if p.ok else 'n/a ')
            line = f'[{mark}] {p.name.ljust(width)}  {p.detail}'
            if p.version:
                line += f'  (have {p.version}, pinned {p.pinned})' if p.pinned else f'  ({p.version})'
            print(line)
            if not p.ok and p.hint:
                print(f'{"":9}{"":{width}}  → {p.hint}')
        bad = [p for p in probes if p.required and not p.ok]
        print()
        if bad:
            print(f'{len(bad)} required item(s) missing or unusable: '
                  + ', '.join(p.name for p in bad))
        else:
            print('everything a Windows build needs is present')
    return 0 if not [p for p in probes if p.required and not p.ok] else 1


def log(msg: str) -> None:
    print(msg, flush=True)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog='python -m nspb_qt.win.doctor',
                                 description='Check (and optionally fetch) the Windows build '
                                             'toolchain.')
    ap.add_argument('--json', action='store_true', help='machine-readable output')
    ap.add_argument('--no-probe', action='store_true',
                    help='skip the compile / link / Metal probes (faster, less conclusive)')
    ap.add_argument('--fix', action='store_true', help='download LLVM-MinGW when it is missing')
    ap.add_argument('--sdk', action='store_true', help='download the pinned iPhoneOS SDK (git)')
    ap.add_argument('--sdk-xip', metavar='XCODE_XIP', help='extract the SDK from an Xcode .xip')
    ap.add_argument('--import-sdk', metavar='FOLDER', help='use an iPhoneOS SDK you already have')
    a = ap.parse_args(sys.argv[1:] if argv is None else argv)

    if os.name != 'nt' and not os.environ.get('NSPB_ALLOW_NON_WINDOWS'):
        print('nspb_qt.win.doctor checks the Windows toolchain; on macOS the build uses Xcode. '
              '(Set NSPB_ALLOW_NON_WINDOWS=1 to run it anyway for testing.)', file=sys.stderr)
        return 2

    did = False
    if a.fix:
        try:
            fetch.install_llvm(log=log)
            did = True
        except fetch.DownloadError as e:
            print(f'cannot install LLVM-MinGW: {e}', file=sys.stderr)
    if a.sdk:
        try:
            sdk_fetch.install_sdk(log=log)
            did = True
        except sdk_fetch.SdkError as e:
            print(f'cannot download the SDK: {e}', file=sys.stderr)
    if a.sdk_xip:
        try:
            sdk_fetch.extract_xip(Path(a.sdk_xip), log=log)
            did = True
        except sdk_fetch.SdkError as e:
            print(f'cannot extract {a.sdk_xip}: {e}', file=sys.stderr)
    if a.import_sdk:
        try:
            sdk_fetch.import_local(Path(a.import_sdk), log=log)
            did = True
        except sdk_fetch.SdkError as e:
            print(f'cannot import {a.import_sdk}: {e}', file=sys.stderr)

    if did and not a.json:
        print()

    # The probes run the real compilers, so they need the toolchain folders on PATH and the
    # env variables toolchain.py reads; building the same environment the app builds keeps
    # this report and the app's panel from disagreeing.
    env = shim.build_env()
    saved = {k: os.environ.get(k) for k in env}
    os.environ.update(env)
    try:
        probes = tc.check_all(deep=not a.no_probe)
    finally:
        for k, v in saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v

    code = print_report(probes, a.json)
    if not a.json:
        # what to do next, without repeating every row
        hints = []
        if not tc.llvm_dir():
            hints.append('install LLVM-MinGW: python -m nspb_qt.win.doctor --fix')
        if not tc.llvm_tool('ld64.lld') or not tc.ld64_lld():
            hints.append('the Mach-O linker is missing: it comes from ld.lld.exe, created '
                         'automatically once LLVM is in place')
        if not tc.ios_sdk():
            hints.append('get an iPhoneOS SDK: python -m nspb_qt.win.doctor --sdk '
                         '(or --sdk-xip Xcode.xip)')
        if not (tc.metal_tool('metal') and tc.metal_tool('metallib')):
            hints.append(fetch.metal_tools_hint())
        for h in hints:
            print(f'- {h}')
    return code


if __name__ == '__main__':
    raise SystemExit(main())
