import Foundation
import XCTest
@testable import NXCore

final class SeenShadersProfileTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("seen-shaders-core-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        SeenShadersProfile.clearCacheForTesting()
    }

    override func tearDownWithError() throws {
        SeenShadersProfile.clearCacheForTesting()
        try? FileManager.default.removeItem(at: tmp)
    }

    private func writeProfile(titleID: String, gameTSV: String, seen: String, map: String) throws {
        let dir = tmp.appendingPathComponent("dm/games/\(titleID)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try gameTSV.write(to: dir.appendingPathComponent("game.tsv"), atomically: true, encoding: .utf8)
        try seen.write(to: dir.appendingPathComponent("shader_seen.tsv"), atomically: true, encoding: .utf8)
        try map.write(to: dir.appendingPathComponent("shader_map.tsv"), atomically: true, encoding: .utf8)
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
        XCTAssertTrue(RepoLayout.supportsIOSSeenShaders(repoRoot.path))
        let pokopia = try XCTUnwrap(SeenShadersProfile.inspect(titleID: "0400a3a01ee4c000", engineRoot: engineRoot))
        XCTAssertTrue(pokopia.supportsIOS)
        XCTAssertGreaterThan(pokopia.seenCount, 8000)
        XCTAssertGreaterThan(pokopia.totalCount, 130000)
        XCTAssertGreaterThan(pokopia.totalCount, pokopia.seenCount)
        XCTAssertEqual(SeenShadersProfile.cached(titleID: "0400A3A01EE4C000", engineRoot: engineRoot), pokopia)

        // Civilization VII has 100% coverage in shader_seen.tsv (482/482), so the toggle offers no speed-up.
        XCTAssertNil(SeenShadersProfile.inspect(titleID: "0100C3601518C000", engineRoot: engineRoot))
    }

    func testRejectsMissingNonNVNEmptyAndInvalidatesCacheOnChange() throws {
        let tid = "0400123456789000"
        let gdir = tmp.appendingPathComponent("dm/games/\(tid)", isDirectory: true)
        try FileManager.default.createDirectory(at: gdir, withIntermediateDirectories: true)

        // Missing files returns nil and is never cached.
        XCTAssertFalse(SeenShadersProfile.hasSeenList(titleID: tid, engineRoot: tmp.path))
        XCTAssertNil(SeenShadersProfile.inspect(titleID: tid, engineRoot: tmp.path))

        let seenURL = gdir.appendingPathComponent("shader_seen.tsv")
        let mapURL = gdir.appendingPathComponent("shader_map.tsv")
        let gameURL = gdir.appendingPathComponent("game.tsv")

        try "# seen\n0123456789abcdef\tpixel\nfedcba9876543210\tvertex\n0123456789abcdef\tpixel\n".write(to: seenURL, atomically: true, encoding: .utf8)
        try "# map\nrow1\nrow2\nrow3\nrow4\nrow5\n".write(to: mapURL, atomically: true, encoding: .utf8)
        try "title_id\t\(tid)\n".write(to: gameURL, atomically: true, encoding: .utf8)

        let info = try XCTUnwrap(SeenShadersProfile.inspect(titleID: tid, engineRoot: tmp.path))
        XCTAssertEqual(info, SeenShadersInfo(seenCount: 2, totalCount: 5))
        XCTAssertEqual(SeenShadersProfile.cached(titleID: tid, engineRoot: tmp.path), info)

        // Updating shader_seen.tsv invalidates the cached entry via size/mtime key.
        try "# seen\n0123456789abcdef\tpixel\nfedcba9876543210\tvertex\naabbccddeeff0011\tcompute\n".write(to: seenURL, atomically: true, encoding: .utf8)
        let updated = try XCTUnwrap(SeenShadersProfile.inspect(titleID: tid, engineRoot: tmp.path))
        XCTAssertEqual(updated, SeenShadersInfo(seenCount: 3, totalCount: 5))

        // Non-NVN graphics backend must be rejected (matches build_ipa_from_nsp.py).
        try "title_id\t\(tid)\ngraphics\tvulkan\n".write(to: gameURL, atomically: true, encoding: .utf8)
        XCTAssertNil(SeenShadersProfile.inspect(titleID: tid, engineRoot: tmp.path))

        // Invalid title ID is rejected.
        XCTAssertNil(SeenShadersProfile.inspect(titleID: "not-a-tid", engineRoot: tmp.path))
    }

    func testInspectReadsIOSOptInAndCounts() throws {
        let tid = "0400A3A01EE4C000"
        let seen = "# comment\nkey\tstage\n" + (0..<3).map { String(format: "%016x\tpixel\n", $0 + 1) }.joined()
        let map = "# map\npackage\tindex\tstage\tkey\tsource\n" + (0..<10).map { String(format: "p.bin\t%d\tvs\t%016x\tsrc\n", $0, $0 + 1) }.joined()
        try writeProfile(titleID: tid, gameTSV: "title_id\t\(tid)\nios_seen_shaders\t1\n", seen: seen, map: map)

        let info = SeenShadersProfile.inspect(titleID: tid, engineRoot: tmp.path)
        XCTAssertEqual(info, SeenShadersInfo(seenCount: 3, totalCount: 10, supportsIOS: true))
        XCTAssertEqual(SeenShadersProfile.cached(titleID: tid, engineRoot: tmp.path), info)
    }

    func testNonOptInProfileHasSupportsIOSFalseAndCacheInvalidatesOnGameTSVEdit() throws {
        let tid = "0100111122220000"
        let seen = "key\tstage\n0000000000000001\tpixel\n"
        let map = "package\tindex\tstage\tkey\tsource\np.bin\t0\tvs\t0000000000000001\tsrc\np.bin\t1\tvs\t0000000000000002\tsrc\n"
        try writeProfile(titleID: tid, gameTSV: "title_id\t\(tid)\n", seen: seen, map: map)

        let before = SeenShadersProfile.inspect(titleID: tid, engineRoot: tmp.path)
        XCTAssertEqual(before, SeenShadersInfo(seenCount: 1, totalCount: 2, supportsIOS: false))

        // Update game.tsv with ios_seen_shaders\t1 (changes file size) -> cache must invalidate immediately.
        let gamePath = tmp.appendingPathComponent("dm/games/\(tid)/game.tsv")
        try "title_id\t\(tid)\nios_seen_shaders\t1\n".write(to: gamePath, atomically: true, encoding: .utf8)
        XCTAssertNil(SeenShadersProfile.cached(titleID: tid, engineRoot: tmp.path))
        let after = SeenShadersProfile.inspect(titleID: tid, engineRoot: tmp.path)
        XCTAssertEqual(after, SeenShadersInfo(seenCount: 1, totalCount: 2, supportsIOS: true))
    }

    func testVulkanProfileReturnsNil() throws {
        let tid = "0100555566660000"
        let seen = "0000000000000001\tpixel\n"
        let map = "package\tindex\tstage\tkey\tsource\np.bin\t0\tvs\t0000000000000001\tsrc\np.bin\t1\tvs\t0000000000000002\tsrc\n"
        try writeProfile(titleID: tid, gameTSV: "title_id\t\(tid)\ngraphics\tvulkan\nios_seen_shaders\t1\n", seen: seen, map: map)
        XCTAssertNil(SeenShadersProfile.inspect(titleID: tid, engineRoot: tmp.path))
    }

    func testQueueEntryBackwardCompatibilityForIOSSeenShaders() throws {
        let entry = QueueEntry(
            titleID: "0400A3A01EE4C000",
            name: "Pokemon Pokopia",
            target: BuildTarget.ios,
            inputs: [:],
            outputDirectory: "/tmp/out",
            engineID: "main",
            iosSeenShaders: true
        )
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(QueueEntry.self, from: data)
        XCTAssertEqual(decoded.iosSeenShaders, true)

        // Legacy JSON without iosSeenShaders decodes cleanly as nil.
        var dict = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        dict.removeValue(forKey: "iosSeenShaders")
        let legacyData = try JSONSerialization.data(withJSONObject: dict)
        let legacyDecoded = try JSONDecoder().decode(QueueEntry.self, from: legacyData)
        XCTAssertNil(legacyDecoded.iosSeenShaders)
    }
}
