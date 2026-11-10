import XCTest
import AppKit
import GameController
@testable import NX2Apple
@testable import NXCore

@MainActor final class SteamLinkGamepadTests: IsolatedDefaultsTestCase {
    private func send(_ state: SteamVirtualGamepad, id: String = "steam-test", source: SteamLinkGamepads) {
        NotificationCenter.default.post(name: .steamLinkPadInput, object: source,
                                        userInfo: ["input": SteamLinkGamepads.Input(id: id, state: state)])
    }

    private func drain() async { await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } } }

    private func button(_ usage: Int) -> SteamVirtualGamepad {
        var state = SteamVirtualGamepad()
        _ = state.update(page: 9, usage: usage, value: 1, min: 0, max: 1)
        return state
    }

    func testSteamButtonsUseExistingLauncherActionsOncePerPress() async {
        let source = SteamLinkGamepads(observeSystem: false)
        let pad = LauncherGamepad(steam: source, observeSystem: false, appIsActive: { true })
        var actions: [LauncherGamepad.Action] = []
        pad.perform = { actions.append($0) }
        defer { pad.deactivate() }
        let expected: [(Int, LauncherGamepad.Action)] = [(1, .a), (2, .b), (3, .x), (4, .y), (5, .l), (6, .r),
                                                       (9, .plus), (10, .select), (12, .up), (13, .down), (14, .left), (15, .right)]
        for (usage, action) in expected {
            send(button(usage), source: source)
            send(button(usage), source: source)
            await drain()
            XCTAssertEqual(actions.last, action)
            send(SteamVirtualGamepad(), source: source)
            await drain()
        }
        XCTAssertEqual(actions, expected.map(\.1))
    }

    func testCaptureUsesSameControllerIDAsInventory() async {
        let source = SteamLinkGamepads(observeSystem: false)
        let pad = LauncherGamepad(steam: source, observeSystem: false, appIsActive: { true })
        let snapshot = SteamLinkGamepads.snapshot(id: "steam-test", slot: 0)
        var captured: String?
        var actions = 0
        pad.perform = { _ in actions += 1 }
        pad.capture = { id, _ in captured = id; return true }
        defer { pad.deactivate() }
        send(button(1), source: source)
        await drain()
        XCTAssertEqual(captured, snapshot.id)
        XCTAssertEqual(actions, 0)
        XCTAssertNil(snapshot.battery)
        XCTAssertFalse(snapshot.canIdentify)
        XCTAssertEqual(snapshot.controller.kind, .xbox)
    }

    func testInactiveAndDisconnectedInputCannotFireLater() async {
        let source = SteamLinkGamepads(observeSystem: false)
        var active = false
        let pad = LauncherGamepad(steam: source, observeSystem: false, appIsActive: { active })
        var actions: [LauncherGamepad.Action] = []
        pad.perform = { actions.append($0) }
        defer { pad.deactivate() }
        send(button(15), source: source)
        active = true // Even activation before the queued callback must not replay background input.
        await drain()
        try? await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertTrue(actions.isEmpty)
        send(SteamVirtualGamepad(), source: source)
        send(button(1), source: source)
        NotificationCenter.default.post(name: .steamLinkPadsChanged, object: source, userInfo: ["removed": "steam-test"])
        await drain()
        XCTAssertTrue(actions.isEmpty, "a queued press must not outlive its device")
        send(button(1), source: source)
        await drain()
        XCTAssertEqual(actions, [.a], "reconnect starts with fresh edges")
    }

    func testRepeatsStopOnFocusLossAndDisconnect() async {
        let source = SteamLinkGamepads(observeSystem: false)
        let pad = LauncherGamepad(steam: source, observeSystem: false, appIsActive: { true })
        var actions = 0
        pad.perform = { _ in actions += 1 }
        defer { pad.deactivate() }
        send(button(15), source: source)
        await drain()
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
        try? await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(actions, 1)
        send(SteamVirtualGamepad(), source: source)
        await drain()
        send(button(15), source: source)
        await drain()
        NotificationCenter.default.post(name: .steamLinkPadsChanged, object: source, userInfo: ["removed": "steam-test"])
        try? await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(actions, 2)
    }

    func testDesktopConsoleDesktopRoutesToOneView() async {
        let source = SteamLinkGamepads(observeSystem: false)
        let desktop = LauncherGamepad(steam: source, observeSystem: false, appIsActive: { true })
        let console = LauncherGamepad(steam: source, observeSystem: false, appIsActive: { true })
        var desktopPresses = 0, consolePresses = 0
        desktop.perform = { _ in desktopPresses += 1 }
        send(button(1), source: source)
        await drain()
        send(SteamVirtualGamepad(), source: source)
        await drain()
        send(button(1), source: source)
        await drain()
        console.perform = { _ in consolePresses += 1 }
        desktop.deactivate() // A disappearing old view must not deactivate the new view.
        send(button(1), source: source)
        await drain()
        XCTAssertEqual(consolePresses, 0, "held Steam buttons must not refire on a view change")
        send(SteamVirtualGamepad(), source: source)
        await drain()
        send(button(1), source: source)
        await drain()
        send(SteamVirtualGamepad(), source: source)
        await drain()
        desktop.perform = { _ in desktopPresses += 1 }
        console.deactivate()
        send(button(1), source: source)
        await drain()
        desktop.deactivate()
        XCTAssertEqual(desktopPresses, 3)
        XCTAssertEqual(consolePresses, 1)
    }

    func testHIDOnlyGlyphsAndDiagnosticsExplainTheInputRoute() {
        XCTAssertEqual(ConsoleGlyphs.fallback(steamConnected: true).family, .xbox)
        XCTAssertEqual(ConsoleGlyphs.fallback(steamConnected: false).family, .keyboard)
        let source = SteamLinkGamepads(observeSystem: false)
        let inputs = Diagnostics.Inputs(appVersion: "test", macOS: "test", chip: "test", repoPath: "", python: "", dotnet: "",
                                        controllers: source.diagnostics)
        let report = Diagnostics.report(inputs)
        XCTAssertTrue(report.contains("#### Launcher controllers"))
        XCTAssertTrue(report.contains("Steam Link HID manager: not started"))
        XCTAssertTrue(report.contains("Steam Link HID active: 0"))
    }

    func testGameControllerCallbackFollowsCurrentViewWithoutReconnecting() async {
        let physical = GCController.withExtendedGamepad()
        let desktop = LauncherGamepad(steam: nil, observeSystem: false, appIsActive: { true })
        let console = LauncherGamepad(steam: nil, observeSystem: false, appIsActive: { true })
        var desktopPresses = 0, consolePresses = 0
        desktop.perform = { _ in desktopPresses += 1 }
        LauncherGamepad.attach(physical, id: "gc-test", isJoyCon: false)
        let profile = physical.physicalInputProfile
        let button = physical.extendedGamepad!.buttonA
        button.setValue(1)
        profile.valueDidChangeHandler?(profile, button)
        await drain()
        desktop.perform = { _ in desktopPresses += 1 }
        profile.valueDidChangeHandler?(profile, button)
        await drain()
        XCTAssertEqual(desktopPresses, 1, "updating a visible view's handler does not refire held buttons")
        console.perform = { _ in consolePresses += 1 }
        desktop.deactivate()
        // Release reaches the new view, not the desktop that saw the original press.
        button.setValue(0)
        profile.valueDidChangeHandler?(profile, button)
        await drain()
        button.setValue(1)
        profile.valueDidChangeHandler?(profile, button)
        await drain()
        button.setValue(0)
        profile.valueDidChangeHandler?(profile, button)
        await drain()
        desktop.perform = { _ in desktopPresses += 1 }
        console.deactivate()
        button.setValue(1)
        profile.valueDidChangeHandler?(profile, button)
        await drain()
        desktop.deactivate()
        physical.physicalInputProfile.valueDidChangeHandler = nil
        XCTAssertEqual(desktopPresses, 2)
        XCTAssertEqual(consolePresses, 1)
    }

    func testAcceptedSteamPadsJoinAndLeaveExistingConsoleInventory() {
        var steam = [SteamLinkGamepads.snapshot(id: "steam-test", slot: 0)]
        let library = GameLibrary(file: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
        let driver = LiveConsoleDriver(library: library, controls: ControlLayout(defaults: testDefaults), repo: { "" },
                                       lang: { .en }, labels: { L10n.string($0, .en) }, pads: { [] }, steamPads: { steam },
                                       observeSystem: false)
        XCTAssertEqual(driver.state.controllers.map(\.id), ["steam-test"])
        XCTAssertFalse(driver.state.controllers[0].canIdentify)
        steam = []
        driver.refreshControllers(announce: false)
        XCTAssertTrue(driver.state.controllers.isEmpty)
    }
}
