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

    /// Loads the verified Title ID set for `engineRoot` off the main thread, reusing the cached set while `dm/games` is unchanged.
    static func titleIDs(engineRoot: String) -> Set<String> {
        let key = normalizedKey(engineRoot)
        guard !key.isEmpty else { return [] }
        let fm = FileManager.default
        let gamesURL = URL(fileURLWithPath: key).appendingPathComponent("dm/games")
        guard let attrs = try? fm.attributesOfItem(atPath: gamesURL.path),
              let mtime = attrs[.modificationDate] as? Date else {
            lock.lock()
            cache.removeValue(forKey: key)
            lock.unlock()
            return []
        }

        lock.lock()
        if let existing = cache[key], existing.modificationDate == mtime, !existing.titleIDs.isEmpty {
            let hit = existing.titleIDs
            lock.unlock()
            return hit
        }
        lock.unlock()

        let folders = (try? fm.contentsOfDirectory(atPath: gamesURL.path)) ?? []
        var found = Set<String>()
        for folder in folders {
            let tsvURL = gamesURL.appendingPathComponent(folder).appendingPathComponent("game.tsv")
            guard let text = try? String(contentsOf: tsvURL, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                if line.hasPrefix("#") { continue }
                let cols = line.split(separator: "\t", omittingEmptySubsequences: false)
                guard cols.count >= 2, cols[0] == "title_id" else { continue }
                let tid = cols[1].trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                guard tid.count == 16, let raw = UInt64(tid, radix: 16) else { continue }
                found.insert(tid)
                found.insert(String(format: "%016llX", raw & ~0xFFF))
                break
            }
        }

        lock.lock()
        scanCounter += 1
        if found.isEmpty {
            cache.removeValue(forKey: key)
        } else {
            cache[key] = CacheEntry(modificationDate: mtime, titleIDs: found)
        }
        lock.unlock()
        return found
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
}

@MainActor final class VerifiedProfilesTracker: ObservableObject {
    @Published private(set) var titleIDs: Set<String> = []
    private var generation = 0

    func refresh(engineRoot: String) {
        generation &+= 1
        let expectedGeneration = generation
        guard !engineRoot.isEmpty else {
            if !titleIDs.isEmpty { titleIDs = [] }
            return
        }
        if let memoryHit = VerifiedProfiles.cachedTitleIDs(engineRoot: engineRoot), titleIDs != memoryHit {
            titleIDs = memoryHit
        }
        DispatchQueue.global(qos: .utility).async {
            let loaded = VerifiedProfiles.titleIDs(engineRoot: engineRoot)
            DispatchQueue.main.async {
                guard expectedGeneration == self.generation else { return }
                if self.titleIDs != loaded {
                    self.titleIDs = loaded
                }
            }
        }
    }

    func isUnverified(_ game: LibraryGame) -> Bool {
        VerifiedProfiles.isUnverified(titleID: game.titleID, verifiedTitleIDs: titleIDs)
    }
}
