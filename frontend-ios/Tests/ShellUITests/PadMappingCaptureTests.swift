#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import ShellUI

/// Visual QA of the button mapping (#494, #495), rendered on the Mac: the Controllers page with its two rows, the card for
/// all games and for one game, a button's options, a game's settings row and the button test. Set NX_SHELL_CAPTURE_DIR to
/// write the PNGs, NX_SHELL_CAPTURE_LANG (en, zh, de, ...) for the language.
@MainActor
final class PadMappingCaptureTests: XCTestCase {
    private var lang: String { ProcessInfo.processInfo.environment["NX_SHELL_CAPTURE_LANG"] ?? "en" }

    // The language is set before a test builds its rows, so every text of a capture is in it, whatever the Mac's language is.
    override func setUp() async throws {
        guard ProcessInfo.processInfo.environment["NX_SHELL_CAPTURE_DIR"] != nil else { throw XCTSkip("Set NX_SHELL_CAPTURE_DIR to capture the shell") }
        if let path = ShellStrings.bundle.path(forResource: lang == "zh" ? "zh-Hans" : lang, ofType: "lproj") {
            ShellStrings.captureBundle = Bundle(path: path)
        }
    }
    override func tearDown() async throws { ShellStrings.captureBundle = nil }

    private func capture<V: View>(_ name: String, width: CGFloat, height: CGFloat? = nil, _ view: V) throws {
        let dir = try XCTUnwrap(ProcessInfo.processInfo.environment["NX_SHELL_CAPTURE_DIR"])
        NSApplication.shared.setActivationPolicy(.accessory)
        let framed = view.frame(width: width).frame(height: height).background(ShellPalette.background).environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: framed)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -100_000, y: -100_000), size: host.frame.size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let file = URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(lang).png")
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: file)
    }

    /// All games swap A and B and turn X off.
    private var global: PadMap { PadMap(["A": "B", "B": "A", "X": "none"]) }

    /// A game's rows as the host gives them: this game keeps A and B where they are and puts ZR on ZL, the rest follows.
    private var gameRows: [SettingRow] {
        let own = ["A": "A", "B": "B", "ZR": "ZL"]
        let follow = SettingOption("follow", ShellStrings.text("Default"))
        let swap = SettingRow(id: "pad.swapAB", label: ShellStrings.text("Swap A and B"),
                              kind: .choice([follow, SettingOption("on", ShellStrings.text("On")), SettingOption("off", ShellStrings.text("Off"))]),
                              value: "off")
        return [swap] + PadMap.buttons.map { button in
            SettingRow(id: "pad.\(button)", label: PadMap.label(button), kind: .choice([follow] + PadMap.options),
                       value: own[button] ?? "follow", fromShell: own[button] == nil)
        }
    }

    private func card(_ title: String, rows: [SettingRow], inherited: PadMap?, open: String? = nil) -> some View {
        PadMappingCard(title: title, rows: rows, inherited: inherited, openRow: open, open: { _ in }, pick: { _, _ in },
                       backToList: {}, reset: {}, close: {})
            .padding(16)
            .background(Color.black.opacity(0.55))
    }

    func testCaptureConstrainedMenuContent() throws {
        let pads = [ControllerInfo(id: "1", name: "Xbox Wireless Controller", player: "Player 1", batteryPercent: 80)]
        for width: CGFloat in [320, 375, 560] {
            for large in [false, true] {
                let type: DynamicTypeSize = large ? .accessibility3 : .large
                let suffix = "\(Int(width))-\(large ? "large" : "default")"
                try capture("menu-controllers-\(suffix)", width: width, height: 560,
                            ControllersView(controllers: pads, padMap: global).environment(\.shellNativeBars, true).environment(\.dynamicTypeSize, type))
                try capture("menu-mapping-\(suffix)", width: width, height: 560,
                            card("All games", rows: PadMappingRows.global(global), inherited: nil).environment(\.shellNativeBars, true).environment(\.dynamicTypeSize, type))
                try capture("menu-button-test-\(suffix)", width: width, height: 400,
                            ButtonTestView(snapshot: PadSnapshot(name: "Xbox Wireless Controller"), close: {}).padding(16).environment(\.shellNativeBars, true).environment(\.dynamicTypeSize, type))
            }
        }
    }

    func testCaptureTheControllersPage() throws {
        let pads = [ControllerInfo(id: "1", name: "Xbox Wireless Controller", player: "Player 1", batteryPercent: 80)]
        try capture("pad-controllers", width: 402, height: 820, ControllersView(controllers: pads, padMap: global))
    }

    func testCaptureTheCardForAllGames() throws {
        try capture("pad-card-all", width: 512, card(ShellStrings.text("All games"), rows: PadMappingRows.global(global), inherited: nil))
        try capture("pad-card-all-default", width: 512, card(ShellStrings.text("All games"), rows: PadMappingRows.global(PadMap()), inherited: nil))
        try capture("pad-card-all-options", width: 512, card(ShellStrings.text("All games"), rows: PadMappingRows.global(global),
                                                             inherited: nil, open: "X"))
    }

    func testCaptureTheCardOfAGame() throws {
        try capture("pad-card-game", width: 512, card("Hades II", rows: gameRows, inherited: global))
        try capture("pad-card-game-options", width: 512, card("Hades II", rows: gameRows, inherited: global, open: "pad.Y"))
        // A phone: the card at the width an iPhone gives it.
        try capture("pad-card-game-phone", width: 393, card("Hades II", rows: gameRows, inherited: global))
    }

    func testCaptureAGamesSettingsRow() throws {
        let detail = GameDetail(game: GameTile(id: "0100535012974000", title: "Hades II"),
                                sections: [SettingSection(id: "pad", title: ShellStrings.text("Controller"), rows: gameRows)])
        try capture("pad-settings-row", width: 402, GameDetailView(detail: detail, showsPrimaryAction: false, showsHeader: false).padding(24))
    }

    /// The drawing alone and large, to look at the shoulders: the card's (Switch names, rings on changed buttons, nothing
    /// held, as the card never shows a controller's input) and the test's (Xbox names, the triggers pulled).
    func testCaptureTheDrawingUpClose() throws {
        let card = XboxControllerDiagram(snapshot: PadSnapshot(), switchNames: true, marked: [.rightBumper, .leftTrigger, .b])
        try capture("pad-drawing-card", width: 960, card.aspectRatio(320 / 220, contentMode: .fit).padding(24))
        // The triggers at 25, 50, 75 and 100 percent, LT and RT side by side in each, a face button held.
        for (name, left, right) in [("25-50", 0.25, 0.5), ("75-100", 0.75, 1.0)] {
            let test = XboxControllerDiagram(snapshot: PadSnapshot(pressed: [.rightBumper, .a], leftTrigger: left, rightTrigger: right))
            try capture("pad-drawing-test-\(name)", width: 960, test.aspectRatio(320 / 220, contentMode: .fit).padding(24))
        }
    }

    func testCaptureTheButtonTest() throws {
        let held = PadSnapshot(name: "Xbox Wireless Controller", pressed: [.a, .leftBumper, .up], leftStick: CGPoint(x: 0.6, y: 0.5),
                               rightTrigger: 0.7)
        try capture("pad-test", width: 700, ButtonTestView(snapshot: held, close: {}).padding(16).background(Color.black.opacity(0.7)))
    }
}
#endif
