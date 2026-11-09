import XCTest
import NXCore
@testable import NXModel

/// The shared app's separate actions (#994, #1036): what a send's outcome means for the transfer queue, and Finder recovery.
@MainActor final class SharedAppActionTests: XCTestCase {
    func testASuccessfulSendIsDone() {
        XCTAssertEqual(BuildStore.transferResult(of: .init(ok: true, message: ""), deviceConnected: true), .done)
    }

    func testADeviceThatIsNotConnectedWaitsWhetherTheCopyNeverStartedOrTheDeviceWentAwayInTheMiddle() {
        XCTAssertEqual(BuildStore.transferResult(of: .init(ok: false, message: "x", copySkipped: true), deviceConnected: true), .deviceAbsent)
        XCTAssertEqual(BuildStore.transferResult(of: .init(ok: false, message: "CoreDeviceError 3"), deviceConnected: false), .deviceAbsent)
    }

    func testAFailureOnAConnectedDeviceKeepsItsMessageForRetry() {
        XCTAssertEqual(BuildStore.transferResult(of: .init(ok: false, message: "no space"), deviceConnected: true), .failed("no space"))
    }

    func testTheQueueEntryOfAnExportBatchPackagesAfterwardsAndAMacOneDoesNot() {
        let ios = QueueEntry(titleID: "A", name: "A", target: BuildTarget.ios, inputs: [:], outputDirectory: "", engineID: "e", packageAfter: true)
        XCTAssertTrue(ios.packageAfter && ios.target != BuildTarget.mac)
    }
}
