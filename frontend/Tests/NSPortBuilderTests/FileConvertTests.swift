import XCTest
@testable import NSPortBuilder

/// What the converter runs for a file (FileConvert.swift): the kind by extension, the nsz command and
/// the output beside the input. The nsz run itself needs real dumps and is not tested here.
final class FileConvertTests: XCTestCase {
    func testTheKindFollowsTheExtension() {
        XCTAssertEqual(FileConvert.kind(for: "/g/Mario Kart 8 [0100152000022000][v0].nsz"), .decompress)
        XCTAssertEqual(FileConvert.kind(for: "/g/game.xcz"), .decompress)
        XCTAssertEqual(FileConvert.kind(for: "/g/game.nsp"), .compress)
        XCTAssertEqual(FileConvert.kind(for: "/g/game.xci"), .compress)
        XCTAssertNil(FileConvert.kind(for: "/g/game.bin"))
        XCTAssertNil(FileConvert.kind(for: "/g/without-extension"))
    }

    func testTheCommandIsTheBuildsOwnNszInvocation() {
        XCTAssertEqual(FileConvert.command(python: "/py", kind: .decompress, path: "/g/game.nsz"),
                       ["/py", "-m", "nsz", "-D", "/g/game.nsz"])
        XCTAssertEqual(FileConvert.command(python: "/py", kind: .compress, path: "/g/game.nsp"),
                       ["/py", "-m", "nsz", "-C", "/g/game.nsp"])
    }

    func testTheOutputSitsBesideTheInput() {
        XCTAssertEqual(FileConvert.output(for: "/g/game.nsz", kind: .decompress), "/g/game.nsp")
        XCTAssertEqual(FileConvert.output(for: "/g/game.xcz", kind: .decompress), "/g/game.xci")
        XCTAssertEqual(FileConvert.output(for: "/g/game.NSP", kind: .compress), "/g/game.nsz")
    }

    func testThePlanSkipsWhatItCannotConvert() {
        let plan = FileConvert.plan(for: ["/g/a.nsz", "/g/readme.txt", "/g/b.nsp"])
        XCTAssertEqual(plan.map(\.path), ["/g/a.nsz", "/g/b.nsp"])
        XCTAssertEqual(plan.map(\.kind), [.decompress, .compress])
    }
}
