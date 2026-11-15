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

    /// A DMROMFS1 image: header, 16 bytes of game data, then `index` (13 bytes here, so the hash pads to a multiple of 8).
    static func dmromfs(_ index: [UInt8], data: [UInt8] = [UInt8](repeating: 0x41, count: 16)) -> Data {
        func le(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8((v >> (8 * UInt64($0))) & 0xff) } }
        return Data(Array("DMROMFS1".utf8) + le(UInt64(32 + data.count)) + le(UInt64(index.count)) + le(0) + data + index)
    }
    static let indexA = Array(1...13).map(UInt8.init), indexB = Array(21...33).map(UInt8.init)

    /// Appends a spec-compliant 16 KiB-aligned MSL sub-image and 64-byte `DMMSLTR1` footer (`dm_msl_footer` in `romfs_image.h`).
    static func dmromfsWithTrailer(
        _ base: Data,
        mslPayload: [UInt8] = [UInt8](repeating: 0x5a, count: 45),
        version: UInt32 = 1,
        gfxAPI: UInt8 = 1,
        flags: UInt8 = 0,
        chain: String = "b-3f9a2c",
        overrideBaseSize: UInt64? = nil,
        overrideMslOffset: UInt64? = nil,
        overrideMslSize: UInt64? = nil,
        overrideChainLen: UInt16? = nil,
        magic: String = "DMMSLTR1"
    ) -> Data {
        func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xff), UInt8((v >> 8) & 0xff)] }
        func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * UInt32($0))) & 0xff) } }
        func le64(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8((v >> (8 * UInt64($0))) & 0xff) } }

        let baseEnd = UInt64(base.count)
        let alignedMslOffset = (baseEnd + 16_383) & ~16_383
        var out = base
        out.append(Data(count: Int(alignedMslOffset - baseEnd)))
        out.append(contentsOf: mslPayload)
        let rawEnd = UInt64(out.count)
        let footerOffset = (rawEnd + 7) & ~7
        out.append(Data(count: Int(footerOffset - rawEnd)))

        let chainUTF8 = Array(chain.utf8.prefix(24))
        var chainField = [UInt8](repeating: 0, count: 24)
        for (i, b) in chainUTF8.enumerated() { chainField[i] = b }

        var footer = [UInt8]()
        let magicBytes = Array(magic.utf8.prefix(8))
        footer.append(contentsOf: magicBytes + [UInt8](repeating: 0, count: max(0, 8 - magicBytes.count)))
        footer.append(contentsOf: le32(version))
        footer.append(gfxAPI)
        footer.append(flags)
        footer.append(contentsOf: le16(overrideChainLen ?? UInt16(chainUTF8.count)))
        footer.append(contentsOf: le64(overrideBaseSize ?? baseEnd))
        footer.append(contentsOf: le64(overrideMslOffset ?? alignedMslOffset))
        footer.append(contentsOf: le64(overrideMslSize ?? UInt64(mslPayload.count)))
        footer.append(contentsOf: chainField)
        precondition(footer.count == 64)
        out.append(contentsOf: footer)
        return out
    }

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

    /// An index of 3 MiB and 5 bytes spans four 1 MiB chunks, the last one padded. The expected value is what `romfs_id_of_image` gives
    /// for this image. A smaller chunk (a multiple of 8) must give the same hash.
    @Test func aLargeIndexHashesTheSameInAnyChunkSize() throws {
        let box = try Sandbox()
        let index = (0..<(3 * (1 << 20) + 5)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }
        let url = box.root.appendingPathComponent("big.img")
        try place(Self.dmromfs(index, data: [UInt8](repeating: 0x42, count: 16)), at: url)
        let want = RomfsIdentity(size: 3_145_781, index: 0x3a99427aa95b96e1)
        #expect(RomfsIdentity.ofImage(at: url) == want)
        #expect(RomfsIdentity.ofImage(at: url, chunk: 4096) == want)
        #expect(RomfsIdentity.ofImage(at: url, chunk: 8) == want)
        // Cut off inside the index: not an image.
        try Data(contentsOf: url).prefix(2_000_000).write(to: url)
        #expect(RomfsIdentity.ofImage(at: url) == nil)
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

    @Test func aPickedImageWithTheWrongIdentityFallsBackToTheAppFolder() throws {
        let box = try Sandbox()
        let manifest = try manifest(title: Fixtures.orbit, size: 61, index: "90b5abb4d1ea10d2")
        let picked = box.root.appendingPathComponent("Drive/Picked")
        let app = box.appData.appendingPathComponent(manifest.titleID)
        try place(Self.dmromfs(Self.indexB), at: picked.appendingPathComponent("romfs.img"))
        try place(Self.dmromfs(Self.indexA), at: app.appendingPathComponent("romfs.img"))

        let result = DataLocator.locate(manifest: manifest, picked: .url(picked), appFolder: app)
        #expect(result.source == .app && result.url == app)
    }

    @Test func aSharedTitleFolderWithTheWrongIdentityFallsBackToTheAppFolder() throws {
        let box = try Sandbox()
        let manifest = try manifest(title: Fixtures.orbit, size: 61, index: "90b5abb4d1ea10d2")
        let shared = box.root.appendingPathComponent("Drive")
        let app = box.appData.appendingPathComponent(manifest.titleID)
        try place(Self.dmromfs(Self.indexB), at: shared.appendingPathComponent(manifest.titleID + "/romfs.img"))
        try place(Self.dmromfs(Self.indexA), at: app.appendingPathComponent("romfs.img"))

        let result = DataLocator.locate(manifest: manifest, picked: .none, appFolder: app, global: .url(shared))
        #expect(result.source == .app && result.url == app)
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
        let a = try manifest(title: Fixtures.orbit, size: 61, index: "90b5abb4d1ea10d2")
        let b = try manifest(title: Fixtures.chain, size: 61, index: "9da33c3b161c746a")
        try place(Self.dmromfs(Self.indexA), at: shared.appendingPathComponent(Fixtures.orbit + "/romfs.img"))
        try place(Self.dmromfs(Self.indexB), at: shared.appendingPathComponent(Fixtures.chain + "/romfs.img"))
        let ra = DataLocator.locate(manifest: a, picked: .none, appFolder: box.appData.appendingPathComponent(a.titleID), global: .url(shared))
        let rb = DataLocator.locate(manifest: b, picked: .none, appFolder: box.appData.appendingPathComponent(b.titleID), global: .url(shared))
        #expect(ra.source == .shell && ra.url == shared.appendingPathComponent(Fixtures.orbit))
        #expect(rb.source == .shell && rb.url == shared.appendingPathComponent(Fixtures.chain))
    }

    @Test func aCutOffImageInTheTitleFolderFallsBackToTheAppFolder() throws {
        let box = try Sandbox()
        let shared = box.root.appendingPathComponent("Drive/All", isDirectory: true)
        let m = try manifest(title: Fixtures.orbit, size: 61, index: "90b5abb4d1ea10d2")
        let image = Self.dmromfs(Self.indexA)
        try place(image.prefix(5), at: shared.appendingPathComponent(Fixtures.orbit + "/romfs.img"))
        let app = box.appData.appendingPathComponent(Fixtures.orbit)
        #expect(!DataLocator.locate(manifest: m, picked: .none, appFolder: app, global: .url(shared)).found)
        try place(image, at: app.appendingPathComponent("romfs.img"))
        #expect(DataLocator.locate(manifest: m, picked: .none, appFolder: app, global: .url(shared)).source == .app)
    }

    @Test func theSingleGameLayoutAndTheGamesOwnFolderStillWork() throws {
        let box = try Sandbox()
        let shared = box.root.appendingPathComponent("Drive/One", isDirectory: true)
        let m = try manifest(title: Fixtures.orbit, size: 61, index: "90b5abb4d1ea10d2")
        let app = box.appData.appendingPathComponent(Fixtures.orbit)
        let image = Self.dmromfs(Self.indexA)
        try place(image, at: shared.appendingPathComponent("romfs.img"))
        let single = DataLocator.locate(manifest: m, picked: .none, appFolder: app, global: .url(shared))
        #expect(single.source == .shell && single.url == shared)
        // The title folder is tried before the folder itself, and the game's own pick before both.
        try place(image, at: shared.appendingPathComponent(Fixtures.orbit + "/romfs.img"))
        #expect(DataLocator.locate(manifest: m, picked: .none, appFolder: app, global: .url(shared)).url == shared.appendingPathComponent(Fixtures.orbit))
        let own = box.root.appendingPathComponent("Drive/Own", isDirectory: true)
        try place(image, at: own.appendingPathComponent("romfs.img"))
        let r = DataLocator.locate(manifest: m, picked: .url(own), appFolder: app, global: .url(shared))
        #expect(r.source == .picked && r.url == own)
    }

    @Test func dlcSitsBesideTheTitleFolderImage() throws {
        let box = try Sandbox()
        let shared = box.root.appendingPathComponent("Drive/All", isDirectory: true)
        let m = try manifest(title: Fixtures.orbit, size: 61, index: "90b5abb4d1ea10d2")
        let folder = shared.appendingPathComponent(Fixtures.orbit, isDirectory: true)
        try place(Self.dmromfs(Self.indexA), at: folder.appendingPathComponent("romfs.img"))
        try place(Data(count: 3), at: folder.appendingPathComponent("aoc/0.img"))
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

    @Test func validDMMSLTR1TrailerPreservesBaseIdentityAndInspectsMetadata() throws {
        let box = try Sandbox()
        let baseA = Self.dmromfs(Self.indexA) // 61 bytes
        let plainURL = box.root.appendingPathComponent("plain.img")
        try place(baseA, at: plainURL)
        #expect(RomfsTrailer.inspect(at: plainURL) == nil)

        let nvnURL = box.root.appendingPathComponent("nvn.img")
        let nvnData = Self.dmromfsWithTrailer(baseA, mslPayload: [UInt8](repeating: 0xab, count: 45), gfxAPI: 1, flags: 0, chain: "b-d0e99bd4b2fe")
        try place(nvnData, at: nvnURL)
        let nvnTrailer = try #require(RomfsTrailer.inspect(at: nvnURL))
        #expect(nvnTrailer == RomfsTrailer(version: 1, gfxAPI: 1, multiProgram: false, baseRomfsSize: 61, mslOffset: 16_384, mslSize: 45, chain: "b-d0e99bd4b2fe"))
        #expect(RomfsIdentity.ofImage(at: nvnURL) == RomfsIdentity(size: 61, index: 0x90b5abb4d1ea10d2))

        let glMultiURL = box.root.appendingPathComponent("gl_multi.img")
        let glData = Self.dmromfsWithTrailer(baseA, mslPayload: [UInt8](repeating: 0xcd, count: 64), gfxAPI: 3, flags: 1, chain: "")
        try place(glData, at: glMultiURL)
        let glTrailer = try #require(RomfsTrailer.inspect(at: glMultiURL))
        #expect(glTrailer == RomfsTrailer(version: 1, gfxAPI: 3, multiProgram: true, baseRomfsSize: 61, mslOffset: 16_384, mslSize: 64, chain: ""))
        #expect(RomfsIdentity.ofImage(at: glMultiURL) == RomfsIdentity(size: 61, index: 0x90b5abb4d1ea10d2))

        let m = try manifest(title: Fixtures.orbit, size: 61, index: "90b5abb4d1ea10d2")
        #expect(DataLocator.isComplete(nvnURL, manifest: m, .default))
        #expect(DataLocator.isComplete(glMultiURL, manifest: m, .default))

        // Flat sibling custom-named images in one folder are matched to each game's exact file URL.
        let flat = box.root.appendingPathComponent("FlatRoot", isDirectory: true)
        let stardew = flat.appendingPathComponent("星露谷物语.img")
        let hollow = flat.appendingPathComponent("空洞骑士.img")
        try place(nvnData, at: stardew)
        try place(Self.dmromfsWithTrailer(Self.dmromfs(Self.indexB)), at: hollow)
        try place(nvnData, at: flat.appendingPathComponent(".hidden.img"))
        try place(nvnData, at: flat.appendingPathComponent("bad.nxpart.img"))
        try place(Data("p".utf8), at: flat.appendingPathComponent("星露谷物语.img.nxpart.0000.0002"))

        let index = ShellDataIndex(folder: flat)
        let matchA = try #require(index.imageURL(matching: try ident(Self.indexA)))
        let matchB = try #require(index.imageURL(matching: try ident(Self.indexB)))
        #expect(path(matchA) == path(stardew))
        #expect(path(matchB) == path(hollow))
        #expect(index.folder(matching: try ident(Self.indexA)).map(path) == path(flat))

        let mB = try manifest(title: Fixtures.chain, size: 61, index: "9da33c3b161c746a")
        let locA = DataLocator.locate(manifest: m, picked: .none, appFolder: box.appData.appendingPathComponent(m.titleID),
                                      global: .url(flat), shellMatch: matchA)
        let locB = DataLocator.locate(manifest: mB, picked: .none, appFolder: box.appData.appendingPathComponent(mB.titleID),
                                      global: .url(flat), shellMatch: matchB)
        #expect(locA.source == .shell && locA.url.map(path) == path(flat) && locA.romfsURL.map(path) == path(stardew))
        #expect(locB.source == .shell && locB.url.map(path) == path(flat) && locB.romfsURL.map(path) == path(hollow))

        // Direct directory fallback without shellMatch also skips the non-matching first sibling and binds the second.
        let pickedB = DataLocator.locate(manifest: mB, picked: .url(flat), appFolder: box.appData.appendingPathComponent(mB.titleID))
        #expect(pickedB.source == .picked && pickedB.romfsURL.map(path) == path(hollow))
    }

    @Test func corruptedTruncatedOrMisalignedTrailersAreRejected() throws {
        let box = try Sandbox()
        let baseA = Self.dmromfs(Self.indexA)
        let valid = Self.dmromfsWithTrailer(baseA)
        let wantIdent = try ident(Self.indexA)
        let m = try manifest(title: Fixtures.orbit, size: 61, index: "90b5abb4d1ea10d2")

        var extraZeroPadding = valid.dropLast(64)
        extraZeroPadding.append(Data(count: 8))
        extraZeroPadding.append(valid.suffix(64))

        var embeddedNulInChain = valid
        embeddedNulInChain[embeddedNulInChain.count - 24 + 2] = 0

        var dirtyChainPadding = valid
        dirtyChainPadding[dirtyChainPadding.count - 1] = 0x7f

        var overflowHeader = valid
        let nearMax: UInt64 = UInt64.max - 8
        for k in 0..<8 { overflowHeader[8 + k] = UInt8((nearMax >> (8 * UInt64(k))) & 0xff) }

        let badCases: [(String, Data)] = [
            ("short_garbage", baseA + Data([1, 2, 3, 4, 5])),
            ("long_garbage", baseA + Data(repeating: 0x99, count: 128)),
            ("truncated_1b", Data(valid.dropLast(1))),
            ("truncated_mid_msl", Data(valid.prefix(16_400))),
            ("bad_magic", Self.dmromfsWithTrailer(baseA, magic: "DMMSLTR0")),
            ("bad_version", Self.dmromfsWithTrailer(baseA, version: 2)),
            ("gfx_zero", Self.dmromfsWithTrailer(baseA, gfxAPI: 0)),
            ("gfx_four", Self.dmromfsWithTrailer(baseA, gfxAPI: 4)),
            ("wrong_base_size", Self.dmromfsWithTrailer(baseA, overrideBaseSize: 60)),
            ("unaligned_msl_offset", Self.dmromfsWithTrailer(baseA, overrideMslOffset: 64)),
            ("next_page_msl_offset", Self.dmromfsWithTrailer(baseA, overrideMslOffset: 32_768)),
            ("msl_too_small", Self.dmromfsWithTrailer(baseA, mslPayload: [UInt8](repeating: 0x11, count: 32), overrideMslSize: 31)),
            ("msl_overflow_u64", Self.dmromfsWithTrailer(baseA, overrideMslSize: UInt64.max)),
            ("extra_padding_before_footer", Data(extraZeroPadding)),
            ("chain_len_25", Self.dmromfsWithTrailer(baseA, overrideChainLen: 25)),
            ("nul_inside_chain", embeddedNulInChain),
            ("nonzero_chain_padding", dirtyChainPadding),
            ("header_offset_overflow", overflowHeader)
        ]

        for (label, data) in badCases {
            let dir = box.root.appendingPathComponent(label, isDirectory: true)
            let url = dir.appendingPathComponent("romfs.img")
            try place(data, at: url)
            #expect(RomfsTrailer.inspect(at: url) == nil, "inspect should reject \(label)")
            #expect(RomfsIdentity.ofImage(at: url) == nil, "ofImage should reject \(label)")
            #expect(!DataLocator.isComplete(url, manifest: m, .default), "isComplete should reject \(label)")
            #expect(ShellDataIndex(folder: dir).imageURL(matching: wantIdent) == nil, "ShellDataIndex should reject \(label)")
        }
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

    private func giveOrbitAnIdentity(in box: Sandbox) throws {
        let manifestURL = box.games.appendingPathComponent(Fixtures.orbit + "/game.manifest.json")
        let text = try String(contentsOf: manifestURL, encoding: .utf8)
            .replacingOccurrences(of: "\"DMROMFSID1 fixture\"", with: "\"DMROMFSID1 title=\(Fixtures.orbit) version=1.0 build=v0 size=61 index=90b5abb4d1ea10d2\"")
        try text.write(to: manifestURL, atomically: true, encoding: .utf8)
    }

    @Test func playWaitsForThePickedIdentityAndRejectsAReplacement() async throws {
        let box = try Sandbox()
        let images = ShellDataFolderTests()
        let title = Fixtures.orbit
        try giveOrbitAnIdentity(in: box)
        let picked = box.root.appendingPathComponent("Drive/Picked", isDirectory: true)
        let local = box.appData.appendingPathComponent(title, isDirectory: true)
        let image = picked.appendingPathComponent("romfs.img")
        let good = ShellDataFolderTests.dmromfs(ShellDataFolderTests.indexA)
        try images.place(good, at: image)
        try images.place(good, at: local.appendingPathComponent("romfs.img"))
        let fm = FileManager.default
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try fm.setAttributes([.modificationDate: date], ofItemAtPath: image.path)
        let bookmark = BookmarkStore(defaults: box.defaults(title), key: BookmarkStore.gameDataKey)
        try #require(bookmark.store(picked))

        let launcher = RecordingLauncher()
        let settings = ShellSettingsStore(defaults: UserDefaults(suiteName: "t-shell-\(UUID().uuidString)")!)
        let model = ShellHostModel(config: box.config(), launcher: launcher, shellSettings: settings)
        await model.playNow(title)
        #expect(launcher.launched.last?.dataURL.resolvingSymlinksInPath() == picked.resolvingSymlinksInPath())

        // A copy in place can change the index without changing anything in the library cache's file stamp.
        let before = try fm.attributesOfItem(atPath: image.path)
        let wrong = ShellDataFolderTests.dmromfs(ShellDataFolderTests.indexB)
        let handle = try FileHandle(forWritingTo: image)
        try handle.write(contentsOf: wrong)
        try handle.close()
        try fm.setAttributes([.modificationDate: date], ofItemAtPath: image.path)
        let after = try fm.attributesOfItem(atPath: image.path)
        #expect(after[.size] as? NSNumber == before[.size] as? NSNumber)
        #expect(after[.systemFileNumber] as? NSNumber == before[.systemFileNumber] as? NSNumber)
        #expect(after[.modificationDate] as? Date == date)
        await model.playNow(title)
        #expect(launcher.launched.last?.dataURL == local)

        // An atomic replacement can preserve both the size and the modification date.
        try wrong.write(to: image, options: .atomic)
        try fm.setAttributes([.modificationDate: date], ofItemAtPath: image.path)
        await model.playNow(title)
        let game = try #require(launcher.launched.last)
        #expect(game.dataURL == local)
        let plan = EngineLaunchPlan.make(game: game, appResources: box.root, documents: box.root, envFileText: nil)
        #expect(plan.environment["DM_ROMFS"] == local.appendingPathComponent("romfs.img").path)

        // An unpacked tree beside the rejected image is still usable. The engine must use the selected tree.
        let tree = picked.appendingPathComponent("romfs", isDirectory: true)
        try box.write("", to: tree.appendingPathComponent("fixture.marker"))
        await model.playNow(title)
        let treeGame = try #require(launcher.launched.last)
        let treePlan = EngineLaunchPlan.make(game: treeGame, appResources: box.root, documents: box.root, envFileText: nil)
        let selected = try #require(treePlan.environment["DM_ROMFS"])
        #expect(URL(fileURLWithPath: selected).resolvingSymlinksInPath().path == tree.resolvingSymlinksInPath().path)

        // A directly picked image can have a different name, even when romfs.img is also in its folder.
        let alternate = picked.appendingPathComponent("Selected.img")
        try images.place(good, at: alternate)
        try #require(bookmark.store(alternate))
        await model.playNow(title)
        let imageGame = try #require(launcher.launched.last)
        let imagePlan = EngineLaunchPlan.make(game: imageGame, appResources: box.root, documents: box.root, envFileText: nil)
        let selectedImage = try #require(imagePlan.environment["DM_ROMFS"])
        #expect(URL(fileURLWithPath: selectedImage).resolvingSymlinksInPath().path == alternate.resolvingSymlinksInPath().path)
    }

    @Test func theLibraryWaitsForAnExternalImageBeforeShowingItAsPlayable() async throws {
        let box = try Sandbox()
        try giveOrbitAnIdentity(in: box)
        let picked = box.root.appendingPathComponent("Drive/OnlyCopy", isDirectory: true)
        let image = picked.appendingPathComponent("romfs.img")
        let images = ShellDataFolderTests()
        try images.place(ShellDataFolderTests.dmromfs(ShellDataFolderTests.indexA), at: image)
        let title = Fixtures.orbit
        try #require(BookmarkStore(defaults: box.defaults(title), key: BookmarkStore.gameDataKey).store(picked))

        let host = model(box, picker: MutablePicker(nil))
        #expect(host.details.first { $0.id == title }?.game.state == .needsGameData)
        await host.waitForDataChecks()
        #expect(host.details.first { $0.id == title }?.game.state == .playable)

        try ShellDataFolderTests.dmromfs(ShellDataFolderTests.indexB).write(to: image, options: .atomic)
        host.refreshAll()
        await host.waitForDataChecks()
        #expect(host.details.first { $0.id == title }?.game.state == .needsGameData)
    }

    enum Recovery: CaseIterable {
        case reload, repickGame, repickShared
    }

    @Test(arguments: Recovery.allCases)
    func aCorrectedExternalImageIsRetriedOnReloadOrRepick(recovery: Recovery) async throws {
        let box = try Sandbox()
        try giveOrbitAnIdentity(in: box)
        let shared = box.root.appendingPathComponent("Drive", isDirectory: true)
        let picked = shared.appendingPathComponent("OnlyCopy", isDirectory: true)
        let image = picked.appendingPathComponent("romfs.img")
        let images = ShellDataFolderTests()
        let fm = FileManager.default
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try images.place(ShellDataFolderTests.dmromfs(ShellDataFolderTests.indexB), at: image)
        try fm.setAttributes([.modificationDate: date], ofItemAtPath: image.path)
        let title = Fixtures.orbit
        let host: ShellHostModel
        if recovery == .repickShared {
            host = model(box, picker: MutablePicker(shared))
            await host.pickShellDataNow()
        } else {
            try #require(BookmarkStore(defaults: box.defaults(title), key: BookmarkStore.gameDataKey).store(picked))
            host = model(box, picker: MutablePicker(picked))
        }
        await host.waitForDataChecks()
        #expect(host.details.first { $0.id == title }?.game.state == .needsGameData)

        let before = try fm.attributesOfItem(atPath: image.path)
        let handle = try FileHandle(forWritingTo: image)
        try handle.write(contentsOf: ShellDataFolderTests.dmromfs(ShellDataFolderTests.indexA))
        try handle.close()
        try fm.setAttributes([.modificationDate: date], ofItemAtPath: image.path)
        let after = try fm.attributesOfItem(atPath: image.path)
        #expect(after[.size] as? NSNumber == before[.size] as? NSNumber)
        #expect(after[.systemFileNumber] as? NSNumber == before[.systemFileNumber] as? NSNumber)
        #expect(after[.modificationDate] as? Date == date)

        switch recovery {
        case .repickGame:
            await host.pickGameDataNow(title)
        case .repickShared:
            await host.pickShellDataNow()
            await host.waitForDataChecks()
        case .reload:
            host.reload()
            await host.waitForDataChecks()
        }
        #expect(host.details.first { $0.id == title }?.game.state == .playable)
    }

    @Test func theScanFindsTheGameThenANewFolderDropsIt() async throws {
        let box = try Sandbox()
        try giveOrbitAnIdentity(in: box)
        let drive = box.root.appendingPathComponent("Drive", isDirectory: true)
        try FileManager.default.createDirectory(at: drive.appendingPathComponent("Some name"), withIntermediateDirectories: true)
        try ShellDataFolderTests.dmromfs(ShellDataFolderTests.indexA).write(to: drive.appendingPathComponent("Some name/romfs.img"))
        let empty = box.root.appendingPathComponent("Empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)

        let picker = MutablePicker(drive)
        let m = model(box, picker: picker)
        await m.pickShellDataNow()
        await m.waitForDataChecks()
        var orbit = try #require(m.details.first { $0.id == Fixtures.orbit })
        #expect(orbit.game.state == .playable && orbit.dataFromShell)
        #expect(orbit.dataSource.hasSuffix("(from Settings)"))

        // A new folder: the old matches are gone and the new folder is scanned.
        picker.url = empty
        await m.pickShellDataNow()
        await m.waitForDataChecks()
        orbit = try #require(m.details.first { $0.id == Fixtures.orbit })
        #expect(orbit.game.state == .needsGameData)
    }

    @Test func pickingDriveRootFindsTitleSubfolderAndSurvivesReloadAndRelaunch() async throws {
        let box = try Sandbox()
        let fm = FileManager.default
        let hexTitle = "0100ABCDEF000000"
        defer { UserDefaults().removePersistentDomain(forName: box.suite + hexTitle) }
        let oldDir = box.games.appendingPathComponent(Fixtures.orbit, isDirectory: true)
        let hexDir = box.games.appendingPathComponent(hexTitle, isDirectory: true)
        try fm.moveItem(at: oldDir, to: hexDir)
        for file in ["game.manifest.json", "launcher.json"] {
            let url = hexDir.appendingPathComponent(file)
            let updated = try String(contentsOf: url, encoding: .utf8)
                .replacingOccurrences(of: Fixtures.orbit, with: hexTitle)
                .replacingOccurrences(of: "\"DMROMFSID1 fixture\"", with: "\"DMROMFSID1 title=\(hexTitle) version=1.0 build=v0 size=61 index=90b5abb4d1ea10d2\"")
            try updated.write(to: url, atomically: true, encoding: .utf8)
        }

        // Export layout <Drive>/<lowercase titleid>/romfs.img plus aoc/0.img.
        let drive = box.root.appendingPathComponent("ExternalDrive", isDirectory: true)
        let titleFolder = drive.appendingPathComponent(hexTitle.lowercased(), isDirectory: true)
        let images = ShellDataFolderTests()
        try images.place(ShellDataFolderTests.dmromfs(ShellDataFolderTests.indexA), at: titleFolder.appendingPathComponent("romfs.img"))
        try images.place(Data("dlc".utf8), at: titleFolder.appendingPathComponent("aoc/0.img"))

        let launcher = RecordingLauncher()
        let settings = ShellSettingsStore(defaults: UserDefaults(suiteName: "t-shell-\(UUID().uuidString)")!)
        let picker = MutablePicker(drive)
        let host = ShellHostModel(config: box.config(), launcher: launcher, picker: picker, shellSettings: settings)

        await host.pickGameDataNow(hexTitle)
        #expect(host.notice == nil)
        let pickedDetail = try #require(host.details.first { $0.id == hexTitle })
        #expect(pickedDetail.game.state == .playable)
        #expect(pickedDetail.dataSource == hexTitle.lowercased())
        #expect(pickedDetail.dlc == "1 additional content pack")

        // The stored bookmark must keep pointing at the user-picked parent drive root so its security scope covers the subfolder.
        let storedStore = BookmarkStore(defaults: box.defaults(hexTitle), key: BookmarkStore.gameDataKey)
        guard case .url(let bookmarkedURL) = storedStore.resolve() else {
            Issue.record("expected stored drive bookmark to resolve")
            return
        }
        #expect(bookmarkedURL.resolvingSymlinksInPath().path == drive.resolvingSymlinksInPath().path)

        // Remains playable across reload().
        host.reload()
        await host.waitForDataChecks()
        #expect(host.details.first { $0.id == hexTitle }?.game.state == .playable)

        // Remains playable across a full model relaunch and launches from the title subfolder with launchingGame reset.
        let relaunched = ShellHostModel(config: box.config(), launcher: launcher, picker: MutablePicker(nil), shellSettings: settings)
        await relaunched.waitForDataChecks()
        #expect(relaunched.details.first { $0.id == hexTitle }?.game.state == .playable)
        await relaunched.playNow(hexTitle)
        #expect(!relaunched.launchingGame)
        let launched = try #require(launcher.launched.last)
        #expect(launched.dataURL.resolvingSymlinksInPath().path == titleFolder.resolvingSymlinksInPath().path)
        let plan = EngineLaunchPlan.make(game: launched, appResources: box.root, documents: box.root, envFileText: nil)
        #expect(URL(fileURLWithPath: try #require(plan.environment["DM_ROMFS"])).resolvingSymlinksInPath().path == titleFolder.appendingPathComponent("romfs.img").resolvingSymlinksInPath().path)
        #expect(URL(fileURLWithPath: try #require(plan.environment["DM_AOC_DIR"])).resolvingSymlinksInPath().path == titleFolder.appendingPathComponent("aoc").resolvingSymlinksInPath().path)
    }

    @Test func flatSiblingCustomNamedImagesWithTrailersResolveToEachGamesExactFile() async throws {
        let box = try Sandbox()
        let fm = FileManager.default
        let chainHex = "0100ABCDEF112233"
        defer { UserDefaults().removePersistentDomain(forName: box.suite + chainHex) }

        // Give Orbit (indexA) and a second playable game (indexB) distinct identities of the same base size (61 B).
        try giveOrbitAnIdentity(in: box)
        let secondDir = box.games.appendingPathComponent(chainHex, isDirectory: true)
        try fm.copyItem(at: box.games.appendingPathComponent(Fixtures.orbit), to: secondDir)
        for file in ["game.manifest.json", "launcher.json"] {
            let url = secondDir.appendingPathComponent(file)
            let updated = try String(contentsOf: url, encoding: .utf8)
                .replacingOccurrences(of: Fixtures.orbit, with: chainHex)
                .replacingOccurrences(of: "Orbit Fixture", with: "Hollow Fixture")
                .replacingOccurrences(of: "90b5abb4d1ea10d2", with: "9da33c3b161c746a")
            try updated.write(to: url, atomically: true, encoding: .utf8)
        }

        let shared = box.root.appendingPathComponent("SharedFlatDrive", isDirectory: true)
        let stardewURL = shared.appendingPathComponent("星露谷物语.img")
        let hollowURL = shared.appendingPathComponent("空洞骑士.img")
        let stardewData = ShellDataFolderTests.dmromfsWithTrailer(ShellDataFolderTests.dmromfs(ShellDataFolderTests.indexA), mslPayload: [UInt8](repeating: 0x31, count: 48))
        let hollowData = ShellDataFolderTests.dmromfsWithTrailer(ShellDataFolderTests.dmromfs(ShellDataFolderTests.indexB), mslPayload: [UInt8](repeating: 0x32, count: 96))
        let helpers = ShellDataFolderTests()
        try helpers.place(stardewData, at: stardewURL)
        try helpers.place(hollowData, at: hollowURL)
        // Noise files that must never be mistaken for images:
        try helpers.place(stardewData, at: shared.appendingPathComponent(".隐藏镜像.img"))
        try helpers.place(stardewData, at: shared.appendingPathComponent("星露谷物语.nxpart.img"))
        try helpers.place(Data("part".utf8), at: shared.appendingPathComponent("星露谷物语.img.nxpart.0000.0002"))

        let index = ShellDataIndex(folder: shared)
        let identA = try helpers.ident(ShellDataFolderTests.indexA)
        let identB = try helpers.ident(ShellDataFolderTests.indexB)
        #expect(index.imageURL(matching: identA)?.resolvingSymlinksInPath().path == stardewURL.resolvingSymlinksInPath().path)
        #expect(index.imageURL(matching: identB)?.resolvingSymlinksInPath().path == hollowURL.resolvingSymlinksInPath().path)
        #expect(index.folder(matching: identA)?.resolvingSymlinksInPath().path == shared.resolvingSymlinksInPath().path)

        let launcher = RecordingLauncher()
        let settings = ShellSettingsStore(defaults: UserDefaults(suiteName: "t-shell-\(UUID().uuidString)")!)
        let host = ShellHostModel(config: box.config(), launcher: launcher, picker: MutablePicker(shared), shellSettings: settings)
        await host.pickShellDataNow()
        await host.waitForDataChecks()

        #expect(host.details.first { $0.id == Fixtures.orbit }?.game.state == .playable)
        #expect(host.details.first { $0.id == chainHex }?.game.state == .playable)

        await host.playNow(Fixtures.orbit)
        let launchedOrbit = try #require(launcher.launched.last)
        let orbitPlan = EngineLaunchPlan.make(game: launchedOrbit, appResources: box.root, documents: box.root, envFileText: nil)
        #expect(URL(fileURLWithPath: try #require(orbitPlan.environment["DM_ROMFS"])).resolvingSymlinksInPath().path == stardewURL.resolvingSymlinksInPath().path)

        await host.playNow(chainHex)
        let launchedHollow = try #require(launcher.launched.last)
        let hollowPlan = EngineLaunchPlan.make(game: launchedHollow, appResources: box.root, documents: box.root, envFileText: nil)
        #expect(URL(fileURLWithPath: try #require(hollowPlan.environment["DM_ROMFS"])).resolvingSymlinksInPath().path == hollowURL.resolvingSymlinksInPath().path)

        // Diagnostics also recognize custom-named non-part .img files in nested and wrong-game folders.
        let nestedRoot = box.root.appendingPathComponent("DiagRoot", isDirectory: true)
        try helpers.place(stardewData, at: nestedRoot.appendingPathComponent("Inner/星露谷物语.img"))
        let orbitManifest = try GameManifest.parse(Data(contentsOf: box.games.appendingPathComponent(Fixtures.orbit + "/game.manifest.json")))
        #expect(DataFolderDiagnostics.diagnose(folder: nestedRoot, manifest: orbitManifest) == .nestedGameData(subfolder: "Inner"))

        let wrongRoot = box.root.appendingPathComponent("WrongRoot", isDirectory: true)
        try helpers.place(hollowData, at: wrongRoot.appendingPathComponent("空洞骑士.img"))
        #expect(DataFolderDiagnostics.diagnose(folder: wrongRoot, manifest: orbitManifest) == .wrongGame(otherTitleOrID: nil))
    }
}
