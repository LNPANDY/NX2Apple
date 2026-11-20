import XCTest
import AppKit
import GameController
@testable import NX2Apple
@testable import NXCore

@MainActor final class HIDGamepadTests: IsolatedDefaultsTestCase {
    private func send(_ state: HIDPadState, id: String = "hid-test", source: HIDGamepads) {
        NotificationCenter.default.post(name: .hidPadInput, object: source,
                                        userInfo: ["input": HIDGamepads.Input(id: id, state: state)])
    }

    private func drain() async { await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } } }

    private func pressed(_ usage: Int) -> HIDPadState {
        var state = HIDPadState()
        _ = state.update(page: 9, usage: usage, value: 1, min: 0, max: 1)
        return state
    }

    func testHIDButtonsUseExistingLauncherActionsOncePerPress() async {
        let source = HIDGamepads(observeSystem: false)
        let pad = LauncherGamepad(hid: source, observeSystem: false, appIsActive: { true })
        var actions: [LauncherGamepad.Action] = []
        pad.perform = { actions.append($0) }
        defer { pad.deactivate() }
        let expected: [(Int, LauncherGamepad.Action)] = [(1, .a), (2, .b), (4, .x), (5, .y), (7, .l), (8, .r),
                                                        (12, .plus), (11, .select)]
        for (usage, action) in expected {
            send(pressed(usage), source: source)
            send(pressed(usage), source: source)
            await drain()
            XCTAssertEqual(actions.last, action)
            send(HIDPadState(), source: source)
            await drain()
        }
        XCTAssertEqual(actions, expected.map(\.1))
    }

    func testHatAndLeftStickMoveTheMenus() async {
        let source = HIDGamepads(observeSystem: false)
        let pad = LauncherGamepad(hid: source, observeSystem: false, appIsActive: { true })
        var actions: [LauncherGamepad.Action] = []
        pad.perform = { actions.append($0) }
        defer { pad.deactivate() }
        var right = HIDPadState()
        _ = right.update(page: 1, usage: 0x39, value: 2, min: 0, max: 7)
        send(right, source: source)
        await drain()
        XCTAssertEqual(actions.last, .right)
        var up = HIDPadState()
        _ = up.update(page: 1, usage: 0x30, value: 128, min: 0, max: 255)
        _ = up.update(page: 1, usage: 0x31, value: 0, min: 0, max: 255)
        send(HIDPadState(), source: source)   // the hat is back to neutral first
        await drain()
        send(up, source: source)
        await drain()
        XCTAssertEqual(actions.last, .up, "a pushed-up left stick reads up: HID y is inverted")
        var down = HIDPadState()
        _ = down.update(page: 1, usage: 0x31, value: 255, min: 0, max: 255)
        send(down, source: source)
        await drain()
        XCTAssertEqual(actions.last, .down)
        XCTAssertEqual(actions.filter { $0 == .up }.count, 1)
    }

    func testCaptureUsesSameControllerIDAsInventory() async {
        let source = HIDGamepads(observeSystem: false)
        let pad = LauncherGamepad(hid: source, observeSystem: false, appIsActive: { true })
        var captured: String?
        var actions = 0
        pad.perform = { _ in actions += 1 }
        pad.capture = { id, _ in captured = id; return true }
        defer { pad.deactivate() }
        send(pressed(1), source: source)
        await drain()
        XCTAssertEqual(captured, "hid-test")
        XCTAssertEqual(actions, 0)
    }

    func testHIDSnapshotJoinsAndLeavesTheConsoleInventory() {
        var hid = [ConsolePadSnapshot(id: "hid-test", name: "8BitDo Ultimate 2C Wireless", category: "Xbox", playerIndex: nil,
                                      battery: nil, canIdentify: false)]
        let library = GameLibrary(file: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
        let driver = LiveConsoleDriver(library: library, controls: ControlLayout(defaults: testDefaults), repo: { "" },
                                       lang: { .en }, labels: { L10n.string($0, .en) }, pads: { [] },
                                       steamPads: { [] }, hidPads: { hid }, observeSystem: false)
        XCTAssertEqual(driver.state.controllers.map(\.id), ["hid-test"])
        XCTAssertEqual(driver.state.controllers[0].name, "8BitDo Ultimate 2C Wireless")
        XCTAssertFalse(driver.state.controllers[0].canIdentify)
        hid = []
        driver.refreshControllers(announce: false)
        XCTAssertTrue(driver.state.controllers.isEmpty)
    }

    func testRemovedHIDPadClearsHeldButtons() async {
        let source = HIDGamepads(observeSystem: false)
        var active = false
        let pad = LauncherGamepad(hid: source, observeSystem: false, appIsActive: { active })
        var actions: [LauncherGamepad.Action] = []
        pad.perform = { actions.append($0) }
        defer { pad.deactivate() }
        send(pressed(15), source: source)
        active = true   // Even activation before the queued callback must not replay background input.
        await drain()
        try? await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertTrue(actions.isEmpty)
        NotificationCenter.default.post(name: .hidPadsChanged, object: source, userInfo: ["removed": "hid-test"])
        try? await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertTrue(actions.isEmpty, "a queued press must not outlive its device")
        send(pressed(1), source: source)
        await drain()
        XCTAssertEqual(actions, [.a], "reconnect starts with fresh edges")
    }

    func testGlyphsFallBackToXboxWhenOnlyAnHIDPadIsConnected() {
        let hidGlyphs = ConsoleGlyphs.fallback(steamConnected: true)
        XCTAssertEqual(hidGlyphs.family, .xbox)
        let inputs = Diagnostics.Inputs(appVersion: "test", macOS: "test", chip: "test", repoPath: "", python: "", dotnet: "",
                                        controllers: ["HID fallback manager: not started", "HID fallback active: 0"])
        let report = Diagnostics.report(inputs)
        XCTAssertTrue(report.contains("HID fallback active: 0"))
    }
}
