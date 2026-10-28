import XCTest
@testable import NSPortBuilder

/// A failed dependency install must say why and what to type — the report that motivated this
/// showed a spinner turning back into a button with the reason buried in the log.
final class DependencyFailureTests: XCTestCase {
    func testABrewPermissionProblemNamesTheChownCommand() {
        let (error, fix) = BuildModel.failureInfo([
            "Error: ", "/opt/homebrew is not writable. You should change the",
            "ownership and permissions of /opt/homebrew back to your",
            "user account:", "  sudo chown -R junli /opt/homebrew",
            "Error: Permission denied @ dir_initialize - /opt/homebrew/Library/Taps"])
        XCTAssertTrue(error.hasPrefix("Error:"))
        XCTAssertEqual(fix, "dep.fix.brewOwner")
    }

    func testAMissingBrewSaysWhereToInstallIt() {
        XCTAssertEqual(BuildModel.failureInfo(["/bin/bash: line 1: brew: command not found"]).fix, "dep.fix.brewMissing")
    }

    func testTheXcodeLicenseIsNamed() {
        XCTAssertEqual(BuildModel.failureInfo(["Error: You have not agreed to the Xcode license."]).fix, "dep.fix.xcodeLicense")
    }

    func testANetworkFailureIsNamed() {
        XCTAssertEqual(BuildModel.failureInfo(["curl: (6) Could not resolve host: github.com"]).fix, "dep.fix.network")
    }

    func testAnUnknownFailurePointsAtTheLog() {
        let (error, fix) = BuildModel.failureInfo(["something odd happened", "still odd"])
        XCTAssertEqual(fix, "dep.fix.log")
        XCTAssertFalse(error.isEmpty)
    }

    func testEveryFixHintHasBothLanguages() {
        for key in ["dep.fix.brewOwner", "dep.fix.brewMissing", "dep.fix.xcodeLicense", "dep.fix.network", "dep.fix.log"] {
            let row = L10n.table[key]
            XCTAssertNotNil(row, key)
            XCTAssertFalse(row?.0.isEmpty ?? true, key)
            XCTAssertFalse(row?.1.isEmpty ?? true, key)
            XCTAssertNotEqual(row?.0, row?.1, "\(key) has the English text twice")
        }
    }
}
