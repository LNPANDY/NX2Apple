import Foundation

package enum S2ArmBuilder {
    package static var featureEnabled = ProcessInfo.processInfo.environment["NX2APPLE_MULTI_UPSTREAM"] != "0"

    package struct ResultSummary: Equatable, Sendable {
        package let ok: Bool
        package let ipaPath: String?
        package let packPath: String?
        package let macRootPath: String?
        package let message: String?

        package init(
            ok: Bool,
            ipaPath: String? = nil,
            packPath: String? = nil,
            macRootPath: String? = nil,
            message: String? = nil
        ) {
            self.ok = ok
            self.ipaPath = ipaPath
            self.packPath = packPath
            self.macRootPath = macRootPath
            self.message = message
        }
    }

    package static let macOneClickScript = "pack/oneclick/oneclick.sh"
    package static let defaultMinDotnetSDK = "10.0.403"
    package static let defaultDotnetRollForward = "latestFeature"
    package static let pipPackages = ["numpy", "Pillow", "fonttools", "skia-pathops"]
    package static let requiredPythonPackages: [(module: String, package: String)] = [
        ("numpy", "numpy"),
        ("PIL", "Pillow"),
        ("fontTools", "fonttools"),
        ("pathops", "skia-pathops"),
    ]

    package static func sdkRequirement(in tree: String, fileManager fm: FileManager = .default) -> (version: String, rollForward: String) {
        guard !tree.isEmpty else { return (defaultMinDotnetSDK, defaultDotnetRollForward) }
        let prefix = tree.hasSuffix("/") ? tree : tree + "/"
        let globalPath = prefix + "compat/tree/global.json"
        guard let data = fm.contents(atPath: globalPath),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let sdk = root["sdk"] as? [String: Any],
              let ver = (sdk["version"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              parseSDKVersion(ver) != nil else {
            return (defaultMinDotnetSDK, defaultDotnetRollForward)
        }
        let rf = (sdk["rollForward"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "patch"
        return (ver, rf.isEmpty ? "patch" : rf)
    }

    private static func parseSDKVersion(_ raw: String) -> (major: Int, minor: Int, band: Int, patch: Int)? {
        let core = raw.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).first
            .flatMap { $0.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false).first }
            .map(String.init) ?? raw
        let parts = core.split(separator: ".")
        guard parts.count >= 3,
              let major = Int(parts[0]),
              let minor = Int(parts[1]),
              let third = Int(parts[2]) else {
            return nil
        }
        return (major, minor, third / 100, third % 100)
    }

    package static func sdkSatisfies(
        _ version: String,
        required: String = defaultMinDotnetSDK,
        rollForward: String = defaultDotnetRollForward
    ) -> Bool {
        guard let have = parseSDKVersion(version),
              let want = parseSDKVersion(required) else {
            return false
        }
        switch rollForward {
        case "latestFeature", "feature":
            return have.major == want.major && have.minor == want.minor && (have.band, have.patch) >= (want.band, want.patch)
        case "patch", "latestPatch":
            return have.major == want.major && have.minor == want.minor && have.band == want.band && have.patch >= want.patch
        case "latestMinor", "minor":
            return have.major == want.major && (have.minor, have.band, have.patch) >= (want.minor, want.band, want.patch)
        case "latestMajor", "major":
            return (have.major, have.minor, have.band, have.patch) >= (want.major, want.minor, want.band, want.patch)
        default:
            return have == want
        }
    }

    package static func inspectDotnetSDKs(
        _ listSdks: String,
        required: String = defaultMinDotnetSDK,
        rollForward: String = defaultDotnetRollForward
    ) -> (satisfied: Bool, installedVersions: [String]) {
        var versions: [String] = []
        var satisfied = false
        for line in listSdks.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, trimmed.contains("["), trimmed.hasSuffix("]") else { continue }
            guard let ver = trimmed.split(whereSeparator: \.isWhitespace).first.map(String.init),
                  parseSDKVersion(ver) != nil else { continue }
            if !versions.contains(ver) {
                versions.append(ver)
            }
            if sdkSatisfies(ver, required: required, rollForward: rollForward) {
                satisfied = true
            }
        }
        return (satisfied, versions)
    }

    package static func findDotnet(
        _ candidates: [String] = Toolchain.dotnetCandidates(),
        tree: String = "",
        runner: ProcessRunner = SystemProcessRunner(),
        exists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> (path: String, ok: Bool, requiredVersion: String, foundOldVersion: String?) {
        let req = sdkRequirement(in: tree)
        let reqMajor = parseSDKVersion(req.version)?.major ?? 10
        let found = candidates.filter(exists)
        var bestOld: String?
        for candidate in found {
            let env = [
                "DOTNET_ROOT": (candidate as NSString).deletingLastPathComponent,
                "PATH": "/usr/bin:/bin",
                "HOME": NSHomeDirectory(),
                "TMPDIR": NSTemporaryDirectory(),
            ]
            guard let out = runner.output(candidate, ["--list-sdks"], env: env) else { continue }
            let check = inspectDotnetSDKs(out, required: req.version, rollForward: req.rollForward)
            if check.satisfied {
                return (candidate, true, req.version, nil)
            }
            if let sameMajor = check.installedVersions.last(where: { parseSDKVersion($0)?.major == reqMajor }) {
                bestOld = sameMajor
            } else if bestOld == nil, let last = check.installedVersions.last {
                bestOld = last
            }
        }
        return (found.first ?? "dotnet", false, req.version, bestOld)
    }

    package static func missingPythonPackages(
        python: String,
        runner: ProcessRunner = SystemProcessRunner()
    ) -> [String] {
        guard !python.isEmpty else { return requiredPythonPackages.map(\.package) }
        let probe = """
        import importlib.util
        checks = [("numpy", "numpy"), ("PIL", "Pillow"), ("fontTools", "fonttools"), ("pathops", "skia-pathops")]
        missing = [pkg for mod, pkg in checks if importlib.util.find_spec(mod) is None]
        print(",".join(missing))
        """
        let env = ProcessInfo.processInfo.environment.merging(BundledTools.environment(for: python)) { $1 }
        let res = runner.capture(ProcessLaunch(executable: python, arguments: ["-c", probe], environment: env))
        guard res.started, res.status == 0 else {
            return requiredPythonPackages.map(\.package)
        }
        let line = res.out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return [] }
        return line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    package static func scriptPath(in tree: String) -> String {
        let prefix = tree.hasSuffix("/") ? tree : tree + "/"
        return prefix + macOneClickScript
    }

    package static func isUsableTree(_ directory: String, fileManager fm: FileManager = .default) -> Bool {
        EngineUpstream.isTree(directory, kind: .s2arm, fileManager: fm) && fm.fileExists(atPath: scriptPath(in: directory))
    }

    package static func arguments(
        tree: String,
        sourceInput: String,
        keysPath: String,
        isUnencryptedInput: Bool,
        workDir: String,
        isMacTarget: Bool,
        titleID: String?,
        deviceUDID: String?,
        eventsFile: String
    ) -> [String] {
        var args = [scriptPath(in: tree), sourceInput]
        if !isUnencryptedInput && !keysPath.isEmpty {
            args += ["--keys", keysPath]
        }
        args += ["--out", workDir, "--target", isMacTarget ? "mac" : "ios"]
        if let titleID {
            let tid = titleID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if !tid.isEmpty {
                args += ["--title-id", tid]
            }
        }
        if !isMacTarget, let deviceUDID {
            let dev = deviceUDID.trimmingCharacters(in: .whitespacesAndNewlines)
            if !dev.isEmpty {
                args += ["--device", dev]
            }
        }
        if !eventsFile.isEmpty {
            args += ["--events", eventsFile]
        }
        return args
    }

    package static func environment(pythonPath: String, keysPath: String, isUnencryptedInput: Bool) -> [String: String] {
        var env: [String: String] = [
            "S2A_PYTHON": pythonPath,
            "PYTHONUNBUFFERED": "1"
        ]
        if !isUnencryptedInput && !keysPath.isEmpty {
            env["S2A_KEYS"] = keysPath
        }
        return env
    }

    package static func parseEvents(_ text: String) -> ResultSummary? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines.reversed() {
            guard let data = String(line).data(using: .utf8),
                  let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  (dict["ev"] as? String) == "result" else {
                continue
            }
            let ok = (dict["ok"] as? Bool) ?? false
            let ipaPath = (dict["ipa"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let packPath = (dict["pack"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let macRootPath = (dict["root"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let message = (dict["msg"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return ResultSummary(
                ok: ok,
                ipaPath: ipaPath,
                packPath: packPath,
                macRootPath: macRootPath,
                message: message
            )
        }
        return nil
    }

    package static func lastError(in log: String, eventsText: String? = nil) -> String? {
        if let eventsText, let summary = parseEvents(eventsText), !summary.ok, let msg = summary.message, !msg.isEmpty {
            return msg
        }
        let lines = log.split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines.reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                continue
            }
            if trimmed.contains("🔴") || trimmed.contains("【红】") || trimmed.hasPrefix("ERROR:") {
                return trimmed
            }
        }
        return BuildProgress.lastMeaningfulLine(log)
    }
}
