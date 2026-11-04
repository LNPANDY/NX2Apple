# iOS shell views

A Swift 6 package for iOS and iPadOS 26 and later. `ShellUI` is the view layer of the multi-game shell described in Route C (#144). It renders what it is given and reports what the player does. It has no engine dependency, game launching, storage, document picker, networking or game-file access. `ShellHost` is the layer behind it that does those things.

## Run

```sh
swift build --package-path frontend-ios
swift test --package-path frontend-ios
open frontend-ios/Demo/ShellDemo.xcodeproj
```

Select the `ShellDemo` scheme and an iOS Simulator. After changing targets, regenerate the project with `xcodegen generate --spec frontend-ios/Demo/project.yml`. A command-line build:

```sh
xcodebuild -project frontend-ios/Demo/ShellDemo.xcodeproj -scheme ShellDemo \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/shell-demo build
```

`ShellDemo` is also an executable package target for previews on the Mac. The Xcode app target is `ShellDemoApp`.

The app icon of the demo app and of the shell app (`dm/ios/project-shell.yml`) is `frontend-ios/AppIcon.icon`. It is edited in Icon Composer.

## Integrate

All boundary types are in `Sources/ShellUI/ShellInputs.swift` and `ShellArtwork.swift`:

- `GameTile` and `GameDetail`: title, a short subtitle, the 16:9 banner, the optional square icon, state, recent-play text, settings, game-data source, cloud saves and additional content.
- `Artwork`: a picture decoded once by the host, from file bytes (`Artwork(id:data:)`) or a `CGImage`. The banner is the game's 16:9 key art, the eShop banner the Mac launcher caches per title ID. Covers, Cover Flow cards and the hero all use it. Without a banner the square NACP icon is shown whole inside the 16:9 card on a blurred copy of itself, never stretched. Without either, a calm placeholder is drawn from the title.
- `GameState`: playable, needs game data, needs an app update, or broken with a reason.
- `SettingSection`, `SettingRow`, `SettingKind`, `SettingOption`: ordered toggle, choice and range rows with string values, as in launcher.json. The caller resolves dependencies, defaults and locked rows (`enabled`).
- `ControllerInfo`: a connected controller, its player and an optional battery level.
- `ShellActions`: selection, Play, setting changes, game-data and cloud-folder requests, reset, log, app update and Back. The game ID is always passed.
- `ShellInput`: an optional semantic controller event with an increasing sequence and the device that sent it (`InputDevice`: a controller family or the keyboard), so the hints draw that device's glyphs.

`ShellControllers` is a separate library target, not part of the views: `GamepadAdapter` reads every GameController controller (D-pad and left stick with a deadzone and the Mac's repeat on hold, A activates, B goes back, X and Menu open game settings, Y opens Controllers, by label so each family confirms with its own button) and reports `ShellInput` actions and the connected controllers with their battery. Its pure mapping (`PadMapper`, `RepeatTiming`) is unit tested. The Controllers page also opens a Button mapping card for all games: on top the button test's controller drawing with the Switch names of its places, where a tap on a button opens its choices, a cream ring marks a changed button and a button held on a connected controller lights up, then Swap A and B as a segmented choice, then the 16 buttons in four groups (face buttons, shoulders and triggers, D-pad, more), each row the button's glyph, where it sits and what it sends, with a cream dot on a row that differs and Reset in a footer that does not scroll. The buttons are named as on a Switch controller, by position, as the engine maps every controller. A row picked shows the buttons it can send as a grid of glyphs, and None. These affect games only. Its Button test card draws an Xbox-style controller and lights up each button, trigger and stick of the controller that moved as it is pressed (hold B to close), and forgets a controller that disconnects. Shell menus keep A to confirm and B to go back. Each game's settings have one Button mapping row that opens the same card for that game, which can follow all games, override single buttons, turn a button off, or explicitly keep A and B unswapped. `PadMappingCaptureTests` renders these views on the Mac (`NX_SHELL_CAPTURE_DIR`, `NX_SHELL_CAPTURE_LANG`). The demo uses it, the real shell can too.

```swift
LibraryView(
    games: details,
    controllers: controllers,
    actions: ShellActions(onPlay: { id in /* launch */ },
                          onChange: { gameID, settingID, value in /* store */ }),
    input: latestInput
)
```

The caller returns changed values through `games`. The views keep no second copy.

## Host

`ShellHost` is a library for the real shell app and the demo. It turns real files into the view values and acts on `ShellActions`. `ShellUI` stays view-only. Main types: `ShellHostModel` (the `@Observable` model, its `actions` go to `LibraryView`) and `ShellHostView` (`LibraryView` on a model, plus the log sheet and a notice alert).

| Part | What it does | Mirrors |
| --- | --- | --- |
| `GameCatalogue` | Scans `Games/<title ID>/`: `game.manifest.json` (schema 1, `GameManifest`), `launcher.json` (`LauncherProfile`, `docs/launcher.schema.json`, also read from `<framework>/<manifest.launcher>`), the manifest's `.framework` folder, optional `banner.<ext>` and `icon.<ext>`. A bundle that cannot be read stays in the list as broken with a readable reason (manifest missing, damaged or of another schema, framework missing, settings list damaged, folder and title ID disagree). | `docs/launcher-c-plan.md`, Manifest and Discovery |
| `GameCatalogue` (frameworks) | In the shell app the games are the embedded frameworks: `scan(root:)` also reads every `<Name>.framework` folder (pass `Bundle.main.privateFrameworksURL`). A framework without `game.manifest.json` is skipped silently. Otherwise the entry's ID is the manifest's `title_id` (the folder name without `.framework` when the manifest cannot be read), and `directory` and `frameworkURL` are the framework folder. `launcher.json` comes from `<manifest.launcher>`, else the framework's top level, and `banner.<ext>` and `icon.<ext>` from inside the framework. A manifest whose `framework` differs from the folder name is broken (Game files damaged). Of two frameworks with one title ID the first by name is kept and the second is broken, listed under its folder name. `CatalogueEntry.frameworkURL` is a stored property set by both readers. | `docs/launcher-c-plan.md`, Manifest |
| `EngineLaunchPlan` | A pure value from a `LaunchableGame`, the app's `Resources` and `Documents` folders and the text of `Documents/env.txt` (and the game's own `Documents/games/<title ID>/env.txt`, which it reads itself and which wins over the shared one, #557): the environment the real launcher applies with `setenv` (`DM_PROFILE`, `DM_ROMFS`, `DM_SAVE`, `DM_TEMP`, `DM_NVN_SHMAP`, `DM_MSL_DIR`, `DM_PSO_BUNDLE`, `DM_AOC_DIR`, `DM_CHEATS`, `DM_FONT_DIR`, `DM_SAVE_SYNC`, `DM_LAUNCHER=0`, the player's settings, then the keys of the two env files that nothing else set, the game's file first, listed in `DM_ENV_FILE_KEYS`), the `dm_main` arguments (`dmhost`, `<framework>/dm`, the manifest's modules), the framework executable, the image marker, the log URL and the save and temp folders, which only `createFolders()` creates. `parseEnvFile(_:)` reads the `KEY=VALUE` lines. | `boot_env` in `dm/ios/Sources/main.m`, `docs/launcher-c-plan.md`, Environment at game start |
| `BackupExclusion` | Marks the game data in `Documents/games/<title ID>/` and the single-game names in `Documents` (`romfs*`, `aoc`, `temp`) with `isExcludedFromBackup`, so the backup does not hold many GB (#618). Saves (`save*`) and small text files stay in the backup. Runs when the shell starts, so it also marks what an earlier version left, and `EngineLaunchPlan.createFolders()` marks `temp`. | `boot_env` in `dm/ios/Sources/main.m` |
| `GameStateResolver` | Broken first, then needs app update (the manifest's `chain` differs from `HostEnvironment.chain`, or `min_os` is above the running OS), then needs game data, else playable. | the plan's playable, needsData, needsFramework and broken |
| `DataLocator` | The picked location first, then `Documents/games/<title ID>/`, each accepted only with a non-empty `romfs.img` or the manifest's `romfs_marker` (also under `romfs/`). A picked folder that lost its data falls through to the app folder. | `romfs_locate` in `dm/ios/Sources/main.m`, patch 0003's layout |
| `GameSettingsStore` | One `UserDefaults` suite per game (`dev.nx2apple.shell.game.<title ID>`), keys `launcher.<VAR>` holding strings. Only a value that differs from the tested default is stored, a saved value the game no longer offers reads as the default, and Reset forgets every saved choice. `SettingsPresenter` draws sections in the list's order and hides sub-settings (`needs`). | `dm/ios/Sources/LauncherSettings.swift` |
| `BookmarkStore` | A security-scoped bookmark in the game's suite: `pickedDataBookmark` for game data, `cloudSavesBookmark` for the cloud-save folder. Written with the picker's scope, kept only if it resolves again, scope held once resolved, a stale one reported so the shell asks again, a refreshed one rewritten. No sync logic. | `dm/ios/Sources/DataBookmark.m` |
| `FolderPicker` | `DocumentFolderPicker` is a `UIDocumentPickerViewController` for a folder, opened in place. Tests use a fake. | `DocumentPicker` in `dm/ios/Sources/Launcher.swift` |
| Log | Show log reads the tail (256 KB) of `log.txt` in the game's data folder, else the app's folder, into a read-only sheet. | |
| Update | `ShellHostConfig.updateURL` is opened by Update app. | |
| Touch controls | The shell settings' Touch controls group, for every game: a preview of the controls on a phone held sideways (`TouchControlsPreview`, which mirrors the engine's `DmPadGeometry.h` for that screen) the Size row (small, medium, large) and the Left stick row (corner, higher, inward, the preview marks the default place with a dashed ring). `ShellSettingsStore.touchSize` and `touchStick` store them, and `gameDefaults` passes them to the engine as `DM_TOUCH_SIZE` and `DM_TOUCH_STICK` (medium and the corner are the engine's own and are not passed). The engine keeps a choice off a screen too small for it. Every game also gets `DM_TOUCH_HINT`, the words the engine shows once per launch where the 3D layout's undrawn right stick is (`ios.host.touchHint`). Every game gets the quit prompt's words as `DM_HOME_QUIT_TEXT` (`ios.host.quit*`, five lines in `home_quit.h`'s order, as the Mac launcher passes them): the engine shows the prompt when the player picks Quit in the in-game menu (the gear) or holds a controller's Home button. The Arrangement row opens the layout editor (`TouchLayoutEditorView`, #414): the controls of one layout (2D or 3D, over the picture, and on an iPad or a foldable also below it) on this device's screen, dragged in steps of a quarter key, or chosen and moved with the arrows, a controller (A picks up, the D-pad moves, A or B puts down) or VoiceOver's actions, with Reset this control and Reset all controls (which asks first, in place, and starts on Cancel). Held sideways the preview takes the room left of a column that scrolls, with the arrows in one row. A spot the engine would refuse (on another control, outside the area) turns red and sends the control back. `TouchLayout` holds the offsets and writes the engine's value, `ShellSettingsStore.touchLayout` stores it and `gameDefaults` passes it as `DM_TOUCH_LAYOUT` (nothing moved: not passed). `PadGeo` is a Swift copy of the engine's geometry, pinned to the engine's points by `TouchLayoutTests`, so the editor keeps only what the engine draws. `TouchControlsCaptureTests` renders the group and the editor on the Mac. | `dm/ios/Sources/DmPadGeometry.h`, `quit_prompt.h` (patches 0065 to 0068, 0070) |
| Controllers | `ShellHostModel.startControllers()` runs `GamepadAdapter` and fills `controllers` (`ControllerInfo`) and `input` (`ShellInput`). Global mappings are stored in `ShellSettingsStore.padMap`, individual overrides in the game's suite under `GameDefaults.padMapKey`. At launch, each button resolves game > global > default and is passed to the engine as `DM_PAD_MAP`. A profile's own `DM_PAD_MAP` row takes precedence. Touch controls and shell navigation keep their original mapping. | |

```swift
let config = ShellHostConfig(gamesRoot: gamesURL, appDataRoot: ShellHostConfig.defaultAppDataRoot(),
                             environment: HostEnvironment(chain: dmshChain))
let model = ShellHostModel(config: config, launcher: StubGameLauncher(), picker: DocumentFolderPicker())
ShellHostView(model: model)
```

### Launching: the `GameLauncher` seam

```swift
public protocol GameLauncher: Sendable { @MainActor func launch(_ game: LaunchableGame) async throws }
```

Play on a playable game builds a `LaunchableGame` (title ID, name, manifest, bundle folder, framework URL, data folder, the app's `Documents/games/<title ID>/`, every `DM_*` value as a dictionary, the picked cloud-save folder) and calls `launch`. A thrown error is shown as the notice. `StubGameLauncher` only logs and throws `GameLaunchError.notAvailable` ("Launching is not available yet."). Route C's M2 (#144) plugs in the real launcher: it sets the environment from `environment` and the folders (`DM_PROFILE`, `DM_ROMFS`, `DM_SAVE`, `DM_TEMP`, `DM_SAVE_SYNC` from `cloudSavesURL`), `dlopen`s `frameworkURL` and starts the host with the manifest's modules. Nothing else in the host changes: pass it as `launcher:`. The engine and `dm/` are not part of this package.

### Host mode of the demo

`--host` runs `ShellHostView` on the fixture bundles in `Tests/ShellHostTests/Fixtures/Games` (the Xcode app carries them as its `Games` folder, the package executable takes `--games-dir <folder>`): playable, needs game data, app update (another chain and a newer OS) and broken (no framework, damaged manifest, manifest without keys, damaged settings list). They hold no game data and no pictures (`.gitignore` keeps images out, the tests draw their own). Marker files in a temporary app-data folder make most of them playable, and launching is the stub. `--select <title ID>` picks the first game. A build with `SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) HOST_DEFAULT'` starts in host mode without arguments (for installing on a device), and `--samples` brings the sample games back.

## Layouts

Only the available size decides, never the device model, idiom or orientation (`ShellLayout` in `LibraryView.swift`):

| Size | Layout |
| --- | --- |
| Compact, taller than wide (iPhone portrait, a folded foldable, Split View) | One column: the chosen game's banner edge to edge at the top, flowing into its blurred colour where the title sits, a row of wide cards, recently played, Play and the settings button at the bottom for the thumb. Settings, when asked for, take the whole screen. |
| Regular width and height, not wide (iPad portrait, an unfolded foldable held like a book) | The library alone: the same hero with Play and the settings button in it, a grid of wide cards, recently played. Settings, when asked for, float in as a panel from the right over the dimmed library. |
| Wider than tall (iPhone and iPad landscape, an unfolded foldable on its side) | Cover Flow over the blurred banner, wide cards in a calm deck. Settings, when asked for, float in as the same panel (regular) or take the whole screen (compact). |

iPhone Duo keeps a column on one side for the status bar and the system's vertical bars (#622). Where the system names that edge (`toolbarVerticalEdge`, iOS 27.1) and the column is wide enough, the shell's own bar moves into the column. The Controllers and Settings chips sit at its bottom, above the home indicator. The game settings button sits at the top of its free part, so Play has the bottom bar to itself, and while a game's settings are open Back takes that place. Every chip stays clear of the occluded areas (`reservedRegions(kind: .occlusion)`), which in the iPhone Duo Simulator include the status bar and the camera in every pose. Where the column has no occluded area, nothing reports the status bar, so the top stays empty and the chips stay in the lower half. Upright, the inner display has a status bar at the top and no column, so nothing changes there. Everywhere else nothing changes either (`SideBar`, tested in `SideBarTests` with the values the Simulator reported, rendered on a simulated outer display by `SideBarCaptureTests`). A shell built with an SDK older than iOS 27.1 keeps the chips in the header.

Settings appear only when asked for (the settings button, X on a controller) and close with Back, B or a tap outside. They are one view in one place for every layout, with the game's banner as their header, so the selected game, open settings and both scroll positions survive a fold, a rotation or a Stage Manager resize.

Choice rows with 2 to 4 short labels that fit their equal segment (`ChoicePresentation.resolve`, by option count, label length, row width and Dynamic Type) are segmented. Every other choice is a compact row (label, current value, chevron) that opens a list in the shell's own card: D-pad moves, A picks and closes, B closes without a change, touch and keyboard work the same, the current value carries a checkmark. The settings keep a non-scrolling top bar with an opaque backing that holds Library, so scrolled content never shows under it.

Controller first: the D-pad and stick move a cream focus ring, A activates, B backs out, X opens settings, Y opens controllers. In Cover Flow, left and right move the carousel by one card and the focused card is always the middle one. A hardware keyboard works the same way: arrows, Return, Escape, O for settings and Y for controllers. Touch hides the focus ring and the controller hints until the next press. In Cover Flow the centred card is the button: a tap does what the game needs, a tap on a side card brings it to the middle, a long press opens its settings.

Manrope and its SIL OFL licence are bundled and registered at runtime, with the system font as fallback. Reduce Motion turns the Cover Flow tilt and the slides into plain crossfades. Shell strings are lines of `frontend/l10n/<code>.json` (`ios.ui.*` for ShellUI, `ios.host.*` for ShellHost), and `Resources/Localizable.xcstrings` of ShellUI and ShellHost is generated from them by `python3 tools/l10n_shell_catalogs.py`. Do not edit the catalogs by hand, see `frontend/README.md`, section "Language". Every shell text has all six languages, and the tests fail otherwise. `ShellTextsCaptureTests` renders the library in each state, a game's settings, the help cards, Controllers and Cover Flow from the fixture games in one language (`NX_SHELL_CAPTURE_DIR`, `NX_SHELL_CAPTURE_LANG`). The rows of a game's settings screen come from its English `launcher.json`: `SettingRow`, `SettingOption` and `SettingSection` look their texts up in the ShellUI catalog by the English words (`ShellStrings.setting`), and a text with no entry stays English. The catalog has the `launch.*` texts of the Mac launcher for this, and `tools/tests/test_launcher_texts.py` fails with the missing text when a pin bump brings a new one.

## Demo

Seven sample games. With `--real-art` the demo reads real Switch art at runtime from where the Mac launcher keeps it: the banner cache in the host's `~/Library/Application Support/NS Port Builder/artwork/<TITLEID>.jpg` and this checkout's `docs/images`, which the Simulator can read. `--art-dir <folder>` (repeatable) names other folders. A sample entry whose art is found becomes that real game (name and title ID in `SampleData.swift`). Without the files every entry stays fictional, with a square icon drawn in `SampleArt.swift`, so the demo and its tests work on any machine. No picture is part of this package, and `.gitignore` keeps them out.

Other launch arguments: `--screen library|settings|needs-data|needs-update|broken|empty|controllers|controllers-empty|controllers-mapping|controllers-test|focus`, `--games <n>`, `--select <id>`, `--input-test` (on-screen controller buttons) and `--fold-test` (the foldable stand-in: the running shell in a frame that switches between a 1.4:1 folded size and a larger unfolded one, `--unfolded` to start open).

`UITests/` checks navigation, controller input, setting edits, rotation and the fold. `ShellCaptureTests` captures every screen. With `TEST_RUNNER_SHOT_DIR` set it also writes the PNGs to that folder, and `TEST_RUNNER_SHOT_REAL_ART=1` launches the demo with `--real-art`.
