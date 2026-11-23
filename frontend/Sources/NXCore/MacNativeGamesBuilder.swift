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

    /// True when `path` points inside NX2Apple's MNG-managed `uv-python` store (which must never leak into nxnative/S2Arm builds).
    package static func isManagedUVPython(_ path: String, home: String = NSHomeDirectory()) -> Bool {
        guard !path.isEmpty else { return false }
        let standardized = normalizedPath(path)
        let resolved = normalizedPath(URL(fileURLWithPath: (path as NSString).expandingTildeInPath).resolvingSymlinksInPath().path)
        let roots = [
            normalizedPath(uvPythonDir(home: home)),
            normalizedPath(URL(fileURLWithPath: uvPythonDir(home: home)).resolvingSymlinksInPath().path),
        ]
        for candidate in [standardized, resolved] where !candidate.isEmpty {
            for root in roots where !root.isEmpty {
                if candidate == root || candidate.hasPrefix(root + "/") {
                    return true
                }
            }
            if candidate.contains("/Library/Application Support/NX2Apple/tools/uv-python/") {
                return true
            }
        }
        return false
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

    package static let botwTitleID = "01007EF00011E000"

    package static func needsAutoSharedFonts(
        route: Route,
        titleID: String? = nil,
        gameInput: String,
        isUnencryptedInput: Bool,
        workDir: String,
        fileManager fm: FileManager = .default
    ) -> Bool {
        guard !isUnencryptedInput else { return false }
        let ext = (gameInput as NSString).pathExtension.lowercased()
        let isBOTW = normalizedHex16(titleID) == botwTitleID
        if (ext == "xci" || ext == "xcz") && !isBOTW {
            return false
        }
        switch route {
        case .unifiedBuildApp:
            let manifest = workDir + "/totk/extracted/firmware/shared-fonts/manifest.json"
            return !fm.fileExists(atPath: manifest)
        case .perGameScript(let port):
            guard let relManifest = port.autoSharedFontsManifestRelativePath else { return false }
            return !fm.fileExists(atPath: workDir + "/" + relManifest)
        }
    }

    /// True when `path` is a compressed Switch container that must be pre-decompressed before invoking `route`.
    /// `build_app.py` handles `.nsz` in its own venv, while `.xcz` and all 7 per-game scripts require pre-unpacked `.nsp`/`.xci`.
    package static func needsPreDecompress(route: Route, path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        switch route {
        case .unifiedBuildApp:
            return ext == "xcz"
        case .perGameScript:
            return ext == "nsz" || ext == "xcz"
        }
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

    /// Per-game port scripts maintained by MNG Launcher (`tools/builder_jobs/build_job.py`).
    /// CLI flags strictly match each `games/<id>/build.py` `argparse` contract.
    package enum PerGamePort: String, Equatable, Sendable, CaseIterable {
        case dread
        case ss
        case worldend
        case tmnt
        case acnh
        case eow
        case odyssey

        package var scriptRelativePath: String {
            "games/\(rawValue)/build.py"
        }

        package var supportsUpdate: Bool {
            switch self {
            case .dread, .ss, .acnh, .eow, .odyssey:
                return true
            case .worldend, .tmnt:
                return false
            }
        }

        package var supportsDLC: Bool {
            self == .acnh
        }

        package var supportsSharedFonts: Bool {
            switch self {
            case .dread, .tmnt, .acnh, .eow, .odyssey:
                return true
            case .ss, .worldend:
                return false
            }
        }

        /// Relative manifest path inside `workDir` for per-game scripts that require `--shared-fonts` on NSP inputs.
        package var autoSharedFontsManifestRelativePath: String? {
            switch self {
            case .acnh:
                return "fonts/manifest.json"
            case .eow, .odyssey:
                return "extracted/firmware/shared-fonts/manifest.json"
            case .dread, .ss, .worldend, .tmnt:
                return nil
            }
        }
    }

    package enum Route: Equatable, Sendable {
        case unifiedBuildApp
        case perGameScript(PerGamePort)
    }

    package static let unifiedTitleIDs: Set<String> = [
        "0100F2C0115B6000", // The Legend of Zelda: Tears of the Kingdom
        "01007EF00011E000", // The Legend of Zelda: Breath of the Wild
        "0400486024DEC000", // The Legend of Zelda: Ocarina of Time (Switch 2)
        "040074A01BF12000", // Donkey Kong Bananza (Switch 2)
        "0400A3A01EE4C000", // Pokémon Pokopia (Switch 2)
    ]

    package static let perGameTitleIDs: [String: PerGamePort] = [
        "010093801237C000": .dread,    // Metroid Dread
        "01002DA013484000": .ss,       // The Legend of Zelda: Skyward Sword HD
        "010048900CF64000": .worldend, // WORLDEND SYNDROME
        "0100FE701475A000": .tmnt,     // Teenage Mutant Ninja Turtles: Shredder's Revenge
        "01006F8002326000": .acnh,     // Animal Crossing: New Horizons
        "01008CF01BAAC000": .eow,      // The Legend of Zelda: Echoes of Wisdom
        "0100000000010000": .odyssey,  // Super Mario Odyssey
    ]

    package static let supportedTitleIDs: Set<String> = unifiedTitleIDs.union(perGameTitleIDs.keys)

    /// Titles whose MacNativeGames builder accepts `.nup` archives directly.
    /// Upstream `build_app.py` routes every `.nup` input to Ocarina of Time (`build_oot`), so other Switch 2 titles
    /// such as Pokopia and Donkey Kong Bananza require an unpacked Switch 2 dump folder.
    package static let nupSupportedTitleIDs: Set<String> = [
        "0400486024DEC000", // The Legend of Zelda: Ocarina of Time (Switch 2)
    ]

    /// Returns true only when `titleID` normalizes to one of the 12 official MacNativeGames 16-hex IDs.
    package static func supportsTitleID(_ titleID: String?) -> Bool {
        normalizedHex16(titleID).map { supportedTitleIDs.contains($0) } ?? false
    }

    /// True when `path` is a `.nup` archive file or a folder whose Switch 2 input is a `.nup` file.
    package static func isNUPInputPath(_ path: String?) -> Bool {
        guard let raw = path?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return false }
        if (raw as NSString).pathExtension.lowercased() == "nup" {
            return true
        }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: raw, isDirectory: &isDir), isDir.boolValue {
            let resolved = GameFolder.resolve(raw)
            if (resolved as NSString).pathExtension.lowercased() == "nup" {
                return true
            }
            return !GameFolder.nupFiles(in: resolved).isEmpty
        }
        return false
    }

    /// True when the local MacNativeGames checkout includes generic Switch 2 NUP routing (`tools/nup_input.py`, MNG PR #2339).
    package static func supportsGenericNUP(in tree: String, fileManager fm: FileManager = .default) -> Bool {
        let root = normalizedPath(tree)
        guard !root.isEmpty else { return false }
        return fm.fileExists(atPath: root + "/tools/nup_input.py")
    }

    /// True when MacNativeGames supports `titleID` with the given input format (`isNUP` distinguishes `.nup` files from dump folders / XCI / NSP).
    package static func supportsInput(titleID: String?, isNUP: Bool, tree: String = "", fileManager fm: FileManager = .default) -> Bool {
        guard let tid = normalizedHex16(titleID), supportedTitleIDs.contains(tid) else { return false }
        if !isNUP || nupSupportedTitleIDs.contains(tid) {
            return true
        }
        return supportsGenericNUP(in: tree, fileManager: fm)
    }

    package static func supportsInput(
        titleID: String?,
        gameFolder: String? = nil,
        basePath: String? = nil,
        tree: String = "",
        fileManager fm: FileManager = .default
    ) -> Bool {
        let isNUP = isNUPInputPath(gameFolder) || isNUPInputPath(basePath)
        return supportsInput(titleID: titleID, isNUP: isNUP, tree: tree, fileManager: fm)
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
        case .perGameScript(let port):
            return prefix + port.scriptRelativePath
        }
    }

    package static func route(forTitleID titleID: String?, in tree: String = "", fileManager fm: FileManager = .default) -> Route? {
        _ = tree
        _ = fm
        guard let tid = normalizedHex16(titleID) else { return nil }
        if unifiedTitleIDs.contains(tid) {
            return .unifiedBuildApp
        }
        if let port = perGameTitleIDs[tid] {
            return .perGameScript(port)
        }
        return nil
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
        case .perGameScript(let port):
            // Per-game scripts never take `--platform`; emit only flags accepted by each script's argparse.
            if port.supportsUpdate && includesUpdate {
                args += ["--update", updatePath]
            }
            if port.supportsDLC {
                for dlc in externalDLCs {
                    args += ["--dlc", dlc]
                }
            }
            if port.supportsSharedFonts && !sharedFontsPath.isEmpty {
                args += ["--shared-fonts", sharedFontsPath]
            }
            args += ["--work", workDir, "-o", outputAppPath]
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
