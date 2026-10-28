import XCTest
@testable import NSPortBuilder

/// An App Store download that was never opened leaves `xcode-select -p` on CommandLineTools.
/// The Xcode row has to say that, and offer the one-click switch, instead of "no iOS SDK".
final class XcodeStateTests: XCTestCase {
    func testXcodeSelectedWithTheSDKIsReady() {
        XCTAssertEqual(BuildModel.xcodeState(selected: "/Applications/Xcode.app/Contents/Developer",
                                             xcodeApp: "/Applications/Xcode.app", iosSDK: true), .ready)
    }

    func testXcodeSelectedWithoutTheIOSPlatformAsksForTheDownload() {
        XCTAssertEqual(BuildModel.xcodeState(selected: "/Applications/Xcode.app/Contents/Developer",
                                             xcodeApp: "/Applications/Xcode.app", iosSDK: false),
                       .noIOSSDK(selected: "/Applications/Xcode.app/Contents/Developer"))
    }

    func testCommandLineToolsSelectedWhileXcodeIsInstalledIsItsOwnState() {
        XCTAssertEqual(BuildModel.xcodeState(selected: "/Library/Developer/CommandLineTools",
                                             xcodeApp: "/Applications/Xcode.app", iosSDK: false),
                       .commandLineToolsOnly(xcode: "/Applications/Xcode.app"))
    }

    func testNothingInstalled() {
        XCTAssertEqual(BuildModel.xcodeState(selected: nil, xcodeApp: nil, iosSDK: false), .notInstalled)
    }

    func testACommandLineToolsThatAnswersTheSDKIsUsable() {
        XCTAssertEqual(BuildModel.xcodeState(selected: "/Library/Developer/CommandLineTools",
                                             xcodeApp: nil, iosSDK: true), .ready)
    }

    func testTheTwoXcodeStringsHaveBothLanguages() {
        for key in ["dep.xcode.notSelected", "dep.xcode.fix"] {
            let row = L10n.table[key]
            XCTAssertNotNil(row, key)
            XCTAssertFalse(row?.0.isEmpty ?? true, key)
            XCTAssertFalse(row?.1.isEmpty ?? true, key)
            XCTAssertNotEqual(row?.0, row?.1, "\(key) has the English text twice")
        }
    }
}
