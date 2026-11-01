import XCTest
@testable import NSPortBuilder

final class ShellMirrorTests: XCTestCase {
    func testMirrorLinksAndStandsIn() throws {
        let tmp = NSHomeDirectory() + "/.nspb-mirror-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmp + "/fw", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let fw = tmp + "/fw/DmGame0100A00019DE0000.framework"
        try FileManager.default.createDirectory(atPath: fw + "/inside", withIntermediateDirectories: true)
        try "x".write(toFile: fw + "/inside/f", atomically: true, encoding: .utf8)
        XCTAssertEqual(ShellInstall.titleID(ofFramework: fw), "0100A00019DE0000")
        try ShellInstall.mirrorFramework(framework: fw, root: tmp)
        let mirror = ShellInstall.mirroredFramework(root: tmp, titleID: "0100A00019DE0000")
        XCTAssertTrue(FileManager.default.fileExists(atPath: mirror))
        // 重镜像：删除原 framework 后重新链接不报错
        try ShellInstall.mirrorFramework(framework: fw, root: tmp)
        // dropMissing 的镜像回退：原路径没了，镜像顶上
        var lib = ShellLibrary()
        lib.add(.init(titleID: "0100A00019DE0000", name: "Test", framework: fw))
        try FileManager.default.removeItem(atPath: fw)
        lib.dropMissing(mirror: { g in
            let m = ShellInstall.mirroredFramework(root: tmp, titleID: g.titleID)
            return FileManager.default.fileExists(atPath: m) ? m : nil
        })
        XCTAssertEqual(lib.games.count, 1)
        XCTAssertEqual(lib.games[0].framework, mirror)
        // 无镜像时才真正剔除
        try FileManager.default.removeItem(atPath: mirror)
        lib.dropMissing(mirror: { _ in nil })
        XCTAssertEqual(lib.games.count, 0)
    }
}
