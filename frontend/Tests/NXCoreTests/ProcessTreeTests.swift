import XCTest
@testable import NXCore

/// #952: the launcher finds a game app's host, its child process, to talk to it.
final class ProcessTreeTests: XCTestCase {
    func testAChildProcessIsFound() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["5"]
        try child.run()
        defer { child.terminate(); child.waitUntilExit() }
        XCTAssertTrue(ProcessTree.children(of: getpid()).contains(child.processIdentifier))
        XCTAssertEqual(ProcessTree.children(of: child.processIdentifier), [], "sleep starts nothing")
        XCTAssertEqual(ProcessTree.children(of: 0), [])
        XCTAssertEqual(ProcessTree.children(of: -1), [])
    }
}
