import SwiftUI
import XCTest
@testable import NX2Apple
@testable import NXCore
@testable import NXLauncher

@MainActor final class OnboardingNavigationTests: IsolatedDefaultsTestCase {
    private func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
    func testBlockedSetupCanBeDeferredWithoutMarkingItComplete() throws {
        for scenario in 0..<3 {
            let step: OnboardingStep = scenario == 0 ? .xcode : .games
            var state = MockOnboardingDriver.sampleState
            state.step = step; state.xcode = .missing; state.games = .empty
            if scenario == 2 { state.keys = .skipped; state.games = .found([.init(id: "needs-keys", title: "Game", version: "1")]) }
            let driver = MockOnboardingDriver(state: state, animated: false)
            let focus = PadFocus(), pad = LauncherGamepad(observeSystem: false, appIsActive: { true })
            let window = OffscreenWindow(size: .init(width: 900, height: 680))
            window.contentView = NSHostingView(rootView: OnboardingView(driver: driver, lang: .en, gamepad: pad, padFocus: focus))
            window.orderFront(nil)
            defer { pad.deactivate(); window.contentView = nil; window.orderOut(nil); window.close() }
            settle()
            XCTAssertFalse(focus.frames["onboarding", default: []].contains { $0.id == "onboarding.primary" })
            let later = try XCTUnwrap(focus.frames["onboarding", default: []].first { $0.id == "onboarding.later" })
            focus.show(default: later.id); pad.perform(.a); settle()
            XCTAssertEqual(driver.state.exit, .later)
            XCTAssertEqual(driver.state.step, step)
        }
    }
    func testEverySetupStepHasReachableActionsAndKeyboardReturn() throws {
        for dark in [false, true] {
            for step in OnboardingStep.allCases {
                var state = MockOnboardingDriver.sampleState
                state.step = step; state.platform = .selected(.mac); state.xcode = .ready
                state.keys = .valid; state.games = .found([.init(id: "sample", title: "A long sample game title", version: "1.0")]); state.done = .ready
                for task in OnboardingBackgroundTask.allCases { state.background[task] = .done }
                let driver = MockOnboardingDriver(state: state, animated: false)
                let focus = PadFocus(), pad = LauncherGamepad(observeSystem: false, appIsActive: { true })
                let host = NSHostingView(rootView: OnboardingView(driver: driver, lang: .en, gamepad: pad, padFocus: focus)
                    .environment(\.colorScheme, dark ? .dark : .light))
                let window = OffscreenWindow(size: .init(width: 900, height: 680))
                window.contentView = host; window.orderFront(nil)
                defer { pad.deactivate(); window.contentView = nil; window.orderOut(nil); window.close() }
                settle()
                XCTAssertEqual(focus.scope, "onboarding")
                XCTAssertTrue(focus.frames[focus.scope, default: []].contains { $0.id == "onboarding.primary" }, "\(step)")
                if step == .platform {
                    focus.focused = "onboarding.platform.both"; pad.perform(.a); settle()
                    XCTAssertEqual(driver.state.selectedPlatform, .both)
                }
                if step == .games {
                    focus.show(default: "onboarding.choose.games"); settle()
                    let frame = try XCTUnwrap(focus.frames["onboarding"]?.first { $0.id == "onboarding.choose.games" }?.frame)
                    XCTAssertGreaterThanOrEqual(frame.minY, 90)
                    XCTAssertLessThanOrEqual(frame.maxY, host.bounds.height - 100)
                }
                if let path = ProcessInfo.processInfo.environment["NX_REMAINING_CAPTURE_DIR"] {
                    let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: rep)
                    let directory = URL(fileURLWithPath: path)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("setup-\(step.rawValue)-\(dark ? "dark" : "light").png"))
                }
                if step == .welcome {
                    let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
                    XCTAssertTrue(window.performKeyEquivalent(with: event)); settle()
                    XCTAssertEqual(driver.state.step, .platform)
                } else {
                    pad.perform(.b); settle()
                    XCTAssertLessThan(driver.state.step.index, step.index)
                }
            }
        }
    }
    func testUnchosenPlatformSkipsDisabledContinueAndChoosesAPlatform() {
        var state = MockOnboardingDriver.sampleState; state.step = .platform
        let driver = MockOnboardingDriver(state: state, animated: false)
        let focus = PadFocus(), pad = LauncherGamepad(observeSystem: false, appIsActive: { true })
        let host = NSHostingView(rootView: OnboardingView(driver: driver, lang: .en, gamepad: pad, padFocus: focus))
        let window = OffscreenWindow(size: .init(width: 900, height: 680))
        window.contentView = host; window.orderFront(nil)
        defer { pad.deactivate(); window.contentView = nil; window.orderOut(nil); window.close() }
        settle()
        XCTAssertFalse(focus.frames["onboarding", default: []].contains { $0.id == "onboarding.primary" })
        pad.perform(.a); settle()
        XCTAssertEqual(driver.state.step, .platform)
        XCTAssertEqual(driver.state.selectedPlatform, .mac)
    }

    func testWelcomeFooterAndDiskGateAcrossWindowSizes() throws {
        for size in [CGSize(width: 900, height: 680), CGSize(width: 1280, height: 900)] {
            for dark in [false, true] {
                for lang: Lang in [.en, .de, .zh] {
                    for hasSpace in [false, true] {
                        var state = MockOnboardingDriver.sampleState
                        state.welcome = .requirements(freeGB: hasSpace ? 64 : 8, neededGB: 24)
                        let driver = MockOnboardingDriver(state: state, lang: lang, animated: false)
                        let focus = PadFocus(), pad = LauncherGamepad(observeSystem: false, appIsActive: { true })
                        let host = NSHostingView(rootView: OnboardingView(driver: driver, lang: lang, gamepad: pad, padFocus: focus)
                            .environment(\.colorScheme, dark ? .dark : .light))
                        let window = OffscreenWindow(size: size)
                        window.contentView = host; window.orderFront(nil)
                        defer { pad.deactivate(); window.contentView = nil; window.orderOut(nil); window.close() }
                        settle()
                        let targets = focus.frames["onboarding", default: []]
                        XCTAssertTrue(targets.contains { $0.id == "onboarding.later" })
                        XCTAssertFalse(targets.contains { $0.id == "onboarding.back" })
                        if hasSpace {
                            let primary = try XCTUnwrap(targets.first { $0.id == "onboarding.primary" })
                            XCTAssertGreaterThanOrEqual(primary.frame.minY, host.bounds.height - 100)
                            XCTAssertLessThanOrEqual(primary.frame.maxY, host.bounds.height - 20)
                            focus.show(default: "onboarding.primary"); pad.perform(.a); settle()
                            XCTAssertEqual(driver.state.step, .platform)
                            let footer = focus.frames["onboarding", default: []]
                            let firstCard = try XCTUnwrap(footer.first { $0.id == "onboarding.platform.mac" })
                            XCTAssertEqual(firstCard.frame.height, 180, accuracy: 0.5)
                            XCTAssertGreaterThanOrEqual(firstCard.frame.minY, 300)
                            XCTAssertLessThan(firstCard.frame.maxY, primary.frame.minY - 32)
                            if size.height >= 900 {
                                XCTAssertGreaterThan(firstCard.frame.minY, 400, "Short content should use the available body space")
                            }
                            let back = try XCTUnwrap(footer.first { $0.id == "onboarding.back" })
                            let inset = max(0, (host.bounds.width - 900) / 2) + 40
                            XCTAssertEqual(primary.frame.height, 44, accuracy: 0.5)
                            XCTAssertEqual(back.frame.height, primary.frame.height, accuracy: 0.5)
                            XCTAssertGreaterThanOrEqual(back.frame.width, 150)
                            XCTAssertGreaterThanOrEqual(primary.frame.width, 150)
                            XCTAssertEqual(back.frame.minX, inset, accuracy: 0.5)
                            XCTAssertEqual(primary.frame.maxX, host.bounds.width - inset, accuracy: 0.5)
                            pad.perform(.b); settle()
                            XCTAssertEqual(driver.state.step, .welcome)
                        } else {
                            XCTAssertFalse(targets.contains { $0.id == "onboarding.primary" })
                            pad.perform(.a); settle()
                            XCTAssertEqual(driver.state.step, .welcome)
                        }
                        if let path = ProcessInfo.processInfo.environment["NX_ONBOARDING_WELCOME_CAPTURE_DIR"] {
                            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                            host.cacheDisplay(in: host.bounds, to: rep)
                            let directory = URL(fileURLWithPath: path)
                            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                            let name = "welcome-\(Int(size.width))-\(lang.code)-\(dark ? "dark" : "light")-\(hasSpace ? "ready" : "low-space").png"
                            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name))
                        }
                    }
                }
            }
        }
    }

    func testSetupAccordionsStartClosedAndPreserveFocusThroughRecovery() throws {
        for dark in [false, true] {
            for scenario in ["checking", "ready", "failed"] {
                var state = MockOnboardingDriver.sampleState
                state.step = .xcode; state.platform = .selected(.both)
                let failure = OnboardingFailure(message: "Support download failed", details: "Retry diagnostics")
                state.xcode = scenario == "ready" ? .ready : (scenario == "failed" ? .failed(failure) : .checking)
                state.background = Dictionary(uniqueKeysWithValues: OnboardingBackgroundTask.allCases.map {
                    ($0, scenario == "ready" ? .done : (scenario == "failed" ? .failed(failure) : .running(0.4)))
                })
                let driver = MockOnboardingDriver(state: state, animated: false)
                let focus = PadFocus(), pad = LauncherGamepad(observeSystem: false, appIsActive: { true })
                let host = NSHostingView(rootView: OnboardingView(driver: driver, lang: .en, gamepad: pad, padFocus: focus)
                    .environment(\.colorScheme, dark ? .dark : .light))
                let window = OffscreenWindow(size: .init(width: 1280, height: 900))
                window.contentView = host; window.orderFront(nil)
                defer { pad.deactivate(); window.contentView = nil; window.orderOut(nil); window.close() }
                settle()
                let xcode = try XCTUnwrap(focus.frame(of: "onboarding.xcode"))
                let support = try XCTUnwrap(focus.frame(of: "onboarding.support"))
                XCTAssertEqual(xcode.height, 88, accuracy: 0.5)
                XCTAssertEqual(support.height, xcode.height, accuracy: 0.5)
                XCTAssertGreaterThan(xcode.minY, 400, "Collapsed summaries should sit centrally below the compact hero")
                XCTAssertFalse(focus.frames["onboarding", default: []].contains { $0.id == "onboarding.details" })
                func capture(_ phase: String) throws {
                    guard let path = ProcessInfo.processInfo.environment["NX_SETUP_ACCORDION_CAPTURE_DIR"] else { return }
                    RunLoop.main.run(until: Date().addingTimeInterval(0.25))
                    let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: rep)
                    let directory = URL(fileURLWithPath: path)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("setup-\(scenario)-\(dark ? "dark" : "light")-\(phase).png"))
                }
                try capture("closed")
                focus.show(default: "onboarding.xcode"); pad.perform(.a); settle()
                XCTAssertEqual(focus.focused, "onboarding.xcode")
                if scenario == "failed" {
                    XCTAssertNotNil(focus.frame(of: "onboarding.details"))
                    focus.focused = "onboarding.details"; pad.perform(.a); settle()
                    driver.retry(.xcode); settle()
                    XCTAssertEqual(focus.focused, "onboarding.xcode", "A removed recovery control must restore focus to its parent row")
                }
                focus.focused = "onboarding.support"; pad.perform(.a); settle()
                XCTAssertEqual(focus.focused, "onboarding.support")
                try capture("expanded")
                focus.focused = "onboarding.xcode"; pad.perform(.a); settle()
                XCTAssertNil(focus.frame(of: "onboarding.details"))
                XCTAssertEqual(focus.focused, "onboarding.xcode")
                XCTAssertNotNil(focus.frame(of: "onboarding.support"))
            }
        }
    }

    func testActivationRestoresAValidTargetAfterChangingSteps() {
        let driver = MockOnboardingDriver(animated: false)
        let focus = PadFocus(), pad = LauncherGamepad(observeSystem: false, appIsActive: { true })
        let host = NSHostingView(rootView: OnboardingView(driver: driver, lang: .en, gamepad: pad, padFocus: focus))
        let window = OffscreenWindow(size: .init(width: 900, height: 680))
        window.contentView = host; window.orderFront(nil)
        defer { pad.deactivate(); window.contentView = nil; window.orderOut(nil); window.close() }
        settle()
        pad.perform(.a); settle()
        XCTAssertEqual(driver.state.step, .platform)
        pad.perform(.a); settle()
        XCTAssertEqual(driver.state.selectedPlatform, .mac)
        XCTAssertEqual(focus.focused, "onboarding.platform.mac")
    }

    func testXcodeActionsAreInlineAndFooterWaitsForAllRequirements() throws {
        let failure = OnboardingFailure(message: "Retry required")
        let cases: [(String, OnboardingState.Xcode, Bool)] = [
            ("missing", .missing, false), ("waiting", .downloading, false), ("prepare", .needsSetup, false),
            ("working", .settingUp, false), ("failed", .failed(failure), false), ("ready", .ready, false),
            ("support-failed", .ready, true)
        ]
        for dark in [false, true] {
            for (name, xcode, supportFailed) in cases {
                var state = MockOnboardingDriver.sampleState
                state.step = .xcode; state.platform = .selected(.mac); state.xcode = xcode
                state.background = Dictionary(uniqueKeysWithValues: OnboardingBackgroundTask.allCases.map { ($0, .done) })
                if supportFailed { state.background[.tools] = .failed(failure) }
                let driver = MockOnboardingDriver(state: state, animated: false)
                let focus = PadFocus(), pad = LauncherGamepad(observeSystem: false, appIsActive: { true })
                let host = NSHostingView(rootView: OnboardingView(driver: driver, lang: .en, gamepad: pad, padFocus: focus)
                    .environment(\.colorScheme, dark ? .dark : .light))
                let window = OffscreenWindow(size: .init(width: 1280, height: 900))
                window.contentView = host; window.orderFront(nil)
                defer { pad.deactivate(); window.contentView = nil; window.orderOut(nil); window.close() }
                settle()
                XCTAssertEqual(focus.frame(of: "onboarding.primary") != nil, xcode == .ready && !supportFailed)
                if supportFailed { XCTAssertNotNil(focus.frame(of: "onboarding.support.action")) }
                if let path = ProcessInfo.processInfo.environment["NX_XCODE_ROW_CAPTURE_DIR"] {
                    let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: rep)
                    let directory = URL(fileURLWithPath: path)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("xcode-\(name)-\(dark ? "dark" : "light").png"))
                }
                if xcode == .downloading {
                    let snapshot = driver.state
                    focus.show(default: "onboarding.xcode.action"); pad.perform(.a); settle()
                    XCTAssertEqual(driver.state, snapshot)
                    XCTAssertEqual(focus.focused, "onboarding.xcode.action")
                } else if xcode == .needsSetup {
                    focus.show(default: "onboarding.xcode.action"); pad.perform(.a); settle()
                    XCTAssertEqual(driver.state.xcode, .settingUp)
                    XCTAssertEqual(focus.focused, "onboarding.xcode")
                } else if xcode == .ready && !supportFailed {
                    focus.show(default: "onboarding.primary"); pad.perform(.a); settle()
                    XCTAssertEqual(driver.state.step, .keys)
                }
            }
        }
    }

    func testKeysStayInlineAndRequireConfirmationOrExplicitDeferral() throws {
        let states: [(String, OnboardingState.Keys)] = [("empty", .empty), ("checking", .validating),
            ("valid", .valid), ("invalid", .invalid("Choose a prod.keys file from your own console.")), ("deferred", .skipped)]
        for dark in [false, true] {
            for (name, keys) in states {
                var state = MockOnboardingDriver.sampleState
                state.step = .keys; state.platform = .selected(.mac); state.keys = keys
                if keys != .empty { state.keysFile = URL(fileURLWithPath: "/Demo/prod.keys") }
                let driver = MockOnboardingDriver(state: state, animated: false)
                let focus = PadFocus(), pad = LauncherGamepad(observeSystem: false, appIsActive: { true })
                let host = NSHostingView(rootView: OnboardingView(driver: driver, lang: .en, gamepad: pad, padFocus: focus)
                    .environment(\.colorScheme, dark ? .dark : .light))
                let window = OffscreenWindow(size: .init(width: 900, height: 680))
                window.contentView = host; window.orderFront(nil)
                defer { pad.deactivate(); window.contentView = nil; window.orderOut(nil); window.close() }
                settle()
                XCTAssertNotNil(focus.frame(of: "onboarding.keys.help"))
                XCTAssertEqual(focus.frame(of: "onboarding.primary") != nil, keys == .valid)
                XCTAssertEqual(focus.frame(of: "onboarding.keys.later") != nil, keys != .validating)
                XCTAssertEqual(focus.frame(of: "onboarding.choose.keys") != nil, keys != .validating)
                if let path = ProcessInfo.processInfo.environment["NX_KEYS_CAPTURE_DIR"] {
                    let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: rep)
                    let directory = URL(fileURLWithPath: path)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("keys-\(name)-\(dark ? "dark" : "light").png"))
                }
                if keys == .valid {
                    focus.show(default: "onboarding.primary"); pad.perform(.a); settle()
                    XCTAssertEqual(driver.state.step, .games)
                } else if keys != .validating {
                    focus.show(default: "onboarding.keys.later"); pad.perform(.a); settle()
                    XCTAssertEqual(driver.state.step, .games)
                    XCTAssertEqual(driver.state.keys, .skipped)
                    pad.perform(.b); settle()
                    XCTAssertNotNil(focus.frame(of: "onboarding.keys.later"))
                }
            }
        }
    }

}
