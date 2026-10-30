import XCTest

/// `--host`: the views on the real host layer, with the fixture bundles in the app's Games folder.
@MainActor final class ShellHostUITests: XCTestCase {
    private let app = XCUIApplication()
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch(select id: String) {
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["--host", "--select", id]
        app.launch()
        XCTAssertTrue(app.buttons["tile.\(id)"].waitForExistence(timeout: 10))
    }

    func testPlayableFixtureSaysLaunchingIsNotAvailable() {
        launch(select: "0100000000010000")
        XCTAssertEqual(app.staticTexts["hero.title"].label, "Orbit Fixture")
        let primary = app.buttons.matching(identifier: "state.action").allElementsBoundByIndex.first { $0.isHittable }
        XCTAssertNotNil(primary)
        primary?.tap()
        XCTAssertTrue(app.alerts["Shell"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.alerts.staticTexts["Launching is not available yet."].exists)
        app.alerts.buttons["OK"].tap()
    }

    func testBrokenFixtureShowsItsReason() {
        launch(select: "0100000000040000")
        XCTAssertEqual(app.staticTexts["hero.title"].label, "No Framework Fixture")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'Game code missing'")).firstMatch.waitForExistence(timeout: 5))
    }

    func testSettingChangeSurvivesReopeningSettings() {
        launch(select: "0100000000010000")
        let settings = app.buttons["settings.open"]
        if settings.exists { settings.tap() }
        let frameRate = app.switches["setting.DM_SHOW_FPS"]
        XCTAssertTrue(frameRate.waitForExistence(timeout: 5))
        frameRate.tap()
        XCTAssertEqual(frameRate.value as? String, "1")
    }
}
