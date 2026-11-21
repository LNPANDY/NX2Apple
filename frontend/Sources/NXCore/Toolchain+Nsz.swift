import CryptoKit
import Foundation

/// Classified root cause for a failed `nsz` tool installation, so the UI surfaces actionable guidance instead of a generic hint.
package enum NszInstallFailureKind: Error, Equatable, Sendable {
    case pep668
    case permissionDenied
    case network
    case other(String)
}

/// Failure payload returned when pre-decompressing a `.nsz` or `.xcz` package fails.
package struct NszUnpackError: Error, Equatable, Sendable {
    package let message: String
    package init(_ message: String) { self.message = message }
}

/// Ready-to-run managed `nsz` installation inside an app-owned virtual environment.
package struct ManagedNszTool: Equatable, Sendable {
    package let venvDir: String
    package let binDir: String
    package let pythonPath: String
    package let executablePath: String?

    package init(venvDir: String, binDir: String, pythonPath: String, executablePath: String?) {
        self.venvDir = venvDir
        self.binDir = binDir
        self.pythonPath = pythonPath
        self.executablePath = executablePath
    }
}

extension Toolchain {
    /// Dedicated app-managed virtual environment for the `nsz` decompressor CLI and module.
    /// Kept separate from Homebrew, uv, and system Python installations so PEP 668 never blocks compressed ROM builds.
    package static var customNszVenvDir: String? = nil

    package static func nszVenvDir(home: String = NSHomeDirectory()) -> String {
        if let custom = customNszVenvDir, !custom.isEmpty {
            return custom
        }
        return home + "/Library/Application Support/NX2Apple/tools/nsz-venv"
    }

    package static func nszVenvPython(venvDir: String) -> String {
        venvDir + "/bin/python3"
    }

    package static func nszExecutable(venvDir: String) -> String {
        venvDir + "/bin/nsz"
    }

    /// Returns true when the interpreter lives outside app-managed virtual environments or carries a PEP 668 `EXTERNALLY-MANAGED` marker.
    package static func isExternallyManagedPython(
        _ path: String,
        home: String = NSHomeDirectory(),
        fileManager fm: FileManager = .default
    ) -> Bool {
        guard !path.isEmpty else { return true }
        let standardized = URL(fileURLWithPath: path).standardized.path
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardized.path
        let candidates = Set([standardized, resolved])

        for candidate in candidates {
            if hasExternallyManagedMarker(forPython: candidate, fileManager: fm) {
                return true
            }
        }
        if MacNativeGamesBuilder.isManagedUVPython(standardized, home: home)
            || MacNativeGamesBuilder.isManagedUVPython(resolved, home: home) {
            return true
        }
        let managedRoots = [
            URL(fileURLWithPath: venvDir).standardized.path,
            URL(fileURLWithPath: venvDir).resolvingSymlinksInPath().standardized.path,
            URL(fileURLWithPath: nszVenvDir(home: home)).standardized.path,
            URL(fileURLWithPath: nszVenvDir(home: home)).resolvingSymlinksInPath().standardized.path,
        ]
        for candidate in candidates {
            for root in managedRoots where !root.isEmpty {
                let prefix = root.hasSuffix("/") ? root : root + "/"
                if candidate.hasPrefix(prefix) {
                    return false
                }
            }
        }
        return true
    }

    private static func hasExternallyManagedMarker(forPython pythonPath: String, fileManager fm: FileManager) -> Bool {
        let binDir = (pythonPath as NSString).deletingLastPathComponent
        let prefixDir = (binDir as NSString).deletingLastPathComponent
        let libDir = prefixDir + "/lib"
        guard let entries = try? fm.contentsOfDirectory(atPath: libDir) else { return false }
        for entry in entries where entry.hasPrefix("python") {
            if fm.fileExists(atPath: libDir + "/" + entry + "/EXTERNALLY-MANAGED") {
                return true
            }
        }
        return false
    }

    /// Classifies `pip` / `venv` installation logs into PEP 668, permission, network, or generic failures.
    package static func classifyNszInstallFailure(_ log: String) -> NszInstallFailureKind {
        let lower = log.lowercased()
        if lower.contains("externally-managed-environment") || lower.contains("pep 668") {
            return .pep668
        }
        if lower.contains("permissionerror")
            || lower.contains("permission denied")
            || lower.contains("read-only file system")
            || lower.contains("operation not permitted") {
            return .permissionDenied
        }
        if lower.contains("could not find a version")
            || lower.contains("temporary failure in name resolution")
            || lower.contains("nodename nor servname provided")
            || lower.contains("newconnectionerror")
            || lower.contains("connectionerror")
            || lower.contains("proxyerror")
            || lower.contains("cannot connect to proxy")
            || lower.contains("sslerror")
            || lower.contains("read timed out")
            || lower.contains("connection timed out")
            || lower.contains("failed to establish a new connection") {
            return .network
        }
        let detail = BuildProgress.lastMeaningfulLine(log) ?? ""
        return .other(detail)
    }

    /// Returns the app-managed `nsz-venv` if it already has an executable `nsz` or importable `nsz` module.
    package static func readyManagedNszTool(
        venvDir: String,
        environment: [String: String],
        runner: ProcessRunner = SystemProcessRunner(),
        fileManager fm: FileManager = .default
    ) -> ManagedNszTool? {
        let vpy = nszVenvPython(venvDir: venvDir)
        let nszBin = nszExecutable(venvDir: venvDir)
        guard fm.isExecutableFile(atPath: vpy) else { return nil }
        var cleanEnv = environment
        cleanEnv.removeValue(forKey: "PYTHONHOME")
        cleanEnv.removeValue(forKey: "PYTHONPATH")
        let env = ProxyEnvironment.merged(into: cleanEnv.merging(BundledTools.environment(for: vpy)) { $1 })
        guard runOK(vpy, ["-c", "import nsz"], env: env, runner: runner) else { return nil }
        let exe = fm.isExecutableFile(atPath: nszBin) ? nszBin : nil
        return ManagedNszTool(
            venvDir: venvDir,
            binDir: venvDir + "/bin",
            pythonPath: vpy,
            executablePath: exe
        )
    }

    /// Creates or reuses an app-managed `nsz-venv` and installs `nsz` inside it without mutating host/uv/Homebrew Python.
    package static func ensureManagedNszTool(
        preferredPython: String,
        venvDir: String? = nil,
        home: String = NSHomeDirectory(),
        runner: ProcessRunner = SystemProcessRunner(),
        fileManager fm: FileManager = .default,
        cancel: LockedFlag? = nil,
        onLine: (@Sendable (String) -> Void)? = nil
    ) -> Result<ManagedNszTool, NszInstallFailureKind> {
        let dir = venvDir ?? nszVenvDir(home: home)
        let baseEnv = ProxyEnvironment.merged(into: [
            "PATH": BundledTools.path("/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin", python: preferredPython),
            "HOME": home,
            "LANG": "en_US.UTF-8",
            "TMPDIR": NSTemporaryDirectory(),
        ].merging(BundledTools.environment(for: preferredPython)) { $1 })

        if let existing = readyManagedNszTool(venvDir: dir, environment: baseEnv, runner: runner, fileManager: fm) {
            return .success(existing)
        }
        if cancel?.value == true {
            return .failure(.other("cancelled"))
        }

        let vpy = nszVenvPython(venvDir: dir)
        let parentDir = (dir as NSString).deletingLastPathComponent
        try? fm.createDirectory(atPath: parentDir, withIntermediateDirectories: true)

        final class LineCollector: @unchecked Sendable {
            private let lock = NSLock()
            var lines: [String] = []
            func append(_ line: String) {
                lock.lock()
                lines.append(line)
                lock.unlock()
            }
            var joined: String {
                lock.lock()
                defer { lock.unlock() }
                return lines.joined(separator: "\n")
            }
        }
        let collected = LineCollector()

        func runStep(_ exe: String, _ args: [String], env: [String: String]) -> Bool {
            let launch = ProcessLaunch(executable: exe, arguments: args, environment: env)
            return runner.stream(launch) { line in
                collected.append(line)
                onLine?(line)
            }
        }

        if !fm.isExecutableFile(atPath: vpy) {
            let basePy: String?
            if !preferredPython.isEmpty,
               fm.isExecutableFile(atPath: preferredPython),
               let v = pythonVersion(preferredPython, runner: runner),
               v >= minPython {
                basePy = preferredPython
            } else {
                basePy = venvBase(preferred: preferredPython)
            }
            guard let chosenBase = basePy else {
                return .failure(.other("no Python \(minPython.0).\(minPython.1)+ interpreter available to create nsz-venv"))
            }
            if fm.fileExists(atPath: dir) {
                try? fm.removeItem(atPath: dir)
            }
            let venvEnv = ProxyEnvironment.merged(into: baseEnv.merging(BundledTools.environment(for: chosenBase)) { $1 })
            guard runStep(chosenBase, ["-m", "venv", dir], env: venvEnv) else {
                try? fm.removeItem(atPath: dir)
                return .failure(classifyNszInstallFailure(collected.joined))
            }
        }

        if cancel?.value == true {
            return .failure(.other("cancelled"))
        }

        let pipEnv = ProxyEnvironment.merged(into: [
            "PATH": dir + "/bin:" + (baseEnv["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"),
            "HOME": home,
            "LANG": "en_US.UTF-8",
            "TMPDIR": NSTemporaryDirectory(),
        ].merging(BundledTools.environment(for: vpy)) { $1 })

        guard runStep(vpy, ["-m", "pip", "install", "nsz"], env: pipEnv) else {
            return .failure(classifyNszInstallFailure(collected.joined))
        }
        if cancel?.value == true {
            return .failure(.other("cancelled"))
        }

        let nszBin = nszExecutable(venvDir: dir)
        let exe = fm.isExecutableFile(atPath: nszBin) ? nszBin : nil
        return .success(ManagedNszTool(venvDir: dir, binDir: dir + "/bin", pythonPath: vpy, executablePath: exe))
    }

    /// Pre-decompresses a `.nsz` or `.xcz` container into `workDir/.nsz-unpacked` using the managed `nsz` tool,
    /// reusing cached output only when the source file's canonical path, size, and mtime match the written receipt.
    package static func unpackCompressedPackage(
        input: String,
        keysPath: String,
        workDir: String,
        tool: ManagedNszTool,
        environment: [String: String],
        runner: ProcessRunner = SystemProcessRunner(),
        fileManager fm: FileManager = .default,
        cancel: LockedFlag? = nil,
        onLine: (@Sendable (String) -> Void)? = nil
    ) -> Result<String, NszUnpackError> {
        let ext = (input as NSString).pathExtension.lowercased()
        let outExt: String
        switch ext {
        case "nsz": outExt = "nsp"
        case "xcz": outExt = "xci"
        default: return .success(input)
        }
        guard !keysPath.isEmpty else {
            return .failure(NszUnpackError("prod.keys is required to decompress \(ext.uppercased())"))
        }

        let resolvedInput = URL(fileURLWithPath: input).resolvingSymlinksInPath().standardized.path
        let attrs = (try? fm.attributesOfItem(atPath: resolvedInput)) ?? [:]
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? -1
        let mtime = Int64(((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0) * 1000)
        let stamp = "\(resolvedInput)|\(size)|\(mtime)"

        let unpackDir = workDir + "/.nsz-unpacked"
        let stem = ((input as NSString).lastPathComponent as NSString).deletingPathExtension
        let hash8 = SHA256.hash(data: Data(resolvedInput.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
        let outPath = unpackDir + "/" + stem + "-" + hash8 + "." + outExt
        let receiptPath = outPath + ".receipt"

        if size >= 0,
           fm.fileExists(atPath: outPath),
           let saved = try? String(contentsOfFile: receiptPath, encoding: .utf8),
           saved == stamp {
            return .success(outPath)
        }
        if cancel?.value == true {
            return .failure(NszUnpackError("cancelled"))
        }

        try? fm.createDirectory(atPath: unpackDir, withIntermediateDirectories: true)
        let stagingDir = unpackDir + "/.staging-" + UUID().uuidString
        try? fm.createDirectory(atPath: stagingDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: stagingDir) }

        // nsz skips uppercase extensions (.NSZ/.XCZ); stage a lowercase-extension link/copy when needed.
        var effectiveInput = input
        let rawExt = (input as NSString).pathExtension
        if rawExt != ext {
            let lowerLink = stagingDir + "/" + stem + "." + ext
            if (try? fm.linkItem(atPath: resolvedInput, toPath: lowerLink)) != nil
                || (try? fm.copyItem(atPath: resolvedInput, toPath: lowerLink)) != nil {
                effectiveInput = lowerLink
            }
        }

        var env = environment
        let existingPath = env["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        if !existingPath.split(separator: ":").contains(Substring(tool.binDir)) {
            env["PATH"] = tool.binDir + ":" + existingPath
        }

        let launch: ProcessLaunch
        if let exe = tool.executablePath, fm.isExecutableFile(atPath: exe) {
            launch = ProcessLaunch(
                executable: exe,
                arguments: ["-D", "--keys", keysPath, "-o", stagingDir, effectiveInput],
                environment: env,
                directory: stagingDir
            )
        } else {
            let inline = "import sys; sys.argv = ['nsz', '-D', '--keys', sys.argv[1], '-o', sys.argv[2], sys.argv[3]]; from nsz import main; main()"
            launch = ProcessLaunch(
                executable: tool.pythonPath,
                arguments: ["-c", inline, keysPath, stagingDir, effectiveInput],
                environment: env,
                directory: stagingDir
            )
        }

        final class TailBox: @unchecked Sendable {
            private let lock = NSLock()
            var lines: [String] = []
            func add(_ l: String) { lock.lock(); lines.append(l); lock.unlock() }
            var text: String { lock.lock(); defer { lock.unlock() }; return lines.joined(separator: "\n") }
        }
        let tail = TailBox()
        let ok = runner.stream(launch) { line in
            tail.add(line)
            onLine?(line)
        }
        if cancel?.value == true {
            return .failure(NszUnpackError("cancelled"))
        }
        guard ok else {
            let reason = BuildProgress.lastMeaningfulLine(tail.text) ?? "nsz exited with an error"
            return .failure(NszUnpackError(reason))
        }

        let producedName = (try? fm.contentsOfDirectory(atPath: stagingDir))?
            .first { ($0 as NSString).pathExtension.lowercased() == outExt }
        guard let producedName else {
            return .failure(NszUnpackError("nsz did not produce a .\(outExt) output file"))
        }
        let producedPath = stagingDir + "/" + producedName
        try? fm.removeItem(atPath: outPath)
        try? fm.removeItem(atPath: receiptPath)
        do {
            try fm.moveItem(atPath: producedPath, toPath: outPath)
            if size >= 0 {
                try? stamp.write(toFile: receiptPath, atomically: true, encoding: .utf8)
            }
            return .success(outPath)
        } catch {
            return .failure(NszUnpackError(error.localizedDescription))
        }
    }
}
