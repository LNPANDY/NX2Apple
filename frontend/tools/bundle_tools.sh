#!/bin/bash
# Fills the launcher bundle's Resources folder with the build tools and a Python, so a player installs neither Homebrew nor Python:
#
#   <Resources>/tools/bin        zstd, glslangValidator, spirv-cross, xcodegen
#   <Resources>/tools/share      xcodegen's SettingPresets (it looks for them beside its bin folder)
#   <Resources>/tools/licenses   the license files of all of them
#   <Resources>/python           CPython (python-build-standalone, relocatable) with the packages the build scripts import
#
# Usage: bundle_tools.sh <Resources folder> [work folder]   (the work folder keeps the downloads and the builds; default: a temporary one)
#
# Why not Homebrew's bottles: a bottle is built for the macOS it is poured on (the bottles of 2026 say minos 15 or later, and this app runs
# from macOS 13), and it links its siblings from /opt/homebrew (zstd: libzstd, liblzma, liblz4; glslang: libglslang, SPIRV-Tools). The tools
# are built here from pinned, checksummed source with MACOSX_DEPLOYMENT_TARGET=13.0 and static libraries, so each is one file that links
# only /usr/lib/libSystem and libc++ (otool -L; check_bundle.sh verifies it). xcodegen is the project's own release zip (Swift on the
# system's libswift*), checked against its pinned sha256.
#
# Raising a pin: change the version and its sha256 below (the checksum of the release tarball), run this, then check_bundle.sh.
set -euo pipefail

ZSTD_VERSION=1.5.7
ZSTD_SHA256=37d7284556b20954e56e1ca85b80226768902e2edabd3b649e9e72c0c9012ee3
ZSTD_URL=https://github.com/facebook/zstd/archive/refs/tags/v$ZSTD_VERSION.tar.gz

GLSLANG_VERSION=16.6.0
GLSLANG_SHA256=9c09b901149c729df745057dafa815278aaa101b84d2b6e14f16a42de52f97f2
GLSLANG_URL=https://github.com/KhronosGroup/glslang/archive/refs/tags/$GLSLANG_VERSION.tar.gz

SPIRV_CROSS_TAG=vulkan-sdk-1.4.363.0   # the release the repo's own dm/gfx/tools/spirv_cross_bin/build.sh builds
SPIRV_CROSS_SHA256=f708982e88b763ef5b0394ed468fc2c3628f68cdab89f2e7a946cd628c04e721
SPIRV_CROSS_URL=https://github.com/KhronosGroup/SPIRV-Cross/archive/refs/tags/$SPIRV_CROSS_TAG.tar.gz

XCODEGEN_VERSION=2.46.0
XCODEGEN_SHA256=4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806
XCODEGEN_URL=https://github.com/yonaskolb/XcodeGen/releases/download/$XCODEGEN_VERSION/xcodegen.zip

PYTHON_VERSION=3.13.18
PYTHON_RELEASE=20261026
PYTHON_SHA256=e5af2fde6a937a0e0c795a0c595c4efb70578d57463a2657c819992b9b9acbac
PYTHON_URL=https://github.com/astral-sh/python-build-standalone/releases/download/$PYTHON_RELEASE/cpython-$PYTHON_VERSION+$PYTHON_RELEASE-aarch64-apple-darwin-install_only.tar.gz

HERE=$(cd "$(dirname "$0")" && pwd)
RES=${1:?usage: bundle_tools.sh <Resources folder> [work folder]}
WORK=${2:-$(mktemp -d -t bundle-tools)}
mkdir -p "$RES" "$WORK/dl"
RES=$(cd "$RES" && pwd); WORK=$(cd "$WORK" && pwd)
JOBS=$(sysctl -n hw.ncpu)
export MACOSX_DEPLOYMENT_TARGET=13.0

[ "$(uname -m)" = arm64 ] || { echo "[RED] this builds the arm64 app: run it on an Apple-silicon Mac" >&2; exit 1; }

fetch() {   # fetch <url> <sha256> -> the file in $WORK/dl
    local f="$WORK/dl/$(basename "$1")"
    if [ ! -f "$f" ]; then curl -fsSL --retry 3 -o "$f.part" "$1"; mv "$f.part" "$f"; fi
    local got; got=$(shasum -a 256 "$f" | cut -c1-64)
    [ "$got" = "$2" ] || { echo "[RED] $1: sha256 $got, pinned $2" >&2; rm -f "$f"; exit 1; }
    echo "$f"
}
unpack() {  # unpack <tarball> <dest> -> a fresh source folder
    rm -rf "$2"; mkdir -p "$2"; tar -xzf "$1" -C "$2" --strip-components=1
}

BIN="$RES/tools/bin"; LIC="$RES/tools/licenses"
rm -rf "$RES/tools" "$RES/python"
mkdir -p "$BIN" "$LIC" "$RES/tools/share"

# zstd: the command line tool alone, with its own library compiled in and no xz / lz4 / zlib to link
echo "== zstd $ZSTD_VERSION"
unpack "$(fetch "$ZSTD_URL" "$ZSTD_SHA256")" "$WORK/zstd"
make -C "$WORK/zstd/programs" -j "$JOBS" zstd HAVE_ZLIB=0 HAVE_LZMA=0 HAVE_LZ4=0 > "$WORK/zstd.log" 2>&1 || { tail -30 "$WORK/zstd.log"; exit 1; }
cp "$WORK/zstd/programs/zstd" "$BIN/zstd"
cp "$WORK/zstd/LICENSE" "$LIC/zstd-LICENSE-BSD"; cp "$WORK/zstd/COPYING" "$LIC/zstd-COPYING-GPLv2"

# glslang: glslangValidator alone (the SPIR-V optimizer is not built: gl_shaders.py only compiles with -V)
echo "== glslang $GLSLANG_VERSION"
unpack "$(fetch "$GLSLANG_URL" "$GLSLANG_SHA256")" "$WORK/glslang"
cmake -S "$WORK/glslang" -B "$WORK/glslang-build" -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DENABLE_OPT=OFF -DBUILD_EXTERNAL=OFF \
    -DENABLE_CTEST=OFF -DGLSLANG_TESTS=OFF -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
    -DCMAKE_EXE_LINKER_FLAGS='-Wl,-S,-x' > "$WORK/glslang.log" 2>&1 \
  && cmake --build "$WORK/glslang-build" --target glslang-standalone -j "$JOBS" >> "$WORK/glslang.log" 2>&1 || { tail -30 "$WORK/glslang.log"; exit 1; }
cp -L "$WORK/glslang-build/StandAlone/glslang" "$BIN/glslangValidator"   # glslang's own name for it is a link to the same program
cp "$WORK/glslang/LICENSE.txt" "$LIC/glslang-LICENSE.txt"

# SPIRV-Cross: the command line tool (static; the same options as the repo's spirv_cross_bin/build.sh, for arm64 only)
echo "== spirv-cross $SPIRV_CROSS_TAG"
unpack "$(fetch "$SPIRV_CROSS_URL" "$SPIRV_CROSS_SHA256")" "$WORK/spirv-cross"
cmake -S "$WORK/spirv-cross" -B "$WORK/spirv-cross-build" -DCMAKE_BUILD_TYPE=Release -DSPIRV_CROSS_ENABLE_TESTS=OFF -DSPIRV_CROSS_SKIP_INSTALL=ON \
    -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 -DCMAKE_EXE_LINKER_FLAGS='-Wl,-S,-x' > "$WORK/spirv-cross.log" 2>&1 \
  && cmake --build "$WORK/spirv-cross-build" --target spirv-cross -j "$JOBS" >> "$WORK/spirv-cross.log" 2>&1 || { tail -30 "$WORK/spirv-cross.log"; exit 1; }
cp "$WORK/spirv-cross-build/spirv-cross" "$BIN/spirv-cross"
cp "$WORK/spirv-cross/LICENSE" "$LIC/spirv-cross-LICENSE"
mkdir -p "$LIC/spirv-cross-LICENSES"; cp "$WORK/spirv-cross/LICENSES/"* "$LIC/spirv-cross-LICENSES/"

# xcodegen: the release's bin/xcodegen and share/xcodegen (SettingPresets), which it finds at ../share/xcodegen from its own folder
echo "== xcodegen $XCODEGEN_VERSION"
rm -rf "$WORK/xcodegen"; mkdir -p "$WORK/xcodegen"
ditto -x -k "$(fetch "$XCODEGEN_URL" "$XCODEGEN_SHA256")" "$WORK/xcodegen"
XG=$(find "$WORK/xcodegen" -name xcodegen -type f -perm -u+x -path '*/bin/*' | head -1)
[ -n "$XG" ] || { echo "[RED] no bin/xcodegen in the release zip" >&2; exit 1; }
XGROOT=$(dirname "$(dirname "$XG")")
cp "$XG" "$BIN/xcodegen"; chmod 755 "$BIN/xcodegen"
cp -R "$XGROOT/share/xcodegen" "$RES/tools/share/xcodegen"
cp "$XGROOT/LICENSE" "$LIC/xcodegen-LICENSE" 2>/dev/null || curl -fsSL "https://raw.githubusercontent.com/yonaskolb/XcodeGen/$XCODEGEN_VERSION/LICENSE" -o "$LIC/xcodegen-LICENSE"

# Python: python-build-standalone's install_only build runs from wherever it is (its libpython is @executable_path/../lib), and the packages
# are installed into it now, from the pinned list, so nothing is downloaded on the player's Mac.
echo "== python $PYTHON_VERSION"
PYTAR=$(fetch "$PYTHON_URL" "$PYTHON_SHA256")
rm -rf "$WORK/python-x"; mkdir -p "$WORK/python-x"; tar -xzf "$PYTAR" -C "$WORK/python-x"
mv "$WORK/python-x/python" "$RES/python"
PY="$RES/python/bin/python3"
"$PY" -I -m pip install --disable-pip-version-check --no-warn-script-location --only-binary :all: -r "$HERE/bundled-python-requirements.txt" > "$WORK/pip.log" 2>&1 || { tail -30 "$WORK/pip.log"; exit 1; }
# pip writes console scripts (nsz, fonttools, ...) whose first line names this build's absolute path: they cannot work from the player's copy
# (the build script starts nsz as `python -c`, and nothing else is called by name), so they go. A script of python-build-standalone's own
# (pip3) is a /bin/sh stub and stays.
for s in "$RES/python/bin/"*; do
    [ -f "$s" ] && [ ! -L "$s" ] && head -c 2 "$s" | grep -q '#!' && grep -q "$RES" "$s" && rm -f "$s"
done
# What a build never runs: Python's own test suite, IDLE, the turtle demos and Tk (the NSP script has no window)
SITE="$RES/python/lib/python${PYTHON_VERSION%.*}"
rm -rf "$SITE/test" "$SITE/idlelib" "$SITE/turtledemo" "$SITE/tkinter" "$SITE/lib-dynload/_tkinter"*.so \
       "$RES/python/lib/tcl"* "$RES/python/lib/tk"* "$RES/python/lib/itcl"* "$RES/python/lib/thread"* "$RES/python/lib/libtcl"* "$RES/python/lib/libtk"* "$RES/python/share/man" 2>/dev/null || true
find "$RES/python" -type d -name tests -path '*site-packages*' -prune -exec rm -rf {} + 2>/dev/null || true
cp "$SITE/LICENSE.txt" "$LIC/python-LICENSE.txt" 2>/dev/null || true
mkdir -p "$LIC/python-packages"
for d in "$SITE/site-packages/"*.dist-info; do
    n=$(basename "$d" .dist-info); mkdir -p "$LIC/python-packages/$n"
    find "$d" -maxdepth 2 \( -iname 'LICEN[SC]E*' -o -iname 'COPYING*' -o -iname 'NOTICE*' \) -type f -exec cp {} "$LIC/python-packages/$n/" \;
done
"$PY" -I - <<'PYEOF'
import lz4.block, capstone, fontTools, nsz, ssl, sqlite3, zlib, lzma, bz2
try: from compression import zstd
except ImportError: from backports import zstd
PYEOF

# Every Mach-O file is signed on its own first: `codesign --deep` of the app signs only code in the places a bundle names (MacOS,
# Frameworks, ...), not what sits in Resources, and a copy of a binary whose load paths or content changed keeps its old signature.
echo "== ad-hoc signing the nested code"
n=0
while IFS= read -r -d '' f; do
    if file -b "$f" | grep -q 'Mach-O'; then codesign --force --sign - "$f" 2> /dev/null && n=$((n + 1)); fi
done < <(find "$RES/tools" "$RES/python" -type f -print0)
echo "signed $n Mach-O files"
du -sh "$RES/tools" "$RES/python"
