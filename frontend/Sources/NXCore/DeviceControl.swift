import Foundation

/// `xcrun devicectl` for the save transfer, as one function: the tests hand in a stand-in, so no test ever reaches a device.
/// It takes devicectl's arguments and returns whether it exited 0 and what it printed.
package struct DeviceControl {
    package let run: ([String]) -> (ok: Bool, output: String)

    package init(run: @escaping ([String]) -> (ok: Bool, output: String)) { self.run = run }

    /// What a command that ran out of time prints in place of devicectl's own output (and what a stand-in prints to say the same).
    package static let timedOut = "devicectl timed out"

    /// Every command has a deadline: devicectl's own (`--timeout`), and behind it one on the process (`ProcessLaunch.timeout`),
    /// because CoreDevice can stall on a paired device whose connection is not ready, and a command that never returns leaves the
    /// Saves sheet at "Reading..." for good. A copy gets the longer deadline, a query the shorter one.
    package static func xcrun(_ path: String, queryTimeout: TimeInterval = 10, copyTimeout: TimeInterval = 180,
                              runner: ProcessRunner = SystemProcessRunner()) -> DeviceControl {
        DeviceControl { args in
            let timeout = args.starts(with: ["device", "copy"]) ? copyTimeout : queryTimeout
            let launch = ProcessLaunch(executable: path,
                                       arguments: ["devicectl", "--timeout", String(max(1, Int(timeout.rounded(.up))))] + args,
                                       mergesErrors: true, timeout: timeout + 2)
            let r = runner.capture(launch)
            if !r.started { return (false, r.out) }
            if r.timedOut { return (false, timedOut) }
            return (r.status == 0, r.out)
        }
    }
}
