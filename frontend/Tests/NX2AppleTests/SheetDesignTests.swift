import XCTest
import SwiftUI
import AppKit
@testable import NX2Apple
@testable import NXLauncher

/// The sheet layout (DSSheet, LNPANDY/NX2Apple#1458): the keys of its buttons. The destructive fill's contrast is in DesignRulesTests (status.errorFill).
final class SheetDesignTests: XCTestCase {
    /// Apple HIG, "Alerts": Return never presses a destructive button. In its sheet Return and Escape are both Cancel.
    func testReturnNeverPressesADestructiveAction() {
        XCTAssertEqual(DSSheetKeys.returnKey(role: .destructive, confirmTakesReturn: false), .cancel)
        XCTAssertEqual(DSSheetKeys.returnKey(role: .destructive, confirmTakesReturn: true), .cancel, "a destructive action cannot ask for Return")
        XCTAssertEqual(DSSheetKeys.returnKey(role: .primary, confirmTakesReturn: false), .cancel)
        XCTAssertEqual(DSSheetKeys.returnKey(role: .primary, confirmTakesReturn: true), .confirm)
    }

    /// The Delete game sheet's button is destructive, so Return there is Cancel.
    func testTheDeleteSheetsKeysAreCancel() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/NX2Apple/DeleteGameSheet.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("role: .destructive"), "Delete game is the destructive button")
        XCTAssertFalse(source.contains(".keyboardShortcut(.defaultAction)"), "nothing in the Delete sheet takes Return but Cancel")
    }

    /// No sheet has an icon above its title, a confirmation neither (#1458): the header is the title and its message.
    func testNoSheetHasASubjectIcon() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?.allObjects as? [URL])
        for file in files where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(text.contains("DSSheetSubject") || text.contains("DSSheetIcon") || text.contains("sheetIcon"), file.lastPathComponent)
        }
    }

    /// Content higher than the sheet may be scrolls between the fixed header and button row: the content gets what is left.
    func testTallContentGetsWhatIsLeftBesideTheHeaderAndButtons() {
        typealias Sheet = DSSheet<EmptyView, EmptyView, EmptyView>
        XCTAssertNil(Sheet.contentFrame(content: 0, chrome: 200, maxHeight: 720), "not measured yet: its own height")
        XCTAssertEqual(Sheet.contentFrame(content: 300, chrome: 200, maxHeight: 720), 300, "fits: all of it")
        XCTAssertEqual(Sheet.contentFrame(content: 900, chrome: 200, maxHeight: 720), 520, "too high: the rest scrolls")
    }

    /// A rendered sheet with far more content than room stays within its maximum height, the button row included.
    @MainActor func testATallSheetStaysWithinItsMaximumHeight() throws {
        let sheet = DSSheet(title: "Delete Sample Game?", message: "These go to the Trash.") {
            ForEach(0..<40, id: \.self) { Text("Row \($0)").frame(height: 30) }
        } buttons: { Button("Cancel") {} }
            .environment(\.dsSheetMaxHeight, 400)
            .environmentObject(PadFocus())
        let host = NSHostingView(rootView: sheet)
        let window = OffscreenWindow(size: NSSize(width: 520, height: 900))
        defer { window.contentView = nil; window.orderOut(nil); window.close() }
        window.contentView = host
        window.orderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertLessThanOrEqual(host.fittingSize.height, 401, "the sheet grew past its maximum")
        XCTAssertGreaterThan(host.fittingSize.height, 300, "the sheet uses its room")
    }
}
