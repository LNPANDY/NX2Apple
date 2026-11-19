import XCTest
import SwiftUI
import AppKit
@testable import NX2Apple
@testable import NXCore
@testable import NXLauncher
import NXModel

/// Opt-in renders of every GalleryScene for the design review of LNPANDY/NX2Apple#1458, one PNG per scene, drawn by the same
/// renderer as the state gallery's export (#1459). `NX_LAUNCHER_CAPTURE_DIR=<dir> swift test --filter LauncherDesignCaptureTests`,
/// `NX_CAPTURE_LANG=de` for another language.
@MainActor final class LauncherDesignCaptureTests: IsolatedDefaultsTestCase {
    func testRenderDesignScenes() throws {
        guard let directory = ProcessInfo.processInfo.environment["NX_LAUNCHER_CAPTURE_DIR"] else { throw XCTSkip("Set NX_LAUNCHER_CAPTURE_DIR to capture native views") }
        let output = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.accessory)
        let lang = CaptureLanguage.current(.en)
        let fixtures = GalleryFixtures(lang: lang)
        for scene in GalleryScene.allCases {
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

    func testTheGalleryIsAskedForByFlagOrEnvironment() {
        XCTAssertFalse(GalleryMode.requested, "the test runner is not the gallery")
    }

    func testTheGalleryRunnerStartsNothing() {
        let runner = GalleryProcessRunner()
        XCTAssertFalse(runner.capture(ProcessLaunch(["/usr/bin/true"])).started)
        XCTAssertThrowsError(try runner.start(ProcessLaunch(["/usr/bin/true"]), onOutput: { _ in }, onExit: { _ in }))
    }
}
