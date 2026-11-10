import Foundation

/// How a game's session ended, read from the last lines of its log (LNPANDY/NX2Apple#816, "After a crash"). The Mac app's launcher
/// (dm/mac/launcher.c) runs the host as a child and writes how it ended as its last line: "launcher: the host exited with N" or
/// "launcher: the host stopped on signal N". The host's crash handler (dm/host/crash.c) writes "[dm] CRASH sig=N" and exits with
/// 128 + N. The launcher only reads these lines. It names no cause.
package enum GameExit: Equatable, Sendable {
    /// Exit status 0: the player quit (⌘Q, the Home button prompt, the window closed, the launcher's quit request).
    case quit
    /// A crash, a non-zero exit status or a signal that is not a request to end: console mode shows "stopped unexpectedly".
    case stoppedUnexpectedly
    /// The log says nothing about the end (an older build, a log that was not written, a launcher that was itself ended).
    case unknown

    static let exited = "launcher: the host exited with "
    static let signalled = "launcher: the host stopped on signal "
    static let crash = "[dm] CRASH sig="
    /// The signals someone sends to end a process on purpose (logging out, Activity Monitor's Quit, Terminal): not a crash.
    static let requested: Set<Int> = [1, 2, 9, 15]

    /// The end of the session the log's tail holds: its last "launcher:" end line, or a crash line after the last start of the host.
    package static func from(logTail text: String) -> GameExit {
        let lines = text.split(whereSeparator: \.isNewline)
        for line in lines.reversed() {
            if let range = line.range(of: exited) {
                let status = Int(line[range.upperBound...].prefix { $0.isNumber || $0 == "-" })
                guard let status else { return .unknown }
                return status == 0 ? .quit : .stoppedUnexpectedly
            }
            if let range = line.range(of: signalled) {
                guard let signal = Int(line[range.upperBound...].prefix(while: \.isNumber)) else { return .unknown }
                return requested.contains(signal) ? .quit : .stoppedUnexpectedly
            }
            if line.contains(crash) { return .stoppedUnexpectedly }
            if line.hasPrefix("launcher: ") && line.contains(", host ") { return .unknown }   // the start of this session: nothing after it said how it ended
        }
        return .unknown
    }
}
