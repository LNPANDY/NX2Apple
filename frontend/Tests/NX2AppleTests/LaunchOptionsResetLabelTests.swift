import XCTest
@testable import NX2Apple
@testable import NXCore
@testable import NXLauncher

/// The reset button of a launch option row names the setting it resets (#591).
final class LaunchOptionsResetLabelTests: IsolatedDefaultsTestCase {
    @MainActor func testResetLabelNamesTheSetting() {
        let loc = LauncherStores(defaults: testDefaults).localizer
        let action = loc.t("launch.rowReset")
        XCTAssertFalse(action.isEmpty)
        XCTAssertNotEqual(action, "launch.rowReset", "the key has a text")
        XCTAssertEqual(LaunchOptionsView.resetLabel(loc, "Render scale"), action + ": Render scale")
        XCTAssertNotEqual(LaunchOptionsView.resetLabel(loc, "Render scale"), LaunchOptionsView.resetLabel(loc, "Frame rate"),
                          "two rows must not read the same")
    }
}
