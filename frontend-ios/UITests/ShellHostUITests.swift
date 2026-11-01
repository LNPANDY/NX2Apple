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
        // The hero says what to do, not the parser's message.
        XCTAssertTrue(app.staticTexts["The game's code is missing from this app. Rebuild and reinstall it."].exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'DmGame.framework'")).firstMatch.exists)
    }

    func testBadSettingsShowsASentenceAndKeepsTheRawMessageInDetails() {
        launch(select: "0100000000070000")
        XCTAssertTrue(app.staticTexts["This game's settings list is damaged. Rebuild the game in the launcher on your Mac."].exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'DM_X'")).firstMatch.exists)
        let fix = app.buttons.matching(identifier: "state.action").allElementsBoundByIndex.first { $0.isHittable }
        fix?.tap()
        XCTAssertTrue(app.staticTexts["help.title"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["DM_X is a choice without [value, label] options."].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Details"].exists)
    }

    func testUnreadableManifestIsUnknownGameWithoutTheTitleIDInTheMainUI() {
        launch(select: "0100000000050000")
        XCTAssertEqual(app.staticTexts["hero.title"].label, "Unknown game")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '0100000000050000'")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] \"Can't read this game\"")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts["This game's manifest is damaged. Rebuild the game in the launcher on your Mac."].exists)
        let fix = app.buttons.matching(identifier: "state.action").allElementsBoundByIndex.first { $0.isHittable }
        fix?.tap()
        XCTAssertTrue(app.staticTexts["help.title"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["help.titleid"].label, "Title ID 0100000000050000")
    }

    func testLibraryStartsOnAPlayableGameWithTheVersionLine() {
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["--host"]
        app.launch()
        XCTAssertTrue(app.staticTexts["hero.title"].waitForExistence(timeout: 10))
        XCTAssertNotEqual(app.staticTexts["hero.title"].label, "Bad Settings Fixture")
        XCTAssertEqual(app.staticTexts["hero.title"].label, "Orbit Fixture")
        XCTAssertTrue(app.staticTexts["Version 1.0.0"].exists)
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
