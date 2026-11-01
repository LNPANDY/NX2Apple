import Foundation
import Testing
@testable import ShellHost

/// The shell-level data folder serves every game: `<folder>/<title ID>/romfs.img` per game, the folder itself for one game.
@Suite struct ShellDataFolderTests {
    func manifest(title: String, size: Int) throws -> GameManifest {
        let url = Fixtures.gamesURL.appendingPathComponent(Fixtures.orbit).appendingPathComponent("game.manifest.json")
        let text = try String(contentsOf: url, encoding: .utf8)
            .replacingOccurrences(of: "\"DMROMFSID1 fixture\"", with: "\"DMROMFSID1 title=\(title) version=1.0 build=v0 size=\(size) index=ab\"")
            .replacingOccurrences(of: Fixtures.orbit, with: title)
        return try GameManifest.parse(Data(text.utf8))
    }

    func image(_ size: Int, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: size).write(to: url)
    }

    @Test func oneFolderHoldsSeveralGames() throws {
        let box = try Sandbox()
        let shared = box.root.appendingPathComponent("Drive/All", isDirectory: true)
        let a = try manifest(title: Fixtures.orbit, size: 12), b = try manifest(title: Fixtures.chain, size: 20)
        try image(12, at: shared.appendingPathComponent(Fixtures.orbit).appendingPathComponent("romfs.img"))
        try image(20, at: shared.appendingPathComponent(Fixtures.chain).appendingPathComponent("romfs.img"))
        let ra = DataLocator.locate(manifest: a, picked: .none, appFolder: box.appData.appendingPathComponent(a.titleID), global: .url(shared))
        let rb = DataLocator.locate(manifest: b, picked: .none, appFolder: box.appData.appendingPathComponent(b.titleID), global: .url(shared))
        #expect(ra.source == .shell && ra.url == shared.appendingPathComponent(Fixtures.orbit))
        #expect(rb.source == .shell && rb.url == shared.appendingPathComponent(Fixtures.chain))
    }

    @Test func aCutOffImageInTheTitleFolderFallsBackToTheAppFolder() throws {
        let box = try Sandbox()
        let shared = box.root.appendingPathComponent("Drive/All", isDirectory: true)
        let m = try manifest(title: Fixtures.orbit, size: 12)
        try image(5, at: shared.appendingPathComponent(Fixtures.orbit).appendingPathComponent("romfs.img"))
        let app = box.appData.appendingPathComponent(Fixtures.orbit)
        #expect(!DataLocator.locate(manifest: m, picked: .none, appFolder: app, global: .url(shared)).found)
        try image(12, at: app.appendingPathComponent("romfs.img"))
        #expect(DataLocator.locate(manifest: m, picked: .none, appFolder: app, global: .url(shared)).source == .app)
    }

    @Test func theSingleGameLayoutAndTheGamesOwnFolderStillWork() throws {
        let box = try Sandbox()
        let shared = box.root.appendingPathComponent("Drive/One", isDirectory: true)
        let m = try manifest(title: Fixtures.orbit, size: 12)
        let app = box.appData.appendingPathComponent(Fixtures.orbit)
        try image(12, at: shared.appendingPathComponent("romfs.img"))
        let single = DataLocator.locate(manifest: m, picked: .none, appFolder: app, global: .url(shared))
        #expect(single.source == .shell && single.url == shared)
        // The title folder is tried before the folder itself, and the game's own pick before both.
        try image(12, at: shared.appendingPathComponent(Fixtures.orbit).appendingPathComponent("romfs.img"))
        #expect(DataLocator.locate(manifest: m, picked: .none, appFolder: app, global: .url(shared)).url == shared.appendingPathComponent(Fixtures.orbit))
        let own = box.root.appendingPathComponent("Drive/Own", isDirectory: true)
        try image(12, at: own.appendingPathComponent("romfs.img"))
        let r = DataLocator.locate(manifest: m, picked: .url(own), appFolder: app, global: .url(shared))
        #expect(r.source == .picked && r.url == own)
    }

    @Test func dlcSitsBesideTheTitleFolderImage() throws {
        let box = try Sandbox()
        let shared = box.root.appendingPathComponent("Drive/All", isDirectory: true)
        let m = try manifest(title: Fixtures.orbit, size: 12)
        let folder = shared.appendingPathComponent(Fixtures.orbit, isDirectory: true)
        try image(12, at: folder.appendingPathComponent("romfs.img"))
        try image(3, at: folder.appendingPathComponent("aoc/0.img"))
        let r = DataLocator.locate(manifest: m, picked: .none, appFolder: box.appData.appendingPathComponent(m.titleID), global: .url(shared))
        // The launch plan takes `aoc/` from the folder the locator returns.
        #expect(FileManager.default.fileExists(atPath: try #require(r.url).appendingPathComponent("aoc/0.img").path))
    }
}
