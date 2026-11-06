import Foundation

/// Where the launcher learns about releases and fetches one: the second service of the self-update, next to `ProcessRunner`.
/// `AppUpdateStore` takes one through its initializer, so a test passes in a fake that answers without a network.
package protocol ReleaseSource {
    /// The body of the latest release as the GitHub API gives it. nil when there was no answer (no network, a timeout).
    func latestRelease() async -> Data?
    /// Downloads `url` to `file`. false when it did not arrive or the server did not answer 200.
    func download(_ url: URL, to file: URL) async -> Bool
    /// Downloads `url` to `file` and reports the fraction received (`0...1`) when the response gives a content length.
    func download(_ url: URL, to file: URL, onProgress: @escaping @Sendable (Double) -> Void) async -> Bool
}

extension ReleaseSource {
    package func download(_ url: URL, to file: URL, onProgress: @escaping @Sendable (Double) -> Void) async -> Bool {
        await download(url, to: file)
    }
}

/// The releases of a GitHub repository, over `URLSession.shared`.
package struct GitHubReleases: ReleaseSource {
    package let repository: String

    package init(repository: String = "LNPANDY/NX2Apple") { self.repository = repository }

    package func latestRelease() async -> Data? {
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else { return nil }
        return try? await URLSession.shared.data(from: url).0
    }

    package func download(_ url: URL, to file: URL) async -> Bool {
        await download(url, to: file, onProgress: { _ in })
    }

    package func download(_ url: URL, to file: URL, onProgress: @escaping @Sendable (Double) -> Void) async -> Bool {
        let taskBox = DownloadTaskBox()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let delegate = DownloadDelegate(destination: file, onProgress: onProgress, continuation: continuation)
                let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
                let task = session.downloadTask(with: url)
                taskBox.store(task)
                task.resume()
            }
        } onCancel: {
            taskBox.cancel()
        }
    }
}

private final class DownloadTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDownloadTask?
    private var cancelled = false

    func store(_ newTask: URLSessionDownloadTask) {
        let shouldCancel: Bool = lock.withLock {
            if cancelled { return true }
            task = newTask
            return false
        }
        if shouldCancel { newTask.cancel() }
    }

    func cancel() {
        let current: URLSessionDownloadTask? = lock.withLock {
            cancelled = true
            let t = task
            task = nil
            return t
        }
        current?.cancel()
    }
}

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let onProgress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var moved = false
    private var lastPercent = -1

    init(destination: URL, onProgress: @escaping @Sendable (Double) -> Void, continuation: CheckedContinuation<Bool, Never>) {
        self.destination = destination
        self.onProgress = onProgress
        self.continuation = continuation
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0, totalBytesWritten >= 0 else { return }
        let fraction = min(max(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), 0), 1)
        let pct = Int((fraction * 100).rounded())
        let report: Bool = lock.withLock {
            guard pct != lastPercent else { return false }
            lastPercent = pct
            return true
        }
        if report { onProgress(fraction) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 200 == 200 else { return }
        try? FileManager.default.removeItem(at: destination)
        if (try? FileManager.default.moveItem(at: location, to: destination)) != nil {
            lock.withLock { moved = true }
            onProgress(1)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        session.finishTasksAndInvalidate()
        let (cont, ok): (CheckedContinuation<Bool, Never>?, Bool) = lock.withLock {
            let c = continuation
            continuation = nil
            return (c, error == nil && moved)
        }
        cont?.resume(returning: ok)
    }
}
