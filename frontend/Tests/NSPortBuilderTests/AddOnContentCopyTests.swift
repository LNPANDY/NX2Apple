import XCTest
@testable import NSPortBuilder

/// The slim default leaves DLC images in the work folder, and the archive step copies them into the game folder
/// whichever way it ends (issue #202). The copy is one helper, so this drives it with a stale destination.
final class AddOnContentCopyTests: XCTestCase {
    func testCopiesTheImagesAndReplacesAStaleFolder() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("nxnative-aoc-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let work = root.appendingPathComponent("work/aoc"), dest = root.appendingPathComponent("games/id/aoc")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        try Data([2]).write(to: work.appendingPathComponent("2.img"))
        try Data([9]).write(to: dest.appendingPathComponent("1.img"))   // from an earlier build
        XCTAssertEqual(BuildModel.copyAddOnContent(from: work.path, to: dest.path), 1)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: dest.path), ["2.img"])
    }

    func testNoDLCLeavesTheDestinationAlone() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("nxnative-aoc-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let dest = root.appendingPathComponent("aoc")
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        XCTAssertEqual(BuildModel.copyAddOnContent(from: root.appendingPathComponent("none").path, to: dest.path), 0)
        XCTAssertTrue(fm.fileExists(atPath: dest.path))
    }
}
