import AppKit
import SwiftUI
import XCTest
@testable import NX2Apple
@testable import NXCore
@testable import NXModel
import NXLauncher

/// The Builds page with a Switch 2 game folder chosen (LNPANDY/NX2Apple#512, #445). A synthetic folder and a stand-in engine: an
/// NPDM with only the program ID, empty RomFS folders, a profile with only its name. No game data.
final class GameFolderCaptureTests: IsolatedDefaultsTestCase {
    /// A stand-in engine tree (the marker file, pack_dump.py, Donkey Kong Bananza's profile) and the game's folder beside it.
    static func makeFolders(in root: String, profile: Bool = true, packer: Bool = true) -> (engine: String, game: String) {
        let fm = FileManager.default
        func write(_ path: String, _ data: Data = Data([1])) {
            try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            fm.createFile(atPath: path, contents: data)
        }
        let engine = root + "/engine", game = root + "/Donkey Kong Bananza"
        write(engine + "/" + EngineLayout.marker)
        if packer { write(engine + "/scripts/pack_dump.py"); write(engine + "/scripts/pack_nup.py") }
        // The same game as one NUP file in a folder of its own: its header and package table only (SPEC v1), base, update, DLC
        var nup = [UInt8](repeating: 0, count: 0x80 + 0x30 + 3 * 0x40)
        func put(_ o: Int, _ v: UInt64, _ n: Int) { for i in 0..<n { nup[o + i] = UInt8(v >> (8 * UInt64(i)) & 0xFF) } }
        nup.replaceSubrange(0..<4, with: [0x4E, 0x55, 0x50, 0x01]); put(0x08, 0x80, 8); put(0x40, UInt64(nup.count), 8); put(0x48, 3, 4)
        nup.replaceSubrange(0x80..<0x84, with: [0x54, 0x4F, 0x43, 0x01])
        put(0xB0, 0x040074A01BF12000, 8)
        put(0xF0, 0x040074A01BF12800, 8); put(0xF0 + 20, 458752, 4); nup[0xF0 + 24] = 1
        put(0x130, 0x040074A01BF13001, 8); nup[0x130 + 24] = 2
        write(root + "/NUP/Donkey Kong Bananza.nup", Data(nup))
        if profile {
            write(engine + "/dm/games/040074A01BF12000/game.tsv",
                  Data("# Donkey Kong Bananza (Switch 2, update v458752). In bring-up\ntitle_id\t040074A01BF12000\nname\tDonkey Kong Bananza\n".utf8))
        }
        write(game + "/base/exefs/main.npdm", npdm(programID: 0x040074A01BF12000))
        write(game + "/base/exefs/main")
        for dir in ["/base/romfs", "/updates/458752/exefs", "/updates/458752/romfs", "/dlc/040074a01bf13001/0/romfs"] {
            try? fm.createDirectory(atPath: game + dir, withIntermediateDirectories: true)
        }
        return (engine, game)
    }

    /// A minimal main.npdm, as GameFolderTests (NXCoreTests) makes it.
    static func npdm(programID: UInt64) -> Data {
        var d = [UInt8](repeating: 0, count: 0x100)
        d.replaceSubrange(0..<4, with: Array("META".utf8))
        let off = 0x80, size = 0x40
        for i in 0..<4 { d[0x70 + i] = UInt8(off >> (8 * i) & 0xFF); d[0x74 + i] = UInt8(size >> (8 * i) & 0xFF) }
        d.replaceSubrange(off..<off + 4, with: Array("ACI0".utf8))
        for i in 0..<8 { d[off + 0x10 + i] = UInt8(programID >> (8 * UInt64(i)) & 0xFF) }
        return Data(d)
    }

    /// The library folder scan finds a game folder as one game, keyed by its title ID, with the folder as its input (#512).
    func testTheLibraryScanFindsAGameFolder() {
        let root = NSTemporaryDirectory() + "gamefolder-library-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: root) }
        let folders = Self.makeFolders(in: root)
        let games = GameLibrary.sourceGames(in: URL(fileURLWithPath: root), repo: folders.engine)
        XCTAssertEqual(games.map(\.titleID), ["040074A01BF12000"])
        XCTAssertEqual(games.first?.name, "Donkey Kong Bananza", "the profile's name")
        let real = { (p: String) in URL(fileURLWithPath: p).resolvingSymlinksInPath().path }   // the enumerator hands out /private/var/…
        // the folder of files and the NUP beside it are the same game: one entry, from whichever the scan meets first
        let found = games.first?.inputs[GameLibrary.folderInput]?.map(real) ?? []
        XCTAssertTrue(found == [real(folders.game)] || found == [real(root + "/NUP")], "\(found)")
        let nupBytes = try? Data(contentsOf: URL(fileURLWithPath: root + "/NUP/Donkey Kong Bananza.nup"))
        try? FileManager.default.removeItem(atPath: root + "/NUP")
        let again = GameLibrary.sourceGames(in: URL(fileURLWithPath: root), repo: folders.engine)
        XCTAssertEqual(again.first?.inputs[GameLibrary.folderInput]?.map(real), [real(folders.game)])
        XCTAssertEqual(again.first.map { real($0.sourceFolder) }, real(folders.game))

        // Mixed-depth collection under the library root: GameA at Collection/GameA/base and GameB at Collection/Wrapper/GameB/base.
        // Both titles must be discovered, with their actual game folders stored (never the outer Collection or Wrapper folder).
        let collectionRoot = NSTemporaryDirectory() + "gamefolder-mixed-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: collectionRoot) }
        let fm = FileManager.default
        let gameA = collectionRoot + "/Collection/GameA"
        let gameB = collectionRoot + "/Collection/Wrapper/GameB"
        for (dir, tid) in [(gameA, UInt64(0x040074A01BF12000)), (gameB, UInt64(0x0400A3A01EE4C000))] {
            try? fm.createDirectory(atPath: dir + "/base/exefs", withIntermediateDirectories: true)
            try? fm.createDirectory(atPath: dir + "/base/romfs", withIntermediateDirectories: true)
            fm.createFile(atPath: dir + "/base/exefs/main.npdm", contents: Self.npdm(programID: tid))
        }
        for scanURL in [URL(fileURLWithPath: collectionRoot), URL(fileURLWithPath: collectionRoot + "/Collection")] {
            let discovered = GameLibrary.sourceGames(in: scanURL, repo: folders.engine)
            XCTAssertEqual(Set(discovered.map(\.titleID)), ["040074A01BF12000", "0400A3A01EE4C000"])
            let entryA = discovered.first { $0.titleID == "040074A01BF12000" }
            let entryB = discovered.first { $0.titleID == "0400A3A01EE4C000" }
            XCTAssertEqual(entryA.map { real($0.sourceFolder) }, real(gameA))
            XCTAssertEqual(entryA?.inputs[GameLibrary.folderInput]?.map(real), [real(gameA)])
            XCTAssertEqual(entryB.map { real($0.sourceFolder) }, real(gameB))
            XCTAssertEqual(entryB?.inputs[GameLibrary.folderInput]?.map(real), [real(gameB)])
        }

        // Root-NUP-plus-nested-dump collection: Collection/GameA.nup alongside Collection/DumpB/base/... (and under a parent root).
        let nupCollectionRoot = NSTemporaryDirectory() + "gamefolder-nup-collection-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: nupCollectionRoot) }
        let nupCollection = nupCollectionRoot + "/Collection"
        let nupA = nupCollection + "/GameA.nup"
        let dumpB = nupCollection + "/DumpB"
        try? fm.createDirectory(atPath: dumpB + "/base/exefs", withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: dumpB + "/base/romfs", withIntermediateDirectories: true)
        fm.createFile(atPath: nupA, contents: nupBytes)
        fm.createFile(atPath: dumpB + "/base/exefs/main.npdm", contents: Self.npdm(programID: 0x0400A3A01EE4C000))
        for scanURL in [URL(fileURLWithPath: nupCollection), URL(fileURLWithPath: nupCollectionRoot)] {
            XCTAssertEqual(GameFolder.resolve(scanURL.path), scanURL.path, "failed for \(scanURL.path)")
            XCTAssertFalse(GameFolder.isCandidate(scanURL.path), "failed for \(scanURL.path)")
            let discovered = GameLibrary.sourceGames(in: scanURL, repo: folders.engine)
            XCTAssertEqual(Set(discovered.map(\.titleID)), ["040074A01BF12000", "0400A3A01EE4C000"], "failed for \(scanURL.path)")
            let entryA = discovered.first { $0.titleID == "040074A01BF12000" }
            let entryB = discovered.first { $0.titleID == "0400A3A01EE4C000" }
            XCTAssertEqual(entryA.map { real($0.sourceFolder) }, real(nupCollection))
            XCTAssertEqual(entryA?.inputs[GameLibrary.folderInput]?.map(real), [real(nupA)])
            XCTAssertEqual(entryB.map { real($0.sourceFolder) }, real(dumpB))
            XCTAssertEqual(entryB?.inputs[GameLibrary.folderInput]?.map(real), [real(dumpB)])
        }
    }

    // MARK: Visual QA (matched by --filter testRenderLauncherForVisualQA)

    @MainActor func testRenderLauncherForVisualQAGameFolderLibrary() throws {
        guard let directory = ProcessInfo.processInfo.environment["NX_LAUNCHER_CAPTURE_DIR"] else { throw XCTSkip("Set NX_LAUNCHER_CAPTURE_DIR to capture native views") }
        let output = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let root = NSTemporaryDirectory() + "gamefolder-capture-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: root) }
        let folders = Self.makeFolders(in: root)
        NSApplication.shared.setActivationPolicy(.accessory)
        let stores = LauncherStores(defaults: testDefaults); let model = stores.build
        stores.repo.path = folders.engine
        model.lang = CaptureLanguage.current(.en)
        let library = GameLibrary(file: URL(fileURLWithPath: root + "/preview.json"))
        model.scan(folder: folders.game)
        _ = library.rememberInputs(model)
        library.selectedID = library.games.first?.id
        let host = NSHostingView(rootView: LauncherView(stores: stores, library: library, initialPage: .library, performStartupChecks: false))
        let window = OffscreenWindow(size: NSSize(width: 1440, height: 1024), styleMask: [.titled, .closable, .resizable])
        window.contentView = host
        window.orderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("library-game-folder.png"))
        window.orderOut(nil)
    }

    @MainActor func testRenderLauncherForVisualQAGameFolder() throws {
        guard let directory = ProcessInfo.processInfo.environment["NX_LAUNCHER_CAPTURE_DIR"] else { throw XCTSkip("Set NX_LAUNCHER_CAPTURE_DIR to capture native views") }
        let output = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let root = NSTemporaryDirectory() + "gamefolder-capture-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: root) }
        let folders = Self.makeFolders(in: root)
        NSApplication.shared.setActivationPolicy(.accessory)
        let stores = LauncherStores(defaults: testDefaults); let model = stores.build
        stores.repo.path = folders.engine
        model.lang = CaptureLanguage.current(.en)
        model.outDir = root
        MainActor.assumeIsolated { stores.dependencies.checked = true }
        MainActor.assumeIsolated { stores.dependencies.deps = [Dep(id: "test", name: "Xcode", hint: "", present: true, installCmd: [])] }
        let library = GameLibrary(file: URL(fileURLWithPath: root + "/preview.json"))
        var folderToScan = folders.game
        func capture(_ name: String, target: String) throws {
            model.target = target
            model.scan(folder: folderToScan)
            let host = NSHostingView(rootView: LauncherView(stores: stores, library: library, initialPage: .builds, performStartupChecks: false))
            let window = OffscreenWindow(size: NSSize(width: 1440, height: 1024), styleMask: [.titled, .closable, .resizable])
            window.contentView = host
            window.orderFront(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + ".png"))
            window.orderOut(nil)
        }
        try capture("build-game-folder-mac", target: BuildTarget.mac)
        try capture("build-game-folder-ios", target: BuildTarget.ios)
        folderToScan = root + "/NUP/Donkey Kong Bananza.nup"
        try capture("build-nup-mac", target: BuildTarget.mac)
        folderToScan = folders.game
        // The stages of a game folder's build: "-raw" shows the pack stages as the script writes them (how they looked before this
        // change), the other in the player's language
        model.target = BuildTarget.mac
        for (name, localized) in [("build-game-folder-stages-raw", false), ("build-game-folder-stages", true)] {
            let names = ["pack v458752", "pack DLC", "shader split", "Mac shaders", "Mac host", "Mac app"]
            model.stages = names.enumerated().map { i, n in
                Stage(id: i + 1, name: localized || !n.hasPrefix("pack ") ? Stage.localizedName(n, model.t) : n, state: i < 2 ? .done : (i == 2 ? .running : .pending))
            }
            let host = NSHostingView(rootView: ZStack(alignment: .top) {
                LauncherPalette.background
                ProgressCard(build: model).environmentObject(stores.localizer).padding(24)
            }.frame(width: 760, height: 470))
            let window = OffscreenWindow(size: NSSize(width: 760, height: 470))
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = host
            window.orderFront(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + ".png"))
            window.orderOut(nil)
        }
        model.stages = []
    }
}
