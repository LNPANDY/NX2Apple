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
}
