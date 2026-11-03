import AppKit
import SwiftUI
import XCTest
@testable import NX2Apple
@testable import NXCore
@testable import NXLauncher
@testable import NXModel

/// #559: Delete game on the Mac. What goes (the Mac app, the IPA, the game data for the shared app, the game's place in the
/// shared app, the build folder, the log) and what stays (the files it was built from, other games, and the saves unless the
/// player chose them too).
final class GameDeletionTests: IsolatedDefaultsTestCase {
    private var root: URL!
    private let titleID = "0100535012974000", other = "0100000000010000"
    private var path: String { root.path }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("nxnative-delete-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func file(_ relative: String) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
    }
    private func exists(_ relative: String) -> Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent(relative).path) }

    /// A game built into a library folder (`out`, with the marker) for the Mac and for the shared app, with saves in both places
    /// the Mac app reads them from, a save backup, a Mac development build's save, logs and its place in the shared app.
    private func makeGame() throws -> LibraryGame {
        for f in ["src/Hades [\(titleID)].nsp", "out/.nx2apple-library", "out/Hades.app/Contents/Info.plist", "out/\(titleID).ipa",
                  "out/games/\(titleID)/romfs.img", "out/\(titleID)_build/extract/main", "out/\(titleID)_build/shader/lib",
                  "out/\(titleID)_build/run/save/0", "out/save/\(titleID)/0/file", "out/save/\(titleID)_device/0/file",
                  "out/save/\(titleID)-backups/2026-11-01 mac/file", "out/log/\(titleID).log", "home/Library/Logs/nxnative/\(titleID).prev.log",
                  "support/nxnative/\(titleID)/save/0/file", "support/nxnative/\(titleID)/cheats/x.txt",
                  "shell/frameworks/DmGame\(titleID).framework/DmGame", "shell/frameworks/DmGame\(other).framework/DmGame",
                  "shell/derived-data/Build/Products/Release-iphoneos/DmShell.app/Info.plist"] {
            try file(f)
        }
        var library = ShellLibrary(games: [.init(titleID: titleID, name: "Hades", framework: path + "/shell/frameworks/DmGame\(titleID).framework"),
                                           .init(titleID: other, name: "Other", framework: path + "/shell/frameworks/DmGame\(other).framework")])
        library.bundleID = "org.nxnative.shell"
        try library.save(root: path + "/shell")
        var game = LibraryGame(titleID: titleID, name: "Hades", appPath: path + "/out/Hades.app", ipaPath: path + "/out/\(titleID).ipa",
                               archivePath: path + "/out/games/\(titleID)")
        game.iosAppPath = path + "/shell/derived-data/Build/Products/Release-iphoneos/DmShell.app"
        game.outputDirectory = path + "/out"
        game.inputs = ["base": [path + "/src/Hades [\(titleID)].nsp"]]
        return game
    }

    private func plan(_ game: LibraryGame) -> GameDeletion {
        GameDeletion.plan(for: game, shellRoot: path + "/shell", home: path + "/home", support: root.appendingPathComponent("support"))
    }

    func testThePlanListsWhatGoesAndKeepsTheSavesApart() throws {
        let plan = plan(try makeGame())
        XCTAssertEqual(plan.items.map(\.kind), [.macApp, .ipa, .archive, .shellFramework, .buildFolder, .log],
                       "the shared app holds other games and is not listed")
        XCTAssertEqual(plan.items.first { $0.kind == .buildFolder }?.paths.map { ($0 as NSString).lastPathComponent }, ["extract", "shader"],
                       "run/ is the Mac development build's save")
        XCTAssertEqual(plan.items.first { $0.kind == .log }?.paths.count, 2)
        XCTAssertEqual(plan.saves?.paths.map { $0.replacingOccurrences(of: path + "/", with: "") }.sorted(),
                       ["out/\(titleID)_build/run", "out/save/\(titleID)", "out/save/\(titleID)-backups", "out/save/\(titleID)_device",
                        "support/nxnative/\(titleID)/save"])
        XCTAssertGreaterThan(plan.items.first { $0.kind == .macApp }?.bytes ?? 0, 0)
        XCTAssertEqual(plan.shellRoot, path + "/shell")
    }

    func testDeletingKeepsTheSavesTheSourcesAndTheOtherGames() throws {
        let game = try makeGame()
        let failed = plan(game).run(saves: false, trash: { try FileManager.default.removeItem(at: $0) })
        XCTAssertEqual(failed, [])
        for gone in ["out/Hades.app", "out/\(titleID).ipa", "out/games/\(titleID)", "out/\(titleID)_build/extract", "out/\(titleID)_build/shader",
                     "out/log/\(titleID).log", "home/Library/Logs/nxnative/\(titleID).prev.log", "shell/frameworks/DmGame\(titleID).framework"] {
            XCTAssertFalse(exists(gone), gone)
        }
        for kept in ["src/Hades [\(titleID)].nsp", "out/\(titleID)_build/run/save/0", "out/save/\(titleID)/0/file", "out/save/\(titleID)_device/0/file",
                     "out/save/\(titleID)-backups/2026-11-01 mac/file", "support/nxnative/\(titleID)/save/0/file", "support/nxnative/\(titleID)/cheats/x.txt",
                     "shell/frameworks/DmGame\(other).framework/DmGame", "shell/derived-data/Build/Products/Release-iphoneos/DmShell.app/Info.plist"] {
            XCTAssertTrue(exists(kept), kept)
        }
        XCTAssertEqual(ShellLibrary.load(root: path + "/shell").games.map(\.titleID), [other], "the next shared app leaves the game out")
        XCTAssertEqual(ShellLibrary.load(root: path + "/shell").bundleID, "org.nxnative.shell")
    }

    func testDeletingWithSavesRemovesThemAndTheBuildFolder() throws {
        let game = try makeGame()
        XCTAssertEqual(plan(game).run(saves: true, trash: { try FileManager.default.removeItem(at: $0) }), [])
        for gone in ["out/save/\(titleID)", "out/save/\(titleID)_device", "out/save/\(titleID)-backups", "support/nxnative/\(titleID)/save",
                     "out/\(titleID)_build"] {
            XCTAssertFalse(exists(gone), gone)
        }
        XCTAssertTrue(exists("src/Hades [\(titleID)].nsp"))
        XCTAssertTrue(exists("support/nxnative/\(titleID)/cheats/x.txt"), "only the saves of the support folder go")
    }

    func testWhatCannotBeMovedIsReported() throws {
        let game = try makeGame()
        let failed = plan(game).run(saves: false, trash: { url in if url.pathExtension == "ipa" { throw CocoaError(.fileWriteNoPermission) } })
        XCTAssertEqual(failed, [path + "/out/\(titleID).ipa"])
    }

    func testAGameWithNothingOnThisMacHasAnEmptyPlan() {
        let plan = plan(LibraryGame(titleID: titleID, name: "Hades"))
        XCTAssertEqual(plan.items, [])
        XCTAssertNil(plan.saves)
        XCTAssertNil(plan.shellRoot)
    }

    func testTheTextsHaveNoSemicolons() {
        let keys = ["delete.menu", "delete.busy", "delete.question", "delete.note", "delete.nothing", "delete.sources", "delete.saves",
                    "delete.savesOff", "delete.savesOn", "delete.noSaves", "delete.confirm", "delete.confirmSaves", "delete.failed",
                    "delete.part.shellFrameworkNote"]
        for lang in Lang.all { for key in keys { XCTAssertFalse(L10n.string(key, lang).contains(";") || L10n.string(key, lang).contains("\u{FF1B}"), key) } }
    }

    /// The Delete sheet for visual QA (`NX_LAUNCHER_CAPTURE_DIR`, `NX_CAPTURE_LANG`): a game with everything on this Mac and its
    /// saves kept, the same with the saves chosen too, and a game with nothing on this Mac. Example sizes, no files.
    @MainActor func testRenderDeleteSheetForVisualQA() throws {
        guard let directory = ProcessInfo.processInfo.environment["NX_LAUNCHER_CAPTURE_DIR"] else { throw XCTSkip("Set NX_LAUNCHER_CAPTURE_DIR to capture native views") }
        let output = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.accessory)
        let localizer = LauncherStores(defaults: testDefaults).localizer
        localizer.lang = CaptureLanguage.current(.en)
        let game = LibraryGame(titleID: titleID, name: "Hades")
        let out = "/Volumes/Games/Hades"
        let full = GameDeletion(titleID: titleID, items: [
            .init(kind: .macApp, paths: [out + "/Hades.app"], bytes: 14_600_000_000),
            .init(kind: .ipa, paths: [out + "/\(titleID).ipa"], bytes: 380_000_000),
            .init(kind: .archive, paths: [out + "/games/\(titleID)"], bytes: 11_200_000_000),
            .init(kind: .shellFramework, paths: [], bytes: 0),
            .init(kind: .buildFolder, paths: [out + "/\(titleID)_build/extract"], bytes: 18_900_000_000),
            .init(kind: .log, paths: [out + "/log/\(titleID).log"], bytes: 2_400_000)],
            saves: .init(kind: .saves, paths: [out + "/save/\(titleID)"], bytes: 1_200_000), shellRoot: "/Volumes/Games/NX2Apple-shell")
        let empty = GameDeletion(titleID: titleID, items: [], saves: nil, shellRoot: nil)
        for (name, plan, saves) in [("delete-sheet", full, false), ("delete-sheet-saves", full, true), ("delete-sheet-nothing", empty, false)] {
            let host = NSHostingView(rootView: DeleteGameSheet(game: game, shellRoot: "", plan: plan, saves: saves)
                .environmentObject(PadFocus()).environmentObject(localizer))
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            let window = OffscreenWindow(size: host.frame.size)
            window.contentView = host
            window.orderFront(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("\(name)-\(localizer.lang.code).png"))
            window.orderOut(nil)
        }
    }
}
