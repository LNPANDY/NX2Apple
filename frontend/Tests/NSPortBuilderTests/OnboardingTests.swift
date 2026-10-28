import XCTest
import SwiftUI
@testable import NSPortBuilder

final class OnboardingTests: XCTestCase {
    func testNextBackAndGates() {
        var s = OnboardingState()
        XCTAssertTrue(s.primaryEnabled)
        s.back(); XCTAssertEqual(s.step, .welcome)
        s.next(); XCTAssertEqual(s.step, .platform)
        XCTAssertFalse(s.primaryEnabled)
        s.next(); XCTAssertEqual(s.step, .platform)
        s.platform = .selected(.mac)
        s.next(); XCTAssertEqual(s.step, .xcode)
        XCTAssertFalse(s.primaryEnabled)
        s.xcode = .ready
        XCTAssertFalse(s.canAdvance, "Xcode alone does not finish background preparation")
        s.background = Dictionary(uniqueKeysWithValues: OnboardingBackgroundTask.allCases.map { ($0, .done) })
        XCTAssertTrue(s.canAdvance)
        s.next(); XCTAssertEqual(s.step, .keys)
        s.keys = .valid
        s.next(); XCTAssertEqual(s.step, .games)
        s.games = .found([])
        XCTAssertFalse(s.primaryEnabled)
        s.games = .found([.init(id: "sample", title: "Sample", version: "1")])
        s.next(); XCTAssertEqual(s.step, .done)
        XCTAssertFalse(s.primaryEnabled)
        s.done = .ready
        XCTAssertTrue(s.primaryEnabled)
        s.next(); XCTAssertEqual(s.step, .done)
        s.back(); XCTAssertEqual(s.step, .games)
    }

    func testDiskSpaceGateAndEveryXcodeAction() {
        var s = OnboardingState()
        s.welcome = .requirements(freeGB: 8, neededGB: 24)
        XCTAssertFalse(s.primaryEnabled)
        s.next(); XCTAssertEqual(s.step, .welcome)
        s.step = .xcode
        for value: OnboardingState.Xcode in [.checking, .downloading, .settingUp] {
            s.xcode = value
            XCTAssertFalse(s.primaryEnabled)
            XCTAssertFalse(s.canAdvance)
        }
        s.xcode = .missing
        XCTAssertEqual(s.primary, .getXcode); XCTAssertTrue(s.primaryEnabled)
        s.xcode = .needsSetup
        XCTAssertEqual(s.primary, .finishXcodeSetup); XCTAssertTrue(s.primaryEnabled)
        s.xcode = .failed(.init(message: "Failure", details: "Diagnostic"))
        XCTAssertEqual(s.primary, .retry); XCTAssertTrue(s.primaryEnabled)
        XCTAssertFalse(s.canAdvance)
        s.xcode = .ready
        s.background[.python] = .failed(.init(message: "Failure"))
        XCTAssertEqual(s.primary, .retry)
        XCTAssertFalse(s.canAdvance)
    }

    func testKeysAndGamesNeverAdvanceBeforeValidation() {
        var s = OnboardingState()
        s.step = .keys
        for value: OnboardingState.Keys in [.empty, .searching, .validating, .invalid("Invalid")] {
            s.keys = value
            XCTAssertFalse(s.primaryEnabled)
            s.next(); XCTAssertEqual(s.step, .keys)
        }
        s.keys = .found(URL(fileURLWithPath: "/Demo/prod.keys"))
        XCTAssertEqual(s.primary, .confirmKeys)
        XCTAssertTrue(s.primaryEnabled)
        XCTAssertFalse(s.canAdvance, "Confirming a found file still needs validation")
        s.step = .games
        for value: OnboardingState.Games in [.empty, .scanning, .none, .found([])] {
            s.games = value
            XCTAssertFalse(s.primaryEnabled)
            s.next(); XCTAssertEqual(s.step, .games)
        }
    }

    func testIOSIsAddedOnlyForIPhoneChoices() {
        var s = OnboardingState()
        for platform in OnboardingPlatform.allCases {
            s.platform = .selected(platform)
            XCTAssertEqual(s.setupTasks.contains(.ios), platform != .mac)
            XCTAssertEqual(s.setupTasks.count, platform == .mac ? 4 : 5)
        }
    }

    func testResumeKeepsStepAndSelectionsWithoutPreferences() async {
        await MainActor.run {
            var snapshot = OnboardingState()
            snapshot.step = .games
            snapshot.platform = .selected(.both)
            snapshot.keys = .valid
            snapshot.games = .found([.init(id: "game", title: "Game", version: "1")])
            snapshot.done = .ready
            let d = MockOnboardingDriver(state: snapshot, animated: false)
            d.skipForLater()
            XCTAssertEqual(d.state.exit, .later)
            XCTAssertEqual(d.resumeSnapshot, snapshot)
            XCTAssertFalse(d.state.primaryEnabled)
            d.next(); d.back()
            XCTAssertEqual(d.state.step, .games)
            let restored = MockOnboardingDriver(state: d.resumeSnapshot!, animated: false)
            XCTAssertEqual(restored.state, snapshot)
            d.resume()
            XCTAssertEqual(d.state, snapshot)
            restored.back(); XCTAssertEqual(restored.state.step, .keys)
            d.next(); d.openLibrary()
            XCTAssertEqual(d.state.exit, .library)
            d.resume()
            XCTAssertEqual(d.state.exit, .library, "A completed flow cannot resume an older paused snapshot")
        }
    }

    func testReturningToPlatformAddsIOSWork() async {
        await MainActor.run {
            var s = OnboardingState()
            s.step = .platform
            s.platform = .selected(.mac)
            s.xcode = .ready
            let d = MockOnboardingDriver(state: s, animated: false)
            d.choosePlatform(.both)
            XCTAssertEqual(d.state.xcode, .needsSetup)
            XCTAssertEqual(d.state.setup[.ios], .queued)
            XCTAssertTrue(d.state.setupTasks.contains(.ios))
        }
    }

    func testDriverIntentsAreGated() async {
        await MainActor.run {
            let d = MockOnboardingDriver(animated: false)
            d.getXcode(); d.finishXcodeSetup(); d.confirmKeys(); d.openLibrary()
            XCTAssertEqual(d.state.step, .welcome)
            XCTAssertEqual(d.state.xcode, .checking)
            XCTAssertNil(d.state.exit)
            d.start(); d.choosePlatform(.iphone); d.next()
            XCTAssertEqual(d.state.step, .xcode)
            XCTAssertEqual(d.state.setupTasks.last, .ios)
            d.next(); XCTAssertEqual(d.state.step, .xcode)
        }
    }

    func testAllOnboardingStringsHaveBothLanguages() {
        let keys = L10n.table.keys.filter { $0.hasPrefix("onboarding.") }
        XCTAssertGreaterThan(keys.count, 80)
        for key in keys {
            XCTAssertFalse(L10n.string(key, .en).isEmpty, key)
            XCTAssertFalse(L10n.string(key, .zh).isEmpty, key)
            XCTAssertNotEqual(L10n.string(key, .en), key)
            XCTAssertNotEqual(L10n.string(key, .zh), key)
        }
        for step in OnboardingStep.allCases {
            XCTAssertNotNil(L10n.table[step.titleKey])
            XCTAssertNotNil(L10n.table["onboarding.\(step.rawValue).note"])
        }
        for task in OnboardingSetupTask.allCases { XCTAssertNotNil(L10n.table[task.titleKey]) }
        for task in OnboardingBackgroundTask.allCases { XCTAssertNotNil(L10n.table[task.titleKey]) }
        XCTAssertTrue(L10n.selfCheck().isEmpty)
    }

    /// The same opt-in native capture path as the launcher's other visual QA tests.
    @MainActor func testRenderOnboardingForVisualQA() throws {
        guard let directory = ProcessInfo.processInfo.environment["NX_ONBOARDING_CAPTURE_DIR"] else {
            throw XCTSkip("Set NX_ONBOARDING_CAPTURE_DIR to capture onboarding")
        }
        let output = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.accessory)
        for lang: Lang in [.en, .zh] {
            for step in OnboardingStep.allCases {
                var s = OnboardingState()
                s.step = step
                s.platform = .selected(.both)
                s.xcode = .settingUp
                s.setup = [.selected: .done, .license: .done, .firstLaunch: .done, .metal: .running(0.65), .ios: .queued]
                s.background = [.python: .done, .dotnet: .running(0.5), .tools: .queued]
                s.keys = .found(URL(fileURLWithPath: "/Demo/Switch/prod.keys"))
                s.games = .found([.init(id: "a", title: "Super Mario Odyssey", version: "1.0.0"),
                                  .init(id: "b", title: "Balatro", version: "1.0.0")])
                s.done = .ready
                let driver = MockOnboardingDriver(state: s, lang: lang, animated: false)
                let view = OnboardingView(driver: driver, lang: lang)
                let host = NSHostingView(rootView: view)
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 680),
                                      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
                window.contentView = host
                window.orderFront(nil)
                RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                host.layoutSubtreeIfNeeded()
                let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: rep)
                try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                    .write(to: output.appendingPathComponent("\(step.rawValue)-\(lang.rawValue).png"))
                window.orderOut(nil)
            }
        }
        // The Xcode step keeps one card size across its states: capture each to compare.
        let failure = OnboardingFailure(message: "The Metal Toolchain could not be downloaded.", details: "HTTP 503")
        let states: [(String, OnboardingState.Xcode)] = [("checking", .checking), ("missing", .missing), ("downloading", .downloading),
            ("needsSetup", .needsSetup), ("settingUp", .settingUp), ("ready", .ready), ("failed", .failed(failure))]
        for (name, xcode) in states {
            var s = OnboardingState()
            s.step = .xcode; s.platform = .selected(.both); s.xcode = xcode
            s.setup = [.selected: .done, .license: .done, .firstLaunch: .done, .metal: .running(0.65), .ios: .running(0.2)]
            s.background = [.python: .done, .dotnet: .running(0.5), .tools: .queued]
            let driver = MockOnboardingDriver(state: s, lang: .en, animated: false)
            let host = NSHostingView(rootView: OnboardingView(driver: driver, lang: .en))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 680),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.contentView = host
            window.orderFront(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                .write(to: output.appendingPathComponent("xcode-\(name)-en.png"))
            window.orderOut(nil)
        }
    }
}
