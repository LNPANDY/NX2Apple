import Foundation

/// Logical grouping shown in the engine selector guide.
package enum EngineUpstreamGroup: String, Equatable, Sendable {
    case general
    case gameTuned
}

package enum EngineUpstreamKind: String, Codable, CaseIterable, Equatable, Sendable {
    case nxnative
    case s2arm
    case macNativeGames = "macnativegames"
    case nxkit
    case kidWithSword = "kidwithsword"
    case noLagKart = "nolagkart"

    /// Title ID of The Legend of Zelda: Ocarina of Time (Switch 2).
    package static let ootSwitch2TitleID = "0400486024DEC000"
    /// Title ID of Mario Kart World (Switch 2).
    package static let mkwSwitch2TitleID = "0400C3F00006E000"

    package var displayName: String {
        switch self {
        case .nxnative:
            return "nxnative"
        case .macNativeGames:
            return "MacNativeGames"
        case .s2arm:
            return "S2Arm"
        case .nxkit:
            return "nxkit (Beta)"
        case .kidWithSword:
            return "Kid with Sword"
        case .noLagKart:
            return "No Lag Kart"
        }
    }

    /// Logical section in the engine selector panel.
    package var group: EngineUpstreamGroup {
        switch self {
        case .nxnative, .nxkit, .s2arm:
            return .general
        case .macNativeGames, .kidWithSword, .noLagKart:
            return .gameTuned
        }
    }

    /// True when this engine is an external specialized `nxnative` fork driven by `scripts/build_ipa_from_nsp.py`.
    package var isNxnativeVariant: Bool {
        self == .kidWithSword || self == .noLagKart
    }

    package var cardNoteKey: String {
        switch self {
        case .nxnative:
            return "upstream.nxnativeCardNote"
        case .macNativeGames:
            return "upstream.mngCardNote"
        case .s2arm:
            return "upstream.s2armCardNote"
        case .nxkit:
            return "nxkit.betaNote"
        case .kidWithSword:
            return "upstream.kwsCardNote"
        case .noLagKart:
            return "upstream.noLagKartCardNote"
        }
    }

    /// Concise localization key describing which games this engine is intended for.
    package var scopeSummaryKey: String {
        switch self {
        case .nxnative:
            return "engine.scope.nxnative"
        case .nxkit:
            return "engine.scope.nxkit"
        case .s2arm:
            return "engine.scope.s2arm"
        case .macNativeGames:
            return "engine.scope.mng"
        case .kidWithSword:
            return "engine.scope.kws"
        case .noLagKart:
            return "engine.scope.noLagKart"
        }
    }

    /// Concise localization key highlighting this engine's standout tuning features.
    package var highlightsKey: String {
        switch self {
        case .nxnative:
            return "engine.highlights.nxnative"
        case .nxkit:
            return "engine.highlights.nxkit"
        case .s2arm:
            return "engine.highlights.s2arm"
        case .macNativeGames:
            return "engine.highlights.mng"
        case .kidWithSword:
            return "engine.highlights.kws"
        case .noLagKart:
            return "engine.highlights.noLagKart"
        }
    }

    package var isBuiltIn: Bool {
        self == .nxnative
    }

    /// The engine makes Mac apps only: the iPhone and iPad target is not offered with it.
    package var buildsMacOnly: Bool {
        self == .macNativeGames || self == .nxkit || self == .noLagKart
    }

    /// True when the engine supports building for iPhone/iPad.
    package var supportsIOS: Bool {
        !buildsMacOnly
    }

    /// True when iOS builds can target the shared NX2Apple shell app (`.framework`).
    package var supportsSharedIOSShell: Bool {
        self == .nxnative
    }

    /// True when iOS builds must produce a standalone one-game `.ipa` rather than a shared-shell framework.
    package var buildsIOSStandaloneOnly: Bool {
        self == .kidWithSword
    }

    /// The text that says so.
    package var macOnlyNoteKey: String? {
        switch self {
        case .macNativeGames: return "upstream.mngMacOnly"
        case .nxkit: return "upstream.nxkitMacOnly"
        case .noLagKart: return "upstream.noLagKartMacOnly"
        case .nxnative, .s2arm, .kidWithSword: return nil
        }
    }

    /// The engine needs no Python and no .NET: the dependency list leaves them out.
    package var needsPythonAndDotnet: Bool {
        self != .nxkit
    }

    /// Enforced 16-hex title ID allowlist for specialized engines; nil for general-purpose engines.
    package var enforcedTitleIDs: Set<String>? {
        switch self {
        case .macNativeGames:
            return MacNativeGamesBuilder.supportedTitleIDs
        case .kidWithSword:
            return [Self.ootSwitch2TitleID]
        case .noLagKart:
            return [Self.mkwSwitch2TitleID]
        case .nxnative, .s2arm, .nxkit:
            return nil
        }
    }

    /// Returns true when `raw` is allowed by this engine (always true for general engines).
    package func supportsTitleID(_ raw: String) -> Bool {
        guard let allowlist = enforcedTitleIDs else { return true }
        guard let normalized = MacNativeGamesBuilder.normalizedHex16(raw) else { return false }
        return allowlist.contains(normalized)
    }

    /// Isolated work directory suffix for non-nxnative engines so shader/PSO/extraction caches never collide across engines.
    package var workDirSuffix: String? {
        switch self {
        case .nxnative: return nil
        case .macNativeGames: return "mng"
        case .s2arm: return "s2arm"
        case .nxkit: return "nxkit"
        case .kidWithSword: return "kidwithsword"
        case .noLagKart: return "nolagkart"
        }
    }

    /// Filename suffix appended to non-nxnative Mac `.app` bundles so multiple engine builds coexist in one folder.
    package var appFilenameSuffix: String {
        switch self {
        case .nxnative: return ""
        case .macNativeGames: return "MacNativeGames"
        case .s2arm: return "S2Arm"
        case .nxkit: return "nxkit"
        case .kidWithSword: return "Kid with Sword"
        case .noLagKart: return "No Lag Kart"
        }
    }

    /// Canonical display/fallback order for multi-build cards and selectors.
    package static let displayOrder: [EngineUpstreamKind] = [
        .nxnative, .macNativeGames, .kidWithSword, .noLagKart, .s2arm, .nxkit,
    ]

    /// Distinct Mac bundle identifier for external `nxnative` variants so LaunchServices and SavedChoices never collide.
    package func personalMacBundleID(titleID: String) -> String? {
        guard isNxnativeVariant else { return nil }
        let tid = titleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard tid.count == 16, tid.allSatisfy(\.isHexDigit) else { return nil }
        return "org.nxnative.\(tid).\(rawValue)"
    }

    /// True when this engine uses the same `dm/host` save layout as `nxnative`.
    package var sharesSaveWithNxnative: Bool {
        switch self {
        case .nxnative, .macNativeGames, .kidWithSword, .noLagKart:
            return true
        case .s2arm, .nxkit:
            return false
        }
    }

    /// Remote Git branch tracked by this external engine.
    package var gitBranch: String {
        switch self {
        case .kidWithSword:
            return "L"
        case .nxnative, .s2arm, .macNativeGames, .nxkit, .noLagKart:
            return "main"
        }
    }

    /// Upstream GitHub `<owner>/<repo>` slug for downloadable external engines.
    package var repositorySlug: String? {
        switch self {
        case .macNativeGames:
            return "ly05010419/MacNativeGames"
        case .s2arm:
            return "jhaizhou-ops/S2Arm"
        case .kidWithSword:
            return "cheemu21/kid-with-sword-remake"
        case .noLagKart:
            return "kingbumi31/no-lag-kart"
        case .nxnative, .nxkit:
            return nil
        }
    }
}

package struct EngineUpstreamDescriptor: Equatable, Sendable {
    package let kind: EngineUpstreamKind
    package let markerPaths: [String]
    package let requiredTools: [String]
    package let environmentPrefixes: [String]

    package init(kind: EngineUpstreamKind, markerPaths: [String], requiredTools: [String], environmentPrefixes: [String]) {
        self.kind = kind
        self.markerPaths = markerPaths
        self.requiredTools = requiredTools
        self.environmentPrefixes = environmentPrefixes
    }
}

package enum EngineUpstream {
    package static let descriptors: [EngineUpstreamDescriptor] = [
        EngineUpstreamDescriptor(
            kind: .nxnative,
            markerPaths: ["dm/tools/nx_extract/Program.cs"],
            requiredTools: [RepoLayout.buildScript, RepoLayout.romfsImageTool],
            environmentPrefixes: ["DM_"]
        ),
        EngineUpstreamDescriptor(
            kind: .s2arm,
            markerPaths: ["pack/jobs/main.py", "runtime/rewriter/rewriter.c"],
            requiredTools: ["pack/jobs/main.py"],
            environmentPrefixes: ["S2A_", "DM_"]
        ),
        EngineUpstreamDescriptor(
            kind: .macNativeGames,
            markerPaths: ["build_app.py", "games/totk"],
            requiredTools: ["build_app.py"],
            environmentPrefixes: ["MNG_", "TOTK_"]
        ),
        EngineUpstreamDescriptor(
            kind: .nxkit,
            markerPaths: [NxkitBuilder.builderName],
            requiredTools: [NxkitBuilder.builderName, NxkitBuilder.hostName],
            environmentPrefixes: ["NXB_", "NXKIT_"]
        ),
        EngineUpstreamDescriptor(
            kind: .kidWithSword,
            markerPaths: ["dm/tools/nx_extract/Program.cs", RepoLayout.buildScript],
            requiredTools: [RepoLayout.buildScript],
            environmentPrefixes: ["DM_"]
        ),
        EngineUpstreamDescriptor(
            kind: .noLagKart,
            markerPaths: ["dm/tools/nx_extract/Program.cs", RepoLayout.buildScript],
            requiredTools: [RepoLayout.buildScript],
            environmentPrefixes: ["DM_"]
        )
    ]

    /// Ordered list of build engines offered on macOS, filtered by feature availability.
    package static func availableOnMac(
        macNativeGamesEnabled: Bool = MacNativeGamesBuilder.featureEnabled,
        s2armEnabled: Bool = S2ArmBuilder.featureEnabled,
        nxkitEnabled: Bool = NxkitBuilder.featureEnabled
    ) -> [EngineUpstreamKind] {
        var result: [EngineUpstreamKind] = [.nxnative]
        if nxkitEnabled {
            result.append(.nxkit)
        }
        if s2armEnabled {
            result.append(.s2arm)
        }
        if macNativeGamesEnabled {
            result.append(.macNativeGames)
        }
        result.append(.kidWithSword)
        result.append(.noLagKart)
        return result
    }

    /// All game-tuned engines available for `raw` title ID, ordered with dedicated single-game forks first.
    package static func tunedEngines(
        forTitleID raw: String,
        macNativeGamesEnabled: Bool = MacNativeGamesBuilder.featureEnabled
    ) -> [EngineUpstreamKind] {
        guard let tid = MacNativeGamesBuilder.normalizedHex16(raw) else { return [] }
        var result: [EngineUpstreamKind] = []
        if EngineUpstreamKind.kidWithSword.supportsTitleID(tid) {
            result.append(.kidWithSword)
        }
        if EngineUpstreamKind.noLagKart.supportsTitleID(tid) {
            result.append(.noLagKart)
        }
        if macNativeGamesEnabled && EngineUpstreamKind.macNativeGames.supportsTitleID(tid) {
            result.append(.macNativeGames)
        }
        return result
    }

    /// True when `raw` title ID has at least one dedicated game-tuned engine.
    package static func hasTunedEngine(
        forTitleID raw: String,
        macNativeGamesEnabled: Bool = MacNativeGamesBuilder.featureEnabled
    ) -> Bool {
        !tunedEngines(forTitleID: raw, macNativeGamesEnabled: macNativeGamesEnabled).isEmpty
    }

    /// Best game-tuned engine for `(raw, target)`, preferring engines that support the requested platform.
    package static func recommendedTunedEngine(
        forTitleID raw: String,
        target: String = BuildTarget.mac,
        macNativeGamesEnabled: Bool = MacNativeGamesBuilder.featureEnabled
    ) -> EngineUpstreamKind? {
        let candidates = tunedEngines(forTitleID: raw, macNativeGamesEnabled: macNativeGamesEnabled)
        guard !candidates.isEmpty else { return nil }
        let normalizedTarget = BuildTarget.normalized(target)
        if normalizedTarget != BuildTarget.mac {
            return candidates.first { $0.supportsIOS }
        }
        return candidates.first
    }

    package static func descriptor(for kind: EngineUpstreamKind) -> EngineUpstreamDescriptor {
        descriptors.first(where: { $0.kind == kind })!
    }

    package static func isTree(_ directory: String, kind: EngineUpstreamKind, fileManager fm: FileManager = .default) -> Bool {
        guard !directory.isEmpty else { return false }
        let desc = descriptor(for: kind)
        let prefix = directory.hasSuffix("/") ? directory : directory + "/"
        return desc.markerPaths.allSatisfy { fm.fileExists(atPath: prefix + $0) }
    }

    package static func detect(in directory: String, fileManager fm: FileManager = .default) -> EngineUpstreamKind? {
        guard !directory.isEmpty else { return nil }
        if EngineLayout.hasEngineTool(directory)
            || isTree(directory, kind: .nxnative, fileManager: fm)
            || isTree(directory + "/engine", kind: .nxnative, fileManager: fm) {
            return .nxnative
        }
        if isTree(directory, kind: .s2arm, fileManager: fm) {
            return .s2arm
        }
        if isTree(directory, kind: .macNativeGames, fileManager: fm) {
            return .macNativeGames
        }
        return nil
    }

    package static let macNativeGamesBundleTitleIDs: [String: String] = [
        "org.macnativegames.totk": "0100F2C0115B6000",
        "org.macnativegames.totk-native": "0100F2C0115B6000",
        "org.macnativegames.botw": "01007EF00011E000",
        "org.macnativegames.pokopia": "0400A3A01EE4C000",
        "org.macnativegames.pkp": "0400A3A01EE4C000",
        "org.macnativegames.bananza": "040074A01BF12000",
        "org.macnativegames.dkb": "040074A01BF12000",
        "org.macnativegames.oot": "0400486024DEC000",
        "org.macnativegames.oot-native": "0400486024DEC000",
        "org.macnativegames.dread": "010093801237C000",
        "org.macnativegames.ss": "01002DA013484000",
        "org.macnativegames.worldend": "010048900CF64000",
        "org.macnativegames.tmnt.private": "0100FE701475A000",
        "org.macnativegames.tmnt": "0100FE701475A000",
        "org.macnativegames.acnh": "01006F8002326000",
        "org.macnativegames.eow": "01008CF01BAAC000",
        "org.macnativegames.odyssey": "0100000000010000",
        "org.macnativegames.alc": "01007300020FA000",
        "org.macnativegames.aoc": "01002B00111A2000",
        "org.macnativegames.by3": "01004A4010FEA000",
        "org.macnativegames.jamboree": "0100965017338000",
        "org.macnativegames.la": "01006BB00C6F0000",
        "org.macnativegames.mk8d": "0100152000022000",
        "org.macnativegames.mkw": "0400C3F00006E000",
        "org.macnativegames.mvdk": "0100B99019412000",
        "org.macnativegames.ori": "010061D00DB74000",
        "org.macnativegames.ssbu": "01006A800016E000",
        "org.macnativegames.tomodachi": "010051F0207B2000",
        "org.macnativegames.unicorn": "010054B01AD92000",
        "org.macnativegames.wonder": "010015100B514000"
    ]
}
