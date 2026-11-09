import Foundation

/// What console mode brings over from the desktop launcher, as plain values the driver fills: a game's mods and cheats (switched on
/// and off here, put in place on the desktop), the launcher's own switches on the menu's pages and the app's update. Nothing here builds, picks a folder or reads a file: the driver does (LiveConsoleDriver+Desktop).

/// A mod in the game's mods folder (GameMod). One that changes the game's code (exefs) cannot be used and shows why.
struct ConsoleMod: Identifiable, Equatable {
    var name: String
    var usable: Bool
    var on: Bool
    var id: String { name }
}

/// A row of the game's cheats file for the build it has (CheatFiles): a cheat with its switch, one that is always on, or a heading.
struct ConsoleCheat: Identifiable, Equatable {
    enum Kind: Equatable { case cheat, alwaysOn, label }
    var key: String
    var name: String
    var kind: Kind
    var on: Bool
    var id: String { key }
}

/// The game's cheats: the switch for all of them in the game, and the rows for its build. `note` says why there are none (the build
/// is not known yet, or no file for it was imported on the desktop).
struct ConsoleCheats: Equatable {
    var masterOn = true
    var items: [ConsoleCheat] = []
    var note: String?
}

/// The launcher's own switches console mode shows, each on the menu page it belongs to, as the desktop's Settings groups them (and
/// the same defaults): the library's filter on Library, the ways into console mode on Controllers, the launcher after a game on General.
enum ConsolePref: String, CaseIterable {
    /// ConsolePrompt.startKey: the launcher opens in console mode.
    case startInConsole
    /// ConsolePrompt.defaultsKey: connecting a controller on the desktop offers console mode.
    case promptOnController
    /// ReturnAfterPlay.defaultsKey: the launcher comes back to the front when a game quits.
    case returnAfterPlay
    /// LibraryFilter "built": only the games with a build, on the desktop and here.
    case onlyBuilt
    var titleKey: String { "console.pref." + rawValue }
    var noteKey: String { "console.pref." + rawValue + "Note" }
    /// The switches of each page, in their order.
    static let onLibrary: [ConsolePref] = [.onlyBuilt]
    static let onControllers: [ConsolePref] = [.startInConsole, .promptOnController]
    static let onSettings: [ConsolePref] = [.returnAfterPlay]
}

/// Where the app's own update stands (AppUpdateStore), as the General page's row says it and what A does there.
enum ConsoleAppUpdate: Equatable {
    /// Nothing known yet, or the last check found nothing newer: A checks.
    case upToDate
    case checking
    /// A newer version that can be installed here: A asks, then downloads and installs it.
    case available(String)
    case downloading(Int?)
    /// Installed, the launcher restarts into it: A asks, then restarts.
    case ready
    /// A newer version this copy cannot install itself (a developer build, a read-only place): the desktop's Settings says why.
    case cannotInstall(String)
    /// Updating waits while a build runs.
    case waitingForBuild
    /// The last download or check of a release failed (AppUpdateStore.blocked): A tries again.
    case failed(tag: String, reason: String)
}

struct ConsolePrefs: Equatable {
    var values: [ConsolePref: Bool] = [:]
    var appVersion = ""
    var update: ConsoleAppUpdate = .upToDate
    /// What the update store says now (downloading, ready, why an install failed), shown under the version.
    var updateStatus = ""
    subscript(_ pref: ConsolePref) -> Bool { values[pref] ?? Self.defaults[pref] ?? false }
    static let defaults: [ConsolePref: Bool] = [.startInConsole: false, .promptOnController: true, .returnAfterPlay: true, .onlyBuilt: false]
}
