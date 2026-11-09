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
}
