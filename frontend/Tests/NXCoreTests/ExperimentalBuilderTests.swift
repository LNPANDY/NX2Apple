import XCTest
@testable import NXCore

/// `ExperimentalBuilder` (#749): which nxb the build takes and what it passes. Paths are strings checked by stand-in closures, nothing is run.
final class ExperimentalBuilderTests: XCTestCase {
    private let support = "/Users/p/Library/Application Support/NS Port Builder"

    func testAChosenFileOrFolderNamesTheNxbBinary() {
        XCTAssertEqual(ExperimentalBuilder.binary(at: "/opt/nxbuild/nxb", isDirectory: { _ in false }), "/opt/nxbuild/nxb")
        XCTAssertEqual(ExperimentalBuilder.binary(at: "/opt/nxbuild", isDirectory: { $0 == "/opt/nxbuild" }), "/opt/nxbuild/nxb")
        XCTAssertEqual(ExperimentalBuilder.binary(at: "", isDirectory: { _ in true }), "")
        XCTAssertEqual(ExperimentalBuilder.binary(at: "~/nxb", isDirectory: { _ in false }), NSHomeDirectory() + "/nxb")
    }

    func testTheChosenPathWinsAndIsNeverSwappedForAnother() {
        let installed = support + "/nxbuild/0.1.0/nxb"
        let ok: (String) -> Bool = { [installed, "/opt/nxb"].contains($0) }
        let list: (String) -> [String] = { _ in ["0.1.0"] }
        XCTAssertEqual(ExperimentalBuilder.resolve(customPath: "/opt/nxb", support: support, isExecutable: ok, isDirectory: { _ in false }, list: list), "/opt/nxb")
        XCTAssertNil(ExperimentalBuilder.resolve(customPath: "/gone/nxb", support: support, isExecutable: ok, isDirectory: { _ in false }, list: list),
                     "a chosen path that does not work is reported, not replaced by the downloaded release")
        XCTAssertEqual(ExperimentalBuilder.resolve(customPath: "", support: support, isExecutable: ok, isDirectory: { _ in false }, list: list), installed)
    }

    func testTheNewestDownloadedReleaseIsTaken() {
        let folder = ExperimentalBuilder.installFolder(support: support)
        XCTAssertEqual(folder, support + "/nxbuild")
        let have = Set(["0.2.0", "0.10.0", "0.9.1"].map { folder + "/" + $0 + "/nxb" })
        let nxb = ExperimentalBuilder.resolve(customPath: "", support: support, isExecutable: { have.contains($0) }, isDirectory: { _ in false },
                                              list: { _ in ["0.2.0", "0.10.0", "0.9.1", "notes.txt"] })
        XCTAssertEqual(nxb, folder + "/0.10.0/nxb", "versions compare as numbers")
        XCTAssertNil(ExperimentalBuilder.resolve(customPath: "", support: support, isExecutable: { _ in false }, isDirectory: { _ in false }, list: { _ in [] }))
    }

    func testTheBuildGetsTheSwitchAndThePath() {
        XCTAssertEqual(ExperimentalBuilder.environment(nxb: "/opt/nxb"), ["DM_EXPERIMENTAL_BUILDER": "1", "NXB_BIN": "/opt/nxb"])
    }

    func testNoReleaseIsPinnedYetAndADownloadIsOnlyTakenWithItsDigest() {
        XCTAssertNil(ExperimentalBuilder.releaseURL, "no nxbuild release is published yet: nothing is downloaded")
        XCTAssertNil(ExperimentalBuilder.releaseSHA256)
        let digest = String(repeating: "ab", count: 32)
        XCTAssertFalse(ExperimentalBuilder.matchesRelease(sha256: digest), "without a pinned digest nothing matches")
        XCTAssertTrue(ExperimentalBuilder.matchesRelease(sha256: digest.uppercased(), expected: digest))
        XCTAssertFalse(ExperimentalBuilder.matchesRelease(sha256: String(repeating: "cd", count: 32), expected: digest))
        XCTAssertFalse(ExperimentalBuilder.matchesRelease(sha256: "ab", expected: "ab"), "a digest is 64 hex digits")
    }
}
