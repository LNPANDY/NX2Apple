import XCTest
@testable import NSPortBuilder

final class ShellMirrorTests: XCTestCase {
    func testMoveIntoCacheAndFallBack() throws {
        let tmp = NSHomeDirectory() + "/.nspb-mirror-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmp + "/fw", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let fw = tmp + "/fw/DmGame0100A00019DE0000.framework"
        try FileManager.default.createDirectory(atPath: fw + "/inside", withIntermediateDirectories: true)
        try "x".write(toFile: fw + "/inside/f", atomically: true, encoding: .utf8)
        XCTAssertEqual(ShellInstall.titleID(ofFramework: fw), "0100A00019DE0000")
        // The move: the cache holds the only copy, the build path is gone
        try ShellInstall.moveFrameworkIntoCache(framework: fw, root: tmp)
        let cache = ShellInstall.mirroredFramework(root: tmp, titleID: "0100A00019DE0000")
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fw))
        // install's resolution: a missing build path resolves to the cache
        var lib = ShellLibrary()
        lib.add(.init(titleID: "0100A00019DE0000", name: "Test", framework: fw))
        lib.dropMissing(mirror: { g in
            let m = ShellInstall.mirroredFramework(root: tmp, titleID: g.titleID)
            return FileManager.default.fileExists(atPath: m) ? m : nil
        })
        XCTAssertEqual(lib.games.count, 1)
        XCTAssertEqual(lib.games[0].framework, cache)
        // No cache either: the game drops
        try FileManager.default.removeItem(atPath: cache)
        lib.dropMissing(mirror: { _ in nil })
        XCTAssertEqual(lib.games.count, 0)
    }

}
