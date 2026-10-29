import XCTest

/// Screens for visual review. With TEST_RUNNER_SHOT_DIR set, each capture is also written there as a PNG.
@MainActor final class ShellCaptureTests: XCTestCase {
    private let app = XCUIApplication()
    private var directory: String? { ProcessInfo.processInfo.environment["SHOT_DIR"] }
    private var prefix: String { ProcessInfo.processInfo.environment["SHOT_PREFIX"] ?? (UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "phone") }
    private let screens = ["library", "settings", "needs-data", "needs-update", "broken", "empty", "controllers", "controllers-empty", "focus"]

    private func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(prefix)-\(name).png"))
        }
    }
    private func launch(_ arguments: [String]) {
        app.terminate()
        // TEST_RUNNER_SHOT_REAL_ART=1: the demo reads real game art from the host (see RealArt.swift).
        app.launchArguments = arguments + ((ProcessInfo.processInfo.environment["SHOT_REAL_ART"] ?? "").isEmpty ? [] : ["--real-art"])
        app.launch()
        _ = app.buttons["controllers.open"].firstMatch.waitForExistence(timeout: 10)
            || app.buttons["controllers.close"].waitForExistence(timeout: 2)
        sleep(1)
    }

    func testCaptureMatrix() {
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            let suffix = orientation == .portrait ? "portrait" : "landscape"
            for screen in screens {
                launch(["--screen", screen])
                shot("\(screen)-\(suffix)")
                if screen == "settings" {
                    for index in 1...2 {
                        app.scrollViews.element(boundBy: app.scrollViews.count - 1).swipeUp()
                        shot("settings-scroll\(index)-\(suffix)")
                    }
                }
            }
            launch(["--screen", "library", "--games", "3", "--select", "tide"])
            shot("three-games-\(suffix)")
            launch(["--screen", "library", "--select", "drift"])
            shot("library-drift-\(suffix)")
        }
        XCUIDevice.shared.orientation = .portrait
    }

    /// Run with the Simulator's text size at its largest (xcrun simctl ui <id> content_size accessibility-extra-extra-extra-large).
    func testCaptureLargeText() {
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            let suffix = orientation == .portrait ? "portrait" : "landscape"
            for screen in ["library", "settings", "broken", "controllers"] {
                launch(["--screen", screen])
                shot("large-\(screen)-\(suffix)")
            }
        }
        XCUIDevice.shared.orientation = .portrait
    }

    /// The fold stand-in: one running shell resized between a folded and an unfolded screen.
    func testCaptureFold() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "The fold stand-in needs an iPad canvas")
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            let suffix = orientation == .portrait ? "portrait" : "landscape"
            for screen in ["library", "settings", "needs-data", "controllers"] {
                launch(["--screen", screen, "--fold-test"])
                shot("fold-\(screen)-folded-\(suffix)")
                launch(["--screen", screen, "--fold-test", "--unfolded"])
                shot("fold-\(screen)-unfolded-\(suffix)")
            }
        }
        XCUIDevice.shared.orientation = .portrait
    }
}
