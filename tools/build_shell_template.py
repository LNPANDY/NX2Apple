#!/usr/bin/env python3
"""Build the unsigned iOS DmShell.app template on macOS for the Windows launcher.

The shared iOS app (`DmShell.app`, exported as `NX2Apple.ipa`) links the SwiftUI
`frontend-ios` package (`ShellUI`, `ShellHost`, `ShellControllers`) and loads each
game's `DmGame<title ID>.framework` at runtime via `dlopen` (`link: false`). Because
the shell executable itself does not link against any game framework, a single
pre-built unsigned `DmShell.app` template can be bundled with the Windows launcher,
which compiles each game's `DmGame<title ID>.framework` locally with LLVM-MinGW
(`clang` + `ld64.lld`) and embeds them into `DmShell.app/Frameworks/`.
"""
from __future__ import annotations

import argparse
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
DEFAULT_OUT = REPO / 'frontend-qt' / 'nspb_qt' / 'win' / 'shell_template' / 'DmShell.app'


def _chain_version(engine: Path) -> str:
    hdr = (engine / 'dm' / 'gfx' / 'nvn' / 'dmsh_chain.h').read_text(encoding='utf-8')
    for line in hdr.splitlines():
        if line.startswith('#define DMSH_CHAIN "'):
            return line.split('"')[1]
    raise SystemExit('no DMSH_CHAIN in dm/gfx/nvn/dmsh_chain.h')


def build_template(out_app: Path, engine: Path | None = None) -> Path:
    engine = (engine or (REPO / 'engine')).resolve()
    ios_src = engine / 'dm' / 'ios'
    pkg_dir = engine / 'frontend-ios'
    if not (pkg_dir / 'Package.swift').is_file():
        pkg_dir = engine.parent / 'frontend-ios'
    if not (pkg_dir / 'Package.swift').is_file():
        pkg_dir = REPO / 'frontend-ios'
    if not (ios_src / 'project-shell.yml').is_file():
        raise SystemExit(f'no {ios_src / "project-shell.yml"}: run `python3 tools/engine.py sync` first')
    if not (pkg_dir / 'Package.swift').is_file():
        raise SystemExit(f'no {pkg_dir / "Package.swift"}')

    chain = _chain_version(engine)
    fork_patches_file = engine / 'dm' / 'fork_patches.txt'
    fork_patches = ''
    if fork_patches_file.is_file():
        fork_patches = ','.join(
            ln.strip() for ln in fork_patches_file.read_text(encoding='utf-8').splitlines() if ln.strip()
        )
    commit = ''
    r_git = subprocess.run(['git', '-C', str(engine), 'rev-parse', '--short=12', 'HEAD'],
                           capture_output=True, text=True)
    if r_git.returncode == 0:
        commit = r_git.stdout.strip()

    with tempfile.TemporaryDirectory(prefix='dmshell_tpl_') as td:
        s = Path(td) / 'project'
        dd = Path(td) / 'dd'
        s.mkdir(parents=True)
        dd.mkdir(parents=True)
        for item in ('Sources', 'Shell', 'tools'):
            os.symlink(ios_src / item, s / item)
        gen = s / 'Gen'
        (gen / 'dm' / 'font').mkdir(parents=True)
        (gen / 'dm.xcconfig').write_text('', encoding='utf-8')
        (gen / 'Assets.xcassets').mkdir(parents=True)
        (gen / 'Assets.xcassets' / 'Contents.json').write_text(
            '{"info":{"author":"xcode","version":1}}\n', encoding='utf-8'
        )
        # Drop `# @FRAMEWORKS@`: the Windows shell exporter embeds each game's framework into
        # `DmShell.app/Frameworks/` when packing `NX2Apple.ipa`.
        tpl_lines = (ios_src / 'project-shell.yml').read_text(encoding='utf-8').splitlines()
        proj_lines = [ln for ln in tpl_lines if not ln.lstrip().startswith('# @FRAMEWORKS@')]
        (s / 'project.yml').write_text('\n'.join(proj_lines) + '\n', encoding='utf-8')

        env = dict(
            os.environ,
            LC_ALL='C',
            DM_SHELL_PACKAGE=str(pkg_dir),
            DM_BUNDLE_ID='org.nxnative.shell',
            DM_TEAM_ID='0000000000',
            DM_SHELL_NAME='NX2Apple',
            DM_APP_VERSION='1.0',
            DM_FORK_PATCHES=fork_patches,
        )
        r_xg = subprocess.run(['xcodegen', 'generate', '-q'], cwd=s, env=env,
                              capture_output=True, text=True)
        if r_xg.returncode != 0:
            raise SystemExit(f'xcodegen failed: {r_xg.stderr or r_xg.stdout}')

        info_p = gen / 'Info.plist'
        info = plistlib.loads(info_p.read_bytes())
        if commit:
            info['DMCommit'] = commit
        info['DMChain'] = chain
        info['DMForkPatches'] = fork_patches
        info_p.write_bytes(plistlib.dumps(info, fmt=plistlib.FMT_XML))

        cmd = [
            'xcodebuild',
            '-project', str(s / 'DmShell.xcodeproj'),
            '-scheme', 'DmShell',
            '-configuration', 'Release',
            '-destination', 'generic/platform=iOS',
            '-derivedDataPath', str(dd),
            'CODE_SIGNING_ALLOWED=NO',
            'CODE_SIGNING_REQUIRED=NO',
            'CODE_SIGN_IDENTITY=',
            'OTHER_LDFLAGS=$(inherited) -Wl,-adhoc_codesign',
            'build',
        ]
        r_xb = subprocess.run(cmd, cwd=s, env=env, capture_output=True, text=True)
        if r_xb.returncode != 0:
            tail = '\n'.join((r_xb.stdout + '\n' + r_xb.stderr).splitlines()[-40:])
            raise SystemExit(f'xcodebuild DmShell failed:\n{tail}')

        built = dd / 'Build' / 'Products' / 'Release-iphoneos' / 'DmShell.app'
        exe = built / 'DmShell'
        if not exe.is_file():
            raise SystemExit(f'no built executable at {exe}')

        # Remove bundle-level signature folders or leftover Frameworks; keep only the executable's
        # LC_CODE_SIGNATURE so Windows `macho_sign.sign` can stamp the entitlements in place.
        shutil.rmtree(built / '_CodeSignature', ignore_errors=True)
        shutil.rmtree(built / 'Frameworks', ignore_errors=True)
        (built / 'embedded.mobileprovision').unlink(missing_ok=True)

        if out_app.exists():
            shutil.rmtree(out_app)
        out_app.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(built, out_app)
    return out_app


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--engine', type=Path, default=None,
                    help='path to the synced engine checkout (default: <repo>/engine)')
    ap.add_argument('--out', type=Path, default=DEFAULT_OUT,
                    help='where to write DmShell.app (default: %(default)s)')
    args = ap.parse_args(argv)
    out = build_template(args.out.resolve(), engine=args.engine)
    print(f'built DmShell.app template: {out}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
