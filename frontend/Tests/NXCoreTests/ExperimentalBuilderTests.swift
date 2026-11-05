import XCTest
@testable import NXCore

/// `ExperimentalBuilder` (#749): which nxb the build takes and what it passes. Paths are strings checked by stand-in closures, nothing is run.
final class ExperimentalBuilderTests: XCTestCase {
    private let app = "/Applications/NX2Apple.app/Contents/Resources/nxbuild/nxb"

    func testAChosenFileOrFolderNamesTheNxbBinary() {
        XCTAssertEqual(ExperimentalBuilder.binary(at: "/opt/nxbuild/nxb", isDirectory: { _ in false }), "/opt/nxbuild/nxb")
        XCTAssertEqual(ExperimentalBuilder.binary(at: "/opt/nxbuild", isDirectory: { $0 == "/opt/nxbuild" }), "/opt/nxbuild/nxb")
        XCTAssertEqual(ExperimentalBuilder.binary(at: "", isDirectory: { _ in true }), "")
        XCTAssertEqual(ExperimentalBuilder.binary(at: "~/nxb", isDirectory: { _ in false }), NSHomeDirectory() + "/nxb")
    }

    func testTheAppsCopyIsInResources() {
        XCTAssertEqual(ExperimentalBuilder.bundled(resources: "/Applications/NX2Apple.app/Contents/Resources"), app)
        XCTAssertNil(ExperimentalBuilder.bundled(resources: nil))
    }

    func testTheChosenPathWinsAndIsNeverSwappedForTheAppsCopy() {
        let ok: (String) -> Bool = { [self.app, "/opt/nxb"].contains($0) }
        XCTAssertEqual(ExperimentalBuilder.resolve(customPath: "/opt/nxb", bundled: app, isExecutable: ok, isDirectory: { _ in false }), "/opt/nxb")
        XCTAssertNil(ExperimentalBuilder.resolve(customPath: "/gone/nxb", bundled: app, isExecutable: ok, isDirectory: { _ in false }),
                     "a chosen path that does not work is reported, not replaced")
        XCTAssertEqual(ExperimentalBuilder.resolve(customPath: "", bundled: app, isExecutable: ok, isDirectory: { _ in false }), app)
        XCTAssertNil(ExperimentalBuilder.resolve(customPath: "", bundled: app, isExecutable: { _ in false }, isDirectory: { _ in false }),
                     "an app built without a pinned release has no copy")
    }

    func testTheBuildGetsTheSwitchAndThePath() {
        XCTAssertEqual(ExperimentalBuilder.environment(nxb: "/opt/nxb"), ["DM_EXPERIMENTAL_BUILDER": "1", "NXB_BIN": "/opt/nxb"])
    }
}
