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

    func testNxbBuildGetsTheScriptsOptionsAndTheEngine() {
        let args = ExperimentalBuilder.buildArguments(inputDir: "/g", keys: "/k/prod.keys", titleID: "010015100B514000", out: "/o/W.app", workDir: "/o/w", engine: "/e")
        XCTAssertEqual(args.first, "build", "the one nxb binary: its subcommand")
        for pair in [["--platform", "mac-app"], ["-k", "/k/prod.keys"], ["--title-id", "010015100B514000"], ["-o", "/o/W.app"], ["--work-dir", "/o/w"], ["--engine", "/e"], ["--progress", "json"]] {
            XCTAssertEqual(args[args.firstIndex(of: pair[0])! + 1], pair[1], pair[0])
        }
        XCTAssertEqual(ExperimentalBuilder.environment(engine: "/e"), ["NXB_ENGINE": "/e"])
    }

    func testWhatNxbBuildDoesNotTake() {
        func key(mac: Bool = true, folder: Bool = false, compressed: Bool = false, card: Bool = false, dlc: Bool = false) -> String? {
            ExperimentalBuilder.unsupportedKey(mac: mac, gameFolder: folder, compressed: compressed, card: card, dlc: dlc)
        }
        XCTAssertNil(key())
        XCTAssertEqual(key(mac: false), "nxb.unsupported.target")
        XCTAssertEqual(key(folder: true), "nxb.unsupported.input")
        XCTAssertEqual(key(compressed: true), "nxb.unsupported.input")
        XCTAssertEqual(key(card: true), "nxb.unsupported.input")
        XCTAssertEqual(key(dlc: true), "nxb.unsupported.dlc")
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
