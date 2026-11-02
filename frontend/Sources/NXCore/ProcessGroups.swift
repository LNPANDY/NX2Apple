import Foundation

/// Process groups: Stop and quitting end the whole build.
///
/// The script runs its tools as children (the shader split with its workers, dotnet, xcodebuild) and cleans them up only on Ctrl-C:
/// a SIGTERM to the script alone leaves them running, orphaned. So each build process starts in a process group of its own, and Stop,
/// quitting the app or a SIGTERM to it end the whole group. `ProcessRunner.start` does the grouping. The app also calls `endAll()`
/// when it quits (the notification is AppKit's, so it is hooked up in the app target).
package enum ProcessGroups {
    /// The groups of the builds running now (their leaders' PIDs).
    private static var groups = Set<pid_t>()
    private static let lock = NSLock()
    private static let sigtermHandler: Void = {
        signal(SIGTERM, SIG_IGN)   // handled below: end the builds, then exit
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        source.setEventHandler { endAll(); exit(0) }
        source.resume()
        sigtermSource = source
    }()
    private static var sigtermSource: DispatchSourceSignal?

    /// Run `p` as the leader of a new process group: Python sets the group, then execs into the real command.
    /// It also restores SIGTERM and SIGINT to their defaults first: the app ignores SIGTERM (to end its builds before
    /// it exits), and an ignored signal is inherited across exec, which would make Stop's SIGTERM do nothing.
    package static func inOwnGroup(_ p: Process, python: String) {
        let command = p.executableURL?.path ?? python
        let start = "import os, signal, sys; signal.signal(signal.SIGTERM, signal.SIG_DFL); signal.signal(signal.SIGINT, signal.SIG_DFL); "
            + "os.setpgid(0, 0); os.execv(sys.argv[1], sys.argv[1:])"
        p.arguments = ["-c", start, command] + (p.arguments ?? [])
        p.executableURL = URL(fileURLWithPath: python)
    }

    package static func track(_ p: Process) {
        _ = sigtermHandler
        lock.lock(); groups.insert(p.processIdentifier); lock.unlock()
    }

    package static func untrack(_ p: Process) {
        lock.lock(); groups.remove(p.processIdentifier); lock.unlock()
    }

    /// A build's process group is still running (the app update waits for it: its relaunch would end the build).
    package static var buildProcessesAlive: Bool {
        lock.lock(); defer { lock.unlock() }
        return groups.contains { killpg($0, 0) == 0 }
    }

    /// SIGTERM to every process of the group, SIGKILL 5 s later to whatever is left of it.
    package static func endGroup(_ leader: pid_t) {
        guard leader > 1 else { return }
        killpg(leader, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            if killpg(leader, 0) == 0 { killpg(leader, SIGKILL) }
        }
    }

    /// The app is about to exit: SIGTERM to every group, one grace period for the whole set, then SIGKILL for what remains.
    package static func endAll() {
        lock.lock(); let all = groups; lock.unlock()
        for leader in all {
            killpg(leader, SIGTERM)
        }
        if !all.isEmpty {
            usleep(1_500_000)
            for leader in all where killpg(leader, 0) == 0 { killpg(leader, SIGKILL) }
        }
    }
}
