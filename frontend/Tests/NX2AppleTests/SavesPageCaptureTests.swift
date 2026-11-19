import AppKit
import SwiftUI
import XCTest
@testable import NX2Apple
@testable import NXCore
@testable import NXLauncher
@testable import NXModel

/// Visual QA of the Saves page (#1079), matched by --filter testRenderSavesPageForVisualQA: the top bar with its tabs, and the
/// page with example rows (one save beside its game, one in the usual place with cloud saves on, one never played whose save
/// was left in another place, #1041). NX_CAPTURE_LANG picks the language. No game files: the rows are given, not read.
final class SavesPageCaptureTests: IsolatedDefaultsTestCase {
    @MainActor func testRenderSavesPageForVisualQA() throws {
        guard let directory = ProcessInfo.processInfo.environment["NX_LAUNCHER_CAPTURE_DIR"] else { throw XCTSkip("Set NX_LAUNCHER_CAPTURE_DIR to capture native views") }
        let output = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let root = NSTemporaryDirectory() + "saves-page-capture-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: root) }
        NSApplication.shared.setActivationPolicy(.accessory)
        let lang = CaptureLanguage.current(.en)

        // The top bar, as every page shows it
        let stores = LauncherStores(defaults: testDefaults)
        stores.build.lang = lang
        MainActor.assumeIsolated { stores.dependencies.checked = true }
        MainActor.assumeIsolated { stores.dependencies.deps = [Dep(id: "test", name: "Xcode", hint: "", present: true, installCmd: [])] }
        let empty = GameLibrary(file: URL(fileURLWithPath: root + "/preview.json"))
        try shot("topbar", LauncherView(stores: stores, library: empty, initialPage: .library, performStartupChecks: false),
                 size: NSSize(width: 1440, height: 1024), lang: lang, output: output)

        // The page
        let home = NSHomeDirectory()
        let games = [LibraryGame(titleID: "0400486024DEC000", name: "The Legend of Zelda: Ocarina of Time", appPath: home + "/Games/Switch/Ocarina of Time.app"),
                     LibraryGame(titleID: "010074F013262000", name: "Xenoblade Chronicles 3", appPath: home + "/Games/Switch/Xenoblade Chronicles 3.app"),
                     LibraryGame(titleID: "01007EF00011E000", name: "The Legend of Zelda: Breath of the Wild", appPath: home + "/Games/Switch/Zelda/BotW.app")]
        let library = GameLibrary(file: URL(fileURLWithPath: root + "/page.json"))
        library.games = games
        let day: TimeInterval = 86_400, now = Date()
        func row(_ game: LibraryGame, _ folder: String, _ source: SaveLocations.Source, cloud: String?, newest: Date?, bytes: Int64, elsewhere: String? = nil) -> SaveOverviewRow {
            var row = SaveOverviewRow(id: game.id, titleID: game.titleID, name: game.name, folder: URL(fileURLWithPath: folder), source: source,
                                      volumeHoldsSaves: true, cloud: SaveLocations.EffectiveCloud(folder: cloud, source: cloud == nil ? .standard : .global),
                                      cloudFromEnv: false)
            row.newest = newest; row.bytes = bytes; row.files = newest == nil ? 0 : 3
            row.elsewhere = elsewhere.map { URL(fileURLWithPath: $0) }
            return row
        }
        let rows = [row(games[2], home + "/Library/Application Support/nxnative/01007EF00011E000/save", .standard, cloud: nil, newest: nil, bytes: 0,
                        elsewhere: home + "/Games/Switch/save/01007EF00011E000"),
                    row(games[0], home + "/Games/Switch/save/0400486024DEC000", .libraryFolder, cloud: nil, newest: now.addingTimeInterval(-2 * 3600), bytes: 1_250_000),
                    row(games[1], home + "/Games/Switch/save/010074F013262000", .libraryFolder, cloud: "icloud", newest: now.addingTimeInterval(-day), bytes: 4_800_000)]
        let page = SavesPage(library: library, saveSettings: SaveSettingsStore(defaults: testDefaults), players: PlayerProfileStore(defaults: testDefaults) { Localizer(lang).t("players.default") },
                             repo: "", preview: rows)
            .environmentObject(Localizer(lang)).environmentObject(PadFocus())
            .background(LauncherPalette.background)
        try shot("page", page, size: NSSize(width: 1100, height: 1000), lang: lang, output: output)

        // NX_SAVES_LIBRARY=<library.json>: the page read from a real library and its saves on this Mac (a copy of the file is read)
        if let real = ProcessInfo.processInfo.environment["NX_SAVES_LIBRARY"] {
            try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
            let copy = URL(fileURLWithPath: root + "/real.json")
            try FileManager.default.copyItem(at: URL(fileURLWithPath: real), to: copy)
            let realLibrary = GameLibrary(file: copy)
            let realPage = SavesPage(library: realLibrary, saveSettings: SaveSettingsStore(defaults: testDefaults),
                                     players: PlayerProfileStore(defaults: testDefaults) { Localizer(lang).t("players.default") }, repo: "")
                .environmentObject(Localizer(lang)).environmentObject(PadFocus())
                .background(LauncherPalette.background)
            try shot("real", realPage, size: NSSize(width: 1100, height: 1000), lang: lang, output: output)
        }
    }

    @MainActor private func shot<V: View>(_ name: String, _ view: V, size: NSSize, lang: Lang, output: URL) throws {
        let host = NSHostingView(rootView: view)
        let window = OffscreenWindow(size: size, styleMask: [.titled, .closable, .resizable])
        window.contentView = host
        window.orderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("saves-\(name)-\(lang.code).png"))
        window.orderOut(nil)
    }
}
