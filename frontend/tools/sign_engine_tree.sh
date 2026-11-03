#!/bin/bash
# Signs the engine tree inside the launcher bundle without changing the files the shader chain pins, and checks that it did not.
#
# The release used to re-sign every Mach-O file of Contents/Resources/engine (codesign --force --sign -). codesign rewrites the signature inside
# the file, and dm/gfx/tools/dmsh_chain.lock pins spirv-cross by the SHA-256 of its bytes (tool_lock.py), so every shader build from the bundled
# engine stopped with "translation chain tools do not match the lock file: spirv-cross" (own_compilers.py exit code 1). The upstream binaries
# already carry a signature (spirv-cross the linker's ad-hoc one, the translator's apphost an ad-hoc one), which Apple silicon runs as it is.
# So a Mach-O file is signed here only when it has no signature at all, and every other file stays byte for byte the one the zip asset holds.
#
# Usage: sign_engine_tree.sh <engine folder in the bundle> <engine tree it was copied from>           sign what has no signature, then check
#        sign_engine_tree.sh --check <engine folder in the bundle> <engine tree it was copied from>   only check
set -uo pipefail
CHECK_ONLY=0
if [ "${1:-}" = --check ]; then CHECK_ONLY=1; shift; fi
E=${1:?usage: sign_engine_tree.sh [--check] <engine folder> <engine tree>}
TREE=${2:?usage: sign_engine_tree.sh [--check] <engine folder> <engine tree>}
fail=0
ok()  { echo "ok    $*"; }
bad() { echo "FAIL  $*"; fail=1; }
sha16() { shasum -a 256 "$1" | cut -c1-16; }

if [ "$CHECK_ONLY" = 0 ]; then
    while IFS= read -r -d '' f; do
        file -b "$f" | grep -q 'Mach-O' || continue
        if codesign -d --arch arm64 "$f" > /dev/null 2>&1; then continue; fi   # already signed (ad-hoc or by the linker): left as it is
        codesign --force --sign - "$f" 2> /dev/null && echo "signed ${f#"$E"/} (it had no signature)" || bad "could not sign ${f#"$E"/}"
    done < <(find "$E" -type f -perm -u+x -print0)
fi

# every file of the tree is in the bundle, unchanged, unless it had no signature and was signed above (then it has to verify)
changed=0
while IFS= read -r -d '' rel; do
    rel=${rel#./}
    if [ ! -f "$E/$rel" ]; then bad "missing from the bundle: $rel"; continue; fi
    cmp -s "$TREE/$rel" "$E/$rel" && continue
    if file -b "$E/$rel" | grep -q 'Mach-O' && ! codesign -d --arch arm64 "$TREE/$rel" > /dev/null 2>&1 && codesign -v "$E/$rel" 2> /dev/null; then
        changed=$((changed + 1))
    else
        bad "changed in the bundle: $rel"
    fi
done < <(cd "$TREE" && find . -type f -print0)
[ "$fail" = 0 ] && ok "the engine files are the tree's ($changed signed because they had no signature)"

# the tools the lock pins by their bytes: spirv-cross (tool_lock.py reads the same lines)
LOCK="$E/dm/gfx/tools/dmsh_chain.lock"
want=$(awk -F'\t' '$1 == "spirv-cross" { print $2 }' "$LOCK" 2> /dev/null)
have=$(sha16 "$E/dm/gfx/tools/spirv_cross_bin/spirv-cross" 2> /dev/null)
if [ -n "$want" ] && [ "$want" = "$have" ]; then ok "spirv-cross matches dmsh_chain.lock ($have)"; else bad "spirv-cross is $have, dmsh_chain.lock says ${want:-nothing}"; fi
codesign -d --arch arm64 "$E/dm/gfx/tools/spirv_cross_bin/spirv-cross" > /dev/null 2>&1 && ok "spirv-cross carries a signature" || bad "spirv-cross has no signature"

exit "$fail"
