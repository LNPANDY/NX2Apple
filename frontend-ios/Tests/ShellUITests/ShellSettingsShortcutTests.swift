import XCTest
@testable import ShellUI

/// #1129: the controller's Options button opens the shell's settings (the gear) over the library and over a game's settings, never over
/// another panel or dialog. The gear stays a toolbar target in the focus order for pads without Options.
final class ShellSettingsShortcutTests: XCTestCase {
    func testOptionsOpensTheGearOnlyOverTheLibraryOrAGamesSettings() {
        XCTAssertTrue(LibraryView.optionsOpensShellSettings(under: nil))
        XCTAssertTrue(LibraryView.optionsOpensShellSettings(under: .settings))
        for layer in FocusLayer.allCases where layer != .settings {
            XCTAssertFalse(LibraryView.optionsOpensShellSettings(under: layer), "\(layer)")
        }
    }

    func testTheOptionsGlyphFollowsTheController() {
        XCTAssertEqual(ButtonGlyph.optionsSymbol(.nintendo), "minus")
        XCTAssertEqual(ButtonGlyph.optionsSymbol(.xbox), "rectangle.on.rectangle")
        XCTAssertEqual(ButtonGlyph.optionsSymbol(.playStation), "square.and.arrow.up")
    }
}
