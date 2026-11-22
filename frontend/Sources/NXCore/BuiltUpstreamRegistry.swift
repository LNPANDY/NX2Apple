import Foundation

/// Records which specialized `nxnative` variant built a Mac `.app` without modifying the signed app bundle.
/// Entries bind `(standardized path, titleID, Info.plist size, Info.plist mtime)` so rebuilding with another engine
/// or replacing the bundle outside the launcher automatically invalidates stale attribution.
package enum BuiltUpstreamRegistry {
    package struct Record: Codable, Equatable, Sendable {
        package let titleID: String
        package let upstream: EngineUpstreamKind
        package let plistSize: UInt64
        package let plistModified: TimeInterval

        package init(titleID: String, upstream: EngineUpstreamKind, plistSize: UInt64, plistModified: TimeInterval) {
            self.titleID = titleID
            self.upstream = upstream
            self.plistSize = plistSize
            self.plistModified = plistModified
        }
    }

    private static let lock = NSLock()
    private static var loadedURL: URL?
    private static var cache: [String: Record] = [:]

    /// Optional override for isolated unit tests.
    package static var customStoreURL: URL? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _customStoreURL
        }
        set {
            lock.lock()
            _customStoreURL = newValue
            loadedURL = nil
            cache = [:]
            lock.unlock()
        }
    }
    private static var _customStoreURL: URL?

    private static func storeURL(home: String = NSHomeDirectory()) -> URL {
        if let custom = _customStoreURL {
            return custom
        }
        return URL(fileURLWithPath: home + "/Library/Application Support/NX2Apple/built-upstreams.json")
    }

    private static func normalizedKey(_ appPath: String) -> String {
        URL(fileURLWithPath: appPath).standardizedFileURL.path
    }

    private static func loadLocked(url: URL) {
        guard loadedURL != url else { return }
        loadedURL = url
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: Record].self, from: data) else {
            cache = [:]
            return
        }
        cache = decoded
    }

    private static func saveLocked(url: URL) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(cache)
            try data.write(to: url, options: .atomic)
        } catch {
            // Best-effort metadata persistence; never fail a completed build.
        }
    }

    /// Associates a built Mac `.app` with a specialized `nxnative` variant, or clears the entry for standard `nxnative`.
    package static func record(
        appPath: String,
        titleID: String,
        upstream: EngineUpstreamKind,
        home: String = NSHomeDirectory(),
        fileManager fm: FileManager = .default
    ) {
        let key = normalizedKey(appPath)
        guard !key.isEmpty else { return }
        if !upstream.isNxnativeVariant {
            clear(appPath: key, home: home)
            return
        }
        let plistPath = URL(fileURLWithPath: key).appendingPathComponent("Contents/Info.plist").path
        guard let attrs = try? fm.attributesOfItem(atPath: plistPath),
              let plistSize = attrs[.size] as? UInt64,
              let plistModified = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 else {
            return
        }
        let upperID = titleID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        lock.lock()
        let url = storeURL(home: home)
        loadLocked(url: url)
        cache[key] = Record(
            titleID: upperID,
            upstream: upstream,
            plistSize: plistSize,
            plistModified: plistModified
        )
        saveLocked(url: url)
        lock.unlock()
        MacGameBundle.invalidateCache(forApp: key)
    }

    /// Removes any recorded variant attribution for `appPath`.
    package static func clear(appPath: String, home: String = NSHomeDirectory()) {
        let key = normalizedKey(appPath)
        guard !key.isEmpty else { return }
        lock.lock()
        let url = storeURL(home: home)
        loadLocked(url: url)
        let removed = cache.removeValue(forKey: key) != nil
        if removed {
            saveLocked(url: url)
        }
        lock.unlock()
        if removed {
            MacGameBundle.invalidateCache(forApp: key)
        }
    }

    /// Looks up a previously recorded variant for a Mac `.app`, requiring matching title ID, Info.plist size, and mtime.
    package static func lookup(
        appPath: String,
        titleID: String,
        plistSize: UInt64,
        plistModified: TimeInterval,
        home: String = NSHomeDirectory()
    ) -> EngineUpstreamKind? {
        let key = normalizedKey(appPath)
        guard !key.isEmpty else { return nil }
        let upperID = titleID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        lock.lock()
        defer { lock.unlock() }
        let url = storeURL(home: home)
        loadLocked(url: url)
        guard let rec = cache[key],
              rec.upstream.isNxnativeVariant,
              rec.titleID == upperID,
              rec.plistSize == plistSize,
              abs(rec.plistModified - plistModified) < 0.001 else {
            return nil
        }
        return rec.upstream
    }
}
