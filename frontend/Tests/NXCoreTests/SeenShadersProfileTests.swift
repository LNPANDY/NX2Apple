import Foundation
import XCTest
@testable import NXCore

final class SeenShadersProfileTests: XCTestCase {
    override func setUp() {
        super.setUp()
        SeenShadersProfile.clearCacheForTesting()
    }

    func testInspectsRealEnginePokopiaAndRejectsFullCoverageCivVII() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let engineRoot = EngineLayout.root(repoRoot.path)
        let pokopiaDir = engineRoot + "/dm/games/0400A3A01EE4C000"
        guard FileManager.default.fileExists(atPath: pokopiaDir + "/shader_seen.tsv") else {
            throw XCTSkip("Synced engine/ not available at \(engineRoot)")
        }

        XCTAssertTrue(RepoLayout.supportsSeenShaders(repoRoot.path))
        let pokopia = try XCTUnwrap(SeenShadersProfile.inspect(titleID: "0400a3a01ee4c000", engineRoot: engineRoot))
        XCTAssertGreaterThan(pokopia.seenCount, 1000)
        XCTAssertGreaterThan(pokopia.totalCount, pokopia.seenCount)
        XCTAssertEqual(SeenShadersProfile.cached(titleID: "0400A3A01EE4C000", engineRoot: engineRoot), pokopia)

        // Civilization VII has 100% coverage in shader_seen.tsv (482/482), so the toggle offers no speed-up.
        XCTAssertNil(SeenShadersProfile.inspect(titleID: "0100C3601518C000", engineRoot: engineRoot))
    }

    func testRejectsMissingNonNVNEmptyAndInvalidatesCacheOnChange() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("seen-shaders-core-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let tid = "0400123456789000"
        let gdir = root.appendingPathComponent("dm/games/\(tid)", isDirectory: true)
        try FileManager.default.createDirectory(at: gdir, withIntermediateDirectories: true)

        // Missing files returns nil and is never cached.
        XCTAssertFalse(SeenShadersProfile.hasSeenList(titleID: tid, engineRoot: root.path))
        XCTAssertNil(SeenShadersProfile.inspect(titleID: tid, engineRoot: root.path))

        let seenURL = gdir.appendingPathComponent("shader_seen.tsv")
        let mapURL = gdir.appendingPathComponent("shader_map.tsv")
        let gameURL = gdir.appendingPathComponent("game.tsv")

        try "# seen\n0123456789abcdef\tpixel\nfedcba9876543210\tvertex\n0123456789abcdef\tpixel\n".write(to: seenURL, atomically: true, encoding: .utf8)
        try "# map\nrow1\nrow2\nrow3\nrow4\nrow5\n".write(to: mapURL, atomically: true, encoding: .utf8)
        try "title_id\t\(tid)\n".write(to: gameURL, atomically: true, encoding: .utf8)

        let info = try XCTUnwrap(SeenShadersProfile.inspect(titleID: tid, engineRoot: root.path))
        XCTAssertEqual(info, SeenShadersInfo(seenCount: 2, totalCount: 5))
        XCTAssertEqual(SeenShadersProfile.cached(titleID: tid, engineRoot: root.path), info)

        // Updating shader_seen.tsv invalidates the cached entry via size/mtime key.
        try "# seen\n0123456789abcdef\tpixel\nfedcba9876543210\tvertex\naabbccddeeff0011\tcompute\n".write(to: seenURL, atomically: true, encoding: .utf8)
        let updated = try XCTUnwrap(SeenShadersProfile.inspect(titleID: tid, engineRoot: root.path))
        XCTAssertEqual(updated, SeenShadersInfo(seenCount: 3, totalCount: 5))

        // Non-NVN graphics backend must be rejected (matches build_ipa_from_nsp.py).
        try "title_id\t\(tid)\ngraphics\tvulkan\n".write(to: gameURL, atomically: true, encoding: .utf8)
        XCTAssertNil(SeenShadersProfile.inspect(titleID: tid, engineRoot: root.path))

        // Invalid title ID is rejected.
        XCTAssertNil(SeenShadersProfile.inspect(titleID: "not-a-tid", engineRoot: root.path))
    }
}
