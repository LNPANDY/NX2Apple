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

    func testEnteringAndLeavingConsoleModeRestoresTheWindowInOrder() async throws {
        var calls: [Bool] = []
        var finishEntering: (() -> Void)?
        let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        let coordinator = ConsoleCoordinator(window: { window }, setFullScreen: { _, on, done in calls.append(on); if on { finishEntering = done } else { done() } }, fadeSeconds: 0.05)
        coordinator.enter()
        XCTAssertFalse(coordinator.active, "not while the guided setup shows")
        coordinator.available = true
        coordinator.enter()
        XCTAssertEqual(calls, [true], "the window starts going full screen")
        XCTAssertFalse(coordinator.active, "the console fades in only after the window finished")
        coordinator.enter()
        XCTAssertEqual(calls, [true], "entering twice does nothing")
        finishEntering?()
        XCTAssertTrue(coordinator.active)
        coordinator.exit()
        XCTAssertFalse(coordinator.active, "the console fades out first")
        XCTAssertEqual(calls, [true], "the window has not left full screen yet")
        try await Task.sleep(nanoseconds: 150_000_000)
        coordinator.toggle()
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
                                       repo: { "" }, lang: { .en }, labels: { $0 }, pads: { current }, artwork: { _, _ in nil }, observeSystem: true)
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


    // MARK: Hardware placeholders and reconnects

    private func liveDriver(pads: @escaping () -> [ConsolePadSnapshot]) -> LiveConsoleDriver {
        LiveConsoleDriver(library: GameLibrary(file: temporary.appendingPathComponent("library.json")),
                          controls: ControlLayout(defaults: UserDefaults(suiteName: "ConsoleLiveTests-" + UUID().uuidString)!),
                          repo: { "" }, lang: { .en }, labels: { $0 }, pads: pads, artwork: { _, _ in nil }, observeSystem: false)
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





    /// The Xbox and DualShock 4 together: both listed from the start with their own player, each with its own battery. One is unplugged
    /// and plugged in again (a new instance) while the other stays, and neither loses its battery or player.
    func testTwoControllersTogetherAndOneReconnects() {
        var list = [ConsolePadSnapshot(id: "ds4", name: "DUALSHOCK 4 Wireless Controller", category: "DualShock 4", playerIndex: nil, battery: nil),
                    ConsolePadSnapshot(id: "xbox", name: "Xbox Wireless Controller", category: "Xbox One", playerIndex: nil, battery: 0.8)]
        let driver = LiveConsoleDriver(library: GameLibrary(file: temporary.appendingPathComponent("library.json")),
                                       controls: ControlLayout(defaults: UserDefaults(suiteName: "ConsoleLiveTests-" + UUID().uuidString)!),
                                       repo: { "" }, lang: { .en }, labels: { $0 }, pads: { list }, artwork: { _, _ in nil }, observeSystem: false)
        XCTAssertEqual(driver.state.controllers.map(\.id), ["ds4", "xbox"], "both appear together")
        XCTAssertEqual(driver.state.controllers.map(\.player), [1, 2])
        XCTAssertEqual(driver.state.controllers.map(\.batteryPercent), [nil, 80], "nothing usable for the first one yet")
        list[0].battery = 0.65   // the DualShock's battery arrives on the 2 second read
        driver.refreshControllers(announce: false)
        XCTAssertEqual(driver.state.controllers.map(\.batteryPercent), [65, 80])
        // the DualShock goes away and comes back as a new instance, the Xbox stays
        let xbox = list[1]
        list = [xbox]
        driver.controllerListChanged(connectedName: nil, disconnectedName: "DUALSHOCK 4 Wireless Controller")
        XCTAssertEqual(driver.state.controllers.map(\.id), ["xbox"])
        XCTAssertEqual(driver.state.controllers.first?.batteryPercent, 80, "the other controller is untouched")
        list = [ConsolePadSnapshot(id: "ds4-again", name: "DUALSHOCK 4 Wireless Controller", category: "DualShock 4", playerIndex: nil, battery: nil), xbox]
        driver.controllerListChanged(connectedName: "DUALSHOCK 4 Wireless Controller", disconnectedName: nil)
        XCTAssertEqual(Set(driver.state.controllers.map(\.id)), ["ds4-again", "xbox"], "both listed again")
        XCTAssertEqual(driver.state.controllers.first { $0.id == "ds4-again" }?.player, 1, "its old player is back")
        XCTAssertNil(driver.state.controllers.first { $0.id == "ds4-again" }?.battery, "nothing carried over from the old instance")
        XCTAssertEqual(driver.state.controllers.first { $0.id == "xbox" }?.batteryPercent, 80)
        list[0].battery = 0.64
        driver.refreshControllers(announce: false)
        XCTAssertEqual(driver.state.controllers.first { $0.id == "ds4-again" }?.batteryPercent, 64)
    }

    /// Controller entries come from GameController instances only: no IOKit or HID source can add a phantom entry (a second HID
    /// interface of one pad once showed up as "GamePad-1"), and with no controllers the list stays empty.
    func testOnlyGameControllerInstancesProduceControllerEntries() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/NSPortBuilder")
        for name in ["LiveConsoleDriver.swift", "Gamepad.swift", "ConsoleState.swift", "ConsoleControllersView.swift"] {
            let text = try String(contentsOf: sources.appendingPathComponent(name), encoding: .utf8)
            for forbidden in ["IOKit", "IOHID", "IOService"] { XCTAssertFalse(text.contains(forbidden), "\(name) uses \(forbidden)") }
        }
        let driver = liveDriver { [] }
        driver.refreshControllers(announce: false)
        XCTAssertTrue(driver.state.controllers.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sources.appendingPathComponent("HIDControllerWatcher.swift").path))
    }

    func testNothingIsShownWithoutAUsableBatteryReading() {
        // unknown or 0 with an unknown state, and no battery object: no level, no percentage
        for reading in [ConsolePadSnapshot.batteryReading(level: 0, state: .unknown), ConsolePadSnapshot.batteryReading(level: 0.4, state: .unknown)] {
            XCTAssertNil(reading.level)
            XCTAssertFalse(reading.charging)
        }
        let none = ConsolePadSnapshot(id: "a", name: "Pad", category: nil, playerIndex: 1, battery: nil).controller
        XCTAssertNil(none.batteryPercent, "ConsoleBattery draws nothing for this")
        XCTAssertFalse(none.charging)
        let known = ConsolePadSnapshot(id: "b", name: "Pad", category: nil, playerIndex: 1, battery: 0.65).controller
        XCTAssertEqual(known.batteryPercent, 65)
    }

    /// A fake battery object whose key-value observable properties change: the list follows without waiting for a read.
    @objc final class FakeBattery: NSObject {
        @objc dynamic var batteryLevel: Float = 0
        @objc dynamic var batteryState: Int = 0
    }

    func testBatteryChangesArriveThroughKeyValueObserving() async throws {
        let fake = FakeBattery()
        let driver = liveDriver { [ConsolePadSnapshot(id: "ds4", name: "DUALSHOCK 4 Wireless Controller", category: "DualShock 4", playerIndex: nil,
                                                      battery: fake.batteryState == 1 ? Double(fake.batteryLevel) : nil)] }
        driver.watchBattery(id: "ds4", object: fake)
        XCTAssertNil(driver.state.controllers.first?.battery)
        fake.batteryState = 1; fake.batteryLevel = 0.64
        for _ in 0..<50 where driver.state.controllers.first?.batteryPercent != 64 { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(driver.state.controllers.first?.batteryPercent, 64, "published from the KVO change, not a timer")
        fake.batteryLevel = 0.62
        for _ in 0..<50 where driver.state.controllers.first?.batteryPercent != 62 { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(driver.state.controllers.first?.batteryPercent, 62)
    }

    /// The pad reports no battery until the host sends it an output (the DS4 Bluetooth protocol): the driver sends the player once per
    /// assignment right after connecting, and the battery is known on the next read.
    func testPlayerOutputOnConnectMakesTheBatteryAppear() async throws {
        var wroteOutput = false
        var sent: [(String, Int)] = []
        let driver = LiveConsoleDriver(library: GameLibrary(file: temporary.appendingPathComponent("library.json")),
                                       controls: ControlLayout(defaults: UserDefaults(suiteName: "ConsoleLiveTests-" + UUID().uuidString)!),
                                       repo: { "" }, lang: { .en }, labels: { $0 },
                                       pads: { [ConsolePadSnapshot(id: "g7", name: "DUALSHOCK 4 Wireless Controller", category: "DualShock 4", playerIndex: nil, battery: wroteOutput ? 0.72 : nil)] },
                                       artwork: { _, _ in nil }, observeSystem: false,
                                       playerOutput: { id, player in sent.append((id, player)); wroteOutput = true })   // the fake pad only reports a battery after an output
        XCTAssertEqual(sent.map(\.1), [1], "the player is written once, right on connect")
        XCTAssertNil(driver.state.controllers.first?.battery, "unknown until the output has been sent")
        for _ in 0..<80 where driver.state.controllers.first?.batteryPercent != 72 { try await Task.sleep(nanoseconds: 25_000_000) }
        XCTAssertEqual(driver.state.controllers.first?.batteryPercent, 72, "known on the read after the output")
        driver.refreshControllers(announce: false)
        XCTAssertEqual(sent.count, 1, "not sent again for the same assignment")
        XCTAssertEqual(LiveConsoleDriver.playerLightColor(1).blue, 1.0)
        XCTAssertNotEqual(LiveConsoleDriver.playerLightColor(2).red, LiveConsoleDriver.playerLightColor(3).red)
    }

    /// GameController posts the connect notification two or three times for one connect, and the disconnect twice: one entry, one
    /// toast, one set of light writes, one reassignment.
    func testRepeatedConnectAndDisconnectNotificationsAreIdempotent() {
        var list: [ConsolePadSnapshot] = []
        var writes: [(String, Int)] = []
        let driver = LiveConsoleDriver(library: GameLibrary(file: temporary.appendingPathComponent("library.json")),
                                       controls: ControlLayout(defaults: UserDefaults(suiteName: "ConsoleLiveTests-" + UUID().uuidString)!),
                                       repo: { "" }, lang: { .en }, labels: { $0 }, pads: { list }, artwork: { _, _ in nil }, observeSystem: false,
                                       playerOutput: { writes.append(($0, $1)) })
        list = [ConsolePadSnapshot(id: "pad", name: "DUALSHOCK 4 Wireless Controller", category: "DualShock 4", playerIndex: nil)]
        XCTAssertTrue(driver.handleConnection(id: "pad", name: "DUALSHOCK 4 Wireless Controller", connected: true), "the first connect counts")
        let toast = driver.state.toast
        XCTAssertNotNil(toast)
        XCTAssertFalse(driver.handleConnection(id: "pad", name: "DUALSHOCK 4 Wireless Controller", connected: true))
        XCTAssertFalse(driver.handleConnection(id: "pad", name: "DUALSHOCK 4 Wireless Controller", connected: true))
        XCTAssertEqual(driver.state.toast, toast, "no second toast")
        XCTAssertEqual(driver.state.controllers.map(\.id), ["pad"], "one entry")
        XCTAssertEqual(driver.state.controllers.map(\.player), [1], "assigned once")
        XCTAssertEqual(writes.count, 1, "one light and player write")
        list = []
        XCTAssertTrue(driver.handleConnection(id: "pad", name: "DUALSHOCK 4 Wireless Controller", connected: false))
        let gone = driver.state.toast
        XCTAssertFalse(driver.handleConnection(id: "pad", name: "DUALSHOCK 4 Wireless Controller", connected: false))
        XCTAssertEqual(driver.state.toast, gone, "no second disconnect toast")
        XCTAssertTrue(driver.state.controllers.isEmpty)
    }
}
