#!/bin/bash
# Build the dlopen probe (docs/probe-dlopen.md) into an ad-hoc signed IPA with plain clang and
# hand-written Info.plists, no Xcode project: DmProbe.app tries to dlopen the Probe.framework beside
# its own executable and to call probe_answer() in it, logging every step to Documents/probe-log.txt
# on the phone (also shown on the screen). The sideloader (AltStore / Sideloadly / i4Tools) re-signs
# the app and the nested framework on install; the ad-hoc signature here is the placeholder the repo
# ships in every IPA (the same order build_ipa.sh uses: nested code first, then the bundle).
# Usage: dm/ios/probe/build_probe.sh [out.ipa]   (default: <repo>/probe-out/DmProbe.ipa)
# Self-checks: codesign verifies the framework and the app inside the build tree and again inside the
# extracted IPA; the load commands carry the rpath and the install name; the deployment target is 26.0;
# both binaries are arm64; both Info.plists lint.
set -u
cd "$(dirname "$0")" || exit 1
P=$PWD; REPO=$(cd ../../.. && pwd)
t() { echo "[$(date +%T)] $*"; }; die() { t "FAIL: $*"; exit 1; }
OUT=${1:-$REPO/probe-out/DmProbe.ipa}
APP=build/pkg/Payload/DmProbe.app
TARGET=arm64-apple-ios26.0

rm -rf build/pkg && mkdir -p "$APP/Frameworks/Probe.framework" || die "mkdir $APP"

t "compile Probe.framework (arm64 iOS, install_name @rpath/Probe.framework/Probe)"
xcrun -sdk iphoneos clang -arch arm64 -target "$TARGET" -Oz -Wall -dynamiclib \
  -install_name @rpath/Probe.framework/Probe \
  src/probe.c -o "$APP/Frameworks/Probe.framework/Probe" || die "clang Probe.framework"

t "compile the DmProbe shell app (rpath @executable_path/Frameworks)"
xcrun -sdk iphoneos clang -arch arm64 -target "$TARGET" -O2 -Wall -fobjc-arc \
  -framework Foundation -framework UIKit \
  -Wl,-rpath,@executable_path/Frameworks \
  src/probe_main.m -o "$APP/DmProbe" || die "clang DmProbe"

cat > "$APP/Frameworks/Probe.framework/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>Probe</string>
	<key>CFBundleIdentifier</key><string>org.nxnative.DmProbe.Probe</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleName</key><string>Probe</string>
	<key>CFBundlePackageType</key><string>FMWK</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>MinimumOSVersion</key><string>26.0</string>
</dict>
</plist>
EOF

# UIFileSharingEnabled: the Files app shows Documents/, so probe-log.txt can be read and shared
# on the phone; LSSupportsOpeningDocumentsInPlace opens it in place. No icons: a blank home-screen
# icon is fine for a probe (the repo's unsigned IPAs have none either).
cat > "$APP/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key><string>en</string>
	<key>CFBundleDisplayName</key><string>DmProbe</string>
	<key>CFBundleExecutable</key><string>DmProbe</string>
	<key>CFBundleIdentifier</key><string>org.nxnative.DmProbe</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleName</key><string>DmProbe</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>CFBundleSupportedPlatforms</key><array><string>iPhoneOS</string></array>
	<key>CFBundleVersion</key><string>1</string>
	<key>LSRequiresIPhoneOS</key><true/>
	<key>LSSupportsOpeningDocumentsInPlace</key><true/>
	<key>MinimumOSVersion</key><string>26.0</string>
	<key>UIFileSharingEnabled</key><true/>
	<key>UILaunchScreen</key><dict/>
	<key>UIRequiredDeviceCapabilities</key><array><string>arm64</string></array>
	<key>UISupportedInterfaceOrientations</key><array><string>UIInterfaceOrientationPortrait</string></array>
</dict>
</plist>
EOF

t "ad-hoc sign (nested framework first, then the bundle)"
xattr -cr "$APP" 2>/dev/null   # Finder information or resource forks on copied files: codesign refuses them
codesign --force --sign - "$APP/Frameworks/Probe.framework" || die "codesign Probe.framework"
codesign --force --sign - "$APP" || die "codesign DmProbe.app"

t "self-check the built bundle"
codesign -vvv --verify --strict "$APP/Frameworks/Probe.framework" >/dev/null || die "verify the framework signature"
codesign -vvv --verify --strict "$APP" >/dev/null || die "verify the app signature (covers the nested framework)"
[ -z "$(codesign -d --entitlements :- "$APP" 2>/dev/null)" ] || die "the probe embeds no entitlements, yet its signature carries some"
plutil -lint "$APP/Info.plist" "$APP/Frameworks/Probe.framework/Info.plist" >/dev/null || die "plutil"
lipo -info "$APP/DmProbe" "$APP/Frameworks/Probe.framework/Probe" | sed 's/^/  /'
otool -l "$APP/Frameworks/Probe.framework/Probe" | grep -A3 LC_ID_DYLIB | sed 's/^/  /'
otool -l "$APP/DmProbe" | grep -A3 LC_RPATH | sed 's/^/  /'
otool -l "$APP/DmProbe" | grep -A4 LC_BUILD_VERSION | sed 's/^/  /'
grep -qx '@executable_path/Frameworks' <(otool -l "$APP/DmProbe" | awk '/LC_RPATH/,/^$/{print $2}') || die "no LC_RPATH @executable_path/Frameworks in DmProbe"
grep -qx '@rpath/Probe.framework/Probe' <(otool -l "$APP/Frameworks/Probe.framework/Probe" | awk '/LC_ID_DYLIB/,/^$/{print $2}') || die "Probe.framework has the wrong install name"
grep -q 'minos 26.0' <(otool -l "$APP/DmProbe"; otool -l "$APP/Frameworks/Probe.framework/Probe") || die "deployment target is not 26.0"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Info.plist")" = DmProbe ] || die "CFBundleExecutable"
[ "$(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$APP/Info.plist")" = 26.0 ] || die "MinimumOSVersion"

t "pack the IPA (dm/ios/tools/pack_ipa.py)"
mkdir -p "$(dirname "$OUT")" || die "mkdir $(dirname "$OUT")"
rm -f "$OUT" "$OUT.idx"
python3 "$REPO/dm/ios/tools/pack_ipa.py" "$OUT" "Payload/DmProbe.app=$PWD/$APP" || die "pack_ipa"

t "self-check the packed IPA"
X=build/check && rm -rf "$X" && mkdir -p "$X" || die "mkdir $X"
unzip -q "$OUT" -d "$X" || die "unzip $OUT"
codesign -vvv --verify --strict "$X/Payload/DmProbe.app" >/dev/null || die "verify the extracted app"
codesign -vvv --verify --strict "$X/Payload/DmProbe.app/Frameworks/Probe.framework" >/dev/null || die "verify the extracted framework"
codesign -d -vvv "$X/Payload/DmProbe.app" 2>&1 | grep -E 'Identifier|Format|CDHash|TeamIdentifier' | sed 's/^/  /'

t "IPA: $OUT ($(du -h "$OUT" | cut -f1 | tr -d ' '))"
t "ready: sideload it (AltStore / Sideloadly / i4Tools), open DmProbe, read Documents/probe-log.txt; docs/probe-dlopen.md explains the results"
