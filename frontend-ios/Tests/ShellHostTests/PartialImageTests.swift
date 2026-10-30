import Foundation
import Testing
@testable import ShellHost

/// A romfs.img cut off partway (the Mac launcher's copy stopped when the device locked or was unplugged) is not game data: the
/// game keeps asking for its data, and the engine is never pointed at the short file. The manifest's identity names the size.
@Suite struct PartialImageTests {
    func manifest(identity: String) throws -> GameManifest {
        let url = Fixtures.gamesURL.appendingPathComponent(Fixtures.orbit).appendingPathComponent("game.manifest.json")
        let text = try String(contentsOf: url, encoding: .utf8)
            .replacingOccurrences(of: "\"DMROMFSID1 fixture\"", with: "\"\(identity)\"")
        return try GameManifest.parse(Data(text.utf8))
    }

    @Test func theSizeComesFromTheIdentityLine() throws {
        #expect(DataLocator.expectedImageSize(try manifest(identity: "DMROMFSID1 title=0100000000010000 version=1.0 build=v0 size=12 index=ab")) == 12)
        #expect(DataLocator.expectedImageSize(try manifest(identity: "DMROMFSID1 fixture")) == nil)
    }

    @Test func aShortImageIsNotGameDataAndTheFullOneIs() throws {
        let box = try FrameworkBox()
        let folder = box.documents.appendingPathComponent("games/0100000000010000", isDirectory: true)
        try box.makeFolder(folder)
        let m = try manifest(identity: "DMROMFSID1 title=0100000000010000 version=1.0 build=v0 size=12 index=ab")
        let image = folder.appendingPathComponent("romfs.img")
        try Data(count: 5).write(to: image)
        #expect(DataLocator.locate(manifest: m, picked: .none, appFolder: folder).found == false)
        try Data(count: 12).write(to: image)
        #expect(DataLocator.locate(manifest: m, picked: .none, appFolder: folder).url == folder)
        // Without a size in the identity (a folder build), any non-empty image counts, as before
        try Data(count: 5).write(to: image)
        #expect(DataLocator.locate(manifest: try manifest(identity: "DMROMFSID1 fixture"), picked: .none, appFolder: folder).found)
    }
}
