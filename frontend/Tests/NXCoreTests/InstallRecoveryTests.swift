import XCTest
@testable import NXCore

final class InstallRecoveryTests: XCTestCase {
    func testDeveloperModeDisabledHasItsOwnFailureBeforeAccountDiagnosis() {
        for step in [BuildFailureClassifier.InstallStep.sign, .install, .copy] {
            for listed in [false, true] {
                for error in ["Developer Mode disabledTo use this device for development, enable Developer Mode in Settings → Privacy & Security.",
                              "Developer Mode is disabled", "Developer Mode is not enabled"] {
                    XCTAssertEqual(BuildFailureClassifier.classifyInstall(step, error: error, teamListed: listed)?.kind, .developerMode)
                }
            }
        }
    }

    func testEnabledDeveloperModeDoesNotHideAnUnrelatedSigningError() {
        XCTAssertNil(BuildFailureClassifier.classifyInstall(.sign, error: "Developer Mode enabled. Unknown signing error", teamListed: true))
    }
}
