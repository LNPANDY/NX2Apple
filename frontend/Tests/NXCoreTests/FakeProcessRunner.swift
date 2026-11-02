import Foundation
@testable import NXCore

/// A `ProcessRunner` that starts nothing: it records what it was asked to run and answers from a script.
final class FakeProcessRunner: ProcessRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [ProcessLaunch] = []
    /// The answer for a launch. The default is a run that exits 0 and prints nothing.
    var answer: (ProcessLaunch) -> ProcessResult = { _ in ProcessResult() }
    /// What `stream` prints, and whether it exits 0.
    var lines: [String] = []
    var streamOK = true
    /// The exit status of `streamLines`. nil: it fails to start.
    var lineStatus: Int32? = 0
    /// What `start` reports: the output chunks, then the exit status. nil: it fails to start.
    var startOutput: [String]? = []
    var startStatus: Int32 = 0

    var launches: [ProcessLaunch] { lock.lock(); defer { lock.unlock() }; return recorded }
    /// Each launch as one line: the tool's name and its arguments.
    var commands: [String] { launches.map { ([($0.executable as NSString).lastPathComponent] + $0.arguments).joined(separator: " ") } }

    private func record(_ l: ProcessLaunch) { lock.lock(); recorded.append(l); lock.unlock() }

    func capture(_ launch: ProcessLaunch) -> ProcessResult { record(launch); return answer(launch) }

    func stream(_ launch: ProcessLaunch, line: @escaping (String) -> Void) -> Bool {
        record(launch)
        lines.forEach(line)
        return streamOK
    }

    func streamLines(_ launch: ProcessLaunch, started: @escaping (RunningProcess) -> Void, line: @escaping (String) -> Void) -> ProcessResult {
        record(launch)
        guard let status = lineStatus else { return .failedToStart("could not start") }
        started(FakeRunningProcess())
        lines.forEach(line)
        return ProcessResult(status: status)
    }

    func start(_ launch: ProcessLaunch, onOutput: @escaping (Data) -> Void, onExit: @escaping (Int32) -> Void) throws -> RunningProcess {
        record(launch)
        guard let output = startOutput else { throw CocoaError(.fileNoSuchFile) }
        output.forEach { onOutput(Data($0.utf8)) }
        onExit(startStatus)
        return FakeRunningProcess()
    }
}

final class FakeRunningProcess: RunningProcess {
    var processIdentifier: Int32 { 0 }
    var isRunning: Bool { false }
}
