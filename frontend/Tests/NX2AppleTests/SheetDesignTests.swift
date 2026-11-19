import XCTest
import SwiftUI
import AppKit
@testable import NX2Apple
@testable import NXLauncher

/// The sheet layout (DSSheet, LNPANDY/NX2Apple#1458): the keys of its buttons and the colours of the destructive button.
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

    /// The white label on the destructive fill reads at 4.5:1 (WCAG AA), on tokens.json's values.
    func testTheDestructiveLabelHasEnoughContrast() throws {
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("design-tokens/tokens.json"))) as? [String: Any])
        let sheet = try XCTUnwrap((json["color"] as? [String: Any])?["sheet"] as? [String: Any])
        func value(_ key: String) throws -> String { try XCTUnwrap((sheet[key] as? [String: Any])?["$value"] as? String) }
        XCTAssertGreaterThanOrEqual(DesignRulesTests.contrast(try value("destructiveOn"), on: try value("destructive")), 4.5)
    }
}
