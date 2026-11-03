import Foundation

package enum BuildFailureClassifier {
    /// One row per message of the script. The pattern is a stable part of the text in scripts/build_ipa_from_nsp.py,
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
        ("arm32.program", .a32Program, "is a 32-bit ARM program"),
        ("keys.missing", .keys, "(?m)^\\[RED\\] no such file: "),
        ("games.several", .severalGames, "more than one game in the folder"),
        ("games.noTitleID", .noTitleID, "no NSP with a readable title ID in "),
        ("disk.low", .diskFull, "less than [0-9]+ GB free on the volume of "),
        ("disk.full", .diskFull, "No space left on device"),
        ("icloud.detritus", .cloudFolder, "resource fork, Finder information, or similar detritus not allowed"),
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
        for row in table where log.range(of: row.pattern, options: .regularExpression) != nil {
            return BuildFailure(kind: row.kind, gameName: row.kind == .a32Program ? gameName(in: log) : nil, detail: detail(of: row.kind, in: log))
        }
        // The keys file is gone or cannot be read: nx_extract stops with an exit code and no line of its own for it.
        if !inputs.keysPath.isEmpty, !inputs.isReadable(inputs.keysPath) { return BuildFailure(kind: .keys, gameName: nil) }
        return BuildFailure(kind: .unknown, gameName: nil)
    }

    private static func detail(of kind: BuildFailureKind, in log: String) -> String? {
        switch kind {
        case .diskFull:   // "less than 40 GB free on the volume of /Volumes/X/..."
            guard let r = log.range(of: #"less than [0-9]+ GB free"#, options: .regularExpression) else { return nil }
            return log[r].split(separator: " ").dropFirst(2).first.map(String.init)
        case .noTitleID:   // "no NSP with a readable title ID in /path"
            guard let r = log.range(of: #"(?m)no NSP with a readable title ID in (.+)$"#, options: .regularExpression),
                  let at = log[r].range(of: " in ") else { return nil }
            return String(log[r][at.upperBound...]).trimmingCharacters(in: .whitespaces)
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
        switch step {
        case .sign:
            if signingTeamTaken(error) { return BuildFailure(kind: .teamTaken, gameName: nil) }
            return teamListed ? nil : BuildFailure(kind: .noSigningAccount, gameName: nil)
        case .install, .copy:
            return BuildFailure(kind: .deviceTransfer, gameName: nil)
        }
    }

    /// xcodebuild's words when the app's identifier is registered to another team.
    package static func signingTeamTaken(_ error: String) -> Bool {
        error.contains("cannot be registered to your development team") || error.contains("No profiles for 'org.nxnative.")
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
