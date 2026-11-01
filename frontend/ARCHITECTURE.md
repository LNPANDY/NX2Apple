# Architecture of the Mac launcher

The launcher is one SwiftPM package with four targets. The compiler keeps the layers apart: each target may only import the ones above it in this table. A store that imports SwiftUI does not compile.

| Target | Holds | May import |
|---|---|---|
| `NXCore` | pure logic and services | Foundation |
| `NXModel` | stores | `NXCore`, Foundation, Combine |
| `NXLauncher` | views | `NXModel`, `NXCore`, SwiftUI, AppKit |
| `NX2Apple` (app) | entry point, wiring | all |

The plan and the steps are in [LNPANDY/NX2Apple#387](https://github.com/LNPANDY/NX2Apple/issues/387). `Package.swift` is the source of truth for what a target depends on.

## Where it stands

Step 1 of #387 made the targets and moved the files that already fit. Step 2 moved the language out of `BuildModel` into the `Localizer` store. The rest still lives in the app target and moves with the later steps.

- `BuildModel` is the model of the whole launcher and reaches into every layer, so the files that use it cannot leave the app target yet. It no longer owns the language: it holds the `Localizer` it was given and forwards `lang` and `t()` to it, for the text it writes itself (alerts, status, failures).
- `NXCore` holds the value types and static functions that need only Foundation: app and engine update parsing, `Localization.swift`, the release notes, the device and signing tools, the cloud folder and saves migration, the bundled tools, input staging, the build target and the pipe reader.
- `NXModel` holds `Localizer`: `lang` and `t()`. The app creates one with each `BuildModel`, and `ContentView` hands it to every view as an environment object. A view that shows text declares `@EnvironmentObject var loc: Localizer` and calls `loc.t(...)`. A language change redraws these views and nothing else. No other store exists yet.
- `NXLauncher` holds the views and styles that do not need `BuildModel`: `LauncherPalette`, `Typography`, `LauncherStyles`, `LauncherDropdown`, `PadFocus` and `EmbeddedFonts`.
- `NX2Apple` holds everything else, including `BuildModel`.

## Access level

Types shared between targets use `package`, not `public`. Everything else stays `internal`. A `package struct` has no memberwise initializer outside its module, so give it a `package init`.

Tests use `@testable import` for the targets they test, which reaches `internal` too.

## Language mode

The package uses `swift-tools-version` 6.0 and builds every target in Swift 5 mode. `NXCore` is meant to build in Swift 6 mode so the compiler checks data races there. It does not yet: `LauncherWork.counts` is global mutable state, and `PipeReader` captures a non-Sendable closure in a `@Sendable` one. Fixing these changes signatures that the app uses, so it is its own step. When `NXCore` builds clean, give it `swiftSettings: [.swiftLanguageMode(.v6)]` in `Package.swift`.

## Stores

A store is a small `ObservableObject` that owns its `@Published` state and is `@MainActor`. It gets services and other stores through `init`. It checks the conditions for its own actions. It asks another store for what it needs through a narrow protocol, not the whole store.

Services start processes or touch the file system and have no `@Published` state. Each one is a protocol with one real implementation, so a test passes in a fake.

Things a store needs from AppKit, such as file pickers and opening Finder, reach it as closures.

A view observes only the stores it shows. A change in one store invalidates only the views that observe it.

## Where a new feature goes

- Parsing, formatting, classification, anything that is a function of its input: `NXCore`, as a value type or a static function, with a test.
- Running a process or reading and writing files: a service in `NXCore` behind a protocol.
- State that a view shows and changes: a store in `NXModel`.
- A view: `NXLauncher`, observing the stores it shows.
- Creating the services and stores and handing them to the views: `NX2Apple`, nothing else.

Do not add to `BuildModel`. It only shrinks.

## File size

No Swift file under `frontend/Sources` is above 800 lines. `SourceSizeTests` fails otherwise. The files that are above it today are listed in that test with their size, and they may only shrink. When one drops to 800 lines or fewer, remove its entry.

## Names that stay

The app is `NX2Apple.app`, and the target, the sources folder and the tests carry that name. Three names keep the old one, because players would lose data or updates otherwise:

- `CFBundleIdentifier` `org.nxnative.NSPortBuilder`. The settings in UserDefaults belong to it, and the updater rejects a bundle with another identifier.
- `CFBundleExecutable` `NSPortBuilder`. The build copies `.build/release/NX2Apple` to `Contents/MacOS/NSPortBuilder`.
- The data folder `~/Library/Application Support/NS Port Builder/` with the venv, the artwork and `library.json`.
