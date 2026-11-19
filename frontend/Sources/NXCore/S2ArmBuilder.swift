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
    package static let pipPackages = ["capstone", "lz4", "zstandard", "numpy", "Pillow", "fonttools", "skia-pathops", "cmake", "meson", "ninja"]
    package static let requiredPythonPackages: [(module: String, package: String)] = [
        ("capstone", "capstone"),
        ("lz4", "lz4"),
        ("zstandard", "zstandard"),
        ("numpy", "numpy"),
        ("PIL", "Pillow"),
        ("fontTools", "fonttools"),
        ("pathops", "skia-pathops"),
    ]

    /// True when `path` or its resolved symlink target lives inside Homebrew (`/Cellar/` or `/homebrew/`).
    /// Homebrew's source-built `.NET SDK` lacks static Brotli libraries required by S2Arm's macOS host C# build.
    package static func isHomebrewDotnetPath(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        for p in [path, resolved] {
            if p.contains("/Cellar/") || p.contains("/homebrew/") {
                return true
            }
        }
        return false
    }

    /// Ordered non-Homebrew `.NET` candidate paths for S2Arm (`~/.dotnet` and `/usr/local/share/dotnet` first).
    package static func dotnetCandidates(home: String = NSHomeDirectory()) -> [String] {
        var ordered = [
            home + "/.dotnet/dotnet",
            "/usr/local/share/dotnet/dotnet",
        ]
        for cand in Toolchain.dotnetCandidates(home: home) where !ordered.contains(cand) && !isHomebrewDotnetPath(cand) {
            ordered.append(cand)
        }
        return ordered
    }

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
        _ candidates: [String] = S2ArmBuilder.dotnetCandidates(),
        tree: String = "",
        runner: ProcessRunner = SystemProcessRunner(),
        exists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> (path: String, ok: Bool, requiredVersion: String, foundOldVersion: String?) {
        let req = sdkRequirement(in: tree)
        let reqMajor = parseSDKVersion(req.version)?.major ?? 10
        let found = candidates.filter { !isHomebrewDotnetPath($0) && exists($0) }
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
        tree: String = "",
        runner: ProcessRunner = SystemProcessRunner()
    ) -> [String] {
        guard !python.isEmpty else { return requiredPythonPackages.map(\.package) }
        let pins = tree.isEmpty ? [] : S2ArmBootstrap.requirementSpecs(in: tree).pinned
        let checksLiteral = requiredPythonPackages
            .map { "(\"\($0.module)\", \"\($0.package)\")" }
            .joined(separator: ", ")
        let pinsLiteral = pins
            .map { pair -> String in
                let n = pair.name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                let v = pair.version.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                return "(\"\(n)\", \"\(v)\")"
            }
            .joined(separator: ", ")
        let probe = """
        import importlib.metadata, importlib.util
        checks = [\(checksLiteral)]
        pins = [\(pinsLiteral)]
        missing = []
        for mod, pkg in checks:
            if importlib.util.find_spec(mod) is None:
                missing.append(pkg)
        for pkg, expected in pins:
            try:
                have = importlib.metadata.version(pkg)
            except importlib.metadata.PackageNotFoundError:
                have = None
            if have != expected:
                tag = f"{pkg}=={expected}"
                if tag not in missing:
                    missing.append(tag)
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

    package struct ResolvedSource: Equatable, Sendable {
        package let directory: String
        package let stagedDirectory: String?
        package let stagingFailed: Bool

        package init(directory: String, stagedDirectory: String? = nil, stagingFailed: Bool = false) {
            self.directory = directory
            self.stagedDirectory = stagedDirectory
            self.stagingFailed = stagingFailed
        }
    }

    private static let siblingContainerExtensions: Set<String> = ["nup", "nsp", "xci", "nsz", "xcz"]

    /// Ensures the source argument passed to S2Arm's `oneclick.sh` (`cd "$1"`) is always a directory.
    /// When a single `.nup` (or other file) is selected:
    /// - if its parent folder holds only this file and no sibling `.nup`/`.nsp`/`.xci`/`.nsz`/`.xcz` packages,
    ///   passes the parent folder directly;
    /// - otherwise symlinks the file into `<workDir>/staging` via `InputStaging` and returns that directory.
    package static func resolveSourceDirectory(
        _ sourceInput: String,
        workDir: String,
        fileManager fm: FileManager = .default
    ) -> ResolvedSource {
        guard !sourceInput.isEmpty else {
            return ResolvedSource(directory: sourceInput)
        }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: sourceInput, isDirectory: &isDir), !isDir.boolValue else {
            return ResolvedSource(directory: sourceInput)
        }
        let parentDir = (sourceInput as NSString).deletingLastPathComponent
        let fileName = (sourceInput as NSString).lastPathComponent
        let siblings = ((try? fm.contentsOfDirectory(atPath: parentDir)) ?? []).filter { name in
            guard !name.hasPrefix("._") else { return false }
            let ext = (name as NSString).pathExtension.lowercased()
            guard siblingContainerExtensions.contains(ext) else { return false }
            var childIsDir: ObjCBool = false
            return fm.fileExists(atPath: parentDir + "/" + name, isDirectory: &childIsDir) && !childIsDir.boolValue
        }
        if siblings == [fileName] {
            return ResolvedSource(directory: parentDir)
        }
        let tmp = InputStaging.folder(workDir: workDir)
        let linked = InputStaging.sync(files: [sourceInput], into: tmp)
        guard linked > 0 else {
            return ResolvedSource(directory: "", stagedDirectory: nil, stagingFailed: true)
        }
        return ResolvedSource(directory: tmp, stagedDirectory: tmp)
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

    /// Computes conservative fallback concurrency floors (`S2A_DIRECT_J`, `S2A_CPU_BAKE`) from
    /// physical memory and logical CPU count so macOS file-cache pressure does not collapse
    /// `cores.sh` down to single-core serial compilation on 16+ GiB Macs.
    package static func recommendedConcurrency(
        physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory,
        cpuCount: Int = ProcessInfo.processInfo.processorCount
    ) -> (directJ: Int, cpuBake: Int)? {
        let cores = max(1, cpuCount)
        let memGiB = physicalMemoryBytes / (1024 * 1024 * 1024)
        if memGiB >= 32 {
            return (min(cores, 8), min(cores, 4))
        }
        if memGiB >= 24 {
            return (min(cores, 6), min(cores, 3))
        }
        if memGiB >= 16 {
            return (min(cores, 4), min(cores, 2))
        }
        if memGiB >= 8 {
            return (min(cores, 2), 1)
        }
        return nil
    }

    /// Applies conservative `S2A_DIRECT_J` and `S2A_CPU_BAKE` defaults when absent from both `env`
    /// and `processEnv`, never overriding caller-specified values.
    package static func environmentWithConcurrencyDefaults(
        into env: [String: String],
        processEnv: [String: String] = ProcessInfo.processInfo.environment,
        physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory,
        cpuCount: Int = ProcessInfo.processInfo.processorCount
    ) -> [String: String] {
        var out = env
        let existingDirect = (out["S2A_DIRECT_J"] ?? processEnv["S2A_DIRECT_J"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let existingBake = (out["S2A_CPU_BAKE"] ?? processEnv["S2A_CPU_BAKE"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !existingDirect.isEmpty {
            out["S2A_DIRECT_J"] = existingDirect
        }
        if !existingBake.isEmpty {
            out["S2A_CPU_BAKE"] = existingBake
        }
        guard let rec = recommendedConcurrency(physicalMemoryBytes: physicalMemoryBytes, cpuCount: cpuCount) else {
            return out
        }
        if existingDirect.isEmpty {
            out["S2A_DIRECT_J"] = String(rec.directJ)
        }
        if existingBake.isEmpty {
            out["S2A_CPU_BAKE"] = String(rec.cpuBake)
        }
        return out
    }

    /// Injects DOTNET_ROOT and prepends tool/dotnet/wrapper bin folders into PATH without duplicates.
    package static func environmentWithToolPaths(
        base: [String: String],
        dotnetPath: String?,
        extraBinDirs: [String] = [],
        home: String = NSHomeDirectory(),
        runner: ProcessRunner = SystemProcessRunner()
    ) -> [String: String] {
        var env = base
        var prepend: [String] = extraBinDirs.filter { !$0.isEmpty }
        if let dotnetPath, !dotnetPath.isEmpty {
            let binDir = (dotnetPath as NSString).deletingLastPathComponent
            if !binDir.isEmpty {
                prepend.append(binDir)
            }
            let root = Toolchain.dotnetRoot(for: dotnetPath, runner: runner) ?? binDir
            if !root.isEmpty {
                env["DOTNET_ROOT"] = root
                env["DOTNET_ROOT_ARM64"] = root
            }
        }
        prepend += [
            home + "/.dotnet",
            "/usr/local/share/dotnet",
            "/opt/homebrew/bin",
            "/usr/local/bin",
        ]
        let existing = (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
            .split(separator: ":")
            .map(String.init)
        var seen = Set<String>()
        let merged = (prepend + existing).filter { !$0.isEmpty && seen.insert($0).inserted }
        env["PATH"] = merged.joined(separator: ":")
        return env
    }

    /// Ensures a runnable `zstd` command is available on PATH for `oneclick.sh`.
    /// When neither PATH nor Homebrew/usr/local has `zstd`, writes a lightweight Python-backed
    /// wrapper at `<workDir>/.nx2a-bin/zstd` (0755) and returns its containing directory.
    package static func ensureZstdWrapper(
        workDir: String,
        python: String,
        pathEnv: String,
        fileManager fm: FileManager = .default
    ) -> String? {
        let searchDirs = pathEnv.split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        for dir in searchDirs where !dir.isEmpty {
            let candidate = (dir.hasSuffix("/") ? dir : dir + "/") + "zstd"
            if fm.isExecutableFile(atPath: candidate) {
                return nil
            }
        }
        guard !workDir.isEmpty, !python.isEmpty else { return nil }
        let binDir = (workDir.hasSuffix("/") ? workDir : workDir + "/") + ".nx2a-bin"
        let wrapperPath = binDir + "/zstd"
        let escapedPy = python.replacingOccurrences(of: "'", with: "'\\''")
        let script = """
        #!/bin/sh
        exec '\(escapedPy)' - "$@" <<'PYEOF'
        import os, sys
        try:
            from compression import zstd
        except ImportError:
            from backports import zstd

        decompress = False
        to_stdout = False
        out_path = None
        remove_src = False
        files = []
        args = sys.argv[1:]
        i = 0
        while i < len(args):
            a = args[i]
            if a == '--':
                files.extend(args[i + 1:])
                break
            if a in ('-d', '--decompress', '--uncompress'):
                decompress = True
            elif a in ('-c', '--stdout'):
                to_stdout = True
            elif a in ('-f', '--force', '-q', '--quiet', '-k', '--keep', '-T0', '--no-progress'):
                pass
            elif a == '--rm':
                remove_src = True
            elif a == '-o' and i + 1 < len(args):
                i += 1
                out_path = args[i]
            elif a.startswith('-o') and len(a) > 2:
                out_path = a[2:]
            elif a.startswith('-T') or a.startswith('--threads'):
                if a == '--threads' and i + 1 < len(args):
                    i += 1
            elif a.startswith('-') and not a.startswith('--') and len(a) > 1:
                for ch in a[1:]:
                    if ch == 'd':
                        decompress = True
                    elif ch == 'c':
                        to_stdout = True
                    elif ch in ('f', 'q', 'k'):
                        pass
            else:
                files.append(a)
            i += 1

        def run_stream(src_f, dst_f):
            data = src_f.read()
            dst_f.write(zstd.decompress(data) if decompress else zstd.compress(data))

        if not files or files == ['-']:
            run_stream(sys.stdin.buffer, sys.stdout.buffer)
            sys.exit(0)

        for src in files:
            if to_stdout:
                with open(src, 'rb') as sf:
                    run_stream(sf, sys.stdout.buffer)
            else:
                if out_path:
                    dst = out_path
                elif decompress and src.endswith('.zst'):
                    dst = src[:-4]
                elif not decompress:
                    dst = src + '.zst'
                else:
                    dst = src + '.out'
                with open(src, 'rb') as sf, open(dst, 'wb') as df:
                    run_stream(sf, df)
                if remove_src:
                    try:
                        os.remove(src)
                    except OSError:
                        pass
        PYEOF
        """
        do {
            try fm.createDirectory(atPath: binDir, withIntermediateDirectories: true)
            try Data(script.utf8).write(to: URL(fileURLWithPath: wrapperPath), options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapperPath)
            return binDir
        } catch {
            return nil
        }
    }

    private static let s2armDoneRegex = try! NSRegularExpression(pattern: #"(.+?)完成[，,]\s*用时\s*(.+)$"#)

    /// Parses S2Arm Chinese stage markers: `▶ <stage>开始` and `<stage>完成，用时<elapsed>`.
    package static func parseStageEvent(_ line: String) -> (name: String, finished: Bool, detail: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let arrow = trimmed.range(of: "▶") {
            let after = trimmed[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
            if after.hasSuffix("开始") {
                let name = String(after.dropLast(2)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty {
                    return (name, false, "")
                }
            }
        }
        let ns = trimmed as NSString
        if let m = s2armDoneRegex.firstMatch(in: trimmed, range: NSRange(location: 0, length: ns.length)) {
            let rawName = ns.substring(with: m.range(at: 1))
                .trimmingCharacters(in: CharacterSet(charactersIn: " ✓✔✅▶•·-[]"))
            let elapsed = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !rawName.isEmpty {
                return (rawName, true, elapsed)
            }
        }
        return nil
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
