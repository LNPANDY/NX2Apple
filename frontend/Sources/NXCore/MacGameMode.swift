import Darwin
import Foundation

/// Per-game macOS Game Mode configuration (`LSSupportsGameMode` in `<app>/Contents/Info.plist`).
///
/// The engine packs Mac game bundles with `LSSupportsGameMode = false` by default because macOS Game Mode can hold the GPU at its
/// lowest clock after a few minutes of full-screen play on some Macs (`docs/reference/frame-rate.md`). Players who want Game Mode's
/// doubled Bluetooth controller polling and lower audio latency can opt in per game; changing `Info.plist` requires re-signing an
/// ad-hoc signed bundle so macOS accepts the modified plist at launch.
package enum MacGameMode {
    package static let optionEnv = "MAC_GAME_MODE"
    package static let plistKey = "LSSupportsGameMode"
    package static let shared = Coordinator()

    package enum ApplyError: LocalizedError, Equatable {
        case invalidBundle
        case customSignature
        case signingFailed(String)

        package var errorDescription: String? {
            switch self {
            case .invalidBundle:
                return "Invalid Mac game app bundle."
            case .customSignature:
                return "Cannot re-sign a Mac game bundle signed with a custom developer identity."
            case .signingFailed(let detail):
                return detail.isEmpty ? "codesign failed while updating Info.plist." : detail
            }
        }
    }

    package enum SignatureState: Equatable {
        case unsigned
        case adhoc
        case customIdentity
    }

    private struct CachedEntry {
        let plistInode: UInt64
        let plistSize: UInt64
        let plistModified: TimeInterval
        let enabled: Bool
    }

    private static let cacheLock = NSLock()
    private static var cache: [String: CachedEntry] = [:]

    private static let lsregisterPath =
        "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

    /// True only for a complete, playable Mac game `.app` bundle (`Info.plist`, launcher executable, and `dmhost`).
    package static func canConfigure(app: String) -> Bool {
        guard !app.isEmpty else { return false }
        return (try? MacGameBundle.read(URL(fileURLWithPath: app))) != nil
    }

    package static func invalidateCache(forApp app: String) {
        guard !app.isEmpty else { return }
        let key = URL(fileURLWithPath: app).standardizedFileURL.path
        cacheLock.lock()
        cache.removeValue(forKey: key)
        cacheLock.unlock()
    }

    /// Reads `LSSupportsGameMode` from `<app>/Contents/Info.plist`, cached by `(path, inode, size, mtime)`.
    package static func isEnabled(inApp app: String) -> Bool {
        guard !app.isEmpty else { return false }
        let bundleURL = URL(fileURLWithPath: app).standardizedFileURL
        guard bundleURL.pathExtension.lowercased() == "app" else { return false }
        let bundleKey = bundleURL.path
        let plistURL = bundleURL.appendingPathComponent("Contents/Info.plist")
        let fm = FileManager.default
        guard let attr = try? fm.attributesOfItem(atPath: plistURL.path),
              let plistSize = attr[.size] as? UInt64,
              let plistModified = (attr[.modificationDate] as? Date)?.timeIntervalSince1970 else {
            invalidateCache(forApp: bundleKey)
            return false
        }
        let plistInode = attr[.systemFileNumber] as? UInt64 ?? 0
        cacheLock.lock()
        if let hit = cache[bundleKey],
           hit.plistInode == plistInode,
           hit.plistSize == plistSize,
           hit.plistModified == plistModified {
            cacheLock.unlock()
            return hit.enabled
        }
        cacheLock.unlock()

        guard let data = try? Data(contentsOf: plistURL),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            invalidateCache(forApp: bundleKey)
            return false
        }
        let enabled = (info[plistKey] as? Bool) ?? false
        cacheLock.lock()
        if cache.count >= 512 { cache.removeAll(keepingCapacity: true) }
        cache[bundleKey] = CachedEntry(
            plistInode: plistInode,
            plistSize: plistSize,
            plistModified: plistModified,
            enabled: enabled
        )
        cacheLock.unlock()
        return enabled
    }

    /// Inspects the bundle's existing signature so a Developer ID / Apple Development signature is never overwritten with ad-hoc `-`.
    package static func signatureState(ofApp app: String, runner: ProcessRunner = SystemProcessRunner()) -> SignatureState {
        let bundlePath = URL(fileURLWithPath: app).standardizedFileURL.path
        let probe = runner.capture(ProcessLaunch(
            executable: "/usr/bin/codesign",
            arguments: ["-dv", bundlePath],
            mergesErrors: true
        ))
        let combined = probe.out + "\n" + probe.err
        if !probe.ok && combined.localizedCaseInsensitiveContains("not signed at all") {
            return .unsigned
        }
        let hasAuthority = combined
            .split(whereSeparator: { $0.isNewline })
            .contains { $0.hasPrefix("Authority=") }
        if hasAuthority {
            return .customIdentity
        }
        return .adhoc
    }

    /// Removes AppleDouble `._*` files and `.DS_Store` inside the bundle (matching `dm/mac/pack_app.py:strip_detritus`) without
    /// traversing symbolic links. Uses POSIX `opendir`/`readdir` because `CFURLEnumerator` (`FileManager.enumerator(at:)`) hides `._*`
    /// sidecars on macOS.
    static func stripDetritus(in bundleURL: URL) {
        var rootStat = stat()
        let rootPath = bundleURL.path
        guard lstat(rootPath, &rootStat) == 0, (rootStat.st_mode & S_IFMT) == S_IFDIR else { return }
        var stack = [rootPath]
        while let current = stack.popLast() {
            guard let dir = opendir(current) else { continue }
            defer { closedir(dir) }
            while let entry = readdir(dir) {
                let name = withUnsafePointer(to: entry.pointee.d_name) { ptr in
                    ptr.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                        String(cString: $0)
                    }
                }
                if name == "." || name == ".." { continue }
                let child = current + "/" + name
                var childStat = stat()
                guard lstat(child, &childStat) == 0 else { continue }
                let kind = childStat.st_mode & S_IFMT
                if kind == S_IFLNK { continue }
                if name.hasPrefix("._") || name == ".DS_Store" {
                    if kind != S_IFDIR {
                        _ = unlink(child)
                    }
                    continue
                }
                if kind == S_IFDIR {
                    stack.append(child)
                }
            }
        }
    }

    /// Atomically updates `LSSupportsGameMode` in `<app>/Contents/Info.plist` and ad-hoc re-signs the bundle.
    /// Restores the original `Info.plist` bytes (and ad-hoc signature) if signing fails.
    package static func applySync(
        _ enabled: Bool,
        toApp app: String,
        runner: ProcessRunner = SystemProcessRunner()
    ) throws {
        guard canConfigure(app: app) else { throw ApplyError.invalidBundle }
        let bundleURL = URL(fileURLWithPath: app).standardizedFileURL
        let bundlePath = bundleURL.path
        let plistURL = bundleURL.appendingPathComponent("Contents/Info.plist")
        guard let originalBytes = try? Data(contentsOf: plistURL),
              var info = (try? PropertyListSerialization.propertyList(from: originalBytes, format: nil)) as? [String: Any] else {
            throw ApplyError.invalidBundle
        }
        if (info[plistKey] as? Bool) == enabled {
            _ = isEnabled(inApp: bundlePath)
            return
        }

        let existingSig = signatureState(ofApp: bundlePath, runner: runner)
        if existingSig == .customIdentity {
            throw ApplyError.customSignature
        }

        info[plistKey] = enabled
        let updatedBytes: Data
        do {
            updatedBytes = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            try updatedBytes.write(to: plistURL, options: .atomic)
        } catch {
            try? originalBytes.write(to: plistURL, options: .atomic)
            invalidateCache(forApp: bundlePath)
            MacGameBundle.invalidateCache(forApp: bundlePath)
            throw ApplyError.signingFailed(error.localizedDescription)
        }

        func signOnce() -> ProcessResult {
            stripDetritus(in: bundleURL)
            var result = runner.capture(ProcessLaunch(
                executable: "/usr/bin/codesign",
                arguments: ["--force", "--sign", "-", bundlePath],
                mergesErrors: true
            ))
            let output = result.out + "\n" + result.err
            if !result.ok,
               output.contains("detritus") || output.contains("._")
                || output.contains("not signed at all") || output.contains("resource fork") {
                _ = runner.capture(ProcessLaunch(
                    executable: "/usr/bin/xattr",
                    arguments: ["-cr", bundlePath],
                    mergesErrors: true
                ))
                stripDetritus(in: bundleURL)
                result = runner.capture(ProcessLaunch(
                    executable: "/usr/bin/codesign",
                    arguments: ["--force", "--sign", "-", bundlePath],
                    mergesErrors: true
                ))
            }
            stripDetritus(in: bundleURL)
            return result
        }

        let signResult = signOnce()
        guard signResult.ok else {
            try? originalBytes.write(to: plistURL, options: .atomic)
            if existingSig == .adhoc {
                _ = signOnce()
            }
            invalidateCache(forApp: bundlePath)
            MacGameBundle.invalidateCache(forApp: bundlePath)
            let detail = (signResult.err.isEmpty ? signResult.out : signResult.err)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw ApplyError.signingFailed(detail)
        }

        invalidateCache(forApp: bundlePath)
        MacGameBundle.invalidateCache(forApp: bundlePath)
        _ = isEnabled(inApp: bundlePath)

        if FileManager.default.isExecutableFile(atPath: lsregisterPath) {
            _ = runner.capture(ProcessLaunch(
                executable: lsregisterPath,
                arguments: ["-f", bundlePath],
                mergesErrors: true
            ))
        }
    }

    /// Serial background coordinator with per-bundle generation counters so rapid toggles never block `@MainActor`, coalesce intermediate
    /// writes, and serialize safely ahead of `NSWorkspace.openApplication`.
    package final class Coordinator: @unchecked Sendable {
        private let lock = NSLock()
        private let queue = DispatchQueue(label: "org.nxnative.mac-game-mode", qos: .utility)
        private let runner: ProcessRunner
        private var generations: [String: UInt64] = [:]
        private var pendingValues: [String: Bool] = [:]
        private var inFlightCounts: [String: Int] = [:]

        package init(runner: ProcessRunner = SystemProcessRunner()) {
            self.runner = runner
        }

        private func normalizedKey(_ app: String) -> String {
            URL(fileURLWithPath: app).standardizedFileURL.path
        }

        /// The effective switch state shown in the UI: an explicit stored choice wins, then an in-flight toggle, else the bundle's `Info.plist`.
        package func effectiveEnabled(forApp app: String, storedOption: String?) -> Bool {
            if storedOption == "1" { return true }
            if storedOption == "0" { return false }
            guard !app.isEmpty else { return false }
            let key = normalizedKey(app)
            lock.lock()
            let pending = pendingValues[key]
            lock.unlock()
            if let pending { return pending }
            return MacGameMode.isEnabled(inApp: key)
        }

        /// Enqueues an asynchronous `Info.plist` + `codesign` update guarded by a monotonic generation counter.
        package func scheduleApply(
            _ enabled: Bool,
            toApp app: String,
            onError: (@Sendable (Error) -> Void)? = nil
        ) {
            guard !app.isEmpty else { return }
            let key = normalizedKey(app)
            lock.lock()
            let gen = (generations[key] ?? 0) &+ 1
            generations[key] = gen
            pendingValues[key] = enabled
            inFlightCounts[key, default: 0] += 1
            lock.unlock()

            queue.async { [self] in
                lock.lock()
                let supersededBeforeStart = generations[key] != gen
                if supersededBeforeStart {
                    inFlightCounts[key] = max(0, (inFlightCounts[key] ?? 1) - 1)
                }
                lock.unlock()
                if supersededBeforeStart { return }

                var caught: Error?
                do {
                    try MacGameMode.applySync(enabled, toApp: key, runner: runner)
                } catch {
                    caught = error
                }

                lock.lock()
                let stillLatest = generations[key] == gen
                if stillLatest {
                    pendingValues.removeValue(forKey: key)
                }
                inFlightCounts[key] = max(0, (inFlightCounts[key] ?? 1) - 1)
                if inFlightCounts[key] == 0 {
                    inFlightCounts.removeValue(forKey: key)
                }
                lock.unlock()

                if stillLatest, let caught {
                    onError?(caught)
                }
            }
        }

        /// True only when an async queue drain or `Info.plist` update is needed before launching `app`.
        package func needsLaunchSync(enabled: Bool, forApp app: String) -> Bool {
            guard MacGameMode.canConfigure(app: app) else { return false }
            let key = normalizedKey(app)
            lock.lock()
            let active = (inFlightCounts[key] ?? 0) > 0
            lock.unlock()
            if active { return true }
            return MacGameMode.isEnabled(inApp: key) != enabled
        }

        /// Ensures the bundle's `Info.plist` matches `enabled` and any in-flight re-sign has finished before opening the app.
        /// Runs synchronously on the fast path when nothing is pending and the plist already matches.
        package func prepareForLaunch(
            enabled: Bool,
            forApp app: String,
            completion: @escaping @Sendable (Error?) -> Void
        ) {
            guard needsLaunchSync(enabled: enabled, forApp: app) else {
                completion(nil)
                return
            }
            let key = normalizedKey(app)
            queue.async { [self] in
                var caught: Error?
                if MacGameMode.isEnabled(inApp: key) != enabled {
                    do {
                        try MacGameMode.applySync(enabled, toApp: key, runner: runner)
                    } catch {
                        caught = error
                    }
                }
                DispatchQueue.main.async {
                    completion(caught)
                }
            }
        }

        /// Waits for all queued work to finish (used by unit tests).
        package func flushForTesting() {
            queue.sync {}
        }
    }
}
