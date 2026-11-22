import Foundation

/// 30-second anti-crash fuse for Atmosphere cheats stored under a game's `cheats/` folder.
///
/// Before launch, `recoverIfArmed()` checks for a leftover `.cheats-armed.json` from a previous
/// session that crashed within 30 seconds and automatically disables only the newly enabled entries
/// (or all armed entries if none were new, or writes `.cheats-off-<TID>` for master-only files),
/// recording `.cheats-tripped.json`. `armBeforeLaunch(buildID:)` then writes `.cheats-armed.json`
/// whenever cheats will run; after 30 seconds of stable runtime, `disarmAndRecordStable()` clears
/// `.cheats-armed.json` and updates `.cheats-stable.json`.
public struct CheatFuseGuard: Sendable {
    public static let armedFileName = ".cheats-armed.json"
    public static let stableFileName = ".cheats-stable.json"
    public static let trippedFileName = ".cheats-tripped.json"
    public static let defaultDisarmSeconds: TimeInterval = 30.0

    public struct ArmedReceipt: Codable, Equatable, Sendable {
        public let titleID: String
        public let buildID: String
        public let enabled: [String]
        public let newlyEnabled: [String]
        public let hadMasterOnly: Bool
        public let startedAt: TimeInterval

        public init(titleID: String, buildID: String, enabled: [String], newlyEnabled: [String], hadMasterOnly: Bool, startedAt: TimeInterval) {
            self.titleID = titleID
            self.buildID = buildID
            self.enabled = enabled
            self.newlyEnabled = newlyEnabled
            self.hadMasterOnly = hadMasterOnly
            self.startedAt = startedAt
        }
    }

    public struct StableReceipt: Codable, Equatable, Sendable {
        public let buildID: String
        public let enabled: [String]
        public let recordedAt: TimeInterval

        public init(buildID: String, enabled: [String], recordedAt: TimeInterval) {
            self.buildID = buildID
            self.enabled = enabled
            self.recordedAt = recordedAt
        }
    }

    public struct TrippedReceipt: Codable, Equatable, Sendable {
        public let titleID: String
        public let buildID: String
        public let disabled: [String]
        public let disabledMaster: Bool
        public let trippedAt: TimeInterval

        public init(titleID: String, buildID: String, disabled: [String], disabledMaster: Bool, trippedAt: TimeInterval) {
            self.titleID = titleID
            self.buildID = buildID
            self.disabled = disabled
            self.disabledMaster = disabledMaster
            self.trippedAt = trippedAt
        }
    }

    public let titleID: String
    public let folder: URL

    public init(titleID: String, folder: URL) {
        self.titleID = titleID.uppercased()
        self.folder = folder
    }

    public var armedURL: URL { folder.appendingPathComponent(Self.armedFileName) }
    public var stableURL: URL { folder.appendingPathComponent(Self.stableFileName) }
    public var trippedURL: URL { folder.appendingPathComponent(Self.trippedFileName) }
    public var masterOffURL: URL { folder.appendingPathComponent(".cheats-off-\(titleID)") }

    public func enabledURL(for buildID: String) -> URL {
        folder.appendingPathComponent(buildID.uppercased() + ".enabled")
    }

    public var masterOn: Bool {
        !FileManager.default.fileExists(atPath: masterOffURL.path)
    }

    public func readArmed() -> ArmedReceipt? {
        Self.decode(ArmedReceipt.self, at: armedURL)
    }

    public func readStable() -> StableReceipt? {
        Self.decode(StableReceipt.self, at: stableURL)
    }

    public func readTripped() -> TrippedReceipt? {
        Self.decode(TrippedReceipt.self, at: trippedURL)
    }

    public func clearTripped() {
        try? FileManager.default.removeItem(at: trippedURL)
    }

    /// Resolves the 16-character uppercase build ID from a framework's `dm/main.fixups.tsv`.
    public static func buildID(frameworkURL: URL) -> String? {
        let fixupsURL = frameworkURL.appendingPathComponent("dm/main.fixups.tsv")
        guard let text = try? String(contentsOf: fixupsURL, encoding: .utf8) else { return nil }
        return buildID(fixups: text)
    }

    public static func buildID(fixups text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) where line.hasPrefix("#") {
            let fields = line.dropFirst().split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 2, fields[0] == "BUILD_ID", fields[1].count >= 16 else { continue }
            let prefix = fields[1].prefix(16)
            if prefix.allSatisfy(\.isHexDigit) {
                return prefix.uppercased()
            }
        }
        return nil
    }

    /// Checks for a leftover `.cheats-armed.json` from a crashed session and automatically disables
    /// the suspected cheats, writing `.cheats-tripped.json`. Returns nil if nothing was armed.
    @discardableResult
    public func recoverIfArmed(now: Date = Date()) -> TrippedReceipt? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: armedURL.path) else { return nil }
        defer { try? fm.removeItem(at: armedURL) }
        guard let armed = readArmed() else { return nil }

        let targetBuild = armed.buildID.uppercased()
        var disabledNames: [String] = []
        var disabledMaster = false

        if !armed.newlyEnabled.isEmpty {
            disabledNames = armed.newlyEnabled
            removeKeys(Set(armed.newlyEnabled), fromBuild: targetBuild)
        } else if !armed.enabled.isEmpty {
            disabledNames = armed.enabled
            removeKeys(Set(armed.enabled), fromBuild: targetBuild)
        } else if armed.hadMasterOnly {
            disabledMaster = true
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try? Data().write(to: masterOffURL, options: .atomic)
        } else {
            return nil
        }

        let receipt = TrippedReceipt(
            titleID: titleID,
            buildID: targetBuild,
            disabled: disabledNames,
            disabledMaster: disabledMaster,
            trippedAt: now.timeIntervalSince1970
        )
        Self.encode(receipt, to: trippedURL)
        return receipt
    }

    /// Writes `.cheats-armed.json` before launch if any cheats (or master-only blocks) are active.
    /// Returns the armed receipt if armed, or nil if no cheats will run for this launch.
    @discardableResult
    public func armBeforeLaunch(buildID explicitBuildID: String?, now: Date = Date()) -> ArmedReceipt? {
        let fm = FileManager.default
        guard masterOn else { return nil }
        guard let resolvedBuild = resolveBuildID(explicit: explicitBuildID) else { return nil }

        let enabled = readEnabledList(for: resolvedBuild)
        let hasMaster = cheatFileHasMaster(buildID: resolvedBuild)
        let hadMasterOnly = enabled.isEmpty && hasMaster
        guard !enabled.isEmpty || hadMasterOnly else { return nil }

        let stable = readStable()
        let stableSet: Set<String>
        if let stable, stable.buildID.uppercased() == resolvedBuild {
            stableSet = Set(stable.enabled)
        } else {
            stableSet = []
        }
        let newlyEnabled = enabled.filter { !stableSet.contains($0) }

        let receipt = ArmedReceipt(
            titleID: titleID,
            buildID: resolvedBuild,
            enabled: enabled,
            newlyEnabled: newlyEnabled,
            hadMasterOnly: hadMasterOnly,
            startedAt: now.timeIntervalSince1970
        )
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        Self.encode(receipt, to: armedURL)
        return receipt
    }

    /// Disarms the active session after surviving the stability window and records `.cheats-stable.json`.
    @discardableResult
    public func disarmAndRecordStable(expectedBuildID: String? = nil, now: Date = Date()) -> Bool {
        let fm = FileManager.default
        guard let armed = readArmed() else { return false }
        if let expectedBuildID, armed.buildID.uppercased() != expectedBuildID.uppercased() {
            return false
        }
        let stable = StableReceipt(
            buildID: armed.buildID.uppercased(),
            enabled: armed.enabled,
            recordedAt: now.timeIntervalSince1970
        )
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        Self.encode(stable, to: stableURL)
        try? fm.removeItem(at: armedURL)
        return true
    }

    /// Removes `.cheats-armed.json` on a deliberate clean exit (such as returning to the iOS shell library).
    /// Records `.cheats-stable.json` only if the session lasted at least `threshold` seconds.
    public func disarmOnCleanReturn(elapsed: TimeInterval, threshold: TimeInterval = defaultDisarmSeconds, now: Date = Date()) {
        if elapsed >= threshold {
            disarmAndRecordStable(now: now)
        } else {
            try? FileManager.default.removeItem(at: armedURL)
        }
    }

    /// Resolves a process exit: disarms as stable when `elapsed >= threshold`, otherwise trips the fuse if still armed.
    @discardableResult
    public func handleProcessExit(elapsed: TimeInterval, threshold: TimeInterval = defaultDisarmSeconds, now: Date = Date()) -> TrippedReceipt? {
        if elapsed >= threshold {
            disarmAndRecordStable(now: now)
            return nil
        }
        return recoverIfArmed(now: now)
    }

    // MARK: - Helpers

    private var scanFolders: [URL] {
        [
            folder,
            folder.appendingPathComponent("atmosphere/contents/\(titleID)/cheats"),
            folder.appendingPathComponent("contents/\(titleID)/cheats")
        ]
    }

    private func resolveBuildID(explicit: String?) -> String? {
        if let explicit {
            let trimmed = explicit.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if trimmed.count >= 16 {
                let prefix = String(trimmed.prefix(16))
                if prefix.allSatisfy(\.isHexDigit) { return prefix }
            }
        }
        var found: Set<String> = []
        let fm = FileManager.default
        for dir in scanFolders {
            let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
            for name in names where name.count >= 20 && name.lowercased().hasSuffix(".txt") {
                let prefix = name.prefix(16)
                if prefix.allSatisfy(\.isHexDigit) {
                    found.insert(prefix.uppercased())
                }
            }
        }
        return found.count == 1 ? found.first : nil
    }

    private func readEnabledList(for buildID: String) -> [String] {
        guard let text = try? String(contentsOf: enabledURL(for: buildID), encoding: .utf8) else { return [] }
        var seen = Set<String>()
        var out: [String] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let key = String(raw)
            if !key.isEmpty, seen.insert(key).inserted {
                out.append(key)
            }
        }
        return out
    }

    private func removeKeys(_ toRemove: Set<String>, fromBuild buildID: String) {
        let url = enabledURL(for: buildID)
        let current = readEnabledList(for: buildID)
        let remaining = current.filter { !toRemove.contains($0) }
        let body = remaining.map { $0 + "\n" }.joined()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? Data(body.utf8).write(to: url, options: .atomic)
    }

    private func cheatFileHasMaster(buildID: String) -> Bool {
        let fm = FileManager.default
        let targetPrefix = buildID.uppercased()
        for dir in scanFolders {
            let names = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
            for name in names where name.count >= 20 && name.lowercased().hasSuffix(".txt") && name.prefix(16).uppercased() == targetPrefix {
                let path = dir.appendingPathComponent(name)
                guard let text = try? String(contentsOf: path, encoding: .utf8) else { continue }
                var inMaster = false
                for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
                    let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("{") && trimmed.contains("}") {
                        inMaster = true
                        continue
                    }
                    if trimmed.hasPrefix("[") {
                        inMaster = false
                        continue
                    }
                    if inMaster, containsEightHexWord(trimmed) {
                        return true
                    }
                }
                return false
            }
        }
        return false
    }

    private func containsEightHexWord(_ line: String) -> Bool {
        for token in line.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
            if token.count >= 8 && token.count % 8 == 0 && token.allSatisfy(\.isHexDigit) {
                return true
            }
        }
        return false
    }

    private static func decode<T: Decodable>(_ type: T.Type, at url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func encode<T: Encodable>(_ value: T, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// Generation-guarded runtime coordinator for iOS shell game sessions so a late 30 s disarm
/// callback from a previous game session can never disarm or stamp a subsequent session.
public final class CheatFuseSession: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var activeGuard: CheatFuseGuard?
    private var activeBuildID: String?
    private var startedAt: Date?

    public init() {}

    /// Recovers any leftover armed receipt from a prior crash, then arms the new session if cheats are active.
    /// Schedules automatic disarm after `delaySeconds` bound to the current session generation.
    @discardableResult
    public func beginSession(
        titleID: String,
        cheatsFolder: URL,
        buildID: String?,
        delaySeconds: TimeInterval = CheatFuseGuard.defaultDisarmSeconds,
        queue: DispatchQueue = DispatchQueue.global(qos: .utility)
    ) -> (tripped: CheatFuseGuard.TrippedReceipt?, armed: CheatFuseGuard.ArmedReceipt?) {
        let guardObj = CheatFuseGuard(titleID: titleID, folder: cheatsFolder)
        let tripped = guardObj.recoverIfArmed()
        let armed = guardObj.armBeforeLaunch(buildID: buildID)

        lock.lock()
        generation &+= 1
        let sessionGen = generation
        activeGuard = armed != nil ? guardObj : nil
        activeBuildID = armed?.buildID
        startedAt = armed != nil ? Date() : nil
        lock.unlock()

        if let armed, delaySeconds > 0 {
            queue.asyncAfter(deadline: .now() + delaySeconds) { [weak self] in
                self?.disarmIfMatching(generation: sessionGen, expectedBuildID: armed.buildID)
            }
        }
        return (tripped, armed)
    }

    /// Ends the active session cleanly (for example, returning to the shell library) and invalidates any pending timer.
    public func endSessionCleanly(threshold: TimeInterval = CheatFuseGuard.defaultDisarmSeconds) {
        lock.lock()
        generation &+= 1
        let guardObj = activeGuard
        let start = startedAt
        activeGuard = nil
        activeBuildID = nil
        startedAt = nil
        lock.unlock()

        if let guardObj, let start {
            let elapsed = Date().timeIntervalSince(start)
            guardObj.disarmOnCleanReturn(elapsed: elapsed, threshold: threshold)
        }
    }

    /// Cancels an armed session if launch itself failed before the guest started.
    public func abortBeforeRun() {
        lock.lock()
        generation &+= 1
        let guardObj = activeGuard
        activeGuard = nil
        activeBuildID = nil
        startedAt = nil
        lock.unlock()

        if let guardObj {
            try? FileManager.default.removeItem(at: guardObj.armedURL)
        }
    }

    private func disarmIfMatching(generation expectedGen: UInt64, expectedBuildID: String) {
        lock.lock()
        guard generation == expectedGen, let guardObj = activeGuard, activeBuildID == expectedBuildID else {
            lock.unlock()
            return
        }
        activeGuard = nil
        activeBuildID = nil
        startedAt = nil
        lock.unlock()

        guardObj.disarmAndRecordStable(expectedBuildID: expectedBuildID)
    }
}
