import XCTest
@testable import NXCore

/// A stale venv below minPython (issue #75) and Pythons managed by mise or asdf (issue #113).
final class PythonVenvTests: XCTestCase {
    private var tmp: URL!
    private var oldVenv = "", oldMise = "", oldAsdf = ""

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("pyvenv-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        oldVenv = Toolchain.venvDir; oldMise = Toolchain.miseDataDir; oldAsdf = Toolchain.asdfDataDir
    }

    override func tearDownWithError() throws {
        Toolchain.venvDir = oldVenv; Toolchain.miseDataDir = oldMise; Toolchain.asdfDataDir = oldAsdf
        try? FileManager.default.removeItem(at: tmp)
    }

    /// A stand-in interpreter that reports `version` and accepts every import probe.
    @discardableResult
    private func stub(_ rel: String, version: String) throws -> String {
        let url = tmp.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\ncase \"$2\" in *sys.version_info*) echo \(version);; esac\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    func testAVenvBelowTheFloorIsNotReturnedAsReady() throws {
        Toolchain.venvDir = tmp.appendingPathComponent("venv").path
        let vpy = try stub("venv/bin/python3", version: "3.9")
        let found = Toolchain.findPython(resources: tmp)
        XCTAssertFalse(found.path == vpy && found.ok, "a 3.9 venv with every package is still too old")
        // With nothing else on the Mac the row reports the old state, not ready.
        let detail = Toolchain.pythonDetail(py: vpy, ok: false)
        XCTAssertTrue(detail.hasPrefix("dep.python.old:3.9:"), detail)
    }

    func testAVenvAtTheFloorIsStillReady() throws {
        Toolchain.venvDir = tmp.appendingPathComponent("venv").path
        let vpy = try stub("venv/bin/python3", version: "3.12")
        let found = Toolchain.findPython(resources: tmp)
        // A system Python with the packages may win on a developer Mac, the venv must not be rejected.
        XCTAssertTrue(found.ok)
        XCTAssertTrue(found.path == vpy || FileManager.default.isExecutableFile(atPath: found.path))
    }

    func testMakeVenvMovesATooOldVenvAside() throws {
        Toolchain.venvDir = tmp.appendingPathComponent("venv").path
        try stub("venv/bin/python3", version: "3.9")
        let base = try stub("base/python3", version: "3.12")
        _ = Toolchain.makeVenv(base: base)
        let names = try FileManager.default.contentsOfDirectory(atPath: tmp.path)
        let aside = names.filter { $0.hasPrefix("venv.old-") }
        XCTAssertEqual(aside.count, 1, "the old venv is renamed, not deleted: \(names)")
        XCTAssertTrue(FileManager.default.isExecutableFile(
            atPath: tmp.appendingPathComponent(aside[0] + "/bin/python3").path))
    }

    func testMakeVenvLeavesAVenvAtTheFloorInPlace() throws {
        Toolchain.venvDir = tmp.appendingPathComponent("venv").path
        let vpy = try stub("venv/bin/python3", version: "3.12")
        _ = Toolchain.makeVenv(base: vpy)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: vpy))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: tmp.path).contains { $0.hasPrefix("venv.old-") })
    }

    func testMiseAndAsdfPythonsAreCandidates() throws {
        Toolchain.miseDataDir = tmp.appendingPathComponent("mise").path
        Toolchain.asdfDataDir = tmp.appendingPathComponent("asdf").path
        let install = try stub("mise/installs/python/3.12.8/bin/python3", version: "3.12")
        let minor = try stub("mise/installs/python/3.12.8/bin/python3.12", version: "3.12")
        let config = try stub("mise/installs/python/3.12.8/bin/python3-config", version: "3.12")
        let shim = try stub("mise/shims/python3", version: "3.12")
        let asdf = try stub("asdf/installs/python/3.13.1/bin/python3", version: "3.13")
        let cands = Toolchain.pythonCandidates()
        for p in [install, minor, shim, asdf] { XCTAssertTrue(cands.contains(p), p) }
        XCTAssertFalse(cands.contains(config), "python3-config is not an interpreter")
    }
}
