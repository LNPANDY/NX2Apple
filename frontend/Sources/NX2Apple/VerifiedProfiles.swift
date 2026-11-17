import Foundation
import SwiftUI
import NXCore

/// Thread-safe, EngineRoot-memoized lookup of Title IDs that have a verified profile under `<engineRoot>/dm/games`.
/// Disk reads happen only off the main thread and are cached per normalized engine root and `dm/games` directory modification date.
/// Empty results are never cached so an engine checkout or sync that completes later is picked up cleanly.
enum VerifiedProfiles {
    private struct CacheEntry {
        let modificationDate: Date
        let titleIDs: Set<String>
        let fullScreenTitleIDs: Set<String>
    }

    private static let lock = NSLock()
    private static var cache: [String: CacheEntry] = [:]
    private static var scanCounter = 0

    static var diskScanCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return scanCounter
    }

    static func resetCacheForTesting() {
        lock.lock()
        cache.removeAll()
        scanCounter = 0
        lock.unlock()
    }

    static func normalizedKey(_ engineRoot: String) -> String {
        guard !engineRoot.isEmpty else { return "" }
        let standardized = URL(fileURLWithPath: engineRoot).standardizedFileURL.path
        return standardized.count > 1 && standardized.hasSuffix("/") ? String(standardized.dropLast()) : standardized
    }

    /// Pure in-memory lookup with zero filesystem calls, suitable for synchronous first-frame checks on the main actor.
    static func cachedTitleIDs(engineRoot: String) -> Set<String>? {
        let key = normalizedKey(engineRoot)
        guard !key.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return cache[key]?.titleIDs
    }

    static func cachedFullScreenTitleIDs(engineRoot: String) -> Set<String>? {
        let key = normalizedKey(engineRoot)
        guard !key.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return cache[key]?.fullScreenTitleIDs
    }

    private static func loadEntry(engineRoot: String) -> (titleIDs: Set<String>, fullScreenTitleIDs: Set<String>) {
        let key = normalizedKey(engineRoot)
        guard !key.isEmpty else { return ([], []) }
        let fm = FileManager.default
        let gamesURL = URL(fileURLWithPath: key).appendingPathComponent("dm/games")
        guard let attrs = try? fm.attributesOfItem(atPath: gamesURL.path),
              let mtime = attrs[.modificationDate] as? Date else {
            lock.lock()
            cache.removeValue(forKey: key)
            lock.unlock()
            return ([], [])
        }

        lock.lock()
        if let existing = cache[key], existing.modificationDate == mtime, !existing.titleIDs.isEmpty {
            let hit = (existing.titleIDs, existing.fullScreenTitleIDs)
            lock.unlock()
            return hit
        }
        lock.unlock()

        let folders = (try? fm.contentsOfDirectory(atPath: gamesURL.path)) ?? []
        var found = Set<String>()
        var fullScreen = Set<String>()
        for folder in folders {
            let tsvURL = gamesURL.appendingPathComponent(folder).appendingPathComponent("game.tsv")
            guard let text = try? String(contentsOf: tsvURL, encoding: .utf8) else { continue }
            var profileTID: (hex: String, blockHex: String)?
            var hasFullScreen = false
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                if line.hasPrefix("#") { continue }
                let cols = line.split(separator: "\t", omittingEmptySubsequences: false)
                guard cols.count >= 2 else { continue }
                if cols[0] == "title_id", profileTID == nil {
                    let tid = cols[1].trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                    if tid.count == 16, let raw = UInt64(tid, radix: 16) {
                        profileTID = (tid, String(format: "%016llX", raw & ~0xFFF))
                    }
                } else if cols[0] == "screen_aspect" {
                    let aspect = cols[1].trimmingCharacters(in: .whitespacesAndNewlines)
                    hasFullScreen = !aspect.isEmpty && aspect != "off"
                }
            }
            if let profileTID {
                found.insert(profileTID.hex)
                found.insert(profileTID.blockHex)
                if hasFullScreen {
                    fullScreen.insert(profileTID.hex)
                    fullScreen.insert(profileTID.blockHex)
                }
            }
        }

        lock.lock()
        scanCounter += 1
        if found.isEmpty {
            cache.removeValue(forKey: key)
        } else {
            cache[key] = CacheEntry(modificationDate: mtime, titleIDs: found, fullScreenTitleIDs: fullScreen)
        }
        lock.unlock()
        return (found, fullScreen)
    }

    /// Loads the verified Title ID set for `engineRoot` off the main thread, reusing the cached set while `dm/games` is unchanged.
    static func titleIDs(engineRoot: String) -> Set<String> {
        loadEntry(engineRoot: engineRoot).titleIDs
    }

    static func fullScreenTitleIDs(engineRoot: String) -> Set<String> {
        loadEntry(engineRoot: engineRoot).fullScreenTitleIDs
    }

    /// True only when the engine's verified profile set is non-empty and neither `titleID` nor its base Title ID has a profile.
    static func isUnverified(titleID: String, verifiedTitleIDs: Set<String>) -> Bool {
        guard !verifiedTitleIDs.isEmpty else { return false }
        let upper = titleID.uppercased()
        guard upper.count == 16, let raw = UInt64(upper, radix: 16) else { return false }
        if verifiedTitleIDs.contains(upper) { return false }
        let ownerHex = String(format: "%016llX", TitleID.owner(raw))
        if verifiedTitleIDs.contains(ownerHex) { return false }
        let blockHex = String(format: "%016llX", raw & ~0xFFF)
        return !verifiedTitleIDs.contains(blockHex)
    }

    /// True when `titleID` or its base Title ID has `screen_aspect` enabled in its engine profile.
    static func supportsFullScreen(titleID: String, fullScreenTitleIDs: Set<String>) -> Bool {
        guard !fullScreenTitleIDs.isEmpty else { return false }
        let upper = titleID.uppercased()
        guard upper.count == 16, let raw = UInt64(upper, radix: 16) else { return false }
        if fullScreenTitleIDs.contains(upper) { return true }
        let ownerHex = String(format: "%016llX", TitleID.owner(raw))
        if fullScreenTitleIDs.contains(ownerHex) { return true }
        let blockHex = String(format: "%016llX", raw & ~0xFFF)
        return fullScreenTitleIDs.contains(blockHex)
    }
}

@MainActor final class VerifiedProfilesTracker: ObservableObject {
    @Published private(set) var titleIDs: Set<String> = []
    @Published private(set) var fullScreenTitleIDs: Set<String> = []
    private var generation = 0

    func refresh(engineRoot: String) {
        generation &+= 1
        let expectedGeneration = generation
        guard !engineRoot.isEmpty else {
            if !titleIDs.isEmpty { titleIDs = [] }
            if !fullScreenTitleIDs.isEmpty { fullScreenTitleIDs = [] }
            return
        }
        if let memoryHit = VerifiedProfiles.cachedTitleIDs(engineRoot: engineRoot), titleIDs != memoryHit {
            titleIDs = memoryHit
        }
        if let fsHit = VerifiedProfiles.cachedFullScreenTitleIDs(engineRoot: engineRoot), fullScreenTitleIDs != fsHit {
            fullScreenTitleIDs = fsHit
        }
        DispatchQueue.global(qos: .utility).async {
            let loaded = VerifiedProfiles.titleIDs(engineRoot: engineRoot)
            let loadedFS = VerifiedProfiles.cachedFullScreenTitleIDs(engineRoot: engineRoot) ?? []
            DispatchQueue.main.async {
                guard expectedGeneration == self.generation else { return }
                if self.titleIDs != loaded {
                    self.titleIDs = loaded
                }
                if self.fullScreenTitleIDs != loadedFS {
                    self.fullScreenTitleIDs = loadedFS
                }
            }
        }
    }

    func isUnverified(_ game: LibraryGame) -> Bool {
        VerifiedProfiles.isUnverified(titleID: game.titleID, verifiedTitleIDs: titleIDs)
    }

    func supportsFullScreen(_ game: LibraryGame) -> Bool {
        VerifiedProfiles.supportsFullScreen(titleID: game.titleID, fullScreenTitleIDs: fullScreenTitleIDs)
    }
}
