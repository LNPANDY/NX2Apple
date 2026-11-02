import Foundation
import Combine
import NXCore

// The install on a device after the archive: the shared app, the reinstall, the re-sign and the IPA (LNPANDY/NX2Apple#387).

extension BuildStore {
    // MARK: Installing on a device

    /// Steps 4 to 7 of the shared app (ShellInstall.swift) for a game whose framework is built and whose archive is packed: the
    /// shell's project, signing, the install over the app that is already there, and the game data the device lacks.
    package func installShell(framework: String, titleID: String, name: String, archive: String, dataOnly: Bool = false) {
        running = true
        if dataOnly { failure = nil; done = false; doneNote = "" }
        shellRetry = (framework, titleID, name, archive)
        let python = deps.pythonPath.isEmpty ? Toolchain.findPython().path : deps.pythonPath
        let root = shellRoot
        var installer = ShellInstaller(xcrun: devices.xcrun, repo: repo.path, python: python, root: root, device: devices.installDevice, team: devices.signingTeam)
        installer.deviceName = devices.deviceName(devices.installDevice)
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
        installer.decideCopy = { plan in target.askCopy(plan) }
        installer.waiting = { on in target.setWaiting(on) }
        installer.waitCancelled = { target.waitCancelled }
        let device = devices.installDevice
        DispatchQueue.global(qos: .userInitiated).async {
            let result = dataOnly ? installer.installData(titleID: titleID, archive: archive)
                                  : installer.install(framework: framework, titleID: titleID, name: name, archive: archive)
            hop {
                target.copyEnded()
                if self.stopping {
                    self.stopping = false; self.running = false
                    self.resetProgress(); self.doneNote = self.t("msg.stopped"); self.cleanupStaging()
                    return
                }
                guard result.ok else {
                    self.finishInstall(result.message)
                    if let kind = result.failure { self.failure = BuildFailure(kind: kind, gameName: nil) }
                    else if let step = result.step { self.noteInstallFailure(step, error: result.message) }
                    return
                }
                self.installedOn = device
                self.installedAppPath = result.appPath
                self.finishInstall(nil, note: result.message)
            }
        }
    }

    /// Retry after game data that went over in part: only the data step runs again (listing, diff, copy).
    package func retryShellData() {
        guard !running, let r = shellRetry else { return }
        installShell(framework: r.framework, titleID: r.titleID, name: r.name, archive: r.archive, dataOnly: true)
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
        running = true
        runTool(id: 1004, name: String(format: t("dev.reinstallStage"), devices.deviceName(device)),
                BuildCommands.reinstallCommand(xcrun: devices.xcrun, device: device, app: app), step: BuildProgress.installStep) { error in
            if let error {
                // The app is still on the device: a failed reinstall is a note, not a failed build
                self.running = false
                self.doneNote = String(format: self.t("dev.reinstallFailed"), error)
            } else {
                self.finishInstall(nil, note: String(format: self.t("dev.reinstalled"), self.devices.deviceName(device)))
            }
            then?()
        }
    }

    /// Renew the shared app's signature (a free Apple ID's profile lasts 7 days). The same xcodebuild parameters as
    /// the install, run on the cached project and derived data: Xcode reuses the compiled products and only signs
    /// again, then devicectl installs the app over itself. PRODUCT_BUNDLE_IDENTIFIER is the one shell.json holds, so the
    /// device keeps the app's Documents (game data, saves).
    package func resignOnDevice(app: String, device: String, then: (() -> Void)? = nil) {
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
        let bundle = ShellLibrary.load(root: shell.root).bundleID
        running = true
        // The shared app is signed again under the identifier shell.json holds, so the device keeps its Documents
        let command = ShellInstall.buildCommand(xcrun: xcrun, root: shell.root, device: device, team: team, bundleID: bundle)
        runTool(id: 1006, name: String(format: t("dev.resignStage"), name),
                command, step: BuildProgress.xcodeStep) { error in
            if let error, !error.isEmpty {
                self.running = false
                self.doneNote = String(format: self.t("dev.resignFailed"), error)
                then?(); return
            }
            self.runTool(id: 1007, name: String(format: self.t("dev.installStage"), name),
                         BuildCommands.reinstallCommand(xcrun: xcrun, device: device, app: app), step: BuildProgress.installStep) { installError in
                self.running = false
                if let installError {
                    self.doneNote = String(format: self.t("dev.installFailed"), installError)
                } else {
                    self.installedOn = device
                    self.installedAppPath = app
                    self.doneNote = String(format: self.t("dev.resigned"), name)
                }
                then?()
            }
        }
    }

    /// The signed app as an .ipa, written to the place the app's save panel (`chooseSaveLocation`) returned.
    package func saveIPAPanel() {
        guard let url = chooseSaveLocation(t("dev.saveIPATitle"), defaultIPAName()) else { return }
        saveIPA(to: url)
    }

    /// The signed app as an .ipa (Payload/<name>.app, the layout iOS and the sideloaders install): useful while the
    /// signature lasts, and the thing to re-sign when it expires. The game data is not in it — it stays in the app's
    /// Documents (romfs.img), as a normal iOS build has it.
    package func saveIPA(to url: URL, then: (() -> Void)? = nil) {
        let app = installedAppPath, fm = FileManager.default
        guard !app.isEmpty, fm.fileExists(atPath: app) else {
            doneNote = String(format: t("dev.saveNeedsApp"), shortPath(app))
            then?(); return
        }
        let stage = fm.temporaryDirectory.appendingPathComponent("nspb-ipa-" + UUID().uuidString)
        let payload = stage.appendingPathComponent("Payload")
        do {
            try fm.createDirectory(at: payload, withIntermediateDirectories: true)
            try fm.copyItem(atPath: app, toPath: payload.appendingPathComponent((app as NSString).lastPathComponent).path)
        } catch {
            try? fm.removeItem(at: stage)
            doneNote = String(format: t("dev.saveFailed"), error.localizedDescription)
            then?(); return
        }
        running = true
        runTool(id: 1005, name: t("dev.saveStage"), BuildCommands.ipaCommand(payload: payload.path, ipa: url.path), step: { _ in nil }) { error in
            try? fm.removeItem(at: stage)
            self.running = false
            self.doneNote = error.map { String(format: self.t("dev.saveFailed"), $0) }
                ?? String(format: self.t("dev.savedIPA"), self.shortPath(url.path))
            then?()
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
    package func runTool(id: Int, name: String, _ command: [String], step: @escaping (String) -> (detail: String, percent: Double?)?,
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
        let launch = ProcessLaunch(command, environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory(), "USER": NSUserName(), "LANG": "en_US.UTF-8"],
                                   groupPython: deps.pythonPath.isEmpty ? "/usr/bin/python3" : deps.pythonPath)
        var buffer = "", lastError = ""
        let onOutput: @Sendable (Data) -> Void = { [weak self] d in
            guard let chunk = String(data: d, encoding: .utf8) else { return }
            hop {
                guard let self else { return }
                buffer += chunk
                while let nl = buffer.firstIndex(of: "\n") {
                    let line = String(buffer[..<nl]); buffer = String(buffer[buffer.index(after: nl)...])
                    self.append(line + "\n")
                    if line.contains("error:") || line.hasPrefix("ERROR:") { lastError = line.trimmingCharacters(in: .whitespaces) }
                    if let s = step(line), let i = self.stages.firstIndex(where: { $0.id == id }) {
                        self.stages[i].detail = s.detail
                        if let percent = s.percent { self.stages[i].percent = percent }
                    }
                }
            }
        }
        let onExit: @Sendable (Int32) -> Void = { [weak self] status in
            hop {
                guard let self else { return }
                if self.stopping {
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
        do { proc = try runner.start(launch, onOutput: onOutput, onExit: onExit) } catch { then(error.localizedDescription) }
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
