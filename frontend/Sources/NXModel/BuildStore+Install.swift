import Foundation
import Combine
import NXCore

// The install on a device after the archive: the shared app, the reinstall, the re-sign and the IPA (LNPANDY/NX2Apple#387).

extension BuildStore {
    // MARK: Installing on a device

    /// The installer with this store's tools, log, stages and process hand-off wired in. The install and the export (BuildStore+Export.swift) share it.
    func makeInstaller() -> ShellInstaller {
        let python = deps.pythonPath.isEmpty ? Toolchain.findPython().path : deps.pythonPath
        var installer = ShellInstaller(xcrun: devices.xcrun, repo: repo.path, python: python, root: shellRoot, device: devices.installDevice, team: devices.signingTeam)
        installer.deviceName = devices.deviceName(devices.installDevice)
        installer.defaults = defaults
        installer.lang = localizer.lang
        installer.ownGroup = true
        installer.toolPath = BuildCommands.toolPath("/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin", python: python)
        installer.log = { @Sendable s in hop { self.append(s) } }
        installer.stage = { @Sendable s in hop {
            if let i = self.stages.firstIndex(where: { $0.id == s.id }) {
                self.stages[i].name = s.name; self.stages[i].state = s.state; self.stages[i].detail = s.detail
                if let percent = s.percent { self.stages[i].percent = percent }
                if s.state == .running, self.stages[i].started == nil { self.stages[i].started = Date() }
            } else {
                self.stages.append(Stage(id: s.id, name: s.name, state: s.state, detail: s.detail, percent: s.percent,
                                         started: s.state == .running ? Date() : nil))
            }
        } }
        installer.runner = runner
        installer.processStarted = { @Sendable p in hop { self.proc = p } }
        // The size and the connection are shown with Continue, "Wait for a cable" and "Not now" (ShellCopyCard)
        let target = devices
        let cancel = installCancel
        installer.decideCopy = { plan in cancel.value ? .skip : target.askCopy(plan) }
        installer.waiting = { on in if !cancel.value || !on { target.setWaiting(on) } }
        installer.waitCancelled = { cancel.value || target.waitCancelled }
        return installer
    }

    /// Steps 4 to 7 of the shared app (ShellInstall.swift) for a game whose framework is built and whose archive is packed: the
    /// shell's project, signing, the install over the app that is already there, and the game data the device lacks.
    package func installShell(framework: String, titleID: String, name: String, archive: String, dataOnly: Bool = false) {
        buildingGame = true
        runningTarget = BuildTarget.ios
        beginOperation(dataOnly ? .sendingGameData : .installing, game: name, titleID: titleID, destination: .target)
        stopping = false; installCancel.set(false); installPhaseActive = true
        if dataOnly { stoppedByPlayer = false }
        running = true
        finderShown = false
        if dataOnly { failure = nil; done = false; doneNote = "" }
        shellBatchRetry = nil
        shellRetry = (framework, titleID, name, archive)
        let installer = makeInstaller()
        let target = devices
        let device = devices.installDevice
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
        finderShown = false
        let installer = makeInstaller()
        let device = devices.installDevice
        DispatchQueue.global(qos: .userInitiated).async {
            let result = installer.installBuilt(framework: framework, titleID: titleID, name: name)
            hop {
                self.installPhaseActive = false
                if self.stopping {
                    self.stopping = false; self.running = false
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
        running = true; done = false; doneNote = ""; failure = nil
        if dataOnly { stages = [] }
        finderShown = false
        shellBatchRetry = games
        shellRetry = (last.framework, last.titleID, last.name, last.archive)
        let batchGames = games.map {
            ShellInstaller.BatchGame(framework: $0.framework, titleID: $0.titleID, name: $0.name, archive: $0.archive,
                                     pickedArtwork: pickedArtworkForTitleID($0.titleID))
        }
        let installer = makeInstaller()
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
                    self.resetProgress(); self.doneNote = self.t("msg.stopped"); self.cleanupStaging()
                    return
                }
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
                self.shellBatchRetry = nil
                self.installedOn = device
                self.installedAppPath = result.appPath
                self.onBatchShellInstalled(games, result.appPath, device)
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

    package func finishInstall(_ failure: String?, note: String? = nil) {
        running = false
        done = failure == nil
        doneNote = failure ?? note ?? String(format: t("dev.installed"), devices.deviceName(devices.installDevice))
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
        buildingGame = false; runningTarget = BuildTarget.ios
        beginOperation(.installing, game: nil, titleID: nil, destination: .target)
        running = true
        runTool(id: 1004, name: String(format: t("dev.reinstallStage"), devices.deviceName(device)),
                BuildCommands.reinstallCommand(xcrun: devices.xcrun, device: device, app: app), step: BuildProgress.installStep) { error in
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
        buildingGame = false; runningTarget = BuildTarget.ios
        beginOperation(.renewingSignature, game: nil, titleID: nil, destination: .target)
        stopping = false; stoppedByPlayer = false; installPhaseActive = true
        running = true
        // The shared app is signed again under the identifier shell.json holds, so the device keeps its Documents
        let command = ShellInstall.buildCommand(xcrun: xcrun, root: shell.root, device: device, team: team, bundleID: bundle)
        let signAndInstall = {
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
                        self.running = false
                        self.doneNote = self.t("msg.stopped")
                        then?(); return
                    }
                    self.stagedResignProfiles = stagedProfiles
                    self.runTool(id: 1006, name: String(format: self.t("dev.resignStage"), name),
                                 command, step: BuildProgress.xcodeStep) { error in
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
                                     BuildCommands.reinstallCommand(xcrun: xcrun, device: device, app: app), step: BuildProgress.installStep) { installError in
                            if let installError {
                                self.doneNote = String(format: self.t("dev.installFailed"), installError)
                            } else {
                                self.installedOn = device
                                self.installedAppPath = app
                                self.doneNote = String(format: self.t("dev.resigned"), name)
                            }
                            self.running = false
                            then?()
                        }
                    }
                }
            }
        }
        guard needsProjectUpdate else {
            signAndInstall()
            return
        }
        let engineRoot = EngineLayout.root(repoPath)
        let python = deps.pythonPath.isEmpty ? Toolchain.findPython().path : deps.pythonPath
        let toolPath = BuildCommands.toolPath("/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin", python: python)
        guard let package = ShellInstall.shellPackage(resources: resources, repo: repoPath) else {
            let looked = ([resources, repoPath].compactMap { $0 }.filter { !$0.isEmpty }).map { $0 + "/frontend-ios" }.joined(separator: ", ")
            self.installPhaseActive = false
            self.running = false
            self.doneNote = String(format: self.t("shell.projectFailed"), "no frontend-ios Swift package (Package.swift) in " + looked)
            then?(); return
        }
        var env = ShellInstall.projectEnvironment(root: shell.root, frameworks: library.games.map(\.framework), bundleID: bundle,
                                                  team: team, python: python, path: toolPath, home: NSHomeDirectory(), user: NSUserName(),
                                                  tmp: NSTemporaryDirectory(), package: package, engine: engineRoot)
        env.merge(BundledTools.environment(for: python)) { $1 }
        let xcconfig = shell.root + "/project/Gen/dm.xcconfig"
        if (try? String(contentsOfFile: xcconfig, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true
            || FileManager.default.fileExists(atPath: shell.root + "/project/entitlements-empty") {
            env["DM_ENTITLEMENTS"] = ""
        }
        runTool(id: ShellInstaller.projectStageID, name: t("shell.projectStage"),
                ShellInstall.projectCommand(package: package), environment: env, step: { _ in nil }) { projectError in
            if let projectError, !projectError.isEmpty {
                self.installPhaseActive = false
                self.running = false
                self.doneNote = String(format: self.t("shell.projectFailed"), projectError)
                then?(); return
            }
            ShellInstall.writeProjectFrameworks(root: shell.root, games: library.games)
            signAndInstall()
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
        let groupPython = deps.pythonPath.isEmpty ? "/usr/bin/python3" : deps.pythonPath
        let lang = localizer.lang
        let runner = self.runner
        let cancel = installCancel
        buildingGame = false
        runningTarget = BuildTarget.ios
        beginOperation(.exportingIPA, game: nil, titleID: nil, destination: .none)
        stopping = false
        stoppedByPlayer = false
        cancel.set(false)
        installPhaseActive = true
        running = true
        if let i = stages.firstIndex(where: { $0.id == stageID }) {
            stages[i] = Stage(id: stageID, name: stageName, state: .running, started: Date())
        } else {
            stages.append(Stage(id: stageID, name: stageName, state: .running, started: Date()))
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
                         step: @escaping (String) -> (detail: String, percent: Double?)?,
                         then: @escaping (String?) -> Void) {
        // A stage that runs again (the team-variant signing retry uses the same id) keeps its row:
        // a second row with that id would never see an update again — every lookup takes the first
        // match — and would spin for ever after the build moved on.
        if let i = stages.firstIndex(where: { $0.id == id }) {
            stages[i] = Stage(id: id, name: name, state: .running, started: Date())
        } else {
            stages.append(Stage(id: id, name: name, state: .running, started: Date()))
        }
        append("[\(name)] \(command.joined(separator: " "))\n")
        let env = environment ?? ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory(), "USER": NSUserName(), "LANG": "en_US.UTF-8"]
        let launch = ProcessLaunch(command, environment: env,
                                   groupPython: deps.pythonPath.isEmpty ? "/usr/bin/python3" : deps.pythonPath)
        let utf8 = UTF8StreamDecoder.Locked()
        var buffer = "", lastError = ""
        let handleLine: @MainActor (BuildStore, String) -> Void = { store, raw in
            var line = raw
            if line.unicodeScalars.last == "\r" { line.unicodeScalars.removeLast() }
            store.append(line + "\n")
            if line.contains("error:") || line.hasPrefix("ERROR:") { lastError = line.trimmingCharacters(in: .whitespaces) }
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
                    self.resetProgress(); self.doneNote = self.t("msg.stopped"); self.cleanupStaging()
                    return
                }
                let ok = status == 0
                if let i = self.stages.firstIndex(where: { $0.id == id }) {
                    self.stages[i].state = ok ? .done : .failed
                    if ok { self.stages[i].percent = 100; self.stages[i].detail = "" }
                }
                then(ok ? nil : (lastError.isEmpty ? String(format: self.t("msg.exitCode"), status) : lastError))
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
