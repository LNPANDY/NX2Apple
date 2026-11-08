#!/bin/bash
# Builds the launcher for the app bundle (swift build -c release) and checks that the executable records the macOS SDK it was built with.
#
# Since Swift 6.4 (Xcode 27) swift build uses Swift Build, whose link step hands the SDK to clang as --sysroot. Clang reads the SDK version
# from -isysroot or SDKROOT only, so ld wrote the deployment target (13.0) as the SDK version, and macOS ran the launcher as an app built
# with the macOS 13 SDK. On macOS 27 SwiftUI then made no window when the Dock icon was clicked after the last window was closed (#962).
# -isysroot on the link gives clang the SDK again (the native build system did not need it). The check fails the build if it drifts back.
#
# Usage: build_launcher.sh                     build, then check .build/release/NX2Apple (run from anywhere)
#        build_launcher.sh --check <executable>  only the check
set -euo pipefail
cd "$(dirname "$0")/.."
SDK=$(xcrun --sdk macosx --show-sdk-path)
SDK_VERSION=$(xcrun --sdk macosx --show-sdk-version)

# The minos and sdk of the executable's LC_BUILD_VERSION; the sdk must be the SDK's own version, never the deployment target.
check() {
    local exe=$1 minos sdk
    read -r minos sdk < <(otool -l "$exe" | awk '/cmd LC_BUILD_VERSION/ { f = 1 } f && $1 == "minos" { m = $2 } f && $1 == "sdk" { print m, $2; exit }') || true
    if [ -z "${sdk:-}" ]; then
        echo "FAIL  $exe has no LC_BUILD_VERSION" >&2; return 1
    fi
    if [ "$sdk" != "$SDK_VERSION" ]; then
        echo "FAIL  $exe records SDK $sdk (minimum macOS $minos), not the macOS $SDK_VERSION SDK it was built with: macOS runs it as an app" \
             "built with the macOS $sdk SDK (#962). Build it with frontend/tools/build_launcher.sh." >&2
        return 1
    fi
    echo "ok    $exe: SDK $sdk, minimum macOS $minos"
}

if [ "${1:-}" = "--check" ]; then
    check "${2:?usage: build_launcher.sh --check <executable>}"
    exit
fi

swift build -c release -Xswiftc -Xclang-linker -Xswiftc -isysroot -Xswiftc -Xclang-linker -Xswiftc "$SDK"
check .build/release/NX2Apple
