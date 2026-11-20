import Darwin
import Foundation

/// Watches the shell's writable `Documents/` tree (`Documents/`, `Documents/games/`, each immediate `<titleID>`
/// game directory, existing `msl`/`aoc` subfolders, and `Documents/Frameworks/` plus its `.staging-*` folders)
/// using Darwin `kqueue` (`O_EVTONLY` + `DispatchSourceFileSystemObject`).
///
/// Filesystem events are coalesced with a debounce window, and `.nxpart` split files are gated by two-sample
/// `(size, mtime)` stability plus a quiet window before firing so streaming writes are never joined mid-transfer
/// and still trigger automatically once writing finishes without requiring a second directory vnode event.
final class GameDirectoryWatcher: Sendable {
    struct ChangeHint: Equatable, Sendable {
        var hasReadyHotFramework: Bool
        /// Canonical paths (`resolvingSymlinksInPath().standardizedFileURL.path`) of `.nxpart` files still settling.
        var unstablePartPaths: Set<String>
    }

    private struct WatchedEntry {
        let source: any DispatchSourceFileSystemObject
        let dev: dev_t
        let ino: ino_t
    }

    private struct PartSignature: Equatable {
        let size: Int64
        let mtimeSec: Int
        let mtimeNsec: Int
    }

    private struct ObservedPart {
        var signature: PartSignature
        var stableSamples: Int
        var lastChangedMonotonic: TimeInterval
    }

    /// Mutable state owned exclusively by `queue`.
    private final class State: @unchecked Sendable {
        let appDataRoot: URL
        let documentsRoot: URL
        let hotFrameworksRoot: URL?
        let debounceInterval: TimeInterval
        let partStableWindow: TimeInterval
        let partRecheckInterval: TimeInterval
        let queue: DispatchQueue
        let onChange: @Sendable (ChangeHint) -> Void
        let maxDescriptors = 128

        var watchers: [String: WatchedEntry] = [:]
        var debounceWorkItem: DispatchWorkItem?
        var partRecheckWorkItem: DispatchWorkItem?
        var observedParts: [String: ObservedPart] = [:]
        var lastNotifiedStableSnapshot: [String: PartSignature] = [:]
        var isPaused = false
        var dirtyWhilePaused = false
        var isStopped = false

        init(appDataRoot: URL, hotFrameworksRoot: URL?, debounceInterval: TimeInterval,
             partStableWindow: TimeInterval, queue: DispatchQueue,
             onChange: @escaping @Sendable (ChangeHint) -> Void) {
            self.appDataRoot = appDataRoot
            self.documentsRoot = appDataRoot.deletingLastPathComponent()
            self.hotFrameworksRoot = hotFrameworksRoot
            self.debounceInterval = max(0, debounceInterval)
            self.partStableWindow = max(0, partStableWindow)
            self.partRecheckInterval = partStableWindow > 0 ? min(0.35, max(0.04, partStableWindow / 3.0)) : 0
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
            // Seed snapshots for any pre-existing parts so startup changes are tracked cleanly.
            _ = evaluatePartsLocked()
        }

        func setPausedLocked(_ paused: Bool) {
            guard !isStopped, isPaused != paused else { return }
            isPaused = paused
            if paused {
                debounceWorkItem?.cancel()
                debounceWorkItem = nil
                partRecheckWorkItem?.cancel()
                partRecheckWorkItem = nil
                if !observedParts.isEmpty {
                    dirtyWhilePaused = true
                }
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
            partRecheckWorkItem?.cancel()
            partRecheckWorkItem = nil
            observedParts.removeAll()
            lastNotifiedStableSnapshot.removeAll()
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
                self.evaluateAndNotifyLocked(fromDirectoryEvent: true)
            }
            debounceWorkItem = work
            queue.asyncAfter(deadline: .now() + debounceInterval, execute: work)
        }

        private func schedulePartRecheckLocked() {
            guard partRecheckWorkItem == nil, !isStopped, !isPaused, partRecheckInterval > 0 else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.isStopped, !self.isPaused else { return }
                self.partRecheckWorkItem = nil
                self.evaluateAndNotifyLocked(fromDirectoryEvent: false)
            }
            partRecheckWorkItem = work
            queue.asyncAfter(deadline: .now() + partRecheckInterval, execute: work)
        }

        private func evaluateAndNotifyLocked(fromDirectoryEvent: Bool) {
            syncWatchesLocked()
            let eval = evaluatePartsLocked()
            let hasReadyHot = hotFrameworksRoot.map { GameCatalogue.hasReadyStagedFramework(in: $0) } ?? false

            if !eval.unstablePaths.isEmpty {
                schedulePartRecheckLocked()
            } else {
                partRecheckWorkItem?.cancel()
                partRecheckWorkItem = nil
            }

            let stableChanged = eval.stableSnapshot != lastNotifiedStableSnapshot
            let shouldNotify: Bool
            if hasReadyHot {
                shouldNotify = true
            } else if stableChanged && !eval.stableSnapshot.isEmpty {
                shouldNotify = true
            } else if fromDirectoryEvent && eval.unstablePaths.isEmpty {
                // Covers loose .img drops in Documents/ or deletions when no streaming .nxpart is active.
                shouldNotify = true
            } else {
                shouldNotify = false
            }

            if eval.stableSnapshot.isEmpty && eval.unstablePaths.isEmpty {
                lastNotifiedStableSnapshot.removeAll()
            } else if shouldNotify {
                lastNotifiedStableSnapshot = eval.stableSnapshot
            }

            if shouldNotify {
                onChange(ChangeHint(hasReadyHotFramework: hasReadyHot, unstablePartPaths: eval.unstablePaths))
            }
        }

        private func evaluatePartsLocked() -> (stableSnapshot: [String: PartSignature], unstablePaths: Set<String>) {
            let fm = FileManager.default
            guard let walk = fm.enumerator(at: appDataRoot, includingPropertiesForKeys: [.isRegularFileKey]) else {
                observedParts.removeAll()
                return ([:], [])
            }
            let nowMonotonic = ProcessInfo.processInfo.systemUptime
            let nowWall = Date().timeIntervalSince1970

            var found: [String: (sig: PartSignature, mtimeWall: TimeInterval)] = [:]
            for case let url as URL in walk {
                guard DataParts.parse(url.lastPathComponent) != nil else { continue }
                let canonicalPath = url.resolvingSymlinksInPath().standardizedFileURL.path
                var st = stat()
                guard Darwin.lstat(canonicalPath, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { continue }
                let sig = PartSignature(
                    size: Int64(st.st_size),
                    mtimeSec: Int(st.st_mtimespec.tv_sec),
                    mtimeNsec: Int(st.st_mtimespec.tv_nsec)
                )
                let mtimeWall = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1_000_000_000.0
                found[canonicalPath] = (sig, mtimeWall)
            }

            // Drop records for removed or already-joined parts.
            for path in Array(observedParts.keys) where found[path] == nil {
                observedParts.removeValue(forKey: path)
            }

            var stableSnapshot: [String: PartSignature] = [:]
            var unstablePaths = Set<String>()

            for (path, info) in found {
                var record: ObservedPart
                if var existing = observedParts[path], existing.signature == info.sig {
                    existing.stableSamples += 1
                    record = existing
                } else {
                    record = ObservedPart(signature: info.sig, stableSamples: 0, lastChangedMonotonic: nowMonotonic)
                }
                observedParts[path] = record

                let monotonicAge = nowMonotonic - record.lastChangedMonotonic
                let wallAge = nowWall - info.mtimeWall
                let isStable = (partStableWindow <= 0)
                    || (record.stableSamples >= 1 && monotonicAge >= partStableWindow && wallAge >= partStableWindow)
                if isStable {
                    stableSnapshot[path] = info.sig
                } else {
                    unstablePaths.insert(path)
                }
            }

            return (stableSnapshot, unstablePaths)
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
         partStableWindow: TimeInterval = 1.0,
         onChange: @escaping @Sendable (ChangeHint) -> Void) {
        let queue = DispatchQueue(label: "dev.nx2apple.shell.directory-watcher", qos: .utility)
        self.queue = queue
        self.state = State(appDataRoot: appDataRoot, hotFrameworksRoot: hotFrameworksRoot,
                           debounceInterval: debounceInterval, partStableWindow: partStableWindow,
                           queue: queue, onChange: onChange)
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
