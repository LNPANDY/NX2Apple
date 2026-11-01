import XCTest
@testable import NXCore

/// `ProcessRunner`: the real one against small system tools, and the helpers over a fake.
final class ProcessRunnerTests: XCTestCase {
    private let real = SystemProcessRunner()

    // MARK: The real runner

    func testCaptureKeepsStdoutAndStderrApart() {
        let r = real.capture(ProcessLaunch(["/bin/sh", "-c", "echo out; echo err >&2; exit 3"]))
        XCTAssertTrue(r.started)
        XCTAssertEqual(r.status, 3)
        XCTAssertFalse(r.ok)
        XCTAssertEqual(r.out, "out\n")
        XCTAssertEqual(r.err, "err\n")
    }

    func testRunQuietMergesBothStreams() {
        let r = real.runQuiet(["/bin/sh", "-c", "echo out; echo err >&2"], env: ["PATH": "/usr/bin:/bin"])
        XCTAssertTrue(r.ok)
        XCTAssertEqual(Set(r.out.split(separator: "\n")), ["out", "err"])
    }

    func testTheEnvironmentIsExactlyTheOneGiven() {
        let r = real.runQuiet(["/usr/bin/env"], env: ["ONLY": "this"])
        XCTAssertEqual(r.out.trimmingCharacters(in: .whitespacesAndNewlines), "ONLY=this")
    }

    func testTheDirectoryIsTheOneGiven() {
        let dir = NSTemporaryDirectory()
        let r = real.capture(ProcessLaunch(executable: "/bin/pwd", directory: dir))
        let printed = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(URL(fileURLWithPath: printed).resolvingSymlinksInPath().path, URL(fileURLWithPath: dir).resolvingSymlinksInPath().path)
    }

    func testAToolThatDoesNotExistFailsToStartWithAReason() {
        let r = real.runQuiet(["/nonexistent/tool"], env: [:])
        XCTAssertFalse(r.started)
        XCTAssertFalse(r.ok)
        XCTAssertFalse(r.out.isEmpty)
        XCTAssertFalse(real.runOK("/nonexistent/tool", []))
        XCTAssertNil(real.output("/nonexistent/tool", []))
    }

    func testRunOKAndOutputFollowTheExitStatus() {
        XCTAssertTrue(real.runOK("/usr/bin/true", []))
        XCTAssertFalse(real.runOK("/usr/bin/false", []))
        XCTAssertEqual(real.output("/bin/echo", ["hello"]), "hello\n")
        XCTAssertNil(real.output("/usr/bin/false", []))
    }

    func testCaptureDoesNotBlockOnAFullStderrPipe() {
        // Far more than a pipe holds, on the stream that is read second.
        let r = real.capture(ProcessLaunch(["/bin/sh", "-c", "head -c 300000 /dev/zero | tr '\\0' x >&2; echo done"]))
        XCTAssertTrue(r.ok)
        XCTAssertEqual(r.out, "done\n")
        XCTAssertEqual(r.err.count, 300000)
    }

    func testStreamGivesEachLineAndTheResult() {
        let lines = Collected()
        let ok = real.runCaptured(["/bin/sh", "-c", "echo one; echo two >&2; exit 0"], env: ["PATH": "/usr/bin:/bin"]) { lines.add($0) }
        XCTAssertTrue(ok)
        XCTAssertEqual(Set(lines.values), ["one", "two"])
        XCTAssertFalse(real.runCaptured(["/usr/bin/false"], env: [:]) { _ in })
    }

    func testStreamReportsAToolThatDoesNotStartAsALine() {
        let lines = Collected()
        XCTAssertFalse(real.runCaptured(["/nonexistent/tool"], env: [:]) { lines.add($0) })
        XCTAssertEqual(lines.values.count, 1)
        XCTAssertTrue(lines.values[0].hasPrefix("could not start /nonexistent/tool"))
    }

    func testStartReportsOutputAndTheExitStatus() throws {
        let output = Collected(), exited = expectation(description: "exit")
        var status: Int32 = -1
        _ = try real.start(ProcessLaunch(["/bin/sh", "-c", "echo started; exit 5"]), onOutput: { output.add(String(decoding: $0, as: UTF8.self)) },
                           onExit: { status = $0; exited.fulfill() })
        wait(for: [exited], timeout: 10)
        XCTAssertEqual(status, 5)
        let deadline = Date().addingTimeInterval(5)
        while !output.values.joined().contains("started") && Date() < deadline { usleep(20_000) }
        XCTAssertTrue(output.values.joined().contains("started"))
    }

    func testStartThrowsForAToolThatDoesNotExist() {
        XCTAssertThrowsError(try real.start(ProcessLaunch(["/nonexistent/tool"]), onOutput: { _ in }, onExit: { _ in }))
    }

    /// With a group the process leads a group of its own, and the group is tracked until it exits.
    func testStartInAGroupLeadsItsOwnGroupAndEndsWithIt() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else { throw XCTSkip("System Python is required") }
        let exited = expectation(description: "exit")
        let process = try real.start(ProcessLaunch(["/bin/sh", "-c", "sleep 30"], groupPython: "/usr/bin/python3"), onOutput: { _ in },
                                     onExit: { _ in exited.fulfill() })
        let pid = process.processIdentifier
        var tries = 0
        while getpgid(pid) != pid && tries < 100 { usleep(50_000); tries += 1 }
        XCTAssertEqual(getpgid(pid), pid, "the process is the leader of its own group")
        XCTAssertTrue(ProcessGroups.buildProcessesAlive)
        ProcessGroups.endGroup(pid)
        wait(for: [exited], timeout: 10)
        var alive = true
        tries = 0
        while alive && tries < 50 { alive = ProcessGroups.buildProcessesAlive; if alive { usleep(50_000) }; tries += 1 }
        XCTAssertFalse(alive, "an ended process is no longer tracked")
    }

    // MARK: The helpers over a fake

    func testRunQuietAsksForOneMergedRunWithTheGivenEnvironment() {
        let fake = FakeProcessRunner()
        fake.answer = { _ in ProcessResult(out: "hi") }
        let r = fake.runQuiet(["/usr/bin/git", "status"], env: ["A": "1"])
        XCTAssertEqual(r.out, "hi")
        XCTAssertEqual(fake.commands, ["git status"])
        XCTAssertTrue(fake.launches[0].mergesErrors)
        XCTAssertEqual(fake.launches[0].environment, ["A": "1"])
    }

    func testRunOKAndOutputReadTheFakesAnswer() {
        let fake = FakeProcessRunner()
        fake.answer = { $0.executable == "/good" ? ProcessResult(out: "yes\n") : ProcessResult(status: 1) }
        XCTAssertTrue(fake.runOK("/good", []))
        XCTAssertFalse(fake.runOK("/bad", []))
        XCTAssertEqual(fake.output("/good", []), "yes\n")
        XCTAssertNil(fake.output("/bad", []))
    }

    // MARK: A service that takes the runner

    func testToolchainReadsTheDeveloperDirectoryThroughTheRunner() throws {
        let fake = FakeProcessRunner()
        let folder = NSTemporaryDirectory()
        fake.answer = { _ in ProcessResult(out: folder + "\n") }
        XCTAssertEqual(Toolchain.developerDir(runner: fake), folder)
        XCTAssertEqual(fake.commands, ["xcode-select -p"])
        fake.answer = { _ in ProcessResult(status: 1) }
        XCTAssertNil(Toolchain.developerDir(runner: fake))
    }

    func testToolchainParsesThePythonVersionFromTheRunner() {
        let fake = FakeProcessRunner()
        fake.answer = { _ in ProcessResult(out: "3.12\n") }
        let v = Toolchain.pythonVersion("/fake/python3", runner: fake)
        XCTAssertEqual(v?.0, 3)
        XCTAssertEqual(v?.1, 12)
        fake.answer = { _ in ProcessResult(out: "not a version") }
        XCTAssertNil(Toolchain.pythonVersion("/fake/python3", runner: fake))
        fake.answer = { _ in .failedToStart("no such file") }
        XCTAssertNil(Toolchain.pythonVersion("/fake/python3", runner: fake))
    }

    func testToolchainTakesTheFirstLineOfAToolsOutput() {
        let fake = FakeProcessRunner()
        fake.answer = { _ in ProcessResult(out: "Apple metal version 32023\nTarget: air64\n") }
        XCTAssertEqual(Toolchain.firstOutputLine("/usr/bin/xcrun", ["metal", "--version"], runner: fake), "Apple metal version 32023")
        XCTAssertEqual(fake.commands, ["xcrun metal --version"])
    }

    func testMakeVenvLogsWhatTheToolsPrintAndStopsWhenOneFails() {
        let fake = FakeProcessRunner()
        fake.answer = { _ in ProcessResult(status: 1, out: "so far", err: "externally-managed-environment") }
        let r = Toolchain.makeVenv(base: "/fake/python3", runner: fake)
        XCTAssertFalse(r.ok)
        XCTAssertTrue(r.log.contains("externally-managed-environment"))
    }
}

/// Lines from a pipe's threads, read afterwards.
private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var box: [String] = []
    func add(_ s: String) { lock.lock(); box.append(s); lock.unlock() }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return box }
}
