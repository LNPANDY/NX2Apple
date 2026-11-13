import XCTest
@testable import ShellHost

final class ShellSigningIdentityTests: XCTestCase {
    func testImportedIdentityReadIsBoundedAndRejectsNonFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("identity.p12")
        try Data([1, 2, 3]).write(to: file)
        XCTAssertEqual(try ShellSigningIdentityStore.readImportedFile(file, maximumBytes: 3), Data([1, 2, 3]))
        XCTAssertThrowsError(try ShellSigningIdentityStore.readImportedFile(file, maximumBytes: 2))
        try Data().write(to: file)
        XCTAssertThrowsError(try ShellSigningIdentityStore.readImportedFile(file, maximumBytes: 3))
        XCTAssertThrowsError(try ShellSigningIdentityStore.readImportedFile(directory, maximumBytes: 3))
        XCTAssertThrowsError(try ShellSigningIdentityStore.readImportedFile(file, maximumBytes: Int.max))
    }

    func testMissingIdentityCannotSign() {
        let store = ShellSigningIdentityStore(bundleID: "test.shell." + UUID().uuidString)
        XCTAssertThrowsError(try store.sign(framework: URL(fileURLWithPath: "/unused"), expectedTeamID: "TESTTEAM01"))
    }
}
