import Darwin
import Foundation
import Combine
import NXCore

// The archive step after the script: the RomFS image the game data goes over with (LNPANDY/NX2Apple#387).

extension BuildStore {
    // MARK: Archive

    private struct IOSShaderSource: Sendable {
        var path: String
        var gfxAPI: String?
        var chain: String?
        var multiProgram: Bool
    }

    private struct TrailerInjectionError: Error, Sendable {
        var status: Int32
        var message: String
    }

    nonisolated static func placeAddOnContentOnBackground(workDir: String, in dest: String) -> Int {
        let count = PostBuildCleanup.placeAddOnContent(from: workDir + "/aoc", to: dest + "/aoc")
        if let fw = ShellInstall.builtFramework(workDir: workDir) {
            let romfsSource = RomFSArchive.primaryImagePath(in: dest) ?? dest
            RomFSLanguages.applyToLauncherJSON(at: fw + "/dm/launcher.json", romfs: romfsSource)
        }
        return count
    }

    /// The DLC images ride along: with the slim default the build script leaves them in the work folder
    /// instead of packing them into the IPA, and the host mounts them from DM_AOC_DIR/<index>.img, so
    /// they belong in this game's folder. Every way the archive step can end (folder pack, image move,
    /// image reuse, stamp reuse) goes through here (issue #202).
    package func placeAddOnContent(workDir: String, in dest: String) {
        let n = Self.placeAddOnContentOnBackground(workDir: workDir, in: dest)
        if n > 0 { say(String(format: t("msg.aocCopied"), n)) }
    }

    /// Resolves the display/folder name for the game archive, matching Qt's `_resolve_archive_game_name` precedence.
    nonisolated static func resolveArchiveGameName(
        workDir: String,
        tid: String,
        repoPath: String,
        retryName: String,
        fallbackName: String,
        fm: FileManager = .default
    ) -> String {
        if !workDir.isEmpty,
           let fw = ShellInstall.builtFramework(workDir: workDir, fm: fm),
           let data = fm.contents(atPath: fw + "/game.manifest.json"),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let manifestName = (obj["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !manifestName.isEmpty,
           manifestName.caseInsensitiveCompare(tid) != .orderedSame {
            return manifestName
        }
        let retry = retryName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !retry.isEmpty, retry.caseInsensitiveCompare(tid) != .orderedSame {
            return retry
        }
        if let tidVal = UInt64(tid, radix: 16),
           let profile = GameFolder.profileName(tidVal, engineRoot: EngineLayout.root(repoPath))?
               .trimmingCharacters(in: .whitespacesAndNewlines),
           !profile.isEmpty {
            return profile
        }
        let fallback = fallbackName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !fallback.isEmpty, fallback.caseInsensitiveCompare(tid) != .orderedSame {
            return fallback
        }
        return tid
    }

    /// Pack or move the extracted RomFS into `<games>/<FolderName>/<FolderName>.img` off the main actor, inject any iOS `DMMSLTR1`
    /// shader trailer, and reclaim intermediate build files in `workDir`.
    /// `then` continues the build with the archive's folder (installing on a device or exporting the shared app).
    /// `titleID` names the game's title ID (the framework's title ID), falling back to the build key when omitted.
    package func packArchive(workDir: String, titleID: String? = nil, then: @escaping (String) -> Void) {
        buildingGame = true; runningTarget = BuildTarget.ios
        if operation == nil { beginOperation(.building, game: gameName, titleID: titleID, destination: .target) }
        running = true
        archiveGeneration &+= 1
        let generation = archiveGeneration
        let gamesRoot = (outDir.isEmpty ? inputFolder : outDir) + "/games"
        let tid = titleID.flatMap { $0.isEmpty ? nil : $0 } ?? buildKey
        let retryName = (shellRetry?.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedFallbackName = RomFSArchive.cleanPackageGameName(gameName)
        let isIOSBuild = runningTarget != BuildTarget.mac
        let repoPath = repo.path
        let pythonPath = deps.pythonPath
        let runner = self.runner
        let idx = 1000

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let fm = FileManager.default
            let extract = workDir + "/extract"
            guard let v = RomFSArchive.extractedVersion(in: extract) else {
                hop {
                    guard let self, self.archiveGeneration == generation else { return }
                    if self.stopping {
                        self.finishStoppedArchive()
                        return
                    }
                    self.stages.append(Stage(id: idx, name: self.t("prog.archiveShort"), state: .failed, detail: self.t("prog.noRomfs")))
                    self.doneNote = String(format: self.t("msg.archiveSkipped"), extract)
                    self.running = false
                    self.cleanupStaging()
                }
                return
            }

            let resolvedName = Self.resolveArchiveGameName(
                workDir: workDir, tid: tid, repoPath: repoPath,
                retryName: retryName, fallbackName: cleanedFallbackName, fm: fm
            )
            let folderName = RomFSArchive.archiveDirectoryName(gameName: resolvedName, titleID: tid, gamesRoot: gamesRoot, fm: fm)
            let dest = gamesRoot + "/" + folderName
            let targetImg = dest + "/" + folderName + ".img"
            let romfs = extract + "/" + v + "/RomFS"
            let romfsImage = extract + "/" + v + "/RomFS.img"

            try? fm.createDirectory(atPath: dest, withIntermediateDirectories: true)
            Self.migrateLegacyArchiveIfNeeded(gamesRoot: gamesRoot, tid: tid, folderName: folderName, dest: dest, targetImg: targetImg, fm: fm)
            try? (tid.uppercased() + "\n").write(toFile: dest + "/.titleid", atomically: true, encoding: .utf8)

            let stampPath = dest + "/.packstamp"
            if fm.fileExists(atPath: targetImg),
               let stamp = try? String(contentsOfFile: stampPath, encoding: .utf8), !stamp.isEmpty,
               let reused = RomFSArchive.archiveReusable(source: romfs, version: v, stamp: stamp) {
                let trailerOut: String?
                switch Self.injectIOSShaderTrailerIfNeeded(
                    targetImg: targetImg, workDir: workDir, tid: tid, isIOSBuild: isIOSBuild,
                    repoPath: repoPath, pythonPath: pythonPath, runner: runner, fm: fm
                ) {
                case .success(let logLine):
                    trailerOut = logLine
                case .failure(let err):
                    hop {
                        guard let self, self.archiveGeneration == generation else { return }
                        if self.stopping {
                            self.finishStoppedArchive()
                            return
                        }
                        self.failArchiveTrailer(stageID: idx, error: err)
                    }
                    return
                }
                let aocCount = Self.placeAddOnContentOnBackground(workDir: workDir, in: dest)
                PostBuildCleanup.cleanWorkDirectory(workDir, removeExtractedRomFS: false, removeShellFramework: false)
                hop {
                    guard let self, self.archiveGeneration == generation else { return }
                    if self.stopping {
                        self.finishStoppedArchive()
                        return
                    }
                    if let trailerOut, !trailerOut.isEmpty { self.say(trailerOut) }
                    self.archivePath = dest
                    self.stages.append(Stage(id: idx, name: self.t("prog.archive"), state: .done,
                                             detail: String(format: self.t("prog.archiveReused"), reused)))
                    self.say(String(format: self.t("msg.archiveReused"), dest))
                    if aocCount > 0 { self.say(String(format: self.t("msg.aocCopied"), aocCount)) }
                    then(dest)
                }
                return
            }

            // Remove legacy ROMFSARC shards while keeping any existing image in place until PostBuildCleanup.placeImage
            // either matches its size and modification date or replaces it atomically.
            for old in ((try? fm.contentsOfDirectory(atPath: dest)) ?? [])
            where old == "romfs.idx" || (old.hasPrefix("romfs.") && old.dropFirst(6).allSatisfy(\.isNumber)) {
                try? fm.removeItem(atPath: dest + "/" + old)
            }

            if fm.fileExists(atPath: romfsImage) {
                hop {
                    guard let self, self.archiveGeneration == generation, !self.stopping else { return }
                    self.upsertArchiveStage(id: idx, state: .running, detail: v)
                    self.say(String(format: self.t("msg.archiveLog"), romfs, dest))
                }
                do {
                    let placement = try PostBuildCleanup.placeImage(from: romfsImage, to: targetImg)
                    let trailerOut: String?
                    switch Self.injectIOSShaderTrailerIfNeeded(
                        targetImg: targetImg, workDir: workDir, tid: tid, isIOSBuild: isIOSBuild,
                        repoPath: repoPath, pythonPath: pythonPath, runner: runner, fm: fm
                    ) {
                    case .success(let logLine):
                        trailerOut = logLine
                    case .failure(let err):
                        hop {
                            guard let self, self.archiveGeneration == generation else { return }
                            if self.stopping {
                                self.finishStoppedArchive()
                                return
                            }
                            self.failArchiveTrailer(stageID: idx, error: err)
                        }
                        return
                    }
                    let aocCount = Self.placeAddOnContentOnBackground(workDir: workDir, in: dest)
                    PostBuildCleanup.cleanWorkDirectory(workDir, removeExtractedRomFS: true, removeShellFramework: false)
                    hop {
                        guard let self, self.archiveGeneration == generation else { return }
                        if self.stopping {
                            self.finishStoppedArchive()
                            return
                        }
                        if let trailerOut, !trailerOut.isEmpty { self.say(trailerOut) }
                        switch placement {
                        case .reused:
                            self.upsertArchiveStage(id: idx, state: .done, detail: String(format: self.t("prog.archiveReused"), 1))
                            self.say(String(format: self.t("msg.archiveReused"), dest))
                        case .moved:
                            self.upsertArchiveStage(id: idx, state: .done, detail: v)
                            self.say(String(format: self.t("msg.archiveLog"), romfsImage, dest))
                        }
                        if aocCount > 0 { self.say(String(format: self.t("msg.aocCopied"), aocCount)) }
                        self.archivePath = dest
                        then(dest)
                    }
                } catch {
                    hop {
                        guard let self, self.archiveGeneration == generation else { return }
                        if self.stopping {
                            self.finishStoppedArchive()
                            return
                        }
                        self.upsertArchiveStage(id: idx, state: .failed, detail: error.localizedDescription)
                        self.doneNote = String(format: self.t("msg.archiveFailed"), 1)
                        self.running = false
                        self.cleanupStaging()
                    }
                }
                return
            }

            for old in Set(["romfs.img", "romfs.img.id", folderName + ".img", folderName + ".img.id"]) {
                try? fm.removeItem(atPath: dest + "/" + old)
            }
            hop {
                guard let self, self.archiveGeneration == generation else { return }
                if self.stopping {
                    self.finishStoppedArchive()
                    return
                }
                self.upsertArchiveStage(id: idx, state: .running, detail: v)
                self.say(String(format: self.t("msg.archiveLog"), romfs, dest))
                self.launchLegacyRomFSImagePack(
                    workDir: workDir, romfs: romfs, version: v, dest: dest, targetImg: targetImg,
                    tid: tid, isIOSBuild: isIOSBuild, repoPath: repoPath, pythonPath: pythonPath,
                    stageID: idx, generation: generation, then: then
                )
            }
        }
    }

    private func upsertArchiveStage(id: Int, state: StepState, detail: String) {
        if let i = stages.firstIndex(where: { $0.id == id }) {
            stages[i].state = state
            stages[i].detail = detail
        } else {
            stages.append(Stage(id: id, name: t("prog.archive"), state: state, detail: detail))
        }
    }

    private func failArchiveTrailer(stageID: Int, error: TrailerInjectionError) {
        if !error.message.isEmpty { say("✗ " + error.message) }
        let note = String(format: t("msg.archiveFailed"), error.status)
        upsertArchiveStage(id: stageID, state: .failed, detail: error.message.isEmpty ? note : error.message)
        doneNote = note
        running = false
        done = false
        cleanupStaging()
    }

    private func finishStoppedArchive() {
        stopping = false
        running = false
        done = false
        resetProgress()
        doneNote = t("msg.stopped")
        cleanupStaging()
    }

    private func launchLegacyRomFSImagePack(
        workDir: String, romfs: String, version: String, dest: String, targetImg: String,
        tid: String, isIOSBuild: Bool, repoPath: String, pythonPath: String, stageID: Int,
        generation: Int, then: @escaping (String) -> Void
    ) {
        let engine = EngineLayout.root(repoPath)
        let romfsPy = pythonPath.isEmpty ? "/usr/bin/python3" : pythonPath
        let runner = self.runner
        let launch = ProcessLaunch(
            executable: romfsPy,
            arguments: [engine + "/" + RepoLayout.romfsImageTool, "--reuse", romfs, targetImg],
            environment: ["PATH": BuildCommands.toolPath("/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin", python: romfsPy),
                          "PYTHONPATH": engine + "/dm/tools"]
                .merging(BundledTools.environment(for: romfsPy)) { $1 },
            groupPython: romfsPy
        )
        let onExit: @Sendable (Int32) -> Void = { [weak self] st in
            hop {
                guard let self, self.archiveGeneration == generation else { return }
                let cancelled = self.stopping
                let succeeded = st == 0 && !cancelled
                self.stopping = false
                guard succeeded else {
                    self.upsertArchiveStage(id: stageID, state: .failed, detail: String(format: self.t("msg.archiveFailed"), st))
                    self.cleanupStaging()
                    self.running = false
                    self.done = false
                    if cancelled { self.resetProgress() }
                    self.doneNote = cancelled ? self.t("msg.stopped") : String(format: self.t("msg.archiveFailed"), st)
                    return
                }
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    let fm = FileManager.default
                    RomFSArchive.writeStamp(source: romfs, version: version, to: dest + "/.packstamp")
                    let trailerOut: String?
                    switch Self.injectIOSShaderTrailerIfNeeded(
                        targetImg: targetImg, workDir: workDir, tid: tid, isIOSBuild: isIOSBuild,
                        repoPath: repoPath, pythonPath: pythonPath, runner: runner, fm: fm
                    ) {
                    case .success(let logLine):
                        trailerOut = logLine
                    case .failure(let err):
                        hop {
                            guard let self, self.archiveGeneration == generation else { return }
                            if self.stopping {
                                self.finishStoppedArchive()
                                return
                            }
                            self.failArchiveTrailer(stageID: stageID, error: err)
                        }
                        return
                    }
                    let aocCount = Self.placeAddOnContentOnBackground(workDir: workDir, in: dest)
                    PostBuildCleanup.cleanWorkDirectory(workDir, removeExtractedRomFS: true, removeShellFramework: false)
                    hop {
                        guard let self, self.archiveGeneration == generation else { return }
                        if self.stopping {
                            self.finishStoppedArchive()
                            return
                        }
                        if let trailerOut, !trailerOut.isEmpty { self.say(trailerOut) }
                        self.archivePath = dest
                        if aocCount > 0 { self.say(String(format: self.t("msg.aocCopied"), aocCount)) }
                        self.upsertArchiveStage(id: stageID, state: .done, detail: String(format: self.t("prog.archiveDone"), dest))
                        then(dest)
                    }
                }
            }
        }
        do {
            proc = try runner.start(launch, onOutput: { @Sendable [weak self] d in
                guard let s = String(data: d, encoding: .utf8) else { return }
                hop { self?.append(s) }
            }, onExit: onExit)
        } catch {
            upsertArchiveStage(id: stageID, state: .failed, detail: t("msg.archiveNoStart"))
            running = false
            doneNote = t("msg.archiveNoStart")
            cleanupStaging()
        }
    }

    // MARK: Legacy Migration & Trailer Injection

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

    private nonisolated static func migrateLegacyArchiveIfNeeded(
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

    private nonisolated static func locateIOSShaderSource(
        workDir: String,
        tid: String,
        repoPath: String,
        fm: FileManager
    ) -> IOSShaderSource? {
        let builtFW = ShellInstall.builtFramework(workDir: workDir, fm: fm)
        let fwTID = builtFW.map { ShellInstall.titleID(ofFramework: $0) } ?? ""
        var cacheIDs: [String] = []
        for candidate in [tid.uppercased(), fwTID.uppercased()] where !candidate.isEmpty && !cacheIDs.contains(candidate) {
            cacheIDs.append(candidate)
        }
        for cacheID in cacheIDs {
            let metaPath = workDir + "/shell-framework/.msl-cache/" + cacheID + ".json"
            if let data = fm.contents(atPath: metaPath),
               let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                let libPath = (json["lib_path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let mslRoot = (json["msl_root"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let chosen = (!libPath.isEmpty && fm.fileExists(atPath: libPath)) ? libPath
                    : ((!mslRoot.isEmpty && fm.fileExists(atPath: mslRoot)) ? mslRoot : "")
                if !chosen.isEmpty {
                    let api = (json["gfx_api"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let chain = (json["chain"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let multi = (json["multi_program"] as? Bool) ?? false
                    return IOSShaderSource(
                        path: chosen,
                        gfxAPI: (api?.isEmpty == false) ? api : nil,
                        chain: (chain?.isEmpty == false) ? chain : nil,
                        multiProgram: multi
                    )
                }
            }
        }

        let manifest = builtFW
            .flatMap { fm.contents(atPath: $0 + "/game.manifest.json") }
            .flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
        let manifestAPI = (manifest?["gfx_api"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let manifestChain = (manifest?["chain"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let expectedChain = (manifestChain?.isEmpty == false) ? manifestChain
            : EngineLayout.shaderChain(repo: repoPath).map { "b-" + $0 }

        let shaderIOS = workDir + "/shader/ios"
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: shaderIOS, isDirectory: &isDir), isDir.boolValue,
           let entries = try? fm.contentsOfDirectory(atPath: shaderIOS) {
            let visible = entries.filter { !$0.hasPrefix(".") && !$0.contains(".tmp") && !$0.hasSuffix(".key") }.sorted()
            let progDirs = visible.filter { name in
                guard name.range(of: #"^p\d+$"#, options: .regularExpression) != nil else { return false }
                var subDir: ObjCBool = false
                return fm.fileExists(atPath: shaderIOS + "/" + name, isDirectory: &subDir) && subDir.boolValue
            }
            if !progDirs.isEmpty {
                let api = (manifestAPI?.isEmpty == false) ? manifestAPI : nil
                let chain = (api == nil || api == "nvn") ? expectedChain : nil
                return IOSShaderSource(path: shaderIOS, gfxAPI: api, chain: chain, multiProgram: true)
            }
            if manifestAPI == "vulkan", fm.fileExists(atPath: shaderIOS + "/vk") {
                return IOSShaderSource(path: shaderIOS + "/vk", gfxAPI: "vulkan", chain: nil, multiProgram: false)
            }
            if manifestAPI == "gl", fm.fileExists(atPath: shaderIOS + "/gl") {
                return IOSShaderSource(path: shaderIOS + "/gl", gfxAPI: "gl", chain: nil, multiProgram: false)
            }
            if let expectedChain, (manifestAPI == nil || manifestAPI == "nvn") {
                let dirCandidate = shaderIOS + "/" + expectedChain
                let imgCandidate = dirCandidate + ".img"
                if fm.fileExists(atPath: dirCandidate) {
                    return IOSShaderSource(path: dirCandidate, gfxAPI: "nvn", chain: expectedChain, multiProgram: false)
                }
                if fm.fileExists(atPath: imgCandidate) {
                    return IOSShaderSource(path: imgCandidate, gfxAPI: "nvn", chain: expectedChain, multiProgram: false)
                }
            }
            var nvnStems: [String] = []
            for name in visible {
                if name.hasPrefix("b-") {
                    let stem = name.hasSuffix(".img") ? String(name.dropLast(4)) : name
                    if !nvnStems.contains(stem) { nvnStems.append(stem) }
                }
            }
            if let chosenStem = nvnStems.max(by: { a, b in
                let pa = fm.fileExists(atPath: shaderIOS + "/" + a) ? (shaderIOS + "/" + a) : (shaderIOS + "/" + a + ".img")
                let pb = fm.fileExists(atPath: shaderIOS + "/" + b) ? (shaderIOS + "/" + b) : (shaderIOS + "/" + b + ".img")
                let da = ((try? fm.attributesOfItem(atPath: pa))?[.modificationDate] as? Date) ?? .distantPast
                let db = ((try? fm.attributesOfItem(atPath: pb))?[.modificationDate] as? Date) ?? .distantPast
                return (da, a) < (db, b)
            }) {
                let dirPath = shaderIOS + "/" + chosenStem
                let srcPath = fm.fileExists(atPath: dirPath) ? dirPath : (dirPath + ".img")
                return IOSShaderSource(path: srcPath, gfxAPI: "nvn", chain: chosenStem, multiProgram: false)
            }
            if fm.fileExists(atPath: shaderIOS + "/vk") {
                return IOSShaderSource(path: shaderIOS + "/vk", gfxAPI: "vulkan", chain: nil, multiProgram: false)
            }
            if fm.fileExists(atPath: shaderIOS + "/gl") {
                return IOSShaderSource(path: shaderIOS + "/gl", gfxAPI: "gl", chain: nil, multiProgram: false)
            }
        }

        for dmshB in [workDir + "/build/ios/dmsh_b", workDir + "/ipa/build/ios/dmsh_b"] {
            var dmshIsDir: ObjCBool = false
            guard fm.fileExists(atPath: dmshB, isDirectory: &dmshIsDir), dmshIsDir.boolValue,
                  let files = try? fm.contentsOfDirectory(atPath: dmshB) else { continue }
            let hasShaderPayload = files.contains { name in
                !name.hasPrefix(".") && (name.hasSuffix(".metallib") || name.hasSuffix(".tsv") || name.hasSuffix(".json"))
            }
            guard hasShaderPayload else { continue }
            let api = (manifestAPI?.isEmpty == false) ? manifestAPI! : "nvn"
            let chain = api == "nvn" ? expectedChain : nil
            return IOSShaderSource(path: dmshB, gfxAPI: api, chain: chain, multiProgram: false)
        }
        return nil
    }

    private nonisolated static func injectIOSShaderTrailerIfNeeded(
        targetImg: String,
        workDir: String,
        tid: String,
        isIOSBuild: Bool,
        repoPath: String,
        pythonPath: String,
        runner: ProcessRunner,
        fm: FileManager
    ) -> Result<String?, TrailerInjectionError> {
        guard let shaderSource = locateIOSShaderSource(workDir: workDir, tid: tid, repoPath: repoPath, fm: fm),
              isIOSBuild else {
            return .success(nil)
        }
        do {
            try PostBuildCleanup.breakHardLinksIfNeeded(at: targetImg, fm: fm)
        } catch {
            return .failure(TrailerInjectionError(status: 1, message: error.localizedDescription))
        }

        let resolvedPy = pythonPath.isEmpty ? Toolchain.findPython().path : pythonPath
        let py = resolvedPy.isEmpty ? "/usr/bin/python3" : resolvedPy
        let tool = EngineLayout.root(repoPath) + "/" + RepoLayout.romfsImageTool
        let env = ["PATH": BuildCommands.toolPath("/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin", python: py)]
            .merging(BundledTools.environment(for: py)) { $1 }

        func run(modeFlag: String) -> ProcessResult {
            var args = ["-I", tool, modeFlag, targetImg, shaderSource.path]
            if let api = shaderSource.gfxAPI, !api.isEmpty { args += ["--gfx-api", api] }
            if let chain = shaderSource.chain, !chain.isEmpty { args += ["--chain", chain] }
            if shaderSource.multiProgram { args.append("--multi-program") }
            return runner.capture(ProcessLaunch(executable: py, arguments: args, environment: env, mergesErrors: true))
        }

        var result = run(modeFlag: "--append-msl")
        if !result.ok {
            result = run(modeFlag: "--replace-msl")
        }
        let text = result.out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.ok else {
            let code: Int32 = result.status == 0 ? 1 : result.status
            return .failure(TrailerInjectionError(status: code, message: text))
        }
        return .success(text.isEmpty ? nil : text)
    }
}
