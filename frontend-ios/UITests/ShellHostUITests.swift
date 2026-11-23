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
        XCTAssertTrue(app.alerts["NX2Apple"].waitForExistence(timeout: 5))
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

    func testLibraryStartsOnAPlayableGameWithoutAVersionLineOnTheCover() {
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["--host"]
        app.launch()
        XCTAssertTrue(app.staticTexts["hero.title"].waitForExistence(timeout: 10))
        XCTAssertNotEqual(app.staticTexts["hero.title"].label, "Bad Settings Fixture")
        XCTAssertEqual(app.staticTexts["hero.title"].label, "Orbit Fixture")
        // The accepted design shows the version in the game's settings only, no longer under the hero title.
        XCTAssertFalse(app.staticTexts["Version 1.0.0"].exists)
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

    func testGameSettingsShowsChangeCoverButtonWithoutResetWhenDefault() {
        launch(select: "0100000000010000")
        let settings = app.buttons["settings.open"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        let scroll = app.descendants(matching: .any)["settings.scroll"].firstMatch
        let changeCover = app.buttons["set.cover"]
        for _ in 0..<8 where !changeCover.exists {
            scroll.swipeUp()
        }
        XCTAssertTrue(changeCover.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["set.cover.reset"].exists)
    }

    func testStrippedFrameworkWithoutShadersShowsUpdateDataAction() {
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["--host", "--select", "0100000000010000", "--omit-msl", "0100000000010000"]
        app.launch()
        XCTAssertTrue(app.buttons["tile.0100000000010000"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["hero.title"].label, "Orbit Fixture")
        let action = app.buttons["state.action"]
        XCTAssertTrue(action.waitForExistence(timeout: 5))
        XCTAssertTrue(action.label.hasPrefix("Update game data"))
        XCTAssertTrue(app.buttons["settings.open"].isHittable)
    }

    func testGameDataErrorAlertAppearsAboveGameSettingsSheet() {
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["--host", "--select", "0100000000010000", "--screen", "settings", "--mock-bad-folder"]
        app.launch()
        let scroll = app.descendants(matching: .any)["settings.scroll"].firstMatch
        XCTAssertTrue(scroll.waitForExistence(timeout: 10))
        let chooseData = app.buttons["Choose game data…"]
        for _ in 0..<8 where !chooseData.exists {
            scroll.swipeUp()
        }
        XCTAssertTrue(chooseData.waitForExistence(timeout: 5))
        chooseData.tap()
        // Notice must appear above the open game settings sheet, not underneath it.
        let alert = app.alerts["NX2Apple"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertTrue(alert.buttons["OK"].isHittable)
        alert.buttons["OK"].tap()
        // Dismissing the notice keeps the player on the game settings sheet.
        XCTAssertTrue(scroll.waitForExistence(timeout: 5))
    }

    func testCertificateImportPasswordSheetAllowsTypingAndShowsInlineError() {
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["--host", "--select", "0100000000010000", "--mock-cert-picker"]
        app.launch()
        XCTAssertTrue(app.buttons["tile.0100000000010000"].waitForExistence(timeout: 10))
        let shellSettingsButton = app.buttons["shellSettings.open"].firstMatch
        XCTAssertTrue(shellSettingsButton.waitForExistence(timeout: 5))
        shellSettingsButton.tap()
        let importButton = app.buttons["shellSettings.sideloadCert.import"]
        for _ in 0..<6 where !importButton.exists {
            app.swipeUp()
        }
        XCTAssertTrue(importButton.waitForExistence(timeout: 5))
        importButton.tap()

        let passwordField = app.secureTextFields["shellSettings.sideloadCert.passwordField"]
        XCTAssertTrue(passwordField.waitForExistence(timeout: 5))
        XCTAssertTrue(passwordField.isHittable)
        passwordField.tap()
        passwordField.typeText("wrong-pass")

        let confirmButton = app.buttons["shellSettings.sideloadCert.passwordConfirm"]
        XCTAssertTrue(confirmButton.waitForExistence(timeout: 5))
        confirmButton.tap()

        // Invalid password/PKCS12 reports inline inside the password sheet without clearing the entered password.
        let errorText = app.staticTexts["shellSettings.sideloadCert.passwordError"]
        XCTAssertTrue(errorText.waitForExistence(timeout: 5))
        XCTAssertTrue(passwordField.exists)
        let toggleButton = app.buttons["shellSettings.sideloadCert.passwordToggle"]
        XCTAssertTrue(toggleButton.exists)
        toggleButton.tap()
        let revealedField = app.textFields["shellSettings.sideloadCert.passwordField"]
        XCTAssertTrue(revealedField.waitForExistence(timeout: 5))
        XCTAssertEqual(revealedField.value as? String, "wrong-pass")

        let cancelButton = app.buttons["shellSettings.sideloadCert.passwordCancel"]
        XCTAssertTrue(cancelButton.exists)
        cancelButton.tap()
        XCTAssertTrue(importButton.waitForExistence(timeout: 5))
    }

    func testGameSettingsCheatsImportTriageAndToggleFlow() throws {
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en", "--host", "--select", "0100000000010000", "--screen", "settings", "--mock-cheat-file"]
        app.launch()

        let cheatsEntry = app.buttons["set.cheats"]
        XCTAssertTrue(cheatsEntry.waitForExistence(timeout: 10))
        saveOptionalScreenshot(named: "ios-settings-cheats-entry-en")

        cheatsEntry.tap()
        XCTAssertTrue(app.staticTexts["cheats.buildID"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["cheats.buildID"].label, "CD57B23FA4BBAD65")
        XCTAssertTrue(app.otherElements["cheats.emptyCard"].exists || app.staticTexts["No cheats imported yet"].exists)

        let importButton = app.buttons["cheats.import"]
        XCTAssertTrue(importButton.waitForExistence(timeout: 5))
        importButton.tap()

        // Triage card shows direct-ready count + code-needs-bake guidance + share button.
        XCTAssertTrue(app.staticTexts["cheats.triageNeedsBakeText"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["cheats.shareForBake"].exists || app.buttons["cheats.share"].exists)

        // Direct-on-iPhone and baked-code entries expose live switches, while unbaked code entries show locked badge.
        let healthToggle = app.switches["cheats.toggle.Infinite Health"]
        let scroll = app.scrollViews.element(boundBy: app.scrollViews.count - 1)
        scroll.swipeUp()
        for _ in 0..<4 where !healthToggle.isHittable {
            scroll.swipeUp()
        }
        XCTAssertTrue(healthToggle.waitForExistence(timeout: 5))
        healthToggle.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()
        XCTAssertEqual(healthToggle.value as? String, "1")

        let moonJumpKey = app.descendants(matching: .any)["cheats.key.Moon Jump (Hold ZR+B)"].firstMatch
        for _ in 0..<4 where !moonJumpKey.isHittable {
            scroll.swipeUp()
        }
        XCTAssertTrue(moonJumpKey.waitForExistence(timeout: 5))
        XCTAssertTrue(app.switches["cheats.toggle.Moon Jump (Hold ZR+B)"].exists)

        let lockedCode = app.buttons["cheats.locked.2x Movement Speed"]
        for _ in 0..<4 where !lockedCode.isHittable {
            scroll.swipeUp()
        }
        XCTAssertTrue(lockedCode.waitForExistence(timeout: 5))
        XCTAssertFalse(app.switches["cheats.toggle.--SectionStart:Movement & Combat--"].exists)
        XCTAssertFalse(app.switches["cheats.toggle.Truncated Cheat"].exists)
    }

    func testCheatsBuildMismatchShowsConfirmationAlert() {
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en", "--host", "--select", "0100000000010000", "--screen", "settings", "--mock-cheat-mismatch"]
        app.launch()

        let cheatsEntry = app.buttons["set.cheats"]
        XCTAssertTrue(cheatsEntry.waitForExistence(timeout: 10))
        cheatsEntry.tap()

        let importButton = app.buttons["cheats.import"]
        XCTAssertTrue(importButton.waitForExistence(timeout: 5))
        importButton.tap()

        let alert = app.alerts["Build ID does not match"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Import for this build"].tap()

        XCTAssertTrue(app.staticTexts["cheats.triageNeedsBakeText"].waitForExistence(timeout: 5))
    }

    func testCaptureCheatsScreenshotsEnAndZh() throws {
        guard let shotDir = ProcessInfo.processInfo.environment["NX_IOS_CHEATS_SHOT_DIR"], !shotDir.isEmpty else {
            throw XCTSkip("Set NX_IOS_CHEATS_SHOT_DIR to capture iOS Cheats screenshots")
        }
        let dirURL = URL(fileURLWithPath: shotDir, isDirectory: true)
        try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)

        func capture(_ name: String) throws {
            let png = XCUIScreen.main.screenshot().pngRepresentation
            try png.write(to: dirURL.appendingPathComponent("\(name).png"))
        }

        for (langTag, appleLang) in [("en", "en"), ("zh", "zh-Hans")] {
            XCUIDevice.shared.orientation = .portrait
            app.launchArguments = [
                "-AppleLanguages", "(\(appleLang))",
                "-AppleLocale", appleLang,
                "--host", "--select", "0100000000010000", "--screen", "settings", "--mock-cheat-preloaded"
            ]
            app.launch()
            let cheatsEntry = app.buttons["set.cheats"]
            XCTAssertTrue(cheatsEntry.waitForExistence(timeout: 10))
            try capture("ios-settings-cheats-entry-\(langTag)")

            cheatsEntry.tap()
            XCTAssertTrue(app.staticTexts["cheats.buildID"].waitForExistence(timeout: 5))
            try capture("ios-cheats-triage-top-\(langTag)")

            app.scrollViews.firstMatch.swipeUp()
            sleep(1)
            try capture("ios-cheats-entries-list-\(langTag)")
            app.terminate()
        }
    }

    private func saveOptionalScreenshot(named name: String) {
        guard let shotDir = ProcessInfo.processInfo.environment["NX_IOS_CHEATS_SHOT_DIR"], !shotDir.isEmpty else { return }
        let url = URL(fileURLWithPath: shotDir, isDirectory: true).appendingPathComponent("\(name).png")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: url)
    }
}
