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
        // Settings start on Back, then Play and the play mode choice, then the toggle.
        XCTAssertTrue(app.buttons["library.back"].exists)
        for _ in 0..<3 { app.buttons["qa.input.down"].tap() }
        app.buttons["qa.input.activate"].tap()
        XCTAssertEqual(toggle.value as? String, "1")
        app.buttons["qa.input.activate"].tap()
        XCTAssertEqual(toggle.value as? String, "0")
        capture("controller-toggles-setting")
        app.buttons["qa.input.back"].tap()
        XCTAssertFalse(app.buttons["library.back"].isHittable)
        capture("controller-back-restores-library")
        // The one-column row: right walks through every cover, also the ones still off screen.
        guard UIDevice.current.userInterfaceIdiom == .phone else { return }
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
        // Unfolded: the settings stay open, now as a panel over the library.
        XCTAssertEqual(app.staticTexts["detail.title"].label, "The Quiet Tide")
        XCTAssertTrue(toggle.exists)
        XCTAssertTrue(app.buttons["library.back"].exists)
        capture("unfolded-settings-scrolled")
        app.buttons["qa.fold"].tap()
        XCTAssertTrue(app.buttons["library.back"].waitForExistence(timeout: 5))
        capture("refolded-settings-scrolled")
        app.scrollViews.element(boundBy: app.scrollViews.count - 1).swipeDown()
        XCTAssertEqual(toggle.value as? String, "1")
        app.buttons["library.back"].tap()
        XCTAssertEqual(app.staticTexts["hero.title"].label, "The Quiet Tide")
    }

    /// The middle of the centred card, measured from the title under it. The tilted cards' accessibility frames are
    /// skewed by their 3D transform, so a tap on the element itself can land on a neighbour.
    private func centreCard() -> XCUICoordinate {
        let window = app.windows.firstMatch.frame
        let title = app.staticTexts["hero.title"].frame
        return app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: window.midX - window.minX, dy: title.minY - window.minY - 80))
    }
    private let sampleTitles = ["Orbit Valley", "The Quiet Tide", "Paper Trails", "Moonlit Express", "Wild Gardens", "Drift Atlas", "Amber Hours"]

    /// A touch swipe that snaps to another card makes it the selection: title, counter and buttons follow.
    private func swipeCoverFlow(_ arguments: [String]) {
        XCUIDevice.shared.orientation = .landscapeLeft
        app.launchArguments = arguments
        app.launch()
        XCTAssertTrue(app.buttons["tile.orbit"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["hero.title"].label, "Orbit Valley")
        let start = centreCard()
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: -260, dy: 0)), withVelocity: .fast, thenHoldForDuration: 0)
        sleep(2)
        let counter = app.staticTexts.matching(NSPredicate(format: "label ENDSWITH ' of 7'")).firstMatch
        XCTAssertTrue(counter.exists)
        let place = Int(counter.label.split(separator: " ").first ?? "") ?? 1
        XCTAssertGreaterThan(place, 1, "the swipe moved the carousel")
        XCTAssertEqual(app.staticTexts["hero.title"].label, sampleTitles[place - 1])
        XCTAssertFalse(app.alerts["Demo action"].exists, "a swipe that ends on a card never launches it")
        capture("cover-flow-swiped")
        XCUIDevice.shared.orientation = .portrait
    }
    func testCoverFlowTouchSwipeSelects() { swipeCoverFlow(["--screen", "library"]) }
    func testCoverFlowTouchSwipeSelectsUnfolded() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "The fold stand-in needs an iPad canvas")
        swipeCoverFlow(["--screen", "library", "--fold-test", "--unfolded"])
    }

    /// A broken game says what is wrong and explains the fix, the log stays one step away for a bug report.
    func testBrokenGameExplainsTheFix() {
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["--screen", "broken"]
        app.launch()
        XCTAssertTrue(app.staticTexts["hero.title"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] 'game files damaged'")).firstMatch.exists)
        let fix = app.buttons.matching(identifier: "state.action").allElementsBoundByIndex.first { $0.isHittable }
        XCTAssertEqual(fix?.label, "How to fix, Wild Gardens")
        fix?.tap()
        XCTAssertTrue(app.staticTexts["help.title"].waitForExistence(timeout: 5))
        capture("broken-how-to-fix")
        app.buttons["help.log"].tap()
        XCTAssertTrue(app.alerts["Demo action"].waitForExistence(timeout: 5))
        app.alerts.buttons["OK"].tap()
        app.buttons["help.done"].tap()
        XCTAssertFalse(app.staticTexts["help.title"].waitForExistence(timeout: 1))
    }

    /// Tapping a side card centres it and starts nothing. Tapping the centred card runs its primary action once.
    func testCoverFlowTaps() {
        XCUIDevice.shared.orientation = .landscapeLeft
        app.launchArguments = ["--screen", "library"]
        app.launch()
        let side = app.buttons["tile.tide"]
        XCTAssertTrue(side.waitForExistence(timeout: 10))
        side.tap()
        sleep(1)
        XCTAssertEqual(app.staticTexts["hero.title"].label, "The Quiet Tide")
        XCTAssertFalse(app.alerts["Demo action"].exists, "a side card only comes to the middle")
        centreCard().tap()
        XCTAssertTrue(app.alerts["Demo action"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.alerts.staticTexts["Play requested. The demo does not launch games."].exists)
        app.alerts.buttons["OK"].tap()
        XCTAssertFalse(app.alerts["Demo action"].waitForExistence(timeout: 1), "the action ran once")
        XCUIDevice.shared.orientation = .portrait
    }

    /// A slow drag to the next card, then at once a quick swipe the same way: two cards on, never back.
    func testSlowDragThenQuickSwipeAdvancesTwo() {
        XCUIDevice.shared.orientation = .landscapeLeft
        app.launchArguments = ["--screen", "library"]
        app.launch()
        XCTAssertTrue(app.buttons["tile.orbit"].waitForExistence(timeout: 10))
        let start = centreCard()
        let window = app.windows.firstMatch.frame
        let step = window.width * 0.32
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: -step, dy: 0)), withVelocity: XCUIGestureVelocity(250), thenHoldForDuration: 0)
        start.press(forDuration: 0.02, thenDragTo: start.withOffset(CGVector(dx: -step * 0.6, dy: 0)), withVelocity: .fast, thenHoldForDuration: 0)
        sleep(2)
        let counter = app.staticTexts.matching(NSPredicate(format: "label ENDSWITH ' of 7'")).firstMatch
        XCTAssertEqual(counter.label, "3 of 7")
        XCTAssertEqual(app.staticTexts["hero.title"].label, "Paper Trails")
        XCTAssertFalse(app.alerts["Demo action"].exists)
        XCUIDevice.shared.orientation = .portrait
    }
}
