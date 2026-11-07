import XCTest

@MainActor final class ShellDemoUITests: XCTestCase {
    private let app = XCUIApplication()
    private var extraArguments: [String] = []
    override func setUp() async throws {
        await MainActor.run {
            continueAfterFailure = false
            app.terminate()
            XCUIDevice.shared.orientation = .portrait
        }
    }
    private func launch(_ screen: String) {
        app.launchArguments = ["--screen", screen] + extraArguments
        app.launch()
        let ready = screen.hasPrefix("controllers") ? "controllers.close" : screen == "settings" ? "library.back" : screen == "shell-settings" ? "shellSettings.close" : "controllers.open"
        XCTAssertTrue(app.buttons[ready].waitForExistence(timeout: 10))
    }
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    func testThumbnailContextMenuDoesNotShowKeyboard() {
        extraArguments = ["--samples"]
        launch("library")
        let tile = app.buttons["tile.orbit"]
        XCTAssertTrue(tile.waitForExistence(timeout: 5))
        XCTAssertEqual(app.keyboards.count, 0)
        tile.press(forDuration: 1)
        let settings = app.buttons["Game settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        XCTAssertEqual(app.keyboards.count, 0)
        let play = app.buttons["Play"]
        XCTAssertTrue(play.exists)
        XCTAssertLessThan(play.frame.minY, settings.frame.minY)
        capture("thumbnail-context-menu")
        play.tap()
        XCTAssertTrue(app.alerts["Demo action"].waitForExistence(timeout: 5))

    }

    func testHardwareArrowNavigationDoesNotRequireEditingFocus() {
        extraArguments = ["--samples"]
        launch("library")
        app.buttons["tile.orbit"].press(forDuration: 1)
        let menuSettings = app.buttons["Game settings"]
        XCTAssertTrue(menuSettings.waitForExistence(timeout: 5))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.95)).tap()
        XCTAssertTrue(menuSettings.waitForNonExistence(timeout: 5))
        app.typeKey(.rightArrow, modifierFlags: []) // First press establishes the current tile's focus.
        app.typeKey(.rightArrow, modifierFlags: [])
        let changed = NSPredicate(format: "label == %@", "Animal Crossing™: New Horizons")
        expectation(for: changed, evaluatedWith: app.staticTexts["hero.title"])
        waitForExpectations(timeout: 5)
        XCTAssertEqual(app.keyboards.count, 0)
    }

    func testRecentGamesSelectWithoutLaunching() {
        extraArguments = ["--samples"]
        launch("library")
        let row = app.buttons["recent.select.tide"]
        for _ in 0..<6 {
            if row.isHittable { break }
            app.scrollViews["library.grid"].swipeUp()
        }
        XCTAssertTrue(row.isHittable)
        XCTAssertTrue(app.buttons["recent.play.tide"].exists)
        row.tap()
        XCTAssertFalse(app.alerts["Demo action"].exists)
        XCTAssertEqual(app.staticTexts["hero.title"].label, "Animal Crossing™: New Horizons")
        capture("recent-selection-only")
        app.buttons["state.action"].tap()
        XCTAssertTrue(app.alerts["Demo action"].waitForExistence(timeout: 5))
    }

    func testAppSettingsFolderRowLabels() {
        extraArguments = ["--samples"]
        launch("shell-settings")
        let data = app.buttons["shellSettings.data"]
        let cloud = app.buttons["shellSettings.cloud"]
        XCTAssertTrue(data.staticTexts["Game data"].exists)
        XCTAssertTrue(data.staticTexts["Choose folder…"].exists)
        XCTAssertTrue(cloud.staticTexts["Enable Cloud saves"].exists)
        XCTAssertTrue(cloud.staticTexts["Choose folder…"].exists)
        XCTAssertFalse(app.staticTexts["No folder chosen"].exists)
        cloud.tap()
        XCTAssertTrue(app.alerts["Demo action"].waitForExistence(timeout: 5))
        extraArguments = ["--samples", "-globalCloudSavesFolderName", "Test Saves", "-globalDataFolderName", "Test Games"]
        launch("shell-settings")
        XCTAssertTrue(app.buttons["shellSettings.cloud"].staticTexts["Cloud saves to"].exists)
        XCTAssertTrue(app.buttons["shellSettings.cloud"].staticTexts["Test Saves"].exists)
        XCTAssertTrue(app.buttons["shellSettings.data"].staticTexts["Test Games"].exists)
        capture("settings-configured-folder-rows")
    }

    func testGameSettingsGlassActionsPreserveBehavior() {
        extraArguments = ["--samples"]
        launch("settings")
        let sheet = settingsScroll
        sheet.segmentedControls.firstMatch.buttons["Docked"].tap()
        func reveal(_ button: XCUIElement) {
            for _ in 0..<8 {
                if button.isHittable { return }
                sheet.swipeUp()
            }
            XCTAssertTrue(button.isHittable)
        }
        for title in ["Choose game data…", "Use app data", "Choose folder…"] {
            launch("settings")
            let button = sheet.buttons[title].firstMatch
            reveal(button)
            button.tap()
            XCTAssertTrue(app.alerts["Demo action"].waitForExistence(timeout: 5))
            app.alerts.buttons["OK"].tap()
        }
        launch("settings")
        sheet.segmentedControls.firstMatch.buttons["Docked"].tap()
        let reset = app.buttons["set.reset"]
        reveal(reset)
        XCTAssertTrue(reset.isEnabled)
        reset.tap()
        XCTAssertFalse(reset.isEnabled)
        let delete = app.buttons["set.delete"]
        reveal(delete)
        delete.tap()
        XCTAssertTrue(app.buttons["delete.confirm"].waitForExistence(timeout: 5))
        app.buttons["delete.cancel"].tap()
        XCTAssertTrue(app.buttons["set.delete"].waitForExistence(timeout: 5))
    }

    func testFirstGameSettingsGroupsUseNativeControls() {
        extraArguments = ["--samples"]
        launch("settings")
        let sheet = settingsScroll
        let mode = sheet.segmentedControls.firstMatch
        XCTAssertTrue(mode.waitForExistence(timeout: 5))
        mode.buttons["Docked"].tap()
        XCTAssertTrue(mode.buttons["Docked"].isSelected)
        XCTAssertFalse(sheet.staticTexts["From Settings"].exists)
        let fps = sheet.switches.matching(NSPredicate(format: "label BEGINSWITH %@", "Show frame rate")).firstMatch
        XCTAssertTrue(fps.exists)
        fps.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        XCTAssertEqual(fps.value as? String, "0")
        let merge = sheet.switches.matching(NSPredicate(format: "label BEGINSWITH %@", "All controllers are player 1")).firstMatch
        merge.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        XCTAssertEqual(merge.value as? String, "1")
        sheet.buttons["setting.DM_LANGUAGE"].tap()
        let japanese = app.buttons["Japanese"].firstMatch
        XCTAssertTrue(japanese.waitForExistence(timeout: 5))
        japanese.tap()
        XCTAssertTrue(sheet.staticTexts["Japanese"].exists)
        capture("native-game-settings-game-group")
        sheet.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65))
            .press(forDuration: 0.1, thenDragTo: sheet.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)))
        XCTAssertTrue(app.navigationBars.staticTexts["Mario Kart™ 8 Deluxe"].waitForExistence(timeout: 5))
        let slider = sheet.sliders.firstMatch
        for _ in 0..<4 {
            if slider.isHittable { break }
            sheet.swipeUp()
        }
        XCTAssertTrue(slider.isHittable)
        let original = slider.value as? String
        slider.adjust(toNormalizedSliderPosition: 0.8)
        XCTAssertNotEqual(slider.value as? String, original)
        XCTAssertFalse(sheet.buttons["Increase Render scale"].exists)
        XCTAssertFalse(sheet.buttons["Decrease Render scale"].exists)
        let rate = sheet.segmentedControls.matching(NSPredicate(format: "label == %@", "Frame rate")).firstMatch
        XCTAssertTrue(rate.exists)
        rate.buttons["30 fps"].tap()
        XCTAssertTrue(rate.buttons["30 fps"].isSelected)
        capture("native-game-settings-performance-group")
    }

    func testGameSettingsToolbarOwnsEveryPrimaryState() {
        for (game, title) in [("orbit", "Play"), ("paper", "Choose game data…"), ("moon", "How to update"), ("wild", "How to fix")] {
            extraArguments = ["--samples", "--select", game]
            launch("settings")
            let action = app.buttons["state.action"]
            XCTAssertTrue(action.waitForExistence(timeout: 5))
            XCTAssertEqual(action.label, title)
            XCTAssertEqual(app.buttons.matching(identifier: "state.action").count, 1)
            XCTAssertFalse(settingsScroll.buttons["state.action"].exists)
            XCTAssertTrue(app.navigationBars.firstMatch.frame.contains(CGPoint(x: action.frame.midX, y: action.frame.midY)))
            capture("settings-toolbar-action-" + game)
            action.tap()
            if game == "moon" || game == "wild" {
                XCTAssertTrue(app.buttons["help.done"].waitForExistence(timeout: 5))
            } else {
                XCTAssertTrue(app.alerts["Demo action"].waitForExistence(timeout: 5))
            }
        }
    }

    func testLandscapeGameSettingsOwnsItsPrimaryAction() {
        XCUIDevice.shared.orientation = .landscapeLeft
        for (game, title) in [("orbit", "Play")] {
            extraArguments = ["--samples", "--select", game]
            launch("settings")
            let action = app.buttons["state.action"]
            XCTAssertTrue(action.waitForExistence(timeout: 5))
            XCTAssertEqual(action.label, title)
            XCTAssertEqual(app.buttons.matching(identifier: "state.action").count, 1)
            XCTAssertFalse(settingsScroll.buttons["state.action"].exists)
            XCTAssertTrue(app.navigationBars.firstMatch.frame.contains(CGPoint(x: action.frame.midX, y: action.frame.midY)))
            capture("settings-toolbar-action-" + game)
            action.tap()
            if game == "moon" || game == "wild" {
                XCTAssertTrue(app.buttons["help.done"].waitForExistence(timeout: 5))
            } else {
                XCTAssertTrue(app.alerts["Demo action"].waitForExistence(timeout: 5))
            }
        }
    }

    func testGameSettingsMetadataHierarchy() {
        for (game, number, subtitle) in [("orbit", "1.4.0", ""), ("paper", "1.0.0", "Missing Data")] {
            extraArguments = ["--samples", "--select", game]
            launch("settings")
            let sheet = settingsScroll
            let title = sheet.staticTexts["detail.title"]
            // The version is the "Version" row's value below the header, not a line above the title.
            let version = sheet.staticTexts[number].firstMatch
            XCTAssertTrue(title.waitForExistence(timeout: 5))
            XCTAssertTrue(version.exists)
            XCTAssertGreaterThanOrEqual(version.frame.minY, title.frame.maxY)
            if subtitle.isEmpty {
                XCTAssertFalse(sheet.staticTexts["Played today"].exists)
                XCTAssertFalse(sheet.staticTexts["Played yesterday"].exists)
            } else {
                let detail = sheet.staticTexts[subtitle].firstMatch
                XCTAssertTrue(detail.exists)
                XCTAssertGreaterThanOrEqual(detail.frame.minY, title.frame.maxY)
            }
            capture("game-settings-metadata-" + game)
        }
    }

    private var settingsScroll: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "settings.scroll").firstMatch
    }

    // Run on the closed Duo in landscape, with its native sheet side rail.
    func testGameSettingsInsetsNativeRailOnce() {
        launch("library")
        XCTAssertTrue(app.scrollViews["library.coverflow"].waitForExistence(timeout: 5))
        app.buttons["settings.open"].tap()
        XCTAssertTrue(app.buttons["library.back"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["library.back"].label, "Close")
        let play = app.buttons.matching(identifier: "state.action").allElementsBoundByIndex.first { $0.isHittable }
        XCTAssertNotNil(play)
        let scroll = app.scrollViews.element(boundBy: app.scrollViews.count - 1)
        XCTAssertLessThan(play!.frame.minX - scroll.frame.minX, scroll.frame.width * 0.2, "The primary action must not repeat the native rail inset")
    }

    func testNativeLauncherBarsFollowTheActiveScreen() {
        launch("library")
        XCTAssertEqual(app.buttons.matching(identifier: "shellSettings.open").count, 1)
        app.buttons["shellSettings.open"].tap()
        XCTAssertTrue(app.buttons["shellSettings.data"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars.staticTexts["Settings"].exists)
        XCTAssertTrue(app.buttons["shellSettings.close"].isHittable)
        XCTAssertEqual(app.buttons["shellSettings.close"].label, "Close")
        app.buttons["shellSettings.close"].tap()
        XCTAssertTrue(app.buttons["controllers.open"].waitForExistence(timeout: 5))
        app.buttons["controllers.open"].tap()
        XCTAssertTrue(app.buttons["controllers.close"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars.staticTexts["Controllers"].exists)
        app.buttons["controllers.close"].tap()
        app.buttons["settings.open"].tap()
        XCTAssertTrue(app.buttons["library.back"].waitForExistence(timeout: 5))
        app.buttons["library.back"].tap()
        XCTAssertTrue(app.buttons["shellSettings.open"].isHittable)
    }

    // Run on a compact portrait device with standard Dynamic Type.
    func testPortraitScrollKeepsLibraryToolbarActionsAvailable() {
        XCUIDevice.shared.orientation = .portrait
        launch("library")
        let grid = app.scrollViews["library.grid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 5))
        grid.swipeUp()
        grid.swipeUp()
        XCTAssertTrue(app.buttons["controllers.open"].isHittable)
        XCTAssertTrue(app.buttons["shellSettings.open"].isHittable)
        app.buttons["controllers.open"].tap()
        XCTAssertTrue(app.buttons["controllers.close"].waitForExistence(timeout: 5))
        app.buttons["controllers.close"].tap()
        XCTAssertTrue(app.buttons["shellSettings.open"].isHittable)
    }

    // Run on a compact portrait device with standard Dynamic Type.
    func testCompactControllerRowsRetainNameAndBatteryOnOneRow() {
        extraArguments = ["--samples"]
        launch("controllers")
        for (id, name) in [("one", "Pro Controller"), ("two", "Wireless Controller"), ("three", "USB Controller")] {
            let row = app.descendants(matching: .any).matching(identifier: "controller." + id).firstMatch
            XCTAssertTrue(row.exists)
            XCTAssertLessThanOrEqual(row.frame.height, 110)
            XCTAssertTrue(row.label.contains(name), "VoiceOver must retain the full controller name")
        }
        let charging = app.descendants(matching: .any).matching(identifier: "controller.two").firstMatch
        XCTAssertTrue(charging.label.contains("16%"))
        XCTAssertTrue(charging.label.contains("Charging"))
        capture("compact-controller-rows")
    }

    func testMappingKeepsPreviewAndUsesChildChoiceSheet() {
        extraArguments = ["--samples"]
        launch("controllers")
        app.buttons["padMapping.open"].tap()
        let preview = app.buttons["padMapping.drawing.A"]
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        let initialY = preview.frame.midY
        capture("mapping-initial-clear-edge")
        XCTAssertFalse(app.buttons["padMapping.reset"].exists)
        XCTAssertFalse(app.staticTexts["Tap a button to change what it sends."].exists)
        let swap = app.switches["padMapping.swap"].firstMatch
        XCTAssertTrue(swap.isHittable)
        swap.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(swap.value as? String, "1")
        capture("mapping-native-switch-on")
        let reset = app.buttons["padMapping.reset"]
        XCTAssertTrue(reset.waitForExistence(timeout: 5))
        reset.tap()
        let confirmReset = app.buttons["padMapping.reset.confirm"].firstMatch
        XCTAssertTrue(confirmReset.waitForExistence(timeout: 5))
        XCTAssertTrue(reset.exists, "opening confirmation must not reset mappings")
        confirmReset.tap()
        XCTAssertTrue(reset.waitForNonExistence(timeout: 5))
        XCTAssertEqual(swap.value as? String, "0")
        swap.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        swap.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(swap.value as? String, "0")
        let row = app.buttons["padMapping.row.A"]
        row.tap()
        XCTAssertTrue(app.buttons["padMapping.option.B"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["padMapping.back"].isHittable)
        XCTAssertFalse(app.staticTexts["Sends in games"].exists)
        app.buttons["padMapping.option.B"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue((row.value as? String)?.contains("B") == true)
        XCTAssertEqual(preview.frame.midY, initialY, accuracy: 2)
        row.tap()
        XCTAssertTrue(app.buttons["padMapping.option.A"].waitForExistence(timeout: 5))
        let destination = app.descendants(matching: .any).matching(identifier: "padMapping.destination").firstMatch
        XCTAssertTrue(destination.exists)
        XCTAssertEqual(destination.label, "B")
        app.buttons["padMapping.option.A"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let list = app.descendants(matching: .any).matching(identifier: "padMapping.mappings").firstMatch
        XCTAssertTrue(list.exists)
        let lower = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
        let upper = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        lower.press(forDuration: 0.05, thenDragTo: upper)
        XCTAssertEqual(preview.frame.midY, initialY, accuracy: 2)
        capture("mapping-pinned-preview")
        upper.press(forDuration: 0.05, thenDragTo: lower)
        capture("mapping-scrolling-back-up")
        preview.tap()
        XCTAssertTrue(app.buttons["padMapping.option.A"].waitForExistence(timeout: 5))
    }

    func testNativeMenuKeepsNestedControllerTools() {
        launch("controllers")
        app.buttons["padMapping.open"].tap()
        XCTAssertTrue(app.buttons["padMapping.close"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars.staticTexts["Button mapping"].exists)
        app.buttons["padMapping.close"].tap()
        XCTAssertTrue(app.buttons["buttonTest.open"].waitForExistence(timeout: 5))
        app.buttons["buttonTest.open"].tap()
        XCTAssertTrue(app.buttons["buttonTest.close"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars.staticTexts["Button test"].exists)
        app.buttons["buttonTest.close"].tap()
        XCTAssertTrue(app.buttons["controllers.close"].waitForExistence(timeout: 5))
        app.buttons["controllers.close"].tap()
        XCTAssertTrue(app.buttons["controllers.open"].waitForExistence(timeout: 5))
    }

    func testControllerShortcutsKeepTheVisibleMenuInSync() {
        launch("controllers")
        app.typeKey("o", modifierFlags: [])
        XCTAssertTrue(app.buttons["library.back"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["controllers.close"].exists)
        app.typeKey("y", modifierFlags: [])
        XCTAssertTrue(app.buttons["controllers.close"].waitForExistence(timeout: 5))
        app.buttons["controllers.close"].tap()
        XCTAssertTrue(app.buttons["library.back"].waitForExistence(timeout: 5))
        app.buttons["library.back"].tap()
        XCTAssertTrue(app.buttons["library.back"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["controllers.open"].isHittable)
    }

    func testEditorMenuKeepsExitAndSaveVisibleWhileScrolling() {
        XCUIDevice.shared.orientation = .landscapeLeft
        launch("shell-settings")
        let arrange = app.buttons["shellSettings.arrange"]
        reveal(arrange)
        arrange.tap()
        let options = app.buttons["touchLayout.options"]
        XCTAssertTrue(options.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 2.25)
        capture("touch-editor-idle-glow")
        XCTAssertTrue(app.descendants(matching: .any)["touchLayout.tip"].firstMatch.waitForExistence(timeout: 5))
        options.tap()
        let save = app.buttons["touchLayout.done"]
        let exit = app.buttons["touchLayout.back"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["touchLayout.orientation"].label, "Landscape")
        XCTAssertFalse(app.staticTexts["Stick placement presets"].exists)
        let y = save.frame.midY
        let scroll = app.scrollViews["touchLayout.options.scroll"].firstMatch
        XCTAssertTrue(scroll.waitForExistence(timeout: 5))
        let lower = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
        let upper = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        lower.press(forDuration: 0.05, thenDragTo: upper)
        XCTAssertTrue(save.isHittable)
        XCTAssertTrue(exit.isHittable)
        XCTAssertEqual(save.frame.midY, y, accuracy: 1)
        upper.press(forDuration: 0.05, thenDragTo: lower)
        XCTAssertEqual(save.frame.midY, y, accuracy: 1)
    }

    func testNativeSettingsSwitchUpdatesAndTouchControlsStillOpens() {
        XCUIDevice.shared.orientation = .portrait
        launch("shell-settings")
        app.swipeUp()
        let hud = app.switches["setting.shell.hud"].firstMatch
        reveal(hud)
        XCTAssertTrue(hud.waitForExistence(timeout: 5))
        let initial = hud.value as? String
        hud.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertNotEqual(hud.value as? String, initial)
        hud.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(hud.value as? String, initial)
        let arrange = app.buttons["shellSettings.arrange"]
        reveal(arrange)
        XCTAssertTrue(arrange.isHittable)
        capture("native-grouped-settings")
        arrange.tap()
        XCTAssertTrue(app.buttons["touchLayout.options"].waitForExistence(timeout: 5))
    }

    // Run on a standard iPhone: editing follows gameplay's landscape-only policy.
    func testPhoneEditorOpensLandscapeAndRestoresPortraitBrowsing() {
        XCUIDevice.shared.orientation = .portrait
        launch("shell-settings")
        let arrange = app.buttons["shellSettings.arrange"]
        reveal(arrange)
        arrange.tap()
        let options = app.buttons["touchLayout.options"]
        XCTAssertTrue(options.waitForExistence(timeout: 5))
        let landscape = NSPredicate { _, _ in
            let frame = self.app.otherElements["touchLayout.editor"].firstMatch.frame
            return frame.width > frame.height
        }
        expectation(for: landscape, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
        XCUIDevice.shared.orientation = .landscapeLeft
        XCUIDevice.shared.orientation = .portrait
        XCTAssertGreaterThan(app.otherElements["touchLayout.editor"].firstMatch.frame.width,
                             app.otherElements["touchLayout.editor"].firstMatch.frame.height)
        options.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).tap()
        let exit = app.buttons["touchLayout.back"]
        XCTAssertTrue(exit.waitForExistence(timeout: 5))
        exit.tap()
        XCTAssertTrue(app.buttons["shellSettings.close"].waitForExistence(timeout: 5))
        XCTAssertFalse(options.exists)
        XCUIDevice.shared.orientation = .landscapeLeft
        XCUIDevice.shared.orientation = .portrait
        let portrait = NSPredicate { _, _ in self.app.frame.height > self.app.frame.width }
        expectation(for: portrait, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
    }

    // Run on iPad: changing orientation must reflow the live canvas, not scale an old snapshot.
    func testTouchEditorFollowsPortraitAndLandscapeBounds() {
        XCUIDevice.shared.orientation = .landscapeLeft
        launch("shell-settings")
        let arrange = app.buttons["shellSettings.arrange"]
        reveal(arrange)
        arrange.tap()
        XCTAssertTrue(app.buttons["touchLayout.options"].waitForExistence(timeout: 5))
        for pose in [UIDeviceOrientation.portrait, .landscapeLeft, .portrait] {
            XCUIDevice.shared.orientation = pose
            let matches = NSPredicate { _, _ in
                let preview = self.app.otherElements["touchLayout.editor"].firstMatch.frame
                let window = self.app.windows.firstMatch.frame
                return abs(preview.width - window.width) < 2 && abs(preview.height - window.height) < 2
                    && (pose == .portrait ? preview.height > preview.width : preview.width > preview.height)
            }
            expectation(for: matches, evaluatedWith: nil)
            waitForExpectations(timeout: 5)
            let stick = app.buttons["Left stick"].firstMatch
            XCTAssertTrue(stick.exists)
            XCTAssertGreaterThan(stick.frame.midY, app.windows.firstMatch.frame.midY)
        }
        let options = app.buttons["touchLayout.options"]
        options.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).tap()
        XCTAssertTrue(app.buttons["touchLayout.done"].waitForExistence(timeout: 5))
        app.buttons["touchLayout.done"].tap()
        XCTAssertTrue(app.buttons["shellSettings.close"].waitForExistence(timeout: 5))
        XCTAssertFalse(options.exists)
        reveal(arrange)
        arrange.tap()
        XCTAssertTrue(options.waitForExistence(timeout: 5))
        options.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).tap()
        app.buttons["touchLayout.back"].tap()
        XCTAssertTrue(app.buttons["shellSettings.close"].waitForExistence(timeout: 5))
        XCTAssertFalse(options.exists)
    }

    func testSavedTouchModeReopensSelected() {
        launch("shell-settings")
        func openOptions() {
            let arrange = app.buttons["shellSettings.arrange"]
            reveal(arrange)
            arrange.tap()
            let options = app.buttons["touchLayout.options"]
            XCTAssertTrue(options.waitForExistence(timeout: 5))
            options.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).tap()
            XCTAssertTrue(app.buttons["touchLayout.done"].waitForExistence(timeout: 5))
        }
        openOptions()
        let modes = app.segmentedControls["setting.lay.layout"]
        let original = modes.buttons.allElementsBoundByIndex.first { $0.isSelected }!.label
        modes.buttons["2D"].tap()
        app.buttons["touchLayout.done"].tap()
        XCTAssertTrue(app.buttons["shellSettings.close"].waitForExistence(timeout: 5))
        openOptions()
        XCTAssertTrue(modes.buttons["2D"].isSelected)
        modes.buttons[original].tap()
        app.buttons["touchLayout.done"].tap()
        XCTAssertTrue(app.buttons["shellSettings.close"].waitForExistence(timeout: 5))
    }

    func testEditedTouchControlsSaveAndDiscardBothCloseTheEditor() {
        launch("shell-settings")
        func openOptions() {
            let arrange = app.buttons["shellSettings.arrange"]
            reveal(arrange)
            arrange.tap()
            let options = app.buttons["touchLayout.options"]
            XCTAssertTrue(options.waitForExistence(timeout: 5))
            options.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).tap()
            XCTAssertTrue(app.buttons["touchLayout.done"].waitForExistence(timeout: 5))
        }
        openOptions()
        let sizes = app.segmentedControls["setting.shell.touchSize"]
        let original = sizes.buttons.allElementsBoundByIndex.first { $0.isSelected }!.label
        let changed = original == "Large" ? "Small" : "Large"
        sizes.buttons[changed].tap()
        app.buttons["touchLayout.done"].tap()
        XCTAssertTrue(app.buttons["shellSettings.close"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["touchLayout.options"].exists)
        openOptions()
        sizes.buttons[original].tap()
        app.buttons["touchLayout.back"].tap()
        let discard = app.buttons["touchLayout.discard"].firstMatch
        XCTAssertTrue(discard.waitForExistence(timeout: 5))
        discard.tap()
        XCTAssertTrue(app.buttons["shellSettings.close"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["touchLayout.options"].exists)
        openOptions()
        sizes.buttons[original].tap()
        app.buttons["touchLayout.done"].tap()
        XCTAssertTrue(app.buttons["shellSettings.close"].waitForExistence(timeout: 5))
    }

    func testArrangeOpensFullScreenWithCancelAndConfirm() {
        launch("shell-settings")
        let arrange = app.buttons["shellSettings.arrange"]
        reveal(arrange)
        arrange.tap()
        XCTAssertTrue(app.buttons["touchLayout.options"].waitForExistence(timeout: 5))
        app.buttons["touchLayout.options"].tap()
        XCTAssertTrue(app.buttons["touchLayout.back"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["touchLayout.done"].isHittable)
        XCTAssertTrue(app.otherElements["touchLayout.editor"].firstMatch.exists)
        capture("arrange-fullscreen")
        app.buttons["touchLayout.back"].tap()
        XCTAssertTrue(app.buttons["shellSettings.close"].waitForExistence(timeout: 5))
        reveal(arrange)
        arrange.tap()
        XCTAssertTrue(app.buttons["touchLayout.options"].waitForExistence(timeout: 5))
        app.buttons["touchLayout.options"].tap()
        XCTAssertTrue(app.buttons["touchLayout.done"].waitForExistence(timeout: 5))
        app.buttons["touchLayout.done"].tap()
        XCTAssertTrue(app.buttons["shellSettings.close"].waitForExistence(timeout: 5))
    }

    // Run on a partially folded inner display, in landscape or tabletop.
    func testFoldedArrangeKeepsInteractivePreviewInEditor() {
        launch("shell-settings")
        let arrange = app.buttons["shellSettings.arrange"]
        reveal(arrange)
        arrange.tap()
        XCTAssertTrue(app.buttons["touchLayout.options"].waitForExistence(timeout: 5))
        app.buttons["touchLayout.options"].tap()
        XCTAssertTrue(app.buttons["touchLayout.back"].waitForExistence(timeout: 5))
        let editor = app.otherElements["touchLayout.editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertTrue(editor.otherElements["touchLayout.preview"].exists,
                      "The draggable preview must belong to the full-screen editor")
        capture("arrange-folded-fullscreen-editor")
        app.buttons["touchLayout.back"].tap()
        XCTAssertTrue(app.buttons["shellSettings.close"].waitForExistence(timeout: 5))
    }

    private func reveal(_ element: XCUIElement) {
        for _ in 0..<16 {
            if element.isHittable { return }
            let scroll = app.scrollViews.element(boundBy: app.scrollViews.count - 1)
            scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
                .press(forDuration: 0.05, thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)), withVelocity: .slow, thenHoldForDuration: 0.1)
        }
        XCTAssertTrue(element.isHittable, element.identifier)
    }

    func testNativeMenuChoiceDeleteCancelAndHelp() {
        launch("settings")
        let language = app.buttons["setting.DM_LANGUAGE"]
        reveal(language)
        language.tap()
        XCTAssertTrue(app.buttons["choice.close"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["choice.title"].exists)
        app.buttons["choice.close"].tap()
        let delete = app.buttons["set.delete"]
        reveal(delete)
        delete.tap()
        XCTAssertTrue(app.staticTexts["delete.title"].waitForExistence(timeout: 5))
        let cancel = app.buttons["delete.cancel"]
        reveal(cancel)
        cancel.tap()
        XCTAssertTrue(app.buttons["library.back"].waitForExistence(timeout: 5))
        app.buttons["library.back"].tap()
        launch("needs-update")
        app.buttons["state.action"].tap()
        XCTAssertTrue(app.buttons["help.done"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["help.done"].label, "Close")
        let update = app.buttons["help.update"]
        reveal(update)
        update.tap()
        XCTAssertTrue(app.alerts["Demo action"].waitForExistence(timeout: 5))
        app.alerts.buttons["OK"].tap()
        XCTAssertFalse(app.buttons["help.done"].exists)
        XCTAssertTrue(app.buttons["controllers.open"].waitForExistence(timeout: 5))
    }

    func testNativeMenuReturnsFromExistingTouchEditor() {
        launch("shell-settings")
        let arrange = app.buttons["shellSettings.arrange"]
        for _ in 0..<6 {
            if arrange.isHittable { break }
            app.scrollViews.element(boundBy: app.scrollViews.count - 1).swipeUp()
        }
        XCTAssertTrue(arrange.isHittable)
        arrange.tap()
        XCTAssertTrue(app.buttons["touchLayout.options"].waitForExistence(timeout: 5))
        app.buttons["touchLayout.options"].tap()
        let done = app.buttons["touchLayout.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        XCTAssertEqual(done.label, "Save")
        done.tap()
        XCTAssertTrue(app.buttons["shellSettings.close"].waitForExistence(timeout: 5))
        XCTAssertFalse(done.exists)
        app.buttons["shellSettings.close"].tap()
        XCTAssertTrue(app.buttons["shellSettings.open"].waitForExistence(timeout: 5))
    }

    // Run in compact portrait: every primary state uses the same bottom action container.
    func testCompactPortraitRecoveryActionsStayAtBottom() {
        XCUIDevice.shared.orientation = .portrait
        launch("library")
        let action = app.buttons["state.action"]
        let baseline = action.frame
        for (screen, label) in [("needs-data", "Choose game data"), ("needs-update", "How to update"), ("broken", "How to fix")] {
            launch(screen)
            XCTAssertEqual(app.buttons.matching(identifier: "state.action").count, 1)
            XCTAssertTrue(action.label.hasPrefix(label))
            XCTAssertTrue(action.isHittable)
            XCTAssertEqual(action.frame.midY, baseline.midY, accuracy: 4)
            XCTAssertGreaterThan(action.frame.width, app.frame.width * 0.6)
            XCTAssertFalse(app.buttons["settings.open"].exists)
        }
    }

    func testNativeGameActionPairAndUnavailableAction() {
        launch("library")
        let play = app.buttons["state.action"], settings = app.buttons["settings.open"]
        XCTAssertTrue(play.isHittable)
        XCTAssertTrue(settings.isHittable)
        XCTAssertEqual(app.buttons.matching(identifier: "settings.open").count, 1)
        XCTAssertEqual(play.frame.midY, settings.frame.midY, accuracy: 4)
        XCTAssertGreaterThan(play.frame.width, settings.frame.width)
        XCTAssertTrue(app.buttons["controllers.open"].isHittable)
        XCTAssertTrue(app.buttons["shellSettings.open"].isHittable)
        settings.tap()
        XCTAssertTrue(app.buttons["library.back"].waitForExistence(timeout: 5))
        app.buttons["library.back"].tap()
        play.tap()
        XCTAssertTrue(app.alerts["Demo action"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.alerts.staticTexts["Play requested. The demo does not launch games."].exists)
        app.alerts.buttons["OK"].tap()
        launch("needs-update")
        XCTAssertFalse(app.buttons["settings.open"].exists)
        XCTAssertTrue(app.buttons["state.action"].isHittable)
        app.buttons["state.action"].tap()
        XCTAssertTrue(app.buttons["help.done"].waitForExistence(timeout: 5))
        app.buttons["help.done"].tap()
    }

    func testGameActionMorphKeepsOnePrimaryAcrossReadinessStates() {
        launch("library")
        for (id, label, playable) in [("paper", "Choose game data", false), ("moon", "How to update", false), ("orbit", "Play", true)] {
            if playable { app.scrollViews["library.grid"].swipeDown() }
            let tile = app.buttons["tile." + id]
            tile.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
            expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: tile)
            expectation(for: NSPredicate(format: "exists == %@", NSNumber(value: playable)), evaluatedWith: app.buttons["settings.open"])
            waitForExpectations(timeout: 5)
            XCTAssertEqual(app.buttons.matching(identifier: "state.action").count, 1)
            XCTAssertTrue(app.buttons["state.action"].label.hasPrefix(label))
            XCTAssertTrue(app.buttons["state.action"].isHittable)
        }
        app.buttons["state.action"].tap()
        XCTAssertTrue(app.alerts["Demo action"].waitForExistence(timeout: 5))
    }

    func testCoverFlowControllerSelectionDoesNotScrollBack() {
        XCUIDevice.shared.orientation = .landscapeLeft
        extraArguments = ["--input-test", "--games", "3"]
        launch("library")
        let initialX = app.buttons["tile.orbit"].frame.midX
        app.buttons["qa.input.right"].tap()
        app.buttons["qa.input.right"].tap()
        let tide = app.buttons["tile.tide"]
        expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: tide)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(tide.frame.midX, initialX, accuracy: 4)
        app.buttons["qa.input.right"].tap()
        XCTAssertTrue(app.buttons["tile.paper"].isSelected)
        XCTAssertTrue(app.buttons["state.action"].label.hasPrefix("Choose game data"))
        app.buttons["qa.input.left"].tap()
        XCTAssertTrue(tide.isSelected)
        XCTAssertEqual(tide.frame.midX, initialX, accuracy: 4)
        XCTAssertTrue(app.buttons["settings.open"].isHittable)
        XCTAssertFalse(app.alerts["Demo action"].exists)
    }

    func testCoverFlowSlowSwipeKeepsSelectionAndTitleInSync() {
        XCUIDevice.shared.orientation = .landscapeLeft
        launch("library")
        let flow = app.scrollViews["library.coverflow"]
        XCTAssertTrue(flow.waitForExistence(timeout: 5))
        flow.swipeLeft(velocity: .slow)
        expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: app.buttons["tile.tide"])
        waitForExpectations(timeout: 5)
        XCTAssertEqual(app.staticTexts["hero.title"].label, "Animal Crossing™: New Horizons")
        XCTAssertFalse(app.alerts["Demo action"].exists)
        flow.swipeRight(velocity: .slow)
        expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: app.buttons["tile.orbit"])
        waitForExpectations(timeout: 5)
        XCTAssertEqual(app.staticTexts["hero.title"].label, "Mario Kart™ 8 Deluxe")
    }

    // Run with the simulator in landscape; Device Hub owns Duo orientation.
    func testCoverFlowSwipesAndCentersSelection() {
        XCUIDevice.shared.orientation = .landscapeLeft
        for count in [7, 3] {
            extraArguments = ["--games", "\(count)"]
            launch("library")
            let flow = app.scrollViews["library.coverflow"]
            XCTAssertTrue(flow.waitForExistence(timeout: 5))
            let orbit = app.buttons["tile.orbit"]
            XCTAssertEqual(orbit.frame.midX, flow.frame.midX, accuracy: 4)
            XCTAssertFalse(app.staticTexts["READY TO PLAY"].exists)
            XCTAssertFalse(app.staticTexts["Version 1.4.0"].exists)
            XCTAssertTrue(orbit.label.contains("Mario Kart™ 8 Deluxe"))
            XCTAssertFalse(orbit.label.contains("1.4.0"), "Version is shown only in Game Settings")
            XCTAssertGreaterThanOrEqual(app.buttons["state.action"].frame.minY - app.staticTexts["hero.title"].frame.maxY, 8)
            flow.swipeLeft()
            let tide = app.buttons["tile.tide"]
            expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: tide)
            waitForExpectations(timeout: 5)
            XCTAssertEqual(tide.frame.midX, flow.frame.midX, accuracy: 4)
            XCTAssertEqual(app.staticTexts["hero.title"].label, "Animal Crossing™: New Horizons")
            XCTAssertFalse(app.alerts["Demo action"].exists)
            let settings = app.buttons["settings.open"]
            XCTAssertEqual(settings.frame.width, settings.frame.height, accuracy: 2)
            XCTAssertTrue(app.buttons["controllers.open"].isHittable)
            XCTAssertTrue(app.buttons["shellSettings.open"].isHittable)
            XCTAssertEqual(app.buttons["controllers.open"].frame.midY, app.buttons["shellSettings.open"].frame.midY, accuracy: 4)
            let position = app.staticTexts["library.position"]
            XCTAssertTrue(position.exists)
            XCTAssertGreaterThan(position.frame.width, app.buttons["controllers.open"].frame.width * 2)
            XCTAssertLessThan(position.frame.maxX, app.buttons["controllers.open"].frame.minX)
            flow.swipeRight()
            expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: orbit)
            waitForExpectations(timeout: 5)
            XCTAssertEqual(orbit.frame.midX, flow.frame.midX, accuracy: 4)
            app.buttons["tile.tide"].tap()
            expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: tide)
            waitForExpectations(timeout: 5)
            XCTAssertEqual(tide.frame.midX, flow.frame.midX, accuracy: 4)
            extraArguments += ["--select", count == 3 ? "paper" : "amber"]
            launch("library")
            let last = app.buttons[count == 3 ? "tile.paper" : "tile.amber"]
            XCTAssertEqual(last.frame.midX, app.scrollViews["library.coverflow"].frame.midX, accuracy: 4)
        }
        capture("native-centered-coverflow")
    }

    // Run on expanded portrait or tabletop: selection scrolls the grid, not the pinned hero.
    func testPortraitTileTapScrollsSelectionIntoView() {
        launch("library")
        let grid = app.scrollViews["library.grid"]
        let actionTop = app.buttons["state.action"].frame.minY
        let tile = ["paper", "moon", "wild", "drift", "amber"].map { app.buttons["tile.\($0)"] }
            .filter { $0.exists && $0.isHittable && $0.frame.midY > grid.frame.midY
                && $0.frame.minY + $0.frame.height * 0.15 < actionTop - 12 }
            .max { $0.frame.midY < $1.frame.midY }
        XCTAssertNotNil(tile, "Choose a visible tile below the viewport center on this column layout")
        guard let tile else { return }
        let initialY = tile.frame.midY
        let heroY = app.staticTexts["hero.title"].frame.midY
        tile.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
        expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: tile)
        expectation(for: NSPredicate { _, _ in tile.frame.midY < initialY - 20 }, evaluatedWith: tile)
        waitForExpectations(timeout: 5)
        XCTAssertGreaterThan(tile.frame.minY, app.staticTexts["hero.title"].frame.maxY)
        XCTAssertLessThan(tile.frame.maxY, app.buttons["state.action"].frame.minY)
        XCTAssertEqual(app.staticTexts["hero.title"].frame.midY, heroY, accuracy: 4)
        capture("portrait-tapped-selection-centered")
    }

    // The QA input buttons send the same ShellInput events as a controller.
    func testPortraitControllerSelectionScrollsIntoView() {
        extraArguments = ["--input-test"]
        launch("library")
        let tile = app.buttons["tile.paper"]
        let initialY = tile.frame.midY
        app.buttons["qa.input.down"].tap()
        app.buttons["qa.input.down"].tap()
        expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: tile)
        expectation(for: NSPredicate { _, _ in tile.frame.midY < initialY - 20 }, evaluatedWith: tile)
        waitForExpectations(timeout: 5)
        XCTAssertLessThan(tile.frame.maxY, app.buttons["state.action"].frame.minY)
        capture("portrait-controller-selection-centered")
    }

    // Run on a compact portrait simulator, including the closed Duo.
    func testCompactPortraitPullDownKeepsNativeActionsAvailable() {
        XCUIDevice.shared.orientation = .portrait
        extraArguments = ["--samples"]
        launch("library")
        let grid = app.scrollViews["library.grid"]
        XCTAssertTrue(grid.exists)
        let controllers = app.buttons["controllers.open"]
        let settings = app.buttons["shellSettings.open"]
        let originalControllers = controllers.frame
        let originalSettings = settings.frame
        let start = grid.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.35))
        let end = grid.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.8))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 3)
        XCTAssertEqual(controllers.frame, originalControllers)
        XCTAssertEqual(settings.frame, originalSettings)
        XCTAssertTrue(controllers.isHittable)
        XCTAssertTrue(settings.isHittable)
        capture("compact-portrait-after-pull-down")
    }

    // Run on an expanded, flat portrait simulator. Use real coordinates, not accessibility activation.
    func testCollapsedPortraitGridReceivesTouchesAboveOriginalScrollOrigin() {
        extraArguments = ["--games", "28", "--samples"]
        launch("library")
        let grid = app.scrollViews["library.grid"]
        let heading = app.otherElements["library.heading"]
        let initialTop = app.buttons["tile.orbit"].frame.minY
        let tide = app.buttons["tile.tide"]
        tide.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(tide.isSelected, "Coordinate taps must reach the active inner display before scrolling")
        grid.swipeUp()
        let candidates = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "tile."))
            .allElementsBoundByIndex.filter(\.exists)
        let exposedTop = heading.frame.maxY + 4
        let tile = candidates.first { !$0.isSelected
            && min($0.frame.maxY, initialTop - 4) - max($0.frame.minY, exposedTop) > 24 }
        XCTAssertNotNil(tile, "A visible tile must occupy the region exposed by the shrinking hero")
        guard let tile else { return }
        let upperGridY = (max(tile.frame.minY, exposedTop) + min(tile.frame.maxY, initialTop - 4)) / 2
        XCTAssertLessThan(upperGridY, initialTop, "Tap must be above the original grid origin")
        capture("collapsed-portrait-before-upper-tile-tap")
        tile.coordinate(withNormalizedOffset: CGVector(dx: 0.5,
            dy: (upperGridY - tile.frame.minY) / tile.frame.height)).tap()
        expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: tile)
        waitForExpectations(timeout: 5)
        capture("collapsed-portrait-after-upper-tile-tap")
    }

    // Run on an expanded, flat portrait simulator.
    func testPortraitHeroFinishesAfterFastScroll() throws {
        for count in [7, 28] {
            extraArguments = ["--samples", "--games", "\(count)"]
            launch("library")
            let grid = app.scrollViews["library.grid"]
            let hero = app.staticTexts["hero.title"]
            try XCTSkipIf(grid.frame.minY < hero.frame.maxY, "Requires an expanded portrait layout")
            let initialHeight = grid.frame.height
            XCTAssertTrue(app.otherElements["library.heading"].staticTexts["\(count)"].exists)
            let start = grid.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.8))
            start.press(forDuration: 0.01, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -140)),
                        withVelocity: .fast, thenHoldForDuration: 0)
            XCTAssertEqual(hero.frame.minX, grid.frame.minX + 24, accuracy: 5)
            XCTAssertGreaterThan(grid.frame.height, initialHeight + 40)
            capture("portrait-hero-fast-scroll-\(count)")
        }
    }

    // Run on an expanded, flat portrait simulator.
    func testPortraitHeroFinishesAfterThresholdWhileScrollIsHeld() throws {
        extraArguments = ["--games", "28", "--samples"]
        launch("library")
        let grid = app.scrollViews["library.grid"]
        let hero = app.staticTexts["hero.title"]
        try XCTSkipIf(grid.frame.minY < hero.frame.maxY, "Requires an expanded portrait layout")
        let initialHeight = grid.frame.height
        let start = grid.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.7))
        let end = start.withOffset(CGVector(dx: 0, dy: -96))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 2)
        XCTAssertEqual(hero.frame.minX, grid.frame.minX + 24, accuracy: 5,
                       "Crossing the threshold must finish the transition without further finger movement")
        XCTAssertGreaterThan(grid.frame.height, initialHeight + 20)
        grid.swipeDown()
        grid.swipeDown()
        XCTAssertEqual(hero.frame.minX, grid.frame.minX + 24, accuracy: 4)
        XCTAssertEqual(grid.frame.height, initialHeight, accuracy: 4)
    }

    // Run on an expanded, flat portrait simulator.
    func testSmallPortraitLibraryBouncesWithoutCollapsingHero() throws {
        extraArguments = ["--games", "1", "--samples"]
        launch("library")
        let grid = app.scrollViews["library.grid"]
        let hero = app.staticTexts["hero.title"]
        try XCTSkipIf(grid.frame.minY < hero.frame.maxY, "Requires an expanded portrait layout")
        let initialHeight = grid.frame.height
        let initialHero = hero.frame
        XCTAssertEqual(hero.frame.minX, grid.frame.minX + 24, accuracy: 4)
        grid.swipeUp()
        grid.swipeUp()
        XCTAssertEqual(hero.frame, initialHero)
        XCTAssertEqual(grid.frame.height, initialHeight, accuracy: 4)
        grid.swipeDown()
        XCTAssertEqual(hero.frame, initialHero)
        XCTAssertTrue(app.buttons["state.action"].isHittable)
        XCTAssertTrue(app.buttons["settings.open"].isHittable)
    }

    // Run on an expanded, flat portrait simulator.
    func testExpandedPortraitHeroKeepsLeadingAlignmentWhileCollapsing() throws {
        launch("library")
        let hero = app.staticTexts["hero.title"]
        let grid = app.scrollViews["library.grid"]
        XCTAssertTrue(hero.waitForExistence(timeout: 5))
        try XCTSkipIf(grid.frame.minY < hero.frame.maxY, "Requires an expanded portrait layout")
        XCTAssertEqual(hero.frame.minX, grid.frame.minX + 24, accuracy: 4)
        let initialY = hero.frame.midY
        capture("expanded-portrait-cover-art-hero")
        grid.swipeUp()
        grid.swipeUp()
        XCTAssertLessThan(hero.frame.midY, initialY - 20)
        XCTAssertLessThan(hero.frame.minX, grid.frame.minX + grid.frame.width * 0.25)
        XCTAssertEqual(hero.frame.minX, grid.frame.minX + 24, accuracy: 4)
        capture("expanded-portrait-leading-hero")
    }

    // Run on an expanded, flat portrait simulator.
    func testPortraitHeroCollapsesThenStaysPinned() {
        launch("library")
        let grid = app.scrollViews["library.grid"]
        let hero = app.staticTexts["hero.title"]
        XCTAssertTrue(hero.waitForExistence(timeout: 5))
        let play = app.buttons["state.action"]
        let initial = play.frame
        let heroInitialY = hero.frame.midY
        grid.swipeUp()
        capture("portrait-after-first-swipe")
        XCTAssertLessThan(hero.frame.midY, heroInitialY - 20)
        XCTAssertEqual(play.frame.midY, initial.midY, accuracy: 4)
        let compactY = hero.frame.midY
        grid.swipeUp()
        XCTAssertEqual(hero.frame.midY, compactY, accuracy: 4)
        XCTAssertEqual(play.frame.midY, initial.midY, accuracy: 4)
        capture("flat-portrait-pinned-hero")
        XCTAssertEqual(app.buttons.matching(identifier: "settings.open").count, 1)
        play.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.alerts["Demo action"].waitForExistence(timeout: 5))
        app.alerts.buttons["OK"].tap()
    }

    // Run in portrait with an active horizontal system division.
    func testTabletopKeepsHeroAndBottomActionsWhileGridScrolls() {
        launch("library")
        let grid = app.scrollViews["library.grid"]
        let hero = app.staticTexts["hero.title"]
        XCTAssertTrue(hero.waitForExistence(timeout: 5))
        let header = hero.frame
        let heading = app.otherElements["library.heading"]
        XCTAssertTrue(heading.exists)
        let headingFrame = heading.frame
        XCTAssertGreaterThan(headingFrame.minY, header.maxY)
        XCTAssertLessThanOrEqual(headingFrame.maxY, grid.frame.minY + 1)
        let play = app.buttons["state.action"]
        let actionFrame = play.frame
        XCTAssertGreaterThan(play.frame.width, grid.frame.width * 0.6)
        let firstTileY = app.buttons["tile.paper"].frame.minY
        grid.swipeUp()
        XCTAssertLessThan(app.buttons["tile.paper"].frame.minY, firstTileY - 20)
        XCTAssertEqual(hero.frame, header)
        XCTAssertEqual(heading.frame, headingFrame)
        XCTAssertEqual(play.frame, actionFrame)
        XCTAssertEqual(app.buttons.matching(identifier: "state.action").count, 1)
        let scrolled = XCTAttachment(screenshot: app.screenshot())
        scrolled.name = "tabletop-scrolled-material-heading"
        scrolled.lifetime = .keepAlways
        add(scrolled)
        app.buttons["settings.open"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["library.back"].waitForExistence(timeout: 5))
        app.buttons["library.back"].tap()
    }

    // Run in tabletop: the visible primary-region hero provides the game's artwork/version context.
    func testTabletopGameSettingsUsesNativeTitleWithoutDuplicateHero() {
        launch("library")
        app.buttons["settings.open"].tap()
        XCTAssertTrue(app.buttons["library.back"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars.staticTexts["Mario Kart™ 8 Deluxe"].exists)
        XCTAssertTrue(app.navigationBars.staticTexts["GAME SETTINGS"].exists)
        XCTAssertFalse(app.staticTexts["detail.title"].exists)
        XCTAssertFalse(settingsScroll.staticTexts["Version 1.4.0"].exists)
        XCTAssertTrue(app.segmentedControls["setting.DM_OPERATION_MODE"].firstMatch.isHittable)
        XCTAssertTrue(app.buttons["state.action"].isHittable)
        app.buttons["library.back"].tap()
        XCTAssertTrue(app.buttons["settings.open"].waitForExistence(timeout: 5))
    }

    // Run with an active horizontal division in tabletop portrait.
    func testTabletopMenusStayBelowHeroAndContentScrolls() {
        launch("library")
        let heroBottom = app.staticTexts["hero.title"].frame.maxY
        for (open, close) in [("controllers.open", "controllers.close"), ("shellSettings.open", "shellSettings.close"), ("settings.open", "library.back")] {
            app.buttons[open].tap()
            XCTAssertTrue(app.buttons[close].waitForExistence(timeout: 5))
            XCTAssertGreaterThan(app.navigationBars.containing(.button, identifier: close).firstMatch.frame.minY, heroBottom)
            let scroll = app.scrollViews.element(boundBy: app.scrollViews.count - 1)
            scroll.swipeUp()
            XCTAssertTrue(app.buttons[close].isHittable)
            XCTAssertGreaterThan(app.navigationBars.containing(.button, identifier: close).firstMatch.frame.minY, heroBottom)
            app.buttons[close].tap()
        }
        XCTAssertTrue(app.buttons["settings.open"].isHittable)
    }

    // Run with an active vertical system division.
    func testFoldedCoverFlowIsOneSequenceWithoutRepeatedSelection() {
        launch("library")
        let flow = app.scrollViews["library.coverflow"]
        XCTAssertTrue(flow.waitForExistence(timeout: 5))
        XCTAssertFalse(app.scrollViews["library.selected"].exists)
        XCTAssertFalse(app.buttons["selected.artwork"].exists)
        let orbit = app.buttons["tile.orbit"]
        let tide = app.buttons["tile.tide"]
        let dragDistance = orbit.frame.width * 0.7
        XCTAssertEqual(app.buttons.matching(identifier: "tile.orbit").count, 1)
        XCTAssertLessThan(orbit.frame.midX, flow.frame.midX)
        XCTAssertGreaterThan(tide.frame.midX, flow.frame.midX)
        XCTAssertGreaterThan(tide.frame.minX, orbit.frame.midX)
        XCTAssertLessThanOrEqual(tide.frame.minX, orbit.frame.maxX + 12)
        XCTAssertLessThan(app.buttons["state.action"].frame.maxX, flow.frame.midX)
        XCTAssertEqual(app.staticTexts["hero.title"].frame.minX, app.buttons["state.action"].frame.minX, accuracy: 4)
        XCTAssertTrue(app.buttons["controllers.open"].isHittable)
        XCTAssertTrue(app.buttons["shellSettings.open"].isHittable)
        XCTAssertTrue(app.staticTexts["library.position"].exists)
        flow.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: flow.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).withOffset(CGVector(dx: -dragDistance, dy: 0)), withVelocity: .slow, thenHoldForDuration: 0.1)
        expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: tide)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(app.staticTexts["hero.title"].label, "Animal Crossing™: New Horizons")
        XCTAssertEqual(app.buttons.matching(identifier: "tile.tide").count, 1)
        XCTAssertFalse(app.alerts["Demo action"].exists)
        XCTAssertEqual(app.buttons.matching(identifier: "state.action").count, 1)
        flow.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: flow.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)).withOffset(CGVector(dx: dragDistance, dy: 0)), withVelocity: .slow, thenHoldForDuration: 0.1)
        expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: orbit)
        waitForExpectations(timeout: 5)
        app.buttons["settings.open"].tap()
        XCTAssertTrue(app.buttons["library.back"].waitForExistence(timeout: 5))
        app.buttons["library.back"].tap()
        capture("folded-coverflow-one-sequence")
        extraArguments = ["--select", "amber"]
        launch("library")
        let last = app.buttons["tile.amber"]
        XCTAssertTrue(last.isSelected)
        XCTAssertLessThan(last.frame.midX, flow.frame.midX)
        XCTAssertEqual(app.buttons.matching(identifier: "tile.amber").count, 1)
        let distance = last.frame.width * 0.7
        flow.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: flow.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)).withOffset(CGVector(dx: distance, dy: 0)), withVelocity: .slow, thenHoldForDuration: 0.1)
        expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: app.buttons["tile.drift"])
        waitForExpectations(timeout: 5)
    }

    // Run on the closed Duo portrait display with its native trailing rail.
    func testOuterPortraitActionsUseBottomWidthClearOfRail() {
        launch("library")
        let play = app.buttons["state.action"]
        let settings = app.buttons["settings.open"]
        let rail = app.buttons["shellSettings.open"]
        let controllers = app.buttons["controllers.open"]
        XCTAssertTrue(controllers.isHittable)
        XCTAssertTrue(rail.isHittable)
        XCTAssertEqual(controllers.frame.midY, rail.frame.midY, accuracy: 4)
        XCTAssertTrue(play.isHittable)
        XCTAssertTrue(settings.isHittable)
        XCTAssertGreaterThan(settings.frame.maxX, rail.frame.minX)
        XCTAssertGreaterThan(settings.frame.minY, rail.frame.maxY)
        XCTAssertEqual(play.frame.midY, settings.frame.midY, accuracy: 2)
        settings.tap()
        XCTAssertTrue(app.buttons["library.back"].waitForExistence(timeout: 5))
    }

    func testGameSettingsTitleFollowsHeroVisibility() {
        launch("library")
        app.buttons["settings.open"].tap()
        XCTAssertTrue(app.buttons["library.back"].waitForExistence(timeout: 5))
        let title = app.navigationBars.staticTexts["Mario Kart™ 8 Deluxe"]
        XCTAssertFalse(title.exists)
        let scroll = settingsScroll
        scroll.swipeUp()
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        scroll.swipeDown()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: title)
        waitForExpectations(timeout: 5)
    }

    func testGameSettingsHeaderPlayHandsOffWithoutDuplicateAction() {
        launch("library")
        app.buttons["settings.open"].tap()
        XCTAssertTrue(app.buttons["library.back"].waitForExistence(timeout: 5))
        let play = app.buttons["state.action"]
        expectation(for: NSPredicate { _, _ in self.app.buttons.matching(identifier: "state.action").count == 1 }, evaluatedWith: app)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(play.isHittable)
        XCTAssertEqual(play.label, "Play")
        play.tap()
        XCTAssertTrue(app.alerts["Demo action"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.alerts.staticTexts["Play requested. The demo does not launch games."].exists)
        app.alerts.buttons["OK"].tap()
        XCTAssertTrue(app.buttons["settings.open"].waitForExistence(timeout: 5))
    }

    func testActionsAndNavigation() {
        XCUIDevice.shared.orientation = .portrait
        launch("library")
        let settings = app.buttons["settings.open"]
        if settings.exists { settings.tap() }
        let frameRate = app.switches["setting.DM_SHOW_FPS"]
        XCTAssertTrue(frameRate.waitForExistence(timeout: 5))
        let toggled = frameRate.value as? String == "1" ? "0" : "1"
        frameRate.tap()
        expectation(for: NSPredicate(format: "value == %@", toggled), evaluatedWith: frameRate)
        waitForExpectations(timeout: 5)
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
    private func dismissSheet(closeID: String = "library.back", short: Bool = false) {
        let bar = app.navigationBars.containing(.button, identifier: closeID).firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        let start = bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05))
        let end = start.withOffset(CGVector(dx: 0, dy: short ? 30 : 600))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: short ? .slow : .fast, thenHoldForDuration: short ? 0.5 : 0)
    }
    func testNativeSheetDismissesSettingsAndCanBeCancelled() {
        launch("library")
        app.buttons["settings.open"].tap()
        XCTAssertTrue(app.buttons["library.back"].waitForExistence(timeout: 5))
        dismissSheet(short: true)
        XCTAssertTrue(app.buttons["library.back"].isHittable)
        dismissSheet()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.buttons["library.back"])
        waitForExpectations(timeout: 5)
        XCTAssertTrue(app.buttons["settings.open"].isHittable)
    }
    func testNativeSheetDismissesControllers() {
        launch("library")
        app.buttons["controllers.open"].tap()
        XCTAssertTrue(app.buttons["controllers.close"].waitForExistence(timeout: 5))
        dismissSheet(closeID: "controllers.close")
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.buttons["controllers.close"])
        waitForExpectations(timeout: 5)
        XCTAssertTrue(app.buttons["controllers.open"].isHittable)
    }
    func testShortShelfSelects() {
        XCUIDevice.shared.orientation = .landscapeLeft
        extraArguments = ["--games", "3"]
        launch("library")
        app.buttons["tile.paper"].tap()
        XCTAssertEqual(app.staticTexts["hero.title"].label, "Super Smash Bros.™ Ultimate")
        // Under the card the native primary action offers the existing recovery action.
        XCTAssertEqual(app.buttons["state.action"].label, "Choose game data…, Super Smash Bros.™ Ultimate")
        XCUIDevice.shared.orientation = .portrait
    }
    func testLargeText() {
        extraArguments = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
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
        XCTAssertEqual(app.staticTexts["hero.title"].label, "Animal Crossing™: New Horizons")
        capture("selected-after-rotation")
    }
}
