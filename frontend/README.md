# nxnative for Mac

> Paths such as `dm/…`, `docs/…` and `scripts/…` in this page are the engine's: `engine/` in a checkout after `python3 tools/engine.py sync`, or nxnative at the pinned commit (`.upstream-ref`).

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
time left. The build log opens under it. **Stop** ends the script and every tool
it started (the build runs in a process group of its own), and so does quitting
the app.

**Settings → Copy diagnostics** puts a short Markdown report on the clipboard, for a
bug report. It holds the app and macOS versions and the chip, the repository (its commit and
branch and how far it is behind `upstream/main` and `origin/main` as of the last fetch, since
nothing is fetched), the Python and .NET the builds run with and the dependency
check, the fork patches in the checkout (`dm/fork_patches.txt`), the selected Xcode and its
version, both Metal compilers beside the versions `dm/gfx/tools/dmsh_chain.lock` pins, the iOS SDK,
and this session's last build command and the last 50 lines of its log. For the selected
game it adds its built app's patches and the last 200 lines of its log. The home
folder is shown as `~`, a log line holding key material (`name = <hex>`, as in
`prod.keys`) keeps only its name, and no environment variables are included.

Every dependency check also writes `deps-check.txt` beside `library.json`
(`~/Library/Application Support/NS Port Builder/`): each row's verdict, the
interpreter paths that were tried, and the `HOME` and `PATH` the panel ran with.
That is the file to attach when the panel and the terminal disagree — a Finder
launch gives the app a different PATH from the shell's.

A completed Mac build appears in the collection automatically and can be started
with **Play**. An iPhone or iPad build goes into the shared app on the device
(see below), and the game appears in the collection with a button that opens it there.

When a build finishes or fails while the app is in the background, a notification
names the game and the target. Clicking it shows the game in the library, or the
Builds page with the log for a failed build. macOS asks for permission when the
first build starts, and **Settings → App** turns it off. Notifications need the
app bundle: started with `swift run` the launcher has no bundle identifier, and
there are none.

## iPhone and iPad

The **iPhone / iPad** target is one app on the device that holds every game you add. It needs
Xcode, a development certificate (sign in to Xcode with your Apple ID under Settings → Accounts)
and a device paired with this Mac. Choose the device under **Install on** and the **Signing team**
next to it before the build. The build script makes only the game's framework
(`--shell-framework`), and the shared app holds the games. The launcher keeps the list of games in
`shell.json` in the shell folder, `~/Library/Application Support/NX2Apple/shell` (saved as
`shellRoot`, it holds the games' frameworks, the project, derived data and the banner cache). Older
versions made it as `NX2Apple-shell` inside the output folder. The launcher moves such a folder
there once at start (a rename on the same volume, shell.json's paths are rewritten), and only when
it is the folder the launcher made, shell.json can be read and the new place is free. On any doubt
the old folder stays where it is and keeps being used, and nothing is deleted. Uninstalling the
launcher leaves this folder alone. The launcher
generates the app's project with `dm/ios/tools/build_shell.sh --prepare-xcode`, signs it with
`xcodebuild -allowProvisioningUpdates` and installs it over the one already there with
`xcrun devicectl device install app`, which keeps the app's Documents. The game files are packed
into `games/<title ID>/romfs.img`, with any DLC in `aoc/` beside it. They are compared with the
device by path and size, and only what is missing is copied to the app's
`Documents/games/<title ID>/`, so a second install of the same game copies nothing. The first copy
of a large game takes a few minutes. The same steps run without the window:

    NSPortBuilder --install-shell --framework <path> --archive <games/TITLEID folder> --title-id <id> \
        --name <name> --device <udid> --team <team> --repo <repo> [--shell-root <dir>] [--python <path>]

The first time, turn on Developer Mode on the device and trust the developer
under Settings → General → VPN & Device Management. With a free Apple ID the
profile expires after seven days, and **Re-sign** on the game renews it. The devices and teams are
read with `devicectl list devices` and `security find-identity`. The team is the certificate's
organizational unit, not the code in its name.

A game that an earlier version built as its own app or IPA stays in the library, marked as an
older iPhone build. Nothing is deleted. **Build** makes it again for the shared app. A saved
iPhone target from an earlier version becomes the shared-app target.

**Manage > Show game log** opens the game's latest log in Console. It is `<library folder>/log/<title ID>.log`
when the app's folder holds the library marker (`.nx2apple-library`), else
`~/Library/Logs/nxnative/<title ID>.log` (`dm/mac/launcher.c`), and the row is off with a tooltip until the game has run.

## Saves

**Manage > Saves…** (a controller's Y) shows a game's save on this Mac
(where `dm/mac/launcher.c` puts it: `<library folder>/save/<title ID>` beside the app when
its folder holds `games/`, else `~/Library/Application Support/nxnative/<title ID>/save`, and
until the app has copied an older `~/Library` save across, that one is shown) and
on the device the launcher installed it on (`Documents/games/<title ID>/save` in the app's
data container, from `dm/ios/Sources/main.m`), each with the date of its newest file, and
marks the newer one. **Mac → iPhone** and **iPhone → Mac** copy one over the other, after
asking. The save being replaced is backed up first, beside the Mac save in
`<save>-backups/<date> mac` or `<date> device` (the device's is copied to the Mac before
anything is replaced). A game that also keeps device save data has a `<save>_device`
folder beside it (`dm/host/hle_fs.c`), which goes along. The copy is refused while
the game runs on the Mac. Close it on the device too, or it writes its own save over the
copy later. The device side uses the install's route: `devicectl device info files` for
the date and `devicectl device copy from` / `copy to` with the app's data container. Only
a game installed from here has a known bundle ID, so an app installed another way has no device side.

## Cheats

**Manage > Cheats…** manages a game's cheat files, the contract that `docs/frontends.md` ("Cheats") describes and
the host reads (`dm/host/hle_cheats.c`, from upstream since [seedds/nxnative#406](https://github.com/seedds/nxnative/pull/406)
landed). The files live in `~/Library/Application Support/nxnative/<title ID>/cheats`, which is what the Mac
app's launcher (`dm/mac/launcher.c`) sets `DM_ROOT` to, whatever the library folder is.

- **Import** by dropping onto the sheet or **Import…**: a Ryujinx folder, an SD card's `atmosphere/contents/<title ID>/cheats`
  (or the card itself, where another game's folder is left out), or single `<build ID>.txt` files. Each comes in as
  `<build ID>.txt` in upper case, replacing an older file of that build, with the `.meta.tsv` of `scripts/cheat_anchor.py`
  beside it when there is one. A file whose name carries no build ID is reported, since it cannot be matched to a version.
- **Switches.** The sheet names the build ID the game uses (`# BUILD_ID` in the app's `dm/main.fixups.tsv`, the first 16 digits)
  and marks the file for it. Files for other builds are listed dimmed without switches. Each cheat of this build's file has a
  switch, written at once to `<build ID>.enabled` (one name per line, `Name #2` for a duplicate, never masters, labels,
  one-pass cheats or the off half of an on / off pair), the file the game's own Cheats panel reads and writes. **Run cheats
  in the game** is the master switch (the flag file `.cheats-off-<title ID>`).
- **iPhone / iPad.** For a game installed from here, **Copy to iPhone** replaces the app's `Documents/games/<title ID>/cheats`
  with this folder over the install's route (`devicectl device copy to`, as the Saves sheet does), without the Mac's
  safe-mode flag. The iOS app points `DM_CHEATS` at that folder (fork patch `ios-game-data-folder`), so copy again after a
  change. The iPhone runs data cheats only. A cheat that writes into the game's code is turned off there with a line in the log,
  because iOS does not allow changing the game's code. The sheet carries a note saying so for a game with an iOS build.
- **Mac.** Code cheats run in the Mac app. The host refuses a code write into a word the rewriter changed, listed in the
  app's `dm/main.changed.tsv`. Modules from an older rewriter have no such file. Then every code write is refused until the modules are rewritten.

The host reads the files when the game starts, or on its Reload cheats (⌘R) on the Mac, and never watches the folder. So a
change while the game runs applies after a reload, and the sheet says so. Live switching from the launcher is not part of it.

## Your games folder

Set **Your games folder** in Settings once. The launcher remembers it, checks it
on startup, and uses it as the default output location for new builds. **Refresh**
looks for existing nxnative Mac game apps, including apps in subfolders up to four
levels deep. It skips game contents, extraction folders and build caches. It does
not copy or move the games. Several builds of the same title occupy one entry,
and an already linked, valid build keeps its location.

Readiness is checked against each app's title ID and executables. Ready games are
green, building games are yellow, and games without a finished output are gray.
Removing a collection entry leaves its game and source files on disk. The small
library manifest is stored at
`~/Library/Application Support/NS Port Builder/library.json`.

## Launch options

The button beside **Play** opens the game's launch options: the settings the iPhone
launcher shows before a game starts ([docs/settings.md](https://github.com/seedds/nxnative/blob/f25fa9562ee96d06f1e6412dbb91aab2b7035ec1/docs/settings.md)), read
from the list the engine packs into the Mac app (`Contents/Resources/dm/launcher.json`,
written by `dm/games/settings.py` from `dm/games/settings.tsv`, and the engine change that
packs it is [seedds/nxnative#352](https://github.com/seedds/nxnative/pull/352), so a
sync from upstream brings it). **Play** starts the app with every setting in its
environment. Only a choice that differs from the game's tested default is kept, in the
library manifest. **Reset to tested defaults** forgets them. An app without the list
shows none. Starting the app from Finder uses its defaults.

## Controls

**Settings → Controls → Customize…** sets the global keyboard and controller layout.
For a key, click its field and press the new key (Esc keeps the old one, × leaves the
function on no key). One key holds one function, so the function that had the key before
is left on none, as in the host. For a controller button, choose the button it sends
(A and B swapped, for example). The right stick has no keys by default and can get some
here.

For rebuilt games that support saved controller mappings, **Manage → Launch options →
Controller mapping…** opens a layout for that game. It shares standard button mappings
with the game's controller menu, including **Shake**. The first launch or opening of
this editor copies a changed global keyboard/controller layout only where the game has
no saved mapping. This happens once, including when the global layout is unchanged,
so resetting in the game's menu stays reset. **Copy global layout** explicitly replaces
only the standard keyboard and controller maps. Steam extra inputs remain unchanged.
The per-game editor refreshes after switching back from the game's menu.

The **Steam Controller (2026)** section configures L4/R4/L5/R5, both pad clicks,
Guide and Quick Access, the two trackpad modes and motion controls. Extra buttons are
unbound by default, the left pad is a D-pad, the right pad is a touchscreen, and motion
is enabled. **Reset Steam controls** resets only this section. Standard maps apply to
all controllers for the game, while these extra settings apply to the Steam model.

Existing game apps must be rebuilt with the updated engine to receive direct Steam
Controller input and the per-game editor. The launcher checks the built app's explicit
`DMControllerMappings=1` capability marker. Older builds continue receiving the global
layout as `DM_KEYMAP` and `DM_PAD_MAP` at Play. New builds read those maps from the
game's preferences, allowing the in-game panel to change them. Explicit launch overrides
and `env.txt` retain their precedence. `DM_SAVED_CHOICES=0` prevents migration and
preserves the legacy launch environment. No controller preferences are written while
saved choices are disabled.

Direct raw Steam input belongs to built games. Library and console navigation in
NX2Apple continue to depend on Apple's GameController support.

macOS may require **System Settings → Privacy & Security → Input Monitoring**
permission for the game app's direct Steam input. Bluetooth pairing alone does not
grant it. If direct input, motion or rumble is unavailable, enable the game app
you launch there, quit and reopen it, then reconnect the controller. Replacing or
rebuilding an ad-hoc signed app can require renewing that permission.

The controller has four layouts, each only a `DM_PAD_MAP` value. **Standard layout**
(the default) passes nothing: the host reads the face buttons by position, in the
Nintendo layout (right A, bottom B, top X, left Y), for PlayStation and other
controllers. **By label** passes `A=B,B=A,X=Y,Y=X`, so A, B, X and Y are the letters
printed on a Nintendo or Xbox controller: GameController reports both families'
buttons by their letters (an Xbox controller's letters are Apple's button diamond, and
a Pro Controller's A, on the right, arrives as `buttonA`, as
[seedds/nxnative#382](https://github.com/seedds/nxnative/pull/382) found), which the
host's positional reading turns into the other letter, so one swap serves both.
**Custom** is the per-button choice. Changing a button switches to it. **Auto** picks
By label or Standard from `GCController.productCategory` of the controller connected
when **Play** is pressed (Nintendo, Switch Pro, Joy-Con or Xbox in its name: By label).
One map goes to every controller, so two different kinds at once cannot both be right.
A per-controller choice belongs in the host (#382 does it for Nintendo controllers).
The page shows the connected controller and what Auto picks for it.

## Artwork

The launcher shows, in this order: a custom image chosen under **Manage > Change
artwork**, then the game's eShop key art (1920×1080 from Nintendo's image CDN, found by
title ID in the community title database
[blawar/titledb](https://github.com/blawar/titledb)), then a matching gameplay screenshot
from the repository, and last the built app's icon. The title list (about 90 MB) is
downloaded only while a game in the collection has no key art yet, reduced to title
ID → image and kept with the images in
`~/Library/Application Support/NS Port Builder/artwork/`. A custom image is
downscaled (3840 px wide at most) and copied to `artwork/custom/<game>/` beside them, so
moving or deleting the original changes nothing. The same list names each title's
screenshots (6 at most): they are indexed for the games asked about and
downloaded one by one into `artwork/<title ID>/`, only when asked for. Images chosen with an earlier version are
copied the same way at the next launch.

The list can hold several shop products under one title ID: the game, its Nintendo
Switch 2 Edition, or a bundle with a membership or an expansion pass. The launcher
takes the game's own product. A product whose name marks an edition, a bundle, a pass
or a demo loses, and of two equal ones the first in the shop wins. `sources.json` in
the same folder records where each image came from. An image saved by an older
launcher is checked once against this rule and replaced when it belongs to another
product. A banner with a promotion painted in (for example "Demo Available") cannot be
told from the list. Change artwork covers it. A game the list does not know, as most
Switch 2 games today, falls back to the screenshot, the app icon or the placeholder.

## Type

The interface is set in Manrope (SIL Open Font License, with its license in `fonts/`):
headings, text and a game's status line, whose capitals are the same face, tracked.
Paths and the build log use the system's monospaced face. `python3 fonts/embed_fonts.py`
writes the font into the binary as `Sources/NXLauncher/EmbeddedFonts.swift`, so the app needs no font
installed and no resource bundle beside the executable.

The app icon is `AppIcon.icon`, the Liquid Glass icon made in Icon Composer (the iOS app uses the same file).
`build-mac-app.yml` compiles it with the `actool` of Xcode 27.2 (the one in Xcode 26.6 throws an exception on this icon) into `Assets.car` (macOS 26 and later) and `AppIcon.icns` (macOS 13 to 25),
and `Info.plist` names both. To compile it by hand:

```sh
xcrun actool AppIcon.icon --compile out --platform macosx --minimum-deployment-target 13.0 \
  --app-icon AppIcon --output-partial-info-plist out/partial.plist
```

## App updates

When the app opens it asks GitHub for the latest release. With **Install updates
automatically** on (Settings → App, the default), a newer release is downloaded in
the background and staged: the zip's SHA-256 must match the `digest` GitHub gives
for the asset (a release without one is not installed automatically), and the app
inside must carry this app's bundle identifier, an executable and the release's
version. The staged copy replaces the app when you quit it, so the next launch is
the new version. **Restart now** in Settings and in the library's bottom line
installs it at once. Neither runs while a build does: the swap ends with a relaunch,
which would end the build's process group. If you quit during a build, the build is
stopped as before and the update waits for a later quit. With the switch off,
**Update to vX** in Settings downloads, verifies and relaunches as before (a
release without a digest is still accepted there, but a wrong digest never is).

A launcher built from this repository never replaces itself: `swift run` (no
bundle), a bundle under `.build/` or `DerivedData/`, a bundle beside
`Package.swift` (the `NX2Apple.app` made here), or one whose Info.plist version
is not this binary's release number. `AppUpdate.swift` holds these rules.

## The nxb builder

Settings, Build tools, **Build with nxb** (on by default, LNPANDY/NX2Apple#749). `nxb` is the build tool of [nxkit](https://github.com/v0lumehi/nxkit), in Rust. It makes the same files as the NSP script, faster. With the switch on, the launcher runs `nxb build` with the script's own arguments and `NXB_ENGINE` set to the engine. Exit code 4 ("not supported yet") runs the NSP script with the same arguments, in the same build. Any other failure shows nxb's exit code and its last error line. `BUILDING.md` lists the exit codes. With the switch off, the NSP script builds everything. A player who turned the switch off keeps that choice.

Where `nxb` comes from (`ExperimentalBuilder` in `NXCore`):

1. The path chosen in the row under the switch, the `nxb` binary or the folder that holds it. A chosen path that does not work is reported, never replaced by another binary.
2. Otherwise the app's own copy, `Contents/Resources/nxbuild/nxb`. `frontend/nxbuild.pin` names the nxkit release (version, SHA-256, URL pattern). `build-mac-app.yml` and `tools/try-local` run `frontend/tools/nxbuild.py fetch`. It downloads the zip, checks its SHA-256 against the pin before anything is unpacked, puts `nxb` into Resources and signs it ad hoc. A zip whose digest differs fails the app build. A pin with `PLACEHOLDER` as its digest bundles nothing. `frontend/tools/nxbuild.py bump <version>` pins a new release with the digest from its `SHA256SUMS`. Players download nothing at run time.

With neither, the build log says so and the NSP script builds.

To try a local nxkit:

```bash
cd <nxkit checkout> && cargo build --release      # the binaries land in its target folder, release/
codesign --force --sign - <target>/release/nxb*   # ad hoc, as the app's copy
```

Then choose `release/nxb` (or the folder) in the row under the switch.

The Qt front end has no switch for it. nxb is built for macOS on Apple silicon only, and on a Mac the launcher above is the one to use.

## Run

```bash
cd frontend
swift run
```

or double-click `nxnative.app` in this folder (ad-hoc signed, and rebuild it with `swift build -c release`
and copy the binary into `Contents/MacOS/`). The app's settings and library stay under the folder name it
had before the rename, `~/Library/Application Support/NS Port Builder/`.

To try the app CI built for a pull request, for `main` or for a release candidate, without building it: `tools/try-pr 271`,
`tools/try-pr main` or `tools/try-pr v0.7.6-rc1` from the repository root. It opens the downloaded copy on the engine tree inside it.
That copy shares settings and Application Support with an installed NX2Apple. The top of `tools/try-pr` says what that means.

SwiftUI, macOS 13+.

### Why the dependency check does not use `which`

A GUI app does not inherit the shell's PATH. On a machine where a terminal sees
`.NET` and the Python packages just fine, a naive `which dotnet` and
`/usr/bin/python3` check reports both missing. So the app looks where the tools
actually are (`~/.dotnet`, `/usr/local/share/dotnet`, the Python framework
installs), verifies `.NET` with `--list-sdks` (the extractor targets `net10.0`),
and picks the first interpreter that can really import
`lz4 capstone fontTools zbic backports.zstd`. That same interpreter then runs the
build.

The interpreters uv installs (`uv python install`) count as well: they live in
`~/.local/share/uv/python` (or `UV_PYTHON_INSTALL_DIR`) with shims in
`~/.local/bin`, neither of which a GUI launch's PATH contains, and a uv user
often has no Homebrew and no python.org framework at all. When no interpreter is
found, **Install** creates the app's venv from the newest one that does run at
3.12 or newer rather than from the venv path it is about to create.

### The bundled build tools and Python

The release app (`NX2Apple.app`) carries `zstd`, `glslangValidator`, `spirv-cross`, `xcodegen` (in
`Contents/Resources/tools/bin`) and a relocatable CPython 3.13 with `lz4 capstone fonttools
zbic backports.zstd nsz` (`Contents/Resources/python`), so a player needs no Homebrew and no Python.
`tools/bundle_tools.sh` fills them in during the release workflow (pinned versions and sha256 of the
sources, built for macOS 13 with static libraries, and the Python packages come from
`bundled-python/requirements.txt`, exact pins with hashes that Dependabot keeps current) and `tools/check_bundle.sh` runs each tool from the bundle
with a clean PATH. The dependency check (`BundledTools.swift`) prefers them to Homebrew's and shows
"bundled", and the build's PATH starts with them. Under `swift run`, or in a build without the bundle,
nothing changes: Homebrew's tools, a system Python or the launcher's venv. To try the bundle by hand:
`tools/bundle_tools.sh <folder> <work folder>`, then `tools/check_bundle.sh <folder>`.

## Language

The interface follows the system language at every launch: a device language that has a file in
`l10n/` gets that language (any Chinese variant gets Chinese, Swedish gets Swedish, German gets German,
French gets French) and every other language gets English. Settings > Language overrides
that. The texts and the language list are not in Swift. Every language is one JSON file in `l10n/`
(`en.json`, `zh.json`, `sv.json`, `de.json`, `fr.json`): a flat object with the keys sorted, UTF-8 text
without escapes, and a `_language` entry. It holds the language's own name (`name`, which the picker
shows), the lowercased locale prefixes that select it (`locales`) and optionally its place in the picker
(`order`, languages without one come last by code).
`Sources/NXCore/Localization.swift` keeps only `Lang` (a language is its code, and `Lang.all` is the list
of files) and the lookup, and `LocalizationFiles.swift` reads the files once, at the first lookup. A new
language is one new file under `l10n/`: the picker, the device detection and the lookup find it with no
change in Swift, and the iOS shell offers it too (below). A new string is a line in
`l10n/en.json` and one in `l10n/zh.json`: English and Chinese have every key. Swedish, German and French
may miss a key and then show the English text, and `GermanLocalizationTests` and
`FrenchLocalizationTests` check the entries they have (placeholders match the English text). The Windows
launcher reads the same files, so one edit serves both.

`LocalizationKeyTests` (Mac) and `test_localization_keys.py` (Qt) keep the code and `en.json` in step: a key a lookup
names must exist, a key en.json has must be used by one of the two front ends, and a key built from a prefix and a variable
(`"fail." + kind + ".what"`) needs a line in `frontend/Tests/l10n-key-rules.json` (`dynamicKeys`). A key that is only
kept on purpose goes into `unusedAllowed` there, with the reason. Remove an unused key from every language file.

The iOS shell's texts are in the same files, under `ios.ui.` (ShellUI) and `ios.host.` (ShellHost). The Mac and the
Windows launcher never show them. Xcode needs a string catalog per target, so
`python3 tools/l10n_shell_catalogs.py` writes `frontend-ios/Sources/ShellUI/Resources/Localizable.xcstrings` and
`frontend-ios/Sources/ShellHost/Resources/Localizable.xcstrings` from the files (the catalogs are not edited by hand).
The Swift code asks for a shell text by its English words (`ShellStrings.text("Done")`), so the catalog's key is the English
text of the JSON key, and each language file that has the JSON key adds a localization (`zh.json` becomes `zh-Hans`, every other
code stays as it is). A new shell text is a line in every language file under the prefix, the same words in the Swift call
and `python3 tools/l10n_shell_catalogs.py`. A new language file shows up in both catalogs with no change in the tool. Unlike the
launchers' texts, every shell text has every language: `python3 tools/l10n_shell_catalogs.py --check` fails when a language file
lacks one, and so do `ShellStringsTests` (each catalog entry has all seven) and `ShellTextSourcesTests` (each `ShellStrings.text` and
`hostText` literal of the sources is a catalog key) in frontend-ios. A text a language writes as English does (OK, Minus, Version)
is listed in `ShellStringsTests.cognates` and in the German and French launcher tests. `tools/tests/test_l10n_shell_catalogs.py` fails when a
committed catalog differs from what the files give, and when the app's `CFBundleLocalizations` (the Demo app, `tools/try-local`
and the shell app of the engine, patch 0056) do not list every file, because iOS offers a language to the shell only when the
app declares it. The key checks treat the `ios.*` keys as used (`catalogKeys` in `frontend/Tests/l10n-key-rules.json`).

A game's settings rows (section, label, note, option labels) are not shell texts. They come from the game's `launcher.json`,
which is English and owned by seedds/nxnative, so its format stays. The shell looks each text up in the ShellUI catalog by its
English words, and a text with no entry shows English. The catalog gets these texts from the lines the Mac launcher already
translates (`launch.section.*`, `launch.set.*`, `launch.opt.*`), so there is one translation of each. `ios.setting.*` has the
few texts upstream's `settings.tsv` words differently from the Mac's table (a semicolon in a note, for example): the English
is upstream's, the translation is the same as the Mac's. When a pin bump adds or changes a text in `dm/games/settings.tsv` or the
game language names in `dm/tools/nacp.py`, `tools/tests/test_launcher_texts.py` fails and names the text that has no Chinese
entry. Add the line to `en.json` and `zh.json` (and to the other languages that have the `launch.*` lines), run
`python3 tools/l10n_shell_catalogs.py` and `python3 tools/tests/test_launcher_texts.py --write`.

The app finds the files in `Contents/Resources/l10n` (`build-mac-app.yml` and `tools/try-local` copy the
folder there, the same way as the engine and the bundled tools, not as SwiftPM resources). `swift run` finds
`frontend/l10n` by walking up from the executable, and `swift test` takes it from the source path.
`NX_L10N_DIR` names another folder for a try-out. A missing or broken file does not stop the app: the
lookup shows the English text, then the key, and one line goes to standard error.

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

### Launcher performance test

`LauncherPerformanceTests` fails when a change makes the launcher slow. It runs in
CI with the other Swift tests. To run it alone:

```bash
swift test --package-path frontend --filter LauncherPerformanceTests
```

The test builds a synthetic library in a temporary folder. It has 30 owned games
with banners, and every third game is built. The checkout has 150 game profiles.
One game has two frame time recordings of about 3 MB together. No real game
files or keys are used. The launcher is hosted in a window and driven with the
gamepad. The test measures six interactions: a redraw of the library, the three
tab switches, opening Options and opening Manage. Each one runs five times after
a warm-up round.

There are two guards per interaction:

- Counts of work on the main thread. `LauncherWork` counts game cards built,
  Manrope fonts made, `Info.plist` reads and frame time recordings parsed. The
  counts are the same on every machine. Each budget is about twice what `main`
  does. `main` makes no new font after the warm-up, so the font budget is a
  small fixed number. A recording parsed on the main thread always fails.
- The time the main thread is busy, as the median of the five runs. The budgets
  are several times what `main` needs on the CI runner.

The test prints a table with the measured values and the budgets. A failure
names the interaction, the value, the budget and the likely cause. Most often a
view does work for every game on every redraw. Examples are an eager `HStack`
over all games, a font made per text, or a file read in a computed property.
Make that work lazy or cache it. Then profile a release build with the Time
Profiler to confirm. Raise a budget only when the launcher shows more on purpose,
and say why in the pull request. The counts exist only in debug builds, so
`LauncherWork.count` costs nothing in a release build.
