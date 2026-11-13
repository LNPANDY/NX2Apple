#!/bin/bash
# Route C shell (notes/launcher-c-plan.md M2/M3): one iPhone and iPad app for every game the player added. It embeds each game's
# self-contained framework (build_ipa.sh DM_FRAMEWORK_ONLY=<folder>: the game's modules, host, tables, profile, settings list, shader
# libraries, pipeline archive and icon). The game data stays out: the app takes it from Documents/games/<title ID>/ or a picked folder.
# Usage: frontend-ios/Shell/build_shell.sh --prepare-xcode | --build
#   --prepare-xcode  generates the project in SHELL_DIR and stops: Xcode (or xcodebuild with a team and a device, as the Mac launcher
#                    does) signs every framework and the app and installs it, nothing is signed or installed here
#   --build          also builds it for iOS, unsigned (CODE_SIGNING_ALLOWED=NO), to check it compiles and links (CI, off a device)
# Environment:
#   SHELL_DIR            the shell's project folder (required, outside frontend-ios: Gen/, the project, derived data)
#   DM_SHELL_FRAMEWORKS  the games' framework folders, one per line (required, at least one, <folder>/DmGame<title ID>.framework)
#   DM_BUNDLE_ID         the shell's bundle ID (default org.nxnative.shell). Keep it for the life of the install: the same ID installed
#                        over the existing app keeps its Documents (game data, saves) when it is signed again after 7 days
#   DM_TEAM_ID           the signing team for the prepared project (default 0000000000, a placeholder)
#   DM_SHELL_NAME        the name under the icon (default NX2Apple), DM_APP_VERSION the app version (default 1.0)
#   DM_SHELL_PACKAGE     the frontend-ios Swift package (default: the parent folder of this script)
#   DM_ENGINE_DIR        the synced engine root containing dm/ (default: <repo>/engine or <repo> beside frontend-ios)
#   DM_XCODE_DERIVED_DATA  derived data (default SHELL_DIR/dd), FONT_PY / STD_FONT as for build_ipa.sh
#   DM_GAMES_DIR         passed through, for a provisional game profile
#   DM_ENTITLEMENTS      empty: no Increased Memory Limit request in the prepared project (default: requested, as build_ipa.sh does)
set -u
SHELL_ROOT=$(cd "$(dirname "$0")" && pwd) || exit 1
DEFAULT_PKG=$(cd "$SHELL_ROOT/.." && pwd) || exit 1
REPO_ROOT=$(cd "$DEFAULT_PKG/.." && pwd) || exit 1
t() { echo "[$(date +%T)] $*"; }; die() { t "FAIL: $*"; exit 1; }
MODE=${1:-}; case "$MODE" in --prepare-xcode|--build) ;; *) die "usage: $0 --prepare-xcode | --build";; esac
[ -n "${SHELL_DIR:-}" ] || die "SHELL_DIR is not set: the shell's project folder"
[ -n "${DM_SHELL_FRAMEWORKS:-}" ] || die "DM_SHELL_FRAMEWORKS is not set: the games' framework folders, one per line"
mkdir -p "$SHELL_DIR" || die "mkdir $SHELL_DIR"; S=$(cd "$SHELL_DIR" && pwd)
[ -n "${DM_SHELL_PACKAGE:-}" ] || DM_SHELL_PACKAGE=$DEFAULT_PKG
export DM_SHELL_PACKAGE
[ -f "$DM_SHELL_PACKAGE/Package.swift" ] || die "no Swift package at $DM_SHELL_PACKAGE (DM_SHELL_PACKAGE)"
[ "$S" != "$SHELL_ROOT" ] && [ "$S" != "$DM_SHELL_PACKAGE" ] || die "the shell project must be outside frontend-ios"

ENGINE_ROOT=${DM_ENGINE_DIR:-}
if [ -n "$ENGINE_ROOT" ]; then
  [ -d "$ENGINE_ROOT/engine/dm" ] && ENGINE_ROOT=$ENGINE_ROOT/engine
elif [ -d "$REPO_ROOT/engine/dm" ]; then
  ENGINE_ROOT=$REPO_ROOT/engine
else
  ENGINE_ROOT=$REPO_ROOT
fi
[ -d "$ENGINE_ROOT/dm" ] || die "no engine dm/ folder at $ENGINE_ROOT (set DM_ENGINE_DIR or run python3 tools/engine.py sync)"
DM=$(cd "$ENGINE_ROOT/dm" && pwd)

export LC_ALL=C DM_BUNDLE_ID=${DM_BUNDLE_ID:-org.nxnative.shell} DM_TEAM_ID=${DM_TEAM_ID:-0000000000} DM_SHELL_NAME=${DM_SHELL_NAME:-NX2Apple} DM_APP_VERSION=${DM_APP_VERSION:-1.0}
export DM_FORK_PATCHES=$(paste -sd, "$DM/fork_patches.txt" 2>/dev/null || true)
DD=${DM_XCODE_DERIVED_DATA:-$S/dd}; mkdir -p "$DD" && DD=$(cd "$DD" && pwd)
V=$(sed -n 's/^#define DMSH_CHAIN "\(.*\)"/\1/p' "$DM/gfx/nvn/dmsh_chain.h"); [ -n "$V" ] || die "no DMSH_CHAIN in dm/gfx/nvn/dmsh_chain.h"

# Every framework: a manifest with its own host (loader FH), its executable, a title ID of its own
FWLIST=$S/frameworks.txt
python3 -I - "$FWLIST" <<'PY' || die "the frameworks in DM_SHELL_FRAMEWORKS (above)"
import json, os, sys
out = sys.argv[1]
paths = [p.strip() for p in os.environ['DM_SHELL_FRAMEWORKS'].splitlines() if p.strip()]
if not paths: sys.exit('[RED] no framework named')
seen, rows = {}, []
for p in paths:
    p = os.path.abspath(p)
    try: m = json.load(open(os.path.join(p, 'game.manifest.json'), encoding='utf-8'))
    except (OSError, ValueError) as e: sys.exit(f'[RED] {p}: no readable game.manifest.json ({e})')
    name, exe, tid = m.get('framework'), m.get('framework_executable'), m.get('title_id', '')
    if os.path.basename(p) != name: sys.exit(f'[RED] {p}: the manifest names {name}')
    if not os.path.isfile(os.path.join(p, exe or '-')): sys.exit(f'[RED] {p}: no executable {exe} (build_ipa.sh DM_FRAMEWORK_ONLY builds it)')
    if m.get('loader') != 'FH': sys.exit(f'[RED] {p}: built without a host in the framework (loader {m.get("loader")!r}). Rebuild this game for the shared app.')
    if tid in seen: sys.exit(f'[RED] {p}: title ID {tid} is already in the shell ({seen[tid]})')
    seen[tid] = p; rows.append((tid, p, m.get('name', '')))
with open(out, 'w', encoding='utf-8') as f:
    for tid, p, name in rows: f.write(f'{tid}\t{p}\t{name}\n')
PY
export GAME=$(head -1 "$FWLIST" | cut -f1)
t "shell: $DM_SHELL_NAME ($DM_BUNDLE_ID), games: $(cut -f3 "$FWLIST" | paste -sd, -)"

t "generate Gen/ (shared files, the project)"
rm -f "$S/Sources" "$S/tools"
ln -sfn "$SHELL_ROOT/App" "$S/Shell" || die "link Shell"
cd "$S" || die "cd $S"
rm -rf Gen && mkdir -p Gen/dm/font || die "mkdir Gen"
: > Gen/dm.xcconfig || die "dm.xcconfig"
cp "${STD_FONT:-/System/Library/Fonts/Supplemental/Arial Unicode.ttf}" Gen/dm/font/standard.ttf || die "copy standard font (STD_FONT=a TTF)"
"${FONT_PY:-python3}" "$DM/tools/make_ext_font.py" Gen/dm/font/nintendo_ext.ttf > /dev/null || die "make_ext_font.py (pip install fonttools, or FONT_PY=python with fontTools)"
mkdir -p Gen/Assets.xcassets && printf '{"info":{"author":"xcode","version":1}}\n' > Gen/Assets.xcassets/Contents.json || die "asset catalog"
# The shell asks for the Increased Memory Limit capability, as the one-game app does; a framework cannot hold entitlements
printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
  '<plist version="1.0"><dict><key>com.apple.developer.kernel.increased-memory-limit</key><true/></dict></plist>' > Gen/DmShell.entitlements || die "entitlements"
# DM_ENTITLEMENTS= (empty) leaves the request out, for a team whose profiles cannot carry the capability yet (the game may then run
# out of memory on the device)
if [ "$MODE" = --prepare-xcode ] && [ -n "${DM_ENTITLEMENTS-default}" ]; then echo "CODE_SIGN_ENTITLEMENTS = Gen/DmShell.entitlements" >> Gen/dm.xcconfig
elif [ "$MODE" = --prepare-xcode ]; then t "entitlements: none (DM_ENTITLEMENTS is empty): no Increased Memory Limit"; fi
# The template with one embedded, unlinked framework per game where it says @FRAMEWORKS@
python3 -I - "$SHELL_ROOT/project-shell.yml" "$FWLIST" project.yml <<'PY' || die "project.yml"
import os, sys
template, fwlist, out = sys.argv[1:]
lines, done = [], False
for line in open(template, encoding='utf-8').read().splitlines():
    if line.lstrip().startswith('# @FRAMEWORKS@'):
        pad = line[:len(line) - len(line.lstrip())]
        for row in open(fwlist, encoding='utf-8').read().splitlines():
            path = row.split('\t')[1]
            lines += [f'{pad}- framework: "{path}"', f'{pad}  embed: true', f'{pad}  link: false', f'{pad}  codeSign: true']
        done = True
        continue
    if line.lstrip().startswith('CFBundleLocalizations:'):
        pad = line[:len(line) - len(line.lstrip())]
        xc = os.path.join(os.environ.get('DM_SHELL_PACKAGE', ''), 'Sources/ShellUI/Resources/Localizable.xcstrings')
        if os.path.isfile(xc):
            import json as _j
            _d = _j.load(open(xc, encoding='utf-8')).get('strings', {})
            _locs = sorted({k for v in _d.values() for k in v.get('localizations', {}) if k != 'en'})
            if _locs:
                lines.append(f'{pad}CFBundleLocalizations: [' + ', '.join(['en', *_locs]) + ']')
                continue
    lines.append(line)
if not done: sys.exit('[RED] project-shell.yml has no @FRAMEWORKS@ line')
open(out, 'w', encoding='utf-8').write('\n'.join(lines) + '\n')
PY
xcodegen generate -q > /dev/null || die "xcodegen"
COMMIT=$(git -C "$DM" rev-parse --short=12 HEAD 2> /dev/null) && { [ -z "$(git -C "$DM" status --porcelain --untracked-files=no 2> /dev/null)" ] || COMMIT=$COMMIT+dirty
  /usr/libexec/PlistBuddy -c "Add :DMCommit string $COMMIT" Gen/Info.plist > /dev/null || die "DMCommit"; t "source: $COMMIT"; }
/usr/libexec/PlistBuddy -c "Add :DMChain string $V" Gen/Info.plist > /dev/null || die "DMChain"
/usr/libexec/PlistBuddy -c "Add :DMForkPatches string $DM_FORK_PATCHES" Gen/Info.plist > /dev/null || die "DMForkPatches"
if [ "$MODE" = --prepare-xcode ]; then
  t "Xcode project: $S/DmShell.xcodeproj (scheme DmShell)"
  t "Xcode derived data: $DD"
  t "ready: select your Team in Signing & Capabilities and a physical device, then Run (Release); or xcodebuild -scheme DmShell -destination id=<device> DEVELOPMENT_TEAM=<team> -allowProvisioningUpdates"
  exit 0
fi

t "xcodebuild (Release, unsigned, iPhone + iPad)"
xcodebuild -project DmShell.xcodeproj -scheme DmShell -configuration Release -destination 'generic/platform=iOS' -derivedDataPath "$DD" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= build > "$S/build.log" 2>&1 \
  || { grep -E 'error:' "$S/build.log" | head -20; die "xcodebuild, log $S/build.log"; }
APP=$DD/Build/Products/Release-iphoneos/DmShell.app
[ -x "$APP/DmShell" ] || die "no built app at $APP"
while IFS=$'\t' read -r tid path name; do
  fw=$APP/Frameworks/$(basename "$path"); [ -d "$fw" ] || die "the app does not embed $(basename "$path")"
done < "$FWLIST"
t "done: $APP ($(du -sh "$APP" | cut -f1)), unsigned"
