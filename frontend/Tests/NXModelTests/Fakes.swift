import Foundation
import NXCore

/// A `ProcessRunner` that starts nothing: it records what it was asked to run and answers from a script.
final class FakeProcessRunner: ProcessRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [ProcessLaunch] = []
    /// The answer for a launch. The default is a run that exits 0 and prints nothing.
    var answer: (ProcessLaunch) -> ProcessResult = { _ in ProcessResult() }

    var launches: [ProcessLaunch] { lock.lock(); defer { lock.unlock() }; return recorded }
    /// Each launch as one line: the tool's name and its arguments.
    var commands: [String] { launches.map { ([($0.executable as NSString).lastPathComponent] + $0.arguments).joined(separator: " ") } }

    func capture(_ launch: ProcessLaunch) -> ProcessResult {
        lock.lock(); recorded.append(launch); lock.unlock()
        return answer(launch)
    }

    func stream(_ launch: ProcessLaunch, line: @escaping (String) -> Void) -> Bool {
        lock.lock(); recorded.append(launch); lock.unlock()
        return true
    }

    func start(_ launch: ProcessLaunch, onOutput: @escaping (Data) -> Void, onExit: @escaping (Int32) -> Void) throws -> RunningProcess {
        throw CocoaError(.fileNoSuchFile)
    }
}

/// A `ReleaseSource` without a network: the latest release and the downloads come from what the test sets.
final class FakeReleaseSource: ReleaseSource, @unchecked Sendable {
    private let lock = NSLock()
    private var downloaded: [URL] = []
    private var asked = 0
    /// What the "latest release" call answers. nil: no answer.
    var latest: Data?
    /// What a download writes. nil: the download fails.
    var file: Data? = Data("zip".utf8)

    var downloads: [URL] { lock.lock(); defer { lock.unlock() }; return downloaded }
    var latestCalls: Int { lock.lock(); defer { lock.unlock() }; return asked }

    func latestRelease() async -> Data? {
        lock.withLock { asked += 1 }
        return latest
    }

    func download(_ url: URL, to file: URL) async -> Bool {
        lock.withLock { downloaded.append(url) }
        guard let data = self.file else { return false }
        return (try? data.write(to: file)) != nil
    }

    /// The JSON GitHub gives for a release with the asset this app installs.
    static func release(tag: String, digest: String? = nil, notes: String = "", asset: String = "NX2Apple-macOS-arm64.zip") -> Data {
        var a: [String: Any] = ["name": asset, "browser_download_url": "https://example.invalid/\(asset)"]
        if let digest { a["digest"] = digest }
        return try! JSONSerialization.data(withJSONObject: ["tag_name": tag, "body": notes, "assets": [a]])
    }
}
