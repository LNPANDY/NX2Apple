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

## Integrate

All boundary types are in `Sources/ShellUI/ShellInputs.swift` and `ShellArtwork.swift`:

- `GameTile` and `GameDetail`: title, a short subtitle, the 16:9 banner, the optional square icon, state, recent-play text, settings, game-data source, cloud saves and additional content.
- `Artwork`: a picture decoded once by the host, from file bytes (`Artwork(id:data:)`) or a `CGImage`. The banner is the game's 16:9 key art, the eShop banner the Mac launcher caches per title ID. Covers, Cover Flow cards and the hero all use it. Without a banner the square NACP icon is shown whole inside the 16:9 card on a blurred copy of itself, never stretched. Without either, a calm placeholder is drawn from the title.
- `GameState`: playable, needs game data, needs an app update, or broken with a reason.
- `SettingSection`, `SettingRow`, `SettingKind`, `SettingOption`: ordered toggle, choice and range rows with string values, as in launcher.json. The caller resolves dependencies, defaults and locked rows (`enabled`).
- `ControllerInfo`: a connected controller, its player and an optional battery level.
- `ShellActions`: selection, Play, setting changes, game-data and cloud-folder requests, reset, log, app update and Back. The game ID is always passed.
- `ShellInput`: an optional semantic controller event with an increasing sequence and the device that sent it (`InputDevice`: a controller family or the keyboard), so the hints draw that device's glyphs.

`ShellControllers` is a separate library target, not part of the views: `GamepadAdapter` reads every GameController controller (D-pad and left stick with a deadzone and the Mac's repeat on hold, A activates, B goes back, X and Menu open game settings, Y opens Controllers, by label so each family confirms with its own button) and reports `ShellInput` actions and the connected controllers with their battery. Its pure mapping (`PadMapper`, `RepeatTiming`) is unit tested. The demo uses it, the real shell can too.

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
| `GameStateResolver` | Broken first, then needs app update (the manifest's `chain` differs from `HostEnvironment.chain`, or `min_os` is above the running OS), then needs game data, else playable. | the plan's playable, needsData, needsFramework and broken |
| `DataLocator` | The picked location first, then `Documents/games/<title ID>/`, each accepted only with a non-empty `romfs.img` or the manifest's `romfs_marker` (also under `romfs/`). A picked folder that lost its data falls through to the app folder. | `romfs_locate` in `dm/ios/Sources/main.m`, patch 0003's layout |
| `GameSettingsStore` | One `UserDefaults` suite per game (`dev.nx2apple.shell.game.<title ID>`), keys `launcher.<VAR>` holding strings. Only a value that differs from the tested default is stored, a saved value the game no longer offers reads as the default, and Reset forgets every saved choice. `SettingsPresenter` draws sections in the list's order and hides sub-settings (`needs`). | `dm/ios/Sources/LauncherSettings.swift` |
| `BookmarkStore` | A security-scoped bookmark in the game's suite: `pickedDataBookmark` for game data, `cloudSavesBookmark` for the cloud-save folder. Written with the picker's scope, kept only if it resolves again, scope held once resolved, a stale one reported so the shell asks again, a refreshed one rewritten. No sync logic. | `dm/ios/Sources/DataBookmark.m` |
| `FolderPicker` | `DocumentFolderPicker` is a `UIDocumentPickerViewController` for a folder, opened in place. Tests use a fake. | `DocumentPicker` in `dm/ios/Sources/Launcher.swift` |
| Log | Show log reads the tail (256 KB) of `log.txt` in the game's data folder, else the app's folder, into a read-only sheet. | |
| Update | `ShellHostConfig.updateURL` is opened by Update app. | |
| Controllers | `ShellHostModel.startControllers()` runs `GamepadAdapter` and fills `controllers` (`ControllerInfo`) and `input` (`ShellInput`). | |

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

`--host` runs `ShellHostView` on the fixture bundles in `Tests/ShellHostTests/Fixtures/Games` (the Xcode app carries them as its `Games` folder, the package executable takes `--games-dir <folder>`): playable, needs game data, app update (another chain and a newer OS) and broken (no framework, damaged manifest, manifest without keys, damaged settings list). They hold no game data and no pictures (`.gitignore` keeps images out, the tests draw their own). Marker files in a temporary app-data folder make most of them playable, and launching is the stub. `--select <title ID>` picks the first game.

## Layouts

Only the available size decides, never the device model, idiom or orientation (`ShellLayout` in `LibraryView.swift`):

| Size | Layout |
| --- | --- |
| Compact, taller than wide (iPhone portrait, a folded foldable, Split View) | One column: the chosen game's banner edge to edge at the top, flowing into its blurred colour where the title sits, a row of wide cards, recently played, Play and the settings button at the bottom for the thumb. Settings, when asked for, take the whole screen. |
| Regular width and height, not wide (iPad portrait, an unfolded foldable held like a book) | The library alone: the same hero with Play and the settings button in it, a grid of wide cards, recently played. Settings, when asked for, float in as a panel from the right over the dimmed library. |
| Wider than tall (iPhone and iPad landscape, an unfolded foldable on its side) | Cover Flow over the blurred banner, wide cards in a calm deck. Settings, when asked for, float in as the same panel (regular) or take the whole screen (compact). |

Settings appear only when asked for (the settings button, X on a controller) and close with Back, B or a tap outside. They are one view in one place for every layout, with the game's banner as their header, so the selected game, open settings and both scroll positions survive a fold, a rotation or a Stage Manager resize.

Controller first: the D-pad and stick move a cream focus ring, A activates, B backs out, X opens settings, Y opens controllers. In Cover Flow, left and right move the carousel by one card and the focused card is always the middle one. A hardware keyboard works the same way: arrows, Return, Escape, O for settings and Y for controllers. Touch hides the focus ring and the controller hints until the next press. In Cover Flow the centred card is the button: a tap does what the game needs, a tap on a side card brings it to the middle, a long press opens its settings.

Manrope and its SIL OFL licence are bundled and registered at runtime, with the system font as fallback. Reduce Motion turns the Cover Flow tilt and the slides into plain crossfades. Shell strings are in `Resources/Localizable.xcstrings`.

## Demo

Seven sample games. With `--real-art` the demo reads real Switch art at runtime from where the Mac launcher keeps it: the banner cache in the host's `~/Library/Application Support/NS Port Builder/artwork/<TITLEID>.jpg` and this checkout's `docs/images`, which the Simulator can read. `--art-dir <folder>` (repeatable) names other folders. A sample entry whose art is found becomes that real game (name and title ID in `SampleData.swift`). Without the files every entry stays fictional, with a square icon drawn in `SampleArt.swift`, so the demo and its tests work on any machine. No picture is part of this package, and `.gitignore` keeps them out.

Other launch arguments: `--screen library|settings|needs-data|needs-update|broken|empty|controllers|controllers-empty|focus`, `--games <n>`, `--select <id>`, `--input-test` (on-screen controller buttons) and `--fold-test` (the foldable stand-in: the running shell in a frame that switches between a 1.4:1 folded size and a larger unfolded one, `--unfolded` to start open).

`UITests/` checks navigation, controller input, setting edits, rotation and the fold. `ShellCaptureTests` captures every screen. With `TEST_RUNNER_SHOT_DIR` set it also writes the PNGs to that folder, and `TEST_RUNNER_SHOT_REAL_ART=1` launches the demo with `--real-art`.
