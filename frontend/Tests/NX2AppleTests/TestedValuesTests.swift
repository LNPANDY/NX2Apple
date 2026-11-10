import XCTest
@testable import NX2Apple
@testable import NXCore

/// #453: the settings that differ from the game profile's tested default, the dot's test and what Use tested values counts.
final class TestedValuesTests: XCTestCase {
    private func setting(_ env: String, kind: String, def: String) -> LaunchSetting {
        LaunchSetting(env: env, kind: kind, label: env, note: "", def: def, section: "Game", options: nil, min: 0.5, max: 1.5, step: 0.05, on: nil, off: nil)
    }

    func testOnlyValuesThatDifferFromTheTestedDefaultCount() {
        let settings = [setting("DM_RUMBLE", kind: "toggle", def: "1"), setting("DM_RENDER_SCALE", kind: "range", def: "1.0"),
                        setting("DM_OPMODE", kind: "choice", def: "1")]
        let values = ["DM_RUMBLE": "0", "DM_RENDER_SCALE": "1.00", "DM_OPMODE": "1"]
        XCTAssertEqual(LaunchOptionsView.changed(settings) { values[$0.env] ?? $0.def }.map(\.env), ["DM_RUMBLE"],
                       "a slider's 1.00 is the tested 1.0")
        XCTAssertTrue(LaunchOptionsView.changed(settings) { $0.def }.isEmpty, "all tested: no dot and no action")
    }

    func testTheTextsSayHowManyChangeAndHaveNoSemicolons() {
        for lang in [Lang.en, Lang("de"), Lang.zh] {
            for key in ["launch.useTested", "launch.useTestedOne", "launch.useTestedMany", "launch.changedDot"] {
                let text = L10n.string(key, lang)
                XCTAssertNotEqual(text, key, "\(lang.code) \(key)")
                XCTAssertFalse(text.contains(";") || text.contains("；"), "\(lang.code) \(key)")
            }
        }
        XCTAssertEqual(String(format: L10n.string("launch.useTestedMany", .en), 3), "3 settings change back to their tested values.")
    }
}
