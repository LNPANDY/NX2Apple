import Foundation

/// What to start: the tool, its arguments and where it runs. Standard input is always empty for a captured or streamed run.
package struct ProcessLaunch {
    package var executable: String
    package var arguments: [String]
    /// nil: the app's own environment.
    package var environment: [String: String]?
    package var directory: String?
    /// stderr goes into the same stream as stdout.
    package var mergesErrors = false
    /// Start in a process group of its own, through this Python (`ProcessGroups`). nil: no group.
    package var groupPython: String?
    /// A captured run that is still going after this many seconds is ended (SIGTERM, then SIGKILL 2 s later) and reports `timedOut`.
    package var timeout: TimeInterval?
    /// Written to standard input of a captured run, which is then closed. nil: standard input is empty.
    package var input: String?

    package init(executable: String, arguments: [String] = [], environment: [String: String]? = nil, directory: String? = nil,
                 mergesErrors: Bool = false, groupPython: String? = nil, timeout: TimeInterval? = nil, input: String? = nil) {
        self.executable = executable; self.arguments = arguments; self.environment = environment; self.directory = directory
        self.mergesErrors = mergesErrors; self.groupPython = groupPython; self.timeout = timeout; self.input = input
    }

    /// `command[0]` is the tool, the rest its arguments.
    package init(_ command: [String], environment: [String: String]? = nil, directory: String? = nil,
                 mergesErrors: Bool = false, groupPython: String? = nil) {
        self.init(executable: command[0], arguments: Array(command.dropFirst()), environment: environment, directory: directory,
                  mergesErrors: mergesErrors, groupPython: groupPython)
    }
}

/// How a captured run ended. A process that could not start is `started == false` with the reason in `out`.
package struct ProcessResult: Equatable {
    package var started: Bool
    package var status: Int32
    package var out: String
    package var err: String
    /// The run was ended because it outlasted `ProcessLaunch.timeout`.
    package var timedOut: Bool
    package var ok: Bool { started && status == 0 && !timedOut }

    package init(started: Bool = true, status: Int32 = 0, out: String = "", err: String = "", timedOut: Bool = false) {
        self.started = started; self.status = status; self.out = out; self.err = err; self.timedOut = timedOut
    }

    package static func failedToStart(_ reason: String) -> ProcessResult { ProcessResult(started: false, status: -1, out: reason) }
}

/// A process the runner started and that has not ended yet (Stop reads its identifier).
package protocol RunningProcess: AnyObject {
    var processIdentifier: Int32 { get }
    var isRunning: Bool { get }
}

extension Process: RunningProcess {}

/// The only place that starts a process: process groups, environment and captured output. A service takes one through its
/// initializer, so a test passes in a fake that answers without starting anything.
package protocol ProcessRunner {
    /// Run to the end and capture the output (blocking).
    func capture(_ launch: ProcessLaunch) -> ProcessResult
    /// Run to the end and hand each output line to `line` as it arrives (blocking). true when it exited 0.
    func stream(_ launch: ProcessLaunch, line: @escaping (String) -> Void) -> Bool
    /// Run to the end with stdout and stderr merged and hand out every whole line, empty ones too, a last line without its newline
    /// included (blocking). `started` gets the process right after it starts, for a caller that can end it (Stop). With
    /// `groupPython` the process leads a group of its own that `ProcessGroups` tracks until it exits. A process that could not
    /// start is `started == false` with the reason in `out`, and `started` is not called.
    func streamLines(_ launch: ProcessLaunch, started: @escaping (RunningProcess) -> Void, line: @escaping (String) -> Void) -> ProcessResult
    /// Start and return at once. `onOutput` gets the combined output in chunks on a background queue, `onExit` the exit status.
    /// With `groupPython` the process is the leader of a group of its own that `ProcessGroups` tracks until it exits.
    func start(_ launch: ProcessLaunch, onOutput: @escaping (Data) -> Void, onExit: @escaping (Int32) -> Void) throws -> RunningProcess
}

extension ProcessRunner {
    /// All output captured, none streamed (fetch, rev-list and pull print little). A failure to start is `ok == false`, its reason in `out`.
    package func runQuiet(_ args: [String], env: [String: String]) -> ProcessResult {
        capture(ProcessLaunch(args, environment: env, mergesErrors: true))
    }

    /// Whether the tool exits 0, its output thrown away.
    package func runOK(_ tool: String, _ args: [String], env: [String: String]? = nil) -> Bool {
        capture(ProcessLaunch(executable: tool, arguments: args, environment: env)).ok
    }

    /// The tool's stdout when it exits 0, nil when it does not start or fails.
    package func output(_ tool: String, _ args: [String], env: [String: String]? = nil) -> String? {
        let r = capture(ProcessLaunch(executable: tool, arguments: args, environment: env))
        return r.ok ? r.out : nil
    }

    /// Stream the output line by line. A failure to start is reported as a line and returns false.
    package func runCaptured(_ args: [String], env: [String: String], line: @escaping (String) -> Void) -> Bool {
        stream(ProcessLaunch(args, environment: env), line: line)
    }
}

/// Starts real processes.
package struct SystemProcessRunner: ProcessRunner {
    package init() {}

    private func process(_ launch: ProcessLaunch) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launch.executable)
        p.arguments = launch.arguments
        if let env = launch.environment { p.environment = env }
        if let dir = launch.directory { p.currentDirectoryURL = URL(fileURLWithPath: dir) }
        return p
    }

    package func capture(_ launch: ProcessLaunch) -> ProcessResult {
        let p = process(launch)
        let stdin = Pipe()
        p.standardInput = launch.input == nil ? FileHandle.nullDevice : stdin
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = launch.mergesErrors ? out : err
        do { try p.run() } catch { return .failedToStart(error.localizedDescription) }
        let deadline = launch.timeout.map { Deadline(p, after: $0) }
        if let input = launch.input {
            stdin.fileHandleForWriting.write(Data(input.utf8))
            try? stdin.fileHandleForWriting.close()
        }
        // Both pipes are drained before the exit is awaited, so the child cannot block on a full pipe.
        let errData = LockedData()
        let drained = DispatchGroup()
        if !launch.mergesErrors {
            drained.enter()
            DispatchQueue.global().async { errData.set(err.fileHandleForReading.readDataToEndOfFile()); drained.leave() }
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        drained.wait()
        p.waitUntilExit()
        deadline?.cancel()
        return ProcessResult(status: p.terminationStatus, out: String(data: outData, encoding: .utf8) ?? "",
                             err: String(data: errData.value, encoding: .utf8) ?? "", timedOut: deadline?.fired ?? false)
    }

    package func streamLines(_ launch: ProcessLaunch, started: @escaping (RunningProcess) -> Void, line: @escaping (String) -> Void) -> ProcessResult {
        let p = process(launch)
        p.standardInput = FileHandle.nullDevice
        if let python = launch.groupPython { ProcessGroups.inOwnGroup(p, python: python) }
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return .failedToStart(error.localizedDescription) }
        if launch.groupPython != nil { ProcessGroups.track(p) }
        started(p)
        var pending = ""
        let handle = pipe.fileHandleForReading
        while true {
            let data = handle.availableData
            if data.isEmpty { break }
            pending += String(decoding: data, as: UTF8.self)
            while let nl = pending.firstIndex(of: "\n") {
                line(String(pending[..<nl]))
                pending = String(pending[pending.index(after: nl)...])
            }
        }
        if !pending.isEmpty { line(pending) }
        p.waitUntilExit()
        if launch.groupPython != nil { ProcessGroups.untrack(p) }
        return ProcessResult(status: p.terminationStatus)
    }

    package func stream(_ launch: ProcessLaunch, line: @escaping (String) -> Void) -> Bool {
        let p = process(launch)
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err; p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { line("could not start \(launch.executable): \(error.localizedDescription)"); return false }
        for h in [out.fileHandleForReading, err.fileHandleForReading] {
            PipeReader.attach(to: h) { d in
                if let s = String(data: d, encoding: .utf8) {
                    for piece in s.split(separator: "\n") { line(String(piece)) }
                }
            }
        }
        p.waitUntilExit()
        out.fileHandleForReading.readabilityHandler = nil; err.fileHandleForReading.readabilityHandler = nil
        return p.terminationStatus == 0
    }

    package func start(_ launch: ProcessLaunch, onOutput: @escaping (Data) -> Void, onExit: @escaping (Int32) -> Void) throws -> RunningProcess {
        let p = process(launch)
        if let python = launch.groupPython { ProcessGroups.inOwnGroup(p, python: python) }
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        PipeReader.attach(to: pipe.fileHandleForReading, onData: onOutput)
        p.terminationHandler = { done in
            ProcessGroups.untrack(done)
            onExit(done.terminationStatus)
        }
        try p.run()
        if launch.groupPython != nil { ProcessGroups.track(p) }
        return p
    }
}

/// The data a background read leaves for the thread that waits for it.
private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func set(_ new: Data) { lock.lock(); data = new; lock.unlock() }
    var value: Data { lock.lock(); defer { lock.unlock() }; return data }
}

/// Ends a process that outlasts its time: SIGTERM at the deadline, SIGKILL 2 s later when it still runs. Cancelled when the run ends.
private final class Deadline: @unchecked Sendable {
    private let lock = NSLock()
    private var didFire = false
    private var work: DispatchWorkItem?

    init(_ p: Process, after seconds: TimeInterval) {
        let item = DispatchWorkItem { [self] in
            lock.lock(); didFire = true; lock.unlock()
            if p.isRunning { p.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if p.isRunning { kill(p.processIdentifier, SIGKILL) } }
        }
        work = item
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: item)
    }

    func cancel() { work?.cancel() }
    var fired: Bool { lock.lock(); defer { lock.unlock() }; return didFire }
}
