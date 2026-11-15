import Foundation
import XCTest
@testable import NX2Apple
@testable import NXCore
import NXModel

/// Tests for PR A4 Module 4B: scanning orphan `<16-hex>_build` directories at depth 1 and depth 2 across output and library
/// roots, reading game names from `game.tsv` metadata, synthesizing `FreeSpaceView` entries, and safely freeing space.
final class OrphanBuildFilesTests: IsolatedDefaultsTestCase {
    private var temporary: URL!

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("orphan-builds-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporary)
    }

    private func writeKB(_ relativePath: String, in base: URL, kb: Int = 32) throws {
        let target = base.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0xAB, count: kb * 1024).write(to: target)
    }

    @MainActor func testDiscoversDepthOneAndDepthTwoOrphanBuildFoldersWithoutDuplicatingKnownGames() throws {
        let root = temporary.appendingPathComponent("GamesOutput")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // 1. Known library game build folder (must not be duplicated as an orphan)
        let knownTID = "0100535012974000"
        let knownBuild = root.appendingPathComponent("\(knownTID)_build")
        try writeKB("extract/v0/data.bin", in: knownBuild)
        var knownGame = LibraryGame(titleID: knownTID, name: "Hades")
        knownGame.outputDirectory = root.path

        // 2. Depth-1 orphan build folder WITH profile metadata (`game.tsv`)
        let zeldaTID = "01007EF00011E000"
        let zeldaBuild = root.appendingPathComponent("\(zeldaTID)_build")
        try writeKB("extract/v0/rom.bin", in: zeldaBuild, kb: 64)
        try writeKB("logs/build.log", in: zeldaBuild, kb: 4)
        let tsvURL = zeldaBuild.appendingPathComponent("profile/\(zeldaTID)/game.tsv")
        try FileManager.default.createDirectory(at: tsvURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "name\tBreath of the Wild\n".write(to: tsvURL, atomically: true, encoding: .utf8)

        // 3. Depth-2 orphan build folder inside a per-game subfolder (verifies scan does not early-return at depth 1)
        let odysseyTID = "0100000000010000"
        let odysseyBuild = root.appendingPathComponent("SuperMarioSubfolder/\(odysseyTID)_build")
        try writeKB("shader/package.bin", in: odysseyBuild, kb: 48)

        // 4. Invalid `_build` folder names that must be ignored
        try writeKB("extract/x.bin", in: root.appendingPathComponent("NOTHEX0011223344_build"))
        try writeKB("extract/x.bin", in: root.appendingPathComponent("0100ABCD_build"))

        let entries = BuildFiles.games([knownGame], lang: .en, extraRoots: [root.path])
        XCTAssertEqual(entries.count, 3, "expected 1 known game + 2 valid orphan build folders, got \(entries.map(\.name))")

        let zeldaEntry = try XCTUnwrap(entries.first { $0.folder.hasSuffix("\(zeldaTID)_build") })
        XCTAssertTrue(zeldaEntry.name.contains("Breath of the Wild"), zeldaEntry.name)
        XCTAssertTrue(zeldaEntry.name.contains(zeldaTID), zeldaEntry.name)

        let odysseyEntry = try XCTUnwrap(entries.first { $0.folder.hasSuffix("\(odysseyTID)_build") })
        XCTAssertEqual(odysseyEntry.name, "Unlisted build (\(odysseyTID))")

        // Deterministic UUID across repeated scans so SwiftUI row state stays stable
        let entriesAgain = BuildFiles.games([knownGame], lang: .en, extraRoots: [root.path])
        let zeldaAgain = try XCTUnwrap(entriesAgain.first { $0.folder.hasSuffix("\(zeldaTID)_build") })
        XCTAssertEqual(zeldaEntry.id, zeldaAgain.id)

        // Synthesize `LibraryGame` for `Details…` (`FreeSpaceView`) when the orphan is not in `library.games`
        let store = BuildFilesStore(measure: { BuildFiles.measure($0) }, remove: { try BuildFiles.remove($0) })
        store.refresh(entries)
        for _ in 0..<50 {
            if store.entry(zeldaEntry.id) != nil { break }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertNotNil(store.entry(zeldaEntry.id))
        let synthesized = try XCTUnwrap(BuildFiles.freeSpaceGame(id: zeldaEntry.id, in: [knownGame], store: store))
        XCTAssertEqual(synthesized.titleID, zeldaTID)
        XCTAssertEqual(BuildFolder.location(for: synthesized), zeldaEntry.folder)

        // Removing build files frees `extract/` while preserving `logs/` and `profile/`
        let beforeBytes = BuildFiles.measure(zeldaEntry)
        XCTAssertGreaterThan(beforeBytes, 0)
        let freedBytes = try BuildFiles.remove(zeldaEntry)
        XCTAssertGreaterThan(freedBytes, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: zeldaBuild.appendingPathComponent("extract").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: zeldaBuild.appendingPathComponent("logs/build.log").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tsvURL.path))
        XCTAssertEqual(BuildFiles.measure(zeldaEntry), 0)
    }
}
