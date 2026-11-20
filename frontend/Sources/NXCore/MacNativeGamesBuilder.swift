import Foundation

package enum MacNativeGamesBuilder {
    package static var featureEnabled = ProcessInfo.processInfo.environment["NX2APPLE_MULTI_UPSTREAM"] != "0"
    package static let openFontsMarker = "NX2APPLE_OPEN_FONTS="
    /// Test hook to isolate Python 3.14 discovery from the host machine.
    package static var customPython314Candidates: [String]? = nil

    package static func uvBinDir(home: String = NSHomeDirectory()) -> String {
        home + "/Library/Application Support/NX2Apple/tools/uv"
    }

    package static func uvPythonDir(home: String = NSHomeDirectory()) -> String {
        home + "/Library/Application Support/NX2Apple/tools/uv-python"
    }

    package static func python314InstallCommand(home: String = NSHomeDirectory()) -> [String] {
        let uvBin = uvBinDir(home: home)
        let uvPy = uvPythonDir(home: home)
        let script = "curl -LsSf https://astral.sh/uv/install.sh | env UV_UNMANAGED_INSTALL=\"\(uvBin)\" sh && \"\(uvBin)/uv\" python install 3.14 --install-dir \"\(uvPy)\""
        return ["/bin/bash", "-c", script]
    }

    package static func python314Candidates(home: String = NSHomeDirectory()) -> [String] {
        if let custom = customPython314Candidates {
            return custom
        }
        let fm = FileManager.default
        var out: [String] = []
        func appendInstalls(in root: String, prefixFilter: String? = nil) {
            let dirs = ((try? fm.contentsOfDirectory(atPath: root)) ?? [])
                .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            for d in dirs {
                if let prefixFilter, !d.hasPrefix(prefixFilter) { continue }
                let bin = root + "/" + d + "/bin"
                out.append(bin + "/python3.14")
                out.append(bin + "/python3")
            }
        }
        appendInstalls(in: uvPythonDir(home: home))
        appendInstalls(in: Toolchain.uvPythonRoot)
        out.append(Toolchain.uvShimDir + "/python3.14")
        out.append("/opt/homebrew/bin/python3.14")
        out.append("/usr/local/bin/python3.14")
        out.append("/Library/Frameworks/Python.framework/Versions/3.14/bin/python3.14")
        out.append("/Library/Frameworks/Python.framework/Versions/3.14/bin/python3")
        appendInstalls(in: Toolchain.miseDataDir + "/installs/python", prefixFilter: "3.14")
        out.append(Toolchain.miseDataDir + "/shims/python3.14")
        appendInstalls(in: Toolchain.asdfDataDir + "/installs/python", prefixFilter: "3.14")
        return out
    }

    /// Finds an executable Python interpreter whose version is strictly 3.14 (`cp314` wheels).
    package static func findMNGPython314(
        candidates: [String]? = nil,
        home: String = NSHomeDirectory(),
        runner: ProcessRunner = SystemProcessRunner(),
        exists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        let list = candidates ?? python314Candidates(home: home)
        var seen = Set<String>()
        for cand in list where !cand.isEmpty && seen.insert(cand).inserted {
            guard exists(cand) else { continue }
            if let ver = Toolchain.pythonVersion(cand, runner: runner), ver == (3, 14) {
                return cand
            }
        }
        return nil
    }

    package static func needsAutoSharedFonts(
        route: Route,
        gameInput: String,
        isUnencryptedInput: Bool,
        workDir: String,
        fileManager fm: FileManager = .default
    ) -> Bool {
        guard route == .unifiedBuildApp, !isUnencryptedInput else { return false }
        let ext = (gameInput as NSString).pathExtension.lowercased()
        guard ext != "xci" else { return false }
        let manifest = workDir + "/totk/extracted/firmware/shared-fonts/manifest.json"
        return !fm.fileExists(atPath: manifest)
    }

    package static func openFontsArguments(tree: String) -> [String] {
        [
            "-c",
            "import sys; sys.path.insert(0, sys.argv[1]); from tools.deps.open_fonts import open_fonts; print(\"\(openFontsMarker)\" + str(open_fonts()))",
            tree
        ]
    }

    package static func parseOpenFontsOutput(_ stdout: String) -> String? {
        for line in stdout.split(whereSeparator: \.isNewline).reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix(openFontsMarker) {
                let value = String(trimmed.dropFirst(openFontsMarker.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty {
                    return value
                }
            }
        }
        return nil
    }

    private static let stageRegex = try! NSRegularExpression(pattern: #"(?:^|[\[\s=])(\d{1,2})\s*/\s*(\d{1,2})\]?\s+([^\r\n]+)"#)

    /// Parses MacNativeGames stage headers such as `1/4 code`, `2/4 data`, `3/4 shaders`, `4/4 app`.
    package static func parseStageLine(_ line: String) -> (index: Int, total: Int, name: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let ns = trimmed as NSString
        guard let m = stageRegex.firstMatch(in: trimmed, range: NSRange(location: 0, length: ns.length)),
              let k = Int(ns.substring(with: m.range(at: 1))),
              let n = Int(ns.substring(with: m.range(at: 2))),
              k >= 1, n >= 2, n <= 20, k <= n else {
            return nil
        }
        let rawName = ns.substring(with: m.range(at: 3))
            .trimmingCharacters(in: CharacterSet(charactersIn: " =-:.…"))
        guard !rawName.isEmpty else { return nil }
        return (k, n, rawName)
    }

    package static func generateSharedFonts(
        python: String,
        tree: String,
        environment: [String: String],
        runner: ProcessRunner = SystemProcessRunner(),
        onLine: (@Sendable (String) -> Void)? = nil
    ) -> (path: String?, log: String) {
        let launch = ProcessLaunch(
            executable: python,
            arguments: openFontsArguments(tree: tree),
            environment: environment,
            directory: tree
        )
        if let onLine {
            final class LineBox: @unchecked Sendable {
                private let lock = NSLock()
                var lines: [String] = []
                func add(_ line: String) {
                    lock.lock()
                    lines.append(line)
                    lock.unlock()
                }
            }
            let box = LineBox()
            let ok = runner.stream(launch) { line in
                box.add(line)
                if !line.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(openFontsMarker) {
                    onLine(line)
                }
            }
            let combined = box.lines.joined(separator: "\n")
            guard ok else { return (nil, combined) }
            return (parseOpenFontsOutput(combined), combined)
        }
        let res = runner.capture(launch)
        let combined = res.out + (res.err.isEmpty ? "" : "\n" + res.err)
        guard res.ok else { return (nil, combined) }
        return (parseOpenFontsOutput(res.out), combined)
    }

    package enum Route: Equatable, Sendable {
        case unifiedBuildApp
    }

    package static let supportedTitleIDs: Set<String> = [
        "0100F2C0115B6000",
        "01007EF00011E000",
        "0400486024DEC000",
        "040074A01BF12000",
        "0400A3A01EE4C000"
    ]

    /// Returns true only when `titleID` normalizes to one of the 5 upstream-maintained MacNativeGames 16-hex IDs.
    package static func supportsTitleID(_ titleID: String?) -> Bool {
        normalizedHex16(titleID).map { supportedTitleIDs.contains($0) } ?? false
    }

    /// Normalizes a 16-character hexadecimal title ID string, returning nil for empty or non-16-hex values.
    package static func normalizedHex16(_ titleID: String?) -> String? {
        guard let raw = titleID?.trimmingCharacters(in: .whitespacesAndNewlines),
              raw.count == 16,
              raw.allSatisfy(\.isHexDigit) else {
            return nil
        }
        return raw.uppercased()
    }

    package static func isUsableTree(_ directory: String, fileManager fm: FileManager = .default) -> Bool {
        EngineUpstream.isTree(directory, kind: .macNativeGames, fileManager: fm)
    }

    package static func scriptPath(for route: Route, in tree: String) -> String {
        let prefix = tree.hasSuffix("/") ? tree : tree + "/"
        switch route {
        case .unifiedBuildApp:
            return prefix + "build_app.py"
        }
    }

    package static func route(forTitleID titleID: String?, in tree: String = "", fileManager fm: FileManager = .default) -> Route? {
        _ = tree
        _ = fm
        return supportsTitleID(titleID) ? .unifiedBuildApp : nil
    }

    package static func arguments(
        route: Route,
        tree: String,
        gameInput: String,
        keysPath: String,
        isUnencryptedInput: Bool,
        updatePath: String,
        dlcPaths: [String],
        outputAppPath: String,
        workDir: String,
        sharedFontsPath: String = ""
    ) -> [String] {
        // Unencrypted inputs (.nup or unpacked Switch 2 dump folders) bundle their updates and DLCs inside gameInput;
        // passing --update or --dlc makes MacNativeGames reject the build.
        let unencrypted = isUnencryptedInput || (gameInput as NSString).pathExtension.lowercased() == "nup"
        let includesUpdate = !unencrypted && !updatePath.isEmpty && !isContainedOrSamePath(updatePath, in: gameInput)
        let externalDLCs = unencrypted ? [] : dlcPaths.filter { !$0.isEmpty && !isContainedOrSamePath($0, in: gameInput) }

        var args = [scriptPath(for: route, in: tree), gameInput]
        if !unencrypted && !keysPath.isEmpty {
            args += ["-k", keysPath]
        }
        switch route {
        case .unifiedBuildApp:
            args += ["--platform", "macos", "-o", outputAppPath, "--work", workDir]
            if !sharedFontsPath.isEmpty {
                args += ["--shared-fonts", sharedFontsPath]
            }
            if includesUpdate {
                args += ["--update", updatePath]
            }
            for dlc in externalDLCs {
                args += ["--dlc", dlc]
            }
        }
        return args
    }

    private static func isContainedOrSamePath(_ candidate: String, in parentOrSame: String) -> Bool {
        let base = normalizedPath(parentOrSame)
        let target = normalizedPath(candidate)
        guard !base.isEmpty, !target.isEmpty else { return false }
        if target == base {
            return true
        }
        let prefix = base == "/" ? "/" : base + "/"
        return target.hasPrefix(prefix)
    }

    private static func normalizedPath(_ path: String) -> String {
        guard !path.isEmpty else { return "" }
        let expanded = (path as NSString).expandingTildeInPath
        let standardized = URL(fileURLWithPath: expanded).standardized.path
        if standardized.count > 1 && standardized.hasSuffix("/") {
            return String(standardized.dropLast())
        }
        return standardized
    }

    package static func environment(languageCode: String) -> [String: String] {
        ["MNG_LANG": languageCode, "PYTHONUNBUFFERED": "1"]
    }

    package static func lastError(in log: String) -> String? {
        let lines = log.split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines.reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                continue
            }
            if trimmed.hasPrefix("ERROR:") || trimmed.hasPrefix("BuildError:") {
                return trimmed
            }
        }
        return BuildProgress.lastMeaningfulLine(log)
    }
}
