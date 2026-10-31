import XCTest

@MainActor final class ShellDemoUITests: XCTestCase {
    private let app = XCUIApplication()
    private var extraArguments: [String] = []
    override func setUpWithError() throws { continueAfterFailure = false }
    private func launch(_ screen: String) {
        app.launchArguments = ["--screen", screen] + extraArguments
        app.launch()
        XCTAssertTrue(app.buttons[screen.hasPrefix("controllers") ? "controllers.close" : "controllers.open"].waitForExistence(timeout: 10))
    }
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    func testActionsAndNavigation() {
        XCUIDevice.shared.orientation = .portrait
        launch("library")
        let settings = app.buttons["settings.open"]
        if settings.exists { settings.tap() }
        let frameRate = app.switches["setting.DM_SHOW_FPS"]
        XCTAssertTrue(frameRate.waitForExistence(timeout: 5))
        frameRate.tap()
        XCTAssertEqual(frameRate.value as? String, "1")
        let primary = app.buttons.matching(identifier: "state.action").allElementsBoundByIndex.first { $0.isHittable }
        XCTAssertNotNil(primary)
        primary?.tap()
        XCTAssertTrue(app.alerts["Demo action"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.alerts.staticTexts["Play requested. The demo does not launch games."].exists)
        app.alerts.buttons["OK"].tap()
        if app.buttons["library.back"].exists { app.buttons["library.back"].tap() }
        // The panel slides away first.
        let orbit = app.buttons["tile.orbit"]
        expectation(for: NSPredicate(format: "isHittable == true"), evaluatedWith: orbit)
        waitForExpectations(timeout: 5)
        app.buttons["controllers.open"].tap()
        // The sheet lists the real controllers when the device has any, the sample ones otherwise.
        XCTAssertTrue(app.buttons["controllers.close"].waitForExistence(timeout: 5))
        app.buttons["controllers.close"].tap()
        XCTAssertFalse(app.staticTexts["Pro Controller"].exists)
    }
    /// Swipes from the left screen edge to `fraction` of the width. A slow release at a short distance cancels.
    private func edgeSwipe(to fraction: CGFloat, fling: Bool) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5)).withOffset(CGVector(dx: 1, dy: 0))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: fraction, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: fling ? .fast : .slow, thenHoldForDuration: fling ? 0 : 0.5)
    }
    func testEdgeSwipeClosesSettingsAndCanBeCancelled() {
        XCUIDevice.shared.orientation = .portrait
        launch("library")
        app.buttons["settings.open"].tap()
        XCTAssertTrue(app.buttons["library.back"].waitForExistence(timeout: 5))
        edgeSwipe(to: 0.1, fling: false)
        XCTAssertTrue(app.buttons["library.back"].waitForExistence(timeout: 5), "A short swipe let go slowly springs back")
        XCTAssertTrue(app.buttons["library.back"].isHittable)
        edgeSwipe(to: 0.9, fling: true)
        expectation(for: NSPredicate(format: "isHittable == false"), evaluatedWith: app.buttons["library.back"])
        waitForExpectations(timeout: 5)
        XCTAssertTrue(app.buttons["settings.open"].isHittable)
        capture("edge-swipe-back-to-library")
    }
    func testEdgeSwipeClosesControllers() {
        XCUIDevice.shared.orientation = .portrait
        launch("library")
        app.buttons["controllers.open"].tap()
        XCTAssertTrue(app.buttons["controllers.close"].waitForExistence(timeout: 5))
        edgeSwipe(to: 0.9, fling: true)
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.buttons["controllers.close"])
        waitForExpectations(timeout: 5)
        XCTAssertTrue(app.buttons["controllers.open"].isHittable)
    }
    func testShortShelfSelects() {
        XCUIDevice.shared.orientation = .landscapeLeft
        extraArguments = ["--games", "3"]
        launch("library")
        app.buttons["tile.paper"].tap()
        XCTAssertEqual(app.staticTexts["hero.title"].label, "Paper Trails")
        // Under the card the state line is the way out: what is wrong and what to do.
        XCTAssertEqual(app.buttons["state.chip"].label, "Needs game data, Choose game data…")
        XCUIDevice.shared.orientation = .portrait
    }
    func testLargeText() {
        XCUIDevice.shared.orientation = .portrait
        for screen in ["library", "settings", "needs-data", "needs-update", "broken", "empty", "controllers", "controllers-empty", "focus"] {
            launch(screen)
            capture("\(screen)-largest-text")
            if screen == "settings" {
                for index in 1...4 {
                    app.scrollViews.element(boundBy: app.scrollViews.count - 1).swipeUp()
                    capture("settings-scroll-\(index)-largest-text")
                }
            }
        }
    }
    func testSelectionSurvivesRotation() {
        XCUIDevice.shared.orientation = .portrait
        launch("library")
        app.buttons["tile.tide"].tap()
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertEqual(app.staticTexts["hero.title"].label, "The Quiet Tide")
        capture("selected-after-rotation")
    }
}
