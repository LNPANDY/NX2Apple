import XCTest
@testable import NXCore

/// #966: the check before a build compares the game files' size, the least a build needs, with the free space.
final class BuildSpaceTests: XCTestCase {
    func testShortWhenTheFreeSpaceIsBelowTheFilesAlone() {
        XCTAssertTrue(BuildSpace(needed: 10, available: 9).isShort)
        XCTAssertFalse(BuildSpace(needed: 10, available: 10).isShort)
    }

    func testSizeCountsFilesAndFoldersAndIgnoresMissingPaths() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("space-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data(count: 100).write(to: dir.appendingPathComponent("a.bin"))
        try Data(count: 50).write(to: dir.appendingPathComponent("sub/b.bin"))
        XCTAssertEqual(BuildSpace.size(of: [dir.path, dir.appendingPathComponent("a.bin").path, "/nonexistent-\(UUID())", ""]), 250)
    }

    func testAvailableLooksAtTheNearestExistingParent() {
        XCTAssertNotNil(BuildSpace.available(at: NSTemporaryDirectory() + "not-yet/made"))
    }

    /// #1155: macOS answers 0 (or nil) for `volumeAvailableCapacityForImportantUsage` on exFAT external drives,
    /// while `statfs` (`DriveCopy.volume`) reports the drive's real free space.
    func testAvailableFallsBackToStatfsWhenImportantUsageReportsZeroOrNil() {
        let probe = NSTemporaryDirectory() + "not-yet/made"
        XCTAssertEqual(
            BuildSpace.available(at: probe, importantCapacity: { _ in 0 }, fallbackCapacity: { _, _ in 120_000_000_000 }),
            120_000_000_000
        )
        XCTAssertEqual(
            BuildSpace.available(at: probe, importantCapacity: { _ in nil }, fallbackCapacity: { _, _ in 120_000_000_000 }),
            120_000_000_000
        )
        // Truly full volume: both report 0, so 0 is preserved and blocks the build.
        XCTAssertEqual(
            BuildSpace.available(at: probe, importantCapacity: { _ in 0 }, fallbackCapacity: { _, _ in 0 }),
            0
        )
        // Positive important-usage capacity (e.g. APFS with purgeable space) wins without calling fallback.
        XCTAssertEqual(
            BuildSpace.available(at: probe, importantCapacity: { _ in 80_000_000_000 }, fallbackCapacity: { _, _ in 40_000_000_000 }),
            80_000_000_000
        )
        // Unreadable volume on both paths returns nil so preflight skips rather than false-blocking.
        XCTAssertNil(BuildSpace.available(at: probe, importantCapacity: { _ in nil }, fallbackCapacity: { _, _ in nil }))
        XCTAssertNil(BuildSpace.available(at: ""))
    }
}
