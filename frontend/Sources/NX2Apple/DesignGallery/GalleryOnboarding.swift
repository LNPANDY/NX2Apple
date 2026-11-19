import SwiftUI
import NXCore
import NXLauncher

/// The onboarding's states the state gallery shows next to the demo scenarios (MockOnboardingDriver.Scenario): every step, and
/// every state of a step the flow has (OnboardingState's Welcome, Platform, Xcode, Keys, Games and Done). Each scene opens straight
/// at its step with that state, so no scene shows the first step unless it is about it.
enum OnboardingGalleryState: String, CaseIterable {
    case welcomeLowSpace
    case platformEmpty, platformChosen
    case xcodeChecking, xcodeMissing, xcodeDisconnected, xcodeDownloading, xcodeNeedsSetup, xcodeSettingUp, xcodeOld
    case xcodeSupportFailed, xcodeEngineTransfer
    case keysSearching, keysEmpty, keysFound, keysValidating, keysValid, keysSkipped
    case gamesEmpty, gamesScanning, gamesFound, gamesNeedKeys
    case done

    var title: String {
        switch self {
        case .welcomeLowSpace: return "Welcome: not enough space"
        case .platformEmpty: return "Platform: nothing chosen"
        case .platformChosen: return "Platform: Both chosen"
        case .xcodeChecking: return "Xcode: checking"
        case .xcodeMissing: return "Xcode: missing"
        case .xcodeDisconnected: return "Xcode: selected one gone"
        case .xcodeDownloading: return "Xcode: downloading"
        case .xcodeNeedsSetup: return "Xcode: needs setup"
        case .xcodeSettingUp: return "Xcode: setting up"
        case .xcodeOld: return "Xcode: older than NVN needs"
        case .xcodeSupportFailed: return "Xcode: support failed"
        case .xcodeEngineTransfer: return "Xcode: game support download"
        case .keysSearching: return "Keys: searching"
        case .keysEmpty: return "Keys: none found"
        case .keysFound: return "Keys: file found"
        case .keysValidating: return "Keys: checking"
        case .keysValid: return "Keys: verified"
        case .keysSkipped: return "Keys: skipped"
        case .gamesEmpty: return "Games: nothing chosen"
        case .gamesScanning: return "Games: scanning"
        case .gamesFound: return "Games: found"
        case .gamesNeedKeys: return "Games: need keys"
        case .done: return "Done"
        }
    }

    /// The step the scene opens at.
    var step: OnboardingStep {
        switch self {
        case .welcomeLowSpace: return .welcome
        case .platformEmpty, .platformChosen: return .platform
        case .xcodeChecking, .xcodeMissing, .xcodeDisconnected, .xcodeDownloading, .xcodeNeedsSetup, .xcodeSettingUp, .xcodeOld,
             .xcodeSupportFailed, .xcodeEngineTransfer: return .xcode
        case .keysSearching, .keysEmpty, .keysFound, .keysValidating, .keysValid, .keysSkipped: return .keys
        case .gamesEmpty, .gamesScanning, .gamesFound, .gamesNeedKeys: return .games
        case .done: return .done
        }
    }

    /// Scenes whose point is the list of an Xcode section open it.
    var expandsSetup: Bool { [.xcodeSettingUp, .xcodeOld, .xcodeSupportFailed, .xcodeEngineTransfer].contains(self) }
}

extension MockOnboardingDriver.Scenario {
    var galleryTitle: String {
        switch self {
        case .fresh: return "Welcome (fresh)"
        case .oldMac: return "Welcome: older macOS (oldMac)"
        case .xcodeReady: return "Xcode: ready (xcodeReady)"
        case .xcodeFailed: return "Xcode: failed (xcodeFailed)"
        case .keysInvalid: return "Keys: invalid (keysInvalid)"
        case .noGames: return "Games: none found (noGames)"
        }
    }

    /// The step the scene opens at: the step the scenario is about.
    var galleryStep: OnboardingStep {
        switch self {
        case .fresh, .oldMac: return .welcome
        case .xcodeReady, .xcodeFailed: return .xcode
        case .keysInvalid: return .keys
        case .noGames: return .games
        }
    }
}

extension GalleryScene {
    /// The onboarding's scenes in the order of the flow.
    static var onboardingScenes: [GalleryScene] {
        let scenarios = MockOnboardingDriver.Scenario.allCases.map(GalleryScene.onboarding)
        let states = OnboardingGalleryState.allCases.map(GalleryScene.onboardingState)
        return (scenarios + states).enumerated().sorted { a, b in
            let (sa, sb) = (a.element.onboardingStep ?? .welcome, b.element.onboardingStep ?? .welcome)
            return sa.index != sb.index ? sa.index < sb.index : a.offset < b.offset
        }.map(\.element)
    }

    /// The onboarding step a scene opens at, nil for a scene of another group.
    var onboardingStep: OnboardingStep? {
        switch self {
        case .onboarding(let scenario): return scenario.galleryStep
        case .onboardingState(let state): return state.step
        default: return nil
        }
    }
}

@MainActor extension GalleryFixtures {
    /// The demo flow at a scenario's own step, playing on from there (its timers run, Retry and Continue work).
    func onboardingView(_ scenario: MockOnboardingDriver.Scenario) -> AnyView {
        var s = Self.onboardingBase(step: scenario.galleryStep)
        switch scenario {
        case .fresh, .oldMac: break
        case .xcodeReady:
            s.xcode = .ready
            s.setup = Dictionary(uniqueKeysWithValues: s.setupTasks.map { ($0, .done) })
        case .xcodeFailed:
            let failure = OnboardingFailure(message: L10n.string("onboarding.demo.xcodeFailure", lang), details: "Demo: MetalToolchain download returned HTTP 503.")
            s.xcode = .failed(failure)
            s.setup = [.selected: .done, .license: .done, .firstLaunch: .done, .metal: .failed(failure), .ios: .queued]
        case .keysInvalid:
            s.keysFile = URL(fileURLWithPath: "/Users/Shared/Switch/prod.keys")
            s.keys = .invalid(L10n.string("onboarding.demo.keysFailure", lang))
        case .noGames:
            s.games = .none
        }
        return AnyView(OnboardingDemoHost(scenario: scenario, state: s, lang: lang))
    }

    /// One state of a step, held still (no demo timers), so the gallery and the captures show exactly that state.
    func onboardingView(_ state: OnboardingGalleryState) -> AnyView {
        var s = Self.onboardingBase(step: state.step)
        let keysFile = URL(fileURLWithPath: "/Users/Shared/Switch/prod.keys")
        switch state {
        case .welcomeLowSpace: s.welcome = .requirements(freeGB: 8, neededGB: 24)
        case .platformEmpty: s.platform = .empty
        case .platformChosen: break
        case .xcodeChecking, .xcodeMissing, .xcodeDisconnected, .xcodeDownloading, .xcodeNeedsSetup:
            s.xcode = [.xcodeChecking: .checking, .xcodeMissing: .missing, .xcodeDisconnected: .disconnected,
                       .xcodeDownloading: .downloading, .xcodeNeedsSetup: .needsSetup][state] ?? .checking
            s.setup = [:]
            s.background = [.python: .done, .dotnet: .running(0.5), .tools: .queued]
        case .xcodeSettingUp:
            s.xcode = .settingUp
            s.setup = [.selected: .done, .license: .done, .firstLaunch: .done, .metal: .running(0.65), .ios: .queued]
            s.background = [.python: .done, .dotnet: .running(0.5), .tools: .queued]
        case .xcodeOld:
            s.xcodeTooOldForNVN = true
        case .xcodeSupportFailed:
            let failure = OnboardingFailure(message: String(format: L10n.string("dep.install.fail", lang), ".NET"), details: "dotnet-install: HTTP 503")
            s.background[.dotnet] = .failed(failure)
        case .xcodeEngineTransfer:
            s.engineTransfer = OnboardingTransferProgress(fraction: 0.42, detail: "1.2 GB / 2.9 GB")
        case .keysSearching: s.keys = .searching
        case .keysEmpty: s.keys = .empty
        case .keysFound: s.keys = .found(keysFile)
        case .keysValidating: s.keysFile = keysFile; s.keys = .validating
        case .keysValid: s.keysFile = keysFile; s.keys = .valid
        case .keysSkipped: s.keys = .skipped
        case .gamesEmpty: s.games = .empty
        case .gamesScanning: s.games = .scanning
        case .gamesFound: s.games = .found(onboardingGames(count: 6))
        case .gamesNeedKeys:
            s.keys = .skipped
            s.games = .found(onboardingGames(count: 4))
        case .done: s.done = .celebrating
        }
        return AnyView(OnboardingDemoHost(scenario: .fresh, state: s, lang: lang, animated: false, expandSetup: state.expandsSetup))
    }

    /// A state at `step` with every step before it complete: the Mac and iOS chosen, Xcode and its support ready, the keys verified.
    nonisolated static func onboardingBase(step: OnboardingStep) -> OnboardingState {
        var s = MockOnboardingDriver.sampleState
        s.step = step
        guard step != .welcome else { return s }
        s.platform = .selected(.both)
        s.xcode = .ready
        s.setup = Dictionary(uniqueKeysWithValues: s.setupTasks.map { ($0, .done) })
        s.background = Dictionary(uniqueKeysWithValues: OnboardingBackgroundTask.allCases.map { ($0, .done) })
        if step.index > OnboardingStep.keys.index {
            s.keysFile = URL(fileURLWithPath: "/Users/Shared/Switch/prod.keys")
            s.keys = .valid
        }
        return s
    }
}
