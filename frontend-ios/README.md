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
- `ShellInputLog`: an ordered, bounded log of controller presses and releases. Each `ShellInput` has an increasing sequence and the device that sent it (`InputDevice`: a controller family or the keyboard), so the library processes every event between view updates and draws that device's hints.

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
| `EngineLaunchPlan` | A pure value from a `LaunchableGame`, the app's `Resources` and `Documents` folders and the text of `Documents/env.txt` (and the game's own `Documents/games/<title ID>/env.txt`, which it reads itself and which wins over the shared one, #557, followed by build-time defaults in the selected framework's `dm/env.txt`, #719): the environment the real launcher applies with `setenv` (`DM_PROFILE`, `DM_ROMFS`, `DM_SAVE`, `DM_TEMP`, `DM_NVN_SHMAP`, `DM_MSL_DIR`, `DM_PSO_BUNDLE`, `DM_AOC_DIR`, `DM_CHEATS`, `DM_FONT_DIR`, `DM_SAVE_SYNC`, `DM_LAUNCHER=0`, the player's settings, then the keys of the env files that nothing else set, the game's Documents file first and the framework's file last, listed in `DM_ENV_FILE_KEYS`), the `dm_main` arguments (`dmhost`, `<framework>/dm`, the manifest's modules), the framework executable, the image marker, the log URL and the save and temp folders, which only `createFolders()` creates. `parseEnvFile(_:)` reads the `KEY=VALUE` lines. | `boot_env` in `dm/ios/Sources/main.m`, `docs/launcher-c-plan.md`, Environment at game start |
| `BackupExclusion` | Marks the game data in `Documents/games/<title ID>/` and the single-game names in `Documents` (`romfs*`, `aoc`, `temp`) with `isExcludedFromBackup`, so the backup does not hold many GB (#618). Saves (`save*`) and small text files stay in the backup. Runs when the shell starts, so it also marks what an earlier version left, and `EngineLaunchPlan.createFolders()` marks `temp`. | `boot_env` in `dm/ios/Sources/main.m` |
| `GameStateResolver` | Broken first, then needs app update (the manifest's `chain` differs from `HostEnvironment.chain`, or `min_os` is above the running OS), then needs game data, else playable. | the plan's playable, needsData, needsFramework and broken |
| `DataLocator` | The picked location first, then `Documents/games/<title ID>/`, each accepted only with a non-empty `romfs.img` or the manifest's `romfs_marker` (also under `romfs/`). A picked folder that lost its data falls through to the app folder. | `romfs_locate` in `dm/ios/Sources/main.m`, patch 0003's layout |
| `GameSettingsStore` | One `UserDefaults` suite per game (`dev.nx2apple.shell.game.<title ID>`), keys `launcher.<VAR>` holding strings. Only a value that differs from the tested default is stored, a saved value the game no longer offers reads as the default, and Reset forgets every saved choice. `SettingsPresenter` draws sections in the list's order and hides sub-settings (`needs`). | `dm/ios/Sources/LauncherSettings.swift` |
| `BookmarkStore` | A security-scoped bookmark in the game's suite: `pickedDataBookmark` for game data, `cloudSavesBookmark` for the cloud-save folder. Written with the picker's scope, kept only if it resolves again, scope held once resolved, a stale one reported so the shell asks again, a refreshed one rewritten. No sync logic. | `dm/ios/Sources/DataBookmark.m` |
| `FolderPicker` | `DocumentFolderPicker` is a `UIDocumentPickerViewController` for a folder, opened in place. Tests use a fake. | `DocumentPicker` in `dm/ios/Sources/Launcher.swift` |
| Log | Show log reads the tail (256 KB) of `log.txt` in the game's data folder, else the app's folder, into a read-only sheet. | |
| Update | `ShellHostConfig.updateURL` is opened by Update app. | |
| Touch controls | The Settings row opens the full-screen editor (`TouchLayoutEditorView`, #414). One draft owns global Size (`DM_TOUCH_SIZE`), stick placement (`DM_TOUCH_STICK`) and all four position variants (`DM_TOUCH_LAYOUT`). The native glass cog at the gameplay menu position contains Exit, Save and native preset/layout pickers. Exit confirms before discarding unsaved changes; Save commits. Tap a control, then drag it with quarter-key snapping; its contextual reset restores that control. Controller/keyboard and VoiceOver movement alternatives remain, without a directional-adjustment menu. Live window/hinge geometry selects the overlay or split variant while preserving all draft offsets. Red rejected moves retain the engine's boundary/collision safeguards. `PadGeo` mirrors the engine geometry and is pinned by `TouchLayoutTests`. Individual control resizing remains unsupported by the existing engine format. | `dm/ios/Sources/DmPadGeometry.h` (patches 0065, 0066, 0070) |
| Controllers | `ShellHostModel.startControllers()` runs `GamepadAdapter` and fills `controllers` (`ControllerInfo`) and `input` (`ShellInputLog`). Global mappings are stored in `ShellSettingsStore.padMap`, individual overrides in the game's suite under `GameDefaults.padMapKey`. At launch, each button resolves game > global > default and is passed to the engine as `DM_PAD_MAP`. A profile's own `DM_PAD_MAP` row takes precedence. Touch controls and shell navigation keep their original mapping. | |

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

To disable an offline pipeline archive for one game, set `DM_PSO_BUNDLE=off` in `Documents/games/<title ID>/env.txt`. The shared `Documents/env.txt` can set it for every game. An explicit launch setting wins over both files, then the game's file wins over the shared file. When none sets `DM_PSO_BUNDLE`, the shell uses the game's `pso/` folder, then the framework's `pso/` folder. This override does not diagnose or repair an incompatible archive.

Play on a playable game builds a `LaunchableGame` (title ID, name, manifest, bundle folder, framework URL, data folder, the app's `Documents/games/<title ID>/`, every `DM_*` value as a dictionary, the picked cloud-save folder) and calls `launch`. A thrown error is shown as the notice. `StubGameLauncher` only logs and throws `GameLaunchError.notAvailable` ("Launching is not available yet."). Route C's M2 (#144) plugs in the real launcher: it sets the environment from `environment` and the folders (`DM_PROFILE`, `DM_ROMFS`, `DM_SAVE`, `DM_TEMP`, `DM_SAVE_SYNC` from `cloudSavesURL`), `dlopen`s `frameworkURL` and starts the host with the manifest's modules. Nothing else in the host changes: pass it as `launcher:`. The engine and `dm/` are not part of this package.

### Host mode of the demo

`--host` runs `ShellHostView` on the fixture bundles in `Tests/ShellHostTests/Fixtures/Games` (the Xcode app carries them as its `Games` folder, the package executable takes `--games-dir <folder>`): playable, needs game data, app update (another chain and a newer OS) and broken (no framework, damaged manifest, manifest without keys, damaged settings list). They hold no game data and no pictures (`.gitignore` keeps images out, the tests draw their own). Marker files in a temporary app-data folder make most of them playable, and launching is the stub. `--select <title ID>` picks the first game. A build with `SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) HOST_DEFAULT'` starts in host mode without arguments (for installing on a device), and `--samples` brings the sample games back.

## Layouts

Only the available size decides, never the device model, idiom or orientation (`ShellLayout` in `LibraryView.swift`):

| Size | Layout |
| --- | --- |
| Compact, taller than wide (iPhone portrait, a folded foldable, Split View) | One column: the chosen game's banner edge to edge at the top, flowing into its blurred colour where the title sits, a row of wide cards, recently played, Play and the settings button at the bottom for the thumb. |
| Regular width and height, not wide (iPad portrait, an unfolded foldable held like a book) | The library alone: a collapsing pinned hero, a grid of wide cards, recently played, and the primary action at the bottom. |
| Wider than tall (iPhone and iPad landscape, an unfolded foldable on its side) | Cover Flow over the blurred banner, wide cards in a calm deck. |

The library uses a `NavigationStack` with independent native toolbar items for Controllers and app Settings. The same system bar follows the active launcher screen for Back, Close and Done, including the arrangement editor and controller dialogs. UIKit chooses horizontal or vertical bars and avoids the Duo status bar and camera. Controllers precedes app Settings as an independent item; both keep default adaptive placement in expanded portrait. In landscape Cover Flow, a native leading toolbar item contains uppercase YOUR GAMES and the selection count; Cover Flow and compact portrait library toolbars prefer a horizontal axis on iOS 27.1+. No custom side-column measurements are needed. Native toolbar geometry is registered alongside content controls for controller/keyboard focus. Gameplay controls and their saved arrangements are unchanged.

`GameLaunchActions` contains native prominent primary and compact Game Settings buttons. Inline actions size to their labels; portrait bottom rows expand the primary action. Square hero artwork is displayed beside the title over a blurred decorative backdrop. The library owns placement: portrait libraries keep their primary action in a bottom safe-area bar, while Cover Flow keeps it inline in a constrained content column. Recovery actions have no Settings companion. The game-settings sheet places playable games’ Play action in the primary toolbar as a cream icon-only button; recovery actions remain inline. The library toolbar stays mounted beneath modal sheets to preserve its safe-area geometry. Portrait bottom actions retain their inset but are hidden while a sheet owns interaction, preventing duplicate accessible Play actions. The game-settings backdrop extends behind the sheet header. The system's active division region keeps the horizontal action pair on one usable side when a vertical fold intersects it, without model or hinge-angle detection. An active horizontal division uses a native split ArrangementView: the selected hero stays in the top region, and only the lower library grid scrolls, with full-width actions pinned below it. Flat expanded portrait uses a collapsing pinned hero and the native soft scroll-edge blur. An active vertical division anchors the single continuous Cover Flow carousel in the leading usable region, with the selected game rendered once and neighboring cards tucked behind its right edge over the shared backdrop. Its actions stay beneath it; flat Cover Flow stays centered. Portrait cards retain Game Settings through a native context menu and accessibility action; Cover Flow retains its existing long press and adds the accessibility action.

Launcher menus share a native form-sized sheet with a NavigationStack. SwiftUI owns its adaptive presentation and dismissal across iPhone, iPad and Duo. Existing Back/Close/Done and controller actions retain the same state and callbacks; the system sheet drag replaces the custom overlay edge swipe. Game settings, app settings, Controllers, help, delete confirmation, choices, mapping and button test stay in this presentation. The touch-layout editor keeps its existing full-screen canvas and returns to app settings. With an active horizontal division, menus use the standard medium detent because the current runtime lets large detents span the tabletop fold; other contexts keep the large detent. Host-owned Play, log and update presentations wait for menu dismissal. Game-settings artwork and text use a horizontal-fit layout with a vertical fallback inside the sheet safe area. Constrained button-test content scrolls; controller rows stack when their horizontal content cannot fit. Gameplay controls and saved mappings are unchanged.

Choice rows with 2 to 4 short labels that fit their equal segment (`ChoicePresentation.resolve`, by option count, label length, row width and Dynamic Type) are segmented. Every other choice is a compact row (label, current value, chevron) that opens a list in the shell's own card: D-pad moves, A picks and closes, B closes without a change, touch and keyboard work the same, the current value carries a checkmark. The settings keep a non-scrolling top bar with an opaque backing that holds Library, so scrolled content never shows under it.

Controller first: the D-pad and stick move a cream focus ring, A activates, B backs out, X opens settings, Y opens controllers. In Cover Flow, left and right move the carousel by one card and the focused card is always the middle one. A hardware keyboard works the same way: arrows, Return, Escape, O for settings and Y for controllers. Touch hides the focus ring and the controller hints until the next press. Cover Flow uses one native horizontal scroll track for small and large libraries, view-aligned center snapping and scroll-position binding shared with tap/controller selection. The track extends across horizontal container safe areas so the selected cover centers on the display while toolbar items keep system reserved regions. Inline Play has modest horizontal label padding, and Game Settings uses the native circular button border. In Cover Flow the centred card is the button: a tap does what the game needs, a tap on a side card brings it to the middle, a long press opens its settings.

Manrope and its SIL OFL licence are bundled and registered at runtime, with the system font as fallback. Reduce Motion turns the Cover Flow tilt and the slides into plain crossfades. Shell strings are lines of `frontend/l10n/<code>.json` (`ios.ui.*` for ShellUI, `ios.host.*` for ShellHost), and `Resources/Localizable.xcstrings` of ShellUI and ShellHost is generated from them by `python3 tools/l10n_shell_catalogs.py`. Do not edit the catalogs by hand, see `frontend/README.md`, section "Language". Every shell text has all seven languages, and the tests fail otherwise. `ShellTextsCaptureTests` renders the library in each state, a game's settings, the help cards, Controllers and Cover Flow from the fixture games in one language (`NX_SHELL_CAPTURE_DIR`, `NX_SHELL_CAPTURE_LANG`). The rows of a game's settings screen come from its English `launcher.json`: `SettingRow`, `SettingOption` and `SettingSection` look their texts up in the ShellUI catalog by the English words (`ShellStrings.setting`), and a text with no entry stays English. The catalog has the `launch.*` texts of the Mac launcher for this, and `tools/tests/test_launcher_texts.py` fails with the missing text when a pin bump brings a new one.

## Demo

The test launcher uses one nine-game Nintendo metadata catalog. Installed versions, readiness and play history are simulated. Public cover art and app icons are supplied locally in the ignored `Demo/ReviewCatalog/` folder; metadata-only builds use the same Nintendo titles with standard artwork placeholders. Fictional launcher catalogs and legacy artwork switches have been removed. Separate host-test fixtures remain for automated tests.

Other launch arguments: `--screen library|settings|needs-data|needs-update|broken|empty|controllers|controllers-empty|controllers-mapping|controllers-test|focus`, `--games <n>`, `--select <id>`, `--input-test` (on-screen controller buttons) and `--fold-test` (the foldable stand-in: the running shell in a frame that switches between a 1.4:1 folded size and a larger unfolded one, `--unfolded` to start open).

The bundled `Resources/catalog.json` is the metadata source. A local `ReviewCatalog/` also contains its public image files. `--review-catalog /absolute/path/catalog.json` can point at that same catalog for development; malformed input reports an error rather than substituting another catalog. No game data is bundled.

`UITests/` checks navigation, controller input, setting edits, rotation and the fold. `ShellCaptureTests` captures every screen; `TEST_RUNNER_SHOT_DIR` also writes its PNGs to that folder.

Cover Flow selection details use a 240 ms native blur-replace transition, independent of the action row. Play and Game Settings retain their identity between playable games; action-state changes crossfade. The existing 450 ms backdrop fade starts 120 ms later so content leads the background. Reduce Motion disables the new content effects and backdrop delay.

Cover Flow retains input-device glyph hints in a bottom safe-area inset, including compact native-toolbar and divided layouts. Folded hints stay within the leading usable region; narrow containers stack the hints. Touch continues to hide hints until the next controller/key input.

Flat Cover Flow centers the artwork and details as a combined composition, sizes the focused card from available height and container width, and retains status/version above the separated action row. Text transitions are animated by a stable parent container, rather than the replaced child.

Cover Flow uses a shared expanded artwork size across flat and vertically divided poses, while its focus anchor changes. The composition centers in the available content area. Playable status text is omitted by StatusLabel because the Play action and artwork dot already express readiness; non-playable statuses and accessibility state descriptions remain.

Both Cover Flow poses now share the same intrinsic details stack. Native center alignment centers the actual visible composition; no estimated details-height spacer or manual top offset positions it.

Game settings reveal a native inline navigation title containing only the game name after the hero leaves the scroll viewport. Returning to the hero hides the duplicate title; nested destinations do not inherit it.

Final Cover Flow balance centers the artwork with title/version; the action row sits beneath that group. Hints overlay the bottom without shifting that center. This supersedes centering either the artwork alone or the complete action composition.

Cover Flow displays version metadata in a top-leading artwork chip beside the state dot, styled like the state-dot backing. The chip displays the raw version number without a localized prefix. Version is omitted beneath the selected title and included in the card accessibility label. Other library/detail contexts retain their metadata placement.

Compact portrait uses a native bottom safeAreaBar with a horizontally expanded action container, while the scroll content retains its original safe width. Hero decoration bleeds horizontally behind the rail without expanding interactive library content. The bottom bar remains above the home indicator.

Compact portrait library toolbar items prefer the horizontal axis, like Cover Flow; native menus keep their own toolbar behavior. The compact library scroll can fill the horizontally expanded container. Bottom system safe area and the action row’s 8 pt bottom padding remain.

Tabletop fades the primary artwork backdrop to black above the black lower grid. Your Games is a pinned native top safeAreaBar for the lower grid, registering the existing soft scroll-edge effect at the boundary; hero and primary actions remain stationary.

Expanded portrait and tabletop grids pin the Your Games heading with primary foreground text over regular system material. Its background fades above and below the heading, avoiding a hard rectangular divider while preserving the native soft scroll edge.

Cover Flow and library cards display Missing Data, Update Required or Fix Game Files with the state dot in one solid-black outlined artwork chip. Their duplicate text outside the artwork is omitted; recovery CTAs and hero/settings warnings retain their existing behavior. Chip labels are localized through frontend/l10n.

Expanded portrait keeps its Play/recovery action row in the bottom safeAreaBar, matching tabletop placement. The collapsing hero has no duplicate action row. This shared expanded-portrait policy also applies to regular-width iPad layouts.

Current grid design: one native soft scroll-edge effect with a plain pinned heading, no masked material band. Expanded portrait and tabletop use a black grid surface; blurred hero artwork fades to black at its bottom. Tabletop centers enlarged artwork above centered text within the native primary region. Version appears before the recent-play/status eyebrow row, above the title.

Native bars follow the proposal in #695, related to #622, replacing the custom column introduced by #633. The branch is integrated with main's launch-preparation feedback, backup exclusion and RomFS language discovery; the native presentation changes do not replace those host behaviors.

Tapping a portrait tile uses a native center scroll anchor, subject to collection boundaries. Portrait hero artwork and text share Cover Flow's 240 ms blur-replacement transition, disabled for Reduce Motion. Action controls retain identity between playable games and transition only when the action changes.

In tabletop, ArrangementView content respects the top toolbar safe area while the decorative hero backdrop extends behind it. The hero centers above a Your Games/count footer in the primary region. The lower region begins with the independently scrolling grid, native soft scroll-edge effect and a dark masked ultra-thin material blur that fades in proportionally with scroll distance, with the automatic top edge effect disabled only in tabletop; its bottom actions remain pinned.

Launcher action rows use a persistent primary native glass-prominent Button and an optional native glass Settings Button in a GlassEffectContainer. Stable primary/settings effect IDs coordinate native matched-geometry insertion/removal and animated bounds changes; label content crossfades without the artwork/title blur. PortraitLibrary owns the namespace/container across its adaptive bottom-row layouts, while standalone rows own a local container. Reduce Motion uses identity glass transitions and no app-authored row animation. The supported package minimum is iOS/macOS 26, so no older-OS fallback is needed.

Tabletop game-settings sheets omit the duplicated artwork/version hero because the primary region retains that context. Native inline navigation title/subtitle show the game name and localized GAME SETTINGS between Close and Play. Other poses retain the sheet hero and reveal the game-name title only when that hero scrolls away.

Every portrait library readiness state now uses the same bottom Liquid Glass action row, including compact iPhone/outer-display layouts. Recovery actions no longer move into the hero; playable games alone include the Settings circle.

Controller rows retain a horizontal layout at standard text sizes, truncating only the visible name while preserving the complete name for accessibility. Accessibility text sizes wrap names and place the battery below. Charging is centered over the battery body; the fill and percentage still reflect actual charge and VoiceOver announces Charging.

Cover Flow previews the nearest game during dragging/deceleration, then aligns its scroll ID at idle without a second animated recenter. Content blur, action morph and card movement use shorter Cover Flow-specific timings; the background starts 40 ms later and fades over 220 ms. Moving-card taps remain guarded and controller/programmatic scrolls do not change selection from geometry callbacks.

The full-screen touch editor uses a dedicated native hosting controller: standard iPhones and the Duo outer display open landscape-only; iPad and recognized Duo inner displays retain adaptive rotation. Closing the editor releases that policy so portrait browsing remains available. No portrait rotate-instruction preview is presented. The editor labels its settings Global defaults; game/configuration overrides remain intact. Its idle cream cog halo pulses every two seconds and respects Reduce Motion.

App Settings uses a native grouped Form with Section headers/footers, folder actions in LabeledContent rows, a dedicated Touch controls disclosure row, and a native cream-tinted switch. The sheet retains native safe areas and dark appearance; its existing actions, editor presentation and controller targets remain.

Saving touch controls saves the 2D/3D global starting layout only when the final mode differs from the session's initial mode. Unchanged, size-only, arrangement-only, and pose-only saves preserve an unset preference so each game's profile still supplies its starting layout. Editor entry restores an explicit preference, and launch supplies DM_PROF_PAD_LAYOUT for games without a more specific choice. Existing game-saved layouts and explicit overrides remain authoritative. Geometry chooses split/overlay independently of the saved 2D/3D preference.
