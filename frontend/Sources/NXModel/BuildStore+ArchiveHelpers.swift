import Darwin
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
    /// Returns true when `path` points inside an intermediate build directory (`*_build`, `shader/`, `extract/`, `pso/`, `shell-framework/`).
    nonisolated static func isBuildWorkDirectoryPath(_ path: String) -> Bool {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        let components = normalized.split(separator: "/").map { $0.lowercased() }
        if components.contains(where: { $0 == "shader" || $0 == "extract" || $0 == "pso" || $0 == "shell-framework" }) {
            return true
        }
        return components.contains(where: { $0.hasSuffix("_build") })
    }

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
            guard !trimmed.isEmpty,
                  !isBuildWorkDirectoryPath(trimmed),
                  fm.fileExists(atPath: trimmed) else { return nil }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: trimmed, isDirectory: &isDir) else { return nil }
            if isDir.boolValue {
                guard let primary = RomFSArchive.primaryImagePath(in: trimmed, fm: fm),
                      fm.fileExists(atPath: primary),
                      RomFSArchive.isValidPrimaryRomFSImage(atPath: primary) else {
                    return nil
                }
                return (trimmed, primary)
            }
            let lower = trimmed.lowercased()
            guard lower.hasSuffix(".img"),
                  !lower.contains(".app/"),
                  RomFSArchive.isValidPrimaryRomFSImage(atPath: trimmed) else {
                return nil
            }
            let parent = (trimmed as NSString).deletingLastPathComponent
            guard !isBuildWorkDirectoryPath(parent) else { return nil }
            return (parent, trimmed)
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
        for cand in prefillCandidates where !cand.contains(".app/") && !isBuildWorkDirectoryPath(cand) {
            if let found = matchInPath(cand) {
                return found
            }
        }
        return nil
    }

    /// Pulls `Documents/games/<TID>/romfs.img` from `deviceID` when it is online so rebuilt iOS shaders can be injected into a real `DMROMFS1` image.
    /// Returns `nil` when the device is offline/unpaired, or a `Result` with the pulled `(archiveDir, imgPath)` / error.
    nonisolated static func pullDeviceImageIfOnline(
        deviceID: String,
        snapshotDevices: [AppleDevice],
        xcrun: String,
        shellCachePath: String,
        seedRoot: String,
        repoPath: String,
        tid: String,
        gameName: String,
        outDir: String,
        runner: ProcessRunner,
        isCancelled: @escaping @Sendable () -> Bool,
        onStartingPull: @Sendable () -> Void
    ) -> Result<(archiveDir: String, imgPath: String), DeviceImgPullError>? {
        guard !deviceID.isEmpty else { return nil }
        if isCancelled() { return .failure(.cancelled) }

        var connection = ShellInstall.connection(of: deviceID, in: snapshotDevices)
        if connection == .notPaired || connection == .notConnected {
            let liveDevices = DeviceTools.devices(xcrun: xcrun, timeout: 15, runner: runner)
            if isCancelled() { return .failure(.cancelled) }
            connection = ShellInstall.connection(of: deviceID, in: liveDevices)
        }
        guard connection != .notPaired && connection != .notConnected else {
            return nil
        }

        onStartingPull()

        let bundleID = ShellLibrary.load(root: shellCachePath).bundleID
        let rawIdentity = BuildSeedCache.inspect(titleID: tid, seedRoot: seedRoot, repoPath: repoPath)
            .record?.romfsIdentity?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let expectedIdentity = rawIdentity.flatMap { RomfsImageIdentity.parseIdentityLine($0) != nil ? $0 : nil }

        let control = DeviceControl.xcrun(xcrun, queryTimeout: 15, copyTimeout: 900, runner: runner)
        let puller = DeviceImgPuller(control: control)
        switch puller.pullImage(
            device: deviceID,
            bundleID: bundleID,
            titleID: tid,
            gameName: gameName,
            outDir: outDir,
            expectedIdentity: expectedIdentity,
            isCancelled: isCancelled
        ) {
        case .success(let pulledImg):
            guard RomFSArchive.isValidPrimaryRomFSImage(atPath: pulledImg) else {
                return .failure(.invalidPulledImage)
            }
            return .success(((pulledImg as NSString).deletingLastPathComponent, pulledImg))
        case .failure(let error):
            return .failure(error)
        }
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
                let dirName = (shaderSourcePath as NSString).lastPathComponent
                let keepSubdir = dirName.hasPrefix("b-") || dirName == "vk" || dirName == "gl"
                if keepSubdir {
                    try fm.createDirectory(atPath: stage, withIntermediateDirectories: true)
                    try fm.copyItem(atPath: shaderSourcePath, toPath: stage + "/" + dirName)
                } else {
                    try fm.copyItem(atPath: shaderSourcePath, toPath: stage)
                }
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
        guard RomFSArchive.isValidPrimaryRomFSImage(atPath: targetImg) else {
            return .failure(TrailerInjectionError(
                status: 1,
                message: "Refusing to modify non-DMROMFS1 file: \((targetImg as NSString).lastPathComponent)"
            ))
        }
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

    // MARK: Legacy Archive Migration

    private nonisolated static func sameInode(_ a: String, _ b: String) -> Bool {
        var sa = stat(), sb = stat()
        guard stat(a, &sa) == 0, stat(b, &sb) == 0 else {
            return URL(fileURLWithPath: a).standardizedFileURL == URL(fileURLWithPath: b).standardizedFileURL
        }
        return sa.st_dev == sb.st_dev && sa.st_ino == sb.st_ino
    }

    private nonisolated static func moveOrCopyReplacing(from src: String, to dst: String, fm: FileManager) -> Bool {
        do {
            try fm.moveItem(atPath: src, toPath: dst)
            return true
        } catch {
            let parent = (dst as NSString).deletingLastPathComponent
            let partial = parent + "/." + (dst as NSString).lastPathComponent + ".migrate-" + UUID().uuidString
            defer { try? fm.removeItem(atPath: partial) }
            do {
                try fm.copyItem(atPath: src, toPath: partial)
                try fm.moveItem(atPath: partial, toPath: dst)
                try? fm.removeItem(atPath: src)
                return true
            } catch {
                return false
            }
        }
    }

    nonisolated static func migrateLegacyArchiveIfNeeded(
        gamesRoot: String,
        tid: String,
        folderName: String,
        dest: String,
        targetImg: String,
        fm: FileManager
    ) {
        guard !tid.isEmpty else { return }
        // Same-folder upgrade: `<games>/<TID>/romfs.img` -> `<games>/<TID>/<TID>.img`.
        let legacySameFolderImg = dest + "/romfs.img"
        if folderName.caseInsensitiveCompare("romfs") != .orderedSame,
           !fm.fileExists(atPath: targetImg),
           fm.fileExists(atPath: legacySameFolderImg),
           !sameInode(legacySameFolderImg, targetImg) {
            if moveOrCopyReplacing(from: legacySameFolderImg, to: targetImg, fm: fm) {
                RomFSArchive.copyImageIdentity(of: legacySameFolderImg, to: targetImg)
                try? fm.removeItem(atPath: legacySameFolderImg + ".id")
            }
        }

        // Cross-folder migration: `<games>/<tid>/` -> `<games>/<folderName>/`.
        var checked = Set<String>()
        for candidateName in [tid, tid.uppercased(), tid.lowercased()] where checked.insert(candidateName).inserted {
            let legacyDir = gamesRoot + "/" + candidateName
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: legacyDir, isDirectory: &isDir), isDir.boolValue else { continue }
            guard !sameInode(legacyDir, dest) else { continue }
            let legacyImg = fm.fileExists(atPath: legacyDir + "/romfs.img")
                ? (legacyDir + "/romfs.img")
                : RomFSArchive.primaryImagePath(in: legacyDir, fm: fm)
            guard let legacyImg, fm.fileExists(atPath: legacyImg) else { continue }
            try? fm.createDirectory(atPath: dest, withIntermediateDirectories: true)

            if !fm.fileExists(atPath: targetImg) {
                if moveOrCopyReplacing(from: legacyImg, to: targetImg, fm: fm) {
                    RomFSArchive.copyImageIdentity(of: legacyImg, to: targetImg)
                    try? fm.removeItem(atPath: legacyImg + ".id")
                }
            }
            let legacyStamp = legacyDir + "/.packstamp"
            let destStamp = dest + "/.packstamp"
            if fm.fileExists(atPath: legacyStamp), !fm.fileExists(atPath: destStamp) {
                _ = moveOrCopyReplacing(from: legacyStamp, to: destStamp, fm: fm)
            }
            let legacyAOC = legacyDir + "/aoc"
            let destAOC = dest + "/aoc"
            if fm.fileExists(atPath: legacyAOC), !fm.fileExists(atPath: destAOC) {
                _ = moveOrCopyReplacing(from: legacyAOC, to: destAOC, fm: fm)
            }
            let remaining = (try? fm.contentsOfDirectory(atPath: legacyDir)) ?? []
            let disposable: Set<String> = [".DS_Store", ".titleid", ".packstamp"]
            if remaining.allSatisfy({ disposable.contains($0) }) {
                for item in remaining {
                    try? fm.removeItem(atPath: legacyDir + "/" + item)
                }
                try? fm.removeItem(atPath: legacyDir)
            }
        }
    }
}
