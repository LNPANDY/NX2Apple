import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import NX2Apple
@testable import NXCore

final class ArtworkImportTests: XCTestCase {
    private var temporary: URL!
    private var folder: URL { temporary.appendingPathComponent("artwork") }

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("nxnative-import-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: temporary)
    }

    /// An image of `width` × `height` pixels, in `type`, with the EXIF orientation set as a camera writes it. The left half is
    /// red and the right half blue, so a turned image shows.
    @discardableResult
    private func image(_ name: String, width: Int, height: Int, type: UTType = .jpeg, orientation: Int = 1) throws -> URL {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
        let url = temporary.appendingPathComponent(name)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), [kCGImagePropertyOrientation: orientation] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw XCTSkip("this machine cannot write \(type.identifier)") }
        return url
    }

    private func size(of url: URL) throws -> CGSize {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        return CGSize(width: try XCTUnwrap(properties[kCGImagePropertyPixelWidth] as? Int), height: try XCTUnwrap(properties[kCGImagePropertyPixelHeight] as? Int))
    }

    private func failure(_ url: URL, kind: ArtworkImport.Kind = .hero) -> ArtworkImport.Failure? {
        do { _ = try ArtworkImport.prepare(url, kind: kind, into: folder) } catch { return error as? ArtworkImport.Failure }
        return nil
    }

    func testATextFileNamedPNGIsNotAnImage() throws {
        let url = temporary.appendingPathComponent("notes.png")
        try Data("not an image".utf8).write(to: url)
        XCTAssertEqual(failure(url), .notAnImage)
    }

    func testAFileOverFiftyMegabytesIsRefusedUnread() throws {
        let url = temporary.appendingPathComponent("huge.png")
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 51 << 20)   // sparse: nothing is written, and a read would find no image
        try handle.close()
        XCTAssertEqual(failure(url), .tooLarge)
    }

    func testAJPEGCutOffBeforeItsPixelsIsUnreadable() throws {
        let whole = try Data(contentsOf: image("whole.jpg", width: 800, height: 450))
        let url = temporary.appendingPathComponent("cut.jpg")
        try whole.prefix(300).write(to: url)   // ImageIO draws one cut later as far as it goes, as Preview does
        XCTAssertEqual(failure(url), .unreadable)
    }

    func testAMissingFileIsUnreadable() {
        XCTAssertEqual(failure(temporary.appendingPathComponent("gone.jpg")), .unreadable)
    }

    func testAHeroIsKeptToTheWidthOfA4KScreen() throws {
        let prepared = try ArtworkImport.prepare(image("big.jpg", width: 6000, height: 3375), kind: .hero, into: folder)
        XCTAssertEqual(prepared.pixelSize, CGSize(width: 3840, height: 2160))
        XCTAssertEqual(try size(of: prepared.url), prepared.pixelSize)
        XCTAssertEqual(prepared.url.pathExtension, "jpg")
        XCTAssertFalse(prepared.lowResolution)
    }

    func testASmallHeroIsNotEnlargedAndIsLowResolution() throws {
        let prepared = try ArtworkImport.prepare(image("small.jpg", width: 800, height: 450), kind: .hero, into: folder)
        XCTAssertEqual(prepared.pixelSize, CGSize(width: 800, height: 450))
        XCTAssertTrue(prepared.lowResolution)
    }

    func testAThumbnailIsKeptTo1920AndLowBelow640() throws {
        let wide = try ArtworkImport.prepare(image("wide.jpg", width: 4000, height: 2000), kind: .thumbnail, into: folder)
        XCTAssertEqual(wide.pixelSize, CGSize(width: 1920, height: 960))
        XCTAssertFalse(wide.lowResolution)
        XCTAssertTrue(try ArtworkImport.prepare(image("narrow.jpg", width: 600, height: 300), kind: .thumbnail, into: folder).lowResolution)
        XCTAssertFalse(try ArtworkImport.prepare(image("edge.jpg", width: 640, height: 360), kind: .thumbnail, into: folder).lowResolution)
    }

    func testTheOrientationIsAppliedToThePixels() throws {
        // Orientation 6: stored 100 × 50, shown 50 × 100 and turned a quarter to the right.
        let prepared = try ArtworkImport.prepare(image("turned.jpg", width: 100, height: 50, orientation: 6), kind: .hero, into: folder)
        XCTAssertEqual(prepared.pixelSize, CGSize(width: 50, height: 100))
        let stored = try XCTUnwrap(NSImage(contentsOf: prepared.url)?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertEqual(stored.width, 50)
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(try XCTUnwrap(CGImageSourceCreateWithURL(prepared.url as CFURL, nil)), 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyOrientation] as? Int ?? 1, 1)   // upright, with no tag left to apply twice
        let pixels = try XCTUnwrap(stored.dataProvider?.data as Data?)
        XCTAssertGreaterThan(pixels[0], pixels[2])   // the top row is the red half: it was the left one
    }

    func testPNGHEICAndTIFFAreAccepted() throws {
        for (type, name) in [(UTType.png, "a.png"), (.tiff, "a.tiff"), (.heic, "a.heic")] {
            let prepared = try ArtworkImport.prepare(image(name, width: 640, height: 360, type: type), kind: .hero, into: folder)
            XCTAssertEqual(prepared.pixelSize, CGSize(width: 640, height: 360), name)
        }
    }

    func testWebPIsAccepted() throws {
        // ImageIO reads WebP but does not write it: a 1 × 1 lossless file, in bytes.
        let url = temporary.appendingPathComponent("a.webp")
        try XCTUnwrap(Data(base64Encoded: "UklGRhoAAABXRUJQVlA4TA0AAAAvAAAAEAcQERGIiP4HAA==")).write(to: url)
        guard CGImageSourceCreateWithURL(url as CFURL, nil).flatMap(CGImageSourceGetType) as String? == "org.webmproject.webp" else { throw XCTSkip("this system cannot read WebP") }
        let prepared = try ArtworkImport.prepare(url, kind: .hero, into: folder)
        XCTAssertEqual(prepared.pixelSize, CGSize(width: 1, height: 1))
        XCTAssertTrue(prepared.lowResolution)
    }

    func testTheSameImageIsTheSameFile() throws {
        let first = try ArtworkImport.prepare(image("one.jpg", width: 800, height: 450), kind: .hero, into: folder)
        let second = try ArtworkImport.prepare(image("two.jpg", width: 800, height: 450), kind: .hero, into: folder)
        XCTAssertEqual(first.url, second.url)
        XCTAssertEqual(first.url.deletingPathExtension().lastPathComponent.count, 64)   // a SHA-256 in hex
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 1)   // and no temporary file left
        let other = try ArtworkImport.prepare(image("three.jpg", width: 800, height: 400), kind: .hero, into: folder)
        XCTAssertNotEqual(first.url, other.url)
    }

    func testTheCustomFolderIsKeyedOnTheGameID() {
        let id = UUID()
        XCTAssertEqual(ArtworkStore.customDirectory(for: id, in: folder).path, folder.path + "/custom/" + id.uuidString)
    }


    /// A library file holding one game per path, the way an earlier version saved it.
    private func library(artwork paths: [String], volumes: String = "/Volumes") throws -> GameLibrary {
        let games = paths.enumerated().map { index, path in
            var game = LibraryGame(titleID: "01005350129740" + String(format: "%02X", index), name: "Game \(index)")
            game.artworkPath = path
            return game
        }
        let file = temporary.appendingPathComponent("state/library.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        struct Snapshot: Encodable { let games: [LibraryGame], folder: String }
        try JSONEncoder().encode(Snapshot(games: games, folder: "")).write(to: file)
        return GameLibrary(file: file, volumes: volumes, artwork: folder)
    }

    private func migrate(_ library: GameLibrary, volumes: String = "/Volumes") {
        let done = expectation(description: "migrated")
        library.migrateArtwork(volumes: volumes) { done.fulfill() }
        wait(for: [done], timeout: 10)
    }

    func testMigrationCopiesAnExternalImageAndLeavesTheOriginal() throws {
        let original = try image("mine.jpg", width: 2000, height: 1000)
        let before = try Data(contentsOf: original)
        let library = try library(artwork: [original.path])
        let id = library.games[0].id
        migrate(library)
        XCTAssertEqual(library.games[0].artworkPath, "")
        let name = try XCTUnwrap(library.games[0].artwork.hero).source
        guard case .imported(let file) = name else { return XCTFail("the copy is the hero") }
        let path = ArtworkStore.customDirectory(for: id, in: folder).appendingPathComponent(file).path
        XCTAssertEqual(try Data(contentsOf: original), before)
        try FileManager.default.removeItem(at: original)   // the copy does not depend on it
        XCTAssertNotNil(NSImage(contentsOfFile: path))
        XCTAssertEqual(GameLibrary(file: temporary.appendingPathComponent("state/library.json"), artwork: folder).games[0].artwork.hero?.source, .imported(file))   // saved
        migrate(library)   // and a copy is not copied again
        XCTAssertEqual(library.games[0].artwork.hero?.source, .imported(file))
    }

    func testSettingArtworkDoesNotSweepTheFolderOfAGameBeingMigrated() throws {
        let original = try image("mine.jpg", width: 2000, height: 1000)
        let library = try library(artwork: [original.path])
        let id = library.games[0].id
        let custom = ArtworkStore.customDirectory(for: id, in: folder)
        try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
        let copy = custom.appendingPathComponent(String(repeating: "a", count: 64) + ".jpg")   // what the background copy has just written
        try Data("x".utf8).write(to: copy)
        let done = expectation(description: "migrated")
        library.migrateArtwork { done.fulfill() }
        var artwork = GameArtwork()
        artwork.thumbnail = ArtworkChoice(source: .screenshot(1))
        library.setArtwork(artwork, for: id)   // on the main thread, so before the migration's completion runs
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path), "the copy waits to be adopted")
        wait(for: [done], timeout: 10)
        library.setArtwork(artwork, for: id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path), "swept once the migration is over")
    }

    func testMigrationKeepsAnImageOnAnUnmountedVolume() throws {
        let volumes = temporary.appendingPathComponent("Volumes").path
        try FileManager.default.createDirectory(atPath: volumes, withIntermediateDirectories: true)
        let path = volumes + "/Unplugged/art.jpg"
        let library = try library(artwork: [path], volumes: volumes)
        migrate(library, volumes: volumes)
        XCTAssertEqual(library.games[0].artworkPath, path)
    }

    func testMigrationClearsAMissingFileAndKeepsOneItCannotCopyYet() throws {
        let notes = temporary.appendingPathComponent("notes.png")
        try Data("not an image".utf8).write(to: notes)
        let volumes = temporary.appendingPathComponent("Volumes").path
        try FileManager.default.createDirectory(atPath: volumes + "/Mounted", withIntermediateDirectories: true)
        let library = try library(artwork: [volumes + "/Mounted/gone.jpg", notes.path, ""], volumes: volumes)
        migrate(library, volumes: volumes)
        XCTAssertEqual(library.games.map(\.artworkPath), ["", notes.path, ""])   // tried again at the next launch, the banner shows meanwhile
        XCTAssertTrue(FileManager.default.fileExists(atPath: notes.path))
    }

    func testRemovingAGameDeletesItsCopiesOnly() throws {
        let original = try image("mine.jpg", width: 800, height: 450)
        let library = try library(artwork: [original.path, original.path])
        migrate(library)
        let (first, second) = (library.games[0].id, library.games[1].id)
        let firstFolder = ArtworkStore.customDirectory(for: first, in: folder), secondFolder = ArtworkStore.customDirectory(for: second, in: folder)
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstFolder.path))
        library.remove(first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstFolder.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondFolder.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
    }

    func testReplacingOrClearingArtworkDeletesTheOrphanedCopy() throws {
        let library = try library(artwork: [""])
        let id = library.games[0].id, directory = ArtworkStore.customDirectory(for: id, in: folder)
        let old = try ArtworkImport.prepare(image("old.jpg", width: 800, height: 450), kind: .hero, into: directory).url
        func hero(_ url: URL) -> GameArtwork { GameArtwork(hero: ArtworkChoice(source: .imported(url.lastPathComponent))) }
        library.setArtwork(hero(old), for: id)
        library.setArtwork(hero(old), for: id)   // the same copy again keeps it
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path))
        let new = try ArtworkImport.prepare(image("new.jpg", width: 800, height: 400), kind: .hero, into: directory).url   // made now: setArtwork sweeps what no slot uses
        library.setArtwork(hero(new), for: id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: new.path))
        library.setArtwork(GameArtwork(), for: id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: new.path))
    }

    func testAnImageAnySlotUsesIsKeptAndOtherGamesFoldersAreNotTouched() throws {
        let library = try library(artwork: ["", ""])
        let (id, other) = (library.games[0].id, library.games[1].id)
        let directory = ArtworkStore.customDirectory(for: id, in: folder), otherDirectory = ArtworkStore.customDirectory(for: other, in: folder)
        let hero = try ArtworkImport.prepare(image("hero.jpg", width: 800, height: 450), kind: .hero, into: directory).url
        let thumbnail = try ArtworkImport.prepare(image("thumbnail.jpg", width: 800, height: 400), kind: .thumbnail, into: directory).url
        let kept = try ArtworkImport.prepare(image("kept.jpg", width: 800, height: 300), kind: .hero, into: otherDirectory).url
        let outside = try image("outside.jpg", width: 800, height: 450)   // not ours: never deleted
        library.setArtwork(GameArtwork(hero: ArtworkChoice(source: .imported(hero.lastPathComponent)),
                                       thumbnail: ArtworkChoice(source: .imported(thumbnail.lastPathComponent))), for: id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: hero.path) && FileManager.default.fileExists(atPath: thumbnail.path))
        library.setArtwork(GameArtwork(thumbnail: ArtworkChoice(source: .imported(thumbnail.lastPathComponent))), for: id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: hero.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: thumbnail.path))
        library.setArtwork(GameArtwork(), for: id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: thumbnail.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }
}
