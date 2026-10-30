#!/usr/bin/env python3
"""Write the game.manifest.json that travels inside a route C game framework (docs/launcher-c-plan.md, "Manifest").

build_ipa.sh's DM_FRAMEWORK=1 mode calls this before xcodegen, so the file is a resource of the DmGame framework:
<framework>/game.manifest.json. M1 builds one game per app and does not read it yet; M2's shell discovers the framework
through it and M3 validates several (schema, title ID, chain against the shell's DMSH_CHAIN, CFBundleExecutable) and
cross-checks the sections it names. Writing it now keeps the schema honest, and test_framework_build.py checks it.

Usage:
  gen_manifest.py <out.json> --game <title ID> --name <name> --display-version <v> --package-version <pkg>
                  --modules "main sdk" [--nro-table <nro.tsv>] --chain b-<hex> --romfs-marker <path>
                  [--romfs-identity "DMROMFSID1 ..."] [--min-os 26.0]
Exit status 1 on a value the schema cannot carry (a bad title ID, no module, a chain not written b-<hex>).
"""
import argparse
import json
import re
import sys
from pathlib import Path

SCHEMA = 1
# The M1 framework's fixed names, the same constants project-framework.yml and FrameworkBootstrap.h use
FRAMEWORK = 'DmGame.framework'
FRAMEWORK_EXECUTABLE = 'DmGame'
IMAGE_MARKER = 'dmgame_image_marker'
PROFILE = 'profile.tsv'          # the framework's root: main.m points DM_PROFILE at it
SHADER_MAP = 'dm/shader_map.tsv'  # inside the framework: main.m points DM_NVN_SHMAP at it
LAUNCHER = 'dm/launcher.json'     # the loader's tables and the launcher settings share the framework's dm/
TITLE_ID = re.compile(r'^[0-9A-F]{16}$')
CHAIN = re.compile(r'^b-[0-9A-Za-z._-]+$')


def nro_count(table):
    """Rows gen_embed.py embeds: everything but comments, blank lines and the 'refused' ones (an online SDK the host never
    loads, dm/tools/nro_collect.py). The same filter gen_embed.py applies when it packs the NRO pieces."""
    if table is None:
        return 0
    rows = (line.split('\t')[0] for line in Path(table).read_text(encoding='utf-8').splitlines())
    return sum(1 for name in rows if name and not name.startswith('#') and name != 'refused')


def manifest(args):
    """The schema's keys in its order; optional ones only when a value is given."""
    title_id = args.game.upper()
    modules = args.modules.split()
    if not TITLE_ID.match(title_id):
        raise SystemExit(f'[RED] gen_manifest: --game {args.game!r} is not a 16-digit hex title ID')
    if not modules or any(not re.match(r'^[A-Za-z0-9]+$', m) for m in modules):
        raise SystemExit(f'[RED] gen_manifest: --modules {args.modules!r} names no module or a module with an underscore '
                         '(the loader\'s embedded section names cannot hold one)')
    if not CHAIN.match(args.chain):
        raise SystemExit(f'[RED] gen_manifest: --chain {args.chain!r} is not written b-<version> (dm/gfx/nvn/dmsh_chain.h)')
    if args.romfs_identity and not args.romfs_identity.startswith('DMROMFSID1 '):
        raise SystemExit('[RED] gen_manifest: --romfs-identity is not a romfs_image.py identity line (DMROMFSID1 ...)')
    data = {
        'schema': SCHEMA,
        'title_id': title_id,
        'name': args.name,
        'display_version': args.display_version,
        'package_version': args.package_version,
        'modules': modules,
        'nro_count': nro_count(args.nro_table),
        'chain': args.chain,
        'loader': 'FR',                # a pure module container: the shell is the host (design §1.1 FR)
        'framework': FRAMEWORK,
        'framework_executable': FRAMEWORK_EXECUTABLE,
        'image_marker': IMAGE_MARKER,
        'profile': PROFILE,
        'shader_map': SHADER_MAP,
        'launcher': LAUNCHER,
        'romfs_marker': args.romfs_marker,
        'romfs_identity': args.romfs_identity or '',
        'min_os': args.min_os,
    }
    if args.built_by:
        data['built_by'] = args.built_by
    return data


def main(argv=None):
    ap = argparse.ArgumentParser(description='Write a route C game framework\'s game.manifest.json.')
    ap.add_argument('out', help='the file to write (<Gen>/framework/game.manifest.json)')
    ap.add_argument('--game', required=True, help='the base game title ID (16 hex digits)')
    ap.add_argument('--name', required=True, help='the game name (control.nacp, as build_ipa.sh reads it)')
    ap.add_argument('--display-version', required=True, help='the packed version\'s display version')
    ap.add_argument('--package-version', required=True, help='the packed package version (the profile\'s package key)')
    ap.add_argument('--modules', required=True, help='the game\'s modules, space separated (the profile\'s modules)')
    ap.add_argument('--nro-table', help='the rewriter\'s nro.tsv, for nro_count; without it the count is 0')
    ap.add_argument('--chain', required=True, help='the shader chain version, b-<version> (dm/gfx/nvn/dmsh_chain.h)')
    ap.add_argument('--romfs-marker', required=True, help='the profile\'s romfs_marker: a folder with it is this game\'s data')
    ap.add_argument('--romfs-identity', default='', help='the RomFS image identity line build_ipa.sh writes (empty for a folder)')
    ap.add_argument('--min-os', default='26.0', help='the minimum iOS version (project.yml\'s deployment target)')
    ap.add_argument('--built-by', help='who built it, for a log line (optional; a device or tool name)')
    args = ap.parse_args(argv)
    data = manifest(args)
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    # Indented and in the schema's order, so a diff between two builds is one line per changed value
    out.write_text(json.dumps(data, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')
    print(out)
    return data


if __name__ == '__main__':
    main()
