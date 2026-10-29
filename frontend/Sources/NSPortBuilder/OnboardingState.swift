import AppKit
import Combine

enum OnboardingStep: String, CaseIterable, Codable {
    case welcome, platform, xcode, keys, games, done
    var index: Int { Self.allCases.firstIndex(of: self)! }
    var titleKey: String { "onboarding.\(rawValue).title" }
}

/// What NVN games' shaders need: the Metal compiler of Xcode 27.1, which itself needs macOS 26.6.
enum OnboardingNVN {
    static let minimumXcode = [27, 1]
    static let minimumOS = OperatingSystemVersion(majorVersion: 26, minorVersion: 6, patchVersion: 0)

    static func osTooOld(_ v: OperatingSystemVersion) -> Bool {
        (v.majorVersion, v.minorVersion, v.patchVersion) < (minimumOS.majorVersion, minimumOS.minorVersion, minimumOS.patchVersion)
    }

    /// `xcodebuild -version` prints "Xcode 27.1" first. An unreadable version is not reported as too old.
    static func xcodeVersion(from output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline) where line.hasPrefix("Xcode ") {
            let v = line.dropFirst(6).split(separator: " ").first.map(String.init) ?? ""
            if v.split(separator: ".").allSatisfy({ Int($0) != nil }), !v.isEmpty { return v }
        }
        return nil
    }

    static func xcodeTooOld(_ version: String?) -> Bool {
        guard let version else { return false }
        var parts = version.split(separator: ".").compactMap { Int($0) }
        while parts.count < minimumXcode.count { parts.append(0) }
        for (a, b) in zip(parts, minimumXcode) where a != b { return a < b }
        return false
    }
}

enum OnboardingPlatform: String, CaseIterable {
    case mac, iphone, both
    var includesIOS: Bool { self != .mac }
    var symbol: String { self == .mac ? "desktopcomputer" : (self == .iphone ? "iphone" : "laptopcomputer.and.iphone") }
}

/// The message is already localized by the driver. Details are a diagnostic log, never keys or file contents.
struct OnboardingFailure: Equatable {
    var message: String
    var details: String = ""
}

enum OnboardingTaskState: Equatable {
    case queued, running(Double?), done, failed(OnboardingFailure)
    var isDone: Bool { self == .done }
    var statusKey: String {
        switch self {
        case .queued: return "onboarding.queued"
        case .running: return "onboarding.running"
        case .done: return "onboarding.ready"
        case .failed: return "onboarding.failed"
        }
    }
}

enum OnboardingSetupTask: String, CaseIterable {
    case selected, license, firstLaunch, metal, ios
    var titleKey: String { "onboarding.setup.\(rawValue)" }
}

enum OnboardingBackgroundTask: String, CaseIterable {
    case python, dotnet, tools
    var titleKey: String { "onboarding.background.\(rawValue)" }
}

struct OnboardingGame: Identifiable, Equatable {
    var id: String
    var title: String
    var version: String
    /// Decoded artwork is supplied by the driver. The view never reads or fetches a file.
    var cover: NSImage? = nil
}

struct OnboardingState: Equatable {
    enum Welcome: Equatable {
        case requirements(freeGB: Int, neededGB: Int)
        var hasSpace: Bool {
            switch self { case let .requirements(free, needed): return free >= needed }
        }
    }
    enum Platform: Equatable { case empty, selected(OnboardingPlatform) }
    enum Xcode: Equatable {
        case checking, missing, downloading, needsSetup, settingUp, ready, failed(OnboardingFailure)
        var statusKey: String {
            switch self {
            case .checking: return "onboarding.xcode.checking"
            case .missing: return "onboarding.xcode.missing"
            case .downloading: return "onboarding.xcode.downloading"
            case .needsSetup: return "onboarding.xcode.needsSetup"
            case .settingUp: return "onboarding.xcode.settingUp"
            case .ready: return "onboarding.xcode.ready"
            case .failed: return "onboarding.failed"
            }
        }
    }
    enum Keys: Equatable {
        case searching, found(URL), validating, valid, invalid(String), empty
        var statusKey: String {
            switch self {
            case .searching: return "onboarding.keys.searching"
            case .found: return "onboarding.keys.found"
            case .validating: return "onboarding.keys.validating"
            case .valid: return "onboarding.keys.valid"
            case .invalid: return "onboarding.keys.invalid"
            case .empty: return "onboarding.keys.empty"
            }
        }
    }
    enum Games: Equatable { case empty, scanning, found([OnboardingGame]), none }
    enum Done: Equatable { case celebrating, ready }
    enum Exit: Equatable { case later, library }
    enum Primary: Equatable { case start, next, getXcode, finishXcodeSetup, retry, confirmKeys, openLibrary, waiting }

    var step: OnboardingStep = .welcome
    var welcome: Welcome = .requirements(freeGB: 0, neededGB: 0)
    var platform: Platform = .empty
    var xcode: Xcode = .checking
    var setup: [OnboardingSetupTask: OnboardingTaskState] = [:]
    var background: [OnboardingBackgroundTask: OnboardingTaskState] = [:]
    var keys: Keys = .empty
    var games: Games = .empty
    var done: Done = .celebrating
    var exit: Exit? = nil
    /// NVN games need the Metal compiler of Xcode 27.1, which needs macOS 26.6. Hints only: setup continues either way.
    var osTooOldForNVN = false
    var xcodeTooOldForNVN = false

    var selectedPlatform: OnboardingPlatform? {
        if case let .selected(value) = platform { return value }
        return nil
    }
    var setupTasks: [OnboardingSetupTask] {
        OnboardingSetupTask.allCases.filter { $0 != .ios || selectedPlatform?.includesIOS == true }
    }
    var backgroundReady: Bool { OnboardingBackgroundTask.allCases.allSatisfy { background[$0] == .done } }
    var backgroundFailed: Bool {
        background.values.contains { if case .failed = $0 { return true }; return false }
    }
    var canAdvance: Bool {
        switch step {
        case .welcome: return welcome.hasSpace
        case .platform: return selectedPlatform != nil
        case .xcode: return xcode == .ready && backgroundReady
        case .keys: return keys == .valid
        case .games: if case let .found(games) = games { return !games.isEmpty }; return false
        case .done: return false
        }
    }
    var primary: Primary {
        switch step {
        case .welcome: return .start
        case .platform, .games: return .next
        case .xcode:
            switch xcode {
            case .missing: return .getXcode
            case .needsSetup: return .finishXcodeSetup
            case .failed: return .retry
            default: return backgroundFailed ? .retry : (canAdvance ? .next : .waiting)
            }
        case .keys: if case .found = keys { return .confirmKeys }; return canAdvance ? .next : .waiting
        case .done: return .openLibrary
        }
    }
    var primaryEnabled: Bool {
        guard exit == nil else { return false }
        switch primary {
        case .start, .next: return canAdvance
        case .waiting: return false
        case .openLibrary: return done == .ready
        default: return true
        }
    }
    var primaryKey: String {
        switch primary {
        case .start: return "onboarding.start"
        case .next: return "onboarding.continue"
        case .getXcode: return "onboarding.getXcode"
        case .finishXcodeSetup: return "onboarding.finishSetup"
        case .retry: return "onboarding.retry"
        case .confirmKeys: return "onboarding.confirmKeys"
        case .openLibrary: return "onboarding.openLibrary"
        case .waiting: return "onboarding.waiting"
        }
    }

    /// Pure navigation, shared by the demo and the future real driver. No step can skip its prerequisite.
    mutating func next() {
        guard exit == nil, canAdvance, step.index + 1 < OnboardingStep.allCases.count else { return }
        step = OnboardingStep.allCases[step.index + 1]
    }
    mutating func back() {
        guard exit == nil, step.index > 0 else { return }
        step = OnboardingStep.allCases[step.index - 1]
    }
}

/// Publish a fresh value when detection or installation changes. Own all work, security-scoped URL access,
/// persistence and automatic advancement in the driver; the generic view only renders and sends intents.
@MainActor protocol OnboardingDriver: ObservableObject {
    var state: OnboardingState { get }
    func start()
    func choosePlatform(_ platform: OnboardingPlatform)
    func getXcode()
    func finishXcodeSetup()
    func retry(_ step: OnboardingStep)
    func chooseKeys(_ url: URL)
    func confirmKeys()
    func chooseGames(_ url: URL)
    func back()
    func next()
    func skipForLater()
    func openLibrary()
}
