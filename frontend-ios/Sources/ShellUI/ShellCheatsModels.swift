import Foundation

/// Four-tier iOS cheat compatibility status shown in the iOS Cheats sheet.
public enum CheatCapability: String, Equatable, Sendable {
    /// Writes only to writable game memory: works directly on iOS without re-baking.
    case dataReady
    /// Modifies game code and already has offline trampolines baked into the current framework.
    case codeBaked
    /// Modifies game code and must be baked once via desktop fast refresh before enabling on iOS.
    case codeNeedsBake
    /// Writes to a hardcoded non-zero heap offset that may drift between saves (still directly switchable on iOS).
    case fixedHeapWarning
}

/// One parsed cheat entry for display and toggling inside `CheatsSheetView`.
public struct GameCheatEntry: Identifiable, Equatable, Sendable {
    public var id: String { key }
    public var name: String
    public var key: String
    public var section: String
    public var isMaster: Bool
    public var isLabel: Bool
    public var isSectionMarker: Bool
    public var isBroken: Bool
    public var isOnce: Bool
    public var capability: CheatCapability
    public var triggerKeys: [String]
    public var enabled: Bool
    public var hasFixedAddress: Bool
    public var unsafeCodeReason: String?

    public init(
        name: String,
        key: String,
        section: String = "",
        isMaster: Bool = false,
        isLabel: Bool = false,
        isSectionMarker: Bool = false,
        isBroken: Bool = false,
        isOnce: Bool = false,
        capability: CheatCapability = .dataReady,
        triggerKeys: [String] = [],
        enabled: Bool = false,
        hasFixedAddress: Bool = false,
        unsafeCodeReason: String? = nil
    ) {
        self.name = name
        self.key = key
        self.section = section
        self.isMaster = isMaster
        self.isLabel = isLabel
        self.isSectionMarker = isSectionMarker
        self.isBroken = isBroken
        self.isOnce = isOnce
        self.capability = capability
        self.triggerKeys = triggerKeys
        self.enabled = enabled
        self.hasFixedAddress = hasFixedAddress
        self.unsafeCodeReason = unsafeCodeReason
    }

    public var isUnsafeCode: Bool {
        unsafeCodeReason != nil
    }

    public var switchableOnIOS: Bool {
        !isMaster && !isLabel && !isBroken && !isOnce && !isUnsafeCode && capability != .codeNeedsBake
    }

    public var triggerCombo: String? {
        triggerKeys.isEmpty ? nil : triggerKeys.joined(separator: " + ")
    }
}

/// Persistent receipt written to `.cheats-fetch.json` alongside a game's cheat files.
public struct GameCheatFetchReceipt: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var titleID: String
    public var buildID: String
    public var status: String
    public var sources: [String]
    public var entryCount: Int
    public var fetchedAt: TimeInterval
    public var fileName: String
    public var fileSHA256: String
    public var origin: String
    public var detail: String

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case titleID
        case buildID
        case status
        case sources
        case entryCount
        case fetchedAt
        case fileName
        case fileSHA256
        case origin
        case detail
    }

    public init(
        schemaVersion: Int = 1,
        titleID: String,
        buildID: String,
        status: String,
        sources: [String] = [],
        entryCount: Int = 0,
        fetchedAt: TimeInterval = 0,
        fileName: String = "",
        fileSHA256: String = "",
        origin: String = "fetched",
        detail: String = ""
    ) {
        self.schemaVersion = schemaVersion
        self.titleID = titleID
        self.buildID = buildID
        self.status = status
        self.sources = sources
        self.entryCount = entryCount
        self.fetchedAt = fetchedAt
        self.fileName = fileName
        self.fileSHA256 = fileSHA256
        self.origin = origin
        self.detail = detail
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        titleID = try container.decodeIfPresent(String.self, forKey: .titleID) ?? ""
        buildID = try container.decodeIfPresent(String.self, forKey: .buildID) ?? ""
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? ""
        sources = try container.decodeIfPresent([String].self, forKey: .sources) ?? []
        entryCount = try container.decodeIfPresent(Int.self, forKey: .entryCount) ?? 0
        if let numeric = try? container.decode(Double.self, forKey: .fetchedAt) {
            fetchedAt = numeric
        } else if let rawString = try? container.decode(String.self, forKey: .fetchedAt) {
            fetchedAt = Self.parseTimestamp(rawString) ?? 0
        } else {
            fetchedAt = 0
        }
        fileName = try container.decodeIfPresent(String.self, forKey: .fileName) ?? ""
        fileSHA256 = try container.decodeIfPresent(String.self, forKey: .fileSHA256) ?? ""
        origin = try container.decodeIfPresent(String.self, forKey: .origin) ?? ""
        detail = try container.decodeIfPresent(String.self, forKey: .detail) ?? ""
    }

    public var isFoundStatus: Bool {
        status == "found" || status == "fetched"
    }

    private static func parseTimestamp(_ raw: String) -> TimeInterval? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: trimmed) {
            return date.timeIntervalSince1970
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: trimmed) {
            return date.timeIntervalSince1970
        }
        return Double(trimmed)
    }
}

/// One entry in an online cheat fetch candidate compared against the player's local `<BID>.txt`.
public struct GameCheatOnlineEntry: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var key: String
    public var isMaster: Bool
    public var isAdded: Bool
    public var rawLines: [String]
    public var capability: CheatCapability
    public var hasFixedAddress: Bool
    public var isBroken: Bool
    public var triggerKeys: [String]
    public var unsafeCodeReason: String?

    public init(
        id: String,
        name: String,
        key: String? = nil,
        isMaster: Bool = false,
        isAdded: Bool,
        rawLines: [String] = [],
        capability: CheatCapability = .dataReady,
        hasFixedAddress: Bool = false,
        isBroken: Bool = false,
        triggerKeys: [String] = [],
        unsafeCodeReason: String? = nil
    ) {
        self.id = id
        self.name = name
        self.key = key ?? name
        self.isMaster = isMaster
        self.isAdded = isAdded
        self.rawLines = rawLines
        self.capability = capability
        self.hasFixedAddress = hasFixedAddress
        self.isBroken = isBroken
        self.triggerKeys = triggerKeys
        self.unsafeCodeReason = unsafeCodeReason
    }

    public var isUnsafeCode: Bool {
        unsafeCodeReason != nil
    }

    public var rawText: String {
        rawLines.joined(separator: "\n")
    }
}

/// Structured diff and raw payload presented when online cheats are fetched while a user cheat file already exists.
public struct GameCheatOnlinePreview: Identifiable, Equatable, Sendable {
    public var id: String { "\(titleID):\(buildID):\(onlineSHA256)" }
    public var titleID: String
    public var buildID: String
    public var fileName: String
    public var sources: [String]
    public var onlineText: String
    public var onlineSHA256: String
    public var localCount: Int
    public var onlineCount: Int
    public var addedCount: Int
    public var sameNameCount: Int
    public var localOnlyCount: Int
    public var entries: [GameCheatOnlineEntry]

    public init(
        titleID: String,
        buildID: String,
        fileName: String? = nil,
        sources: [String],
        onlineText: String,
        onlineSHA256: String = "",
        localCount: Int,
        onlineCount: Int,
        addedCount: Int,
        sameNameCount: Int,
        localOnlyCount: Int,
        entries: [GameCheatOnlineEntry]
    ) {
        self.titleID = titleID
        self.buildID = buildID
        self.fileName = fileName ?? "\(buildID).txt"
        self.sources = sources
        self.onlineText = onlineText
        self.onlineSHA256 = onlineSHA256
        self.localCount = localCount
        self.onlineCount = onlineCount
        self.addedCount = addedCount
        self.sameNameCount = sameNameCount
        self.localOnlyCount = localOnlyCount
        self.entries = entries
    }
}

/// Summary of the 30-second anti-crash fuse trip shown in the iOS Cheats sheet.
public struct GameCheatFuseAlert: Equatable, Sendable {
    public var disabledItems: [String]
    public var disabledMaster: Bool

    public init(disabledItems: [String] = [], disabledMaster: Bool = false) {
        self.disabledItems = disabledItems
        self.disabledMaster = disabledMaster
    }
}

/// Lightweight per-game cheats summary displayed on the Game Settings entry row.
public struct GameCheatsSummary: Equatable, Sendable {
    public var buildID: String?
    public var totalCount: Int
    public var enabledCount: Int
    public var needsBakeCount: Int
    public var masterOn: Bool
    public var fuseTripped: Bool

    public init(
        buildID: String? = nil,
        totalCount: Int = 0,
        enabledCount: Int = 0,
        needsBakeCount: Int = 0,
        masterOn: Bool = true,
        fuseTripped: Bool = false
    ) {
        self.buildID = buildID
        self.totalCount = totalCount
        self.enabledCount = enabledCount
        self.needsBakeCount = needsBakeCount
        self.masterOn = masterOn
        self.fuseTripped = fuseTripped
    }
}

/// Full cheats state snapshot for one game, produced by `ShellHost` and rendered by `ShellUI`.
public struct GameCheatsSnapshot: Equatable, Sendable {
    public var gameID: String
    public var gameTitle: String
    public var buildID: String?
    public var hasCurrentFile: Bool
    public var otherBuildIDs: [String]
    public var masterOn: Bool
    public var entries: [GameCheatEntry]
    public var fuseAlert: GameCheatFuseAlert?
    public var exportFileURL: URL?
    public var fetchReceipt: GameCheatFetchReceipt?

    public init(
        gameID: String,
        gameTitle: String,
        buildID: String? = nil,
        hasCurrentFile: Bool = false,
        otherBuildIDs: [String] = [],
        masterOn: Bool = true,
        entries: [GameCheatEntry] = [],
        fuseAlert: GameCheatFuseAlert? = nil,
        exportFileURL: URL? = nil,
        fetchReceipt: GameCheatFetchReceipt? = nil
    ) {
        self.gameID = gameID
        self.gameTitle = gameTitle
        self.buildID = buildID
        self.hasCurrentFile = hasCurrentFile
        self.otherBuildIDs = otherBuildIDs
        self.masterOn = masterOn
        self.entries = entries
        self.fuseAlert = fuseAlert
        self.exportFileURL = exportFileURL
        self.fetchReceipt = fetchReceipt
    }

    public var visibleEntries: [GameCheatEntry] {
        entries.filter { !($0.isLabel && ($0.name.isEmpty || $0.isSectionMarker)) }
    }

    public var dataReadyCount: Int {
        entries.filter { !$0.isLabel && !$0.isBroken && !$0.isUnsafeCode && $0.capability == .dataReady }.count
    }

    public var codeBakedCount: Int {
        entries.filter { !$0.isLabel && !$0.isBroken && !$0.isUnsafeCode && $0.capability == .codeBaked }.count
    }

    public var codeNeedsBakeCount: Int {
        entries.filter { !$0.isLabel && !$0.isBroken && !$0.isUnsafeCode && $0.capability == .codeNeedsBake }.count
    }

    public var unsafeCodeCount: Int {
        entries.filter { !$0.isLabel && !$0.isBroken && $0.isUnsafeCode }.count
    }

    public var fixedHeapWarningCount: Int {
        entries.filter { !$0.isLabel && !$0.isBroken && !$0.isUnsafeCode && $0.capability == .fixedHeapWarning }.count
    }

    public var fixedAddressCount: Int {
        entries.filter { !$0.isLabel && !$0.isBroken && ($0.hasFixedAddress || $0.capability == .fixedHeapWarning) }.count
    }

    public var readyOnIOSCount: Int {
        dataReadyCount + codeBakedCount + fixedHeapWarningCount
    }

    public var totalActiveCount: Int {
        readyOnIOSCount + codeNeedsBakeCount + unsafeCodeCount
    }
}

/// Outcome of importing a `.txt` cheat file from Files on iOS.
public enum CheatImportOutcome: Equatable, Sendable {
    case imported(snapshot: GameCheatsSnapshot, buildID: String, entryCount: Int)
    case buildMismatch(fileBuildID: String?, expectedBuildID: String, fileName: String, pendingToken: String)
    case cancelled
    case failed(String)
}

/// Outcome of fetching cheats online for a game on iOS.
public enum CheatFetchOutcome: Equatable, Sendable {
    case completed(snapshot: GameCheatsSnapshot, receipt: GameCheatFetchReceipt)
    case previewRequired(snapshot: GameCheatsSnapshot, receipt: GameCheatFetchReceipt, preview: GameCheatOnlinePreview)
    case failed(String)
}

/// Outcome of applying an online cheat preview candidate (merge or replace) onto disk.
public enum CheatOnlineApplyOutcome: Equatable, Sendable {
    case applied(snapshot: GameCheatsSnapshot)
    case failed(String)
}
