import Foundation

package enum BuildFailureClassifier {
    /// One row per message of the script. The pattern is a stable part of the text in scripts/build_ipa_from_nsp.py, dm/gfx/tools/pso_offline.py,
    /// dm/gfx/tools/own_compilers.py or dm/tools/nx_extract/Program.cs (regular expressions, searched in the log).
    /// Frontend/Tests/Fixtures/build_failures.json holds the real message for every row, and a test checks that each
    /// fragment is still in the engine's script, so a sync that rewords a message fails there instead of turning a
    /// hint into the raw last line. The Qt front end has the same table (nspb_qt/build_failure.py, compared by a test).
    package static let table: [(id: String, kind: BuildFailureKind, pattern: String)] = [
        ("rosetta.intel", .rosetta, "is an Intel one running under Rosetta"),
        ("translator.run", .translator, "the shader translator does not run"),
        ("translator.start", .translator, "the shader translator does not start"),
        ("zbic.missing", .zbic, "need the zbic package"),
        ("ios.sdk", .iosSDK, "the iOS SDK is not installed"),
        ("clt.selected", .cltSelected, "the selected developer folder is the Command Line Tools"),
        ("metal.other", .otherMetal, "Metal compiler is not the one the shaders were tested with"),
        ("shaders.regression", .shaderRegression, "a change to the translation chain broke them"),
        ("nsp.damaged", .damagedNSP, "files fail the NCA's hash check"),
        ("nup.damaged", .damagedNSP, "Pack again from a good copy of the game"),
        ("arm32.program", .a32Program, "is a 32-bit ARM program"),
        ("keys.missing", .keys, "(?m)^\\[RED\\] no such file: "),
        ("keys.old", .keysOld, "the keys are older than the game"),
        ("profile.stale", .staleProfile, "cached provisional profile describes"),
        ("games.several", .severalGames, "more than one game in the folder"),
        ("games.noTitleID", .noTitleID, "no (?:NSP|game package) with a readable (?:title ID|content meta) in "),
        ("disk.low", .diskFull, "less than [0-9]+ GB free on the volume of "),
        ("pso.low", .psoDiskFull, "pso_offline: [0-9.]+ GB free on the volume of [^\\n]+, metal-tt needs about [0-9.]+ GB for [0-9]+ bases:"),
        ("pso.merge", .psoDiskFull, "pso_offline: [0-9.]+ GB free before merging; need at least [0-9.]+ GB"),
        ("pso.failed", .psoDiskFull, "pso_offline: metal-tt failed[^\\n]+when it failed: likely out of disk space"),
        ("disk.full", .diskFull, "No space left on device"),
        ("icloud.detritus", .cloudFolder, "resource fork, Finder information, or similar detritus not allowed"),
        ("volume.swap", .volumeFormat, "\\[Errno 45\\] Operation not supported: '[^']*\\.app'"),
    ]

    /// Apple error 9120 and the surrounding 10-App-IDs-per-7-days wording on a free Apple ID.
    package static let appIDLimitPattern =
        #"(?i)(?:maximum App ID limit|(?:create|register) (?:up to|more than) 10 App IDs|10 App IDs[^\n]{0,30}7[- ]day|Reached the maximum number of[^\n]{0,40}App IDs|MaximumAppIDLimitReached|(?:DVTPortal\w*|IDEProvisioning\w*|DVTProvisioning\w*|resultCode)\b[^\n]{0,80}(?<!\d)9120(?!\d)|(?:App ID|bundle identifier|provisioning|development team|Communication with Apple|Apple Developer|register bundle)[^\n]{0,160}(?:\(\s*9120\s*\)|(?:\bcode\b|\berror\b|resultCode)\s*[=:]?\s*9120(?!\d))|(?:\(\s*9120\s*\)|(?:\bcode\b|\berror\b|resultCode)\s*[=:]?\s*9120(?!\d))[^\n]{0,160}(?:App ID|bundle identifier|provisioning|development team|Communication with Apple|Apple))"#

    /// Additional Mac launcher rules for Metal Toolchain components, game profile update mismatches, and free Apple ID limits.
    /// Kept separate from `table` so `Tests/Fixtures/build_failures.json` stays aligned with the shared Qt fixture table.
    package static let extraTable: [(id: String, kind: BuildFailureKind, pattern: String)] = [
        (id: "metal.toolchain", kind: .metalToolchain, pattern: "(?:the Metal compiler does not run|cannot execute tool 'metal'|missing Metal Toolchain|metal_(?:macosx|iphoneos): lock [^\\n]+ / actual missing|(?:use:|install it with) xcodebuild -downloadComponent MetalToolchain)"),
        (id: "pso.metalToolchain", kind: .metalToolchain, pattern: "pso_offline: metal-tt is not available"),
        (id: "update.missing", kind: .updateMismatch, pattern: "no NSP for update v[0-9]+ \\(the game profile needs these versions:"),
        (id: "profile.tables", kind: .updateMismatch, pattern: "Either these game files are not the versions the profile registers, or shader_split\\.py now reads them differently"),
        (id: "profile.builds", kind: .updateMismatch, pattern: "not the builds provisional game profile [0-9A-Fa-f]+ registers:"),
        (id: "signing.appIDLimit", kind: .appIDLimit, pattern: appIDLimitPattern),
        (id: "signing.freeLimit", kind: .freeAccountLimit, pattern: "(?i)(?:maximum number of (?:provisioning profiles|installed apps|apps for free development profiles|provisioned iOS devices)|code -36607)"),
    ]

    /// What the launcher itself knows when the log says nothing it can use. The keys file and the game files are checked
    /// first: a drive that is not connected makes every later message ("not a folder", a dangling link) a consequence.
    package struct Inputs {
        package var keysPath = ""
        package var paths: [String] = []          // the picked game files and the game folder
        package var volumes = "/Volumes"
        package var isReadable: (String) -> Bool = { FileManager.default.isReadableFile(atPath: $0) }

        package init(keysPath: String = "", paths: [String] = [], volumes: String = "/Volumes",
                     isReadable: @escaping (String) -> Bool = { FileManager.default.isReadableFile(atPath: $0) }) {
            self.keysPath = keysPath; self.paths = paths; self.volumes = volumes; self.isReadable = isReadable
        }
    }

    /// `unknown` when no row matches: the caller then keeps showing the last line of the log.
    package static func classify(_ log: String, inputs: Inputs = Inputs()) -> BuildFailure {
        for path in [inputs.keysPath] + inputs.paths where !path.isEmpty && VolumePath.onUnmounted(path, volumes: inputs.volumes) {
            let prefix = inputs.volumes.hasSuffix("/") ? inputs.volumes : inputs.volumes + "/"
            let name = path.dropFirst(prefix.count).split(separator: "/").first.map(String.init)
            return BuildFailure(kind: .driveMissing, gameName: nil, detail: name)
        }
        for row in (table + extraTable) where log.range(of: row.pattern, options: .regularExpression) != nil {
            var failure = BuildFailure(kind: row.kind, gameName: row.kind == .a32Program ? gameName(in: log) : nil, detail: detail(of: row.kind, in: log))
            if row.kind == .severalGames { failure.titleIDs = selectableTitles(in: log) }
            return failure
        }
        // The keys file is gone or cannot be read: nx_extract stops with an exit code and no line of its own for it.
        if !inputs.keysPath.isEmpty, !inputs.isReadable(inputs.keysPath) { return BuildFailure(kind: .keys, gameName: nil) }
        return BuildFailure(kind: .unknown, gameName: nil)
    }

    /// Only the engine's list of base games on the stop that advertises --title-id. Other log lines can name updates, DLC or unrelated files.
    private static func selectableTitles(in log: String) -> [String] {
        let prefix = "[RED] more than one game in the folder: "
        guard let line = log.split(separator: "\n").last(where: { $0.hasPrefix(prefix) }),
              let end = line.firstIndex(of: ";"), line[end...].contains("--title-id") else { return [] }
        let list = line[..<end].dropFirst(prefix.count)
        let ids = list.components(separatedBy: ", ")
        guard ids.count > 1, Set(ids).count == ids.count,
              ids.allSatisfy({ $0.range(of: #"^[0-9A-F]{13}000$"#, options: .regularExpression) != nil }) else { return [] }
        return ids
    }

    private static func detail(of kind: BuildFailureKind, in log: String) -> String? {
        switch kind {
        case .diskFull:   // "less than 40 GB free on the volume of /Volumes/X/..."
            guard let r = log.range(of: #"less than [0-9]+ GB free"#, options: .regularExpression) else { return nil }
            return log[r].split(separator: " ").dropFirst(2).first.map(String.init)
        case .psoDiskFull:
            guard let r = log.range(of: #"pso_offline: [^\n]+(?:metal-tt needs about|before merging; need at least) [0-9.]+ GB"#, options: .regularExpression) else { return nil }
            return log[r].split(separator: " ").dropLast().last.map(String.init)
        case .staleProfile:   // "... Preserving the existing profile at /path. Use --profile-out ..."
            guard let r = log.range(of: #"Preserving the existing profile at [^\n]+?\. (?:Use|Refusing)"#, options: .regularExpression),
                  let at = log[r].range(of: "profile at ") else { return nil }
            return String(log[r][at.upperBound...]).replacingOccurrences(of: #"\. (?:Use|Refusing)$"#, with: "", options: .regularExpression)
        case .noTitleID:   // "no game package with a readable content meta in /path" (engines before c78d7375: "no NSP with a readable title ID in /path")
            guard let r = log.range(of: #"(?m)no (?:NSP|game package) with a readable (?:title ID|content meta) in (.+)$"#, options: .regularExpression),
                  let at = log[r].range(of: " in ") else { return nil }
            return String(log[r][at.upperBound...]).trimmingCharacters(in: .whitespaces)
        case .updateMismatch:
            let marker = "the game profile needs these versions: "
            guard let r = log.range(of: #"the game profile needs these versions: ([^)\n]+)"#, options: .regularExpression),
                  let at = log[r].range(of: marker) else { return nil }
            return String(log[r][at.upperBound...]).trimmingCharacters(in: .whitespaces)
        case .appIDLimit:
            return appIDLimitReset(in: log)
        default: return nil
        }
    }

    /// A step of the install on a device that failed, with the tool's last error line. The sign step's own retry (the team's
    /// variant of the bundle ID) has run already when this is called.
    package enum InstallStep { case sign, install, copy }

    /// nil when the launcher has no better words than the tool's own line. `teamListed`: whether the chosen team is still one
    /// the Mac knows (an account signed in to Xcode, or a development certificate in the keychain).
    package static func classifyInstall(_ step: InstallStep, error: String, teamListed: Bool) -> BuildFailure? {
        if error.contains("No space left on device") { return BuildFailure(kind: .diskFull, gameName: nil) }
        if appIDLimitReached(error) { return BuildFailure(kind: .appIDLimit, gameName: nil, detail: appIDLimitReset(in: error)) }
        if freeAccountLimitReached(error) { return BuildFailure(kind: .freeAccountLimit, gameName: nil) }
        switch step {
        case .sign:
            if signingTeamTaken(error) { return BuildFailure(kind: .teamTaken, gameName: nil) }
            return teamListed ? nil : BuildFailure(kind: .noSigningAccount, gameName: nil)
        case .install, .copy:
            return BuildFailure(kind: .deviceTransfer, gameName: nil)
        }
    }

    /// Matches Apple error 9120 and the 10-App-IDs-in-7-days free developer account cap.
    package static func appIDLimitReached(_ error: String) -> Bool {
        error.range(of: appIDLimitPattern, options: .regularExpression) != nil
    }

    private static let appIDResetRegex = try? NSRegularExpression(
        pattern: #"(?i)(?:expires?|frees? up|available(?: again)?|resets?|try again|until)\s+(?:on|after|at)?\s*(\d{4}-\d{2}-\d{2}(?:[T ]\d{2}:\d{2}(?::\d{2})?(?:\s*(?:UTC|GMT|Z|[+-]\d{2}:?\d{2}))?)?|(?:Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|Jun(?:e)?|Jul(?:y)?|Aug(?:ust)?|Sep(?:t(?:ember)?)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)\s+\d{1,2},?\s+\d{4}(?:\s+(?:at\s+)?\d{1,2}:\d{2}(?:\s*[AP]M)?(?:\s*(?:UTC|GMT))?)?)"#
    )

    /// Extracts the date when the oldest App ID slot frees up, when the signing log names it.
    package static func appIDLimitReset(in log: String) -> String? {
        guard let re = appIDResetRegex,
              let match = re.firstMatch(in: log, range: NSRange(log.startIndex..., in: log)),
              let range = Range(match.range(at: 1), in: log) else { return nil }
        let value = log[range].trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n."))
        return value.isEmpty ? nil : value
    }

    /// Matches other free Apple developer account limits (such as the 3-active-apps-per-device sideloading limit).
    package static func freeAccountLimitReached(_ error: String) -> Bool {
        error.range(
            of: #"(?i)(?:maximum number of (?:provisioning profiles|installed apps|apps for free development profiles|provisioned iOS devices)|code -36607)"#,
            options: .regularExpression
        ) != nil
    }

    /// xcodebuild's words when the app's identifier is registered to another team. "No profiles for" counts only for an identifier
    /// with one part after `org.nxnative.` (`org.nxnative.shell`, or an older per-game `org.nxnative.<title ID>`): for the team's own
    /// variant (`org.nxnative.shell.<team>`) it has another cause, such as a capability the team cannot add, and the retry under the
    /// team's identifier has run already. This picks the card only: the retry has its own, wider rule (`ShellInstall.retryUnderTeamVariant`).
    package static func signingTeamTaken(_ error: String) -> Bool {
        error.contains("cannot be registered to your development team")
            || error.range(of: #"No profiles for 'org\.nxnative\.[^'.]+'"#, options: .regularExpression) != nil
    }

    /// "<name> (<title ID>) is a 32-bit ARM program": the name is "?" when the extraction has none.
    package static func gameName(in log: String) -> String? {
        guard let r = log.range(of: #"(?m)^(?:\[RED\] )?.+? \([0-9A-Fa-f]{16}\) is a 32-bit ARM program"#, options: .regularExpression) else { return nil }
        var line = String(log[r])
        if line.hasPrefix("[RED] ") { line.removeFirst(6) }
        guard let paren = line.range(of: " (", options: .backwards, range: nil, locale: nil) else { return nil }
        let name = String(line[..<paren.lowerBound]).trimmingCharacters(in: .whitespaces)
        return name.isEmpty || name == "?" ? nil : name
    }

    /// The build arguments with the one-off override added: exactly one `--allow-*`, or none.
    package static func arguments(_ args: [String], adding flag: String?) -> [String] {
        let rest = args.filter { !$0.hasPrefix("--allow-") }
        guard let flag, flag.hasPrefix("--allow-") else { return rest }
        return rest + [flag]
    }
}
