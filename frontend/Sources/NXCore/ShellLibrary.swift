import Foundation

/// The shell's library: which games are in it, and the bundle ID the app has on the device. It lives in `<shell root>/shell.json`.
package struct ShellLibrary: Codable, Equatable {
    package struct Game: Codable, Equatable {
        package var titleID: String
        package var name: String
        package var framework: String

        package init(titleID: String, name: String, framework: String) { self.titleID = titleID; self.name = name; self.framework = framework }
    }

    package init(bundleID: String = ShellLibrary.defaultBundleID, team: String = "", games: [Game] = []) {
        self.bundleID = bundleID; self.team = team; self.games = games
    }

    package static let defaultBundleID = "org.nxnative.shell"

    package var bundleID = ShellLibrary.defaultBundleID
    package var team = ""
    package var games: [Game] = []

    /// The identifier a team falls back to when `org.nxnative.shell` is registered to another team (the same per-team variant the
    /// per-game install uses). Once stored in shell.json it stays: the app's Documents (game data, saves) belong to the identifier.
    package static func teamVariant(team: String) -> String { defaultBundleID + "." + team }

    /// Normalizes a game title written to `shell.json`, preferring `game.manifest.json` when `raw` is a raw package filename or blank,
    /// and stripping `[0100...][v0]` dump tags and `.nsp`/`.xci` extensions.
    package static func cleanGameName(
        _ raw: String,
        framework: String = "",
        titleID: String = "",
        fm: FileManager = .default
    ) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = RomFSArchive.cleanPackageGameName(trimmed)
        let looksRawOrEmpty = trimmed.isEmpty
            || cleaned != trimmed
            || trimmed.caseInsensitiveCompare(titleID) == .orderedSame
        if looksRawOrEmpty,
           !framework.isEmpty,
           let data = fm.contents(atPath: framework + "/game.manifest.json"),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let manifestName = (obj["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !manifestName.isEmpty,
           manifestName.caseInsensitiveCompare(titleID) != .orderedSame {
            return manifestName
        }
        if !cleaned.isEmpty {
            return cleaned
        }
        let tid = titleID.trimmingCharacters(in: .whitespacesAndNewlines)
        return tid.isEmpty ? trimmed : tid
    }

    /// Adding a game replaces the entry with the same title ID (a rebuilt game has a new framework folder), otherwise appends.
    package mutating func add(_ game: Game) {
        var normalized = game
        normalized.name = Self.cleanGameName(game.name, framework: game.framework, titleID: game.titleID)
        if let i = games.firstIndex(where: { $0.titleID == normalized.titleID }) { games[i] = normalized } else { games.append(normalized) }
    }

    /// Drops the games whose framework folder is gone, so the shell is never built against a missing one.
    package mutating func dropMissing(exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) {
        games = games.filter { exists($0.framework) }
    }

    package static func stateFile(root: String) -> String { root + "/shell.json" }
    private static func receiptFile(root: String) -> String { root + "/.installed-games.json" }
    private static func legacyReceiptFile(root: String) -> String { ShellInstall.derivedData(root: root) + "/.installed-games.json" }
    private static func deviceReceiptFile(root: String) -> String { root + "/.installed-device" }

    /// The file's library, or a fresh one when there is none (or it cannot be read: the next save writes a valid one).
    package static func load(root: String) -> ShellLibrary {
        guard let data = FileManager.default.contents(atPath: stateFile(root: root)),
              let library = try? JSONDecoder().decode(ShellLibrary.self, from: data) else { return ShellLibrary() }
        return library
    }

    package func save(root: String) throws {
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: URL(fileURLWithPath: Self.stateFile(root: root)), options: .atomic)
    }

    /// Records that the current `shell.json` game set has been installed onto a device, returning those uppercased title IDs.
    /// Stored under `<shell root>/.installed-games.json` (outside `DmShell.app` and `derived-data` so code-signature resources stay
    /// untouched, and cleaning derived data preserves install provenance without mutating `shell.json` on a failed device install).
    @discardableResult
    package static func recordInstalled(root: String, device: String = "") -> Set<String> {
        let titles = load(root: root).games.map { $0.titleID.uppercased() }
        guard !titles.isEmpty else { return [] }
        let receipt = receiptFile(root: root)
        try? FileManager.default.createDirectory(atPath: (receipt as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? JSONEncoder().encode(titles).write(to: URL(fileURLWithPath: receipt), options: .atomic)
        let trimmedDevice = device.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedDevice.isEmpty {
            try? Data(trimmedDevice.utf8).write(to: URL(fileURLWithPath: deviceReceiptFile(root: root)), options: .atomic)
        }
        return Set(titles)
    }

    /// The UDID of the device the shared app was last installed onto, when recorded alongside `.installed-games.json`.
    package static func installedDevice(root: String) -> String {
        guard let data = FileManager.default.contents(atPath: deviceReceiptFile(root: root)),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Saves the device UDID for an existing install receipt when migrating an older receipt that stored only title IDs.
    package static func recordInstalledDevice(_ device: String, root: String) {
        let trimmed = device.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !installedReceipt(root: root).isEmpty else { return }
        try? Data(trimmed.utf8).write(to: URL(fileURLWithPath: deviceReceiptFile(root: root)), options: .atomic)
    }

    /// The uppercased title IDs from the last successful device install that are still present in `shell.json`.
    package static func installedReceipt(root: String) -> Set<String> {
        let current = Set(load(root: root).games.map { $0.titleID.uppercased() })
        guard !current.isEmpty else { return [] }
        let fm = FileManager.default
        let data = fm.contents(atPath: receiptFile(root: root)) ?? fm.contents(atPath: legacyReceiptFile(root: root))
        guard let data, let installed = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(installed.map { $0.uppercased() }).intersection(current)
    }

    /// The folder a shell root may live in: an absolute path that is not the root of a volume. `""` (no game or output
    /// folder chosen yet) and `/` both gave `/NX2Apple-shell` on the read-only system volume (#492); `home` stands in.
    package static func parentFolder(_ parent: String, home: String = NSHomeDirectory()) -> String {
        let path = (parent as NSString).expandingTildeInPath
        return path.hasPrefix("/") && path != "/" ? path : home
    }

    /// Whether a saved root can be used as it is: an absolute path below a volume root. `/NX2Apple-shell` came from an
    /// empty parent and is repaired instead of used (#492).
    package static func rootIsUsable(_ root: String) -> Bool {
        root.hasPrefix("/") && (root as NSString).pathComponents.filter { $0 != "/" }.count >= 2
    }

    /// The root the next install would use, without saving it or moving anything. The Settings page shows it before any game is
    /// chosen, and that look must not decide where builds save (#492). Since #427 the default no longer depends on the output
    /// folder: it is `ShellRootMigration.defaultRoot`. A root saved by an older version shows until `resolveRoot` moves it.
    package static func previewRoot(defaults: UserDefaults = .standard, parent: String, home: String = NSHomeDirectory()) -> String {
        if let saved = defaults.string(forKey: "shellRoot"), rootIsUsable(saved) { return saved }
        return ShellRootMigration.defaultRoot(home: home)
    }

    /// The shell root: the saved one (`shellRoot` in `defaults`), else `~/Library/Application Support/NX2Apple/shell`, which is then
    /// saved. A root that an older version made inside the output folder (`<folder>/NX2Apple-shell`) moves there once, when that is
    /// safe (`ShellRootMigration`), and otherwise stays where it is. `parent` is where an older version would have made it. A saved
    /// root at a volume root is repaired (#492).
    package static func resolveRoot(defaults: UserDefaults = .standard, parent: String, home: String = NSHomeDirectory()) -> String {
        if let saved = defaults.string(forKey: "shellRoot"), rootIsUsable(saved) {
            // A cache folder the player moved there (Move cache folder, ShellRootMove) is named like an old one but stays
            let legacy = ShellRootMigration.isLegacy(saved, home: home) && !defaults.bool(forKey: ShellRootMove.pickedKey)
            return legacy ? settle(legacy: saved, defaults: defaults, home: home) : saved
        }
        let legacy = parentFolder(parent, home: home) + "/" + ShellRootMigration.legacyName
        if FileManager.default.fileExists(atPath: legacy) { return settle(legacy: legacy, defaults: defaults, home: home) }
        let root = ShellRootMigration.defaultRoot(home: home)
        defaults.set(root, forKey: "shellRoot")
        return root
    }

    /// Moves an old root to the default place and saves the answer. When the old folder has to stay, it stays the saved root.
    private static func settle(legacy: String, defaults: UserDefaults, home: String) -> String {
        let root: String
        switch ShellRootMigration.migrate(from: legacy, to: ShellRootMigration.defaultRoot(home: home)) {
        case .moved, .nothingToMove: root = ShellRootMigration.defaultRoot(home: home)
        case .left: root = legacy
        }
        defaults.set(root, forKey: "shellRoot")
        return root
    }
}
