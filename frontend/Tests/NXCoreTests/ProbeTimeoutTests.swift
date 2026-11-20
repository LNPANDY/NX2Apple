import XCTest
@testable import NXCore

/// A probe of the tools check never runs without an end (#1474): on the macOS 27 CI runner `xcrun --show-sdk-version` hung, each
/// hung scan held a thread of the Swift concurrency pool, and later tests that await (the library scan, the artwork panel) never ran.
final class ProbeTimeoutTests: XCTestCase {
    func testAProbeThatDoesNotAnswerIsEnded() {
        let runner = SystemProcessRunner(xcodeApp: nil, probeTimeout: 0.5)
        let started = Date()
        let result = runner.capture(ProcessLaunch(executable: "/bin/sleep", arguments: ["30"]))
        XCTAssertTrue(result.timedOut)
        XCTAssertFalse(result.ok)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    func testAProbeThatAnswersIsNotTouchedAndABuildRunnerHasNoLimit() {
        let runner = SystemProcessRunner(xcodeApp: nil, probeTimeout: 30)
        let result = runner.capture(ProcessLaunch(executable: "/bin/echo", arguments: ["ok"]))
        XCTAssertTrue(result.ok)
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(DependencyCheck.probeTimeout, 60)
    }
}
