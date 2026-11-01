import Foundation
import Testing
import ShellUI
@testable import ShellHost

/// The shell-level data folder serves every game: found by the image's identity in any folder name, `<folder>/<title ID>/romfs.img` by name, the folder itself for one game.
@Suite struct ShellDataFolderTests {
    func manifest(title: String, size: Int, index: String = "ab") throws -> GameManifest {
        let url = Fixtures.gamesURL.appendingPathComponent(Fixtures.orbit).appendingPathComponent("game.manifest.json")
        let text = try String(contentsOf: url, encoding: .utf8)
            .replacingOccurrences(of: "\"DMROMFSID1 fixture\"", with: "\"DMROMFSID1 title=\(title) version=1.0 build=v0 size=\(size) index=\(index)\"")
            .replacingOccurrences(of: Fixtures.orbit, with: title)
        return try GameManifest.parse(Data(text.utf8))
    }

    func image(_ size: Int, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: size).write(to: url)
    }

    /// A DMROMFS1 image: header, 16 bytes of game data, then `index` (13 bytes here, so the hash pads to a multiple of 8).
    static func dmromfs(_ index: [UInt8], data: [UInt8] = [UInt8](repeating: 0x41, count: 16)) -> Data {
        func le(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8((v >> (8 * UInt64($0))) & 0xff) } }
        return Data(Array("DMROMFS1".utf8) + le(UInt64(32 + data.count)) + le(UInt64(index.count)) + le(0) + data + index)
    }
    static let indexA = Array(1...13).map(UInt8.init), indexB = Array(21...33).map(UInt8.init)

    func place(_ data: Data, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    func ident(_ index: [UInt8]) throws -> RomfsIdentity { try #require(RomfsIdentity.parse("DMROMFSID1 title=1 version=1 build=1 size=61 index=" + (index == Self.indexA ? "90b5abb4d1ea10d2" : "9da33c3b161c746a"))) }

    /// The folder `ShellDataIndex` finds for an identity.
    /// Compared by resolved path: the temporary folder is a symbolic link and the listing may spell it either way.
    func found(_ want: RomfsIdentity, in folder: URL) -> String? { ShellDataIndex(folder: folder).folder(matching: want)?.resolvingSymlinksInPath().path }
    func path(_ url: URL) -> String { url.resolvingSymlinksInPath().path }

    // The expected values are what `romfs_id_of_image` (dm/host/romfs_identity.h) returns for these two images.
    @Test func theIdentityIsTheOneTheCCodeComputes() throws {
        let box = try Sandbox()
        let a = box.root.appendingPathComponent("a.img"), b = box.root.appendingPathComponent("b.img")
        try place(Self.dmromfs(Self.indexA), at: a)
        try place(Self.dmromfs(Self.indexB), at: b)
        #expect(RomfsIdentity.ofImage(at: a) == RomfsIdentity(size: 61, index: 0x90b5abb4d1ea10d2))
        #expect(RomfsIdentity.ofImage(at: b) == RomfsIdentity(size: 61, index: 0x9da33c3b161c746a))
        #expect(RomfsIdentity.parse("DMROMFSID1 title=0100000000010000 version=1.0 build=v0 size=61 index=90b5abb4d1ea10d2") == RomfsIdentity(size: 61, index: 0x90b5abb4d1ea10d2))
        #expect(RomfsIdentity.parse("DMROMFSID1 fixture") == nil && RomfsIdentity.parse("DMROMFSID1 size=5") == nil && RomfsIdentity.parse("size=5 index=ab") == nil)
    }

    @Test func anInvalidOrCutOffImageHasNoIdentity() throws {
        let box = try Sandbox()
        let good = Self.dmromfs(Self.indexA)
        for (name, data) in [("short", good.prefix(40)), ("magic", Data("XXXXXXXX".utf8) + good.dropFirst(8)), ("empty", Data())] {
            try place(Data(data), at: box.root.appendingPathComponent("\(name).img"))
            #expect(RomfsIdentity.ofImage(at: box.root.appendingPathComponent("\(name).img")) == nil)
        }
        #expect(RomfsIdentity.ofImage(at: box.root.appendingPathComponent("missing.img")) == nil)
    }

    @Test func gamesInFoldersWithAnyNamesAreFoundByIdentity() throws {
        let box = try Sandbox()
        let shared = box.root.appendingPathComponent("Drive", isDirectory: true)
        try place(Self.dmromfs(Self.indexA), at: shared.appendingPathComponent("Hades II (1.0.0)/romfs.img"))
        try place(Self.dmromfs(Self.indexB), at: shared.appendingPathComponent("Switch games/whatever/ROMFS.IMG"))
        // Two images of the same size (61 bytes): only the index tells them apart.
        #expect(found(try ident(Self.indexA), in: shared) == path(shared.appendingPathComponent("Hades II (1.0.0)")))
        #expect(found(try ident(Self.indexB), in: shared) == path(shared.appendingPathComponent("Switch games/whatever")))
        let m = try manifest(title: Fixtures.orbit, size: 61, index: "90b5abb4d1ea10d2")
        let r = DataLocator.locate(manifest: m, picked: .none, appFolder: box.appData.appendingPathComponent(m.titleID), global: .url(shared),
                                   shellMatch: shared.appendingPathComponent("Hades II (1.0.0)"))
        #expect(r.source == .shell && r.url == shared.appendingPathComponent("Hades II (1.0.0)"))
    }

    @Test func aCutOffCopyOrAnotherImageIsNotAMatch() throws {
        let box = try Sandbox()
        let shared = box.root.appendingPathComponent("Drive", isDirectory: true)
        try place(Self.dmromfs(Self.indexA).prefix(50), at: shared.appendingPathComponent("Copy/romfs.img"))
        #expect(found(try ident(Self.indexA), in: shared) == nil)
        // The size fits but the index does not.
        try place(Self.dmromfs(Self.indexB), at: shared.appendingPathComponent("Other/romfs.img"))
        #expect(found(try ident(Self.indexA), in: shared) == nil)
    }

    @Test func theScanIsBounded() throws {
        let box = try Sandbox()
        let shared = box.root.appendingPathComponent("Drive", isDirectory: true)
        let image = Self.dmromfs(Self.indexA)
        try place(image, at: shared.appendingPathComponent("one/two/romfs.img"))
        #expect(found(try ident(Self.indexA), in: shared) == path(shared.appendingPathComponent("one/two")), "two levels down")
        try FileManager.default.removeItem(at: shared)
        try place(image, at: shared.appendingPathComponent("one/two/three/romfs.img"))
        #expect(found(try ident(Self.indexA), in: shared) == nil, "three levels down is not looked at")
        try FileManager.default.removeItem(at: shared)
        try place(image, at: shared.appendingPathComponent(".hidden/romfs.img"))
        try FileManager.default.createDirectory(at: box.root.appendingPathComponent("Real"), withIntermediateDirectories: true)
        try place(image, at: box.root.appendingPathComponent("Real/romfs.img"))
        try FileManager.default.createSymbolicLink(at: shared.appendingPathComponent("Link"), withDestinationURL: box.root.appendingPathComponent("Real"))
        try FileManager.default.createSymbolicLink(at: shared.appendingPathComponent("Loop"), withDestinationURL: shared)
        #expect(found(try ident(Self.indexA), in: shared) == nil, "hidden items and symbolic links are skipped")
        try FileManager.default.removeItem(at: shared)
        for i in 0..<(ShellDataIndex.maxEntries + 100) { try place(Data(), at: shared.appendingPathComponent("a/f\(i)")) }
        try place(image, at: shared.appendingPathComponent("z/romfs.img"))
        #expect(found(try ident(Self.indexA), in: shared) == nil, "a folder with more entries than the cap ends the scan")
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

extension ShellDataFolderTests {
    @Test func dlcSitsBesideTheMatchedImage() throws {
        let box = try Sandbox()
        let shared = box.root.appendingPathComponent("Drive", isDirectory: true)
        let folder = shared.appendingPathComponent("My game", isDirectory: true)
        try place(Self.dmromfs(Self.indexA), at: folder.appendingPathComponent("romfs.img"))
        try place(Data(count: 3), at: folder.appendingPathComponent("aoc/0.img"))
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("aoc/1"), withIntermediateDirectories: true)
        let m = try manifest(title: Fixtures.orbit, size: 61, index: "90b5abb4d1ea10d2")
        let match = try #require(ShellDataIndex(folder: shared).folder(matching: try ident(Self.indexA)))
        let r = DataLocator.locate(manifest: m, picked: .none, appFolder: box.appData.appendingPathComponent(m.titleID), global: .url(shared), shellMatch: match)
        let dir = try #require(r.url)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("aoc/0.img").path) && FileManager.default.fileExists(atPath: dir.appendingPathComponent("aoc/1").path))
    }

    @Test func aGameKeepsItsOwnPickAndTheMatchBeatsTheTitleFolder() throws {
        let box = try Sandbox()
        let shared = box.root.appendingPathComponent("Drive", isDirectory: true)
        let m = try manifest(title: Fixtures.orbit, size: 61, index: "90b5abb4d1ea10d2")
        let app = box.appData.appendingPathComponent(m.titleID)
        try place(Self.dmromfs(Self.indexA), at: shared.appendingPathComponent("Named/romfs.img"))
        try place(Self.dmromfs(Self.indexA), at: shared.appendingPathComponent(m.titleID).appendingPathComponent("romfs.img"))
        let named = shared.appendingPathComponent("Named")
        #expect(DataLocator.locate(manifest: m, picked: .none, appFolder: app, global: .url(shared), shellMatch: named).url == named)
        #expect(DataLocator.locate(manifest: m, picked: .none, appFolder: app, global: .url(shared)).url == shared.appendingPathComponent(m.titleID), "no match yet: by name")
        let own = box.root.appendingPathComponent("Own", isDirectory: true)
        try place(Self.dmromfs(Self.indexA), at: own.appendingPathComponent("romfs.img"))
        let r = DataLocator.locate(manifest: m, picked: .url(own), appFolder: app, global: .url(shared), shellMatch: named)
        #expect(r.source == .picked && r.url == own)
        // A match that was deleted since the scan is not game data.
        try FileManager.default.removeItem(at: named)
        #expect(DataLocator.locate(manifest: m, picked: .none, appFolder: app, global: .url(shared), shellMatch: named).url == shared.appendingPathComponent(m.titleID))
    }

    @Test func aManifestWithoutAnIdentityLineIsNotMatchedByIdentity() throws {
        #expect(RomfsIdentity.parse(try manifest(title: Fixtures.orbit, size: 5).romfsIdentity) != nil)
        let url = Fixtures.gamesURL.appendingPathComponent(Fixtures.orbit).appendingPathComponent("game.manifest.json")
        let m = try GameManifest.parse(Data(contentsOf: url))
        #expect(RomfsIdentity.parse(m.romfsIdentity) == nil, "the fixture's line is `DMROMFSID1 fixture`: only the by-name paths apply")
    }
}

final class MutablePicker: FolderPicker, @unchecked Sendable {
    var url: URL?
    init(_ url: URL?) { self.url = url }
    func pickFolder() async -> URL? { url }
}

@MainActor @Suite struct ShellDataFolderModelTests {
    private func model(_ box: Sandbox, picker: MutablePicker) -> ShellHostModel {
        ShellHostModel(config: box.config(), picker: picker,
                       shellSettings: ShellSettingsStore(defaults: UserDefaults(suiteName: "t-shell-\(UUID().uuidString)")!))
    }

    @Test func theScanFindsTheGameThenANewFolderDropsIt() async throws {
        let box = try Sandbox()
        let manifestURL = box.games.appendingPathComponent(Fixtures.orbit).appendingPathComponent("game.manifest.json")
        let text = try String(contentsOf: manifestURL, encoding: .utf8)
            .replacingOccurrences(of: "\"DMROMFSID1 fixture\"", with: "\"DMROMFSID1 title=\(Fixtures.orbit) version=1.0 build=v0 size=61 index=90b5abb4d1ea10d2\"")
        try text.write(to: manifestURL, atomically: true, encoding: .utf8)
        let drive = box.root.appendingPathComponent("Drive", isDirectory: true)
        try FileManager.default.createDirectory(at: drive.appendingPathComponent("Some name"), withIntermediateDirectories: true)
        try ShellDataFolderTests.dmromfs(ShellDataFolderTests.indexA).write(to: drive.appendingPathComponent("Some name/romfs.img"))
        let empty = box.root.appendingPathComponent("Empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)

        let picker = MutablePicker(drive)
        let m = model(box, picker: picker)
        await m.pickShellDataNow()
        await m.waitForShellScan()
        var orbit = try #require(m.details.first { $0.id == Fixtures.orbit })
        #expect(orbit.game.state == .playable && orbit.dataFromShell)
        #expect(orbit.dataSource.hasSuffix("(from Settings)"))

        // A new folder: the old matches are gone and the new folder is scanned.
        picker.url = empty
        await m.pickShellDataNow()
        await m.waitForShellScan()
        orbit = try #require(m.details.first { $0.id == Fixtures.orbit })
        #expect(orbit.game.state == .needsGameData)
    }
}
