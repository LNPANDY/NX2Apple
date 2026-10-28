import XCTest
import SwiftUI
@testable import NSPortBuilder

/// The live console driver over a real GameLibrary in a temporary folder, with fake controllers and a fake launch call.
@MainActor final class ConsoleLiveTests: XCTestCase {
    private var temporary: URL!
    private let titleID = "01001A9012345000"
    private let bundleID = "org.nxnative.consolelivetests"

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("ConsoleLiveTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }
    override func tearDown() {
        try? FileManager.default.removeItem(at: temporary)
        for key in ["launcher.DM_FPS_TARGET"] { CFPreferencesSetAppValue(key as CFString, nil, bundleID as CFString) }
        CFPreferencesAppSynchronize(bundleID as CFString)
    }

    private func makeApp(name: String = "Hades") throws -> URL {
        let app = temporary.appendingPathComponent(name + ".app")
        let macos = app.appendingPathComponent("Contents/MacOS"), dm = app.appendingPathComponent("Contents/Resources/dm")
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dm, withIntermediateDirectories: true)
        for exe in ["nxnative", "dmhost"] { try FileManager.default.createSymbolicLink(at: macos.appendingPathComponent(exe), withDestinationURL: URL(fileURLWithPath: "/usr/bin/true")) }
        let info: [String: Any] = ["DMTitleID": titleID, "CFBundleDisplayName": name, "CFBundleExecutable": "nxnative", "CFBundleIdentifier": bundleID,
                                   "CFBundleShortVersionString": "1.2.3"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        let list = #"{"schema":1,"settings":[{"env":"DM_FPS_TARGET","kind":"choice","label":"Frame rate","note":"","default":"60","section":"Game","options":[["30","30 fps"],["60","60 fps"]]}]}"#
        try Data(list.utf8).write(to: dm.appendingPathComponent("launcher.json"))
        return app
    }

    private struct Launch { var game: LibraryGame; var environment: [String: String] }

    private func makeDriver(controls: ControlLayout? = nil, pads: [ConsolePadSnapshot] = [], launched: @escaping (Launch) -> Void = { _ in }) throws
        -> (LiveConsoleDriver, GameLibrary, ControlLayout) {
        let library = GameLibrary(file: temporary.appendingPathComponent("library.json"))
        _ = try library.addApp(try makeApp())
        let layout = controls ?? ControlLayout(defaults: UserDefaults(suiteName: "ConsoleLiveTests-" + UUID().uuidString)!)
        let driver = LiveConsoleDriver(library: library, controls: layout, repo: { "" }, lang: { .en }, labels: { L10n.string($0, .en) },
                                       pads: { pads }, launch: { game, env, done in launched(Launch(game: game, environment: env)); done(4242, nil) },
                                       artwork: { _, _ in nil }, startingTimeout: 0.2, observeSystem: false)
        return (driver, library, layout)
    }

    func testLibraryEntriesBecomeConsoleGames() throws {
        let (driver, library, _) = try makeDriver()
        let game = try XCTUnwrap(driver.state.games.first)
        XCTAssertEqual(library.games.count, 1)
        XCTAssertEqual(game.title, "Hades")
        XCTAssertEqual(game.version, "1.2.3")
        XCTAssertEqual(game.status, .ready)
        XCTAssertEqual(game.platforms, [.mac])
        XCTAssertTrue(game.settings.map(\.env).contains("DM_FPS_TARGET"))
        XCTAssertEqual(game.values["DM_FPS_TARGET"], "60")
        XCTAssertEqual(driver.state.focusedGameID, game.id)
    }

    func testStatusAndPlatformsPerLibraryEntry() {
        let broken = LibraryGame(titleID: titleID, name: "A", appPath: "/gone/A.app")
        XCTAssertEqual(LiveConsoleDriver.status(of: broken, brokenMessage: "x"), .broken("x"))
        XCTAssertEqual(LiveConsoleDriver.status(of: LibraryGame(titleID: titleID, name: "B"), brokenMessage: "x"), .needsData)
        var chosen = LibraryGame(titleID: titleID, name: "C")
        chosen.inputs = ["keys": ["/k"]]
        XCTAssertEqual(LiveConsoleDriver.status(of: chosen, brokenMessage: "x"), .needsBuild)
        XCTAssertEqual(LiveConsoleDriver.platforms(of: broken), [.mac])
    }

    func testPlayRoutesToTheLaunchWithTheDesktopEnvironment() throws {
        var launches: [Launch] = []
        let (driver, _, layout) = try makeDriver { launches.append($0) }
        layout.padMerge = true
        let id = try XCTUnwrap(driver.state.games.first?.id)
        driver.play(id)
        XCTAssertEqual(launches.count, 1)
        XCTAssertEqual(launches.first?.environment["DM_PAD_MERGE"], "1")
        XCTAssertEqual(launches.first?.environment["DM_LAUNCHER"], "0")
        XCTAssertEqual(launches.first?.game.titleID, titleID)
        let expected = launches.first.map { GameStart.environment(for: $0.game, library: GameLibrary(file: temporary.appendingPathComponent("other.json")), controls: layout, repo: "", labels: { $0 }) }
        XCTAssertEqual(launches.first?.environment, expected, "the same function the desktop Play uses")
    }

    func testStartingEndsWhenTheGameQuits() async throws {
        let (driver, _, _) = try makeDriver()
        let id = try XCTUnwrap(driver.state.games.first?.id)
        driver.play(id)
        for _ in 0..<50 where driver.state.starting != .opening { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(driver.state.startingGameID, id)
        XCTAssertEqual(driver.state.starting, .opening)
        driver.gameDidTerminate(pid: 1)
        XCTAssertEqual(driver.state.startingGameID, id, "another process changes nothing")
        driver.gameDidTerminate(pid: 4242)
        XCTAssertNil(driver.state.startingGameID)
        XCTAssertFalse(driver.state.exited)
        XCTAssertEqual(driver.state.focusedGameID, id, "the selected game is kept")
    }

    func testOptionsRoundTripThroughSavedChoices() throws {
        let (driver, library, _) = try makeDriver()
        let game = try XCTUnwrap(library.games.first)
        let id = game.id.uuidString
        driver.setOption(gameID: id, setting: "DM_FPS_TARGET", value: "30")
        XCTAssertEqual(driver.state.games.first?.values["DM_FPS_TARGET"], "30")
        let setting = try XCTUnwrap(driver.state.games.first?.settings.first { $0.env == "DM_FPS_TARGET" })
        XCTAssertEqual(SavedChoices(app: game.appPath, titleID: game.titleID).current(setting), "30", "the same store LaunchOptionsView reads")
        driver.refresh()
        XCTAssertEqual(driver.state.games.first?.values["DM_FPS_TARGET"], "30")
        driver.setOption(gameID: id, setting: "DM_FPS_TARGET", value: "60")
        XCTAssertNil(SavedChoices(app: game.appPath, titleID: game.titleID).value(setting), "the default removes the saved choice")
        driver.setOption(gameID: id, setting: "DM_FPS_TARGET", value: "999")
        XCTAssertEqual(driver.state.games.first?.values["DM_FPS_TARGET"], "60", "a value the build does not offer is refused")
    }

    func testControllerSnapshotMapping() {
        let xbox = ConsolePadSnapshot(id: "a", name: "Wireless Controller", category: "Xbox One", playerIndex: 2, battery: 0.76, charging: false).controller
        XCTAssertEqual(xbox.kind, .xbox)
        XCTAssertEqual(xbox.player, 2)
        XCTAssertEqual(xbox.batteryPercent, 76)
        XCTAssertEqual(ConsolePadSnapshot(id: "b", name: "p", category: "Switch Pro Controller", playerIndex: nil).controller.kind, .fullSize)
        XCTAssertEqual(ConsolePadSnapshot(id: "c", name: "j", category: "Nintendo Switch JoyCon (L/R)", playerIndex: 1).controller.kind, .paired)
        let ps = ConsolePadSnapshot(id: "d", name: "DualSense", category: "DualSense", playerIndex: 4, battery: 0.1, charging: true).controller
        XCTAssertEqual(ps.kind, .gamepad)
        XCTAssertTrue(ps.charging)
        XCTAssertNil(ConsolePadSnapshot(id: "e", name: "x", category: nil, playerIndex: nil).controller.battery)
    }

    func testDriverShowsFakeControllersAndTheSharedPlayerMode() throws {
        let pads = [ConsolePadSnapshot(id: "a", name: "Pad", category: "Xbox One", playerIndex: 1, battery: 0.5)]
        let (driver, _, layout) = try makeDriver(pads: pads)
        XCTAssertEqual(driver.state.controllers.map(\.id), ["a"])
        driver.setPadMerge(true)
        XCTAssertTrue(layout.padMerge)
        XCTAssertTrue(driver.state.padMerge)
        driver.disconnect(controllerID: "a")
        XCTAssertNotNil(driver.state.toast, "a Bluetooth controller cannot be dropped by an app: the toast says where")
    }

    func testEnteringAndLeavingConsoleModeRestoresTheWindow() {
        var calls: [Bool] = []
        let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        let coordinator = ConsoleCoordinator(window: { window }, setFullScreen: { _, on in calls.append(on) })
        coordinator.enter()
        XCTAssertFalse(coordinator.active, "not while the guided setup shows")
        coordinator.available = true
        coordinator.enter()
        XCTAssertTrue(coordinator.active)
        XCTAssertEqual(calls, [true])
        coordinator.enter()
        XCTAssertEqual(calls, [true], "entering twice does nothing")
        coordinator.exit()
        XCTAssertFalse(coordinator.active)
        coordinator.toggle()
        XCTAssertTrue(coordinator.active)
    }

    func testControllerPromptOncePerSessionAndSetting() {
        XCTAssertTrue(ConsolePrompt.shouldShow(enabled: true, shown: false))
        XCTAssertFalse(ConsolePrompt.shouldShow(enabled: true, shown: true))
        XCTAssertFalse(ConsolePrompt.shouldShow(enabled: false, shown: false))
    }

    func testBatteryFillFraction() {
        XCTAssertEqual(BatteryIcon.fillFraction(0.76), 0.76)
        XCTAssertEqual(BatteryIcon.fillFraction(0), 0)
        XCTAssertEqual(BatteryIcon.fillFraction(1.4), 1)
        XCTAssertEqual(BatteryIcon.fillFraction(-1), 0)
        XCTAssertEqual(BatteryIcon.fillFraction(.nan), 0)
        XCTAssertEqual(BatteryIcon.fillFraction(nil), 0)
        XCTAssertTrue(BatteryIcon.isLow(0.2))
        XCTAssertTrue(BatteryIcon.isLow(0.12))
        XCTAssertFalse(BatteryIcon.isLow(0.21))
        XCTAssertFalse(BatteryIcon.isLow(nil))
    }

    func testPlayersAreAssignedAutomaticallyInOrder() {
        func pad(_ id: String, _ player: Int?) -> ConsolePadSnapshot { ConsolePadSnapshot(id: id, name: id, category: nil, playerIndex: player) }
        let result = LiveConsoleDriver.autoAssigned([pad("a", nil), pad("b", 1), pad("c", nil), pad("d", nil)])
        XCTAssertEqual(result.map(\.playerIndex), [2, 1, 3, 4], "the next free players, never one already taken")
        let full = LiveConsoleDriver.autoAssigned([pad("a", 1), pad("b", 2), pad("c", 3), pad("d", 4), pad("e", nil)])
        XCTAssertNil(full.last?.playerIndex, "a fifth controller has no free player")
        XCTAssertEqual(LiveConsoleDriver.autoAssigned([pad("a", 3)]).map(\.playerIndex), [3], "an assigned one keeps its player")
    }

    func testDriverListsFakeControllersWithPlayers() throws {
        let pads = [ConsolePadSnapshot(id: "a", name: "Pad", category: "Xbox One", playerIndex: nil)]
        let (driver, _, _) = try makeDriver(pads: pads)
        XCTAssertEqual(driver.state.controllers.first?.player, 1, "never shown as unassigned")
    }

    func testIPhoneOnlyAndNotBuiltStatuses() throws {
        var ios = LibraryGame(titleID: titleID, name: "A")
        ios.iosAppPath = temporary.path   // any folder with an Info.plist counts as an iOS app
        try Data([0]).write(to: temporary.appendingPathComponent("Info.plist"))
        XCTAssertEqual(LiveConsoleDriver.status(of: ios, brokenMessage: "x"), .iphoneOnly)
        XCTAssertEqual(LiveConsoleDriver.platforms(of: ios), [.iphone])
        XCTAssertEqual(LiveConsoleDriver.status(of: LibraryGame(titleID: titleID, name: "B"), brokenMessage: "x"), .needsData)
        XCTAssertEqual(ConsoleGame.Status.iphoneOnly.labelKey, "console.iphoneOnly")
        XCTAssertEqual(ConsoleGame.Status.needsBuild.labelKey, "console.notBuilt")
        XCTAssertEqual(ConsoleGame.Status.needsData.labelKey, "console.needsDataBadge")
    }

    func testVersionFromMacAppIOSAppAndPlist() throws {
        XCTAssertEqual(LiveConsoleDriver.version(plist: try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": "1.2.3"], format: .xml, options: 0)), "1.2.3")
        XCTAssertEqual(LiveConsoleDriver.version(plist: try PropertyListSerialization.data(fromPropertyList: ["CFBundleVersion": "7"], format: .xml, options: 0)), "7")
        XCTAssertEqual(LiveConsoleDriver.version(plist: Data([0])), "")
        let ios = temporary.appendingPathComponent("ios.app")
        try FileManager.default.createDirectory(at: ios, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": "2.0.1"], format: .xml, options: 0).write(to: ios.appendingPathComponent("Info.plist"))
        XCTAssertEqual(LiveConsoleDriver.version(at: ios.path), "2.0.1")
        XCTAssertEqual(LiveConsoleDriver.version(at: temporary.appendingPathComponent("none.app").path), "")
    }

    func testBatteryReadingTreatsAnUnreportedLevelAsUnknown() {
        XCTAssertNil(ConsolePadSnapshot.batteryReading(level: 0, state: .unknown).level, "a DualShock 4 over Bluetooth: 0 with an unknown state")
        XCTAssertNil(ConsolePadSnapshot.batteryReading(level: 0.5, state: .unknown).level)
        XCTAssertEqual(ConsolePadSnapshot.batteryReading(level: 0.12, state: .discharging).level, 0.12)
        XCTAssertEqual(ConsolePadSnapshot.batteryReading(level: 0, state: .discharging).level, 0, "an explicit empty battery is real")
        let charging = ConsolePadSnapshot.batteryReading(level: 0.4, state: .charging)
        XCTAssertEqual(charging.level, 0.4)
        XCTAssertTrue(charging.charging)
        XCTAssertEqual(ConsolePadSnapshot.batteryReading(level: 0, state: .charging).level, 0, "charging reports its real level, even a low one")
        let full = ConsolePadSnapshot.batteryReading(level: 0, state: .full)
        XCTAssertEqual(full.level, 1, "full: the full battery")
        XCTAssertTrue(full.charging, "with the bolt")
        let topped = ConsolePadSnapshot.batteryReading(level: 1.0, state: .charging)
        XCTAssertEqual(topped.level, 1)
        XCTAssertTrue(topped.charging)
        XCTAssertNil(ConsolePadSnapshot.batteryReading(level: 1, state: .unknown).level, "no guess of full for a pad that reports no state")
        let pad = ConsolePadSnapshot(id: "a", name: "DUALSHOCK 4", category: "DualShock 4", playerIndex: 1, battery: nil).controller
        XCTAssertNil(pad.battery)
        XCTAssertNil(pad.batteryPercent, "no percentage, so no red 0%")
    }

    func testIdentifyUsesWhatTheControllerHasInOrder() {
        XCTAssertEqual(IdentifyPlan.actions(playerLights: true, lightBar: true, rumble: true), [.playerLights, .lightBar, .rumble])
        XCTAssertEqual(IdentifyPlan.actions(playerLights: false, lightBar: true, rumble: true), [.lightBar, .rumble], "a DualShock 4: light bar and rumble")
        XCTAssertEqual(IdentifyPlan.actions(playerLights: false, lightBar: false, rumble: true), [.rumble])
        XCTAssertEqual(IdentifyPlan.actions(playerLights: false, lightBar: false, rumble: false), [], "nothing to do: the button is hidden")
        var pad = ConsolePadSnapshot(id: "a", name: "x", category: nil, playerIndex: 1)
        XCTAssertTrue(pad.controller.canIdentify)
        pad.canIdentify = false
        XCTAssertFalse(pad.controller.canIdentify)
    }

    func testSelectButtonGlyphAndInput() {
        XCTAssertNil(ConsoleInput(.select), "in console mode Select does nothing special")
        XCTAssertEqual(ConsoleGlyphs.Role.select.element, .select)
        XCTAssertEqual(ConsoleGlyphs(family: .playStation, reported: [.select: "square.and.arrow.up"]).glyph(for: .select), .symbol("square.and.arrow.up"), "the controller's own symbol")
        for family in [ConsoleGlyphs.Family.xbox, .playStation, .nintendo, .neutral] {
            XCTAssertEqual(ConsoleGlyphs(family: family).glyph(for: .select), .symbol("minus.circle"), "\(family) reporting nothing")
        }
        XCTAssertEqual(ConsoleGlyphs.keyboard.glyph(for: .select), .key("\u{2325}\u{2318}K"))
    }

    /// Two fake controllers connecting one after the other: each is published as soon as the connect notification arrives and takes
    /// the next free player, in connection order.
    func testConnectNotificationPublishesTheNewControllerAtOnce() async throws {
        var current = [ConsolePadSnapshot(id: "first", name: "First", category: "DualShock 4", playerIndex: nil)]
        let library = GameLibrary(file: temporary.appendingPathComponent("library.json"))
        let driver = LiveConsoleDriver(library: library, controls: ControlLayout(defaults: UserDefaults(suiteName: "ConsoleLiveTests-" + UUID().uuidString)!),
                                       repo: { "" }, lang: { .en }, labels: { $0 }, pads: { current }, artwork: { _, _ in nil }, observeSystem: true, watchHardware: false)
        XCTAssertEqual(driver.state.controllers.map(\.id), ["first"])
        XCTAssertEqual(driver.state.controllers.map(\.player), [1])
        current.append(ConsolePadSnapshot(id: "second", name: "Second", category: "Wired", playerIndex: nil))
        NotificationCenter.default.post(name: .GCControllerDidConnect, object: nil)
        for _ in 0..<50 where driver.state.controllers.count < 2 { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(driver.state.controllers.map(\.id), ["first", "second"], "published at once, not at the next tick")
        XCTAssertEqual(driver.state.controllers.map(\.player), [1, 2])
        current.removeFirst()
        NotificationCenter.default.post(name: .GCControllerDidDisconnect, object: nil)
        for _ in 0..<50 where driver.state.controllers.count > 1 { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(driver.state.controllers.map(\.id), ["second"])
    }

    func testInputFromASecondControllerIsNotHiddenByTheFirst() {
        var edges = LauncherGamepad.Edges()
        XCTAssertEqual(edges.changes(controller: "one", state: [("a", true, .a)]).pressed, [.a])
        XCTAssertEqual(edges.changes(controller: "one", state: [("a", true, .a)]).pressed, [], "held on the same controller: no repeat")
        XCTAssertEqual(edges.changes(controller: "two", state: [("a", true, .a)]).pressed, [.a], "the same button on another controller still counts")
        XCTAssertEqual(edges.changes(controller: "one", state: [("a", false, .a)]).released, [.a])
        XCTAssertEqual(edges.changes(controller: "two", state: [("select", true, .select)]).pressed, [.select])
    }

    func testBatteryFillStaysInsideTheOutline() {
        for height: CGFloat in [10, 12, 13, 16] {
            for level in [0, 0.12, 0.65, 1.0] as [Double] {
                let g = BatteryIcon.geometry(height: height, level: level)
                XCTAssertTrue(g.inner.contains(g.fill) || g.fill.width == 0, "height \(height) level \(level): \(g.fill) in \(g.inner)")
                XCTAssertTrue(g.outer.contains(g.inner))
                XCTAssertEqual(g.inner.minX - g.outer.minX, 2, "the stroke and a 1 point gap on every side")
                XCTAssertEqual(g.outer.maxY - g.inner.maxY, 2)
                XCTAssertEqual(g.fill.minX, g.inner.minX, "leading-aligned")
                XCTAssertLessThanOrEqual(g.fill.width, g.inner.width)
                XCTAssertGreaterThanOrEqual(g.nub.minX, g.outer.maxX, "the nub sits outside the body, to the right")
                XCTAssertEqual(g.innerRadius, max(0, g.outerRadius - 2))
                XCTAssertEqual(g.fill.width * 2, (g.fill.width * 2).rounded(), "snapped to whole pixels at 2x")
            }
        }
        let half = BatteryIcon.geometry(height: 12, level: 0.5)
        XCTAssertEqual(half.fill.width, (half.inner.width * 0.5 * 2).rounded() / 2)
        XCTAssertEqual(BatteryIcon.geometry(height: 12, level: nil).fill.width, 0)
    }

    // MARK: Player assignment

    private func twoPadDriver(merge: Bool) -> (LiveConsoleDriver, ControlLayout) {
        let layout = ControlLayout(defaults: UserDefaults(suiteName: "ConsoleLiveTests-" + UUID().uuidString)!)
        layout.padMerge = merge
        let pads = [ConsolePadSnapshot(id: "xbox", name: "Xbox Wireless Controller", category: "Xbox One", playerIndex: nil),
                    ConsolePadSnapshot(id: "ds4", name: "DUALSHOCK 4", category: "DualShock 4", playerIndex: nil)]
        let driver = LiveConsoleDriver(library: GameLibrary(file: temporary.appendingPathComponent("library.json")), controls: layout, repo: { "" }, lang: { .en },
                                       labels: { $0 }, pads: { pads }, artwork: { _, _ in nil }, observeSystem: false)
        driver.captureSeconds = 0.2
        driver.openControllers()
        return (driver, layout)
    }

    func testPickingAPlayerTurnsMergeOffAndTheNextPressAssignsIt() {
        let (driver, layout) = twoPadDriver(merge: true)
        XCTAssertEqual(driver.state.controllers.map(\.player), [1, 2], "assigned on connect whatever the merge")
        driver.requestPlayer(2)
        XCTAssertFalse(layout.padMerge, "merge is switched off by choosing a player")
        XCTAssertFalse(driver.state.padMerge)
        XCTAssertEqual(driver.state.toast?.message, "Each controller is now its own player.")
        XCTAssertEqual(driver.state.assigningPlayer, 2)
        // a press from the first controller: taken as the answer, never used to navigate
        XCTAssertTrue(driver.consumePress(controllerID: "xbox", isBack: false))
        XCTAssertEqual(driver.state.controllers.map(\.player), [2, 1], "the pressed one is P2, the holder of P2 got the freed P1")
        XCTAssertNil(driver.state.assigningPlayer, "capture ended")
        XCTAssertEqual(driver.state.toast?.message, "Xbox Wireless Controller is player 2")
        XCTAssertFalse(driver.consumePress(controllerID: "ds4", isBack: false), "no capture any more: the press navigates")
    }

    func testBackCancelsAssignmentAndPressesFromTheOtherControllerAreIgnoredForARow() {
        let (driver, _) = twoPadDriver(merge: false)
        driver.requestPlayer(3)
        XCTAssertTrue(driver.consumePress(controllerID: "ds4", isBack: true))
        XCTAssertNil(driver.state.assigningPlayer)
        XCTAssertEqual(driver.state.controllers.map(\.player), [1, 2], "nothing changed")
        driver.requestAssignment(controllerID: "ds4")
        XCTAssertTrue(driver.consumePress(controllerID: "xbox", isBack: false), "taken but ignored: the row chose the other controller")
        XCTAssertEqual(driver.state.controllers.map(\.player), [1, 2])
        XCTAssertNotNil(driver.state.assigningPlayer)
        XCTAssertTrue(driver.consumePress(controllerID: "ds4", isBack: false))
        XCTAssertEqual(driver.state.controllers.first { $0.id == "ds4" }?.player, 2, "the row's own player")
    }

    func testAssignmentTimesOut() async throws {
        let (driver, _) = twoPadDriver(merge: false)
        driver.requestPlayer(4)
        XCTAssertNotNil(driver.state.assigningPlayer)
        for _ in 0..<50 where driver.state.assigningPlayer != nil { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertNil(driver.state.assigningPlayer)
        XCTAssertEqual(driver.state.toast?.message, "No button was pressed. Choose a player to try again.")
        XCTAssertEqual(driver.state.controllers.map(\.player), [1, 2])
    }

    func testNoBatteryObjectMeansWired() {
        var pad = ConsolePadSnapshot(id: "w", name: "Wired pad", category: "Generic", playerIndex: 1, battery: nil, hasBattery: false)
        XCTAssertTrue(pad.controller.wired, "no battery object: powered by its cable")
        XCTAssertNil(pad.controller.battery)
        pad.hasBattery = true
        XCTAssertFalse(pad.controller.wired, "a battery object with an unknown state is the neutral outline, not a cable")
        var keyboard = ConsolePadSnapshot(id: "k", name: "Keyboard", category: nil, playerIndex: 1, hasBattery: false)
        keyboard.category = "keyboard"
        XCTAssertNotNil(L10n.table["console.wired"])
    }

    // MARK: Hardware placeholders and reconnects

    private func liveDriver(pads: @escaping () -> [ConsolePadSnapshot]) -> LiveConsoleDriver {
        LiveConsoleDriver(library: GameLibrary(file: temporary.appendingPathComponent("library.json")),
                          controls: ControlLayout(defaults: UserDefaults(suiteName: "ConsoleLiveTests-" + UUID().uuidString)!),
                          repo: { "" }, lang: { .en }, labels: { $0 }, pads: pads, artwork: { _, _ in nil }, observeSystem: false)
    }

    func testPlaceholderFromThePlugInUntilGameControllerReports() {
        var list: [ConsolePadSnapshot] = []
        let driver = liveDriver { list }
        driver.hidEvent(.init(kind: .attach, id: 7, name: "Wireless Controller"))
        XCTAssertEqual(driver.state.controllers.map(\.connecting), [true], "a Connecting chip from the hardware attach")
        XCTAssertEqual(driver.state.controllers.first?.name, "Wireless Controller")
        list = [ConsolePadSnapshot(id: "gc1", name: "DUALSHOCK 4 Wireless Controller", category: "DualShock 4", playerIndex: nil)]
        driver.controllerListChanged(connectedName: "DUALSHOCK 4 Wireless Controller", disconnectedName: nil)
        XCTAssertEqual(driver.state.controllers.map(\.connecting), [false], "replaced by the real controller")
        XCTAssertEqual(driver.state.controllers.map(\.player), [1])
    }

    func testPlaceholderIsRemovedOnUnplugAndGameControllerLateDisconnectIsHandled() {
        var list: [ConsolePadSnapshot] = []
        let driver = liveDriver { list }
        driver.hidEvent(.init(kind: .attach, id: 1, name: "Pad"))
        driver.hidEvent(.init(kind: .detach, id: 1, name: "Pad"))
        XCTAssertTrue(driver.state.controllers.isEmpty, "unplugged before GameController ever reported it")
        // a real one that the hardware drops first: hidden at once, GameController lets go later
        list = [ConsolePadSnapshot(id: "gc1", name: "Pad", category: nil, playerIndex: nil)]
        driver.controllerListChanged(connectedName: "Pad", disconnectedName: nil)
        XCTAssertEqual(driver.state.controllers.count, 1)
        driver.hidEvent(.init(kind: .detach, id: 2, name: "Pad"))
        XCTAssertTrue(driver.state.controllers.isEmpty, "removed on the hardware detach, before GameController's disconnect")
        list = []
        driver.controllerListChanged(connectedName: nil, disconnectedName: "Pad")
        XCTAssertTrue(driver.state.controllers.isEmpty)
    }

    func testPresenceExpiresAfterTenSecondsAndMatchesNamesLoosely() {
        var presence = HIDPresence()
        let start = Date()
        presence.attached(id: 1, name: "Wireless Controller", at: start)
        presence.expire(now: start.addingTimeInterval(9))
        XCTAssertEqual(presence.pending.count, 1)
        presence.expire(now: start.addingTimeInterval(10.5))
        XCTAssertTrue(presence.pending.isEmpty, "GameController never reported it")
        XCTAssertTrue(HIDPresence.matches("DUALSHOCK 4 Wireless Controller", "Wireless Controller"))
        XCTAssertFalse(HIDPresence.matches("Xbox Wireless Controller", ""))
    }

    /// Connect, disconnect, connect the same controller again as a new instance: it is listed again with its player, and the battery
    /// comes from the new instance (unknown first, then the real level).
    func testReconnectShowsTheControllerAgainWithItsPlayerAndFreshBattery() {
        var list = [ConsolePadSnapshot(id: "first", name: "DUALSHOCK 4 Wireless Controller", category: "DualShock 4", playerIndex: nil, battery: 0.65),
                    ConsolePadSnapshot(id: "other", name: "Xbox Wireless Controller", category: "Xbox One", playerIndex: nil, battery: 0.5)]
        let driver = liveDriver { list }
        driver.refreshControllers(announce: false)
        XCTAssertEqual(driver.state.controllers.map(\.player), [1, 2])
        XCTAssertEqual(driver.state.controllers.first?.batteryPercent, 65)
        list.removeFirst()   // unplugged
        driver.controllerListChanged(connectedName: nil, disconnectedName: "DUALSHOCK 4 Wireless Controller")
        XCTAssertEqual(driver.state.controllers.map(\.name), ["Xbox Wireless Controller"])
        // plugged in again: a new instance, a new id, nothing known about its battery yet
        list = [ConsolePadSnapshot(id: "second", name: "DUALSHOCK 4 Wireless Controller", category: "DualShock 4", playerIndex: nil, battery: nil)]
            + [ConsolePadSnapshot(id: "other", name: "Xbox Wireless Controller", category: "Xbox One", playerIndex: nil, battery: 0.5)]
        driver.controllerListChanged(connectedName: "DUALSHOCK 4 Wireless Controller", disconnectedName: nil)
        XCTAssertEqual(driver.state.controllers.count, 2, "it appears again")
        let back = driver.state.controllers.first { $0.id == "second" }
        XCTAssertEqual(back?.player, 1, "its old player comes back")
        XCTAssertNil(back?.battery, "unknown at first: the outline")
        list[0].battery = 0.64
        driver.refreshControllers(announce: false)
        XCTAssertEqual(driver.state.controllers.first { $0.id == "second" }?.batteryPercent, 64, "the next read picks up the real level")
    }

    func testNoPlaceholderForAControllerGameControllerAlreadyListsAtLaunch() {
        let list = [ConsolePadSnapshot(id: "gc", name: "DUALSHOCK 4 Wireless Controller", category: "DualShock 4", playerIndex: nil)]
        let driver = liveDriver { list }
        driver.refreshControllers(announce: false)
        driver.hidEvent(.init(kind: .attach, id: 1, name: "DUALSHOCK 4 Wireless Controller"))
        XCTAssertEqual(driver.state.controllers.map(\.connecting), [false], "its hardware attach at launch adds nothing")
        driver.hidEvent(.init(kind: .attach, id: 2, name: "GamePad-1"))
        XCTAssertEqual(driver.state.controllers.map(\.connecting), [false, true], "a device GameController has not reported shows as connecting")
    }

    func testAnotherDevicesPlaceholderSurvivesAControllerAppearing() {
        var list: [ConsolePadSnapshot] = []
        let driver = liveDriver { list }
        driver.hidEvent(.init(kind: .attach, id: 1, name: "GamePad-1"))
        driver.hidEvent(.init(kind: .attach, id: 2, name: "DUALSHOCK 4 Wireless Controller"))
        list = [ConsolePadSnapshot(id: "gc", name: "DUALSHOCK 4 Wireless Controller", category: "DualShock 4", playerIndex: nil)]
        driver.controllerListChanged(connectedName: "DUALSHOCK 4 Wireless Controller", disconnectedName: nil)
        XCTAssertEqual(driver.state.controllers.map(\.name), ["DUALSHOCK 4 Wireless Controller", "GamePad-1"])
        XCTAssertEqual(driver.state.controllers.map(\.connecting), [false, true], "the unreported device keeps its placeholder")
    }
}
