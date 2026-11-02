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

Step 1 of #387 made the targets and moved the files that already fit. Step 2 moved the language out of `BuildModel` into the `Localizer` store. Step 3 moved the build log into the `BuildLog` store. Step 4 moved the pure logic into `NXCore`. Step 5 added the first services. Step 6 added the first store, `AppUpdateStore`, the reference for the others. Step 7 moves the rest one store per PR: the repository, the engine sync, then the dependencies. The rest still lives in the app target and moves with the later steps.

- `BuildModel` is the model of the whole launcher and reaches into every layer, so the files that use it cannot leave the app target yet. It no longer owns the language: it holds the `Localizer` it was given and forwards `lang` and `t()` to it, for the text it writes itself (alerts, status, failures).
- `NXCore` holds the value types and static functions that need only Foundation: app and engine update parsing, `Localization.swift`, the release notes, the device and signing tools, the cloud folder and saves migration, the bundled tools, input staging, the build target and the pipe reader. Step 4 added four types: `TitleID` (parse a title ID from a file name, its owner, the update version, the build key), `GameInputs` (classify files into the four rows, row mismatch, allowed file types), `BuildProgress` (stage lines, progress details, durations, the steps of Xcode and the install, failure info) and `Toolchain` (probing Python, the venv, dotnet and Xcode, and the dependency rows `Dep`). `Stage` and `StepState` moved with `BuildProgress`. Step 5 added the first services (step 6 added `ReleaseSource`, see below): `ProcessRunner` (a protocol, with `SystemProcessRunner` as the real one), `ProcessGroups` (the process groups that Stop and quitting end) and `GitCheckout` (a protocol, with `SystemGitCheckout`, plus `GitRules` for the decisions that need no git). `ProcessRunner` is where a build process starts: `capture` runs to the end and keeps the output, `stream` hands out lines, `start` returns at once and can lead a process group. `BuildModel` holds a runner and a checkout, takes them in `init`, and uses them for the clone, fetch, pull, adoption of a ZIP copy, the build run, the tools of a stage, the archive step and `openOnDevice`. `Toolchain`, `Diagnostics`, `OlderTools`, `Uninstall`, `EngineLayout.runSync` and the update staging take a runner or a checkout as a parameter with the real one as default. Tests pass in a fake. These still start a `Process` themselves and move with the step that owns them: `AppSignature` (codesign) with the device store, `DeviceTools.run` (devicectl with a timeout and input) and `SaveTransfer` with the device store, `ShellInstaller.run` (a blocking read with start and end callbacks) with the build store, `EngineInstaller` (ditto, in `NXCore` since the engine sync store) still starts it itself, the administrator prompt in `LiveOnboardingDriver` and the game start in `LiveConsoleDriver`. The tests that stand in for `xcodebuild` and `devicectl` through `BuildModel.xcrunPath` stay too: `ShellInstaller` and `DeviceTools` run those tools themselves, so they move with the device store. What reads `MetalPin`, `EngineLayout` or `OnboardingDefaults` (`detectDepsSync`, `metalDep`, `needsIOSPlatform`) and the handling of the build's JSON events stay in `BuildModel` until the later store steps.
- Step 6 moved the self-update out of `BuildModel`. `AppUpdate` (`NXCore`) now also holds the release parsing (`release(fromJSON:)`, `check(latest:current:)`), the version compare (`isNewer`), the asset names, the staging of a download (`stage`, `StageFailure`) and the install, which clears the quarantine flag through a `ProcessRunner`. `ReleaseSource` is the second service (a protocol, with `GitHubReleases` as the real one): the latest release and the download. `Uninstall` moved to `NXCore` too, because the store holds its plan. `AppUpdate.relaunch` still starts its detached shell itself, and the store gets it as a closure.
- `NXCoreTests` tests `NXCore` alone. It links no other target, so these tests run without SwiftUI. New tests of pure logic go there.
- `NXModel` holds `Localizer`: `lang` and `t()`. The app creates one with each `BuildModel`, and `ContentView` hands it to every view as an environment object. A view that shows text declares `@EnvironmentObject var loc: Localizer` and calls `loc.t(...)`. A language change redraws these views and nothing else.
- `NXModel` holds `AppUpdateStore`: the release check, the staged update, the update sheet, the uninstall plan and `appVersion`. `BuildModel` creates it with its localizer, runner and release source, and the views that show the update (the launcher's top bar and activity line, the Settings section, the update sheet) observe it and not `BuildModel`. `NXModelTests` tests it with a fake runner and a fake release source, without SwiftUI.
- `NXModel` holds `RepoStore` (step 7, repository): the repository path, the status line under it, how far it is behind origin/main, the clone, the update check, the pull, the automatic update when the app opens and the adoption of a ZIP copy. `BuildModel` creates it with its `Localizer` and `GitCheckout` and wires four closures: whether a build runs, whether this is a release app (which never clones or pulls), the build log, and `didMove`, which starts the engine sync after a clone, a pull or an adoption. The views that show the repository (Settings "Tools", the library's activity line, the setup hint) observe the store. `RepoLocation` is the narrow protocol (`path`, `isRepo`, `isGit`) for a store that needs only where the repository is. `NXCore` got the rules the store needs: `RepoLayout` (is it a repository, the tools a build needs, which checkout to use at start) and the file-system part of `EngineLayout` (`marker`, `root`, `isCheckout`, `hasEngineTool`). The stale check and the sync of `EngineLayout` stay in the app target with the engine.
- `NXModel` holds `EngineSyncStore` (step 7, engine sync): the engine selection (channel, engine ID, version, the one kept), the sync of a checkout's `engine/` (`tools/engine.py sync`, its status line and its failure row with Try again, the calls that wait for a running sync) and the engine of the release app (seeding the app's own engine, the check of the selected channel, the install, the channel switch after a confirmation, an engine that waits for the running build). `BuildModel` creates it with its localizer and runner, the `RepoStore` as the `RepoLocation` to read, the `DependencyStore` as the `PythonLocation` (a narrow protocol with `pythonPath`) and closures: where the build reads its tools from (`setRepoPath`, an installed engine tree), whether a build runs, the automatic update and the log. `RepoStore.didMove` starts its sync. The views that show the engine (Settings "Tools", the sync banner, the failure row's Try again, the launcher's checks after a sync) observe the store. `NXCore` got what the store needs: the stale check and the sync of `EngineLayout`, `EngineUpdater.swift` (`EngineChannel`, `EngineSelection`, `EngineUpdate`, `EngineInstaller`, `EngineTransport`) and `BuildFailureKind` with `BuildFailure` (the sync's failure row). The classifier `BuildFailureClassifier` stays in the app target. `NXModelTests` tests the store with a fake runner, without SwiftUI.
- Still in `BuildModel`, going to their store: `repoPath`, `repoOK` and `repoIsGit` are forwarders to `RepoStore`, because the build code (start, archive, install, diagnostics) reads the path and is not a store yet. `BuildModel` also forwards the objectWillChange of `RepoStore` and of `EngineSyncStore` to its own, because `canBuild` and the build views read the repository and the engine's paths through it. Both go with the build store (step 7, build). The synchronous calls of the build (`startBuild` waits for the sync, `Diagnostics` reads the selection) stay. `BuildModel` is not `@MainActor` yet, so it reaches the stores through `MainActor.assumeIsolated`.
- `NXModel` holds `DependencyStore` (step 7, dependencies): the rows of the tools panel (`deps`, `checked`, whether the list is expanded), the Python and dotnet paths the check finds, the check (`check()`) and the installs (`install(_:)`, with the failure kept on the row and a note for it). It is the `PythonLocation` that `EngineSyncStore` reads, and `DependencyStatus` (`checked`, `allPresent`, `pythonPath`, `dotnetPath`, `deps`) is the narrow protocol the build reads. `BuildModel` creates it with its localizer, runner and the `RepoStore` as the `RepoLocation`, and wires closures: the guided setup's platform choice (`needsIOS`), the App Store (a row with no command, Xcode), the log and the note after a failed install. The views that show the rows (Settings "Tools", the setup hint and the status line of the Builds page) observe the store. `NXCore` got what the store needs: `DependencyCheck` (the list of rows, the Metal row, the dotnet install command, `deps-check.txt`, the bash command and environment of an install) and `MetalPin`. `NXModelTests` tests the store with a fake runner and a fake detection, without SwiftUI. The Python row's venv install (`Toolchain.makeVenv`) is not tested there, because it reads and writes the real venv folder.
- Still in `BuildModel`, going to the build store: `pythonPath`, `dotnetPath`, `depsChecked` and `allDepsPresent` are read-only forwarders to the store through `DependencyStatus`, because the build code (start, RomFS, diagnostics, `canBuild`) reads them. `BuildModel` forwards the store's objectWillChange to its own, like the other stores. The card's fix buttons (`fixBuildFailure`, `fixBusy`) call the store's `install` and `isInstalling`. `needsIOSPlatform` stays in the app target, because it reads `OnboardingDefaults` (the guided setup's keys), and goes to the store with the onboarding. `BuildModel` is not `@MainActor` yet, so it reaches the store through `MainActor.assumeIsolated`.
- `NXModel` also holds `BuildLog`: the log text, its tail trimming and the line buffer. `BuildModel` holds it in a `let` and does not publish it, and only `BuildLogView` (in `NXLauncher`) observes it. A log line redraws the log and no game card. `LauncherPerformanceTests` writes 1000 lines during a build and allows 0 cards. `BuildModel` is not `@MainActor` yet, so it reaches the log through `BuildLog.onMain`.
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

### The pattern: `AppUpdateStore`

`Sources/NXModel/AppUpdateStore.swift` is the reference. A new store follows it:

- **Declaration.** `@MainActor package final class XStore: ObservableObject`. It imports `Foundation`, `Combine` and `NXCore`, never SwiftUI or AppKit.
- **State.** Everything a view shows is `@Published`. `package private(set)` when only the store changes it. `package var` when a view binds it (`showUpdateSheet`, `uninstallPlan`) or a test sets it up.
- **`init` takes what the store works with.** The services as protocols (`ProcessRunner`, `ReleaseSource`), the `Localizer` for its text, and the facts of its environment with the real ones as defaults (`bundle`, `version`, `defaults`, `runningOS`). A test passes in fakes and temporary folders. Another store or the model's flags come as a narrow closure (`buildRunning`), never as the whole object.
- **AppKit as closures.** Quitting and relaunching reach the store as `terminate` and `relaunch`. A system notification is forwarded by the app, which calls a method of the store (`appWillTerminate()`).
- **Logic stays out.** What needs no state (parsing, comparing, deciding what may be installed) is a static function in `NXCore` (`AppUpdate`) with its own tests. The store only calls it and keeps the result.
- **Actions check their own conditions.** `install` refuses while a build runs and for a copy that is not a released one. The view does not decide that.
- **Async work.** The method that starts it sets its state synchronously (`busy = true`), runs a `Task` on the main actor, hops off it for blocking work (`Task.detached`) and returns the `Task`, so a test awaits `store.checkForUpdate().value`.
- **Tests.** `NXModelTests`, a `@MainActor` test class, no SwiftUI. Fakes for the services, a `UserDefaults` suite of its own, files in a temporary folder.
- **Wiring.** Until `BuildModel` is gone, it creates the store. The store is not published through the model: views take it as an `@ObservedObject` parameter (or as an environment object, as `Localizer`), so a change redraws the views that show it and nothing else.

### `appVersion`

`AppUpdateStore.appVersion` is the one line that says which release the launcher is: `nonisolated package static let appVersion = "x.y.z"`. `build-mac-app.yml` checks the tag against it, `sync-upstream.yml` names the experimental engine after it, `tools/try-local` builds `<appVersion>-local`, and `RELEASING.md` says where to bump it. They read the line with `sed`, so keep it in that form and in that file. `tools/tests/test_app_version.py` fails when a reader names a file without the line, or a new reader is not in its list. When the line moves again, move every reader with it.

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
