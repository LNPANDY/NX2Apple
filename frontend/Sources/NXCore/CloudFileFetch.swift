import Foundation

/// Brings a file that iCloud Drive (or another file provider) has only listed onto this Mac before a game reads it (#957): the
/// engine reads the cloud's save with a plain copy at the game's first save mount, and a download that has not finished then
/// leaves it without the cloud's save. There is no time limit here: the player sees the wait and can cancel it.
package enum CloudFetchResult: Equatable {
    case ready             // the file is on this Mac, whole
    case missing           // there is no such file (the cloud has no save of this game)
    case failed(String)    // the download failed, or the file cannot be read: the reason
    case cancelled
}

package protocol CloudFileFetching: Sendable {
    /// Blocks until the file is here, it fails, or `cancelled()` says so (asked a few times a second). Not on the main thread.
    func fetch(_ file: URL, cancelled: @escaping @Sendable () -> Bool) -> CloudFetchResult
}

/// The real one: a coordinated read (NSFileCoordinator), which has the file provider download a file it has only listed, while
/// the download's error is watched (`ubiquitousItemDownloadingErrorKey`) so a failed one ends the wait instead of holding it.
package struct CoordinatedCloudFetch: CloudFileFetching {
    package init() {}

    package func fetch(_ file: URL, cancelled: @escaping @Sendable () -> Bool) -> CloudFetchResult {
        let fm = FileManager.default
        // A file iCloud has only listed is a dataless file (macOS 14 and later) or, on older systems, a ".<name>.icloud" placeholder beside it
        let placeholder = file.deletingLastPathComponent().appendingPathComponent("." + file.lastPathComponent + ".icloud")
        guard fm.fileExists(atPath: file.path) || fm.fileExists(atPath: placeholder.path) else {
            // No file in a folder that is there: the cloud has no save. No folder at all (iCloud Drive off, not signed in, not synced yet) is no answer
            let game = file.deletingLastPathComponent(), folder = game.deletingLastPathComponent()
            return [game, folder].contains { var isDir: ObjCBool = false; return fm.fileExists(atPath: $0.path, isDirectory: &isDir) && isDir.boolValue }
                ? .missing : .failed("The cloud saves folder is not on this Mac.")
        }
        if (try? file.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) == true {
            try? fm.startDownloadingUbiquitousItem(at: file)
        }
        let coordinator = NSFileCoordinator()
        let state = FetchState()
        Thread.detachNewThread {
            var error: NSError?
            var outcome = CloudFetchResult.failed("The file could not be read.")
            coordinator.coordinate(readingItemAt: file, options: [], error: &error) { url in
                // The coordinated read has the provider bring the file here; reading it all checks that it is whole
                if let handle = try? FileHandle(forReadingFrom: url) {
                    defer { try? handle.close() }
                    while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {}
                    outcome = .ready
                }
            }
            if let error { outcome = error.code == NSUserCancelledError ? .cancelled : .failed(error.localizedDescription) }
            state.finish(outcome)
        }
        while true {
            if let done = state.wait(seconds: 0.25) { return done }
            if cancelled() { coordinator.cancel(); state.finish(.cancelled); return .cancelled }
            var url = file
            url.removeAllCachedResourceValues()
            if let error = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingErrorKey]).ubiquitousItemDownloadingError {
                coordinator.cancel()
                state.finish(.failed(error.localizedDescription))
                return .failed(error.localizedDescription)
            }
        }
    }
}

/// The coordinated read's answer, handed from its thread to the waiting one: the first answer counts.
private final class FetchState: @unchecked Sendable {
    private let condition = NSCondition()
    private var result: CloudFetchResult?

    func finish(_ value: CloudFetchResult) {
        condition.lock(); if result == nil { result = value }; condition.broadcast(); condition.unlock()
    }

    func wait(seconds: TimeInterval) -> CloudFetchResult? {
        condition.lock(); defer { condition.unlock() }
        if result == nil { _ = condition.wait(until: Date().addingTimeInterval(seconds)) }
        return result
    }
}
