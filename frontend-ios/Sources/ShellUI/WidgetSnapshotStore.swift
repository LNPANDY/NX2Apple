import CoreGraphics
import Foundation
import ImageIO
import Security
#if canImport(WidgetKit)
import WidgetKit
#endif

/// Compact JSON payload shared between `ShellHostModel` and the WidgetKit extension.
public struct WidgetSnapshotPayload: Codable, Equatable, Sendable {
    public static let currentSchema = 1

    public struct GameRecord: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var title: String
        public var version: String
        public var isSwitch2: Bool
        public var isPlayable: Bool
        public var needsData: Bool
        public var lastPlayedEpoch: Double?

        public init(
            id: String,
            title: String,
            version: String = "",
            isSwitch2: Bool = false,
            isPlayable: Bool = true,
            needsData: Bool = false,
            lastPlayedEpoch: Double? = nil
        ) {
            self.id = id
            self.title = title
            self.version = version
            self.isSwitch2 = isSwitch2
            self.isPlayable = isPlayable
            self.needsData = needsData
            self.lastPlayedEpoch = lastPlayedEpoch
        }
    }

    public var schema: Int
    public var generatedAtEpoch: Double
    public var readyCount: Int
    public var totalCount: Int
    public var games: [GameRecord]

    public init(
        schema: Int = Self.currentSchema,
        generatedAtEpoch: Double,
        readyCount: Int,
        totalCount: Int,
        games: [GameRecord]
    ) {
        self.schema = schema
        self.generatedAtEpoch = generatedAtEpoch
        self.readyCount = readyCount
        self.totalCount = totalCount
        self.games = games
    }
}

/// Three-tier snapshot bridge (App Group container -> shared team Keychain -> parent `.app/Frameworks` bundle scan)
/// with `ImageIO` thumbnail downsampling so the widget extension stays well below WidgetKit's 30 MB Jetsam ceiling
/// and compiles cleanly under `APPLICATION_EXTENSION_API_ONLY = YES`.
public enum WidgetSnapshotStore {
    public static let fileName = "widget-snapshot.json"
    public static let keychainService = "dev.nx2apple.shell.widget.v1"
    public static let keychainAccount = "snapshot"
    public static let maxStoredGames = 48
    public static let maxDecodedArtworkGames = 7
    public static let heroMaxPixelSize = 720
    public static let gridMaxPixelSize = 360
    public static let iconMaxPixelSize = 128
    private static let imageExtensions = ["png", "jpg", "jpeg", "heic", "webp"]

    private struct EmbeddedEntry {
        var id: String
        var title: String
        var version: String
        var isSwitch2: Bool
        var bannerURL: URL?
        var iconURL: URL?
    }

    private struct EmbeddedManifest: Decodable {
        var schema: Int?
        var titleID: String
        var name: String
        var displayVersion: String?
        var console: String?
        var framework: String?
        var frameworkExecutable: String?

        enum CodingKeys: String, CodingKey {
            case schema
            case titleID = "title_id"
            case name
            case displayVersion = "display_version"
            case console
            case framework
            case frameworkExecutable = "framework_executable"
        }
    }

    /// Builds a compact payload from the host's current ordered details and last-played timestamps.
    public static func makePayload(
        details: [GameDetail],
        lastPlayed: [String: Date],
        now: Date = Date()
    ) -> WidgetSnapshotPayload {
        let readyCount = details.filter { $0.game.state == .playable }.count
        let records = details.prefix(maxStoredGames).map { detail in
            let tile = detail.game
            let needsData: Bool
            switch tile.state {
            case .needsGameData, .joiningGameData: needsData = true
            default: needsData = false
            }
            return WidgetSnapshotPayload.GameRecord(
                id: tile.id,
                title: tile.title,
                version: tile.version,
                isSwitch2: tile.isSwitch2,
                isPlayable: tile.state == .playable,
                needsData: needsData,
                lastPlayedEpoch: lastPlayed[tile.id]?.timeIntervalSince1970
            )
        }
        return WidgetSnapshotPayload(
            generatedAtEpoch: now.timeIntervalSince1970,
            readyCount: readyCount,
            totalCount: details.count,
            games: records
        )
    }

    /// Writes `payload` to the local container directory (and on iOS to any provisioned App Group + Keychain + WidgetCenter).
    @discardableResult
    public static func save(
        _ payload: WidgetSnapshotPayload,
        directory: URL?,
        appGroupDirectory: URL? = defaultAppGroupDirectory(),
        reloadTimelines: Bool = true
    ) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(payload) else { return nil }
        if let directory {
            writeSnapshotFile(data, in: directory)
        }
        if let appGroupDirectory, appGroupDirectory != directory {
            writeSnapshotFile(data, in: appGroupDirectory)
        }
        #if os(iOS)
        saveKeychainSnapshot(data)
        if reloadTimelines {
            WidgetCenter.shared.reloadAllTimelines()
        }
        #endif
        return data
    }

    /// Decodes a downsampled `Artwork` directly from disk via `ImageIO` without allocating full-resolution RGBA buffers.
    public static func downsampledArtwork(at url: URL?, maxPixelSize: Int) -> Artwork? {
        guard let url, maxPixelSize > 0,
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return Artwork(id: url.path, image: cgImage)
    }

    /// Resolves the live `ShellWidgetSnapshot` for the widget extension or tests.
    /// Filtering and pinning are applied before `ImageIO` thumbnail decoding so a pinned or Switch 2 hero
    /// outside the top 7 still receives crisp `heroMaxPixelSize` artwork while staying under WidgetKit memory limits.
    public static func loadSnapshot(
        directory: URL? = nil,
        appGroupDirectory: URL? = defaultAppGroupDirectory(),
        parentAppBundle: URL? = defaultParentAppBundle(),
        keychainFallback: Bool = true,
        filter: ShellWidgetFilter = .all,
        pinnedGameID: String? = nil,
        decodeArtwork: Bool = true,
        now: Date = Date()
    ) -> ShellWidgetSnapshot {
        let embeddedEntries = scanParentBundleEntries(parentAppBundle)
        let embeddedByID = Dictionary(
            embeddedEntries.map { ($0.id.uppercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var payload = directory.flatMap(readSnapshotFile(in:))
            ?? appGroupDirectory.flatMap(readSnapshotFile(in:))
        #if os(iOS)
        if payload == nil, keychainFallback, let data = readKeychainSnapshot() {
            payload = decodePayload(data)
        }
        #endif

        let baseSnapshot: ShellWidgetSnapshot
        if let payload {
            let games: [ShellWidgetGame] = payload.games.map { record in
                let state: GameState = record.isPlayable ? .playable : (record.needsData ? .needsGameData : .broken(reason: ""))
                let played = record.lastPlayedEpoch.map {
                    ShellFormat.played(Date(timeIntervalSince1970: $0), now: now)
                }
                return ShellWidgetGame(
                    id: record.id,
                    title: record.title,
                    version: record.version,
                    state: state,
                    recentlyPlayed: played,
                    isSwitch2: record.isSwitch2
                )
            }
            baseSnapshot = ShellWidgetSnapshot(games: games, readyCount: payload.readyCount, totalCount: payload.totalCount)
        } else {
            // Tier 3 fallback: scan embedded frameworks/games directly inside parent DmShell.app before first launch.
            guard !embeddedEntries.isEmpty else { return ShellWidgetSnapshot() }
            let sortedEntries = embeddedEntries.sorted { a, b in
                let cmp = a.title.localizedCaseInsensitiveCompare(b.title)
                return cmp == .orderedSame ? a.id < b.id : cmp == .orderedAscending
            }
            let games: [ShellWidgetGame] = sortedEntries.prefix(maxStoredGames).map { entry in
                ShellWidgetGame(
                    id: entry.id,
                    title: entry.title,
                    version: entry.version,
                    state: .playable,
                    recentlyPlayed: nil,
                    isSwitch2: entry.isSwitch2
                )
            }
            baseSnapshot = ShellWidgetSnapshot(games: games, readyCount: sortedEntries.count, totalCount: sortedEntries.count)
        }

        let resolved: ShellWidgetSnapshot
        if filter == .switch2, let pinnedGameID, !pinnedGameID.isEmpty {
            resolved = baseSnapshot.resolved(filter: .switch2).resolved(filter: .pinned, pinnedGameID: pinnedGameID)
        } else {
            resolved = baseSnapshot.resolved(filter: filter, pinnedGameID: pinnedGameID)
        }

        guard decodeArtwork, !embeddedByID.isEmpty else { return resolved }
        let hydratedGames: [ShellWidgetGame] = resolved.games.enumerated().map { index, game in
            guard index < maxDecodedArtworkGames, let entry = embeddedByID[game.id.uppercased()] else {
                return game
            }
            var hydrated = game
            let bannerMax = index == 0 ? heroMaxPixelSize : gridMaxPixelSize
            hydrated.banner = downsampledArtwork(at: entry.bannerURL, maxPixelSize: bannerMax)
            hydrated.icon = downsampledArtwork(at: entry.iconURL, maxPixelSize: iconMaxPixelSize)
            return hydrated
        }
        return ShellWidgetSnapshot(games: hydratedGames, readyCount: resolved.readyCount, totalCount: resolved.totalCount)
    }

    // MARK: - Container Discovery

    public static func baseAppBundleIdentifier(from bundleID: String? = Bundle.main.bundleIdentifier) -> String? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        if bundleID.hasSuffix(".widget") {
            return String(bundleID.dropLast(".widget".count))
        }
        return bundleID
    }

    public static func defaultAppGroupDirectory(bundleID: String? = Bundle.main.bundleIdentifier) -> URL? {
        #if os(iOS)
        guard let base = baseAppBundleIdentifier(from: bundleID),
              let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group." + base) else {
            return nil
        }
        return root.appendingPathComponent("Library/Caches/nx2apple-widget", isDirectory: true)
        #else
        return nil
        #endif
    }

    /// When running inside `DmShell.app/PlugIns/DmShellWidget.appex`, returns `DmShell.app`.
    public static func defaultParentAppBundle(bundleURL: URL = Bundle.main.bundleURL) -> URL? {
        if bundleURL.pathExtension == "appex" {
            let parent = bundleURL.deletingLastPathComponent().deletingLastPathComponent()
            if parent.pathExtension == "app" { return parent }
        }
        if bundleURL.pathExtension == "app" {
            return bundleURL
        }
        return nil
    }

    private static func scanParentBundleEntries(_ appBundle: URL?) -> [EmbeddedEntry] {
        guard let appBundle else { return [] }
        let fm = FileManager.default
        var results: [EmbeddedEntry] = []
        var seen = Set<String>()
        for folderName in ["Frameworks", "Games"] {
            let root = appBundle.appendingPathComponent(folderName, isDirectory: true)
            guard let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { continue }
            for item in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let name = item.lastPathComponent
                if name.hasPrefix(".") { continue }
                guard let entry = readEmbeddedEntry(at: item, fileManager: fm),
                      seen.insert(entry.id.uppercased()).inserted else { continue }
                results.append(entry)
            }
        }
        return results
    }

    private static func readEmbeddedEntry(at dir: URL, fileManager fm: FileManager) -> EmbeddedEntry? {
        let manifestURL = dir.appendingPathComponent("game.manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(EmbeddedManifest.self, from: data),
              manifest.schema == nil || manifest.schema == 1,
              !manifest.titleID.isEmpty,
              !manifest.name.isEmpty else {
            return nil
        }
        let fwDir: URL
        if dir.pathExtension == "framework" {
            fwDir = dir
        } else if let fwName = manifest.framework, !fwName.isEmpty {
            fwDir = dir.appendingPathComponent(fwName, isDirectory: true)
        } else {
            fwDir = dir
        }
        if let exe = manifest.frameworkExecutable, !exe.isEmpty {
            guard fm.fileExists(atPath: fwDir.appendingPathComponent(exe).path) else { return nil }
        }
        let bannerURL = findArtwork(named: "banner", in: [dir, fwDir], fileManager: fm)
        let iconURL = findArtwork(named: "icon", in: [dir, fwDir], fileManager: fm)
        let isSwitch2 = manifest.console == "switch2" || manifest.titleID.uppercased().hasPrefix("0400")
        return EmbeddedEntry(
            id: manifest.titleID,
            title: manifest.name,
            version: manifest.displayVersion ?? "",
            isSwitch2: isSwitch2,
            bannerURL: bannerURL,
            iconURL: iconURL
        )
    }

    private static func findArtwork(named stem: String, in directories: [URL], fileManager fm: FileManager) -> URL? {
        for dir in directories {
            for ext in imageExtensions {
                let candidate = dir.appendingPathComponent("\(stem).\(ext)")
                if fm.fileExists(atPath: candidate.path) {
                    return candidate
                }
            }
        }
        return nil
    }

    private static func writeSnapshotFile(_ data: Data, in directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent(fileName), options: .atomic)
    }

    public static func readSnapshotFile(in directory: URL) -> WidgetSnapshotPayload? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(fileName)) else { return nil }
        return decodePayload(data)
    }

    public static func decodePayload(_ data: Data) -> WidgetSnapshotPayload? {
        guard let payload = try? JSONDecoder().decode(WidgetSnapshotPayload.self, from: data),
              payload.schema == WidgetSnapshotPayload.currentSchema else {
            return nil
        }
        return payload
    }

    // MARK: - iOS Shared Team Keychain Bridge

    #if os(iOS)
    private static func saveKeychainSnapshot(_ data: Data) {
        let baseQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: keychainAccount,
        ]
        let attributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = baseQuery
            for (k, v) in attributes { addQuery[k] = v }
            _ = SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    private static func readKeychainSnapshot() -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: keychainAccount,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        return item as? Data
    }
    #endif
}
