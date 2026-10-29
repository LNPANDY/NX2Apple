import XCTest

@MainActor final class ShellWindowTests: XCTestCase {
    private let app = XCUIApplication()
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    func testStageManagerResize() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Stage Manager needs an iPad simulator")
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["--screen", "library"]
        app.launch()
        XCTAssertTrue(app.buttons["tile.tide"].waitForExistence(timeout: 10))
        app.buttons["tile.tide"].tap()
        capture("stage-manager-wide-before")
        let frame = app.windows.firstMatch.frame
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let corner = origin.withOffset(CGVector(dx: frame.width - 16, dy: frame.height - 16))
        corner.press(forDuration: 0.5, thenDragTo: origin.withOffset(CGVector(dx: frame.width * 0.6, dy: frame.height * 0.72)))
        capture("stage-manager-compact")
        let tree = XCTAttachment(string: app.debugDescription + "\nSPRINGBOARD\n" + XCUIApplication(bundleIdentifier: "com.apple.springboard").debugDescription)
        tree.name = "stage-manager-hierarchy"
        tree.lifetime = .keepAlways
        add(tree)
        XCTAssertTrue(app.staticTexts["The Quiet Tide"].firstMatch.exists)
        XCTAssertTrue(app.buttons["settings.open"].waitForExistence(timeout: 5), "The actual window resize must enter compact layout")
    }
}

@MainActor final class ShellInputAndResizeTests: XCTestCase {
    private let app = XCUIApplication()
    private func capture(_ name: String) {
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        image.name = name
        image.lifetime = .keepAlways
        add(image)
    }
    func testSemanticControllerActions() {
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["--screen", "focus", "--input-test"]
        app.launch()
        XCTAssertTrue(app.buttons["qa.input.right"].waitForExistence(timeout: 10))
        app.buttons["qa.input.right"].tap()
        XCTAssertEqual(app.staticTexts["hero.title"].label, "The Quiet Tide")
        capture("controller-right-selects-second-cover")
        app.buttons["qa.input.activate"].tap()
        XCTAssertTrue(app.alerts["Demo action"].waitForExistence(timeout: 5))
        app.alerts.buttons["OK"].tap()
        app.buttons["qa.input.settings"].tap()
        let toggle = app.switches["setting.DM_SHOW_FPS"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        // Pushed settings start on Back, then Play and the play mode choice. Beside the library they start on the choice.
        let pushed = app.buttons["library.back"].exists
        for _ in 0..<(pushed ? 3 : 1) { app.buttons["qa.input.down"].tap() }
        app.buttons["qa.input.activate"].tap()
        XCTAssertEqual(toggle.value as? String, "1")
        app.buttons["qa.input.activate"].tap()
        XCTAssertEqual(toggle.value as? String, "0")
        capture("controller-toggles-setting")
        app.buttons["qa.input.back"].tap()
        if pushed { XCTAssertFalse(app.buttons["library.back"].isHittable) }
        capture("controller-back-restores-library")
        // The one-column row: right walks through every cover, also the ones still off screen.
        guard pushed else { return }
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["qa.input.right"].waitForExistence(timeout: 10))
        for _ in 0..<6 { app.buttons["qa.input.right"].tap() }
        XCTAssertEqual(app.staticTexts["hero.title"].label, "Amber Hours")
        capture("controller-reaches-last-cover")
    }

    func testCoverFlowFollowsTheController() {
        XCUIDevice.shared.orientation = .landscapeLeft
        app.launchArguments = ["--screen", "focus", "--input-test"]
        app.launch()
        XCTAssertTrue(app.buttons["qa.input.right"].waitForExistence(timeout: 10))
        for _ in 0..<3 { app.buttons["qa.input.right"].tap() }
        XCTAssertEqual(app.staticTexts["hero.title"].label, "Moonlit Express")
        app.buttons["qa.input.left"].tap()
        XCTAssertEqual(app.staticTexts["hero.title"].label, "Paper Trails")
        capture("cover-flow-controller")
        XCUIDevice.shared.orientation = .portrait
    }

    /// The foldable stand-in: the same running shell goes from the folded size to the unfolded one and back.
    /// Selection, an edited toggle, the open settings and their scroll position must survive both changes.
    func testFoldKeepsSelectionSettingsAndScroll() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "The fold stand-in needs an iPad canvas")
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["--screen", "library", "--fold-test"]
        app.launch()
        XCTAssertTrue(app.buttons["tile.tide"].waitForExistence(timeout: 10))
        app.buttons["tile.tide"].tap()
        app.buttons["settings.open"].tap()
        let toggle = app.switches["setting.DM_SHOW_FPS"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.tap()
        app.scrollViews.element(boundBy: app.scrollViews.count - 1).swipeUp()
        capture("folded-settings-scrolled")
        app.buttons["qa.fold"].tap()
        // Unfolded: two panes, the hero beside the open settings.
        XCTAssertEqual(app.staticTexts["hero.title"].label, "The Quiet Tide")
        XCTAssertTrue(toggle.exists)
        XCTAssertFalse(app.buttons["library.back"].exists)
        capture("unfolded-settings-scrolled")
        app.buttons["qa.fold"].tap()
        XCTAssertTrue(app.buttons["library.back"].waitForExistence(timeout: 5))
        capture("refolded-settings-scrolled")
        app.scrollViews.element(boundBy: app.scrollViews.count - 1).swipeDown()
        XCTAssertEqual(toggle.value as? String, "1")
        app.buttons["library.back"].tap()
        XCTAssertEqual(app.staticTexts["hero.title"].label, "The Quiet Tide")
    }
}
