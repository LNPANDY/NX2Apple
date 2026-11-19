import XCTest
@testable import NX2Apple
@testable import NXCore
@testable import NXLauncher

/// The options panel's value stepper (the console pass of #1458): the thin bar under a continuous value is filled to where the value
/// sits in its range, the chevrons dim at the ends, and a game with one language shows the value without chevrons. The bug was a
/// "100 %" row whose bar stood at a third.
@MainActor final class ConsoleValueStepperTests: XCTestCase {
    private func range(_ env: String, min: Double, max: Double, step: Double, def: String) -> LaunchSetting {
        LaunchSetting(env: env, kind: "range", label: env, note: "", def: def, section: nil, options: nil, min: min, max: max, step: step, on: nil, off: nil)
    }
    private func row(_ setting: LaunchSetting, value: String) -> ConsoleOptionRow {
        ConsoleOptionRow(setting: setting, value: value, label: value, compact: false, lang: .en, scope: "test", editing: false,
                         edit: { _ in }, adjust: { _ in }, set: { _ in })
    }

    func testTheFillIsWhereTheValueSitsInItsRange() {
        XCTAssertEqual(ConsoleValueBar.fillFraction(value: 0, lo: 0, hi: 3), 0)
        XCTAssertEqual(ConsoleValueBar.fillFraction(value: 3, lo: 0, hi: 3), 1)
        XCTAssertEqual(ConsoleValueBar.fillFraction(value: 1.5, lo: 0, hi: 3), 0.5, accuracy: 1e-9)
        XCTAssertEqual(ConsoleValueBar.fillFraction(value: 65, lo: 10, hi: 120), 0.5, accuracy: 1e-9)
        XCTAssertEqual(ConsoleValueBar.fillFraction(value: -4, lo: 0, hi: 3), 0, "below the range: empty")
        XCTAssertEqual(ConsoleValueBar.fillFraction(value: 9, lo: 0, hi: 3), 1, "above the range: full")
        XCTAssertEqual(ConsoleValueBar.fillFraction(value: .nan, lo: 0, hi: 3), 0)
        XCTAssertEqual(ConsoleValueBar.fillFraction(value: 1, lo: 2, hi: 2), 0, "an empty range draws no fill")
    }

    func testOnlyAContinuousRangeHasABarAndItMatchesTheRowsValue() {
        // the render scale (0.5 to 2 in quarters) is a stepper of seven values: no bar, so "100 %" never stands next to a third-full bar
        XCTAssertNil(row(range("DM_RENDER_SCALE", min: 0.5, max: 2, step: 0.25, def: "1"), value: "1").fill)
        let gain = range("DM_RUMBLE_GAIN", min: 0, max: 3, step: 0.1, def: "1")
        for (value, fill) in [("0", 0.0), ("1.5", 0.5), ("3", 1.0), ("0.3", 0.1)] {
            XCTAssertEqual(try XCTUnwrap(row(gain, value: value).fill), fill, accuracy: 1e-9, value)
        }
    }

    func testChevronsDimAtTheEnds() {
        let scale = range("DM_RENDER_SCALE", min: 0.5, max: 2, step: 0.25, def: "1")
        XCTAssertFalse(row(scale, value: "0.5").canStep(-1))
        XCTAssertTrue(row(scale, value: "0.5").canStep(1))
        XCTAssertFalse(row(scale, value: "2").canStep(1))
        XCTAssertTrue(row(scale, value: "1").canStep(-1) && row(scale, value: "1").canStep(1))
        let fps = LaunchSetting(env: "DM_FPS_TARGET", kind: "choice", label: "Frame rate", note: "", def: "60", section: nil,
                                options: [["30", "30"], ["60", "60"]], min: nil, max: nil, step: nil, on: nil, off: nil)
        XCTAssertFalse(row(fps, value: "30").canStep(-1))
        XCTAssertTrue(row(fps, value: "30").canStep(1))
        XCTAssertFalse(row(fps, value: "60").canStep(1))
    }

    func testAGameWithOneLanguageCannotChangeIt() {
        let language = LaunchSetting(env: "DM_LANG", kind: "choice", label: "Game language", note: "", def: "en", section: nil,
                                     options: [["en", "English"]], min: nil, max: nil, step: nil, on: nil, off: nil)
        XCTAssertFalse(row(language, value: "en").canStep(-1))
        XCTAssertFalse(row(language, value: "en").canStep(1))
    }
}
