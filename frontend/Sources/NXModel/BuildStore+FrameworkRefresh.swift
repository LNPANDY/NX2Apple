import Foundation
import NXCore

extension BuildStore {
    /// True when the current iOS target can refresh an already-built game framework from cached ExeFS, shaders,
    /// and a local `romfs.img` without needing the original Switch packages or decryption keys.
    package var canRefreshCurrentIOSFramework: Bool {
        guard target != BuildTarget.mac, !exportsOneGame, !repo.path.isEmpty, gameFolder == nil else { return false }
        guard !refreshInputsDifferFromCandidate else { return false }
        for titleID in refreshTitleIDCandidates {
            let workDirs = refreshWorkDirs(for: titleID)
            let romfs = FrameworkRefresh.romfsCandidates(
                archivePath: refreshCandidate?.archivePath ?? "",
                outDir: outDir,
                inputFolder: inputFolder,
                titleID: titleID,
                workDirs: workDirs
            )
            if FrameworkRefresh.canAttempt(workDirs: workDirs, romfsCandidates: romfs, repo: repo.path, titleID: titleID) {
                return true
            }
        }
        return false
    }

    /// Evaluates whether `runBuild()` should run the fast framework-refresh path instead of a full package build.
    /// Returns `nil` to fall back to the standard full build pipeline.
    func shouldPreferFrameworkRefresh() -> FrameworkRefresh.Status? {
        guard target != BuildTarget.mac, !exportsOneGame, !repo.path.isEmpty, gameFolder == nil else { return nil }
        let modifiedInputs = refreshInputsDifferFromCandidate
        if inputsReady && (refreshCandidate == nil || modifiedInputs) { return nil }
        for titleID in refreshTitleIDCandidates {
            let workDirs = refreshWorkDirs(for: titleID)
            let romfs = FrameworkRefresh.romfsCandidates(
                archivePath: refreshCandidate?.archivePath ?? "",
                outDir: outDir,
                inputFolder: inputFolder,
                titleID: titleID,
                workDirs: workDirs
            )
            let fallbackArchive = (outDir.isEmpty ? inputFolder : outDir) + "/games/" + titleID
            let status = FrameworkRefresh.inspect(
                workDirs: workDirs,
                romfsCandidates: romfs,
                fallbackArchiveDir: fallbackArchive,
                repo: repo.path,
                titleID: titleID
            )
            switch status {
            case .ready:
                return status
            case .shadersStale:
                return inputsReady ? nil : status
            case .unavailable:
                continue
            }
        }
        return nil
    }

    /// Runs incremental NSO rewrite (when needed) and `build_ipa.sh` (`DM_FRAMEWORK_ONLY`), then finishes into the shell
    /// install, IPA export, or deferred batch queue without re-packing `romfs.img`.
    func runFrameworkRefresh(plan: FrameworkRefresh.Plan, allowFallbackToFullBuild: Bool = true) {
        stopping = false; stoppedByPlayer = false; archiveGeneration &+= 1
        buildingGame = true; runningTarget = BuildTarget.ios
        let displayName = refreshDisplayName(fallbackTitleID: plan.titleID)
        beginOperation(.building, game: displayName, titleID: plan.titleID, destination: .target)
        running = true; done = false; doneNote = ""; stages = []; log.clear(); staleShadersMessageKey = nil
        failure = nil; confirmingOverride = nil
        installedOn = ""; installedAppPath = ""; exportedIPAPath = ""; send = .idle

        guard repo.isRepo else {
            fail(repo.path.isEmpty ? t("msg.repoInvalidEmpty") : String(format: t("msg.repoInvalid"), shortPath(repo.path)))
            return
        }
        let py = deps.pythonPath.isEmpty ? Toolchain.findPython().path : deps.pythonPath
        if EngineLayout.needsSyncBeforeBuild(repo.path) {
            _ = engine.syncEngine { ok in
                self.running = false
                if ok && !EngineLayout.needsSyncBeforeBuild(self.repo.path) {
                    self.runBuild(allowFrameworkRefresh: true)
                } else {
                    self.fail(String(format: self.t("msg.toolsOld"), "engine/ (python3 tools/engine.py sync, see the log)"))
                }
            }
            return
        }
        let missing = RepoLayout.missingTools(in: repo.path)
        if !missing.isEmpty {
            fail(String(format: t("msg.toolsOld"), missing.joined(separator: ", ")))
            return
        }
        if cloudFolderCheck(plan.workDir) {
            failure = BuildFailure(kind: .cloudFolder, gameName: nil, detail: plan.workDir)
            fail(failureWhat(failure!))
            return
        }
        if let why = shellRootProblem() { fail(why); return }

        effectiveWorkDir = plan.workDir
        let team = exportsShell ? "" : devices.signingTeam
        var tempEnvURL: URL?
        let envURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nspb-env-\(UUID().uuidString).txt")
        do {
            try GameMenuText.envFile(bcOnCPU: bcOnCPU, t).write(to: envURL, atomically: true, encoding: .utf8)
            tempEnvURL = envURL
            if bcOnCPU { say(t("msg.bcOn")) }
        } catch {
            say(String(format: t("msg.bcEnvFailed"), error.localizedDescription))
        }

        let denv = toolEnvironment(python: py)
        let launch = FrameworkRefresh.makeLaunch(
            plan: plan,
            repo: repo.path,
            python: py,
            teamID: team,
            fallbackName: displayName,
            envFile: tempEnvURL?.path,
            environment: denv
        )
        say(String(format: t("msg.running"), py) + " (framework refresh) " + plan.workDir)
        lastBuildCommand = [launch.executable] + launch.arguments

        let envCleanup = tempEnvURL
        let utf8 = UTF8StreamDecoder.Locked()
        let onExit: @Sendable (Int32) -> Void = { [weak self] status in
            if let envCleanup { try? FileManager.default.removeItem(at: envCleanup) }
            hop {
                guard let self else { return }
                let tail = utf8.finish()
                if !tail.isEmpty { self.ingest(tail) }
                self.flushLines()
                self.running = false
                if self.stopping {
                    self.stopping = false
                    self.resetProgress()
                    self.doneNote = self.t("msg.stopped")
                    self.cleanupStaging()
                    return
                }
                if status == FrameworkRefresh.staleExitCode {
                    if allowFallbackToFullBuild && self.inputsReady {
                        self.resetProgress()
                        self.done = false
                        self.doneNote = ""
                        self.cleanupStaging()
                        self.runBuild(allowFrameworkRefresh: false)
                    } else {
                        self.fail(self.t("msg.refreshShadersStale"))
                    }
                    return
                }
                guard status == 0 else {
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
                    return
                }
                self.finishFrameworkRefresh(plan: plan, displayName: displayName)
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
            fail(String(format: t("msg.launchFailed"), error.localizedDescription))
        }
    }

    private func finishFrameworkRefresh(plan: FrameworkRefresh.Plan, displayName: String) {
        let generation = archiveGeneration
        let workDir = plan.workDir
        let romfsPath = plan.romfsPath
        let archiveDir = plan.archiveDir
        let fallbackTID = plan.titleID
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let fw = ShellInstall.builtFramework(workDir: workDir)
                ?? ShellInstall.frameworkPath(workDir: workDir, titleID: fallbackTID)
            let tid = {
                let parsed = ShellInstall.titleID(ofFramework: fw)
                return parsed.isEmpty ? fallbackTID : parsed
            }()
            let destImg = archiveDir + "/romfs.img"
            if URL(fileURLWithPath: romfsPath).standardizedFileURL.path != URL(fileURLWithPath: destImg).standardizedFileURL.path {
                _ = try? PostBuildCleanup.placeImage(from: romfsPath, to: destImg)
            }
            RomFSLanguages.applyToLauncherJSON(at: fw + "/dm/launcher.json", romfs: archiveDir)
            PostBuildCleanup.cleanWorkDirectory(workDir, removeExtractedRomFS: false, removeShellFramework: false)
            hop {
                guard let self, self.archiveGeneration == generation else { return }
                if self.stopping {
                    self.stopping = false
                    self.running = false
                    self.resetProgress()
                    self.doneNote = self.t("msg.stopped")
                    self.cleanupStaging()
                    return
                }
                self.markAllDone()
                self.archivePath = archiveDir
                if self.deferShellPackaging {
                    self.deferShellPackage(framework: fw, titleID: tid, name: displayName, archive: archiveDir)
                } else if self.exportsShell {
                    self.exportShell(framework: fw, titleID: tid, name: displayName)
                } else {
                    self.installShell(framework: fw, titleID: tid, name: displayName, archive: archiveDir)
                }
            }
        }
    }

    // MARK: - Candidate helpers

    private var refreshInputsDifferFromCandidate: Bool {
        guard let cand = refreshCandidate else { return false }
        let sameBase = basePath.isEmpty || cand.recordedBase.isEmpty
            || URL(fileURLWithPath: basePath).standardizedFileURL.path == URL(fileURLWithPath: cand.recordedBase).standardizedFileURL.path
        if !sameBase { return true }
        if !cand.recordedBase.isEmpty {
            if updatePath != cand.recordedUpdate || dlcPaths != cand.recordedDLC { return true }
        }
        return false
    }

    private var refreshTitleIDCandidates: [String] {
        var raw: [String] = []
        if let cand = refreshCandidate?.titleID, !cand.isEmpty { raw.append(cand.uppercased()) }
        if let selected = selectedTitleID, !selected.isEmpty { raw.append(selected.uppercased()) }
        if let tid = gameTitleID, !tid.isEmpty { raw.append(tid.uppercased()) }
        var seen = Set<String>()
        return raw.filter { $0.count == 16 && $0.allSatisfy(\.isHexDigit) && seen.insert($0).inserted }
    }

    private func refreshWorkDirs(for titleID: String) -> [String] {
        var bases: [String] = []
        if !outDir.isEmpty { bases.append(outDir) }
        if let archive = refreshCandidate?.archivePath, !archive.isEmpty {
            let parent = (archive as NSString).deletingLastPathComponent
            if (parent as NSString).lastPathComponent.lowercased() == "games" {
                bases.append((parent as NSString).deletingLastPathComponent)
            }
        }
        let dir = inputFolder
        if !dir.isEmpty { bases.append(dir) }

        var dirs: [String] = []
        if !effectiveWorkDir.isEmpty { dirs.append(effectiveWorkDir) }
        for base in bases where !base.isEmpty {
            dirs.append(base + "/" + titleID.uppercased() + "_build")
            dirs.append(base + "/" + titleID.lowercased() + "_build")
        }
        return dirs
    }

    private func refreshDisplayName(fallbackTitleID: String) -> String {
        if let name = refreshCandidate?.name, !name.isEmpty { return name }
        if !basePath.isEmpty { return gameName }
        return fallbackTitleID
    }
}
