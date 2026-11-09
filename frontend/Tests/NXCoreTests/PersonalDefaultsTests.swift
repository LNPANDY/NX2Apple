import XCTest
@testable import NXCore

final class PersonalDefaultsTests: XCTestCase {
    func testOnlyLanguageDisplayAndRumbleAreKept() {
        var defaults = PersonalDefaults()
        defaults.set("de", for: "DM_LANG")
        defaults.set("1", for: "DM_FULLSCREEN")
        defaults.set("0", for: "DM_RUMBLE")
        defaults.set("0.5", for: "DM_RENDER_SCALE")   // performance is not a personal default
        XCTAssertEqual(defaults.values, ["DM_LANG": "de", "DM_FULLSCREEN": "1", "DM_RUMBLE": "0"])
        XCTAssertEqual(PersonalDefaults(values: ["DM_FPS_TARGET": "30", "DM_LANG": "fr"]).values, ["DM_LANG": "fr"])
    }

    func testAnEmptyValueMeansSystemOrTested() {
        var defaults = PersonalDefaults(values: ["DM_LANG": "de"])
        defaults.set("", for: "DM_LANG")
        XCTAssertTrue(defaults.isEmpty)
    }

    func testRoundTripAndReset() {
        let suite = TestDefaults.make("personal-defaults")
        var defaults = PersonalDefaults(values: ["DM_FULLSCREEN": "1"])
        defaults.save(suite)
        XCTAssertEqual(PersonalDefaults.load(suite), defaults)
        defaults.reset()
        defaults.save(suite)
        XCTAssertNil(suite.object(forKey: PersonalDefaults.defaultsKey))
        XCTAssertTrue(PersonalDefaults.load(suite).isEmpty)
    }
}
