#!/bin/bash
# Checks an assembled launcher bundle the way a player's Mac uses it: every bundled tool starts from the bundle with a clean PATH (nothing of
# Homebrew or the system Python), nothing links into /opt/homebrew or /usr/local, and the code signature holds.
# Usage: check_bundle.sh <NX2Apple.app or a folder that holds tools/ and python/> [--sign]   (--sign: also ad-hoc sign the app and verify it)
set -uo pipefail
APP=${1:?usage: check_bundle.sh <app> [--sign]}
if [ -d "$APP/Contents/Resources" ]; then RES="$APP/Contents/Resources"; else RES="$APP"; fi
fail=0
ok()  { echo "ok    $*"; }
bad() { echo "FAIL  $*"; fail=1; }
clean() { env -i PATH=/usr/bin:/bin HOME="${TMPDIR:-/tmp}" "$@"; }   # no PATH entry but the system's, and the tool by its full path

T="$RES/tools/bin"
v=$(clean "$T/zstd" --version 2>&1) && ok "zstd: $v" || bad "zstd --version: $v"
v=$(clean "$T/glslangValidator" --version 2>&1 | head -2 | tr '\n' ' ') && [ -n "$v" ] && ok "glslangValidator: $v" || bad "glslangValidator --version"
v=$(clean "$T/spirv-cross" --help 2>&1); echo "$v" | grep -qi 'usage' && ok "spirv-cross --help: $(echo "$v" | grep -i usage | head -1)" || bad "spirv-cross --help: $v"
v=$(clean "$T/xcodegen" --version 2>&1) && ok "xcodegen: $v" || bad "xcodegen --version: $v"
# the tools by name, from a PATH that has only the bundle and the system (what the launcher passes)
for t in zstd glslangValidator spirv-cross xcodegen; do
    p=$(env -i PATH="$T:/usr/bin:/bin" /usr/bin/which "$t") && [ "$p" = "$T/$t" ] && ok "PATH finds $t in the bundle" || bad "PATH finds $t at '$p'"
done
PY="$RES/python/bin/python3"
v=$(clean "$PY" -I -c "import sys, lz4.block, capstone, fontTools, zbic, nsz; from compression import zstd" 2>&1 \
    || clean "$PY" -I -c "import lz4.block, capstone, fontTools, zbic, nsz; from backports import zstd" 2>&1) && ok "python imports lz4, capstone, fontTools, zbic, nsz, zstd" || bad "python imports: $v"
v=$(clean "$PY" -I -c "import sys; print(sys.version.split()[0], sys.prefix)" 2>&1); echo "$v" | grep -q "$RES/python" && ok "python runs from the bundle: $v" || bad "python prefix is not the bundle: $v"

# load paths: only the system's (a library's or extension's own install name is not a dependency)
links=0
while IFS= read -r -d '' f; do
    file -b "$f" | grep -q 'Mach-O' || continue
    out=$(otool -L "$f" 2>/dev/null | tail -n +2 | awk '{print $1}' | grep -v -x -F "$f" | grep -v -e '^/usr/lib/' -e '^/System/Library/' -e '^@rpath/' -e '^@loader_path/' -e '^@executable_path/') || true
    [ -z "$out" ] || { bad "${f#$RES/} links: $(echo "$out" | tr '\n' ' ')"; links=1; }
    min=$(otool -l "$f" 2>/dev/null | awk '/minos/{print $2; exit}')
    [ -z "$min" ] || [ "$(printf '%s\n13.0\n' "$min" | sort -V | tail -1)" = 13.0 ] || { bad "${f#$RES/} needs macOS $min (the app runs from 13.0)"; links=1; }
    otool -L "$f" 2>/dev/null | grep -q -e '/opt/homebrew' -e '/usr/local' && { bad "${f#$RES/} links into Homebrew"; links=1; }
done < <(find "$RES/tools" "$RES/python" -type f -print0)
[ "$links" = 0 ] && ok "no Mach-O file links outside the system or the bundle, and none needs macOS later than 13.0"

if [ "${2:-}" = "--sign" ] && [ -d "$APP/Contents" ]; then
    codesign --force --deep --sign - "$APP" 2>&1 | tail -3
    codesign -v --deep --strict "$APP" 2>&1 && ok "codesign -v --deep --strict" || bad "codesign -v --deep --strict"
fi
exit $fail
