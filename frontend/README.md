# nxnative for Mac

The native macOS front end for building games from your own Switch files, with a
library for playing the finished Mac apps. The interface is designed around
building a game, rather than manually importing finished apps.

<img src="screenshots/launcher-library.webp" width="100%" alt="The library, with a build in progress">

<img src="screenshots/launcher-build.webp" width="66%" alt="Build game"> <img src="screenshots/launcher-launch-options.webp" width="32%" alt="Launch options">

The screenshots are rendered by the app's own views: `NX_LAUNCHER_README_DIR=<dir>
NX_LAUNCHER_README_SETTINGS=<a Mac launcher.json> swift test --filter testReadmeScreenshots`
writes them as PNG (from a copy of your library, with example paths), and
`cwebp -q 86 -alpha_q 100 -m 6` makes the WebP files here.

## Build game

1. Select **Build game** and choose the folder containing one game's files, or
   pick the base game and `prod.keys` separately. Dropping NSP, NSZ or XCI files,
   a folder or `prod.keys` onto the page does the same: they are sorted into base
   game, update and DLC by the title ID in their names, as a chosen folder is.
2. Add an update or DLC under **Updates & add-on content** when needed.
3. Choose **This Mac** or **iPhone / iPad**, then **Build game**.

As soon as the base game and `prod.keys` are chosen, the line under `prod.keys` says
whether the keys open the game files: it decrypts the NCA headers of the NSP or NSZ
(base game, update, DLC) with `header_key` and checks that the keys of each one's key
generation are in the file, so keys that are too old for an update show up before the
build, not in its extraction step. An XCI cannot be checked this way and says so. No
key value is shown or logged.

Setup lives under **Settings**: the games folder, the repository and its updates,
the dependency checks and installers, and app updates. Missing setup is linked
from the build screen. The progress shows each of the script's steps with its
count, the time it has been running and, while the script's estimate lasts, the
time left; the build log opens under it. **Stop** ends the script and every tool
it started (the build runs in a process group of its own), and so does quitting
the app.

**Settings → Copy diagnostics** puts a short Markdown report on the clipboard, for a
bug report: the app and macOS versions and the chip; the repository, its commit and
branch and how far it is behind `upstream/main` and `origin/main` as of the last fetch
(nothing is fetched); the Python and .NET the builds run with and the dependency
check; this session's last build command and the last 50 lines of its log. The home
folder is shown as `~`, a log line holding key material (`name = <hex>`, as in
`prod.keys`) keeps only its name, and no environment variables are included.

A completed Mac build appears in the collection automatically and can be started
with **Play**. An iPhone build, by default, offers its unsigned IPA and the
sideloading and RomFS-copy instructions.

When a build finishes or fails while the app is in the background, a notification
names the game and the target; clicking it shows the game in the library, or the
Builds page with the log for a failed build. macOS asks for permission when the
first build starts, and **Settings → App** turns it off. Notifications need the
app bundle: started with `swift run` the launcher has no bundle identifier, and
there are none.

## Install on an iPhone or iPad

With Xcode, a development certificate (sign in to Xcode with your Apple ID under
Settings → Accounts) and a device paired with this Mac, an iPhone build can go
straight to the device: choose it under **Install on** and the **Signing team**
next to it. The script then prepares the game's Xcode project
(`--prepare-xcode --team-id`, the route it offers developers) instead of an IPA,
`xcodebuild -allowProvisioningUpdates` signs it for that device with the team
(Xcode makes the provisioning profile), and `xcrun devicectl device install app`
installs it. The game files take the same route as for sideloading. They are packed into
`games/<title ID>/romfs.img`, with any DLC in `aoc/` beside it, and the app is built
without them (`DM_COPY_ROMFS=NO`). After the install, `xcrun devicectl device copy to`
puts that folder into the app's `Documents/games/<title ID>/`, where the app looks first. devicectl skips files
that did not change, so a reinstall sends the code and shaders, not the whole game
again. The first copy of a large game takes a few minutes. The game then appears
in the collection, and its button opens it on the device.

The first time, turn on Developer Mode on the device and trust the developer
under Settings → General → VPN & Device Management. With a free Apple ID the
profile expires after seven days. **Don't install, export the IPA** keeps the
unsigned IPA as before. The devices and teams are read with `devicectl list
devices` and `security find-identity`; the team is the certificate's
organizational unit, not the code in its name.

## Saves

**Manage > Saves…** (a controller's Y) shows a game's save on this Mac
(where `dm/mac/launcher.c` puts it: `<library folder>/save/<title ID>` beside the app when
its folder holds `games/`, else `~/Library/Application Support/nxnative/<title ID>/save`;
until the app has copied an older `~/Library` save across, that one is shown) and
on the device the launcher installed it on (`Documents/games/<title ID>/save` in the app's
data container, from `dm/ios/Sources/main.m`), each with the date of its newest file, and
marks the newer one. **Mac → iPhone** and **iPhone → Mac** copy one over the other, after
asking. The save being replaced is backed up first, beside the Mac save in
`<save>-backups/<date> mac` or `<date> device` (the device's is copied to the Mac before
anything is replaced). A game that also keeps device save data has a `<save>_device`
folder beside it (`dm/host/hle_fs.c`), which goes along. The copy is refused while
the game runs on the Mac; close it on the device too, or it writes its own save over the
copy later. The device side uses the install's route: `devicectl device info files` for
the date and `devicectl device copy from` / `copy to` with the app's data container. Only
a game installed from here has a known bundle ID, so a sideloaded IPA has no device side.

## Your games folder

Set **Your games folder** in Settings once. The launcher remembers it, checks it
on startup, and uses it as the default output location for new builds. **Refresh**
looks for existing nxnative Mac game apps, including apps in subfolders up to four
levels deep. It skips game contents, extraction folders and build caches. It does
not copy or move the games. Several builds of the same title occupy one entry;
an already linked, valid build keeps its location.

Readiness is checked against each app's title ID and executables. Ready games are
green, building games are yellow, and games without a finished output are gray.
Removing a collection entry leaves its game and source files on disk. The small
library manifest is stored at
`~/Library/Application Support/NS Port Builder/library.json`.

## Launch options

The button beside **Play** opens the game's launch options: the settings the iPhone
launcher shows before a game starts ([docs/settings.md](../docs/settings.md)), read
from the list the engine packs into the Mac app (`Contents/Resources/dm/launcher.json`,
written by `dm/games/settings.py` from `dm/games/settings.tsv`; the engine change that
packs it is [seedds/nxnative#352](https://github.com/seedds/nxnative/pull/352), so a
sync from upstream brings it). **Play** starts the app with every setting in its
environment. Only a choice that differs from the game's tested default is kept, in the
library manifest; **Reset to tested defaults** forgets them. An app without the list
shows none. Starting the app from Finder uses its defaults.

## Controls

**Settings → Controls → Customize…** sets the keys and controller buttons for every game.
For a key, click its field and press the new key (Esc keeps the old one, × leaves the
function on no key). One key holds one function, so the function that had the key before
is left on none, as in the host. For a controller button, choose the button it sends
(A and B swapped, for example). The right stick has no keys by default and can get some
here. **Play** passes only the changes, as `DM_KEYMAP` and `DM_PAD_MAP`, which the host
reads through `dm/host/input_map.h` — upstream's
[seedds/nxnative#386](https://github.com/seedds/nxnative/pull/386), carried in this fork
while it is open, and listed in `docs/env_switches.tsv`. A host built before the carrier
has no `input_map.h` and ignores both, so its games play with the default keys.

The controller has four layouts, each only a `DM_PAD_MAP` value. **Standard layout**
(the default) passes nothing: the host reads the face buttons by position, in the
Nintendo layout (right A, bottom B, top X, left Y), for PlayStation and other
controllers. **By label** passes `A=B,B=A,X=Y,Y=X`, so A, B, X and Y are the letters
printed on a Nintendo or Xbox controller: GameController reports both families'
buttons by their letters (an Xbox controller's letters are Apple's button diamond, and
a Pro Controller's A, on the right, arrives as `buttonA`, as
[seedds/nxnative#382](https://github.com/seedds/nxnative/pull/382) found), which the
host's positional reading turns into the other letter, so one swap serves both.
**Custom** is the per-button choice; changing a button switches to it. **Auto** picks
By label or Standard from `GCController.productCategory` of the controller connected
when **Play** is pressed (Nintendo, Switch Pro, Joy-Con or Xbox in its name: By label).
One map goes to every controller, so two different kinds at once cannot both be right;
a per-controller choice belongs in the host (#382 does it for Nintendo controllers).
The page shows the connected controller and what Auto picks for it.

## Artwork

The launcher shows, in this order: a custom image chosen under **Manage > Change
artwork**; the game's eShop key art (1920×1080 from Nintendo's image CDN, found by
title ID in the community title database
[blawar/titledb](https://github.com/blawar/titledb)); a matching gameplay screenshot
from the repository; the built app's icon. The title list (about 90 MB) is
downloaded only while a game in the collection has no key art yet, reduced to title
ID → image and kept with the images in
`~/Library/Application Support/NS Port Builder/artwork/`. Custom images stay at
their chosen path.

## Type

The interface is set in Manrope (SIL Open Font License; `fonts/`, with its license):
headings, text and a game's status line, whose capitals are the same face, tracked.
Paths and the build log use the system's monospaced face. `python3 fonts/embed_fonts.py`
writes the font into the binary as `Sources/NSPortBuilder/EmbeddedFonts.swift`, so the app needs no font
installed and no resource bundle beside the executable.

The app icon is drawn by `make_icon.swift`; `./make_icon.sh` writes `icon.iconset/`
and `AppIcon.icns` from it.

## App updates

When the app opens it asks GitHub for the latest release. With **Install updates
automatically** on (Settings → App, the default), a newer release is downloaded in
the background and staged: the zip's SHA-256 must match the `digest` GitHub gives
for the asset (a release without one is not installed automatically), and the app
inside must carry this app's bundle identifier, an executable and the release's
version. The staged copy replaces the app when you quit it, so the next launch is
the new version; **Restart now** in Settings and in the library's bottom line
installs it at once. Neither runs while a build does: the swap ends with a relaunch,
which would end the build's process group. If you quit during a build, the build is
stopped as before and the update waits for a later quit. With the switch off,
**Update to vX** in Settings downloads, verifies and relaunches as before (a
release without a digest is still accepted there; a wrong digest never is).

A launcher built from this repository never replaces itself: `swift run` (no
bundle), a bundle under `.build/` or `DerivedData/`, a bundle beside
`Package.swift` (the `NX2Apple.app` made here), or one whose Info.plist version
is not this binary's release number. `AppUpdate.swift` holds these rules.

## Run

```bash
cd frontend
swift run
```

or double-click `nxnative.app` in this folder (ad-hoc signed; rebuild it with `swift build -c release`
and copy the binary into `Contents/MacOS/`). The app's settings and library stay under the folder name it
had before the rename, `~/Library/Application Support/NS Port Builder/`.

SwiftUI, macOS 13+.

### Why the dependency check does not use `which`

A GUI app does not inherit the shell's PATH. On a machine where a terminal sees
`.NET` and the Python packages just fine, a naive `which dotnet` and
`/usr/bin/python3` check reports both missing. So the app looks where the tools
actually are (`~/.dotnet`, `/usr/local/share/dotnet`, the Python framework
installs), verifies `.NET` with `--list-sdks` (the extractor targets `net10.0`),
and picks the first interpreter that can really import
`lz4 capstone fontTools backports.zstd`. That same interpreter then runs the
build.

### The bundled build tools and Python

The release app (`NX2Apple.app`) carries `zstd`, `glslangValidator`, `spirv-cross`, `xcodegen` (in
`Contents/Resources/tools/bin`) and a relocatable CPython 3.13 with `lz4 capstone fonttools
backports.zstd nsz` (`Contents/Resources/python`), so a player needs no Homebrew and no Python.
`tools/bundle_tools.sh` fills them in during the release workflow (pinned versions and sha256 of the
sources, built for macOS 13 with static libraries; the Python packages come from
`tools/bundled-python-requirements.txt`) and `tools/check_bundle.sh` runs each tool from the bundle
with a clean PATH. The dependency check (`BundledTools.swift`) prefers them to Homebrew's and shows
"bundled"; the build's PATH starts with them. Under `swift run`, or in a build without the bundle,
nothing changes: Homebrew's tools, a system Python or the launcher's venv. To try the bundle by hand:
`tools/bundle_tools.sh <folder> <work folder>`, then `tools/check_bundle.sh <folder>`.

## Language

The interface follows the system language at every launch: any Chinese variant
(Simplified, Traditional, Hong Kong, Taiwan) gets Chinese, every other language gets
English; the app has no language switch. Strings live in
`Sources/NSPortBuilder/Localization.swift`; regenerate the Qt table after editing
it with `python3 frontend-qt/gen_localization.py` from the repository root.

## Verification

```bash
swift test --package-path frontend
```

The Swift tests cover bundle validation, persistent metadata, folder discovery,
source-file preservation, and automatic registration through a synthetic build
process, including when the window is hidden. Set `NX_LAUNCHER_CAPTURE_DIR` to
capture the native library, build, settings, empty and active-build views for
visual QA. Capture fixtures are isolated from the user's library and never run a
real game build.
