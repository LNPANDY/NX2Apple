import XCTest
import ShellUI
@testable import ShellControllers

final class PadMappingTests: XCTestCase {
    func testButtonsMapLikeTheMacConsole() {
        XCTAssertEqual(PadMapper.action(for: .a), .activate)
        XCTAssertEqual(PadMapper.action(for: .b), .back)
        XCTAssertEqual(PadMapper.action(for: .x), .settings)
        XCTAssertEqual(PadMapper.action(for: .menu), .settings)
        XCTAssertEqual(PadMapper.action(for: .y), .controllers)
        XCTAssertNil(PadMapper.action(for: .leftShoulder))
    }
    func testDeadzoneAndStrongerAxis() {
        XCTAssertNil(PadMapper.direction(x: 0.4, y: -0.3))
        XCTAssertEqual(PadMapper.direction(x: 0.8, y: 0.6), .right)
        XCTAssertEqual(PadMapper.direction(x: -0.2, y: 0.9), .up)
        XCTAssertEqual(PadMapper.direction(x: 0.1, y: -0.7), .down)
        XCTAssertEqual(PadMapper.direction(x: -0.51, y: 0), .left)
    }
    func testOnePressOneActionPerController() {
        var mapper = PadMapper()
        XCTAssertEqual(mapper.changes(controller: "one", state: PadState(buttons: [.a])).pressed, [.activate])
        XCTAssertEqual(mapper.changes(controller: "one", state: PadState(buttons: [.a])).pressed, [], "held is not pressed again")
        XCTAssertEqual(mapper.changes(controller: "two", state: PadState(buttons: [.a])).pressed, [.activate], "another controller counts on its own")
        XCTAssertEqual(mapper.changes(controller: "one", state: PadState()).pressed, [])
        XCTAssertEqual(mapper.changes(controller: "one", state: PadState(buttons: [.a])).pressed, [.activate])
    }
    func testDirectionPressAndRelease() {
        var mapper = PadMapper()
        XCTAssertEqual(mapper.changes(controller: "one", state: PadState(x: 1)).pressed, [.right])
        let released = mapper.changes(controller: "one", state: PadState(x: 0))
        XCTAssertEqual(released.released, [.right])
        mapper.reset(controller: "one")
        XCTAssertEqual(mapper.changes(controller: "one", state: PadState(x: 1)).pressed, [.right])
    }
    func testRepeatTiming() {
        XCTAssertEqual(RepeatTiming.moves(heldFor: 0.2), 1)
        XCTAssertEqual(RepeatTiming.moves(heldFor: 0.4), 2)
        XCTAssertEqual(RepeatTiming.moves(heldFor: 0.52), 3)
        XCTAssertEqual(RepeatTiming.moves(heldFor: 1.0), 7)
    }
    func testFamiliesFromProductCategory() {
        XCTAssertEqual(ControllerFamily(productCategory: "DualSense"), .playStation)
        XCTAssertEqual(ControllerFamily(productCategory: "DualShock 4"), .playStation)
        XCTAssertEqual(ControllerFamily(productCategory: "Xbox One"), .xbox)
        XCTAssertEqual(ControllerFamily(productCategory: "Switch Pro Controller"), .nintendo)
        XCTAssertEqual(ControllerFamily(productCategory: "Nintendo Switch JoyCon (L/R)"), .nintendo)
        XCTAssertEqual(ControllerFamily(productCategory: "MFi"), .neutral)
        XCTAssertEqual(ControllerFamily(productCategory: nil), .neutral)
    }
}
