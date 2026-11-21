import XCTest
@testable import NXCore

final class DeviceGPUTests: XCTestCase {
    func testA20ProIPhoneTakesG19p() {
        XCTAssertEqual(DeviceGPU.target(udid: "00008160-000449843E58000A"), "g19p")
    }

    func testA19ProIPhoneTakesG18p() {
        XCTAssertEqual(DeviceGPU.target(udid: "00008150-0001110C0EC0401C"), "g18p")
    }

    func testUnknownChipTakesNoTarget() {
        XCTAssertNil(DeviceGPU.target(udid: "00008110-000A1234567890AB"))
    }

    func testSimulatorOrMalformedIdentifierTakesNoTarget() {
        XCTAssertNil(DeviceGPU.target(udid: "437EBB0C-E340-4400-9AF4-541E47D5B8B2"))
        XCTAssertNil(DeviceGPU.target(udid: ""))
    }

    func testShellBuildArgumentsCarryTheGPU() {
        XCTAssertEqual(ShellInstall.buildArguments(workDir: "/w", team: "T", gpu: "g19p"),
                       ["--shell-framework", "/w/shell-framework", "--team-id", "T", "--gpu", "g19p"])
        XCTAssertEqual(ShellInstall.buildArguments(workDir: "/w", team: "T", gpu: nil),
                       ["--shell-framework", "/w/shell-framework", "--team-id", "T"])
    }
}
