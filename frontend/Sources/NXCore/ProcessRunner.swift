import Darwin
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
    private let xcodeApp: () -> String?

    package init(defaults: UserDefaults = .standard) { xcodeApp = { XcodeSelection.app(in: defaults) } }

    /// A dependency scan probes one selection throughout, even if a new scan starts before it finishes.
    init(xcodeApp: String?) { self.xcodeApp = { xcodeApp } }

    private func process(_ launch: ProcessLaunch) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launch.executable)
        p.arguments = launch.arguments
        if let app = xcodeApp(), XcodeSelection.isXcode(app) {
            // xcrun, xcodebuild and the engine's grandchildren must agree, even for a build or install with a clean environment.
            var env = launch.environment ?? ProcessInfo.processInfo.environment
            env["DEVELOPER_DIR"] = app + "/Contents/Developer"
            p.environment = env
        } else if let env = launch.environment {
            p.environment = env
        }
        if let dir = launch.directory { p.currentDirectoryURL = URL(fileURLWithPath: dir) }
        return p
    }

    package func capture(_ launch: ProcessLaunch) -> ProcessResult {
        let p = process(launch)
        let stdin = launch.input == nil ? nil : Pipe()
        p.standardInput = stdin ?? FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = launch.mergesErrors ? out : err
        do { try p.run() } catch { return .failedToStart(error.localizedDescription) }
        let deadline = launch.timeout.map { Deadline(p, after: $0) }
        // Start draining stdout and stderr before writing stdin asynchronously so >64 KB inputs cannot deadlock both ends.
        let outData = LockedData(), errData = LockedData()
        let drained = DispatchGroup()
        drained.enter()
        DispatchQueue.global().async { outData.set(out.fileHandleForReading.readDataToEndOfFile()); drained.leave() }
        if !launch.mergesErrors {
            drained.enter()
            DispatchQueue.global().async { errData.set(err.fileHandleForReading.readDataToEndOfFile()); drained.leave() }
        }
        if let input = launch.input, let stdin {
            let handle = stdin.fileHandleForWriting
            _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
            let bytes = Data(input.utf8)
            DispatchQueue.global().async {
                if !bytes.isEmpty { try? handle.write(contentsOf: bytes) }
                try? handle.close()
            }
        }
        drained.wait()
        p.waitUntilExit()
        deadline?.cancel()
        return ProcessResult(status: p.terminationStatus, out: String(decoding: outData.value, as: UTF8.self),
                             err: String(decoding: errData.value, as: UTF8.self), timedOut: deadline?.fired ?? false)
    }

    package func streamLines(_ launch: ProcessLaunch, started: @escaping (RunningProcess) -> Void, line: @escaping (String) -> Void) -> ProcessResult {
        let p = process(launch)
        p.standardInput = FileHandle.nullDevice
        if let python = launch.groupPython { ProcessGroups.inOwnGroup(p, python: python) }
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return .failedToStart(error.localizedDescription) }
        if launch.groupPython != nil { ProcessGroups.track(p) }
        started(p)
        var utf8 = UTF8StreamDecoder()
        var pending = ""
        let handle = pipe.fileHandleForReading
        while true {
            let data = handle.availableData
            if data.isEmpty { break }
            pending += utf8.decode(data)
            Self.drainLines(&pending, to: line)
        }
        let rest = utf8.finish()
        if !rest.isEmpty {
            pending += rest
            Self.drainLines(&pending, to: line)
        }
        if !pending.isEmpty {
            if pending.unicodeScalars.last == "\r" { pending.unicodeScalars.removeLast() }
            line(pending)
        }
        p.waitUntilExit()
        if launch.groupPython != nil { ProcessGroups.untrack(p) }
        return ProcessResult(status: p.terminationStatus)
    }

    package func stream(_ launch: ProcessLaunch, line: @escaping (String) -> Void) -> Bool {
        let p = process(launch)
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err; p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { line("could not start \(launch.executable): \(error.localizedDescription)"); return false }
        let emitLock = NSLock()
        let emit: (String) -> Void = { s in emitLock.lock(); defer { emitLock.unlock() }; line(s) }
        let outLines = PipeLineBuffer(emit: emit), errLines = PipeLineBuffer(emit: emit)
        out.fileHandleForReading.readabilityHandler = { outLines.readAvailable(from: $0) }
        err.fileHandleForReading.readabilityHandler = { errLines.readAvailable(from: $0) }
        p.waitUntilExit()
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        outLines.finish(reading: out.fileHandleForReading)
        errLines.finish(reading: err.fileHandleForReading)
        return p.terminationStatus == 0
    }

    package func start(_ launch: ProcessLaunch, onOutput: @escaping (Data) -> Void, onExit: @escaping (Int32) -> Void) throws -> RunningProcess {
        let p = process(launch)
        if let python = launch.groupPython { ProcessGroups.inOwnGroup(p, python: python) }
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        let readHandle = pipe.fileHandleForReading
        let outputGate = PipeOutputGate(onOutput: onOutput)
        readHandle.readabilityHandler = { outputGate.readAvailable(from: $0) }
        let group = launch.groupPython != nil ? ProcessGroups.Registration() : nil
        p.terminationHandler = { done in
            outputGate.drainAvailableBeforeExit(from: readHandle)
            group?.untrack(done)
            onExit(done.terminationStatus)
        }
        try p.run()
        group?.track(p)
        return p
    }

    fileprivate static func drainLines(_ pending: inout String, to emit: (String) -> Void) {
        while let nl = pending.unicodeScalars.firstIndex(of: "\n") {
            var piece = String(pending.unicodeScalars[..<nl])
            if piece.unicodeScalars.last == "\r" { piece.unicodeScalars.removeLast() }
            emit(piece)
            pending = String(pending.unicodeScalars[pending.unicodeScalars.index(after: nl)...])
        }
    }
}

/// Buffers UTF-8 bytes and partial lines across pipe chunks for `SystemProcessRunner.stream`, then drains remaining pipe data on exit.
private final class PipeLineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var utf8 = UTF8StreamDecoder()
    private var pending = ""
    private var finished = false
    private let emit: (String) -> Void

    init(emit: @escaping (String) -> Void) { self.emit = emit }

    func readAvailable(from handle: FileHandle) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        let d = handle.availableData
        if d.isEmpty {
            handle.readabilityHandler = nil
            return
        }
        pending += utf8.decode(d)
        SystemProcessRunner.drainLines(&pending, to: emit)
    }

    func finish(reading handle: FileHandle) {
        handle.readabilityHandler = nil
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        let rest = handle.readDataToEndOfFile()
        if !rest.isEmpty {
            pending += utf8.decode(rest)
            SystemProcessRunner.drainLines(&pending, to: emit)
        }
        let tail = utf8.finish()
        if !tail.isEmpty {
            pending += tail
            SystemProcessRunner.drainLines(&pending, to: emit)
        }
        if !pending.isEmpty {
            var last = pending
            pending = ""
            if last.unicodeScalars.last == "\r" { last.unicodeScalars.removeLast() }
            emit(last)
        }
    }
}

/// Serializes `readabilityHandler` chunks with non-blocking exit draining for `SystemProcessRunner.start` so trailing bytes
/// already buffered in the pipe arrive at `onOutput` before `onExit` runs, without blocking if a grandchild keeps the pipe open.
private final class PipeOutputGate: @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false
    private let onOutput: (Data) -> Void

    init(onOutput: @escaping (Data) -> Void) { self.onOutput = onOutput }

    func readAvailable(from handle: FileHandle) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        let d = handle.availableData
        if d.isEmpty {
            handle.readabilityHandler = nil
            closed = true
            return
        }
        onOutput(d)
    }

    func drainAvailableBeforeExit(from handle: FileHandle) {
        handle.readabilityHandler = nil
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        let fd = handle.fileDescriptor
        guard fd >= 0 else { return }
        while true {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, 0) > 0, (pfd.revents & Int16(POLLIN | POLLHUP)) != 0 else { break }
            let d = handle.availableData
            if d.isEmpty { break }
            onOutput(d)
        }
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
