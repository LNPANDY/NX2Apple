import Foundation
@preconcurrency import NXCore

extension BuildStore {
    /// Renew the shared app's signature (a free Apple ID's profile lasts 7 days). The same xcodebuild parameters as
    /// the install, run on the cached project and derived data: Xcode reuses the compiled products and only signs
    /// again, then devicectl installs the app over itself. PRODUCT_BUNDLE_IDENTIFIER is the one shell.json holds, so the
    /// device keeps the app's Documents (game data, saves).
    package func resignOnDevice(app: String, device: String, then: (() -> Void)? = nil) {
        installedOn = ""
        guard !device.isEmpty, !app.isEmpty else { then?(); return }
        guard !devices.signingTeam.isEmpty else {
            doneNote = t("dev.resignNoTeam")
            then?(); return
        }
        // An app from before the shared app has its own project and cannot be signed again here: build the game again
        guard let shell = ShellInstall.paths(ofApp: app) else {
            doneNote = t("dev.resignOlder")
            then?(); return
        }
        guard FileManager.default.fileExists(atPath: shell.project) else {
            doneNote = String(format: t("dev.resignNoProject"), shortPath(shell.project))
            then?(); return
        }
        let xcrun = devices.xcrun, team = devices.signingTeam, name = devices.deviceName(device)
        let loaded = ShellLibrary.load(root: shell.root)
        var library = loaded
        library.dropMissing()
        library.games.removeAll { ShellInstall.missingFile(inFramework: $0.framework, titleID: $0.titleID) != nil }
        if library != loaded { try? library.save(root: shell.root) }
        ShellInstall.pruneEmbeddedFrameworks(root: shell.root, keeping: library.games)
        let needsProjectUpdate = ShellInstall.projectNeedsUpdate(root: shell.root, games: library.games)
        if needsProjectUpdate, library.games.isEmpty {
            doneNote = String(format: t("dev.resignNoProject"), shortPath(shell.project))
            then?(); return
        }
        let bundle = library.bundleID
        let resources = Bundle.main.resourceURL?.path, repoPath = repo.path, home = self.home, runner = self.runner
        let expectedChain = ShellHotInstall.expectedChain(resources: resources, repo: repoPath)
        let stampMatches = ShellHotInstall.projectStampMatches(root: shell.root, expectedChain: expectedChain)
        buildingGame = false; runningTarget = BuildTarget.ios
        beginOperation(.renewingSignature, game: nil, titleID: nil, destination: .device(name))
        setInstallRecovery(.resign(app: app, device: device, then: then))
        stopping = false; stoppedByPlayer = false; installPhaseActive = true
        needsReplaceOldImgReminder = false; updatedImgPath = ""; shellUpdatedOnDevice = false
        failure = nil; done = false; doneNote = ""
        running = true
        // The shared app is signed again under the identifier shell.json holds, so the device keeps its Documents
        let command = ShellInstall.buildCommand(xcrun: xcrun, root: shell.root, device: device, team: team, bundleID: bundle)
        let signAndInstall: (Bool) -> Void = { shellUpgraded in
            DispatchQueue.global(qos: .userInitiated).async {
                ShellInstall.refreshProjectLinks(root: shell.root, resources: resources, repo: repoPath)
                let stagedProfiles = AppSignature.stageProfilesForResign(
                    app: app, bundleID: bundle, team: team, home: home, runner: runner
                )
                hop {
                    self.installPhaseActive = false
                    if self.stopping {
                        self.stopping = false
                        stagedProfiles.rollback()
                        self.failure = nil; self.clearInstallRecovery(includeFastRefresh: true)
                        self.running = false
                        self.doneNote = self.t("msg.stopped")
                        then?(); return
                    }
                    self.stagedResignProfiles = stagedProfiles
                    self.runTool(id: 1006, name: String(format: self.t("dev.resignStage"), name),
                                 command, nameKey: "dev.resignStage", nameArgument: name, step: BuildProgress.xcodeStep) { error in
                        if let error, !error.isEmpty {
                            stagedProfiles.rollback()
                            self.stagedResignProfiles = nil
                            self.doneNote = String(format: self.t("dev.resignFailed"), error)
                            self.noteInstallFailure(.sign, error: error)
                            self.running = false
                            then?(); return
                        }
                        stagedProfiles.commit()
                        self.stagedResignProfiles = nil
                        self.runTool(id: 1007, name: String(format: self.t("dev.installStage"), name),
                                     BuildCommands.reinstallCommand(xcrun: xcrun, device: device, app: app), nameKey: "dev.installStage",
                                     nameArgument: name, step: BuildProgress.installStep) { installError in
                            if let installError {
                                self.doneNote = String(format: self.t("dev.installFailed"), installError)
                                self.noteInstallFailure(.install, error: installError)
                            } else {
                                ShellLibrary.recordInstalled(root: shell.root, device: device)
                                self.installedOn = device
                                self.installedAppPath = app
                                self.shellUpdatedOnDevice = shellUpgraded
                                let base = String(format: self.t("dev.resigned"), name)
                                self.doneNote = shellUpgraded ? base + "\n" + self.t("shell.updatedShell") : base
                            }
                            self.running = false
                            then?()
                        }
                    }
                }
            }
        }
        let engineRoot = EngineLayout.root(repoPath)
        let python = resolveBuildPython()
        let toolPath = BuildCommands.toolPath("/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin", python: python)
        let extraEnv = BundledTools.environment(for: python).merging(seedEnvironment) { $1 }
        let gamesForResign = library.games
        DispatchQueue.global(qos: .userInitiated).async {
            var deviceShellIncompatible = false
            var mismatchDetail = ""
            if !gamesForResign.isEmpty, !bundle.isEmpty {
                let beaconFile = NSTemporaryDirectory() + "nspb-resign-beacon-\(UUID().uuidString.prefix(8)).json"
                defer { try? FileManager.default.removeItem(atPath: beaconFile) }
                let cmd = ShellHotInstall.beaconCommand(xcrun: xcrun, device: device, bundleID: bundle, destination: beaconFile)
                let fetched = runner.capture(ProcessLaunch(executable: cmd[0], arguments: Array(cmd.dropFirst()), mergesErrors: true))
                let data = fetched.status == 0 ? FileManager.default.contents(atPath: beaconFile) : nil
                if case .incompatible(let detail) = ShellHotInstall.evaluateBeacon(
                    data, expectedBundleID: bundle, team: team,
                    nowEpoch: Int64(Date().timeIntervalSince1970), expectedChain: expectedChain
                ) {
                    deviceShellIncompatible = true
                    mismatchDetail = detail
                }
            }
            let regenerateProject = !gamesForResign.isEmpty && (needsProjectUpdate || !stampMatches || deviceShellIncompatible)
            let shellUpgraded = !gamesForResign.isEmpty && (!stampMatches || deviceShellIncompatible)
            hop {
                if !mismatchDetail.isEmpty {
                    self.append("resign: host beacon mismatch (\(mismatchDetail)), updating shared shell\n")
                }
                if self.stopping {
                    self.installPhaseActive = false
                    self.stopping = false
                    self.failure = nil; self.clearInstallRecovery(includeFastRefresh: true)
                    self.running = false
                    self.doneNote = self.t("msg.stopped")
                    then?(); return
                }
                guard regenerateProject else {
                    signAndInstall(shellUpgraded)
                    return
                }
                guard let package = ShellInstall.shellPackage(resources: resources, repo: repoPath) else {
                    let looked = ([resources, repoPath].compactMap { $0 }.filter { !$0.isEmpty }).map { $0 + "/frontend-ios" }.joined(separator: ", ")
                    self.installPhaseActive = false
                    self.running = false
                    self.doneNote = String(format: self.t("shell.projectFailed"), "no frontend-ios Swift package (Package.swift) in " + looked)
                    then?(); return
                }
                var env = ShellInstall.projectEnvironment(root: shell.root, frameworks: gamesForResign.map(\.framework), bundleID: bundle,
                                                          team: team, python: python, path: toolPath, home: NSHomeDirectory(), user: NSUserName(),
                                                          tmp: NSTemporaryDirectory(), package: package, engine: engineRoot)
                env.merge(extraEnv) { $1 }
                let xcconfig = shell.root + "/project/Gen/dm.xcconfig"
                if (try? String(contentsOfFile: xcconfig, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true
                    || FileManager.default.fileExists(atPath: shell.root + "/project/entitlements-empty") {
                    env["DM_ENTITLEMENTS"] = ""
                }
                self.runTool(id: ShellInstaller.projectStageID, name: self.t("shell.projectStage"),
                             ShellInstall.projectCommand(package: package), environment: env, nameKey: "shell.projectStage", step: { _ in nil }) { projectError in
                    if let projectError, !projectError.isEmpty {
                        self.installPhaseActive = false
                        self.running = false
                        self.doneNote = String(format: self.t("shell.projectFailed"), projectError)
                        then?(); return
                    }
                    ShellInstall.writeProjectFrameworks(root: shell.root, games: gamesForResign)
                    ShellHotInstall.writeProjectStamp(root: shell.root, resources: resources, repo: repoPath)
                    signAndInstall(shellUpgraded)
                }
            }
        }
    }
}
