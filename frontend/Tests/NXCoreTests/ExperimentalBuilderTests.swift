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

    func testNxbBuildGetsTheScriptsOptionsUnchanged() {
        let script = ["/e/scripts/build_ipa_from_nsp.py", "/g", "-k", "/k/prod.keys", "--progress", "json", "--work-dir", "/o/w", "--platform", "mac-app", "-o", "/o/W.app"]
        XCTAssertEqual(ExperimentalBuilder.arguments(fromScript: script), ["build"] + script.dropFirst(), "the one nxb binary: its subcommand in place of the script")
        XCTAssertEqual(ExperimentalBuilder.arguments(fromScript: []), ["build"])
        XCTAssertEqual(ExperimentalBuilder.environment(engine: "/e"), ["NXB_ENGINE": "/e"])
    }

    func testTheVersionThatHasTheWholeCommandLine() {
        XCTAssertTrue(ExperimentalBuilder.isNewEnough("nxb 0.6.3\n"))
        XCTAssertTrue(ExperimentalBuilder.isNewEnough("nxb 0.6.10"))
        XCTAssertTrue(ExperimentalBuilder.isNewEnough("nxb 1.0.0"))
        XCTAssertFalse(ExperimentalBuilder.isNewEnough("nxb 0.6.2"), "stops in the Mac shader step without the own front end's verdicts")
        XCTAssertFalse(ExperimentalBuilder.isNewEnough("nxb 0.6.1"), "reads no engine from NXB_ENGINE or refuses the engine's patch_nso.py")
        XCTAssertFalse(ExperimentalBuilder.isNewEnough("nxb 0.5.1"))
        XCTAssertFalse(ExperimentalBuilder.isNewEnough("nxb 0.4.0"))
        XCTAssertFalse(ExperimentalBuilder.isNewEnough("usage: nxb <command>"), "no version in it")
        XCTAssertFalse(ExperimentalBuilder.isNewEnough(""))
        XCTAssertTrue(ExperimentalBuilder.isNewEnough("nxb 0.5", minimum: "0.5.0"))
    }

    func testEveryExitCodeOfNxbHasItsOwnMessage() {
        XCTAssertEqual([1, 2, 3, 4, 6, 130].map { ExperimentalBuilder.exitKey($0) }, ["nxb.exit.1", "nxb.exit.2", "nxb.exit.3", "nxb.exit.4", "nxb.exit.6", "nxb.exit.130"])
        XCTAssertEqual(ExperimentalBuilder.exitKey(7), "nxb.exit.other")
    }

    func testTheLastErrorLineIsReadFromAnEventOrPlainText() {
        let log = "{\"ev\": \"say\", \"msg\": \"[RED] first\"}\nplain line\n[RED] second one\ntool output\n"
        XCTAssertEqual(ExperimentalBuilder.lastError(in: log), "second one")
        XCTAssertEqual(ExperimentalBuilder.lastError(in: "{\"ev\": \"say\", \"msg\": \"[RED] only\"}\n"), "only")
        XCTAssertNil(ExperimentalBuilder.lastError(in: "all fine\n"))
    }
}
