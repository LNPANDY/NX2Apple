import XCTest
import SwiftUI
import AppKit
@testable import NX2Apple
@testable import NXCore
@testable import NXLauncher
import NXModel

/// Opt-in renders of every GalleryScene for the design review of LNPANDY/NX2Apple#1458, one PNG per scene, drawn by the same
/// renderer as the state gallery's export (#1459). `NX_LAUNCHER_CAPTURE_DIR=<dir> swift test --filter LauncherDesignCaptureTests`,
/// `NX_CAPTURE_LANG=de` for another language, `NX_CAPTURE_GROUP=Sheets` for one group of the gallery.
@MainActor final class LauncherDesignCaptureTests: IsolatedDefaultsTestCase {
    func testRenderDesignScenes() throws {
        guard let directory = ProcessInfo.processInfo.environment["NX_LAUNCHER_CAPTURE_DIR"] else { throw XCTSkip("Set NX_LAUNCHER_CAPTURE_DIR to capture native views") }
        let output = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.accessory)
        let lang = CaptureLanguage.current(.en)
        // Generated art by default, so CI and PR images never show a player's library. NX_CAPTURE_REAL_COVERS=1 uses copies of this
        // Mac's own covers, as the gallery does.
        var fixtures = GalleryFixtures(lang: lang)
        if ProcessInfo.processInfo.environment["NX_CAPTURE_REAL_COVERS"] == "1" {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nx-capture-covers-" + UUID().uuidString)
            addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
            fixtures = GalleryFixtures(lang: lang, covers: GalleryRealCovers.snapshot(into: folder), coverFolder: folder)
        }
        // NX_CAPTURE_GROUP=Sheets (a GalleryScene.Group's name) renders that group only, NX_CAPTURE_SCENES=console only the scenes
        // whose id starts with it (several prefixes separated by commas)
        let group = ProcessInfo.processInfo.environment["NX_CAPTURE_GROUP"]
        let only = (ProcessInfo.processInfo.environment["NX_CAPTURE_SCENES"] ?? "").split(separator: ",").map(String.init)
        for scene in GalleryScene.allCases where (group == nil || scene.group.rawValue == group) && (only.isEmpty || only.contains { scene.id.hasPrefix($0) }) {
            let png = try XCTUnwrap(GalleryRenderer.png(scene, fixtures: fixtures), scene.id)
            try png.write(to: output.appendingPathComponent("\(scene.id)-\(lang.code).png"))
        }
    }
}

/// The state gallery's catalogue (#1459): every scene builds and draws, and none touches the app's own defaults.
@MainActor final class GalleryCatalogTests: IsolatedDefaultsTestCase {
    func testEverySceneDrawsWithoutTouchingTheSharedDefaults() throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let before = NSDictionary(dictionary: Self.sharedKeys())
        let fixtures = GalleryFixtures(lang: Lang("de"))
        var ids: Set<String> = []
        for scene in GalleryScene.allCases {
            XCTAssertTrue(ids.insert(scene.id).inserted, "\(scene.id) is named once")
            let png = try XCTUnwrap(GalleryRenderer.png(scene, fixtures: fixtures, settle: 0.25), scene.id)
            XCTAssertGreaterThan(png.count, 1000, "\(scene.id) draws something")
        }
        XCTAssertEqual(NSDictionary(dictionary: Self.sharedKeys()), before, "a gallery scene wrote to the app's defaults")
        XCTAssertGreaterThanOrEqual(GalleryScene.allCases.count, 60)
        for group in GalleryScene.Group.allCases {
            XCTAssertTrue(GalleryScene.allCases.contains { $0.group == group }, "\(group.rawValue) has scenes")
        }
    }

    /// Every onboarding scene opens at its own step with its state, not at the first step (xcodeReady, keysInvalid, xcodeFailed and
    /// noGames all showed Welcome before): the step count and the step's title in the rendered view say which step it is.
    func testEveryOnboardingSceneOpensAtItsOwnStep() throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        // SwiftUI builds its accessibility tree only for an assistive client
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApplication.shared.accessibilityAttributeValue(enhanced)
        NSApplication.shared.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApplication.shared.accessibilitySetValue(previous ?? false, forAttribute: enhanced) }
        let fixtures = GalleryFixtures(lang: .en)
        let scenes = GalleryScene.allCases.filter { $0.group == .onboarding }
        XCTAssertGreaterThanOrEqual(scenes.count, 25, "every step and state of the flow")
        var rendered: [GalleryScene: OnboardingStep] = [:]
        for scene in scenes {
            let expected = try XCTUnwrap(scene.onboardingStep, scene.id)
            let window = OffscreenWindow(size: scene.size)
            window.contentView = NSHostingView(rootView: fixtures.view(scene))
            window.orderFront(nil)
            defer { window.contentView = nil; window.orderOut(nil); window.close() }
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            let labels = Self.texts(in: window)
            let shown = OnboardingStep.allCases.filter {
                labels.contains(String(format: L10n.string("onboarding.stepCount", .en), $0.index + 1, OnboardingStep.allCases.count))
            }
            XCTAssertEqual(shown, [expected], "\(scene.id) shows \(shown)")
            XCTAssertTrue(labels.contains(L10n.string(expected.titleKey, .en)), "\(scene.id) shows the title of \(expected)")
            rendered[scene] = shown.first
        }
        for scenario in [MockOnboardingDriver.Scenario.xcodeReady, .keysInvalid, .xcodeFailed, .noGames] {
            XCTAssertNotEqual(rendered[.onboarding(scenario)], rendered[.onboarding(.fresh)], "\(scenario) opens at its own step, not Welcome")
        }
        XCTAssertEqual(Set(rendered.values), Set(OnboardingStep.allCases), "every step has a scene")
    }

    private static func texts(in node: NSObject) -> Set<String> {
        var labels: Set<String> = []
        func visit(_ node: NSObject) {
            for selector in ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"] {
                let sel = NSSelectorFromString(selector)
                if node.responds(to: sel), let value = node.perform(sel)?.takeUnretainedValue() as? String { labels.insert(value) }
            }
            let children = NSSelectorFromString("accessibilityChildren")
            if node.responds(to: children), let next = node.perform(children)?.takeUnretainedValue() as? [NSObject] { next.forEach(visit) }
        }
        visit(node)
        return labels
    }

    func testTheGalleryIsAskedForByFlagOrEnvironment() {
        XCTAssertFalse(GalleryMode.requested, "the test runner is not the gallery")
    }

    func testTheGalleryRunnerStartsNothing() {
        let runner = GalleryProcessRunner()
        XCTAssertFalse(runner.capture(ProcessLaunch(["/usr/bin/true"])).started)
        XCTAssertThrowsError(try runner.start(ProcessLaunch(["/usr/bin/true"]), onOutput: { _ in }, onExit: { _ in }))
    }
}
