# First-run UI preview

With a recognized `NSPB_ONBOARDING_DEMO` value the app shows a scripted preview of the guided setup. The preview never instantiates `BuildModel`, detects tools, reads selected files, installs anything or opens the App Store. Its exit screen stands in for opening the library. Without it, `RootView` (`OnboardingRoot.swift`) runs the real flow described under "The real driver" below, or opens the launcher.

From the repository root, enter `frontend`, then run one scenario:

```sh
cd frontend
NSPB_ONBOARDING_DEMO=fresh swift run
NSPB_ONBOARDING_DEMO=xcodeReady swift run
NSPB_ONBOARDING_DEMO=keysInvalid swift run
NSPB_ONBOARDING_DEMO=xcodeFailed swift run
NSPB_ONBOARDING_DEMO=noGames swift run
NSPB_ONBOARDING_DEMO=oldMac swift run
```

- `fresh`: Start, select a platform, Continue, Get Xcode, wait, Finish setup, confirm the found keys, review the games, Continue, Open library.
- `xcodeReady`: the same path, with Xcode already present, and its checks tick through automatically.
- `keysInvalid`: confirming the found file fails validation. Choose or drop another file to exercise recovery. The mock does not read it.
- `xcodeFailed`: setup fails with a plain explanation and expandable diagnostics. Retry, then Finish setup to recover.
- `oldMac`: the `fresh` path with the NVN hints on (below).
- `noGames`: the mock folder scan finds no NSPs and shows a hint. Use Back or Set up later.

Set up later preserves an in-memory snapshot, and Resume setup restores it. The mock persists nothing, and the real driver does (below).

`NSPB_ONBOARDING_FORCE=1 swift run` shows the real flow (the live driver, real detection) on launch even when setup is complete or marked done. It writes nothing until the player finishes or picks "Set up later": no `onboarding.completed`, step, platform or build target, and nothing is installed until an install action (Get Xcode, Finish setup, Retry) is pressed. Quitting in between leaves no trace.

## Wiring contract

`OnboardingView<Driver: OnboardingDriver>` observes a driver on the main actor. A real `ObservableObject` should publish `OnboardingState` as one value and implement these intents:

```swift
start()
choosePlatform(_ platform: OnboardingPlatform)
getXcode()
finishXcodeSetup()
retry(_ step: OnboardingStep)
chooseKeys(_ url: URL)
confirmKeys()
chooseGames(_ url: URL)
back()
next()
skipForLater()
openLibrary()
```

The driver owns detection, installation, privileges, security-scoped access to selected URLs, validation, decoded cover images, persistence, and navigation. The view owns only presentation, the system chooser, drop URL decoding, disclosure expansion and input handling. No key file contents belong in `OnboardingState`, failure text or diagnostics. Failure messages must already be localized, and `details` is diagnostic text supplied by the driver.

Use `OnboardingState.next()` and `.back()` for gated navigation. `canAdvance` requires disk space on Welcome, a platform selection, Xcode plus all background tasks, valid keys, or a nonempty games list respectively. `primary` distinguishes a step action (Get Xcode, Finish setup, confirm keys, Retry) from advancing. `primaryEnabled` also gates completion and dismissed flows. `setupTasks` derives the iOS row from the selected platform.

Automatic advancement belongs in the driver. The mock gives completed Xcode and keys a brief checkmark hold, then advances. Returning to an already completed step stays there so Back remains useful. Games wait for explicit Continue so the player can review what was found. On a return visit, selecting iPhone after completed Mac setup adds the iOS preparation step.

Persist the current step and selections before handling `skipForLater`, then inject the restored state on the next launch and revalidate external prerequisites in the real driver. `MockOnboardingDriver(state:)` demonstrates restoration without preferences or file I/O. Its `animated: false` initializer disables scheduled changes for deterministic tests.

## The real driver

`LiveOnboardingDriver` (`LiveOnboardingDriver.swift`) implements the contract over the launcher's own `BuildModel` and `GameLibrary`, which `RootView` shares with `ContentView`. Everything it does to the machine goes through `OnboardingEnvironment`, so the tests use fakes.

- When it shows: on launch, unless `onboarding.completed` is set or setup is already complete (all tools present, a keys file known, a games folder set, and a complete one is marked done without being shown). Settings has "Run setup again". Set up later stores the step, platform and an in-progress flag in `UserDefaults`, and the next launch resumes there and revalidates (a stored step past Xcode returns to Xcode when Xcode no longer holds).
- Detection and installs are `BuildModel.checkDeps` / `deps` / `installDep`, one install at a time (Python, .NET, then Homebrew and the formulas). Homebrew waits for Xcode to be ready. The xcode row asks for the iOS SDK only when the stored platform is not Mac-only or builds target an iPhone (`BuildModel.needsIOSPlatform`).
- Xcode: missing opens the App Store and polls /Applications for it, and setup is one administrator prompt (`OnboardingAdmin.source`: `xcode-select -s`, `xcodebuild -license accept`, `-runFirstLaunch`), then the Metal Toolchain and, for iPhone or both, the iOS platform without it. A cancelled prompt returns to `needsSetup`.
- Keys are found in `~/.switch`, `~/Downloads` and the games folder, checked by `KeyCheck`, and only the path goes into the keys slot. Games use `GameLibrary.sourceGames`, `BuildModel.scan` and `GameLibrary.setFolder`.

## NVN hints

NVN games' shaders need the Metal compiler of Xcode 27.1, which needs macOS 26.6. `OnboardingState.osTooOldForNVN` (macOS below 26.6, from `OnboardingEnvironment.osVersion`) adds a calm note to Welcome, and `xcodeTooOldForNVN` (the probe's `xcodebuild -version` below 27.1, where an unreadable version never counts) adds a secondary line in the Xcode card. Neither gates anything: other games build with an older Xcode.

## Presentation choices

The flow retains the launcher's dark appearance, palette, Manrope, cream capsule primary button, secondary button style and 1.8:1 cover crop. The app currently forces dark mode, so onboarding does too. Background preparation stays beside Xcode, while a fixed footer keeps the primary action visible at the launcher's 900 × 680 minimum window size. Long content scrolls. The two Xcode cards share one fixed height across all of that step's states (content scrolls inside a card rather than resizing it), and the platform, keys and games cards keep their size between states.

Return activates the primary action, Escape and controller B go back. Every interactive element has an onboarding controller target. Step headings receive VoiceOver focus, and changing status is announced. Reduced Motion replaces slides with fades, shows completed checks immediately, stops indeterminate loops and disables progress interpolation.

## Validation

```sh
swift build -c release
swift test
NX_ONBOARDING_CAPTURE_DIR="$PWD/.build/onboarding-captures" swift test --filter OnboardingTests
```

The last command optionally captures all six screens at minimum window size in English and Simplified Chinese. It only hosts mock SwiftUI views. The normal suite skips that capture unless requested.

Files added: `OnboardingState.swift`, `MockOnboardingDriver.swift`, `OnboardingView.swift`, `OnboardingTests.swift`, and this note. Files changed: `NSPortBuilderApp.swift` (demo branch) and `Localization.swift` (both languages).
