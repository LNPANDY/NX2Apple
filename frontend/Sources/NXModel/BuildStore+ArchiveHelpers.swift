import Foundation
import NXCore

/// Result of `BuildStore.packArchiveWithOutcome`, tracking whether `.img` (or `msl/` fallback) actually changed on disk.
package struct ArchivePackOutcome: Equatable, Sendable {
    package var archiveDir: String
    package var primaryImgPath: String
    package var didUpdateImg: Bool
    package var usedMSLFallback: Bool

    package init(
        archiveDir: String = "",
        primaryImgPath: String = "",
        didUpdateImg: Bool = false,
        usedMSLFallback: Bool = false
    ) {
        self.archiveDir = archiveDir
        self.primaryImgPath = primaryImgPath
        self.didUpdateImg = didUpdateImg
        self.usedMSLFallback = usedMSLFallback
    }
}

/// Outcome of `BuildStore.injectIOSShaderTrailer`, distinguishing 0-I/O skip from actual trailer writes.
enum TrailerInjectionOutcome: Equatable, Sendable {
    case noShaderSource
    case skipped
    case injected(logLine: String?)

    var logLine: String? {
        if case .injected(let line) = self { return line }
        return nil
    }

    var didWriteTrailer: Bool {
        if case .injected = self { return true }
        return false
    }
}

extension BuildStore {
    /// Resolves an existing local `<Game>.img` / `romfs.img` when the canonical `<gamesRoot>/<FolderName>/<FolderName>.img` path is absent.
    nonisolated static func findFallbackLocalArchive(
        tid: String,
        knownArchivePath: String?,
        outDir: String,
        refreshBuildsRoot: String,
        prefillCandidates: [String],
        fm: FileManager = .default
    ) -> (archiveDir: String, imgPath: String)? {
        func matchInPath(_ candidate: String) -> (String, String)? {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, fm.fileExists(atPath: trimmed) else { return nil }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: trimmed, isDirectory: &isDir) else { return nil }
            if isDir.boolValue {
                if let primary = RomFSArchive.primaryImagePath(in: trimmed, fm: fm), fm.fileExists(atPath: primary) {
                    return (trimmed, primary)
                }
                return nil
            }
            let lower = trimmed.lowercased()
            guard lower.hasSuffix(".img"), !lower.contains(".app/") else { return nil }
            return ((trimmed as NSString).deletingLastPathComponent, trimmed)
        }

        if let knownArchivePath, let found = matchInPath(knownArchivePath) {
            return found
        }
        for root in [outDir, refreshBuildsRoot] where !root.isEmpty {
            let gamesRoot = root + "/games"
            for dir in RomFSArchive.archiveDirectories(forTitleID: tid, gamesRoot: gamesRoot, fm: fm) {
                if let found = matchInPath(dir) {
                    return found
                }
            }
        }
        for cand in prefillCandidates where !cand.contains(".app/") {
            if let found = matchInPath(cand) {
                return found
            }
        }
        return nil
    }

    /// Checks whether `shaderSourcePath` contains any shader file modified at or after `referenceDate` (or newer than `targetImg`),
    /// indicating that trailers should be replaced rather than skipped even when the shader chain string did not change.
    nonisolated static func shouldForceTrailerReplace(
        targetImg: String,
        shaderSourcePath: String,
        forceReplace: Bool,
        runStartedAt: Date?,
        fm: FileManager = .default
    ) -> Bool {
        if forceReplace { return true }
        let newestShaderDate = newestModificationDate(atPath: shaderSourcePath, fm: fm)
        guard let newestShaderDate else { return false }
        if let runStartedAt, newestShaderDate >= runStartedAt.addingTimeInterval(-1.0) {
            return true
        }
        if let imgDate = (try? fm.attributesOfItem(atPath: targetImg))?[.modificationDate] as? Date,
           newestShaderDate > imgDate.addingTimeInterval(0.5) {
            return true
        }
        return false
    }

    private nonisolated static func newestModificationDate(atPath path: String, fm: FileManager) -> Date? {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else { return nil }
        if !isDir.boolValue {
            return (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        }
        guard let en = fm.enumerator(atPath: path) else { return nil }
        var newest: Date?
        for case let rel as String in en {
            let name = (rel as NSString).lastPathComponent
            if name.hasPrefix(".") { continue }
            let full = path + "/" + rel
            var itemDir: ObjCBool = false
            guard fm.fileExists(atPath: full, isDirectory: &itemDir), !itemDir.boolValue,
                  let mtime = (try? fm.attributesOfItem(atPath: full))?[.modificationDate] as? Date else { continue }
            if newest == nil || mtime > newest! {
                newest = mtime
            }
        }
        return newest
    }

    /// Copies freshly compiled iOS shaders into `<dest>/msl/` when no local `.img` exists, so device transfer can satisfy
    /// `ShaderResources` Tier 2 (`Documents/games/<titleID>/msl`) and prevent false "needs data update" prompts.
    nonisolated static func stageMSLFallbackDirectory(
        shaderSourcePath: String,
        dest: String,
        tid: String,
        fm: FileManager = .default
    ) -> String? {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: shaderSourcePath, isDirectory: &isDir) else { return nil }
        let mslDest = dest + "/msl"
        let stage = dest + "/.msl-staging-" + UUID().uuidString.prefix(8)
        defer { try? fm.removeItem(atPath: stage) }
        do {
            try fm.createDirectory(atPath: dest, withIntermediateDirectories: true)
            try (tid.uppercased() + "\n").write(toFile: dest + "/.titleid", atomically: true, encoding: .utf8)
            if isDir.boolValue {
                try fm.copyItem(atPath: shaderSourcePath, toPath: stage)
            } else {
                try fm.createDirectory(atPath: stage, withIntermediateDirectories: true)
                let fileName = (shaderSourcePath as NSString).lastPathComponent
                try fm.copyItem(atPath: shaderSourcePath, toPath: stage + "/" + fileName)
            }
            if fm.fileExists(atPath: mslDest) {
                try fm.removeItem(atPath: mslDest)
            }
            try fm.moveItem(atPath: stage, toPath: mslDest)
            return mslDest
        } catch {
            return nil
        }
    }

    nonisolated static func injectIOSShaderTrailer(
        targetImg: String,
        workDir: String,
        tid: String,
        isIOSBuild: Bool,
        repoPath: String,
        pythonPath: String,
        runner: ProcessRunner,
        forceReplace: Bool = false,
        runStartedAt: Date? = nil,
        fm: FileManager = .default
    ) -> Result<TrailerInjectionOutcome, TrailerInjectionError> {
        guard let shaderSource = locateIOSShaderSource(workDir: workDir, tid: tid, repoPath: repoPath, fm: fm),
              isIOSBuild else {
            return .success(.noShaderSource)
        }

        let resolvedPy = (pythonPath.isEmpty || MacNativeGamesBuilder.isManagedUVPython(pythonPath)) ? Toolchain.findPython().path : pythonPath
        let py = resolvedPy.isEmpty ? "/usr/bin/python3" : resolvedPy
        let tool = EngineLayout.root(repoPath) + "/" + RepoLayout.romfsImageTool
        let env = ["PATH": BuildCommands.toolPath("/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin", python: py)]
            .merging(BundledTools.environment(for: py)) { $1 }

        let shouldForce = shouldForceTrailerReplace(
            targetImg: targetImg,
            shaderSourcePath: shaderSource.path,
            forceReplace: forceReplace,
            runStartedAt: runStartedAt,
            fm: fm
        )

        var initialHasTrailer = false
        let inspectRes = runner.capture(ProcessLaunch(
            executable: py, arguments: ["-I", tool, "--inspect-msl", targetImg], environment: env, mergesErrors: true
        ))
        if inspectRes.ok,
           let status = BuildSeedCache.parseTrailerStatus(from: inspectRes.out) {
            initialHasTrailer = status.hasTrailer
            if BuildSeedCache.shouldSkipTrailerInjection(
                status: status,
                gfxAPI: shaderSource.gfxAPI,
                chain: shaderSource.chain,
                multiProgram: shaderSource.multiProgram,
                forceReplace: shouldForce
            ) {
                return .success(.skipped)
            }
        }

        do {
            try PostBuildCleanup.breakHardLinksIfNeeded(at: targetImg, fm: fm)
        } catch {
            return .failure(TrailerInjectionError(status: 1, message: error.localizedDescription))
        }

        func run(modeFlag: String) -> ProcessResult {
            var args = ["-I", tool, modeFlag, targetImg, shaderSource.path]
            if let api = shaderSource.gfxAPI, !api.isEmpty { args += ["--gfx-api", api] }
            if let chain = shaderSource.chain, !chain.isEmpty { args += ["--chain", chain] }
            if shaderSource.multiProgram { args.append("--multi-program") }
            return runner.capture(ProcessLaunch(executable: py, arguments: args, environment: env, mergesErrors: true))
        }

        let primaryMode = initialHasTrailer ? "--replace-msl" : "--append-msl"
        var result = run(modeFlag: primaryMode)
        if !result.ok {
            let fallbackMode = initialHasTrailer ? "--append-msl" : "--replace-msl"
            result = run(modeFlag: fallbackMode)
        }
        let text = result.out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.ok else {
            let code: Int32 = result.status == 0 ? 1 : result.status
            return .failure(TrailerInjectionError(status: code, message: text))
        }
        return .success(.injected(logLine: text.isEmpty ? nil : text))
    }
}
