# iOS shell views

A Swift 6 package for iOS and iPadOS 26 and later. `ShellUI` is the view layer of the multi-game shell described in Route C (#144). It renders what it is given and reports what the player does. It has no engine dependency, game launching, storage, document picker, networking or game-file access.

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

- `GameTile` and `GameDetail`: title, a short subtitle, the cover, optional wider hero art, state, recent-play text, settings, game-data source, cloud saves and additional content.
- `Artwork`: a picture decoded once by the host, from the NACP icon's bytes (`Artwork(id:data:)`) or a `CGImage`. The views draw it and make their blurred backdrops from a small copy. Without one, a calm placeholder is drawn from the title.
- `GameState`: playable, needs game data, needs an app update, or broken with a reason.
- `SettingSection`, `SettingRow`, `SettingKind`, `SettingOption`: ordered toggle, choice and range rows with string values, as in launcher.json. The caller resolves dependencies, defaults and locked rows (`enabled`).
- `ControllerInfo`: a connected controller, its player and an optional battery level.
- `ShellActions`: selection, Play, setting changes, game-data and cloud-folder requests, reset, log, app update and Back. The game ID is always passed.
- `ShellInput`: an optional semantic controller event with an increasing sequence. Hardware belongs to the caller. The demo's `DemoControllerInput` is one such adapter.

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

## Layouts

Only the available size decides, never the device model, idiom or orientation (`ShellLayout` in `LibraryView.swift`):

| Size | Layout |
| --- | --- |
| Compact, taller than wide (iPhone portrait, a folded foldable, Split View) | One column: the chosen game's art as a full-bleed hero with the title over it, a row of covers, recently played, Play and settings at the bottom for the thumb. Settings push over the library. |
| Regular width and height, not wide (iPad portrait, an unfolded foldable held like a book) | Two panes: the same library with a cover grid and Play in the hero, settings inline beside it. |
| Wider than tall (iPhone and iPad landscape, an unfolded foldable on its side) | Cover Flow over the blurred cover. Settings open as a panel on the right (regular) or over the library (compact). |

The settings pane is one view in one place for every layout, so the selected game, open settings and both scroll positions survive a fold, a rotation or a Stage Manager resize.

Controller first: the D-pad and stick move a cream focus ring, A activates, B backs out, X opens settings, Y opens controllers. In Cover Flow, left and right move the carousel by one cover and the focused cover is always the middle one. Keyboard arrows, Return and Escape take the same path. Touch and pointer use ordinary controls.

Manrope and its SIL OFL licence are bundled and registered at runtime, with the system font as fallback. Reduce Motion turns the Cover Flow tilt and the slides into plain crossfades. Shell strings are in `Resources/Localizable.xcstrings`.

## Demo

Seven fictional games with their own drawn cover art (`Sources/ShellDemo/SampleArt.swift`, rendered to images at launch so the views get them exactly as real icons). Launch arguments: `--screen library|settings|needs-data|needs-update|broken|empty|controllers|controllers-empty|focus`, `--games <n>`, `--select <id>`, `--input-test` (on-screen controller buttons) and `--fold-test` (the foldable stand-in: the running shell in a frame that switches between a 1.4:1 folded size and a larger unfolded one).

`UITests/` checks navigation, controller input, setting edits, rotation and the fold. `ShellCaptureTests` captures every screen. With `TEST_RUNNER_SHOT_DIR` set it also writes the PNGs to that folder.
