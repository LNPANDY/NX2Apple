import XCTest
import SwiftUI
@testable import NX2Apple
@testable import NXCore
import NXModel
@testable import NXLauncher

/// Manage > Rename (LNPANDY/NX2Apple#895): the player's name for a game, shown in every language in place of the game's own names,
/// kept in library.json, found by the search, and empty to go back. The bundle name stays for the artwork lookup and the saves.
@MainActor final class RenameGameTests: IsolatedDefaultsTestCase {
    private var temporary: URL!

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("nxnative-rename-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: temporary) }

    private func library() throws -> (GameLibrary, UUID) {
        let library = GameLibrary(file: temporary.appendingPathComponent("library.json"))
        let app = temporary.appendingPathComponent("01008D7016438000.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        for exe in ["nxnative", "dmhost"] {
            try FileManager.default.createSymbolicLink(at: app.appendingPathComponent("Contents/MacOS/" + exe), withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
        }
        let info: [String: Any] = ["DMTitleID": "01008D7016438000", "CFBundleDisplayName": "13기병방위권", "CFBundleExecutable": "nxnative",
                                   "CFBundleIdentifier": TestPreferences.domain(in: temporary, "rename")]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        let id = try library.addApp(app)
        library.setTitleNames(["ko": "13기병방위권", "zh-Hans": "十三机兵防卫圈", "zh-Hant": "十三機兵防衛圈"], for: id)   // as TitleNameLookup reads them
        return (library, id)
    }

    func testTheNameShowsInEveryLanguageAndEmptyGoesBack() throws {
        let (library, id) = try library()
        library.rename(id, to: "  十三機兵防衛圏 ")
        let game = try XCTUnwrap(library.games.first { $0.id == id })
        XCTAssertEqual(game.customName, "十三機兵防衛圏")
        for lang in [Lang.zh, .en, Lang("ja"), Lang("sv")] { XCTAssertEqual(game.displayName(lang), "十三機兵防衛圏", lang.code) }
        XCTAssertEqual(game.ownName(.zh), "十三机兵防卫圈")   // what the sheet offers to go back to
        XCTAssertEqual(LibraryFilter.owned.visibleGames(library.games, matching: "防衛圏", lang: .zh).map(\.id), [id])
        XCTAssertEqual(GameLibrary(file: temporary.appendingPathComponent("library.json")).games.first?.customName, "十三機兵防衛圏")   // kept

        library.rename(id, to: " ")
        let back = try XCTUnwrap(library.games.first { $0.id == id })
        XCTAssertEqual(back.customName, "")
        XCTAssertEqual(back.displayName(.zh), "十三机兵防卫圈")
        XCTAssertEqual(back.displayName(Lang("ja")), "13기병방위권")   // no Japanese or English title: the bundle name
    }

    /// Opt-in: `NX_LAUNCHER_CAPTURE_DIR=<dir> swift test --filter RenameGameTests` writes the sheet, empty and with a name, and the library after it.
    func testRenderRenameSheet() throws {
        guard let directory = ProcessInfo.processInfo.environment["NX_LAUNCHER_CAPTURE_DIR"] else { throw XCTSkip("Set NX_LAUNCHER_CAPTURE_DIR to capture native views") }
        let output = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.accessory)
        let stores = LauncherStores(defaults: testDefaults)
        let lang = CaptureLanguage.current(Lang("ja"))
        stores.localizer.lang = lang
        let (library, id) = try library()
        func shot<V: View>(_ name: String, _ view: V, size: NSSize) throws {
            let host = NSHostingView(rootView: view)
            let window = OffscreenWindow(size: size, styleMask: [.titled])
            window.contentView = host
            window.orderFront(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("rename-\(lang.code)-\(name).png"))
            window.orderOut(nil)
        }
        let game = try XCTUnwrap(library.games.first { $0.id == id })
        try shot("sheet-empty", RenameGameSheet(game: game).environmentObject(stores.localizer).environmentObject(PadFocus()), size: NSSize(width: 520, height: 300))
        library.rename(id, to: "十三機兵防衛圏")
        let renamed = try XCTUnwrap(library.games.first { $0.id == id })
        try shot("sheet-named", RenameGameSheet(game: renamed).environmentObject(stores.localizer).environmentObject(PadFocus()), size: NSSize(width: 520, height: 300))
        try shot("manage-menu", LauncherView(stores: stores, library: library, initialPage: .library, performStartupChecks: false, manageOpen: true),
                 size: NSSize(width: 1440, height: 1024))
    }
}
