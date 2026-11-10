import XCTest
@testable import NXCore

final class StickDeadzoneTests: XCTestCase {
    func testOffAddsNothingAndKeepsTheEnginesBehaviour() {
        XCTAssertEqual(StickDeadzoneSettings().environment, [:])
        XCTAssertEqual(StickDeadzoneSettings(custom: false, left: 30, right: 12).environment, [:], "values kept while off do nothing")
        XCTAssertTrue(StickDeadzoneSettings().isDefault)
    }

    func testOnWritesOnlyTheSticksThatHaveAValue() {
        XCTAssertEqual(StickDeadzoneSettings(custom: true, left: 15, right: 0).environment, ["DM_STICK_DEADZONE_L": "15"])
        XCTAssertEqual(StickDeadzoneSettings(custom: true, left: 0, right: 7).environment, ["DM_STICK_DEADZONE_R": "7"])
        XCTAssertEqual(StickDeadzoneSettings(custom: true, left: 20, right: 50).environment, ["DM_STICK_DEADZONE_L": "20", "DM_STICK_DEADZONE_R": "50"])
        XCTAssertEqual(StickDeadzoneSettings(custom: true).environment, [:])
    }

    func testValuesStayInZeroToFifty() {
        XCTAssertEqual(StickDeadzoneSettings(custom: true, left: -4, right: 80).left, 0)
        XCTAssertEqual(StickDeadzoneSettings(custom: true, left: -4, right: 80).right, 50)
        XCTAssertEqual(StickDeadzoneSettings.clamp(51), 50)
    }

    /// The same numbers as dm/host/tests/t_stick_deadzone.c, so the preview shows what the engine does.
    func testThePreviewIsTheEnginesRescale() {
        XCTAssertEqual(StickDeadzoneSettings.output(x: 0.3, y: 0.4, percent: 0).x, 0.3, "0 leaves the stick as reported")
        let inside = StickDeadzoneSettings.output(x: 0.1, y: 0.1, percent: 20)
        XCTAssertEqual(inside.x, 0); XCTAssertEqual(inside.y, 0)
        XCTAssertEqual(StickDeadzoneSettings.output(x: 0.5, y: 0, percent: 20).x, 0.375, accuracy: 1e-9)
        let diagonal = StickDeadzoneSettings.output(x: 0.6, y: 0.6, percent: 20)
        XCTAssertEqual(diagonal.x, diagonal.y, accuracy: 1e-9)
        XCTAssertGreaterThan(diagonal.x, 0)
        XCTAssertEqual(StickDeadzoneSettings.output(x: 1, y: 0, percent: 50).x, 1, "full travel stays full")
        XCTAssertEqual(StickDeadzoneSettings.output(x: 1, y: 1, percent: 30).x, 1, "a square corner is not rotated")
    }

    func testRoundTripAsJSON() throws {
        let value = StickDeadzoneSettings(custom: true, left: 12, right: 9)
        XCTAssertEqual(try JSONDecoder().decode(StickDeadzoneSettings.self, from: JSONEncoder().encode(value)), value)
    }
}
