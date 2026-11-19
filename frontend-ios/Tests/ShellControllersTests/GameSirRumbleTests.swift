import XCTest
@testable import ShellControllers

final class GameSirRumbleTests: XCTestCase {
    func testGripAmplitudesAndExplicitStop() {
        var motors = GameSirMotorOutput()
        for (left, right): (UInt8, UInt8) in [(255, 0), (0, 255), (128, 63), (0, 0)] {
            motors.set(left: left, right: right)
            XCTAssertEqual(motors.writeNext {
                XCTAssertEqual(Array($0), [4, left, 1, right, 1, 0, 0, 0, 0])
                return $0.count
            }, 9)
            XCTAssertTrue(motors.delivered)
            XCTAssertEqual(motors.writeNext { _ in XCTFail("Duplicate frame"); return -1 }, 0)
        }
    }

    func testStopAfterPartialWritePreservesReportBoundaries() {
        var motors = GameSirMotorOutput()
        var bytes = [UInt8]()
        motors.set(left: 101, right: 23)
        XCTAssertEqual(motors.writeNext { bytes += $0.prefix(3); return 3 }, 3)
        motors.set(left: 1, right: 255)
        XCTAssertEqual(motors.writeNext { _ in 0 }, 0)
        motors.set(left: 0, right: 0)
        while !motors.delivered {
            XCTAssertGreaterThan(motors.writeNext { bytes += $0; return $0.count }, 0)
        }
        XCTAssertEqual(bytes, [4, 101, 1, 23, 1, 0, 0, 0, 0, 4, 0, 1, 0, 1, 0, 0, 0, 0])
    }

    func testFailedWriteDoesNotAcknowledgeOrReplayAnUnstartedPulse() {
        var motors = GameSirMotorOutput()
        motors.set(left: 155, right: 95)
        XCTAssertEqual(motors.writeNext { _ in -1 }, -1)
        XCTAssertFalse(motors.delivered)
        motors.set(left: 0, right: 0)
        XCTAssertEqual(motors.writeNext {
            XCTAssertEqual(Array($0), [4, 0, 1, 0, 1, 0, 0, 0, 0])
            return $0.count
        }, 9)
    }
}
