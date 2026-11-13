import SwiftUI
import Combine
import NXCore
import NXLauncher

/// Presentation snapshots only. The eventual driver supplies decoded artwork, localized launch settings,
/// controller names and a clock value; none of these types inspects a library or a controller device.
struct ConsoleGame: Identifiable {
    enum Status: Equatable {
        case ready, needsBuild, needsData, iphoneOnly, broken(String)
        var labelKey: String {
            switch self {
            case .ready: return "console.ready"
            case .needsBuild: return "console.notBuilt"
            case .needsData: return "console.needsDataBadge"
            case .iphoneOnly: return "console.iphoneOnly"
            case .broken: return "console.unavailable"
            }
        }
        var explanationKey: String? {
            switch self {
            case .ready: return nil
            case .needsBuild: return "console.needsBuild"
            case .needsData: return "console.needsData"
            case .iphoneOnly: return "console.iphoneOnlyNote"
            case .broken: return "console.broken"
            }
        }
    }
    enum Platform: String, CaseIterable { case mac, iphone
        var labelKey: String { "console.platform." + rawValue }
    }
    var id: String
    var title: String
    var version: String
    var platforms: [Platform]
    var artwork: NSImage?
    /// The game's large artwork (the hero slot, at screen size), for the home screen's backdrop: loaded for the focused game only.
    var hero: NSImage?
    var heroFocus = UnitPoint.center
    /// The part of the cover the card keeps when it crops it (the thumbnail's focus point).
    var artworkFocus = UnitPoint.center
    var status: Status
    /// The exact launcher's model, already decoded and localized by the driver.
    var settings: [LaunchSetting] = []
    var values: [String: String] = [:]
    /// Whether this build keeps a button mapping of its own (DMControllerMappings, saved choices on): its options offer it.
    var mapsButtons = false
    /// Read when its options open (the driver's loadDetails): its mods, its cheats, whether anything differs from the defaults, and
    /// where its cloud save stands.
    var mods: [ConsoleMod] = []
    var cheats: ConsoleCheats?
    var canReset = false
    var save: ConsoleSaveRow?
    /// When it was last played and for how long (the launcher's play history, PlaySessions, and the desktop's Recently played), nil
    /// for a game never played. Built with older tools than the engine has now (ToolsAge). The newest save on this Mac, read when its
    /// page opens.
    var lastPlayed: Date?
    var playSeconds: Double = 0
    var olderTools = false
    var lastSave: Date?

    /// The console's order: the games this Mac can play first, then the rest, each group in the order it came in.
    static func readyFirst(_ games: [ConsoleGame]) -> [ConsoleGame] {
        games.filter { $0.status == .ready } + games.filter { $0.status != .ready }
    }

    func value(_ setting: LaunchSetting) -> String { values[setting.env] ?? setting.def }
    /// The engine's section of a game's controller rows (settings.tsv: Game rumble, its strength and its cutoff): they are shown in the
    /// controller settings, not among the options.
    static let controlsSection = "Controls"
    var optionSettings: [LaunchSetting] { visibleSettings.filter { $0.section != Self.controlsSection } }
    /// The options as the desktop splits them (LaunchSetting.isBasic): the common ones on the options page, the rest behind Advanced.
    var basicSettings: [LaunchSetting] { optionSettings.filter(\.isBasic) }
    var advancedSettings: [LaunchSetting] { optionSettings.filter { !$0.isBasic } }
    var controllerSettings: [LaunchSetting] { visibleSettings.filter { $0.section == Self.controlsSection } }
    var hasControllerSettings: Bool { mapsButtons || !controllerSettings.isEmpty }
    var visibleSettings: [LaunchSetting] {
        settings.filter { setting in
            // Console mode launches fullscreen whatever Display says (GameStart's fullscreen), so the sheet does not offer it.
            guard setting.env != "DM_FULLSCREEN" else { return false }
            guard let needs = setting.needs else { return true }
            let parts = needs.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2, let parent = settings.first(where: { $0.env == parts[0] }) else { return false }
            return value(parent) == parts[1]
        }
    }
}

struct ConsoleController: Identifiable, Equatable {
    var id: String
    var name: String
    var player: Int?
    enum Kind: String, CaseIterable { case gamepad, fullSize, paired, xbox, keyboard
        var labelKey: String { "console.kind." + rawValue }
        var symbol: String {
            switch self {
            case .gamepad: return "gamecontroller"
            case .fullSize: return "gamecontroller.fill"
            case .paired: return "rectangle.split.2x1"
            case .xbox: return "circle.grid.cross"
            case .keyboard: return "keyboard"
            }
        }
    }
    var kind: Kind = .gamepad
    var battery: Double? = nil
    var charging = false
    /// Whether Identify can do anything on this controller (a player light, a light bar or a rumble). Hidden when it cannot.
    var canIdentify = true
    var batteryPercent: Int? { battery.map { Int((min(max($0.isFinite ? $0 : 0, 0), 1) * 100).rounded()) } }
}

/// What the desktop is doing, as the top bar's chip shows it (#1004): the operation line and the current stage's progress, nil when
/// the stage has no share to report. It is never a whole-build percentage or a time: stages are not equal parts of a build.
struct ConsoleActivity: Equatable {
    var title: String
    var stageProgress: Double?
    /// "Current stage 40 percent", already localized, for VoiceOver.
    var spokenProgress = ""
}

struct ConsoleToast: Equatable, Identifiable {
    var id = UUID()   // the notice's own (ConsoleNoticeQueue), so the view animates one change per notice
    /// A button glyph shown after the message (the controller in use), for a toast that names a button.
    var glyph: ConsoleGlyphs.Glyph? = nil
    /// Already localized by the driver, using console connection/identification keys.
    var message: String
}

enum ConsoleStarting: Equatable {
    /// cloudSave: the cloud's save is being brought onto this Mac before the start (#957); `long` once it has taken a while
    case preparing, compilingShaders(completed: Int, total: Int), opening, cloudSave(long: Bool)
    var progress: Double? {
        if case let .compilingShaders(completed, total) = self, total > 0 { return min(max(Double(completed) / Double(total), 0), 1) }
        return nil
    }
}

enum ConsoleSheet: Equatable {
    /// homeButtonHint: the system keeps the controller's Home button, so a game cannot be quit with it (#336, shown once).
    /// menu: the console's own menu (Library, Controllers, General, leaving console mode), on the Select-type button.
    /// mapping: what each controller button sends in games, for all games (the Controls page's controller layout).
    /// gamePad: a game's controller settings (its Controls rows: rumble, and its own button mapping), opened from its options.
    /// library: the menu's Library page (the library's switch, the way to the cloud saves). settings: its General page (the display
    /// language, the app's update, the launcher after a game), language: the display language list.
    /// cloudSaves: each game's cloud save state and time, as a page of its own over the whole screen.
    /// confirmExit: "Leave console mode?", over what is open (the menu's Exit, or B on the home screen).
    /// confirmMapping: "Save changes?", leaving the button mapping after something on it changed.
    /// cloudSave: the cloud's save and this Mac's both changed, or the cloud's cannot be read: the player chooses before the start (#957).
    /// advanced: a game's advanced options. confirmReset: "Reset this game's options?". confirmUpdate: install the app's update, or restart into it.
    case options(String), controllers, explanation(String), homeButtonHint, menu, mapping, gamePad(String), library, settings, language, cloudSaves, confirmExit, confirmMapping
    case advanced(String), confirmReset(String), confirmUpdate, cloudSave(CloudSaveQuestion)
    /// #816: a game's page (A on a tile), all games with their filters, the search with its keyboard, the builds, the quick menu (−),
    /// a game's Manage panel, "stopped unexpectedly" after a crash, and the questions before Stop and before quitting a paused game (#952).
    case gamePage(String), allGames, search, builds, quickMenu, manage(String), stopped, confirmStopBuild, confirmQuitPaused
    /// The supported games (#301): every game the engine has a profile for, with its own search (the Library page's way to it).
    case supportedGames
    /// The questions drawn in the middle of the screen, over what they were asked from.
    var isQuestion: Bool {
        switch self {
        case .confirmExit, .confirmMapping, .confirmReset, .confirmUpdate, .stopped, .confirmStopBuild, .confirmQuitPaused: return true
        default: return false
        }
    }
    /// Pages over the whole screen rather than a panel at the side: the cloud saves, a game's controller settings, the button mapping,
    /// a game's page, all games, the search and the builds.
    var isFullScreen: Bool {
        switch self {
        case .cloudSaves, .gamePad, .mapping, .gamePage, .allGames, .search, .builds, .supportedGames: return true
        default: return false
        }
    }
    var scope: String {
        switch self {
        case .gamePage: return "console.gamePage"
        case .allGames: return "console.allGames"
        case .search: return "console.search"
        case .supportedGames: return "console.supported"
        case .builds: return "console.builds"
        case .quickMenu: return "console.quickMenu"
        case .manage: return "console.manage"
        case .stopped: return "console.stopped"
        case .confirmStopBuild: return "console.confirmStop"
        case .confirmQuitPaused: return "console.confirmQuitPaused"
        case .language: return "console.language"
        case .cloudSave: return "console.cloudSave"
        case .confirmExit: return "console.confirmExit"
        case .confirmMapping: return "console.confirmMapping"
        case .advanced: return "console.advanced"
        case .confirmReset: return "console.confirmReset"
        case .confirmUpdate: return "console.confirmUpdate"
        case .cloudSaves: return "console.saves"   // ConsoleCloudSavesPage.scope
        case .library: return "console.library"
        case .settings: return "console.settings"
        case .options: return "console.options"
        case .gamePad: return "console.gamePad"
        case .controllers: return "console.controllers"
        case .explanation: return "console.explanation"
        case .homeButtonHint: return "console.homeHint"
        case .menu: return "console.menu"
        case .mapping: return "console.mapping"
        }
    }
}

/// What the mapping page puts back on Discard: all games' layout (its mode and its Custom buttons) or a game's DM_PAD_MAP.
struct ConsoleMappingUndo: Equatable {
    var mode: PadMode = .standard
    var pad: [String: String] = [:]
    var gameMap: String?
}

/// The controller layout for all games as the mapping sheet shows it: the Controls page's (`ControlLayout`), read by the driver.
/// The buttons are the host's DM_PAD_MAP names (input_map.h), named as on a Switch controller by where they sit.
struct ConsolePadLayout: Equatable {
    /// The 16 buttons in the four groups the sheet shows, each with the key of its heading. The D-pad reads up, down, left, right.
    static let groups: [(key: String, buttons: [String])] = [
        ("console.mapping.group.face", ["A", "B", "X", "Y"]),
        ("console.mapping.group.shoulders", ["L", "R", "ZL", "ZR"]),
        ("console.mapping.group.dpad", ["Up", "Down", "Left", "Right"]),
        ("console.mapping.group.more", ["LS", "RS", "Plus", "Minus"]),
    ]
    static var buttons: [String] { groups.flatMap(\.buttons) }
    var mode: PadMode = .standard
    /// The game whose own mapping this is, nil for all games. A game's mapping has no layouts, only its buttons.
    var gameTitle: String? = nil
    /// What Reset goes back to and what a changed button is told from: nothing for all games (the standard layout), the mapping of
    /// all games for a game's own.
    var baseline: [String: String] = [:]
    /// What each button sends in the layout chosen (for Auto, the one it picks for the controller connected now): only the
    /// buttons that send another, "none" for nothing.
    var sends: [String: String] = [:]
    /// The Custom layout's buttons as stored, whichever layout is chosen: an edit there is kept at once (ControlLayout.setSends), so
    /// going back to another layout does not undo it, and the mapping page asks about it on leaving.
    var custom: [String: String] = [:]
    func output(_ button: String) -> String { sends[button] ?? button }
    func changed(_ button: String) -> Bool { output(button) != (baseline[button] ?? button) }
    /// Whether anything differs from what Reset goes back to: the standard layout, or for a game the mapping of all games.
    var isDefault: Bool { gameTitle == nil ? mode == .standard && sends.isEmpty : sends == baseline }
}

struct ConsoleState {
    var games: [ConsoleGame] = []
    var focusedGameID: String?
    /// A stack allows an explanation or Controllers to return to the options underneath it.
    var sheets: [ConsoleSheet] = []
    var controllers: [ConsoleController] = []
    var isPreview = false
    var padMerge = false
    var padLayout = ConsolePadLayout()
    /// The button whose choices the mapping sheet shows, nil for the list of buttons.
    var mappingRow: String?
    /// The game whose own mapping the mapping sheet shows, nil for all games.
    var mappingGameID: String?
    /// B confirms and A goes back in console mode's menus, as on a Switch (ConsoleButtons). Off: A confirms, as printed on Xbox and
    /// PlayStation controllers.
    var menuSwapAB = false
    /// The General page's switches and the app's update, and whether this Mac has the Home button setting.
    var prefs = ConsolePrefs()
    var homeButtonAvailable = false
    /// The button mapping page's changes are kept only when it is left with Save: the layout it opened with, Swap A and B in menus
    /// as changed there (it applies on Save, so the menus keep their buttons while it is open), and what the driver puts back on Discard.
    var mappingOrigin: ConsolePadLayout?
    var pendingMenuSwapAB: Bool?
    var mappingUndo: ConsoleMappingUndo?
    /// Swap A and B in menus as the mapping page shows it.
    var shownMenuSwapAB: Bool { pendingMenuSwapAB ?? menuSwapAB }
    /// Whether the mapping page has anything to save: the layout or its buttons, or the swap in menus.
    var mappingChanged: Bool {
        guard let origin = mappingOrigin else { return false }
        let customEdited = mappingGameID == nil && mappingUndo.map { $0.pad != padLayout.custom } == true
        return origin.mode != padLayout.mode || origin.sends != padLayout.sends || customEdited || shownMenuSwapAB != menuSwapAB
    }
    /// The cloud saves page's rows, read when it opens (ConsoleCloudSaves).
    var saveRows: [ConsoleSaveRow] = []
    var toast: ConsoleToast?
    var activity: ConsoleActivity?
    var identifyingControllerID: String?
    var assigningControllerID: String?
    var starting: ConsoleStarting = .preparing
    var assigningPlayer: Int?
    var startingGameID: String?
    var exited = false
    var time: Date = Date()
    /// The game paused in the background from its Home menu (#952, org.nxnative.paused.<pid>), nil while none is.
    var pausedGameID: String?
    /// What waits for the paused game to quit, after "Quit <game>?" was answered (or is being asked).
    var afterQuit: ConsoleAfterQuit?
    /// The paused game was asked to quit and has not yet.
    var quittingPaused = false
    /// The tab a game's page shows (L and R), the filter and the order of all games (L and R, Y), the search and what it finds.
    var gameTab: ConsoleGameTab = .overview
    var libraryFilter: ConsoleLibraryFilter = .all
    var librarySort: LibrarySort = .recent
    /// The games' IDs in `librarySort`'s order, as the desktop sorts them (the driver fills it).
    var libraryOrder: [String] = []
    var searchText = ""
    var searchResults: [String] = []
    /// The supported games page: the engine's profiles (the driver reads them when it opens), what was typed into its search, and the
    /// library's game for a title ID the player owns (upper-case title ID to the game's ID), so a row can say so and open its page.
    var supportedGames: [SupportedGame] = []
    var supportedText = ""
    var supportedOwned: [String: String] = [:]
    /// The desktop's build and its queue, for the Builds page.
    var builds = ConsoleBuilds()
    /// The game that stopped unexpectedly and its newest save, for the screen after a crash.
    var stopped: ConsoleStopped?
    var presentedSheet: ConsoleSheet? { sheets.last }
    var focusedGame: ConsoleGame? { games.first { $0.id == focusedGameID } ?? games.first }
    var startingGame: ConsoleGame? { games.first { $0.id == startingGameID } }

    mutating func focus(_ id: String) {
        guard startingGameID == nil, sheets.isEmpty, !exited, games.contains(where: { $0.id == id }) else { return }
        focusedGameID = id
    }
    mutating func moveFocus(_ step: Int) {
        guard !games.isEmpty else { return }
        let index = games.firstIndex { $0.id == focusedGame?.id } ?? 0
        focus(games[min(max(index + step, 0), games.count - 1)].id)
    }
    mutating func play(_ id: String) {
        guard !exited, startingGameID == nil, let game = games.first(where: { $0.id == id }) else { return }
        if pausedGameID == id { return }   // the driver resumes it (resume)
        if game.status == .ready, pausedGameID != nil { askQuitPaused(then: .play(id)); return }   // one game at a time: the paused one quits first
        if game.status == .ready { startingGameID = id; starting = .preparing; sheets = []; stopped = nil }
        else if presentedSheet != .explanation(id) { sheets.append(.explanation(id)) }
    }
    mutating func openOptions(_ id: String) {
        guard !exited, startingGameID == nil, games.contains(where: { $0.id == id }), presentedSheet != .options(id) else { return }
        sheets.append(.options(id))
    }
    mutating func openControllers() {
        guard !exited, startingGameID == nil, presentedSheet != .controllers else { return }
        sheets.append(.controllers)
    }
    mutating func openCloudSaves(_ rows: [ConsoleSaveRow]) {
        guard !exited, startingGameID == nil, presentedSheet != .cloudSaves else { return }
        saveRows = rows
        sheets.append(.cloudSaves)
    }
    mutating func openLibrary() {
        guard !exited, startingGameID == nil, presentedSheet != .library else { return }
        sheets.append(.library)
    }
    mutating func openSettings() {
        guard !exited, startingGameID == nil, presentedSheet != .settings else { return }
        sheets.append(.settings)
    }
    /// Pages and questions over a game's options or the Settings page, each once.
    mutating func push(_ sheet: ConsoleSheet) {
        guard !exited, startingGameID == nil, presentedSheet != sheet else { return }
        sheets.append(sheet)
    }
    mutating func openLanguage() {
        guard !exited, startingGameID == nil, presentedSheet != .language else { return }
        sheets.append(.language)
    }
    /// Asks before leaving console mode: Leave goes to the desktop (exitToDesktop), B or Cancel closes the question.
    mutating func confirmExit() {
        if pausedGameID != nil { askQuitPaused(then: .leave(selecting: nil)); return }   // the paused game would stay behind: quit it first
        guard !exited, startingGameID == nil, presentedSheet != .confirmExit else { return }
        sheets.append(.confirmExit)
    }
    mutating func openMenu() {
        guard !exited, startingGameID == nil, presentedSheet != .menu else { return }
        sheets.append(.menu)
    }
    /// The button mapping of all games (nil) or of one game.
    mutating func openMapping(game id: String? = nil) {
        guard !exited, startingGameID == nil, presentedSheet != .mapping else { return }
        if let id { guard games.first(where: { $0.id == id })?.mapsButtons == true else { return } }
        mappingRow = nil
        mappingGameID = id
        sheets.append(.mapping)
    }
    /// The driver calls it once the page's layout is read: what Discard goes back to.
    mutating func beginMappingEdit(undo: ConsoleMappingUndo) {
        mappingOrigin = padLayout
        pendingMenuSwapAB = nil
        mappingUndo = undo
    }
    /// After Save or Discard: the question and the page close together, back to what the page was opened from.
    mutating func endMappingEdit() {
        if presentedSheet == .confirmMapping { sheets.removeLast() }
        if presentedSheet == .mapping { sheets.removeLast() }
        mappingOrigin = nil; pendingMenuSwapAB = nil; mappingUndo = nil; mappingRow = nil; mappingGameID = nil
    }
    /// A game's controller settings, over its options.
    mutating func openGamePad(_ id: String) {
        guard !exited, startingGameID == nil, presentedSheet != .gamePad(id), let game = games.first(where: { $0.id == id }), game.hasControllerSettings else { return }
        sheets.append(.gamePad(id))
    }
    /// A button's choices in the mapping sheet, or nil for the list again.
    mutating func openMappingRow(_ button: String?) {
        guard presentedSheet == .mapping, button.map(ConsolePadLayout.buttons.contains) ?? true else { return }
        mappingRow = button
    }
    /// The Home button hint (HomeButtonHint.swift), over the home screen after a game quit.
    mutating func showHomeButtonHint() {
        guard !exited, startingGameID == nil, presentedSheet != .homeButtonHint else { return }
        sheets.append(.homeButtonHint)
    }
    /// The question before the start (#957): Starting ends while the player chooses, the sheet holds the question.
    mutating func askCloudSave(_ question: CloudSaveQuestion) {
        guard !exited else { return }
        startingGameID = nil
        sheets = [.cloudSave(question)]
    }
    mutating func back() {
        guard !exited else { return }
        if startingGameID != nil { return } // the driver ends Starting when the game window appears
        if presentedSheet == .mapping, mappingRow != nil { mappingRow = nil; return }   // B in a button's choices goes back to the list
        if presentedSheet == .mapping, mappingChanged { sheets.append(.confirmMapping); return }   // asks before leaving changes
        if presentedSheet == .mapping { mappingOrigin = nil; pendingMenuSwapAB = nil; mappingUndo = nil }
        if presentedSheet == .confirmQuitPaused { if quittingPaused { return }; afterQuit = nil }   // waiting for the quit: B does not take it back
        if presentedSheet == .stopped { stopped = nil }
        if !sheets.isEmpty {
            if presentedSheet == .mapping { mappingGameID = nil }
            sheets.removeLast(); assigningPlayer = nil; assigningControllerID = nil; mappingRow = nil
        }
        else { confirmExit() }   // B on the home screen asks before leaving
    }
    mutating func exitToDesktop() { exited = true; sheets = []; startingGameID = nil; assigningPlayer = nil; assigningControllerID = nil; mappingRow = nil; mappingGameID = nil; mappingOrigin = nil; pendingMenuSwapAB = nil; mappingUndo = nil }
    mutating func returnFromGame() { exited = false; startingGameID = nil; sheets = []; assigningPlayer = nil; assigningControllerID = nil; mappingRow = nil; mappingGameID = nil }
    mutating func setOption(game id: String, setting env: String, value: String) {
        guard !exited, startingGameID == nil, let i = games.firstIndex(where: { $0.id == id }),
              let setting = games[i].visibleSettings.first(where: { $0.env == env }), setting.accepts(value) else { return }
        games[i].values[env] = value
    }
    mutating func assignPlayer(controller id: String, player: Int) {
        guard presentedSheet == .controllers, assigningControllerID == nil || assigningControllerID == id, (1...4).contains(player), controllers.contains(where: { $0.id == id }) else { return }
        // A player belongs to one controller; reassignment releases its former controller.
        for i in controllers.indices {
            if controllers[i].id == id { controllers[i].player = player }
            else if controllers[i].player == player { controllers[i].player = nil }
        }
        assigningPlayer = nil
        assigningControllerID = nil
    }
}

/// Main-actor intents form the entire I/O seam. A real driver owns launching, persistence, hardware
/// and returning to the desktop. B/Escape is `back`; the future controller-guide-button adapter calls `returnFromGame`.
@MainActor protocol ConsoleDriver: ObservableObject {
    var state: ConsoleState { get }
    func focus(_ gameID: String)
    func play(_ gameID: String)
    func openOptions(_ gameID: String)
    func setOption(gameID: String, setting: String, value: String)
    func openControllers()
    /// The console's menu (the Select-type button, or the menu button in the top bar).
    func openMenu()
    /// The menu's Library and Settings pages, and the cloud saves page (from Library).
    func openLibrary()
    func openSettings()
    func openCloudSaves()
    /// The Settings page's display language list.
    func openLanguage()
    /// "Leave console mode?": the menu's Exit asks first (B on the home screen does too, through `back`).
    func confirmExit()
    /// A short rumble at a game's rumble strength on every connected controller, from its controller settings.
    func testRumble(gameID: String)
    /// A game's options brought over from the desktop: a mod or its cheats on or off, its advanced options, its options back to the
    /// defaults (asked first), and the way to the desktop with the game selected (a build, files or a folder to choose).
    func setMod(gameID: String, name: String, on: Bool)
    func setCheatsMaster(gameID: String, on: Bool)
    func setCheat(gameID: String, key: String, on: Bool)
    func openAdvanced(_ gameID: String)
    func askResetOptions(_ gameID: String)
    func resetOptions(_ gameID: String)
    func openOnDesktop(_ gameID: String)
    /// A launcher switch (on the Library, Controllers or Settings page), and the app's update (checked, or asked about and then installed or restarted into).
    func setPref(_ pref: ConsolePref, on: Bool)
    func appUpdateAction()
    func confirmAppUpdate()
    /// The system's Home button setting (macOS 27), from the Controllers page.
    func openSystemHomeSettings()
    /// The button mapping for all games, and a button's choices in it (nil: back to the list).
    func openMapping()
    /// A game's own button mapping, and its controller settings (rumble and the way to that mapping).
    func openGameMapping(_ gameID: String)
    func openGamePad(_ gameID: String)
    func openMappingRow(_ button: String?)
    /// The layout (Auto, Standard, By label, Custom), what one button sends ("none" for nothing; changing one makes the layout Custom)
    /// and Reset, which goes back to the standard layout. They change the Controls page's layout, which Play passes as DM_PAD_MAP.
    func setPadMode(_ mode: PadMode)
    func setPadSends(button: String, to output: String)
    func resetPadMapping()
    /// Swap A and B in console mode's menus (kept in the launcher's defaults).
    func setMenuSwapAB(_ on: Bool)
    /// The answer to "Save changes?": keep what the mapping page changed (and apply Swap A and B in menus), or put it all back.
    func finishMapping(save: Bool)
    func identify(controllerID: String)
    func disconnect(controllerID: String)
    func requestAssignment(controllerID: String)
    func setPadMerge(_ enabled: Bool)
    func dismissToast()
    func requestPlayer(_ player: Int)
    func assignPlayer(controllerID: String, player: Int)
    func back()
    func exitToDesktop()
    func returnFromGame()
    /// A press from a controller: true when the driver used it (player assignment), so it does not also navigate.
    func consumePress(controllerID: String, isBack: Bool) -> Bool
    /// The Home button hint's button: opens the system's Home button settings and closes the hint.
    func openHomeButtonSettings()
    /// The answer to the cloud save question, or "play with this Mac's save" while the download takes long (#957).
    func chooseCloudSave(_ choice: CloudSaveCheck.Choice)
    /// The cloud save question's Try again: the check runs again.
    func retryCloudSave()

    // #816 (ConsoleState+Pages.swift): a game's page and its tabs, all games (filter on L and R, order on Y), the search and its
    // keyboard, the builds and Stop (asked first), the quick menu and a game's Manage panel.
    func openGamePage(_ gameID: String)
    func stepGameTab(_ step: Int)
    func openAllGames()
    func stepLibraryFilter(_ step: Int)
    func toggleLibrarySort()
    func openSearch()
    func typeSearch(_ text: String)
    func deleteSearch()
    /// The Library page's Supported games (#301), and its search's typing and Delete.
    func openSupportedGames()
    func typeSupported(_ text: String)
    func deleteSupported()
    /// The supported games' covers (SupportedCovers), decoded at `maxPixel`. A driver without a library shows none.
    func supportedCovers(maxPixel: Int) -> SupportedCovers
    func openBuilds()
    func askStopBuild()
    func stopBuild()
    func openQuickMenu()
    func openManage(_ gameID: String)
    /// #952: the paused game plays again, and the answer Quit to "Quit <game>?" (the paused game quits, then what waited for it runs).
    func resume(_ gameID: String)
    func quitPausedGame()
}

extension ConsoleDriver {
    func setPadMode(_ mode: PadMode) {}
    func setPadSends(button: String, to output: String) {}
    func resetPadMapping() {}
    func setMenuSwapAB(_ on: Bool) {}
    func finishMapping(save: Bool) {}
    func openGameMapping(_ gameID: String) {}
    func openLibrary() {}
    func openSettings() {}
    func openCloudSaves() {}
    func openLanguage() {}
    func confirmExit() {}
    func testRumble(gameID: String) {}
    func setMod(gameID: String, name: String, on: Bool) {}
    func setCheatsMaster(gameID: String, on: Bool) {}
    func setCheat(gameID: String, key: String, on: Bool) {}
    func openAdvanced(_ gameID: String) {}
    func askResetOptions(_ gameID: String) {}
    func resetOptions(_ gameID: String) {}
    func openOnDesktop(_ gameID: String) { exitToDesktop() }
    func setPref(_ pref: ConsolePref, on: Bool) {}
    func appUpdateAction() {}
    func confirmAppUpdate() {}
    func openSystemHomeSettings() {}
    func openGamePad(_ gameID: String) {}
    func consumePress(controllerID: String, isBack: Bool) -> Bool { false }
    func openHomeButtonSettings() { back() }
    func chooseCloudSave(_ choice: CloudSaveCheck.Choice) { back() }
    func retryCloudSave() { back() }
    func openGamePage(_ gameID: String) {}
    func stepGameTab(_ step: Int) {}
    func openAllGames() {}
    func stepLibraryFilter(_ step: Int) {}
    func toggleLibrarySort() {}
    func openSearch() {}
    func typeSearch(_ text: String) {}
    func deleteSearch() {}
    func openSupportedGames() {}
    func typeSupported(_ text: String) {}
    func deleteSupported() {}
    func supportedCovers(maxPixel: Int) -> SupportedCovers {
        .saved(in: FileManager.default.temporaryDirectory.appendingPathComponent("console-demo-no-banners"), maxPixel: maxPixel)
    }
    func openBuilds() {}
    func askStopBuild() {}
    func stopBuild() {}
    func openQuickMenu() {}
    func openManage(_ gameID: String) {}
    func resume(_ gameID: String) {}
    func quitPausedGame() {}
}

/// Shared choice/range/toggle stepping for mouse, d-pad and keyboard. No settings store is touched.
enum ConsoleOption {
    static func stepped(_ setting: LaunchSetting, value: String, by step: Int) -> String? {
        switch setting.kind {
        case "choice":
            let values = (setting.options ?? []).compactMap(\.first)
            guard !values.isEmpty else { return nil }
            let index = values.firstIndex(of: value) ?? 0
            return values[((index + step) % values.count + values.count) % values.count]
        case "range":
            guard let lo = setting.min, let hi = setting.max, lo <= hi else { return nil }
            let delta = setting.step ?? 0.05
            guard delta > 0, delta.isFinite else { return nil }
            let current = Double(value) ?? Double(setting.def) ?? lo
            return String(format: "%.6g", min(max(lo + ((current - lo) / delta).rounded() * delta + Double(step) * delta, lo), hi))
        case "toggle": return value == setting.onValue ? setting.offValue : setting.onValue
        default: return nil
        }
    }
    static func label(_ setting: LaunchSetting, value: String, lang: Lang) -> String {
        if setting.kind == "toggle" { return L10n.string(value == setting.onValue ? "console.on" : "console.off", lang) }
        if setting.kind == "choice" {
            return setting.options?.first { $0.first == value }.flatMap { $0.count > 1 ? $0[1] : $0.first } ?? value
        }
        return value
    }
}
