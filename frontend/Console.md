# Console mode UI

This is a native SwiftUI presentation preview for macOS 13+, built off `main`. It never launches a game, reads the real library, discovers controllers or writes settings. The existing desktop launcher remains the default. The onboarding pattern was read from `onboarding-ui`. That branch is not a dependency.

## Run the demos

```sh
cd frontend
NSPB_CONSOLE_DEMO=full swift run
NSPB_CONSOLE_DEMO=few swift run
NSPB_CONSOLE_DEMO=empty swift run
NSPB_CONSOLE_DEMO=controllers swift run
NSPB_CONSOLE_DEMO=controllersMixed swift run
NSPB_CONSOLE_DEMO=starting swift run
```

`full` contains 12 games with ready, needs-build, missing-data and broken states. `few` contains two games. `controllers` opens three controllers with player 3 awaiting assignment. `controllersMixed` adds a Pro-style pad, an Xbox-style pad with 12% battery, a keyboard and charging paired controllers. `starting` animates simulated shader compilation, then waits at Opening game window until the driver reports a return. No real shader compilation runs, and the mock never fabricates a completed game launch. Unknown or absent demo values open the desktop launcher as before.

Arrow keys navigate. Return or Space activates the focused item. O or + opens game options, and Y opens Controllers. Escape acts as B and closes the top sheet, then exits from Home. Home's Play action explains incomplete setup instead of launching. In options, left/right changes the selected row, and Return advances its value. Choose a player, use Assign player on a controller, then Simulate a button press to exercise assignment. Identify and Disconnect update the mock only. The exit preview offers Return to console. The mode fills its window and works in macOS full screen. The view does not change system window state.

## Driver API

`ConsoleView<Driver: ConsoleDriver>` observes one published `ConsoleState` snapshot on the main actor. Implement:

```swift
focus(_ gameID: String)
play(_ gameID: String)
openOptions(_ gameID: String)
setOption(gameID: String, setting: String, value: String)
openControllers()
requestPlayer(_ player: Int)
requestAssignment(controllerID: String)
identify(controllerID: String)
disconnect(controllerID: String)
setPadMerge(_ enabled: Bool)
dismissToast()
assignPlayer(controllerID: String, player: Int)
back()
exitToDesktop()
returnFromGame()
```

The state includes games, decoded SwiftUI artwork images, versions, platforms, ready/build/data/broken status, focused game ID, controllers with kind, player, optional battery fraction (0–1) and charging state, an assignment target, player merge mode, a toast, a sheet stack, Starting, exit status and a clock value. Broken messages and `LaunchSetting` labels/choices/notes are localized by the driver. Option values are in-memory overrides keyed by the existing setting's environment variable. The console uses `LaunchSetting.accepts`, defaults and `needs` dependencies. It renders every supported choice, range and toggle supplied to it, including advanced options, without loading a launcher JSON or a settings store. `ConsoleOption` implements controller stepping. The real driver decides how to persist and apply those values. `setPadMerge` is a presentation intent for the future `DM_PAD_MERGE` bridge. Merged display assigns every controller to player 1 while preserving its separate-player mapping for switching back.

`ConsoleState` provides pure guarded navigation/mutation methods used by the mock and available to the eventual real driver. Sheet nesting preserves the preceding options sheet. Player reassignment releases that player's former controller. Focus does not wrap at the collection ends. Starting ignores further Play/Back actions until the driver completes the transition. Call `returnFromGame` for the future controller guide-button route. It preserves the selected game and clears Starting and sheets.

Pass a publisher of `ConsoleInput` to the view for future controller events: left/right/up/down, activate, back, options and controllers. This adapter is intentionally absent. Every interactive element registers with `padTarget` in `console`, `console.options`, `console.controllers`, `console.explanation` or `console.entry`. The future controller adapter must intercept an assigning controller's button and call `assignPlayer(controllerID:player:)`, rather than treating it as generic activation. The real driver supplies controller connect/disconnect snapshots, short localized toasts and clock ticks. The mock exposes `connect` and `disconnect` events with a three-second toast lifetime. It never flashes, rumbles or disconnects real hardware.

The desktop's `ContentView(enterConsole:controllerDriver:)` button and controller-connect prompt report the injected entry intent only. The default closure is inert until the coordinator is wired. The prompt uses the launcher's existing connection observation, without adding hardware APIs. `ConsoleConnectionPrompt` is also independently renderable. Exiting the mock renders an explicit desktop preview, never constructs the real build launcher. Production navigation and actual window transitions belong to the coordinator. Inject `AnyConsoleDriver(realDriver)` to show the same controller snapshot in the desktop chips and `ConsoleControllersSheet`. With no injection, the desktop controller snapshot is empty. It never guesses controller identity from the existing boolean connection flag. The desktop sheet uses `ConsoleControllerList`, the very same view as console mode. A fixed-height controller strip occupies the second row of the top bar so four chips fit even at 900 points. Narrow windows use accessible icon actions in the first row, preserving the logo and avoiding wrapped navigation labels.

## Design

The visual target is the existing launcher code: `LauncherPalette`, embedded Manrope, cream capsule actions and its 1.8:1 artwork crop. Console mode places the selected game's name and platform badges above large landscape cards, with a soft artwork backdrop and a fixed text-and-glyph hint strip. It has no round system-action row, system avatars, Nintendo fonts, Nintendo sounds or copied home-menu arrangement. The typography and generous spacing carry the console feel. Standard SF Symbols identify controls.

The reusable `ConsoleArtwork` and `ConsoleGameTile` accept presentation values. At compact widths the cards become a touch-friendly horizontal collection, hints form two columns, and the side sheet fills the width. Vertically short windows scroll the library and sheet contents, and the primary option action stays visible. Focus/background transitions last 0.18–0.22 seconds, without springs. Reduced Motion removes focus scaling and scroll animation, retaining only fades. No UI sounds are included. Controller kinds use neutral SF Symbols, including a split rectangle for paired controllers, with no Nintendo artwork. Chips have fixed strip height, horizontal overflow, player numbers, battery percentage when reported and charging status. Connect/disconnect toasts overlay the screen without moving it. All controller copy is localized and contains no semicolons.

Nothing is bundled. The demo takes covers from the repository's `docs/images` through `GameLibrary.artwork(for:repo:)`, the lookup the desktop launcher uses, with the repository found by `BuildModel.findRepo()`. A title without an image gets a generated placeholder (a gradient in the launcher's palette and the name). All interface copy and mock controller labels live in the shared English/Chinese localization table.

Starting takes a `ConsoleStarting` snapshot: preparing, compiling shaders (completed/total), or opening. Shader progress uses the existing cream launcher progress bar, animating for 0.3 seconds per update, and Reduced Motion removes interpolation. A preview label explicitly identifies simulated shader progress. The live driver must publish actual shader stages and counts, then end Starting when the game window appears.

## Checks

```sh
cd frontend
swift build -c release
swift test
NX_CONSOLE_CAPTURE_DIR=/Volumes/NX/console-captures swift test --filter ConsoleTests
```

The optional offscreen capture test hosts every screen, setup explanation, exit preview and entry prompt in English and Chinese at 1920×1080, 1280×800 and 390×844. Ordinary tests skip captures. State tests cover focus bounds, each status's Play behavior, sheet nesting, B/exit/return, launch-setting validation/dependencies and unique controller assignment. Localization tests check both languages for the console keys.

Files added: `ConsoleState.swift`, `MockConsoleDriver.swift`, `ConsoleView.swift`, `ConsoleKeyboardInput.swift`, `ConsoleEntryView.swift`, `ConsoleControllersView.swift`, `ConsoleGlyphs.swift`, `ConsoleLauncherDriver.swift`, `ConsolePadTests.swift`, `ConsoleTests.swift`, and this note. Files changed: `Gamepad.swift` (a + action), `NSPortBuilderApp.swift` (isolated demo hook), `LauncherView.swift` (entry intent and connection prompt), and `Localization.swift` (English/Chinese).

Validation on 2026-10-28: release build passed. The complete frontend suite passed with 188 tests, zero failures and six unrelated opt-in capture tests skipped. The console's two capture tests ran and produced 94 images, including desktop integration at 900 and 1280 points. Native UI checks exercised keyboard focus, option changes after mouse clicks, setup explanations, Identify feedback, assignment, merged player display, Disconnect, chip updates, Escape and return from the exit preview. Visual review corrected duplicate tile focus borders, the Starting crop, minimum-height card clipping, and crowded desktop navigation. This is a new console composition derived from the existing design system, not a pixel-matching recreation of a supplied console mockup.

## Controller, glyphs and the player-mode setting

`ConsoleView` takes the launcher's `LauncherGamepad` (Gamepad.swift), like the onboarding, and maps its actions with `ConsoleInput(_:)`: the D-pad and left stick move, A activates, B backs out, + and X open game options, Y opens Controllers. L and R are unused. `ConsoleGlyphs` resolves each action to the physical button Gamepad.swift reads and shows what the controller last used prints there (Apple's `sfSymbolsName`, a per-family table as fallback, key caps after the keyboard, a neutral letter otherwise). The Controls page layout (By label) only changes what a game receives, so it does not move these glyphs.

"All controllers are player 1" is a launcher setting (off by default, `ControlLayout.padMerge` in UserDefaults). Play passes `DM_PAD_MERGE=1` with the Controls environment. It is in Settings and in the Controllers sheet. 
## Using it

`LiveConsoleDriver` is the real driver. It builds the games from `GameLibrary` (status, version, platforms, covers through `GameLibrary.artwork`), reads and writes launch options through `SavedChoices` and the library as LaunchOptionsView does, starts a game with `GameStart.environment` (the function the desktop Play button uses, so saved choices and `DM_PAD_MERGE` match), lists controllers from GameController and ends Starting when the game window takes the front or the game quits. A game that quits brings the console back (PR #110 brings the launcher back to the front for the desktop and does not conflict, since both only observe the termination).

Enter it with the controller's Select-type button on the desktop (DualShock Share, DualSense Create, Xbox View, Nintendo Minus, GameController's `buttonOptions`, which the system does not claim), from the controller prompt (once per launch, off in Settings), or with View, Console Mode (Option-Command-K, because Control-Command-F is the system's full screen). The desktop's bottom hint row shows the Select glyph of the controller in use with "Console mode", and nothing about controllers appears elsewhere on the desktop. Settings, Controls has a Controllers row (identify, assign players) next to the player-mode switch. In console mode Select does nothing special. The Home button is not touched. The window goes full screen for the mode and returns to its earlier state on leaving. `ConsoleCoordinator` owns that, and RootView swaps the content. Every controller GameController lists drives the launcher, wired or wireless, and each new one takes the next free player at once.

