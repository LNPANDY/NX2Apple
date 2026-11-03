import Foundation
import Combine

/// The text of the build log (LNPANDY/NX2Apple#387). It is a store of its own, so a line from the build script invalidates
/// the views that show the log and nothing else: `BuildStore` holds it in a `let` and does not publish it, and no view above
/// the log observes it. The failure classifier reads `text` once, when a build stops.
///
/// `text` keeps the tail: past `limit` characters it shrinks to the last `keep`. The pipe delivers arbitrary chunks, so
/// `feed` also splits them into lines and holds back a partial last line until its newline arrives.
@MainActor package final class BuildLog: ObservableObject {
    package static let limit = 12000
    package static let keep = 9000

    @Published package private(set) var text = ""
    private var partial = ""

    nonisolated package init() {}

    /// Adds text to the log. It is not split into lines: the caller ends a line itself.
    package func append(_ s: String) {
        text += s
        if text.count > Self.limit { text = String(text.suffix(Self.keep)) }
    }

    /// Takes a chunk of the script's output and returns the lines it completes, without their line ends. The rest waits
    /// for the next chunk. It does not add to `text`: the caller decides what of each line is log text.
    package func feed(_ chunk: String) -> [String] {
        partial += chunk
        var lines: [String] = []
        while let i = partial.firstIndex(of: "\n") {
            lines.append(String(partial[..<i]).replacingOccurrences(of: "\r", with: ""))
            partial = String(partial[partial.index(after: i)...])
        }
        return lines
    }

    /// The partial last line, if any, when the output ends without a newline.
    package func flush() -> String? {
        guard !partial.isEmpty else { return nil }
        defer { partial = "" }
        return partial
    }

    /// Empties the log and drops a partial line: a new build or a stopped one starts clean.
    package func clear() {
        text = ""
        partial = ""
    }

    /// Replaces the text (tests set a log to classify).
    package func set(_ s: String) { text = s }
}
