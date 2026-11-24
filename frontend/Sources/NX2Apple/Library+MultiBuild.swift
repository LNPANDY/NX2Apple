import Foundation
import NXCore

/// A built Mac `.app` artifact associated with a specific engine upstream for a `LibraryGame`.
struct LibraryMacBuild: Codable, Equatable, Hashable {
    var upstream: EngineUpstreamKind
    var appPath: String
    var toolsCommit: String = ""
    var lastUpdated: Date? = nil

    enum CodingKeys: String, CodingKey {
        case upstream
        case appPath
        case toolsCommit
        case lastUpdated
    }

    init(upstream: EngineUpstreamKind, appPath: String, toolsCommit: String = "", lastUpdated: Date? = nil) {
        self.upstream = upstream
        self.appPath = appPath
        self.toolsCommit = toolsCommit
        self.lastUpdated = lastUpdated
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        upstream = try c.decode(EngineUpstreamKind.self, forKey: .upstream)
        appPath = try c.decode(String.self, forKey: .appPath)
        toolsCommit = try c.decodeIfPresent(String.self, forKey: .toolsCommit) ?? ""
        lastUpdated = try c.decodeIfPresent(Date.self, forKey: .lastUpdated)
    }
}

extension LibraryGame {
    /// All recorded Mac `.app` builds in deterministic UI order (`nxnative` first).
    var sortedMacBuilds: [LibraryMacBuild] {
        if !macBuilds.isEmpty {
            let order = Dictionary(uniqueKeysWithValues: EngineUpstreamKind.displayOrder.enumerated().map { ($0.element, $0.offset) })
            return macBuilds.values.sorted {
                let lhs = order[$0.upstream] ?? Int.max
                let rhs = order[$1.upstream] ?? Int.max
                if lhs != rhs { return lhs < rhs }
                return $0.upstream.rawValue < $1.upstream.rawValue
            }
        }
        guard !appPath.isEmpty else { return [] }
        let inferred = Self.inferMacUpstream(appPath: appPath, titleID: titleID)
        return [LibraryMacBuild(upstream: inferred, appPath: appPath, toolsCommit: toolsCommit)]
    }

    /// Mac build entry for a specific engine, falling back to legacy `appPath` when `macBuilds` has not been populated yet.
    func macBuild(for upstream: EngineUpstreamKind) -> LibraryMacBuild? {
        if let hit = macBuilds[upstream.rawValue] { return hit }
        guard macBuilds.isEmpty, !appPath.isEmpty else { return nil }
        let inferred = Self.inferMacUpstream(appPath: appPath, titleID: titleID)
        guard inferred == upstream else { return nil }
        return LibraryMacBuild(upstream: upstream, appPath: appPath, toolsCommit: toolsCommit)
    }

    /// Validated `nxnative` Mac build eligible for `ToolsAge` inspection and `--romfs-from` fast refresh.
    var nxnativeMacBuildForRefresh: LibraryMacBuild? {
        guard let build = macBuild(for: .nxnative), !build.appPath.isEmpty else { return nil }
        guard let bundle = try? MacGameBundle.read(URL(fileURLWithPath: build.appPath)),
              bundle.titleID == titleID,
              bundle.upstream == .nxnative else { return nil }
        return build
    }

    /// All distinct Mac `.app` paths registered for this game (for FreeSpace protection and cleanup).
    var allMacAppPaths: [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for path in sortedMacBuilds.map(\.appPath) + [appPath] where !path.isEmpty {
            if seen.insert(path).inserted { out.append(path) }
        }
        return out
    }

    /// All distinct exported IPA paths registered for this game (for FreeSpace protection and cleanup).
    var allIPAPaths: [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for path in ipaBuilds.values.sorted() + [ipaPath] where !path.isEmpty {
            if seen.insert(path).inserted { out.append(path) }
        }
        return out
    }

    /// Resolves the active Mac build from `DefaultBuildPreference` (UserDefaults) -> `preferredMacUpstream` -> `nxnative` -> first sorted.
    func resolvedActiveMacBuild(defaults: UserDefaults? = .standard) -> LibraryMacBuild? {
        let builds = sortedMacBuilds
        guard !builds.isEmpty else { return nil }
        let storedPref = defaults.flatMap { DefaultBuildPreference.get(titleID: titleID, defaults: $0) }
        let localPref = preferredMacUpstream.flatMap(EngineUpstreamKind.init(rawValue:))
        let resolved = DefaultBuildPreference.resolveActive(
            preferred: storedPref ?? localPref,
            available: builds.map(\.upstream)
        )
        return resolved.flatMap { up in builds.first { $0.upstream == up } } ?? builds.first
    }

    /// Engine of the currently active Mac build (defaults to `.nxnative` if only legacy or empty).
    func activeMacUpstream(defaults: UserDefaults? = .standard) -> EngineUpstreamKind? {
        resolvedActiveMacBuild(defaults: defaults)?.upstream
    }

    /// Returns a transient copy whose `appPath` points to a specific engine's Mac build (used for per-engine launch).
    func targetingMacBuild(_ upstream: EngineUpstreamKind) -> LibraryGame? {
        guard let build = macBuild(for: upstream), !build.appPath.isEmpty else { return nil }
        var copy = self
        copy.appPath = build.appPath
        return copy
    }

    /// Synchronizes legacy `appPath` / `ipaPath` / `toolsCommit` with the active build without discarding other engines.
    mutating func syncActiveBuilds(defaults: UserDefaults? = .standard) {
        if let active = resolvedActiveMacBuild(defaults: defaults) {
            appPath = active.appPath
            if !active.toolsCommit.isEmpty {
                toolsCommit = active.toolsCommit
            }
        } else if !macBuilds.isEmpty || appPath.isEmpty {
            appPath = ""
        }
        if !ipaBuilds.isEmpty {
            let activeUp = resolvedActiveMacBuild(defaults: defaults)?.upstream
            let resolvedIPA = DefaultBuildPreference.resolveActive(
                preferred: activeUp ?? preferredMacUpstream.flatMap(EngineUpstreamKind.init(rawValue:)),
                available: ipaBuilds.keys.compactMap(EngineUpstreamKind.init(rawValue:))
            )
            ipaPath = resolvedIPA.flatMap { ipaBuilds[$0.rawValue] } ?? ipaBuilds.values.sorted().first ?? ""
        }
    }

    /// Infers an engine kind from bundle metadata or known filename hints without crashing on unmounted disks.
    static func inferMacUpstream(appPath: String, titleID: String) -> EngineUpstreamKind {
        if !appPath.isEmpty, let bundle = try? MacGameBundle.read(URL(fileURLWithPath: appPath)) {
            return bundle.upstream
        }
        let filename = URL(fileURLWithPath: appPath).deletingPathExtension().lastPathComponent
        for kind in EngineUpstreamKind.allCases {
            let suffix = kind.appFilenameSuffix
            if !suffix.isEmpty, filename.hasSuffix(" [\(suffix)]") {
                return kind
            }
        }
        return .nxnative
    }

    static func inferIPAUpstream(ipaPath: String) -> EngineUpstreamKind {
        let base = URL(fileURLWithPath: ipaPath).deletingPathExtension().lastPathComponent.lowercased()
        for kind in EngineUpstreamKind.allCases where kind != .nxnative {
            if base.hasSuffix("-" + kind.rawValue.lowercased()) {
                return kind
            }
        }
        return .nxnative
    }
}

extension GameLibrary {
    /// Non-nil only when this library should mirror default-engine preferences to UserDefaults (production app or injected test defaults).
    var preferenceDefaults: UserDefaults? { persistsDefaultsPreference ? defaults : nil }

    /// Migrates pre-multi-build `appPath` and `ipaPath` fields into `macBuilds` and `ipaBuilds` dictionaries once on load.
    func migrateLegacyBuildsIfNeeded() {
        var changed = false
        for i in games.indices {
            if !games[i].appPath.isEmpty && games[i].macBuilds.isEmpty {
                let upstream = LibraryGame.inferMacUpstream(appPath: games[i].appPath, titleID: games[i].titleID)
                games[i].macBuilds[upstream.rawValue] = LibraryMacBuild(
                    upstream: upstream,
                    appPath: games[i].appPath,
                    toolsCommit: games[i].toolsCommit
                )
                changed = true
            }
            if !games[i].ipaPath.isEmpty && games[i].ipaBuilds.isEmpty {
                let upstream = LibraryGame.inferIPAUpstream(ipaPath: games[i].ipaPath)
                games[i].ipaBuilds[upstream.rawValue] = games[i].ipaPath
                changed = true
            }
        }
        if changed { save() }
    }

    /// Check-Read-Revalidate pruning across all engine builds (`macBuilds` and `ipaBuilds`).
    /// Paths on unmounted volumes are kept; missing or invalid bundles on mounted disks are pruned.
    @discardableResult
    func pruneMultiBuilds(volumes: String = "/Volumes", persist: Bool = true) -> Bool {
        let fm = FileManager.default
        func isGone(_ path: String) -> Bool {
            !path.isEmpty && !Self.onUnmountedVolume(path, volumes: volumes) && !fm.fileExists(atPath: path)
        }
        var changed = false
        for index in games.indices {
            var game = games[index]
            var nextMacBuilds: [String: LibraryMacBuild] = [:]
            for (_, entry) in game.macBuilds {
                guard !entry.appPath.isEmpty else { changed = true; continue }
                if Self.onUnmountedVolume(entry.appPath, volumes: volumes) {
                    nextMacBuilds[entry.upstream.rawValue] = entry
                    continue
                }
                guard fm.fileExists(atPath: entry.appPath) else {
                    changed = true
                    continue
                }
                var updated = entry
                if let bundle = try? MacGameBundle.read(URL(fileURLWithPath: entry.appPath)) {
                    guard bundle.titleID == game.titleID else {
                        changed = true
                        continue
                    }
                    if bundle.upstream != entry.upstream {
                        updated.upstream = bundle.upstream
                        changed = true
                    }
                } else if let plist = NSDictionary(contentsOfFile: entry.appPath + "/Contents/Info.plist"),
                          let rawTID = (plist["DMTitleID"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !rawTID.isEmpty,
                          rawTID.caseInsensitiveCompare(game.titleID) != .orderedSame {
                    changed = true
                    continue
                }
                // Keep existing entry if another valid path already claims this upstream, else store.
                if nextMacBuilds[updated.upstream.rawValue] == nil {
                    nextMacBuilds[updated.upstream.rawValue] = updated
                }
            }
            if nextMacBuilds != game.macBuilds {
                game.macBuilds = nextMacBuilds
                changed = true
            }

            var nextIPABuilds = game.ipaBuilds
            for (key, path) in game.ipaBuilds where path.isEmpty || isGone(path) {
                nextIPABuilds.removeValue(forKey: key)
                changed = true
            }
            if nextIPABuilds != game.ipaBuilds {
                game.ipaBuilds = nextIPABuilds
                changed = true
            }

            let prevApp = game.appPath
            let prevIPA = game.ipaPath
            if !game.macBuilds.isEmpty {
                game.syncActiveBuilds(defaults: preferenceDefaults)
            } else if isGone(game.appPath) {
                game.appPath = ""
            }
            if !game.ipaBuilds.isEmpty {
                game.syncActiveBuilds(defaults: preferenceDefaults)
            } else if isGone(game.ipaPath) {
                game.ipaPath = ""
            }
            if game.appPath != prevApp || game.ipaPath != prevIPA { changed = true }
            games[index] = game
        }
        if changed && persist {
            invalidateArtworkStates()
            save()
        }
        return changed
    }

    /// Merges a scanned `.app` into the matching game card (or creates one) without overwriting other engines' builds.
    @discardableResult
    func mergeDiscoveredApp(_ url: URL) throws -> UUID {
        let app = try MacGameBundle.read(url)
        let upstream = app.upstream
        let path = url.standardizedFileURL.path
        var game = games.first { $0.titleID == app.titleID } ?? LibraryGame(titleID: app.titleID, name: app.name)
        if game.name != app.name && (LibraryGame.needsBetterName(game) || game.macBuilds.isEmpty) {
            game.name = app.name
        }
        if !app.titleNames.isEmpty {
            game.titleNames = app.titleNames
        }
        let existingEntry = game.macBuilds[upstream.rawValue]
        let keepExisting = existingEntry.map { entry in
            !entry.appPath.isEmpty
                && entry.appPath != path
                && FileManager.default.fileExists(atPath: entry.appPath)
        } ?? false
        if !keepExisting {
            game.macBuilds[upstream.rawValue] = LibraryMacBuild(
                upstream: upstream,
                appPath: path,
                toolsCommit: existingEntry?.appPath == path ? existingEntry?.toolsCommit ?? "" : "",
                lastUpdated: existingEntry?.appPath == path ? existingEntry?.lastUpdated : nil
            )
        }
        game.syncActiveBuilds(defaults: preferenceDefaults)
        upsert(game)
        return game.id
    }

    /// Sets the preferred default Mac engine for a game and updates `DefaultBuildPreference` + `appPath`.
    func setPreferredMacUpstream(_ upstream: EngineUpstreamKind?, for id: UUID) {
        guard var game = games.first(where: { $0.id == id }) else { return }
        if let preferenceDefaults {
            DefaultBuildPreference.set(upstream, titleID: game.titleID, defaults: preferenceDefaults)
        }
        game.preferredMacUpstream = upstream?.rawValue
        game.syncActiveBuilds(defaults: preferenceDefaults)
        upsert(game)
    }

    /// Records a single exported IPA artifact for a specific engine upstream.
    func recordCompletedIPA(path: String, upstream: EngineUpstreamKind, for id: UUID) {
        guard !path.isEmpty, var game = games.first(where: { $0.id == id }) else { return }
        if (path as NSString).lastPathComponent.lowercased() == "nx2apple.ipa" {
            game.shellIPAExists = true
        } else {
            game.ipaBuilds[upstream.rawValue] = path
            game.ipaPath = path
        }
        upsert(game)
    }

    /// Removes a single engine's build artifact(s) from the game card without deleting the whole game,
    /// or removes the entire game entry if no artifacts or inputs remain.
    func removeBuildArtifact(upstream: EngineUpstreamKind, for id: UUID) {
        guard var game = games.first(where: { $0.id == id }) else { return }
        game.macBuilds.removeValue(forKey: upstream.rawValue)
        game.ipaBuilds.removeValue(forKey: upstream.rawValue)
        if game.preferredMacUpstream == upstream.rawValue {
            game.preferredMacUpstream = nil
        }
        if let preferenceDefaults, DefaultBuildPreference.get(titleID: game.titleID, defaults: preferenceDefaults) == upstream {
            DefaultBuildPreference.set(nil, titleID: game.titleID, defaults: preferenceDefaults)
        }
        if upstream == .nxnative {
            game.hasShellFramework = false
        }
        if game.macBuilds.isEmpty { game.appPath = "" }
        if game.ipaBuilds.isEmpty { game.ipaPath = "" }
        game.syncActiveBuilds(defaults: preferenceDefaults)
        upsert(game)
    }
}
