import Darwin
import Foundation

/// Watches the shell's writable `Documents/` tree (`Documents/`, `Documents/games/`, each immediate `<titleID>`
/// game directory, existing `msl`/`aoc` subfolders, and `Documents/Frameworks/` plus its `.staging-*` folders)
/// using Darwin `kqueue` (`O_EVTONLY` + `DispatchSourceFileSystemObject`).
///
/// Events are coalesced with a debounce window and all file descriptors are closed deterministically via each
/// source's cancel handler on removal, `stop()`, or `deinit`.
final class GameDirectoryWatcher: Sendable {
    struct ChangeHint: Equatable, Sendable {
        var hasReadyHotFramework: Bool
    }

    private struct WatchedEntry {
        let source: any DispatchSourceFileSystemObject
        let dev: dev_t
        let ino: ino_t
    }

    /// Mutable state owned exclusively by `queue`.
    private final class State: @unchecked Sendable {
        let appDataRoot: URL
        let documentsRoot: URL
        let hotFrameworksRoot: URL?
        let debounceInterval: TimeInterval
        let queue: DispatchQueue
        let onChange: @Sendable (ChangeHint) -> Void
        let maxDescriptors = 128

        var watchers: [String: WatchedEntry] = [:]
        var debounceWorkItem: DispatchWorkItem?
        var isPaused = false
        var dirtyWhilePaused = false
        var isStopped = false

        init(appDataRoot: URL, hotFrameworksRoot: URL?, debounceInterval: TimeInterval,
             queue: DispatchQueue, onChange: @escaping @Sendable (ChangeHint) -> Void) {
            self.appDataRoot = appDataRoot
            self.documentsRoot = appDataRoot.deletingLastPathComponent()
            self.hotFrameworksRoot = hotFrameworksRoot
            self.debounceInterval = max(0, debounceInterval)
            self.queue = queue
            self.onChange = onChange
        }

        func startLocked() {
            guard !isStopped else { return }
            let fm = FileManager.default
            if !fm.fileExists(atPath: appDataRoot.path) {
                try? fm.createDirectory(at: appDataRoot, withIntermediateDirectories: true)
            }
            syncWatchesLocked()
        }

        func setPausedLocked(_ paused: Bool) {
            guard !isStopped, isPaused != paused else { return }
            isPaused = paused
            if paused {
                debounceWorkItem?.cancel()
                debounceWorkItem = nil
            } else {
                syncWatchesLocked()
                if dirtyWhilePaused {
                    dirtyWhilePaused = false
                    scheduleDebouncedNotifyLocked()
                }
            }
        }

        func stopLocked() {
            guard !isStopped else { return }
            isStopped = true
            debounceWorkItem?.cancel()
            debounceWorkItem = nil
            for entry in watchers.values {
                entry.source.cancel()
            }
            watchers.removeAll()
        }

        func handleFilesystemEventLocked() {
            guard !isStopped else { return }
            // Refresh watched children immediately so newly created <titleID> or .staging-* folders receive events right away.
            syncWatchesLocked()
            if isPaused {
                dirtyWhilePaused = true
                return
            }
            scheduleDebouncedNotifyLocked()
        }

        private func scheduleDebouncedNotifyLocked() {
            debounceWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.isStopped, !self.isPaused else { return }
                self.debounceWorkItem = nil
                self.syncWatchesLocked()
                let hasReadyHot = self.hotFrameworksRoot.map { GameCatalogue.hasReadyStagedFramework(in: $0) } ?? false
                self.onChange(ChangeHint(hasReadyHotFramework: hasReadyHot))
            }
            debounceWorkItem = work
            queue.asyncAfter(deadline: .now() + debounceInterval, execute: work)
        }

        func syncWatchesLocked() {
            guard !isStopped else { return }
            let desired = desiredPathsLocked()
            let desiredSet = Set(desired)

            // Drop watchers for deleted directories or directories replaced by a new inode.
            for (path, entry) in Array(watchers) {
                guard desiredSet.contains(path),
                      let current = statDirectory(path),
                      current.dev == entry.dev,
                      current.ino == entry.ino else {
                    entry.source.cancel()
                    watchers.removeValue(forKey: path)
                    continue
                }
            }

            // Open descriptors for newly appeared directories up to maxDescriptors.
            for path in desired {
                if watchers[path] != nil { continue }
                guard watchers.count < maxDescriptors else { break }
                if let created = makeWatcherLocked(path: path) {
                    watchers[path] = created
                }
            }
        }

        private func desiredPathsLocked() -> [String] {
            var primary: [String] = []
            var secondary: [String] = []
            var seen = Set<String>()

            func appendIfDir(_ url: URL, into target: inout [String]) {
                let path = url.standardizedFileURL.path
                guard !seen.contains(path), statDirectory(path) != nil else { return }
                seen.insert(path)
                target.append(path)
            }

            appendIfDir(documentsRoot, into: &primary)
            appendIfDir(appDataRoot, into: &primary)

            let fm = FileManager.default
            if let hotRoot = hotFrameworksRoot {
                appendIfDir(hotRoot, into: &primary)
                if let hotItems = try? fm.contentsOfDirectory(atPath: hotRoot.path) {
                    for name in hotItems.sorted() where name.hasPrefix(HotFrameworkReady.stagingPrefix) {
                        appendIfDir(hotRoot.appendingPathComponent(name, isDirectory: true), into: &primary)
                    }
                }
            }

            if let gameItems = try? fm.contentsOfDirectory(atPath: appDataRoot.path) {
                for name in gameItems.sorted() where !name.hasPrefix(".") {
                    let gameDir = appDataRoot.appendingPathComponent(name, isDirectory: true)
                    guard statDirectory(gameDir.standardizedFileURL.path) != nil else { continue }
                    appendIfDir(gameDir, into: &primary)
                    for sub in ["msl", "aoc"] {
                        appendIfDir(gameDir.appendingPathComponent(sub, isDirectory: true), into: &secondary)
                    }
                }
            }

            return primary + secondary
        }

        private func makeWatcherLocked(path: String) -> WatchedEntry? {
            let fd = Darwin.open(path, O_EVTONLY)
            guard fd >= 0 else { return nil }
            var st = stat()
            guard Darwin.fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else {
                Darwin.close(fd)
                return nil
            }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .rename, .delete, .attrib],
                queue: queue
            )
            source.setEventHandler { [weak self] in
                self?.handleFilesystemEventLocked()
            }
            source.setCancelHandler {
                Darwin.close(fd)
            }
            source.resume()
            return WatchedEntry(source: source, dev: st.st_dev, ino: st.st_ino)
        }

        private func statDirectory(_ path: String) -> (dev: dev_t, ino: ino_t)? {
            var st = stat()
            // lstat avoids following symlinks outside the app's writable container.
            guard Darwin.lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { return nil }
            return (st.st_dev, st.st_ino)
        }
    }

    private let queue: DispatchQueue
    private let state: State

    init(appDataRoot: URL, hotFrameworksRoot: URL?, debounceInterval: TimeInterval = 0.6,
         onChange: @escaping @Sendable (ChangeHint) -> Void) {
        let queue = DispatchQueue(label: "dev.nx2apple.shell.directory-watcher", qos: .utility)
        self.queue = queue
        self.state = State(appDataRoot: appDataRoot, hotFrameworksRoot: hotFrameworksRoot,
                           debounceInterval: debounceInterval, queue: queue, onChange: onChange)
    }

    deinit {
        let state = self.state
        queue.async {
            state.stopLocked()
        }
    }

    func start() {
        let state = self.state
        queue.async {
            state.startLocked()
        }
    }

    func setPaused(_ paused: Bool) {
        let state = self.state
        queue.async {
            state.setPausedLocked(paused)
        }
    }

    func refreshTargets() {
        let state = self.state
        queue.async {
            state.syncWatchesLocked()
        }
    }

    func stop() {
        let state = self.state
        queue.async {
            state.stopLocked()
        }
    }

    /// Waits for any previously enqueued watcher control operations (such as `start()`) to complete.
    func waitUntilReady() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                continuation.resume()
            }
        }
    }

    /// Active watched directory descriptor count, for leak and lifecycle tests.
    var activeDescriptorCount: Int {
        queue.sync { state.watchers.count }
    }
}
