import Foundation

/// S2Arm dedicated `.venv` management (exact `requirements*.txt` pins + `cmake`/`meson`/`ninja`)
/// and macOS SPIRV / pinned `zstd 1.5.7` (`libzstd.1.dylib`) runtime toolchain bootstrap.
extension S2ArmBootstrap {
    package static let requirementFiles = [
        "tools/rewriter-requirements.txt",
        "pack/fonts/requirements.txt",
        "launchers/macos/requirements-runtime.txt",
    ]

    package static let fallbackPythonSpecs = [
        "capstone",
        "lz4",
        "zstandard",
        "numpy",
        "Pillow",
        "fonttools",
        "skia-pathops",
    ]

    package static let requiredRuntimeToolBinaries = [
        "spirv-as",
        "spirv-val",
        "glslangValidator",
        "spirv-cross",
        "zstd",
    ]

    package static let runtimeToolsMarker = "NX2APPLE_RUNTIME_TOOLS="

    private static func prefixPath(_ dir: String) -> String {
        dir.hasSuffix("/") ? dir : dir + "/"
    }

    // MARK: - Dedicated `<s2arm>/.venv` & pinned requirements

    package static func venvDirectory(in s2armTree: String) -> String {
        prefixPath(s2armTree) + ".venv"
    }

    package static func venvPython(in s2armTree: String) -> String {
        venvDirectory(in: s2armTree) + "/bin/python3"
    }

    /// Parses all existing S2Arm official requirement files (`tools/rewriter-requirements.txt`,
    /// `pack/fonts/requirements.txt`, `launchers/macos/requirements-runtime.txt`), merges fallback
    /// package names and build tools (`cmake`, `meson`, `ninja`), and returns both pip install
    /// specs and exact `pkg==version` pin pairs.
    package static func requirementSpecs(
        in s2armTree: String,
        fileManager fm: FileManager = .default
    ) -> (specs: [String], pinned: [(name: String, version: String)]) {
        var specs: [String] = []
        var specIndexByKey: [String: Int] = [:]
        var pinned: [(name: String, version: String)] = []
        var pinnedIndexByKey: [String: Int] = [:]

        func canonicalKey(_ rawName: String) -> String {
            rawName
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: "_", with: "-")
        }

        func extractName(_ spec: String) -> String {
            let noExtras = spec.split(separator: "[", maxSplits: 1).first.map(String.init) ?? spec
            let stop = CharacterSet(charactersIn: "=<>!~; ")
            return noExtras.components(separatedBy: stop).first?.trimmingCharacters(in: .whitespaces) ?? noExtras
        }

        func recordSpec(_ raw: String, preferOverride: Bool) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.hasPrefix("-") else { return }
            let name = extractName(trimmed)
            guard !name.isEmpty else { return }
            let key = canonicalKey(name)
            if let idx = specIndexByKey[key] {
                if preferOverride {
                    specs[idx] = trimmed
                }
            } else {
                specIndexByKey[key] = specs.count
                specs.append(trimmed)
            }
            if let eqRange = trimmed.range(of: "==") {
                let lhs = String(trimmed[..<eqRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                let rhs = String(trimmed[eqRange.upperBound...])
                    .split(separator: ";", maxSplits: 1).first?
                    .trimmingCharacters(in: .whitespaces) ?? ""
                if !lhs.isEmpty, !rhs.isEmpty {
                    if let pIdx = pinnedIndexByKey[key] {
                        if preferOverride {
                            pinned[pIdx] = (lhs, rhs)
                        }
                    } else {
                        pinnedIndexByKey[key] = pinned.count
                        pinned.append((lhs, rhs))
                    }
                }
            }
        }

        if !s2armTree.isEmpty {
            let root = prefixPath(s2armTree)
            for rel in requirementFiles {
                let full = root + rel
                guard fm.fileExists(atPath: full),
                      let text = try? String(contentsOfFile: full, encoding: .utf8) else { continue }
                for rawLine in text.split(whereSeparator: \.isNewline) {
                    let withoutComment = rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
                    let clean = withoutComment.trimmingCharacters(in: .whitespacesAndNewlines)
                    recordSpec(clean, preferOverride: true)
                }
            }
        }

        for fallback in fallbackPythonSpecs {
            recordSpec(fallback, preferOverride: false)
        }
        for tool in requiredBuildTools {
            recordSpec(tool, preferOverride: false)
        }
        return (specs, pinned)
    }

    /// Checks whether `cmake`, `meson`, and `ninja` executables exist alongside `python` (inside the venv bin dir).
    package static func missingVenvBuildTools(
        python: String,
        fileManager fm: FileManager = .default
    ) -> [String] {
        guard !python.isEmpty else { return requiredBuildTools }
        let binDir = (python as NSString).deletingLastPathComponent
        guard !binDir.isEmpty else { return requiredBuildTools }
        let prefix = prefixPath(binDir)
        return requiredBuildTools.filter { !fm.isExecutableFile(atPath: prefix + $0) }
    }

    /// True only when `python` is executable, imports all S2Arm runtime modules, matches every
    /// `pkg==version` pin declared in `tree`, and has executable `cmake`, `meson`, and `ninja`
    /// in its bin directory.
    package static func isVenvReady(
        python: String,
        tree: String = "",
        runner: ProcessRunner = SystemProcessRunner(),
        fileManager fm: FileManager = .default
    ) -> Bool {
        guard !python.isEmpty, fm.isExecutableFile(atPath: python) else { return false }
        guard S2ArmBuilder.missingPythonPackages(python: python, tree: tree, runner: runner).isEmpty else {
            return false
        }
        return missingVenvBuildTools(python: python, fileManager: fm).isEmpty
    }

    /// Creates or upgrades the dedicated `<s2arm>/.venv` to satisfy S2Arm's exact pinned
    /// `requirements*.txt` files plus `cmake`, `meson`, and `ninja`.
    package static func ensureS2ArmVenv(
        in s2armTree: String,
        basePython: String,
        home: String = NSHomeDirectory(),
        runner: ProcessRunner = SystemProcessRunner(),
        fileManager fm: FileManager = .default,
        onLine: (@Sendable (String) -> Void)? = nil
    ) -> (ok: Bool, skipped: Bool, python: String, log: String) {
        guard !s2armTree.isEmpty else { return (false, false, "", "S2Arm directory is empty") }
        let vDir = venvDirectory(in: s2armTree)
        let vPy = venvPython(in: s2armTree)

        if isVenvReady(python: vPy, tree: s2armTree, runner: runner, fileManager: fm) {
            return (true, true, vPy, "")
        }

        var log = ""
        let baseEnv = ProxyEnvironment.merged(into: [
            "PATH": BundledTools.path("/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", python: basePython),
            "HOME": home,
        ].merging(BundledTools.environment(for: basePython)) { $1 })

        func runStep(_ exe: String, _ args: [String]) -> Bool {
            let launch = ProcessLaunch(executable: exe, arguments: args, environment: baseEnv, directory: s2armTree)
            if let onLine {
                final class Box: @unchecked Sendable {
                    private let lock = NSLock()
                    var lines: [String] = []
                    func add(_ line: String) {
                        lock.lock()
                        lines.append(line)
                        lock.unlock()
                    }
                }
                let box = Box()
                let ok = runner.stream(launch) { line in
                    box.add(line)
                    onLine(line)
                }
                if !box.lines.isEmpty {
                    log += box.lines.joined(separator: "\n") + "\n"
                }
                return ok
            }
            let res = runner.capture(launch)
            log += res.out + res.err
            return res.ok
        }

        if !fm.isExecutableFile(atPath: vPy) {
            let chosenBase: String?
            if !basePython.isEmpty && fm.isExecutableFile(atPath: basePython) {
                chosenBase = basePython
            } else {
                chosenBase = Toolchain.venvBase(preferred: basePython)
            }
            guard let interp = chosenBase else {
                return (false, false, vPy, log + "No Python 3.12+ interpreter available to create \(vDir)\n")
            }
            log += "$ \(interp) -m venv \(vDir)\n"
            guard runStep(interp, ["-m", "venv", vDir]) else {
                return (false, false, vPy, log + "Failed to create \(vDir)\n")
            }
        }

        let specs = requirementSpecs(in: s2armTree, fileManager: fm).specs
        log += "$ \(vPy) -m pip install " + specs.joined(separator: " ") + "\n"
        let pipOK = runStep(vPy, ["-m", "pip", "install", "--upgrade-strategy", "only-if-needed"] + specs)
        let ready = pipOK && isVenvReady(python: vPy, tree: s2armTree, runner: runner, fileManager: fm)
        return (ready, false, vPy, log)
    }

    // MARK: - macOS SPIRV tools & pinned `zstd 1.5.7` (`libzstd.1.dylib`)

    package static func runtimeToolsPrefix(in s2armTree: String) -> String {
        prefixPath(s2armTree) + "build/macos/runtime-sources/tools"
    }

    package static func isRuntimeToolsPrefixReady(
        _ prefix: String,
        fileManager fm: FileManager = .default
    ) -> Bool {
        guard !prefix.isEmpty else { return false }
        let root = prefixPath(prefix)
        for bin in requiredRuntimeToolBinaries {
            guard fm.isExecutableFile(atPath: root + "bin/" + bin) else { return false }
        }
        return fm.fileExists(atPath: root + "lib/libzstd.1.dylib")
    }

    private static func findExecutable(_ name: String, in pathDirs: [String], fileManager fm: FileManager) -> String? {
        for dir in pathDirs where !dir.isEmpty {
            let cand = prefixPath(dir) + name
            if fm.isExecutableFile(atPath: cand) {
                return cand
            }
        }
        return nil
    }

    private static func findAdjacentZstdLib(forZstdBinary zstdPath: String, fileManager fm: FileManager) -> String? {
        let candidates = [zstdPath, URL(fileURLWithPath: zstdPath).resolvingSymlinksInPath().path]
        for path in candidates {
            let binDir = (path as NSString).deletingLastPathComponent
            let prefix = (binDir as NSString).deletingLastPathComponent
            let lib = prefixPath(prefix) + "lib/libzstd.1.dylib"
            if fm.fileExists(atPath: lib) {
                return lib
            }
        }
        return nil
    }

    package static func inspectSystemRuntimeTools(
        pathEnv: String,
        runner: ProcessRunner = SystemProcessRunner(),
        fileManager fm: FileManager = .default
    ) -> (ready: Bool, zstdLib: String?) {
        let dirs = pathEnv.split(separator: ":").map(String.init).filter { !$0.isEmpty }
        var foundZstd: String?
        var allFound = true
        for tool in requiredRuntimeToolBinaries {
            guard let exe = findExecutable(tool, in: dirs, fileManager: fm) else {
                allFound = false
                continue
            }
            if tool == "zstd" {
                foundZstd = exe
            }
        }
        let zstdLib = foundZstd.flatMap { findAdjacentZstdLib(forZstdBinary: $0, fileManager: fm) }
        guard allFound, let zstdExe = foundZstd, let zstdLib else {
            return (false, zstdLib)
        }
        let verRes = runner.capture(ProcessLaunch(executable: zstdExe, arguments: ["--version"], environment: ["PATH": pathEnv]))
        let output = verRes.out + "\n" + verRes.err
        let isPinned157 = verRes.ok && output.contains("v1.5.7")
        return (isPinned157, zstdLib)
    }

    package static func parseRuntimeToolsOutput(_ stdout: String) -> String? {
        for line in stdout.split(whereSeparator: \.isNewline).reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix(runtimeToolsMarker) {
                let val = String(trimmed.dropFirst(runtimeToolsMarker.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !val.isEmpty { return val }
            }
        }
        return nil
    }

    /// Ensures SPIRV tools (`spirv-as`, `spirv-val`, `glslangValidator`, `spirv-cross`) and
    /// pinned `zstd 1.5.7` + `libzstd.1.dylib` are ready by reusing built `runtime-sources/tools`,
    /// matching system tools, or invoking S2Arm's `launchers/macos/runtime_sources.py`.
    package static func ensureRuntimeTools(
        in s2armTree: String,
        python: String,
        environment: [String: String],
        runner: ProcessRunner = SystemProcessRunner(),
        fileManager fm: FileManager = .default,
        onLine: (@Sendable (String) -> Void)? = nil
    ) -> (ok: Bool, skipped: Bool, binDir: String?, zstdLib: String?, log: String) {
        guard !s2armTree.isEmpty else { return (false, false, nil, nil, "S2Arm directory is empty") }
        let defaultPrefix = runtimeToolsPrefix(in: s2armTree)
        if isRuntimeToolsPrefixReady(defaultPrefix, fileManager: fm) {
            return (true, true, defaultPrefix + "/bin", defaultPrefix + "/lib/libzstd.1.dylib", "")
        }

        let sysCheck = inspectSystemRuntimeTools(pathEnv: environment["PATH"] ?? "", runner: runner, fileManager: fm)
        if sysCheck.ready {
            return (true, true, nil, sysCheck.zstdLib, "")
        }

        let scriptPath = prefixPath(s2armTree) + "launchers/macos/runtime_sources.py"
        guard fm.fileExists(atPath: scriptPath) else {
            return (true, true, nil, sysCheck.zstdLib, "")
        }

        let snippet = "import sys; sys.path.insert(0, 'launchers/macos'); import runtime_sources; p, _ = runtime_sources.tools(); print('\(runtimeToolsMarker)' + str(p))"
        let env = ProxyEnvironment.merged(into: environment)
        let launch = ProcessLaunch(executable: python, arguments: ["-c", snippet], environment: env, directory: s2armTree)

        let ok: Bool
        let combined: String
        if let onLine {
            final class Box: @unchecked Sendable {
                private let lock = NSLock()
                var lines: [String] = []
                func add(_ line: String) {
                    lock.lock()
                    lines.append(line)
                    lock.unlock()
                }
            }
            let box = Box()
            ok = runner.stream(launch) { line in
                box.add(line)
                if !line.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(runtimeToolsMarker) {
                    onLine(line)
                }
            }
            combined = box.lines.joined(separator: "\n")
        } else {
            let res = runner.capture(launch)
            ok = res.ok
            combined = res.out + (res.err.isEmpty ? "" : "\n" + res.err)
        }

        let prefix = parseRuntimeToolsOutput(combined) ?? defaultPrefix
        let ready = ok && isRuntimeToolsPrefixReady(prefix, fileManager: fm)
        guard ready else {
            return (false, false, nil, sysCheck.zstdLib, combined)
        }
        return (true, false, prefixPath(prefix) + "bin", prefixPath(prefix) + "lib/libzstd.1.dylib", combined)
    }
}
