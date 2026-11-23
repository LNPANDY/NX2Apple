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
        enabled: Bool = false
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
    }

    public var switchableOnIOS: Bool {
        !isMaster && !isLabel && !isBroken && !isOnce && capability != .codeNeedsBake
    }

    public var triggerCombo: String? {
        triggerKeys.isEmpty ? nil : triggerKeys.joined(separator: " + ")
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

    public init(
        gameID: String,
        gameTitle: String,
        buildID: String? = nil,
        hasCurrentFile: Bool = false,
        otherBuildIDs: [String] = [],
        masterOn: Bool = true,
        entries: [GameCheatEntry] = [],
        fuseAlert: GameCheatFuseAlert? = nil,
        exportFileURL: URL? = nil
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
    }

    public var visibleEntries: [GameCheatEntry] {
        entries.filter { !($0.isLabel && ($0.name.isEmpty || $0.isSectionMarker)) }
    }

    public var dataReadyCount: Int {
        entries.filter { !$0.isLabel && !$0.isBroken && $0.capability == .dataReady }.count
    }

    public var codeBakedCount: Int {
        entries.filter { !$0.isLabel && !$0.isBroken && $0.capability == .codeBaked }.count
    }

    public var codeNeedsBakeCount: Int {
        entries.filter { !$0.isLabel && !$0.isBroken && $0.capability == .codeNeedsBake }.count
    }

    public var fixedHeapWarningCount: Int {
        entries.filter { !$0.isLabel && !$0.isBroken && $0.capability == .fixedHeapWarning }.count
    }

    public var readyOnIOSCount: Int {
        dataReadyCount + codeBakedCount + fixedHeapWarningCount
    }

    public var totalActiveCount: Int {
        readyOnIOSCount + codeNeedsBakeCount
    }
}

/// Outcome of importing a `.txt` cheat file from Files on iOS.
public enum CheatImportOutcome: Equatable, Sendable {
    case imported(snapshot: GameCheatsSnapshot, buildID: String, entryCount: Int)
    case buildMismatch(fileBuildID: String?, expectedBuildID: String, fileName: String, pendingToken: String)
    case cancelled
    case failed(String)
}
