import Foundation
import Combine
import NXCore

extension BuildStore {
    private func clearFastRefreshContext() {
        fastRefreshActive = false
        fastRefreshTitleID = nil
        fastRefreshBaseDir = nil
        fastRefreshGameName = nil
    }

    /// Starts a fast refresh build (PR #3) from a build seed without requiring NSPs or keys.
    package func startFastRefresh(
        titleID: String,
        target: Int,
        outDir: String? = nil,
        gameName: String? = nil,
        existingMacAppPath: String? = nil
    ) {
        startFastRefresh(
            titleID: titleID,
            targetName: target == 0 ? BuildTarget.mac : BuildTarget.ios,
            outDir: outDir,
            gameName: gameName,
            existingMacAppPath: existingMacAppPath
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
            existingMacAppPath: existingMacAppPath
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
            existingMacAppPath: existingMacAppPath
        )
    }

    /// Starts a fast refresh build using a named build target ("mac-app" or "ios").
    package func startFastRefresh(
        titleID: String,
        targetName: String,
        outDir: String? = nil,
        gameName: String? = nil,
        existingMacAppPath: String? = nil
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

        // If seed is missing or incomplete, attempt automatic adoption from legacy workDir if present
        let inspection = BuildSeedCache.inspect(titleID: tid, seedRoot: seedRoot, repoPath: repo.path)
        if !inspection.isUsable {
            let engine = EngineLayout.root(repo.path)
            let adoptTool = engine + "/" + RepoLayout.buildSeedTool
            if FileManager.default.fileExists(atPath: adoptTool) && FileManager.default.fileExists(atPath: workDir) {
                var adoptArgs = [adoptTool, "adopt", "--seed-cache-dir", seedRoot, "--title-id", tid, "--work-dir", workDir]
                if let app = existingMacAppPath, FileManager.default.fileExists(atPath: app) {
                    adoptArgs += ["--app-path", app]
                }
                let candidates = BuildSeedCache.prefillCandidates(
                    titleID: tid,
                    outDir: resolvedOutDir,
                    gameName: gameName,
                    macAppPath: existingMacAppPath,
                    workDir: workDir
                )
                let imgCandidate = candidates.first { $0.hasSuffix(".img") && !$0.contains(".app") }
                    ?? (resolvedOutDir + "/games/" + tid + "/romfs.img")
                if FileManager.default.fileExists(atPath: imgCandidate) {
                    adoptArgs += ["--img-path", imgCandidate]
                }
                let env = ["PATH": BuildCommands.toolPath(python: py), "HOME": self.home]
                    .merging(BundledTools.environment(for: py)) { $1 }
                _ = runner.runCaptured([py] + adoptArgs, env: env) { _ in }
            }
        }

        // Configure store state for fast refresh
        fastRefreshActive = true
        fastRefreshTitleID = tid
        fastRefreshBaseDir = resolvedOutDir
        fastRefreshGameName = (gameName?.isEmpty == false) ? gameName : nil
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
                self?.startFastRefresh(titleID: tid, targetName: targetName, outDir: outDir, gameName: gameName, existingMacAppPath: existingMacAppPath)
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

        // Prefill candidates for Path B or Mac/iOS image
        let candidates = BuildSeedCache.prefillCandidates(
            titleID: tid,
            outDir: resolvedOutDir,
            gameName: gameName,
            macAppPath: existingMacAppPath ?? macAppPath,
            workDir: workDir
        )
        for cand in candidates {
            args += ["--prefill-msl", cand]
        }

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
