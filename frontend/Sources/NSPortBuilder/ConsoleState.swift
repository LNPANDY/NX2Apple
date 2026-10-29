import SwiftUI
import Combine

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
    var artwork: Image?
    var status: Status
    /// The exact launcher's model, already decoded and localized by the driver.
    var settings: [LaunchSetting] = []
    var values: [String: String] = [:]

    func value(_ setting: LaunchSetting) -> String { values[setting.env] ?? setting.def }
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

struct ConsoleToast: Equatable, Identifiable {
    var id = UUID()
    /// A button glyph shown after the message (the controller in use), for a toast that names a button.
    var glyph: ConsoleGlyphs.Glyph? = nil
    /// Already localized by the driver, using console connection/identification keys.
    var message: String
}

enum ConsoleStarting: Equatable {
    case preparing, compilingShaders(completed: Int, total: Int), opening
    var progress: Double? {
        if case let .compilingShaders(completed, total) = self, total > 0 { return min(max(Double(completed) / Double(total), 0), 1) }
        return nil
    }
}

enum ConsoleSheet: Equatable {
    case options(String), controllers, explanation(String)
    var scope: String {
        switch self {
        case .options: return "console.options"
        case .controllers: return "console.controllers"
        case .explanation: return "console.explanation"
        }
    }
}

struct ConsoleState {
    var games: [ConsoleGame] = []
    var focusedGameID: String?
    /// A stack allows an explanation or Controllers to return to the options underneath it.
    var sheets: [ConsoleSheet] = []
    var controllers: [ConsoleController] = []
    var isPreview = false
    var padMerge = false
    var toast: ConsoleToast?
    var identifyingControllerID: String?
    var assigningControllerID: String?
    var starting: ConsoleStarting = .preparing
    var assigningPlayer: Int?
    var startingGameID: String?
    var exited = false
    var time: Date = Date()
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
        if game.status == .ready { startingGameID = id; starting = .preparing; sheets = [] }
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
    mutating func back() {
        guard !exited else { return }
        if startingGameID != nil { return } // the driver ends Starting when the game window appears
        if !sheets.isEmpty { sheets.removeLast(); assigningPlayer = nil; assigningControllerID = nil }
        else { exitToDesktop() }
    }
    mutating func exitToDesktop() { exited = true; sheets = []; startingGameID = nil; assigningPlayer = nil; assigningControllerID = nil }
    mutating func returnFromGame() { exited = false; startingGameID = nil; sheets = []; assigningPlayer = nil; assigningControllerID = nil }
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
}

extension ConsoleDriver { func consumePress(controllerID: String, isBack: Bool) -> Bool { false } }

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
