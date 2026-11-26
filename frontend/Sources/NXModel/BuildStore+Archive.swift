import Darwin
import Foundation
import Combine
import NXCore

// The archive step after the script: the RomFS image the game data goes over with (LNPANDY/NX2Apple#387).

extension BuildStore {
    // MARK: Archive

    struct IOSShaderSource: Sendable {
        var path: String
        var gfxAPI: String?
        var chain: String?
        var multiProgram: Bool
    }

    struct TrailerInjectionError: Error, Sendable {
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
    package func packArchive(workDir: String, titleID: String? = nil, isFastRefresh: Bool? = nil, then: @escaping (String) -> Void) {
        packArchiveWithOutcome(workDir: workDir, titleID: titleID, isFastRefresh: isFastRefresh) { outcome in
            then(outcome.archiveDir)
        }
    }

    package func packArchiveWithOutcome(
        workDir: String,
        titleID: String? = nil,
        isFastRefresh: Bool? = nil,
        then: @escaping (ArchivePackOutcome) -> Void
    ) {
        buildingGame = true
        runningTarget = BuildTarget.ios
        if operation == nil { beginOperation(.building, game: gameName, titleID: titleID, destination: .target) }
        running = true
        archiveGeneration &+= 1
        let generation = archiveGeneration
        let outFolder = effectiveOutputFolder
        let gamesRoot = outFolder + "/games"
        let tid = titleID.flatMap { $0.isEmpty ? nil : $0 } ?? buildKey
        let retryName = (shellRetry?.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedFallbackName = RomFSArchive.cleanPackageGameName(gameName)
        let isIOSBuild = runningTarget != BuildTarget.mac
        let repoPath = repo.path
        let pythonPath = resolveBuildPython()
        let runner = self.runner
        let externalImg = fastRefreshExternalImgPath
        let knownArchive = activeQueuedArchivePath
        let refreshRoot = refreshBuildsRoot
        let seedRoot = seedCacheRoot
        let shellCache = shellCachePath
        let installDeviceID = devices.installDevice
        let installDeviceName = installDeviceID.isEmpty ? "" : devices.deviceName(installDeviceID)
        let snapshotDevices = devices.devices
        let xcrunPath = devices.xcrun
        let canAutoPullFromDevice = isIOSBuild && installsDirectly && !exportsShell && !installDeviceID.isEmpty
        let cancelFlag = installCancel
        let currentLang = localizer.lang
        cancelFlag.set(false)
        if canAutoPullFromDevice { installPhaseActive = true }
        let forceRebuildTrailer = activeRunRebuiltShaders || activeQueuedRebuildsShaders
        let runStartedAt = activeRunStartedAt
        let deferPackaging = deferShellPackaging
        let isFastRefresh = isFastRefresh ?? (fastRefreshActive || (externalImg?.isEmpty == false))
        fastRefreshExternalImgPath = nil
        let idx = 1000

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let fm = FileManager.default
            let extract = workDir + "/extract"
            guard let v = RomFSArchive.extractedVersion(in: extract) else {
                let resolvedName = Self.resolveArchiveGameName(
                    workDir: workDir, tid: tid, repoPath: repoPath,
                    retryName: retryName, fallbackName: cleanedFallbackName, fm: fm
                )
                let folderName = RomFSArchive.archiveDirectoryName(gameName: resolvedName, titleID: tid, gamesRoot: gamesRoot, fm: fm)
                let canonicalDest = gamesRoot + "/" + folderName
                let canonicalImg = canonicalDest + "/" + folderName + ".img"

                Self.migrateLegacyArchiveIfNeeded(gamesRoot: gamesRoot, tid: tid, folderName: folderName, dest: canonicalDest, targetImg: canonicalImg, fm: fm)

                var resolvedDest = canonicalDest
                var resolvedImg = canonicalImg
                var hasValidLocalImg = fm.fileExists(atPath: resolvedImg) && RomFSArchive.isValidPrimaryRomFSImage(atPath: resolvedImg)
                if !hasValidLocalImg,
                   let externalImg, !externalImg.isEmpty,
                   externalImg.contains(".app/"),
                   fm.fileExists(atPath: externalImg),
                   RomFSArchive.isValidPrimaryRomFSImage(atPath: externalImg) {
                    // Never mutate a signed Mac .app bundle's romfs.img in place: clone/copy to canonicalDest for iOS trailer injection.
                    try? fm.createDirectory(atPath: canonicalDest, withIntermediateDirectories: true)
                    try? fm.removeItem(atPath: canonicalImg)
                    if (try? fm.copyItem(atPath: externalImg, toPath: canonicalImg)) != nil {
                        RomFSArchive.copyImageIdentity(of: externalImg, to: canonicalImg)
                        hasValidLocalImg = true
                    }
                }
                if !hasValidLocalImg,
                   (externalImg?.isEmpty != false),
                   let fallback = Self.findFallbackLocalArchive(
                       tid: tid,
                       knownArchivePath: knownArchive,
                       outDir: outFolder,
                       refreshBuildsRoot: refreshRoot,
                       prefillCandidates: [],
                       fm: fm
                   ) {
                    resolvedDest = fallback.archiveDir
                    resolvedImg = fallback.imgPath
                    hasValidLocalImg = true
                }

                let shaderSrc = (!hasValidLocalImg && (externalImg?.isEmpty != false) && isIOSBuild)
                    ? Self.locateIOSShaderSource(workDir: workDir, tid: tid, repoPath: repoPath, fm: fm)
                    : nil
                let needsShaderUpdate = isIOSBuild && (forceRebuildTrailer || (!isFastRefresh && shaderSrc != nil))
                var pullFailureNote: String? = nil

                if !hasValidLocalImg, (externalImg?.isEmpty != false), needsShaderUpdate, canAutoPullFromDevice {
                    let pullRes = Self.pullDeviceImageIfOnline(
                        deviceID: installDeviceID,
                        snapshotDevices: snapshotDevices,
                        xcrun: xcrunPath,
                        shellCachePath: shellCache,
                        seedRoot: seedRoot,
                        repoPath: repoPath,
                        tid: tid,
                        gameName: resolvedName,
                        outDir: outFolder,
                        runner: runner,
                        isCancelled: { cancelFlag.value },
                        onStartingPull: { [weak self] in
                            hop {
                                guard let self, self.archiveGeneration == generation, !self.stopping else { return }
                                let detail = String(format: self.t("prog.pullingDeviceImg"), installDeviceName)
                                self.upsertArchiveStage(id: idx, state: .running, detail: detail)
                                self.say(String(format: self.t("imgGuide.pulling"), installDeviceName))
                            }
                        }
                    )
                    if let pullRes {
                        switch pullRes {
                        case .success(let pulled):
                            resolvedDest = pulled.archiveDir
                            resolvedImg = pulled.imgPath
                            hasValidLocalImg = true
                        case .failure(.cancelled):
                            hop {
                                guard let self, self.archiveGeneration == generation else { return }
                                self.installPhaseActive = false
                                self.finishStoppedArchive()
                            }
                            return
                        case .failure(let err):
                            let reason = err.localizedReason { L10n.string($0, currentLang) }
                            pullFailureNote = String(format: L10n.string("msg.devicePullFallbackMSL", currentLang), installDeviceName, reason)
                        }
                    }
                }

                if hasValidLocalImg {
                    if cancelFlag.value {
                        hop {
                            guard let self, self.archiveGeneration == generation else { return }
                            self.installPhaseActive = false
                            self.finishStoppedArchive()
                        }
                        return
                    }
                    try? fm.createDirectory(atPath: resolvedDest, withIntermediateDirectories: true)
                    try? (tid.uppercased() + "\n").write(toFile: resolvedDest + "/.titleid", atomically: true, encoding: .utf8)

                    let trailerOutcome: TrailerInjectionOutcome
                    switch Self.injectIOSShaderTrailer(
                        targetImg: resolvedImg, workDir: workDir, tid: tid, isIOSBuild: isIOSBuild,
                        repoPath: repoPath, pythonPath: pythonPath, runner: runner,
                        forceReplace: forceRebuildTrailer, runStartedAt: runStartedAt, fm: fm
                    ) {
                    case .success(let outcome):
                        trailerOutcome = outcome
                    case .failure(let err):
                        hop {
                            guard let self, self.archiveGeneration == generation else { return }
                            self.installPhaseActive = false
                            if self.stopping {
                                self.finishStoppedArchive()
                                return
                            }
                            self.failArchiveTrailer(stageID: idx, error: err)
                        }
                        return
                    }
                    let aocCount = Self.placeAddOnContentOnBackground(workDir: workDir, in: resolvedDest)
                    PostBuildCleanup.cleanWorkDirectory(workDir, removeExtractedRomFS: false, removeShellFramework: false)
                    hop {
                        guard let self, self.archiveGeneration == generation else { return }
                        self.installPhaseActive = false
                        if self.stopping {
                            self.finishStoppedArchive()
                            return
                        }
                        if let line = trailerOutcome.logLine, !line.isEmpty { self.say(line) }
                        let didUpdate = isIOSBuild && trailerOutcome.didWriteTrailer
                        if !deferPackaging {
                            self.needsReplaceOldImgReminder = didUpdate
                            self.updatedImgPath = didUpdate ? resolvedImg : ""
                        }
                        self.archivePath = resolvedDest
                        self.upsertArchiveStage(id: idx, state: .done, detail: String(format: self.t("prog.archiveReused"), 1))
                        self.say(String(format: self.t("msg.archiveReused"), resolvedDest))
                        if aocCount > 0 { self.say(String(format: self.t("msg.aocCopied"), aocCount)) }
                        let outcome = ArchivePackOutcome(archiveDir: resolvedDest, primaryImgPath: resolvedImg, didUpdateImg: didUpdate, usedMSLFallback: false)
                        self.recordActiveEntryArchiveOutcome(outcome)
                        then(outcome)
                    }
                } else {
                    var extNotes: [String] = []
                    var externalResult: (succeeded: Bool, didWriteTrailer: Bool) = (false, false)
                    if isIOSBuild, let externalImg, !externalImg.isEmpty {
                        externalResult = Self.updateExternalImageTrailerInPlaceWithOutcome(
                            imgPath: externalImg, workDir: workDir, tid: tid,
                            repoPath: repoPath, pythonPath: pythonPath, runner: runner,
                            forceReplace: forceRebuildTrailer, runStartedAt: runStartedAt, fm: fm,
                            onNote: { extNotes.append($0) }
                        )
                    }
                    var fallbackMSLPath: String? = nil
                    if !externalResult.succeeded, needsShaderUpdate, let shaderSrc {
                        fallbackMSLPath = Self.stageMSLFallbackDirectory(shaderSourcePath: shaderSrc.path, dest: canonicalDest, tid: tid, fm: fm)
                    }
                    PostBuildCleanup.cleanWorkDirectory(workDir, removeExtractedRomFS: false, removeShellFramework: false)
                    hop {
                        guard let self, self.archiveGeneration == generation else { return }
                        self.installPhaseActive = false
                        if self.stopping {
                            self.finishStoppedArchive()
                            return
                        }
                        if let pullFailureNote { self.say(pullFailureNote) }
                        for note in extNotes where !note.isEmpty { self.say(note) }
                        if externalResult.succeeded, let externalImg {
                            let fileName = (externalImg as NSString).lastPathComponent
                            self.say(String(format: self.t("imgGuide.externalUpdatedLog"), self.shortPath(externalImg)))
                            self.upsertArchiveStage(
                                id: idx,
                                state: .done,
                                detail: String(format: self.t("prog.externalImgUpdated"), fileName)
                            )
                            let didUpdate = externalResult.didWriteTrailer
                            if !deferPackaging {
                                self.needsReplaceOldImgReminder = didUpdate
                                self.updatedImgPath = didUpdate ? externalImg : ""
                            }
                            self.archivePath = ""
                            let outcome = ArchivePackOutcome(archiveDir: "", primaryImgPath: didUpdate ? externalImg : "", didUpdateImg: didUpdate, usedMSLFallback: false)
                            self.recordActiveEntryArchiveOutcome(outcome)
                            then(outcome)
                        } else if let mslPath = fallbackMSLPath {
                            self.say(self.t("msg.mslFallbackStaged"))
                            self.upsertArchiveStage(id: idx, state: .done, detail: self.t("prog.mslFallbackStaged"))
                            if !deferPackaging {
                                self.needsReplaceOldImgReminder = true
                                self.updatedImgPath = mslPath
                            }
                            self.archivePath = canonicalDest
                            let outcome = ArchivePackOutcome(archiveDir: canonicalDest, primaryImgPath: mslPath, didUpdateImg: true, usedMSLFallback: true)
                            self.recordActiveEntryArchiveOutcome(outcome)
                            then(outcome)
                        } else {
                            self.say(String(format: self.t("msg.archiveSkipped"), extract))
                            self.upsertArchiveStage(id: idx, state: .done, detail: self.t("prog.noRomfs"))
                            if !deferPackaging {
                                self.needsReplaceOldImgReminder = false
                                self.updatedImgPath = ""
                            }
                            self.archivePath = ""
                            let outcome = ArchivePackOutcome()
                            self.recordActiveEntryArchiveOutcome(outcome)
                            then(outcome)
                        }
                    }
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
               RomFSArchive.isValidPrimaryRomFSImage(atPath: targetImg),
               let stamp = try? String(contentsOfFile: stampPath, encoding: .utf8), !stamp.isEmpty,
               let reused = RomFSArchive.archiveReusable(source: romfs, version: v, stamp: stamp) {
                let trailerOutcome: TrailerInjectionOutcome
                switch Self.injectIOSShaderTrailer(
                    targetImg: targetImg, workDir: workDir, tid: tid, isIOSBuild: isIOSBuild,
                    repoPath: repoPath, pythonPath: pythonPath, runner: runner,
                    forceReplace: forceRebuildTrailer, runStartedAt: runStartedAt, fm: fm
                ) {
                case .success(let outcome):
                    trailerOutcome = outcome
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
                    if let line = trailerOutcome.logLine, !line.isEmpty { self.say(line) }
                    let didUpdate = isIOSBuild && trailerOutcome.didWriteTrailer
                    if !deferPackaging {
                        self.needsReplaceOldImgReminder = didUpdate
                        self.updatedImgPath = didUpdate ? targetImg : ""
                    }
                    self.archivePath = dest
                    self.upsertArchiveStage(id: idx, state: .done, detail: String(format: self.t("prog.archiveReused"), reused))
                    self.say(String(format: self.t("msg.archiveReused"), dest))
                    if aocCount > 0 { self.say(String(format: self.t("msg.aocCopied"), aocCount)) }
                    let outcome = ArchivePackOutcome(archiveDir: dest, primaryImgPath: targetImg, didUpdateImg: didUpdate, usedMSLFallback: false)
                    self.recordActiveEntryArchiveOutcome(outcome)
                    then(outcome)
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
                    let trailerOutcome: TrailerInjectionOutcome
                    switch Self.injectIOSShaderTrailer(
                        targetImg: targetImg, workDir: workDir, tid: tid, isIOSBuild: isIOSBuild,
                        repoPath: repoPath, pythonPath: pythonPath, runner: runner,
                        forceReplace: forceRebuildTrailer, runStartedAt: runStartedAt, fm: fm
                    ) {
                    case .success(let outcome):
                        trailerOutcome = outcome
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
                        if let line = trailerOutcome.logLine, !line.isEmpty { self.say(line) }
                        let didUpdate = isIOSBuild && (trailerOutcome.didWriteTrailer || (isFastRefresh && placement == .moved))
                        if !deferPackaging {
                            self.needsReplaceOldImgReminder = didUpdate
                            self.updatedImgPath = didUpdate ? targetImg : ""
                        }
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
                        let outcome = ArchivePackOutcome(archiveDir: dest, primaryImgPath: targetImg, didUpdateImg: didUpdate, usedMSLFallback: false)
                        self.recordActiveEntryArchiveOutcome(outcome)
                        then(outcome)
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
                    tid: tid, isIOSBuild: isIOSBuild, fastRefreshMode: isFastRefresh,
                    deferPackaging: deferPackaging,
                    forceReplaceTrailer: forceRebuildTrailer,
                    runStartedAt: runStartedAt,
                    repoPath: repoPath, pythonPath: pythonPath,
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
            stages.append(Stage(id: id, name: t("prog.archive"), state: state, detail: detail, nameKey: "prog.archive"))
        }
        refreshOverallProgress(parsedTotal: nil)
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
        tid: String, isIOSBuild: Bool, fastRefreshMode: Bool, deferPackaging: Bool, forceReplaceTrailer: Bool, runStartedAt: Date?,
        repoPath: String, pythonPath: String, stageID: Int,
        generation: Int, then: @escaping (ArchivePackOutcome) -> Void
    ) {
        let engine = EngineLayout.root(repoPath)
        let safePy = MacNativeGamesBuilder.isManagedUVPython(pythonPath) ? Toolchain.findPython().path : pythonPath
        let romfsPy = safePy.isEmpty ? "/usr/bin/python3" : safePy
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
                    let trailerOutcome: TrailerInjectionOutcome
                    switch Self.injectIOSShaderTrailer(
                        targetImg: targetImg, workDir: workDir, tid: tid, isIOSBuild: isIOSBuild,
                        repoPath: repoPath, pythonPath: pythonPath, runner: runner,
                        forceReplace: forceReplaceTrailer, runStartedAt: runStartedAt, fm: fm
                    ) {
                    case .success(let outcome):
                        trailerOutcome = outcome
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
                        if let line = trailerOutcome.logLine, !line.isEmpty { self.say(line) }
                        let didUpdate = isIOSBuild && (fastRefreshMode || trailerOutcome.didWriteTrailer)
                        if !deferPackaging {
                            self.needsReplaceOldImgReminder = didUpdate
                            self.updatedImgPath = didUpdate ? targetImg : ""
                        }
                        self.archivePath = dest
                        if aocCount > 0 { self.say(String(format: self.t("msg.aocCopied"), aocCount)) }
                        self.upsertArchiveStage(id: stageID, state: .done, detail: String(format: self.t("prog.archiveDone"), dest))
                        let outcome = ArchivePackOutcome(archiveDir: dest, primaryImgPath: targetImg, didUpdateImg: didUpdate, usedMSLFallback: false)
                        self.recordActiveEntryArchiveOutcome(outcome)
                        then(outcome)
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

    // MARK: Shader Source & Trailer Injection

    nonisolated static func locateIOSShaderSource(
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

    nonisolated static func injectIOSShaderTrailerIfNeeded(
        targetImg: String,
        workDir: String,
        tid: String,
        isIOSBuild: Bool,
        repoPath: String,
        pythonPath: String,
        runner: ProcessRunner,
        fm: FileManager
    ) -> Result<String?, TrailerInjectionError> {
        injectIOSShaderTrailer(
            targetImg: targetImg,
            workDir: workDir,
            tid: tid,
            isIOSBuild: isIOSBuild,
            repoPath: repoPath,
            pythonPath: pythonPath,
            runner: runner,
            fm: fm
        ).map(\.logLine)
    }
}
