import Foundation
import Combine
import NXCore

// The build run: the script's arguments and environment, the process, and what happens when it ends (LNPANDY/NX2Apple#387).

extension BuildStore {
    package func startBuild() {
        guard !running else { return }
        selectedTitleID = nil
        queuedExportIPA = nil
        queuedExportOneGame = nil
        runBuild()
    }

    func runBuild() {
        guard !running else { return }
        guard prepareBuildPreflight() else { return }
        // The shared app needs a device this Mac knows. Found out here, before an hour of building, not after it.
        if target != BuildTarget.mac, !shellDeviceChecked, !exportsShell {
            guard installsDirectly else { doneNote = t("shell.needsDevice"); done = false; return }
            verifyShellDevice()
            return
        }
        shellDeviceChecked = false
        let skipStale = skipStaleCheckForQueuedEntry
        skipStaleCheckForQueuedEntry = false
        if target != BuildTarget.mac, !exportsOneGame, !skipStale, askAboutStaleFrameworks() { return }   // StaleFrameworksPrompt.swift (#449)
        if let message = spaceProblem() { doneNote = message; done = false; return }
        stopping = false; stoppedByPlayer = false; archiveGeneration &+= 1
        buildingGame = true; runningTarget = target
        beginOperation(.building, game: gameName, titleID: gameTitleID, destination: .target)
        running = true; done = false; doneNote = ""; stages = []; log.clear(); staleShadersMessageKey = nil
        failure = nil; confirmingOverride = nil
        let override = takeOverrideFlag()   // for this build only: the next one asks again
        installedOn = ""; installedAppPath = ""; exportedIPAPath = ""; send = .idle
        guard repo.isRepo else {
            fail(repo.path.isEmpty ? t("msg.repoInvalidEmpty") : String(format: t("msg.repoInvalid"), shortPath(repo.path)))
            return
        }
        // The experimental builder runs `nxb build` and never the script: no nxb, or one too old, stops here (#749). A game nxb does not take ends with its own exit code 4
        nxbRun = ExperimentalBuilder.featureEnabled && experimentalBuilder
        if let why = experimentalBuilderProblem() { fail(why); return }
        // Resolve the interpreter here if the dependency check has not landed yet. checkDeps()
        // runs on a background queue and startBuild() can beat it — for a moment deps.pythonPath is
        // empty, and the old fallback was Apple's /usr/bin/python3 (3.9), which the script then
        // rejected with "require Python 3.12 or newer" whatever the machine actually had (#53).
        let py = deps.pythonPath.isEmpty ? Toolchain.findPython().path : deps.pythonPath
        // engine/ is the only engine and is stale or missing (#214): make it, then start again
        if EngineLayout.needsSyncBeforeBuild(repo.path) {
            _ = engine.syncEngine { ok in
                self.running = false
                if ok && !EngineLayout.needsSyncBeforeBuild(self.repo.path) { self.runBuild() }
                else { self.fail(String(format: self.t("msg.toolsOld"), "engine/ (python3 tools/engine.py sync, see the log)")) }
            }
            return
        }
        // The tools this app runs, before a build that takes an hour finds one missing at its last step (#87)
        let missing = RepoLayout.missingTools(in: repo.path)
        if !missing.isEmpty {
            fail(String(format: t("msg.toolsOld"), missing.joined(separator: ", ")))
            return
        }

        // One folder when everything lives together; otherwise a staging folder of symlinks. A folder
        // that holds other games too (a ROMs folder with one file per game) is staged as well: the
        // script takes one game per folder and refuses one with several ("more than one game in the
        // folder"), even when only the base game was picked (issue #58; ufooer's PR #31).
        // A game folder (BuildStore+GameFolder.swift) goes to the script as it is: the engine must have its packer and the game's profile.
        let folder = gameFolder
        if let folder, !nxbRun, let why = gameFolderEngineProblem(folder) { fail(why); return }   // nxb reads the folder itself
        let baseDir = inputFolder
        let allPaths = folder != nil ? [] : [basePath, updatePath] + dlcPaths
        let dirs = Set(allPaths.filter { !$0.isEmpty }.map { ($0 as NSString).deletingLastPathComponent })
        let picked = Set(allPaths.filter { !$0.isEmpty }.map { ($0 as NSString).lastPathComponent })
        let unpicked = folder != nil ? [] : ((try? FileManager.default.contentsOfDirectory(atPath: baseDir)) ?? []).filter {
            ["nsp", "xci", "nsz", "xcz"].contains(($0 as NSString).pathExtension.lowercased()) && !picked.contains($0)
        }
        // Staged, the folder's own update and add-on content would be left behind, where the script
        // used to find them unpicked: bring along those whose file name carries this game's title ID
        // exactly as build_ipa_from_nsp.py:445 reads it: the low 12 bits are 0x000 for a base game,
        // 0x800 for its update, and anything else is add-on content below the base.
        var staged = allPaths
        if folder == nil, let base = selectedTitleID.flatMap({ UInt64($0, radix: 16) }) ?? TitleID.parse(basePath) {
            let app = base & ~0xFFF
            for f in unpicked {
                guard let tid = TitleID.parse(f) else { continue }
                let low = tid & 0xFFF
                let owner = low == 0 ? tid : (low == 0x800 ? tid & ~0xFFF : (tid & ~0xFFF) - 0x1000)
                guard owner == app else { continue }
                if low == 0x800 && !updatePath.isEmpty { continue }   // the update was picked already
                if low != 0 && low != 0x800 && tid <= app { continue }   // add-on content sits above its base
                staged.append(baseDir + "/" + f)
            }
        }
        let tidHex = buildKey
        let workDir = (outDir.isEmpty ? baseDir : outDir) + "/" + tidHex + "_build"
        // The build's signing step refuses the attributes a cloud folder adds, after the long steps: stop here instead.
        if cloudFolderCheck(workDir) {
            failure = BuildFailure(kind: .cloudFolder, gameName: nil, detail: workDir)
            fail(failureWhat(failure!))
            return
        }
        // The shared app's own folder is decided before the long steps too: one on a read-only volume (a saved
        // /NX2Apple-shell, a DMG chosen as Save to) failed at the last step after the whole build (#492).
        if target != BuildTarget.mac, !exportsOneGame, let why = shellRootProblem() { fail(why); return }
        var inputDir = folder?.scriptInput ?? baseDir   // a NUP goes to the script as the file
        // A file named .NSP or .Xci is staged too, under a lowercase extension: the script's glob misses it (#554).
        if dirs.count > 1 || !unpicked.isEmpty || staged.contains(where: InputStaging.needsLowercaseName) {
            // A stable folder per game (#132): the script's fingerprints name its files and its profile path.
            let tmp = InputStaging.folder(workDir: workDir)
            let linked = InputStaging.sync(files: staged, into: tmp)
            if linked == 0 { fail(t("msg.stagingFailed")); return }
            staging = tmp; inputDir = tmp
            if !unpicked.isEmpty {
                say(String(format: t("msg.stagedFromSharedFolder"), (basePath as NSString).lastPathComponent))
            }
        } else { staging = nil }

        // This fork's --work-dir keeps the build folder (extracted files, shader cache, the romfs
        // archive) outside the NSPs' folder. An upstream checkout or an older ZIP does not have the
        // option and would stop with "unrecognized arguments" (issue #5), so ask the script; without
        // it the script's own default (<input>/<title ID>_build) is used and the archive step follows
        // whatever folder the build reports.
        let hasWorkDir = nxbRun || RepoLayout.supportsWorkDir(repo.path)
        if !hasWorkDir {
            say(t("msg.noWorkDir"))
        }
        // A compressed dump (NSZ / XCZ) needs nsz in the interpreter the build runs under; it is not
        // part of the dependency probe (most builds never see one), so install it here, once, only
        // when such a file is actually selected — otherwise the build stops with "pip install nsz".
        let compressed = ([basePath, updatePath] + dlcPaths).contains {
            let e = ($0 as NSString).pathExtension.lowercased()
            return e == "nsz" || e == "xcz"
        }
        if compressed, !nxbRun, !Toolchain.runOK(py, ["-c", "import nsz"]) {   // nxb reads NSZ itself
            say(t("msg.installingNsz"))
            let r = runner.runCaptured([py, "-m", "pip", "install", "nsz"],
                                     env: ["PATH": BuildCommands.toolPath(python: py),
                                           "HOME": NSHomeDirectory()].merging(BundledTools.environment(for: py)) { $1 }) { @Sendable line in
                hop { self.append(line + "\n") }
            }
            if !r {
                fail(String(format: t("msg.nszFailed"), py))
                return
            }
        }
        let engine = EngineLayout.root(repo.path)   // the checkout's engine/ (#214)
        // A game folder's files are not encrypted: the script ignores -k for it, and the launcher does not ask for the keys.
        var args = [engine + "/" + RepoLayout.buildScript, inputDir] + (folder != nil ? [] : ["-k", keysPath]) + ["--progress", "json"]
        if let selectedTitleID { args += ["--title-id", selectedTitleID] }
        // A small env file the pipeline copies into the app bundle (main.m sets one variable per line at boot). Only for an iPhone or
        // iPad build: the in-game menu's words in the launcher's language (GameMenuText, #1129), and the CPU decode of BC textures when
        // the player turned that compatibility switch on (a Mac app runs on this Mac's GPU, which always has BC support).
        var tempEnvURL: URL?
        if target != BuildTarget.mac {
            let envURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nspb-env-\(UUID().uuidString).txt")
            do {
                try GameMenuText.envFile(bcOnCPU: bcOnCPU, t).write(to: envURL, atomically: true, encoding: .utf8)
                tempEnvURL = envURL
                args += ["--env-file", envURL.path]
                if bcOnCPU { say(t("msg.bcOn")) }
            } catch {
                say(String(format: t("msg.bcEnvFailed"), error.localizedDescription))
            }
        }
        if hasWorkDir { args += ["--work-dir", workDir] }
        // The image of this game the other platform's build left (the iPhone build's games/<id>/romfs.img, the Mac app's): the
        // script takes it in place of extracting the RomFS again once it checks out as this version's (#708). A game folder is packed, not extracted.
        // Only for the script: the experimental builder gets these arguments too, and `nxb build` has no such option (0.6.3 and 0.6.4 stop at it).
        if folder == nil, !nxbRun, RepoLayout.supportsRomfsFrom(repo.path) {
            for image in RomFSArchive.reusableImages(root: outDir.isEmpty ? baseDir : outDir, key: tidHex) { args += ["--romfs-from", image] }
        }
        let macApp = target == BuildTarget.mac
        let macOutput = macApp ? MacAppOutput(workDir: URL(fileURLWithPath: workDir), key: tidHex, titleID: gameTitleID, preferred: macAppPath) : nil
        oneGameIPAPath = ""
        if exportsOneGame {
            // One game's own IPA with its game data inside (BuildStore+OneGame.swift, #540)
            oneGameIPAPath = OneGameIPA.path(folder: outDir.isEmpty ? baseDir : outDir, titleID: tidHex)
            args += OneGameIPA.arguments(ipa: oneGameIPAPath)
        } else if let macOutput {
            macAppPath = ""
            args += ["--platform", "mac-app", "-o", macOutput.builderURL.path]
            if !nxbRun, RepoLayout.supportsFallbackIcon(repo.path) { args += macFallbackIconArguments(tidHex) }
        } else {
            // Only the game's framework: the one shared app is made and signed after the script (installShell)
            args += ShellInstall.buildArguments(workDir: workDir, team: exportsShell ? "" : devices.signingTeam)
        }
        // The archive step packs whatever folder the build reported; without --work-dir that is the
        // script's default, which is the same workDir unless a separate output folder was chosen.
        effectiveWorkDir = hasWorkDir ? workDir : (inputDir as NSString).appendingPathComponent(tidHex + "_build")
        args = BuildFailureClassifier.arguments(args, adding: override)
        if let override { say(String(format: t("fail.override.note"), override)) }
        say(String(format: t("msg.running"), py) + " " + args.joined(separator: " "))
        lastBuildCommand = [py] + args

        // The root of the runtime the apphost looks for: derived from the detected installation,
        // not assumed to be ~/.dotnet (Homebrew keeps it in …/opt/dotnet/libexec). Only set when the
        // derivation actually answered — a wrong root is worse than none, and the pipeline derives
        // and verifies its own (DOTNET_ROOT, build_ipa_from_nsp.py) when this is absent.
        // TMPDIR as well: .NET 10 on macOS keeps the named mutex its first-run configure takes
        // (NuGet-Migrations) under $TMPDIR/.dotnet/shm, and with no TMPDIR it stats "" and dies with
        // 'NuGet-Migrations' + lstat("") == ENOENT before any project is read. NSTemporaryDirectory()
        // is the per-user temp folder whether or not the app's own environment carries one.
        var denv = toolEnvironment(python: py)
        if !oneGameIPAPath.isEmpty { denv.merge(OneGameIPA.environment) { $1 } }
        let launch = nxbRun
            ? experimentalLaunch(nxb: experimentalBuilderBinary ?? "", scriptArguments: args, engine: engine, environment: denv, python: py)   // BuildStore+Builder.swift (#749)
            : ProcessLaunch(executable: py, arguments: args, environment: denv, directory: engine, groupPython: py)
        let envCleanup = tempEnvURL
        let utf8 = UTF8StreamDecoder.Locked()
        let onExit: @Sendable (Int32) -> Void = { [weak self] status in
            if let envCleanup { try? FileManager.default.removeItem(at: envCleanup) }
            hop {
                guard let self else { return }
                let tail = utf8.finish()
                if !tail.isEmpty { self.ingest(tail) }
                self.flushLines()
                if status == 0, !self.stopping, let macOutput {
                    self.markAllDone()
                    self.finishMacApp(macOutput)
                    return
                }
                self.running = false
                if self.stopping {
                    self.stopping = false
                    self.resetProgress()
                    self.doneNote = self.t("msg.stopped")
                    self.cleanupStaging()
                    return
                }
                if status == 0 {
                    self.markAllDone()
                    if !self.oneGameIPAPath.isEmpty {
                        self.finishOneGameIPA()
                    } else {
                        // The game's archive, then its framework into the one shared app on the device
                        // The framework the build wrote, and the title ID in its name: the script names it after the game
                        // data's title ID, which the build key lacks when the file name has none (#515)
                        let key = self.buildKey
                        let name = self.gameName
                        let fw = ShellInstall.builtFramework(workDir: self.effectiveWorkDir)
                            ?? ShellInstall.frameworkPath(workDir: self.effectiveWorkDir, titleID: key)
                        let tid = ShellInstall.titleID(ofFramework: fw)
                        self.packArchive(workDir: self.effectiveWorkDir, titleID: tid) {
                            if self.deferShellPackaging { self.deferShellPackage(framework: fw, titleID: tid, name: name, archive: $0) }
                            else if self.exportsShell { self.exportShell(framework: fw, titleID: tid, name: name) }
                            else { self.installShell(framework: fw, titleID: tid, name: name, archive: $0) }
                        }
                    }
                } else {
                    if self.nxbRun {
                        // nxb's own exit code and message, as they are: there is no script to run instead (#749)
                        let note = self.experimentalFailureNote(status: status)
                        if let i = self.stages.lastIndex(where: { $0.state == .running }) { self.stages[i].state = .failed; self.stages[i].detail = String(format: self.t("msg.exitCode"), status) }
                        self.doneNote = note
                        self.say("✗ " + note)
                    } else if let i = self.stages.lastIndex(where: { $0.state == .running }) {
                        self.stages[i].state = .failed
                        self.stages[i].detail = String(format: self.t("msg.exitCode"), status)
                        self.noteFailure()
                    } else {
                        // The last real line says more than the exit code alone, and the message
                        // points at the log: "Build failed (exit code 1)" with nothing else sent a
                        // reporter looking for a log that a short window had below the fold (#52)
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
            fail(String(format: t("msg.launchFailed"), error.localizedDescription))
        }
    }

    /// The app goes where the player finds it, macOS checks its first start (`preflight`), and the build is done.
    @discardableResult
    func finishMacApp(_ output: MacAppOutput) -> Task<Void, Never> {
        let workDir = effectiveWorkDir.isEmpty ? output.workDirectoryURL.path : effectiveWorkDir
        archiveGeneration &+= 1
        let generation = archiveGeneration
        return Task {
            do {
                let app = try await Task.detached {
                    let placed = try output.finish()
                    PostBuildCleanup.cleanWorkDirectory(workDir, removeExtractedRomFS: true, removeShellFramework: true)
                    return placed
                }.value
                guard archiveGeneration == generation, !stopping else { return }
                macAppPath = app.path
                say("✓ " + shortPath(app.path))
                await preflight(app)
                guard archiveGeneration == generation else { return }
                done = true
                doneNote = t("msg.macAppDone")
                running = false
                cleanupStaging()
            } catch MacAppOutput.FinishError.retainedApp(let app, let cause) {
                guard archiveGeneration == generation else { return }
                fail(app.path + "\n" + cause.localizedDescription)
            } catch {
                guard archiveGeneration == generation else { return }
                fail(t("msg.macAppMissing"))
            }
        }
    }

    /// The build's last stage: the new app is opened once, hidden, so that macOS checks it now and not at the player's first
    /// start (#1005, `MacPreflight`). Its end, whatever it is, leaves the build done: a failure is a line in the log and a
    /// failed stage. Skipped when switched off in Settings, or when the app's launcher would start the game instead.
    func preflight(_ app: URL) async {
        guard let open = preflightApp, MacPreflight.enabled(defaults), preflightSupported(app) else { return }
        operation?.kind = .verifyingFirstStart
        let id = (stages.map(\.id).max() ?? 0) + 1
        let started = Date()
        stages.append(Stage(id: id, name: Stage.localizedName("preflight", t), state: .running, started: started))
        say(t("msg.preflight"))
        let error: Error?
        if let run = runPreflight {
            let check = Task { @MainActor in await run(app, preflightTimeout) }
            error = await withTaskCancellationHandler {
                await withCheckedContinuation { (c: CheckedContinuation<Error?, Never>) in
                    let end: @MainActor (Error?) -> Void = { [weak self] e in
                        guard let self, self.endPreflight != nil else { return }
                        self.endPreflight = nil
                        check.cancel()
                        c.resume(returning: e)
                    }
                    endPreflight = { end($0) }
                    Task { @MainActor in end(await check.value) }
                }
            } onCancel: {
                check.cancel()
            }
        } else {
            var timer: Task<Void, Never>?
            error = await withCheckedContinuation { (c: CheckedContinuation<Error?, Never>) in
                let end: @MainActor (Error?) -> Void = { [weak self] e in
                    guard let self, self.endPreflight != nil else { return }   // once: the app quit, Stop, or the timeout
                    self.endPreflight = nil
                    c.resume(returning: e)
                }
                endPreflight = { end($0) }
                let timeout = preflightTimeout
                timer = Task {
                    do { try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)) } catch { return }
                    end(MacPreflight.Failure.timedOut)
                }
                open(app, end)
            }
            timer?.cancel()
        }
        guard let i = stages.firstIndex(where: { $0.id == id }) else { return }
        if let error {
            let why: String
            switch error {
            case MacPreflight.Failure.timedOut: why = String(format: t("msg.preflightTimedOut"), Int(preflightTimeout / 60))
            case MacPreflight.Failure.stopped: why = t("msg.stopped")
            default: why = error.localizedDescription
            }
            stages[i].state = .failed
            stages[i].detail = why
            say("✗ " + String(format: t("msg.preflightFailed"), why))
        } else {
            stages[i].state = .done
            say("✓ " + String(format: t("msg.preflightDone"), Int(Date().timeIntervalSince(started).rounded())))
        }
    }

    /// Looks the device up in `devicectl list devices` (in the background), then starts the build, or says how to pair it.
    package func verifyShellDevice() {
        buildingGame = true; runningTarget = target
        beginOperation(.building, game: gameName, titleID: gameTitleID, destination: .target)
        stopping = false; stoppedByPlayer = false; installPhaseActive = true
        running = true; done = false; doneNote = ""; failure = nil; stages = []
        let xcrun = devices.xcrun, device = devices.installDevice, runner = runner
        DispatchQueue.global(qos: .userInitiated).async {
            let link = ShellInstall.connection(of: device, in: DeviceTools.devices(xcrun: xcrun, timeout: 20, runner: runner))
            hop {
                self.installPhaseActive = false
                self.running = false
                if self.stopping {
                    self.skipStaleCheckForQueuedEntry = false
                    self.stopping = false
                    self.doneNote = self.t("msg.stopped")
                    return
                }
                if link == .notPaired {
                    self.skipStaleCheckForQueuedEntry = false
                    self.failure = BuildFailure(kind: .devicePairing, gameName: nil)
                    self.doneNote = String(format: self.t("shell.notPaired"), self.devices.deviceName(device))
                    return
                }
                self.shellDeviceChecked = true
                self.runBuild()
            }
        }
    }
}

extension BuildStore {
    /// #966: the game files are the least a build needs. Short of that, the build does not start, and the note says why and what is kept.
    func spaceProblem() -> String? {
        preflightSpaceProblem()
    }
}
