import XCTest
@testable import NSPortBuilder

final class ShellMirrorTests: XCTestCase {
    private let id = "0100A00019DE0000"
    private var tmp = ""

    override func setUpWithError() throws {
        tmp = NSHomeDirectory() + "/.nspb-mirror-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(atPath: tmp) }

    private func makeFramework() throws -> String {
        let fw = tmp + "/fw/DmGame\(id).framework"
        try FileManager.default.createDirectory(atPath: fw + "/inside", withIntermediateDirectories: true)
        try "x".write(toFile: fw + "/inside/f", atomically: true, encoding: .utf8)
        return fw
    }

    func testMirrorIsACopyThatLaterWritesDoNotReach() throws {
        let fw = try makeFramework()
        XCTAssertEqual(ShellInstall.titleID(ofFramework: fw), id)
        try ShellInstall.mirrorFramework(framework: fw, root: tmp)
        let mirror = ShellInstall.mirroredFramework(root: tmp, titleID: id)
        XCTAssertEqual(try String(contentsOfFile: mirror + "/inside/f"), "x")
        // an overwrite in place and a new file in the build folder stay out of the mirror
        try "changed".write(toFile: fw + "/inside/f", atomically: false, encoding: .utf8)
        try "new".write(toFile: fw + "/inside/g", atomically: true, encoding: .utf8)
        XCTAssertEqual(try String(contentsOfFile: mirror + "/inside/f"), "x")
        XCTAssertFalse(FileManager.default.fileExists(atPath: mirror + "/inside/g"))
        // not a hard link: the file is another inode
        let a = try FileManager.default.attributesOfItem(atPath: fw + "/inside/f")[.systemFileNumber] as? Int
        let b = try FileManager.default.attributesOfItem(atPath: mirror + "/inside/f")[.systemFileNumber] as? Int
        XCTAssertNotEqual(a, b)
    }

    func testMirrorAgainReplacesThePreviousMirror() throws {
        let fw = try makeFramework()
        try ShellInstall.mirrorFramework(framework: fw, root: tmp)
        try "changed".write(toFile: fw + "/inside/f", atomically: false, encoding: .utf8)
        try ShellInstall.mirrorFramework(framework: fw, root: tmp)
        XCTAssertEqual(try String(contentsOfFile: ShellInstall.mirroredFramework(root: tmp, titleID: id) + "/inside/f"), "changed")
    }

    func testMirrorOfAMissingFrameworkThrowsAndLeavesNothing() throws {
        XCTAssertThrowsError(try ShellInstall.mirrorFramework(framework: tmp + "/none/DmGame\(id).framework", root: tmp))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ShellInstall.mirroredFramework(root: tmp, titleID: id)))
    }

    func testDropMissingChecksTheOnePath() throws {
        var lib = ShellLibrary()
        lib.add(.init(titleID: id, name: "Test", framework: tmp + "/gone.framework"))
        lib.add(.init(titleID: "B", name: "Kept", framework: tmp))
        lib.dropMissing()
        XCTAssertEqual(lib.games.map(\.titleID), ["B"])
    }
}
