import XCTest
@testable import NSPortBuilder

/// The build log pipes (#201): at end of output the read handler must remove itself, or the dispatch source
/// fires on the closed pipe forever and pins a CPU core.
final class PipeReaderTests: XCTestCase {
    func testHandlerDetachesAtEndOfOutputAndKeepsAllOutput() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "echo one; echo two; echo three"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        let lock = NSLock()
        var received = Data()
        PipeReader.attach(to: pipe.fileHandleForReading) { d in lock.lock(); received.append(d); lock.unlock() }
        XCTAssertNotNil(pipe.fileHandleForReading.readabilityHandler)
        try p.run()
        p.waitUntilExit()
        let deadline = Date().addingTimeInterval(5)
        while pipe.fileHandleForReading.readabilityHandler != nil, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertNil(pipe.fileHandleForReading.readabilityHandler, "the handler is still attached after end of output")
        lock.lock(); defer { lock.unlock() }
        XCTAssertEqual(String(data: received, encoding: .utf8), "one\ntwo\nthree\n")
    }
}
