import AppKit
import SwiftUI
import XCTest
@testable import NX2Apple
@testable import NXCore
@testable import NXLauncher
@testable import NXModel

/// Where Supported games (#301) is reached from: a button in the collection's header (not a game's Manage menu), the Library page
/// of console mode's menu, Cmd+F in the sheet, and a controller in both.
@MainActor final class SupportedGamesReachabilityTests: IsolatedDefaultsTestCase {
    private func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }

    private func libraryFile() throws -> (URL, [LibraryGame]) {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }
        let games = [LibraryGame(titleID: "0100000000000001", name: "Example Game"), LibraryGame(titleID: "0100000000000002", name: "Another Game")]
        let file = temporary.appendingPathComponent("library.json")
        try JSONEncoder().encode(games).write(to: file)
        return (file, games)
    }

    /// The collection's header has the button before Sort, as high as Sort, at the narrowest and a wide window. A controller reaches it.
    func testCollectionHeaderShowsSupportedGamesBeforeSort() throws {
        let (file, games) = try libraryFile()
        for width in [CGFloat(900), 1440] {
            let stores = LauncherStores(defaults: testDefaults)
            let library = GameLibrary(file: file)
            library.selectedID = games[0].id
            let focus = PadFocus()
            let window = OffscreenWindow(size: NSSize(width: width, height: 760))
            window.contentView = NSHostingView(rootView: LauncherView(stores: stores, library: library, performStartupChecks: false, padFocus: focus))
            window.orderFront(nil)
            defer { window.orderOut(nil) }
            settle()
            let frames = try XCTUnwrap(focus.frames["main"])
            let button = try XCTUnwrap(frames.first { $0.id == "library.supported" }?.frame, "the header shows Supported games at \(width)")
            let sort = try XCTUnwrap(frames.first { $0.id == "library.sort" }?.frame)
            XCTAssertLessThan(button.maxX, sort.minX, "before Sort")
            XCTAssertEqual(button.height, sort.height, accuracy: 1, "as high as Sort")
            XCTAssertEqual(button.midY, sort.midY, accuracy: 1, "on Sort's line")
        }
    }

    /// The list is about the library, not about one game: no game's Manage menu has it any more.
    func testManageMenuHasNoSupportedGames() {
        let game = LibraryGame(titleID: "0100000000000001", name: "Example Game")
        let items = ManageItem.list(game: game, labels: { $0 }, running: false, olderTools: false, activeBuildID: nil, hasBuildFolder: false,
                                    deviceName: "", actions: ManageActions())
        XCTAssertFalse(items.contains { $0.id == "supported" })
    }

    private func sheetWindow(focus: PadFocus) -> (NSWindow, NSHostingView<AnyView>) {
        let games = [SupportedGame(titleID: "0100000000000001", name: "Example Game", edition: .switch1, version: "1.0.0", notes: "Plays to the end."),
                     SupportedGame(titleID: "0100000000000002", name: "Other Game", edition: .switch2, version: nil, notes: "")]
        let owned = LibraryGame(titleID: "0100000000000001", name: "Example Game")
        let sheet = SupportedGamesSheet(games: games, owned: { $0 == owned.titleID ? owned : nil }, covers: .saved(in: URL(fileURLWithPath: "/nonexistent"), maxPixel: SupportedGamesSheet.coverPixels), showInLibrary: { _ in })
            .environmentObject(Localizer(.en)).environmentObject(focus)
        let host = NSHostingView(rootView: AnyView(sheet))
        let window = OffscreenWindow(size: NSSize(width: 680, height: 600))
        window.contentView = host
        window.orderFront(nil)
        return (window, host)
    }

    /// Cmd+F in the sheet goes to the sheet's own search.
    func testCommandFFocusesTheSheetsSearch() throws {
        let (window, host) = sheetWindow(focus: PadFocus())
        defer { window.orderOut(nil) }
        settle()
        window.makeFirstResponder(nil)
        XCTAssertFalse(window.firstResponder is NSText, "nothing is being typed into")
        let find = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                                  windowNumber: window.windowNumber, context: nil, characters: "f",
                                                  charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3))
        XCTAssertTrue(window.performKeyEquivalent(with: find))
        settle()
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView, "the search field takes the typing")
        XCTAssertTrue(editor.isFieldEditor)
        _ = host
    }

    /// A controller reaches every row of the sheet and its close button.
    func testEveryRowOfTheSheetIsAPadTarget() throws {
        let focus = PadFocus()
        let (window, _) = sheetWindow(focus: focus)
        defer { window.orderOut(nil) }
        settle()
        let ids = Set(try XCTUnwrap(focus.frames["supported"]).map(\.id))
        XCTAssertTrue(ids.isSuperset(of: ["supported.row.0100000000000001", "supported.row.0100000000000002", "supported.close"]), "\(ids)")
    }

    /// Console mode: the menu's Library page has the row, it opens the page over the whole screen, the keyboard and the on-screen keys
    /// search it, and an owned game's notes lead to its page.
    func testConsoleLibraryPageOpensSupportedGames() throws {
        let driver = MockConsoleDriver(scenario: .full, animated: false)
        let pad = PadFocus()
        let host = NSHostingView(rootView: ConsoleView(driver: driver, padFocus: pad).frame(width: 1280, height: 800))
        let window = OffscreenWindow(size: NSSize(width: 1280, height: 800), styleMask: [.borderless])
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        settle()
        driver.openMenu(); driver.openLibrary(); settle()
        XCTAssertTrue(try XCTUnwrap(pad.frames["console.library"]).contains { $0.id == "console.library.supported" }, "the Library page has the row")
        pad.focused = "console.library.supported"
        pad.activate(); settle()
        XCTAssertEqual(driver.state.presentedSheet, .supportedGames)
        XCTAssertTrue(ConsoleSheet.supportedGames.isFullScreen)
        XCTAssertEqual(pad.focused, ConsoleSupportedGamesPage<MockConsoleDriver>.firstTarget, "the focus starts on the keyboard")
        let all = driver.state.supportedShown.count
        XCTAssertGreaterThan(all, 1)
        let first = try XCTUnwrap(driver.state.supportedGames.first)
        XCTAssertTrue(try XCTUnwrap(pad.frames["console.supported"]).contains { $0.id == "console.supported.row." + first.titleID }, "a controller reaches the rows")

        pad.focused = "console.supported.key.d"; pad.activate(); settle()   // the on-screen keyboard types
        XCTAssertEqual(driver.state.supportedText, "d")
        driver.deleteSupported()
        for c in first.name.prefix(4) { driver.typeSupported(String(c)) }
        XCTAssertTrue(driver.state.supportedShown.contains(first))
        XCTAssertLessThan(driver.state.supportedShown.count, all)
        driver.typeSupported("zzzz")
        XCTAssertTrue(driver.state.supportedShown.isEmpty)
        while !driver.state.supportedText.isEmpty { driver.deleteSupported() }
        XCTAssertEqual(driver.state.supportedShown.count, all, "an empty search lists them all")
        settle()

        let owned = try XCTUnwrap(driver.state.ownedGameID(first), "the demo owns the first profile")
        pad.focused = "console.supported.row." + first.titleID; pad.activate(); settle()   // A opens the notes
        XCTAssertTrue(try XCTUnwrap(pad.frames["console.supported"]).contains { $0.id == "console.supported.open." + first.titleID })
        pad.focused = "console.supported.open." + first.titleID; pad.activate(); settle()
        XCTAssertEqual(driver.state.presentedSheet, .gamePage(owned))
        driver.back(); settle()
        XCTAssertEqual(driver.state.presentedSheet, .supportedGames, "B goes back to the list")
    }

    /// The Mac's keyboard types into the page as into the search, and Y deletes a letter as there.
    func testConsoleKeyboardTypesIntoSupportedGames() {
        XCTAssertEqual(ConsoleKeyboardInput.KeyView.input(keyCode: 2, characters: "d", typing: true), .typed("d"))
        var state = ConsoleState(games: [])
        state.openSupportedGames([SupportedGame(titleID: "0100000000000001", name: "Example", edition: .unknown, version: nil, notes: "")], owned: [:])
        state.typeSupported("x"); state.typeSupported("a")
        XCTAssertEqual(state.supportedText, "xa")
        XCTAssertEqual(state.supportedShown.count, 1)
        state.deleteSupported()
        XCTAssertEqual(state.supportedText, "x")
        state.back()
        state.typeSupported("y")
        XCTAssertEqual(state.supportedText, "x", "nothing types once the page is closed")
    }
}
