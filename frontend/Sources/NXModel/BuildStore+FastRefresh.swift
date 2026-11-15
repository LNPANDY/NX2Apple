import Foundation
import Combine
import NXCore

extension BuildStore {
    private func clearFastRefreshContext() {
        fastRefreshActive = false
        fastRefreshTitleID = nil
        fastRefreshBaseDir = nil
        fastRefreshGameName = nil
        fastRefreshExternalImgPath = nil
    }

    /// Starts a fast refresh build from a build seed without requiring NSPs or keys.
    package func startFastRefresh(
        titleID: String,
        target: Int,
        outDir: String? = nil,
        gameName: String? = nil,
        existingMacAppPath: String? = nil,
        externalImgPath: String? = nil
    ) {
        startFastRefresh(
            titleID: titleID,
            targetName: target == 0 ? BuildTarget.mac : BuildTarget.ios,
            outDir: outDir,
            gameName: gameName,
            existingMacAppPath: existingMacAppPath,
            externalImgPath: externalImgPath
        )
    }

    /// Compatibility forwarder matching the original 4-parameter signature.
    package func startFastRefresh(
        titleID: String,
        target: Int,
        gameName: String?,
        existingMacAppPath: String?
    ) {
        startFastRefresh(
            titleID: titleID,
            target: target,
            outDir: nil,
            gameName: gameName,
            existingMacAppPath: existingMacAppPath,
            externalImgPath: nil
        )
    }

    /// Compatibility forwarder matching the named target 4-parameter signature.
    package func startFastRefresh(
        titleID: String,
        targetName: String,
        gameName: String?,
        existingMacAppPath: String?
    ) {
        startFastRefresh(
            titleID: titleID,
            targetName: targetName,
            outDir: nil,
            gameName: gameName,
            existingMacAppPath: existingMacAppPath,
            externalImgPath: nil
        )
    }

    /// Starts a fast refresh build using a named build target ("mac-app" or "ios").
    package func startFastRefresh(
        titleID: String,
        targetName: String,
        outDir: String? = nil,
        gameName: String? = nil,
        existingMacAppPath: String? = nil,
        externalImgPath: String? = nil
    ) {
        guard !running else { return }
        let tid = titleID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !tid.isEmpty else { return }

        guard repo.isRepo else {
            fail(repo.path.isEmpty ? t("msg.repoInvalidEmpty") : String(format: t("msg.repoInvalid"), shortPath(repo.path)))
            return
        }
        guard RepoLayout.supportsBuildSeed(repo.path) else {
            fail(String(format: t("msg.toolsOld"), "scripts/build_ipa_from_nsp.py (--from-seed)"))
            return
        }

        let py = deps.pythonPath.isEmpty ? Toolchain.findPython().path : deps.pythonPath
        let seedRoot = BuildSeedCache.defaultRoot(home: self.home)
        let trimmedExternalImg = externalImgPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let validExternalImg: String? = (!trimmedExternalImg.isEmpty && FileManager.default.fileExists(atPath: trimmedExternalImg))
            ? trimmedExternalImg
            : nil

        let resolvedOutDir: String = {
            if let explicit = outDir, !explicit.isEmpty { return explicit }
            if !self.outDir.isEmpty { return self.outDir }
            if let app = existingMacAppPath, !app.isEmpty {
                let parent = (app as NSString).deletingLastPathComponent
                if !parent.isEmpty && parent != "/" { return parent }
            }
            let sameGame = (gameFolder?.hasTitleID == true && gameFolder?.titleIDHex.caseInsensitiveCompare(tid) == .orderedSame)
                || (!basePath.isEmpty && TitleID.parse(basePath).map { String(format: "%016llX", $0) }?.caseInsensitiveCompare(tid) == .orderedSame)
            if sameGame && !inputFolder.isEmpty && inputFolder != "/" {
                return inputFolder
            }
            return (BuildSeedCache.defaultRoot(home: self.home) as NSString).deletingLastPathComponent + "/refresh-builds"
        }()

        try? FileManager.default.createDirectory(atPath: resolvedOutDir, withIntermediateDirectories: true)
        let workDir = resolvedOutDir + "/" + tid + "_build"

        // Configure store state for fast refresh (external image path is set after device verification succeeds)
        fastRefreshActive = true
        fastRefreshTitleID = tid
        fastRefreshBaseDir = resolvedOutDir
        fastRefreshGameName = (gameName?.isEmpty == false) ? gameName : nil
        fastRefreshExternalImgPath = nil
        self.target = BuildTarget.normalized(targetName)
        runningTarget = self.target

        let isMac = self.target == BuildTarget.mac
        if !isMac, !shellDeviceChecked, !exportsShell {
            guard installsDirectly else {
                doneNote = t("shell.needsDevice")
                done = false
                running = false
                clearFastRefreshContext()
                return
            }
            verifyShellDevice { [weak self] in
                self?.startFastRefresh(
                    titleID: tid,
                    targetName: targetName,
                    outDir: outDir,
                    gameName: gameName,
                    existingMacAppPath: existingMacAppPath,
                    externalImgPath: externalImgPath
                )
            }
            return
        }
        shellDeviceChecked = false

        if cloudFolderCheck(workDir) {
            failure = BuildFailure(kind: .cloudFolder, gameName: nil, detail: workDir)
            fail(failureWhat(failure!))
            clearFastRefreshContext()
            return
        }

        if !isMac, !exportsOneGame, let why = shellRootProblem() {
            fail(why)
            clearFastRefreshContext()
            return
        }

        stopping = false
        stoppedByPlayer = false
        archiveGeneration &+= 1
        buildingGame = true
        beginOperation(.building, game: self.gameName, titleID: self.gameTitleID, destination: .target)
        running = true
        done = false
        doneNote = ""
        stages = []
        log.clear()
        staleShadersMessageKey = nil
        failure = nil
        installedOn = ""
        installedAppPath = ""
        exportedIPAPath = ""
        send = .idle

        if let message = preflightSpaceProblem() {
            doneNote = message
            done = false
            running = false
            clearFastRefreshContext()
            return
        }

        let engine = EngineLayout.root(repo.path)
        var args = [
            engine + "/" + RepoLayout.buildScript,
            "--from-seed",
            "--title-id", tid,
            "--seed-cache-dir", seedRoot,
            "--work-dir", workDir,
            "--progress", "json"
        ]

        let macOutput = isMac
            ? MacAppOutput(workDir: URL(fileURLWithPath: workDir), key: tid, titleID: tid, preferred: existingMacAppPath ?? macAppPath)
            : nil
        oneGameIPAPath = ""

        var tempEnvURL: URL?
        if exportsOneGame {
            oneGameIPAPath = OneGameIPA.path(folder: resolvedOutDir, titleID: tid)
            args += OneGameIPA.arguments(ipa: oneGameIPAPath)
        } else if isMac, let macOutput {
            macAppPath = ""
            args += ["--platform", "mac-app", "-o", macOutput.builderURL.path]
            if RepoLayout.supportsFallbackIcon(repo.path) { args += macFallbackIconArguments(tid) }

            var romfsCandidates: [String] = []
            var seenRomfs = Set<String>()
            func addRomfs(_ path: String) {
                guard !path.isEmpty, !seenRomfs.contains(path), FileManager.default.fileExists(atPath: path) else { return }
                seenRomfs.insert(path)
                romfsCandidates.append(path)
            }
            if let existingApp = existingMacAppPath ?? (FileManager.default.fileExists(atPath: macOutput.builderURL.path) ? macOutput.builderURL.path : nil) {
                addRomfs(existingApp + "/Contents/Resources/romfs.img")
            }
            for img in RomFSArchive.reusableImages(root: resolvedOutDir, key: tid) {
                addRomfs(img)
            }
            if let extImg = validExternalImg {
                addRomfs(extImg)
            }
            for img in romfsCandidates {
                args += ["--romfs-from", img]
            }
        } else {
            let envURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nspb-env-\(UUID().uuidString).txt")
            let envText = GameMenuText.envFile(bcOnCPU: bcOnCPU, t)
            try? envText.write(to: envURL, atomically: true, encoding: .utf8)
            tempEnvURL = envURL
            args += ["--env-file", envURL.path]
            if bcOnCPU { say(t("msg.bcOn")) }
            args += ShellInstall.buildArguments(workDir: workDir, team: exportsShell ? "" : devices.signingTeam)
        }

        let repoPath = repo.path
        let prefillMacAppPath = existingMacAppPath ?? macAppPath
        let initialInspection = BuildSeedCache.inspect(titleID: tid, seedRoot: seedRoot, repoPath: repoPath)
        let adoptTool = engine + "/" + RepoLayout.buildSeedTool
        let needsAdopt = !initialInspection.isUsable
            && FileManager.default.fileExists(atPath: adoptTool)
            && FileManager.default.fileExists(atPath: workDir)

        let syncCandidates = needsAdopt
            ? []
            : BuildSeedCache.prefillCandidates(
                titleID: tid,
                outDir: resolvedOutDir,
                gameName: gameName,
                macAppPath: prefillMacAppPath,
                workDir: workDir
            )
        let driveFolder = devices.driveFolder
        let needsDriveScan = !isMac
            && validExternalImg == nil
            && syncCandidates.isEmpty
            && initialInspection.path == .pathB
            && !driveFolder.isEmpty

        if needsAdopt || needsDriveScan {
            let runner = self.runner
            let adoptEnv = ["PATH": BuildCommands.toolPath(python: py), "HOME": self.home]
                .merging(BundledTools.environment(for: py)) { $1 }
            let prepGeneration = archiveGeneration
            let immutableBaseArgs = args
            let immutableEnvURL = tempEnvURL
            effectiveWorkDir = workDir
            installPhaseActive = true
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                var inspection = initialInspection
                if needsAdopt {
                    var adoptArgs = [adoptTool, "adopt", "--seed-cache-dir", seedRoot, "--title-id", tid, "--work-dir", workDir]
                    if let app = existingMacAppPath, FileManager.default.fileExists(atPath: app) {
                        adoptArgs += ["--app-path", app]
                    }
                    let adoptCandidates = BuildSeedCache.prefillCandidates(
                        titleID: tid,
                        outDir: resolvedOutDir,
                        gameName: gameName,
                        macAppPath: existingMacAppPath,
                        workDir: workDir
                    )
                    let imgCandidate = adoptCandidates.first { $0.hasSuffix(".img") && !$0.contains(".app") }
                        ?? validExternalImg
                        ?? (resolvedOutDir + "/games/" + tid + "/romfs.img")
                    if FileManager.default.fileExists(atPath: imgCandidate) {
                        adoptArgs += ["--img-path", imgCandidate]
                    }
                    _ = runner.runCaptured([py] + adoptArgs, env: adoptEnv) { _ in }
                    inspection = BuildSeedCache.inspect(titleID: tid, seedRoot: seedRoot, repoPath: repoPath)
                }

                let finalCandidates = needsAdopt
                    ? BuildSeedCache.prefillCandidates(
                        titleID: tid,
                        outDir: resolvedOutDir,
                        gameName: gameName,
                        macAppPath: prefillMacAppPath,
                        workDir: workDir
                    )
                    : syncCandidates

                var matchedDriveImg: String?
                if !isMac,
                   validExternalImg == nil,
                   finalCandidates.isEmpty,
                   inspection.path == .pathB,
                   !driveFolder.isEmpty {
                    matchedDriveImg = RomfsImageIdentity.scanExternalDriveForMatchingImage(
                        driveFolder: driveFolder,
                        titleID: tid,
                        expectedIdentity: inspection.record?.romfsIdentity
                    )
                }

                hop {
                    guard let self else {
                        if let immutableEnvURL { try? FileManager.default.removeItem(at: immutableEnvURL) }
                        return
                    }
                    guard self.archiveGeneration == prepGeneration else {
                        if let immutableEnvURL { try? FileManager.default.removeItem(at: immutableEnvURL) }
                        return
                    }
                    self.installPhaseActive = false
                    if self.stopping {
                        if let immutableEnvURL { try? FileManager.default.removeItem(at: immutableEnvURL) }
                        self.clearFastRefreshContext()
                        self.stopping = false
                        self.running = false
                        self.resetProgress()
                        self.doneNote = self.t("msg.stopped")
                        self.cleanupStaging()
                        return
                    }
                    var launchArgs = immutableBaseArgs
                    for cand in finalCandidates {
                        launchArgs += ["--prefill-msl", cand]
                    }
                    if !isMac {
                        if let extImg = validExternalImg {
                            self.fastRefreshExternalImgPath = extImg
                            if !finalCandidates.contains(extImg) {
                                launchArgs += ["--prefill-msl", extImg]
                            }
                        } else if let driveImg = matchedDriveImg {
                            self.fastRefreshExternalImgPath = driveImg
                            if !finalCandidates.contains(driveImg) {
                                launchArgs += ["--prefill-msl", driveImg]
                            }
                            self.say(String(format: self.t("imgGuide.driveReused"), (driveImg as NSString).lastPathComponent))
                        }
                    }
                    self.launchFastRefreshProcess(
                        py: py,
                        args: launchArgs,
                        engine: engine,
                        workDir: workDir,
                        macOutput: macOutput,
                        tempEnvURL: immutableEnvURL
                    )
                }
            }
            return
        }

        for cand in syncCandidates {
            args += ["--prefill-msl", cand]
        }
        if !isMac, let extImg = validExternalImg {
            fastRefreshExternalImgPath = extImg
            if !syncCandidates.contains(extImg) {
                args += ["--prefill-msl", extImg]
            }
        }

        launchFastRefreshProcess(
            py: py,
            args: args,
            engine: engine,
            workDir: workDir,
            macOutput: macOutput,
            tempEnvURL: tempEnvURL
        )
    }

    private func launchFastRefreshProcess(
        py: String,
        args: [String],
        engine: String,
        workDir: String,
        macOutput: MacAppOutput?,
        tempEnvURL: URL?
    ) {
        effectiveWorkDir = workDir
        say(String(format: t("msg.running"), py) + " " + args.joined(separator: " "))
        lastBuildCommand = [py] + args

        var denv = toolEnvironment(python: py)
        if !oneGameIPAPath.isEmpty { denv.merge(OneGameIPA.environment) { $1 } }
        let launch = ProcessLaunch(executable: py, arguments: args, environment: denv, directory: engine, groupPython: py)
        let envCleanup = tempEnvURL
        let utf8 = UTF8StreamDecoder.Locked()

        let onExit: @Sendable (Int32) -> Void = { [weak self] status in
            if let envCleanup { try? FileManager.default.removeItem(at: envCleanup) }
            hop {
                guard let self else { return }
                let name = self.gameName
                let tail = utf8.finish()
                if !tail.isEmpty { self.ingest(tail) }
                self.flushLines()
                if status == 0, !self.stopping, let macOutput {
                    self.clearFastRefreshContext()
                    self.markAllDone()
                    self.finishMacApp(macOutput)
                    return
                }
                self.running = false
                if self.stopping {
                    self.clearFastRefreshContext()
                    self.stopping = false
                    self.resetProgress()
                    self.doneNote = self.t("msg.stopped")
                    self.cleanupStaging()
                    return
                }
                if status == 0 {
                    self.markAllDone()
                    if !self.oneGameIPAPath.isEmpty {
                        self.clearFastRefreshContext()
                        self.finishOneGameIPA()
                    } else {
                        let key = self.buildKey
                        let fw = ShellInstall.builtFramework(workDir: self.effectiveWorkDir)
                            ?? ShellInstall.frameworkPath(workDir: self.effectiveWorkDir, titleID: key)
                        let outTID = ShellInstall.titleID(ofFramework: fw)
                        self.packArchive(workDir: self.effectiveWorkDir, titleID: outTID) { archive in
                            if self.deferShellPackaging {
                                self.deferShellPackage(framework: fw, titleID: outTID, name: name, archive: archive)
                            } else if self.exportsShell {
                                self.exportShell(framework: fw, titleID: outTID, name: name)
                            } else {
                                self.installShell(framework: fw, titleID: outTID, name: name, archive: archive)
                            }
                        }
                        self.clearFastRefreshContext()
                    }
                } else {
                    self.clearFastRefreshContext()
                    if let i = self.stages.lastIndex(where: { $0.state == .running }) {
                        self.stages[i].state = .failed
                        self.stages[i].detail = String(format: self.t("msg.exitCode"), status)
                        self.noteFailure()
                    } else {
                        self.doneNote = String(format: self.t("msg.buildFailed"), status)
                        if let last = BuildProgress.lastMeaningfulLine(self.logTail) {
                            self.doneNote = String(format: self.t("msg.buildFailedReason"), last)
                        }
                        self.noteFailure()
                    }
                    self.cleanupStaging()
                }
            }
        }

        do {
            proc = try runner.start(launch, onOutput: { @Sendable [weak self] d in
                hop {
                    guard let self else { return }
                    let s = utf8.decode(d)
                    if !s.isEmpty { self.ingest(s) }
                }
            }, onExit: onExit)
        } catch {
            if let envCleanup { try? FileManager.default.removeItem(at: envCleanup) }
            clearFastRefreshContext()
            fail(String(format: t("msg.launchFailed"), error.localizedDescription))
        }
    }
}
