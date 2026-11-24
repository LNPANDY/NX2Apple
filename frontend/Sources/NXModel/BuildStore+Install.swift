import Foundation
import Combine
import NXCore

// The install on a device after the archive: the shared app, the reinstall, the re-sign and the IPA (LNPANDY/NX2Apple#387).

/// What the build reads from the device store: the device and the team to install on, the names, the listing of the teams, and the
/// copy flow the install blocks on (its queue is not the main one, so those members are `nonisolated`).
@MainActor package protocol InstallTarget: AnyObject {
    var installDevice: String { get }
    /// The paired devices the last listing found.
    var devices: [AppleDevice] { get }
    /// The signing teams the last listing found.
    var teams: [SigningTeam] { get }
    /// Whether the device/team listing has run at least once.
    var checked: Bool { get }
    var signingTeam: String { get }
    /// The build exports the shared app as an IPA instead of installing it.
    var exportIPA: Bool { get }
    /// The export makes one game's own IPA with its game data inside (#540).
    var exportOneGame: Bool { get }
    /// The export makes a standalone `.framework` for the shared app without repacking the shell IPA.
    var exportFramework: Bool { get }
    /// Standalone `.framework` export explicitly skips codesigning (for sideloading / on-device signing).
    var exportFrameworkUnsigned: Bool { get }
    /// The folder the game data is copied to (a drive), empty when none is chosen.
    var driveFolder: String { get set }
    var xcrun: String { get }
    var readTeams: @Sendable () -> [SigningTeam] { get }
    var usbSpeedLookup: @Sendable (String) -> Int64? { get }
    nonisolated var currentPostBuildTransferMode: PostBuildTransferMode { get }
    func deviceName(_ udid: String) -> String
    nonisolated func askCopy(_ plan: ShellCopyPlan) -> ShellCopyDecision
    nonisolated func askCopy(_ plan: ShellCopyPlan, isCancelled: @escaping @Sendable () -> Bool) -> ShellCopyDecision
    nonisolated func setWaiting(_ on: Bool)
    nonisolated var waitCancelled: Bool { get }
    func cancelCopy()
    func copyEnded()
    /// Reads the device listing again (a transfer asks it when a send failed, to tell a device that went away from a refusal).
    func refreshDevices() async
}

extension InstallTarget {
    package var teams: [SigningTeam] { [] }
    package var checked: Bool { false }
    package var exportFramework: Bool { false }
    package var exportFrameworkUnsigned: Bool { false }
    /// Single source of truth for the team used by standalone `.framework` export and displayed in `InstallCard`.
    /// Empty means export unsigned.
    package var effectiveFrameworkSigningTeam: String {
        if exportFrameworkUnsigned { return "" }
        let explicit = signingTeam.trimmingCharacters(in: .whitespacesAndNewlines)
        if !teams.isEmpty {
            if !explicit.isEmpty, teams.contains(where: { $0.id == explicit }) {
                return explicit
            }
            return teams.first(where: { $0.hasCertificate })?.id ?? teams.first?.id ?? ""
        }
        return checked ? "" : explicit
    }
    package var usbSpeedLookup: @Sendable (String) -> Int64? { { _ in nil } }
    nonisolated package var currentPostBuildTransferMode: PostBuildTransferMode { .defaultMode }
    nonisolated package func askCopy(_ plan: ShellCopyPlan, isCancelled: @escaping @Sendable () -> Bool) -> ShellCopyDecision {
        isCancelled() ? .skip : askCopy(plan)
    }
    package func cancelCopy() {}
    package func refreshDevices() async {}
}

extension DeviceStore: InstallTarget {
    package func refreshDevices() async { await refresh().value }
}

extension BuildStore {
    // MARK: Installing on a device

    /// The installer with this store's tools, log, stages and process hand-off wired in. The install and the export (BuildStore+Export.swift) share it.
    func makeInstaller(respectSkipMode: Bool = true) -> ShellInstaller {
        let python = resolveBuildPython()
        var installer = ShellInstaller(xcrun: devices.xcrun, repo: repo.path, python: python, root: shellRoot, device: devices.installDevice, team: devices.signingTeam)
        installer.deviceName = devices.deviceName(devices.installDevice)
        installer.defaults = defaults
        installer.lang = localizer.lang
        installer.ownGroup = true
        installer.toolPath = BuildCommands.toolPath("/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin", python: python)
        installer.log = { @Sendable s in hop { self.append(s) } }
        installer.stage = { @Sendable s in hop {
            let nameKey: String? = switch s.id {
            case ShellInstaller.projectStageID: "shell.projectStage"
            case ShellInstaller.signStageID: "dev.signStage"
            case ShellInstaller.installStageID: "dev.installStage"
            case ShellInstaller.copyStageID: "dev.copyStage"
            case ShellInstaller.checkStageID: "shell.checkStage"
            case ShellInstaller.exportBuildStageID: "shell.exportBuildStage"
            case ShellInstaller.exportPackStageID: "shell.exportPackStage"
            default: nil
            }
            let usesDeviceArg = s.id == ShellInstaller.signStageID || s.id == ShellInstaller.installStageID
                || s.id == ShellInstaller.copyStageID || s.id == ShellInstaller.checkStageID
            let nameArgument = usesDeviceArg ? self.devices.deviceName(self.devices.installDevice) : nil
            if let i = self.stages.firstIndex(where: { $0.id == s.id }) {
                self.stages[i].name = s.name; self.stages[i].state = s.state; self.stages[i].detail = s.detail
                self.stages[i].nameKey = nameKey; self.stages[i].nameArgument = nameKey == nil ? nil : nameArgument
                if let percent = s.percent { self.stages[i].percent = percent }
                if s.state == .running, self.stages[i].started == nil { self.stages[i].started = Date() }
            } else {
                self.stages.append(Stage(id: s.id, name: s.name, state: s.state, detail: s.detail, percent: s.percent,
                                         started: s.state == .running ? Date() : nil, nameKey: nameKey,
                                         nameArgument: nameKey == nil ? nil : nameArgument))
            }
            self.refreshOverallProgress(parsedTotal: nil)
        } }
        installer.runner = runner
        installer.processStarted = { @Sendable p in hop { self.proc = p } }
        // The size and the connection are shown with Start, "Wait for a cable" and "Not now" (ShellCopySheet)
        let target = devices
        let cancel = installCancel
        installer.usbSpeedLookup = target.usbSpeedLookup
        installer.decideCopy = { plan in
            if cancel.value { return .skip }
            let prompt: () -> ShellCopyDecision = {
                target.askCopy(plan, isCancelled: { cancel.value })
            }
            switch target.currentPostBuildTransferMode {
            case .skip:
                return respectSkipMode ? .skip : prompt()
            case .auto:
                return plan.linkProfile.isConnected ? .copy : prompt()
            case .ask:
                return prompt()
            }
        }
        installer.waiting = { on in if !cancel.value || !on { target.setWaiting(on) } }
        installer.waitCancelled = { cancel.value || target.waitCancelled }
        return installer
    }

    /// Steps 4 to 7 of the shared app (ShellInstall.swift) for a game whose framework is built and whose archive is packed: the
    /// shell's project, signing, the install over the app that is already there, and the game data the device lacks.
    package func installShell(
        framework: String,
        titleID: String,
        name: String,
        archive: String,
        dataOnly: Bool = false,
        didUpdateImg: Bool? = nil,
        updatedImgPath: String? = nil
    ) {
        buildingGame = true
        runningTarget = BuildTarget.ios
        beginOperation(dataOnly ? .sendingGameData : .installing, game: name, titleID: titleID, destination: .target)
        stopping = false; installCancel.set(false); installPhaseActive = true
        if dataOnly { stoppedByPlayer = false }
        running = true
        finderShown = false
        if dataOnly { failure = nil; done = false; doneNote = ""; shellUpdatedOnDevice = false }
        else { shellUpdatedOnDevice = false }
        shellBatchRetry = nil
        shellRetry = (framework, titleID, name, archive)
        let shouldTransferUpdatedImg = didUpdateImg ?? needsReplaceOldImgReminder
        let effectiveImgPath = updatedImgPath ?? self.updatedImgPath
        let targetEntryID = activeQueuedEntryID
        let fastRefresh = lastRunWasFastRefresh ? installRecovery.lastFastRefresh : nil
        setInstallRecovery(.install(
            framework: framework, titleID: titleID, name: name, archive: archive, dataOnly: dataOnly,
            didUpdateImg: shouldTransferUpdatedImg, updatedImgPath: effectiveImgPath, fastRefresh: fastRefresh
        ))
        let installer = makeInstaller(respectSkipMode: !dataOnly && !shouldTransferUpdatedImg)
        let target = devices
        let device = devices.installDevice
        let deviceDisplayName = target.deviceName(device)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = dataOnly ? installer.installData(titleID: titleID, archive: archive)
                                  : installer.install(framework: framework, titleID: titleID, name: name, archive: archive)
            if !dataOnly, result.ok {
                PostBuildCleanup.cleanBuiltFrameworkContainer(framework)
            }
            hop {
                self.installPhaseActive = false
                target.copyEnded()
                if self.stopping {
                    self.stopping = false; self.running = false
                    self.failure = nil; self.clearInstallRecovery(includeFastRefresh: true)
                    self.resetProgress(); self.doneNote = self.t("msg.stopped"); self.cleanupStaging()
                    return
                }
                guard result.ok else {
                    if shouldTransferUpdatedImg {
                        self.needsReplaceOldImgReminder = true
                        self.updatedImgPath = effectiveImgPath
                        self.queue?.updateImgStatus(
                            entryID: targetEntryID,
                            titleID: titleID,
                            imgStatus: .manualReplace(imgPath: effectiveImgPath, reason: result.message)
                        )
                    } else {
                        self.needsReplaceOldImgReminder = false
                        self.updatedImgPath = ""
                        self.queue?.updateImgStatus(entryID: targetEntryID, titleID: titleID, imgStatus: .unchanged)
                    }
                    self.finishInstall(result.message)
                    if let kind = result.failure {
                        let detail = (kind == .appIDLimit && !result.detail.isEmpty) ? result.detail : nil
                        let f = BuildFailure(kind: kind, gameName: nil, detail: detail)
                        self.failure = f
                        if kind == .appIDLimit { self.doneNote = self.failureWhat(f) }
                    } else if let step = result.step { self.noteInstallFailure(step, error: result.message) }
                    return
                }
                if shouldTransferUpdatedImg {
                    if result.copySkipped || archive.isEmpty {
                        self.needsReplaceOldImgReminder = true
                        self.updatedImgPath = effectiveImgPath
                        self.queue?.updateImgStatus(
                            entryID: targetEntryID,
                            titleID: titleID,
                            imgStatus: .manualReplace(imgPath: effectiveImgPath, reason: result.copySkipped ? self.t("dev.copySkipped") : nil)
                        )
                    } else {
                        self.needsReplaceOldImgReminder = false
                        self.updatedImgPath = ""
                        let rawName = effectiveImgPath.isEmpty ? "romfs.img" : (effectiveImgPath as NSString).lastPathComponent
                        self.queue?.updateImgStatus(
                            entryID: targetEntryID,
                            titleID: titleID,
                            imgStatus: .transferred(imgName: rawName, deviceName: deviceDisplayName)
                        )
                    }
                } else {
                    self.needsReplaceOldImgReminder = false
                    self.updatedImgPath = ""
                    self.queue?.updateImgStatus(entryID: targetEntryID, titleID: titleID, imgStatus: .unchanged)
                }
                self.installedOn = device
                self.installedAppPath = result.appPath
                self.shellUpdatedOnDevice = result.shellUpdated
                self.installedDataComplete = !result.copySkipped
                self.finishInstall(nil, note: result.message)
            }
        }
    }

    /// Signs and installs the shared app from the frameworks already built, without rebuilding any game or copying `romfs.img` data.
    package func installBuiltShell(framework: String, titleID: String, name: String) {
        buildingGame = false
        runningTarget = BuildTarget.ios
        beginOperation(.installing, game: nil, titleID: nil, destination: .target)
        stopping = false; stoppedByPlayer = false; installCancel.set(false); installPhaseActive = true
        running = true; done = false; doneNote = ""; failure = nil; stages = []
        needsReplaceOldImgReminder = false; updatedImgPath = ""; shellUpdatedOnDevice = false
        setInstallRecovery(.installBuilt(framework: framework, titleID: titleID, name: name))
        finderShown = false
        let installer = makeInstaller()
        let device = devices.installDevice
        DispatchQueue.global(qos: .userInitiated).async {
            let result = installer.installBuilt(framework: framework, titleID: titleID, name: name)
            hop {
                self.installPhaseActive = false
                if self.stopping {
                    self.stopping = false; self.running = false
                    self.failure = nil; self.clearInstallRecovery(includeFastRefresh: true)
                    self.resetProgress(); self.doneNote = self.t("msg.stopped"); self.cleanupStaging()
                    return
                }
                guard result.ok else {
                    self.finishInstall(result.message)
                    if let kind = result.failure {
                        let detail = (kind == .appIDLimit && !result.detail.isEmpty) ? result.detail : nil
                        let f = BuildFailure(kind: kind, gameName: nil, detail: detail)
                        self.failure = f
                        if kind == .appIDLimit { self.doneNote = self.failureWhat(f) }
                    } else if let step = result.step { self.noteInstallFailure(step, error: result.message) }
                    return
                }
                self.installedOn = device
                self.installedAppPath = result.appPath
                self.shellUpdatedOnDevice = result.shellUpdated
                self.onBuiltGamesInstalled(result.appPath, device)
                self.finishInstall(nil, note: result.message)
            }
        }
    }

    /// Signs and installs the shared app once for all successful games of a queued batch, then transfers their missing game data.
    package func installShellBatch(_ games: [DeferredShellGame], dataOnly: Bool = false) {
        guard let last = games.last else { return }
        buildingGame = false
        runningTarget = BuildTarget.ios
        beginOperation(dataOnly ? .sendingGameData : .installing, game: games.count == 1 ? last.name : nil,
                       titleID: games.count == 1 ? last.titleID : nil, destination: .target)
        stopping = false; installCancel.set(false); installPhaseActive = true
        if dataOnly { stoppedByPlayer = false }
        running = true; done = false; doneNote = ""; failure = nil; shellUpdatedOnDevice = false
        if dataOnly { stages = [] }
        finderShown = false
        shellBatchRetry = games
        setInstallRecovery(.installBatch(games: games, dataOnly: dataOnly))
        shellRetry = (last.framework, last.titleID, last.name, last.archive)
        let batchGames = games.map {
            ShellInstaller.BatchGame(
                framework: $0.framework,
                titleID: $0.titleID,
                name: $0.name,
                archive: $0.archive,
                pickedArtwork: pickedArtworkForTitleID($0.titleID),
                queueEntryID: $0.queueEntryID,
                didUpdateImg: $0.didUpdateImg,
                updatedImgPath: $0.updatedImgPath
            )
        }
        let anyImgUpdated = games.contains(where: \.didUpdateImg)
        let installer = makeInstaller(respectSkipMode: !dataOnly && !anyImgUpdated)
        let root = installer.root
        let target = devices
        let device = devices.installDevice
        DispatchQueue.global(qos: .userInitiated).async {
            let result = dataOnly ? installer.installBatchData(batchGames) : installer.installBatch(batchGames)
            if !dataOnly, result.ok {
                let surviving = Set(ShellLibrary.load(root: root).games.map { $0.titleID.uppercased() })
                for game in games where surviving.contains(game.titleID.uppercased()) {
                    PostBuildCleanup.cleanBuiltFrameworkContainer(game.framework)
                }
            }
            hop {
                self.installPhaseActive = false
                target.copyEnded()
                if self.stopping {
                    self.stopping = false; self.running = false
                    self.failure = nil; self.clearInstallRecovery(includeFastRefresh: true)
                    self.resetProgress(); self.doneNote = self.t("msg.stopped"); self.cleanupStaging()
                    return
                }
                self.applyBatchImgResults(result.batchGameResults)
                // Batch installations track per-entry img disposition on QueueEntry rather than the single-game scalar reminder.
                self.needsReplaceOldImgReminder = false
                self.updatedImgPath = ""
                guard result.ok else {
                    if !result.appPath.isEmpty {
                        self.installedOn = device
                        self.installedAppPath = result.appPath
                        self.onBatchShellInstalled(games, result.appPath, device)
                    }
                    self.finishInstall(result.message)
                    if let kind = result.failure {
                        let detail = (kind == .appIDLimit && !result.detail.isEmpty) ? result.detail : nil
                        let f = BuildFailure(kind: kind, gameName: nil, detail: detail)
                        self.failure = f
                        if kind == .appIDLimit { self.doneNote = self.failureWhat(f) }
                    } else if let step = result.step { self.noteInstallFailure(step, error: result.message) }
                    return
                }
                if !result.copySkipped {
                    self.shellBatchRetry = nil
                }
                self.installedOn = device
                self.installedAppPath = result.appPath
                self.shellUpdatedOnDevice = result.shellUpdated
                self.onBatchShellInstalled(games, result.appPath, device)
                self.installedDataComplete = !result.copySkipped
                self.finishInstall(nil, note: result.message)
            }
        }
    }

    /// Retry after game data that went over in part: only the data step runs again (listing, diff, copy).
    package func retryShellData() {
        guard !running else { return }
        if let batch = shellBatchRetry, !batch.isEmpty {
            installShellBatch(batch, dataOnly: true)
            return
        }
        guard let r = shellRetry else { return }
        installShell(framework: r.framework, titleID: r.titleID, name: r.name, archive: r.archive, dataOnly: true)
    }

    /// Cancels an active drive copy or post-build device install wait when no child process is running.
    func stopPendingInstallOrCopy() -> Bool {
        if case .copying = send { stopDriveCopy(); return true }
        guard endPreflight == nil else { return false }
        devices.cancelCopy()
        guard running, !stopping else { return false }
        installCancel.set(true)
        if proc?.isRunning == true { return false }
        guard installPhaseActive else { return false }
        stopping = true
        stopPSOPoll()
        DispatchQueue.main.async { [weak self] in
            if self?.stopping == true { self?.devices.cancelCopy() }
        }
        return true
    }

    package func finishInstall(_ failure: String?, note: String? = nil, completeProgress: Bool = true) {
        running = false
        done = failure == nil
        if failure == nil && completeProgress {
            completeOverallProgress()
        } else {
            refreshOverallProgress(parsedTotal: nil)
        }
        var resolved = failure ?? note ?? String(format: t("dev.installed"), devices.deviceName(devices.installDevice))
        if failure == nil, !deferShellPackaging, needsReplaceOldImgReminder {
            let imgName = updatedImgPath.isEmpty ? "romfs.img" : (updatedImgPath as NSString).lastPathComponent
            let reminder = String(format: t("imgGuide.replaceOldImgBody"), imgName)
            if !resolved.contains(reminder) {
                resolved = resolved.isEmpty ? reminder : (resolved + "\n" + reminder)
            }
        }
        doneNote = resolved
        cleanupStaging()
    }

    /// Reinstall the signed app that is already in derived data, without unpacking, signing or packing again: the
    /// device keeps the app's Documents (game data and saves), as the bundle ID does not change. A reinstall that
    /// fails on an expired signature says so in devicectl's words; signing again is not this button's job.
    package func reinstallOnDevice(then: (() -> Void)? = nil) {
        let device = installedOn, app = installedAppPath
        guard !device.isEmpty, !app.isEmpty else { then?(); return }
        guard FileManager.default.fileExists(atPath: app) else {
            doneNote = String(format: t("dev.reinstallMissing"), shortPath(app))
            then?(); return
        }
        let deviceName = devices.deviceName(device)
        buildingGame = false; runningTarget = BuildTarget.ios
        beginOperation(.installing, game: nil, titleID: nil, destination: .device(deviceName))
        needsReplaceOldImgReminder = false; updatedImgPath = ""; shellUpdatedOnDevice = false
        running = true
        runTool(id: 1004, name: String(format: t("dev.reinstallStage"), deviceName),
                BuildCommands.reinstallCommand(xcrun: devices.xcrun, device: device, app: app), nameKey: "dev.reinstallStage",
                nameArgument: deviceName, step: BuildProgress.installStep) { error in
            if let error {
                // The app is still on the device: a failed reinstall is a note, not a failed build
                self.running = false
                self.doneNote = String(format: self.t("dev.reinstallFailed"), error)
            } else {
                self.running = false
                self.doneNote = String(format: self.t("dev.reinstalled"), self.devices.deviceName(device))
                self.cleanupStaging()
            }
            then?()
        }
    }

    /// The signed app as an .ipa, written to the place the app's save panel (`chooseSaveLocation`) returned.
    package func saveIPAPanel() {
        guard !running else { return }
        guard let url = chooseSaveLocation(t("dev.saveIPATitle"), defaultIPAName()) else { return }
        saveIPA(to: url)
    }

    /// The signed app as an .ipa (Payload/<name>.app, the layout iOS and the sideloaders install): useful while the
    /// signature lasts, and the thing to re-sign when it expires. All staging copies, shader archive packing, ZIP32
    /// entry-count validation and archive creation run on a background queue so multi-GB bundles never freeze the UI.
    package func saveIPA(to url: URL, entryLimit: Int = ShellExport.entryLimit, then: (() -> Void)? = nil) {
        guard !running else { return }
        let app = installedAppPath
        guard !app.isEmpty, FileManager.default.fileExists(atPath: app) else {
            doneNote = String(format: t("dev.saveNeedsApp"), shortPath(app))
            then?()
            return
        }
        let stageID = 1005
        let stageName = t("dev.saveStage")
        let resolvedPy = resolveBuildPython()
        let groupPython = resolvedPy.isEmpty ? "/usr/bin/python3" : resolvedPy
        let lang = localizer.lang
        let runner = self.runner
        let cancel = installCancel
        buildingGame = false
        runningTarget = BuildTarget.ios
        beginOperation(.exportingIPA, game: nil, titleID: nil, destination: .none)
        stopping = false
        stoppedByPlayer = false
        needsReplaceOldImgReminder = false
        updatedImgPath = ""
        cancel.set(false)
        installPhaseActive = true
        running = true
        if let i = stages.firstIndex(where: { $0.id == stageID }) {
            stages[i] = Stage(id: stageID, name: stageName, state: .running, started: Date(), nameKey: "dev.saveStage")
        } else {
            stages.append(Stage(id: stageID, name: stageName, state: .running, started: Date(), nameKey: "dev.saveStage"))
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let fm = FileManager.default
            let stage = fm.temporaryDirectory.appendingPathComponent("nspb-ipa-" + UUID().uuidString)
            let payload = stage.appendingPathComponent("Payload")
            let stagedApp = payload.appendingPathComponent((app as NSString).lastPathComponent)
            let toolEnv = [
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "HOME": NSHomeDirectory(),
                "USER": NSUserName(),
                "LANG": "en_US.UTF-8"
            ]
            let runStep: ([String]) -> (status: Int32, output: String, lastError: String?) = { command in
                hop { self?.append("[\(stageName)] \(command.joined(separator: " "))\n") }
                var output = ""
                var lastError: String?
                let launch = ProcessLaunch(command, environment: toolEnv, groupPython: groupPython)
                let res = runner.streamLines(launch, started: { p in hop { self?.proc = p } }) { line in
                    hop { self?.append(line + "\n") }
                    output += line + "\n"
                    if line.contains("error:") || line.hasPrefix("ERROR:") {
                        lastError = line.trimmingCharacters(in: .whitespaces)
                    }
                }
                guard res.started else { return (127, res.out, res.out) }
                return (res.status, output, lastError)
            }

            var failureReason: String?
            var ranZip = false
            do {
                try fm.createDirectory(at: payload, withIntermediateDirectories: true)
                try fm.copyItem(atPath: app, toPath: stagedApp.path)
                if !cancel.value, try ShellExport.exceedsEntryLimit(in: payload, limit: entryLimit) {
                    let frameworks = ShellExport.gameFrameworkNames(forApp: app, stagedApp: stagedApp, fm: fm)
                    try ShellExport.packShaderLibraries(
                        in: stagedApp,
                        frameworkNames: frameworks,
                        runArchive: runStep,
                        exitCodeMessage: { String(format: L10n.string("msg.exitCode", lang), $0) }
                    )
                    if try ShellExport.exceedsEntryLimit(in: payload, limit: entryLimit) {
                        throw ShellExport.entryLimitExceededError(limit: entryLimit)
                    }
                }
                if !cancel.value {
                    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    ranZip = true
                    let zipped = runStep(BuildCommands.ipaCommand(payload: payload.path, ipa: url.path))
                    if zipped.status != 0 {
                        try? fm.removeItem(at: url)
                        failureReason = zipped.lastError ?? String(format: L10n.string("msg.exitCode", lang), zipped.status)
                    }
                }
            } catch {
                failureReason = error.localizedDescription
            }
            if cancel.value, ranZip {
                try? fm.removeItem(at: url)
            }
            try? fm.removeItem(at: stage)

            hop {
                guard let self else { return }
                self.proc = nil
                self.installPhaseActive = false
                if self.stopping || cancel.value {
                    self.stopping = false
                    self.running = false
                    self.resetProgress()
                    self.doneNote = self.t("msg.stopped")
                    self.cleanupStaging()
                    then?()
                    return
                }
                let ok = failureReason == nil
                if let i = self.stages.firstIndex(where: { $0.id == stageID }) {
                    self.stages[i].state = ok ? .done : .failed
                    if ok {
                        self.stages[i].percent = 100
                        self.stages[i].detail = ""
                    } else if let failureReason {
                        self.stages[i].detail = failureReason
                    }
                }
                self.running = false
                self.doneNote = failureReason.map { String(format: self.t("dev.saveFailed"), $0) }
                    ?? String(format: self.t("dev.savedIPA"), self.shortPath(url.path))
                then?()
            }
        }
    }

    /// The name the save panel offers: the app's display name, so two games' IPAs do not collide. A slash or colon in a
    /// game's name would split the file name or show as a folder in Finder.
    package func defaultIPAName() -> String {
        let plist = NSDictionary(contentsOfFile: installedAppPath + "/Info.plist")
        let name = (plist?["CFBundleDisplayName"] as? String) ?? (plist?["CFBundleExecutable"] as? String) ?? "DmIOS"
        return name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_") + ".ipa"
    }

    /// One of Xcode's tools as a stage of the build: in its own process group (Stop ends it), its output in the log,
    /// its progress in the stage. `then` gets nil on success, else the last error line.
    package func runTool(id: Int, name: String, _ command: [String], environment: [String: String]? = nil,
                         nameKey: String? = nil, nameArgument: String? = nil,
                         step: @escaping (String) -> (detail: String, percent: Double?)?,
                         then: @escaping (String?) -> Void) {
        // A stage that runs again (the team-variant signing retry uses the same id) keeps its row:
        // a second row with that id would never see an update again — every lookup takes the first
        // match — and would spin for ever after the build moved on.
        if let i = stages.firstIndex(where: { $0.id == id }) {
            stages[i] = Stage(id: id, name: name, state: .running, started: Date(), nameKey: nameKey, nameArgument: nameArgument)
        } else {
            stages.append(Stage(id: id, name: name, state: .running, started: Date(), nameKey: nameKey, nameArgument: nameArgument))
        }
        append("[\(name)] \(command.joined(separator: " "))\n")
        let env = environment ?? ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory(), "USER": NSUserName(), "LANG": "en_US.UTF-8"]
        let resolvedGroupPy = resolveBuildPython()
        let launch = ProcessLaunch(command, environment: env,
                                   groupPython: resolvedGroupPy.isEmpty ? "/usr/bin/python3" : resolvedGroupPy)
        let utf8 = UTF8StreamDecoder.Locked()
        var buffer = "", lastError = "", devModeError = ""
        let handleLine: @MainActor (BuildStore, String) -> Void = { store, raw in
            var line = raw
            if line.unicodeScalars.last == "\r" { line.unicodeScalars.removeLast() }
            store.append(line + "\n")
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if line.contains("error:") || line.hasPrefix("ERROR:") { lastError = trimmed }
            if BuildFailureClassifier.isDeveloperModeDisabled(trimmed) { devModeError = trimmed }
            if let s = step(line), let i = store.stages.firstIndex(where: { $0.id == id }) {
                store.stages[i].detail = s.detail
                if let percent = s.percent { store.stages[i].percent = percent }
            }
        }
        let onOutput: @Sendable (Data) -> Void = { [weak self] d in
            hop {
                guard let self else { return }
                let chunk = utf8.decode(d)
                guard !chunk.isEmpty else { return }
                buffer += chunk
                while let nl = buffer.unicodeScalars.firstIndex(of: "\n") {
                    let line = String(buffer.unicodeScalars[..<nl])
                    buffer = String(buffer.unicodeScalars[buffer.unicodeScalars.index(after: nl)...])
                    handleLine(self, line)
                }
            }
        }
        let onExit: @Sendable (Int32) -> Void = { [weak self] status in
            hop {
                guard let self else { return }
                buffer += utf8.finish()
                while let nl = buffer.unicodeScalars.firstIndex(of: "\n") {
                    let line = String(buffer.unicodeScalars[..<nl])
                    buffer = String(buffer.unicodeScalars[buffer.unicodeScalars.index(after: nl)...])
                    handleLine(self, line)
                }
                if !buffer.isEmpty {
                    let tail = buffer; buffer = ""
                    handleLine(self, tail)
                }
                if self.stopping {
                    self.installPhaseActive = false
                    self.stopping = false; self.running = false
                    self.failure = nil; self.clearInstallRecovery(includeFastRefresh: true)
                    self.resetProgress(); self.doneNote = self.t("msg.stopped"); self.cleanupStaging()
                    return
                }
                let ok = status == 0
                if let i = self.stages.firstIndex(where: { $0.id == id }) {
                    self.stages[i].state = ok ? .done : .failed
                    if ok { self.stages[i].percent = 100; self.stages[i].detail = "" }
                }
                let resolvedError = !devModeError.isEmpty ? devModeError : (lastError.isEmpty ? String(format: self.t("msg.exitCode"), status) : lastError)
                then(ok ? nil : resolvedError)
            }
        }
        do { proc = try runner.start(launch, onOutput: onOutput, onExit: onExit) } catch { installPhaseActive = false; then(error.localizedDescription) }
    }

    /// Start the game on the device it was installed on.
    package func openOnDevice(udid: String, app: String, completion: @escaping (String?) -> Void) {
        let info = NSDictionary(contentsOfFile: app + "/Info.plist")
        guard let bundle = info?["CFBundleIdentifier"] as? String else { return completion(String(format: t("dev.noProject"), shortPath(app))) }
        let launch = ProcessLaunch(executable: devices.xcrun, arguments: ["devicectl", "device", "process", "launch", "--device", udid, bundle], mergesErrors: true)
        let runner = runner
        DispatchQueue.global(qos: .userInitiated).async {
            let r = runner.capture(launch)
            var message: String?
            if !r.started { message = r.out }
            else if r.status != 0 { message = r.out.split(separator: "\n").last(where: { $0.contains("rror") }).map(String.init) ?? r.out }
            hop { completion(message) }
        }
    }
}
