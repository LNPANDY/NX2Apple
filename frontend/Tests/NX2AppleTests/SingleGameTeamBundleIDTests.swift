import XCTest
@testable import NX2Apple
@testable import NXCore

/// Regression coverage for Issue #1143 Option A across the Mac launcher's single-game IPA export, save discovery, and build failure classifier.
final class SingleGameTeamBundleIDTests: XCTestCase {
    private let titleID = "0100535012974000"

    func testOneGameIPAKeepsGenericUnsignedArgumentsAndEnvironmentWithoutTeamSuffix() {
        let args = OneGameIPA.arguments(ipa: "/tmp/0100535012974000.ipa")
        XCTAssertEqual(args, ["--platform", "ios", "--romfs", "bundle", "-o", "/tmp/0100535012974000.ipa"])
        XCTAssertFalse(args.contains("--team"))
        XCTAssertFalse(args.contains("--bundle-id"))
        XCTAssertEqual(OneGameIPA.environment, ["DM_FULL_ROMFS": "1"])
        XCTAssertNil(OneGameIPA.environment["DM_TEAM_ID"])
        XCTAssertNil(OneGameIPA.environment["DM_BUNDLE_ID"])
    }

    func testSaveDiscoveryMatchesTeamSuffixedSingleGameBundleID() {
        let teamBundle = "org.nxnative.\(titleID.lowercased()).TEAM123456"
        let apps = [
            InstalledApp(bundle: "com.apple.mobilesafari", name: "Safari"),
            InstalledApp(bundle: "org.nxnative.shell.TEAM123456", name: "NX2Apple"),
            InstalledApp(bundle: teamBundle, name: "Hades"),
        ]
        let matched = SaveDiscovery.match(apps, titleID: titleID, name: "Hades", recordedBundle: nil)
        XCTAssertEqual(matched?.bundle, teamBundle)
    }

    func testSigningTeamTakenMatchesBareBundleIDAndIgnoresTeamSuffixedBundleID() {
        let bare = "org.nxnative.\(titleID.lowercased())"
        let teamSuffixed = "\(bare).TEAM123456"
        XCTAssertTrue(BuildFailureClassifier.signingTeamTaken("error: No profiles for '\(bare)' were found"))
        XCTAssertFalse(BuildFailureClassifier.signingTeamTaken("error: No profiles for '\(teamSuffixed)' were found"))
    }
}
