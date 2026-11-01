import SwiftUI
import XCTest
@testable import NX2Apple
@testable import NXCore
@testable import NXLauncher

final class LauncherDropdownTests: XCTestCase {
    private let window = CGSize(width: 1000, height: 700)

    func testListOpensBelowTheButton() {
        let button = CGRect(x: 100, y: 100, width: 150, height: 36)
        let spot = LauncherDropdownLayout.place(button: button, container: window, rows: 5, width: 200)
        XCTAssertEqual(spot.origin.y, button.maxY + LauncherDropdownLayout.gap)
        XCTAssertEqual(spot.origin.x, 100)
        XCTAssertEqual(spot.size.height, LauncherDropdownLayout.contentHeight(rows: 5))
    }

    func testListOpensAboveWhenThereIsNoRoomBelow() {
        let button = CGRect(x: 100, y: 600, width: 150, height: 36)
        let spot = LauncherDropdownLayout.place(button: button, container: window, rows: 5, width: 200)
        XCTAssertEqual(spot.origin.y + spot.size.height, button.minY - LauncherDropdownLayout.gap)
    }

    func testListScrollsWhenItFitsNeitherSide() {
        let short = CGSize(width: 1000, height: 300)
        let button = CGRect(x: 100, y: 130, width: 150, height: 36)
        let spot = LauncherDropdownLayout.place(button: button, container: short, rows: 14, width: 200)
        XCTAssertLessThan(spot.size.height, LauncherDropdownLayout.contentHeight(rows: 14))
        XCTAssertGreaterThanOrEqual(spot.origin.y, LauncherDropdownLayout.margin)
        XCTAssertLessThanOrEqual(spot.origin.y + spot.size.height, short.height - LauncherDropdownLayout.margin)
    }

    func testAButtonOnTheRightGetsItsListAlignedToItsRightEdge() {
        let button = CGRect(x: 800, y: 100, width: 150, height: 36)
        let spot = LauncherDropdownLayout.place(button: button, container: window, rows: 5, width: 200)
        XCTAssertEqual(spot.origin.x + spot.size.width, button.maxX)
    }

    func testListStaysInsideTheWindow() {
        let button = CGRect(x: 960, y: 100, width: 150, height: 36)
        let spot = LauncherDropdownLayout.place(button: button, container: window, rows: 5, width: 300)
        XCTAssertLessThanOrEqual(spot.origin.x + spot.size.width, window.width - LauncherDropdownLayout.margin)
    }

    func testWidthFollowsTheLongestLabelAndNeverGoesBelowTheButton() {
        let narrow = LauncherDropdownLayout.width(labels: ["A", "B"], button: 150)
        XCTAssertEqual(narrow, LauncherDropdownLayout.minWidth)
        XCTAssertEqual(LauncherDropdownLayout.width(labels: ["A"], button: 250), 250)
        let long = LauncherDropdownLayout.width(labels: ["An iPhone with a rather long name (not connected)"], button: 100)
        XCTAssertGreaterThan(long, LauncherDropdownLayout.minWidth)
        XCTAssertLessThanOrEqual(long, LauncherDropdownLayout.maxWidth)
    }

    func testEveryLanguageInThePickerHasAName() {
        XCTAssertEqual(BuilderView.languageCodes.first, "")
        for code in BuilderView.languageCodes.dropFirst() {
            XCTAssertNotNil(Lang(rawValue: code), code)
            for lang: Lang in [.zh, .en, .sv, .de, .it] { XCTAssertNotEqual(L10n.string("settings.language." + code, lang), "settings.language." + code) }
        }
    }

    func testArrowKeysWrapAndStartAtTheEnds() {
        XCTAssertEqual(LauncherDropdownLayout.step(from: nil, by: 1, count: 4), 0)
        XCTAssertEqual(LauncherDropdownLayout.step(from: nil, by: -1, count: 4), 3)
        XCTAssertEqual(LauncherDropdownLayout.step(from: 3, by: 1, count: 4), 0)
        XCTAssertEqual(LauncherDropdownLayout.step(from: 0, by: -1, count: 4), 3)
        XCTAssertEqual(LauncherDropdownLayout.step(from: 1, by: 1, count: 4), 2)
        XCTAssertNil(LauncherDropdownLayout.step(from: nil, by: 1, count: 0))
    }

    /// Opt-in native rendering for pull request screenshots (NX_LAUNCHER_CAPTURE_DIR): the Settings language row with its list open.
    @MainActor func testRenderDropdownForScreenshots() throws {
        guard let directory = ProcessInfo.processInfo.environment["NX_LAUNCHER_CAPTURE_DIR"] else { throw XCTSkip("Set NX_LAUNCHER_CAPTURE_DIR to capture native views") }
        let output = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        // The picker's own list (every language it offers), in German unless NX_CAPTURE_LANG names another.
        let lang = CaptureLanguage.current(.de)
        let options = BuilderView.languageCodes.map { (value: $0, label: L10n.string("settings.language." + ($0.isEmpty ? "system" : $0), lang)) }
        let width: CGFloat = 620, height: CGFloat = 170 + LauncherDropdownLayout.contentHeight(rows: options.count)
        let rows = VStack(alignment: .trailing, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.string("settings.language", lang)).font(.manrope(14))
                    Text(L10n.string("settings.language.system", lang)).font(.manrope(12.5)).foregroundStyle(.secondary)
                }
                Spacer()
                LauncherDropdown(options: options, selection: "", label: L10n.string("settings.language", lang), style: .button) { _ in }
                    .launcherRowControls()
            }
            .padding(.horizontal, 18).padding(.vertical, 13)
            .background(LauncherPalette.surface.opacity(0.75), in: RoundedRectangle(cornerRadius: 14))
            LauncherDropdownList(options: options, selection: lang.rawValue, label: L10n.string("settings.language", lang), choose: { _ in }, close: {})
                .frame(width: LauncherDropdownLayout.width(labels: options.map(\.label), button: 150), height: LauncherDropdownLayout.contentHeight(rows: options.count))
                .launcherDropdownSurface()
        }
        .padding(24)
        let host = NSHostingView(rootView: ZStack { LauncherPalette.background; rows }.preferredColorScheme(.dark).frame(width: width, height: height))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.appearance = NSAppearance(named: .darkAqua)
        window.orderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("dropdown-settings.png"))
        window.orderOut(nil)
    }
}
