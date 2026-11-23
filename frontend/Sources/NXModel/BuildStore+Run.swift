import Foundation
import Combine
import NXCore

// The build run: the script's arguments and environment, the process, and what happens when it ends (LNPANDY/NX2Apple#387).

extension BuildStore {
    package func startBuild() {
        guard !running else { return }
        fastRefreshActive = false
        fastRefreshTitleID = nil
        fastRefreshGameName = nil
        fastRefreshBaseDir = nil
        fastRefreshExternalImgPath = nil
        selectedTitleID = nil
        queuedExportIPA = nil
        queuedExportOneGame = nil
        queuedExportFramework = nil
        activeQueueEntryUpstream = nil
        queuedIOSSeenShaders = nil
        runBuild()
    }

    func runBuild() {
        guard !running else { return }
        fastRefreshActive = false
        fastRefreshTitleID = nil
        fastRefreshGameName = nil
        fastRefreshBaseDir = nil
        guard prepareBuildPreflight() else {
            fastRefreshExternalImgPath = nil
            return
        }
        if isMacOnlyUpstreamSelected, target != BuildTarget.mac {
            fastRefreshExternalImgPath = nil
            doneNote = t(macOnlyNoteKey)
            done = false
            return
        }
        // The shared app needs a device this Mac knows. Found out here, before an hour of building, not after it.
        if target != BuildTarget.mac, !isS2ArmSelected, !isNxkitSelected, !shellDeviceChecked, !exportsShell {
            guard installsDirectly else {
                fastRefreshExternalImgPath = nil
                doneNote = t("shell.needsDevice")
                done = false
                return
            }
            verifyShellDevice()
            return
        }
        shellDeviceChecked = false
        let skipStale = skipStaleCheckForQueuedEntry
        skipStaleCheckForQueuedEntry = false
        if target != BuildTarget.mac, !isS2ArmSelected, !isNxkitSelected, !exportsOneGame, !exportsFramework, !skipStale, askAboutStaleFrameworks() {
            fastRefreshExternalImgPath = nil
            return
        }   // StaleFrameworksPrompt.swift (#449)
        if let message = spaceProblem() {
            fastRefreshExternalImgPath = nil
            doneNote = message
            done = false
            return
        }
        stopping = false
        stoppedByPlayer = false
        archiveGeneration &+= 1
        buildingGame = true
        runningTarget = target
        beginOperation(.building, game: gameName, titleID: gameTitleID, destination: .target)
        running = true
        done = false
        doneNote = ""
        stages = []
        log.clear()
        staleShadersMessageKey = nil
        failure = nil
        confirmingOverride = nil
        let override = takeOverrideFlag()   // for this build only: the next one asks again
        installedOn = ""
        installedAppPath = ""
        exportedIPAPath = ""
        if !deferShellPackaging {
            needsReplaceOldImgReminder = false
            updatedImgPath = ""
        }
        send = .idle
        mngRun = false
        s2armRun = false
        s2armEventsPath = ""
        nxkitRun = false
        nxkitFeedback = nil   // the last build's question goes with its result (#1460)
        if isMacNativeGamesSelected {
            startMacNativeGamesBuild()
            return
        }
        if isNxkitSelected {
            if let why = nxkitProblem() ?? nxkitWorkRootProblem() {
                fail(why)
                return
            }
            nxkitRun = true
            let tidHex = buildKey
            // The work folder is a cache of the game (a second build reuses its stages). The app is built in the output folder's `<id>_build` and placed beside it.
            let workDir = NxkitBuilder.workDirectory(root: nxkitWorkRoot, key: tidHex)
            let appFolder = (outDir.isEmpty ? inputFolder : outDir) + "/" + tidHex + "_build"
            if cloudFolderCheck(appFolder) {
                failure = BuildFailure(kind: .cloudFolder, gameName: nil, detail: appFolder)
                fail(failureWhat(failure!))
                return
            }
            let fm = FileManager.default
            try? fm.createDirectory(atPath: workDir, withIntermediateDirectories: true)
            try? fm.createDirectory(atPath: appFolder, withIntermediateDirectories: true)
            let nup = gameFolder?.nup
            var input = inputFolder
            if nup == nil {
                guard let folder = nxkitSourceFolder(workDir: workDir) else {
                    fail(t("msg.stagingFailed"))
                    return
                }
                input = folder
            }
            let macOutput = MacAppOutput(workDir: URL(fileURLWithPath: appFolder), key: tidHex, titleID: gameTitleID, preferred: macAppPath)
            oneGameIPAPath = ""
            macAppPath = ""
            effectiveWorkDir = workDir
            guard let launch = nxkitLaunch(input: input, nup: nup, workDir: workDir, outputAppPath: macOutput.builderURL.path) else {
                fail(t("nxkit.missing"))
                return
            }
            startBuildProcess(launch: launch, envCleanup: nil, macOutput: macOutput)
            return
        }
        if isS2ArmSelected {
            startS2ArmBuild()
            return
        }
        guard repo.isRepo else {
            fail(repo.path.isEmpty ? t("msg.repoInvalidEmpty") : String(format: t("msg.repoInvalid"), shortPath(repo.path)))
            return
        }
        // Resolve the interpreter safely while rejecting stale cross-upstream caches and MNG's uv-python.
        let py = resolveBuildPython()
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

        // One folder when everything lives together, otherwise a staging folder of symlinks. A folder
        // that holds other games too (a ROMs folder with one file per game) is staged as well: the
        // script takes one game per folder and refuses one with several ("more than one game in the
        // folder"), even when only the base game was picked (issue #58, ufooer's PR #31).
        // A game folder (BuildStore+GameFolder.swift) goes to the script as it is: the engine must have its packer and the game's profile.
        let folder = gameFolder
        if let folder, let why = gameFolderEngineProblem(folder) {
            fail(why)
            return
        }   // nxb reads the folder itself
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
        if target != BuildTarget.mac, !exportsOneGame, !exportsFramework, let why = shellRootProblem() {
            fail(why)
            return
        }
        // The script writes the game's build seed at the end: not onto this Mac's disk when the seeds' drive is not connected
        if let why = seedRootProblem() {
            fail(why)
            return
        }
        var inputDir = folder?.scriptInput ?? baseDir   // a NUP goes to the script as the file
        // A file named .NSP or .Xci is staged too, under a lowercase extension: the script's glob misses it (#554).
        if dirs.count > 1 || !unpicked.isEmpty || staged.contains(where: InputStaging.needsLowercaseName) {
            // A stable folder per game (#132): the script's fingerprints name its files and its profile path.
            let tmp = InputStaging.folder(workDir: workDir)
            let linked = InputStaging.sync(files: staged, into: tmp)
            if linked == 0 {
                fail(t("msg.stagingFailed"))
                return
            }
            staging = tmp
            inputDir = tmp
            if !unpicked.isEmpty {
                say(String(format: t("msg.stagedFromSharedFolder"), (basePath as NSString).lastPathComponent))
            }
        } else { staging = nil }

        // This fork's --work-dir keeps the build folder (extracted files, shader cache, the romfs
        // archive) outside the NSPs' folder. An upstream checkout or an older ZIP does not have the
        // option and would stop with "unrecognized arguments" (issue #5), so ask the script. Without
        // it the script's own default (<input>/<title ID>_build) is used and the archive step follows
        // whatever folder the build reports.
        let hasWorkDir = RepoLayout.supportsWorkDir(repo.path)
        if !hasWorkDir {
            say(t("msg.noWorkDir"))
        }
        // A compressed dump (NSZ / XCZ) needs `nsz` either in `py` or as an `nsz` executable on PATH
        // (`build_ipa_from_nsp.py:nsz_command`). Never run bare `pip install` against an externally managed
        // interpreter (PEP 668): reuse BundledTools or an app-managed `nsz-venv` and prepend its bin dir to PATH.
        // Inspect `staged` so auto-staged sibling updates/DLCs in .nsz/.xcz format also trigger nsz provisioning.
        let compressed = staged.contains {
            let e = ($0 as NSString).pathExtension.lowercased()
            return e == "nsz" || e == "xcz"
        }
        var extraNszBinDir: String? = nil
        var needsAsyncManagedNszInstall = false
        if compressed {
            let probeEnv = ProxyEnvironment.merged(into: [
                "PATH": BuildCommands.toolPath(python: py),
                "HOME": home,
            ].merging(BundledTools.environment(for: py)) { $1 })
            if !Toolchain.runOK(py, ["-c", "import nsz"], env: probeEnv, runner: runner) {
                if let bundledPy = BundledTools.python(),
                   bundledPy != py,
                   Toolchain.runOK(bundledPy, ["-c", "import nsz"], env: ProxyEnvironment.merged(into: ["HOME": home].merging(BundledTools.environment(for: bundledPy)) { $1 }), runner: runner) {
                    let bundledBin = (bundledPy as NSString).deletingLastPathComponent
                    if FileManager.default.isExecutableFile(atPath: bundledBin + "/nsz") {
                        extraNszBinDir = bundledBin
                    }
                }
                if extraNszBinDir == nil {
                    // Pass a clean base environment (without `py`'s PYTHONHOME/PYTHONPATH) so `nsz-venv` is never contaminated.
                    let cleanNszProbeEnv = ProxyEnvironment.merged(into: [
                        "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                        "HOME": home,
                        "LANG": "en_US.UTF-8",
                    ])
                    if let ready = Toolchain.readyManagedNszTool(
                        venvDir: Toolchain.nszVenvDir(home: home),
                        environment: cleanNszProbeEnv,
                        runner: runner
                    ) {
                        extraNszBinDir = ready.binDir
                    } else {
                        needsAsyncManagedNszInstall = true
                    }
                }
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
        if folder == nil, RepoLayout.supportsRomfsFrom(repo.path) {
            var reusable = RomFSArchive.reusableImages(root: outDir.isEmpty ? baseDir : outDir, key: tidHex)
            if let extImg = fastRefreshExternalImgPath, !reusable.contains(extImg), FileManager.default.fileExists(atPath: extImg) {
                reusable.append(extImg)
            }
            for image in reusable { args += ["--romfs-from", image] }
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
            if shouldPassSeenShaders(forTitleID: gameTitleID ?? tidHex) {
                args += ["--seen-shaders"]
                say(t("msg.seenShadersOn"))
            }
            if RepoLayout.supportsFallbackIcon(repo.path) { args += macFallbackIconArguments(tidHex) }
        } else {
            // Only the game's framework: the one shared app is made and signed after the script (installShell)
            args += ShellInstall.buildArguments(workDir: workDir, team: exportsShell ? "" : devices.signingTeam)
        }
        if !macApp, RepoLayout.supportsCheatDir(repo.path),
           let activeCheatsDir = RepoLayout.existingCheatsDir(titleID: gameTitleID ?? tidHex, home: self.home) {
            args += ["--cheat-dir", activeCheatsDir]
        }
        if !macApp, shouldPassIOSSeenShaders(forTitleID: gameTitleID ?? tidHex, requested: queuedIOSSeenShaders) {
            args += ["--seen-shaders"]
            say(t("msg.iosSeenShadersOn"))
        }
        // The archive step packs whatever folder the build reported, and without --work-dir that is the
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
        if let extraNszBinDir, !extraNszBinDir.isEmpty {
            let curPath = denv["PATH"] ?? BuildCommands.toolPath(python: py)
            if !curPath.split(separator: ":").contains(Substring(extraNszBinDir)) {
                denv["PATH"] = extraNszBinDir + ":" + curPath
            }
        }
        if !oneGameIPAPath.isEmpty { denv.merge(OneGameIPA.environment) { $1 } }

        if needsAsyncManagedNszInstall {
            let gen = archiveGeneration
            let homeDir = home
            let runner = self.runner
            let cancel = installCancel
            let installingNszMsg = t("msg.installingNsz")
            let immutableArgs = args
            let immutableEnv = denv
            let immutableEnvCleanup = tempEnvURL
            cancel.set(false)
            installPhaseActive = true
            beginExternalStage(name: installingNszMsg)
            say(installingNszMsg)
            let appendLine: @Sendable (String) -> Void = { [weak self] line in
                hop {
                    guard let self, self.archiveGeneration == gen, !self.stopping, !self.installCancel.value else { return }
                    self.append(line + "\n")
                }
            }
            Task.detached(priority: .userInitiated) { [weak self] in
                var resolvedBinDir: String? = nil
                var installFailure: NszInstallFailureKind? = nil

                if !Toolchain.isExternallyManagedPython(py, home: homeDir) {
                    let pipEnv = ProxyEnvironment.merged(into: [
                        "PATH": BuildCommands.toolPath(python: py),
                        "HOME": homeDir,
                    ].merging(BundledTools.environment(for: py)) { $1 })
                    final class DirectLog: @unchecked Sendable {
                        private let lock = NSLock()
                        var lines: [String] = []
                        func add(_ l: String) { lock.lock(); lines.append(l); lock.unlock() }
                        var text: String { lock.lock(); defer { lock.unlock() }; return lines.joined(separator: "\n") }
                    }
                    let directLog = DirectLog()
                    let directOK = runner.runCaptured([py, "-m", "pip", "install", "nsz"], env: pipEnv) { @Sendable line in
                        directLog.add(line)
                        appendLine(line)
                    }
                    if directOK {
                        resolvedBinDir = (py as NSString).deletingLastPathComponent
                    } else if !cancel.value {
                        let directKind = Toolchain.classifyNszInstallFailure(directLog.text)
                        if directKind == .pep668 || directKind == .permissionDenied {
                            switch Toolchain.ensureManagedNszTool(
                                preferredPython: py,
                                home: homeDir,
                                runner: runner,
                                cancel: cancel,
                                onLine: appendLine
                            ) {
                            case .success(let tool):
                                resolvedBinDir = tool.binDir
                            case .failure(let err):
                                installFailure = err
                            }
                        } else {
                            installFailure = directKind
                        }
                    }
                } else {
                    switch Toolchain.ensureManagedNszTool(
                        preferredPython: py,
                        home: homeDir,
                        runner: runner,
                        cancel: cancel,
                        onLine: appendLine
                    ) {
                    case .success(let tool):
                        resolvedBinDir = tool.binDir
                    case .failure(let err):
                        installFailure = err
                    }
                }

                let finalBinDir = resolvedBinDir
                let finalFailure = installFailure
                hop {
                    guard let self, self.archiveGeneration == gen else {
                        if let immutableEnvCleanup { try? FileManager.default.removeItem(at: immutableEnvCleanup) }
                        return
                    }
                    self.installPhaseActive = false
                    if self.stopping || self.installCancel.value {
                        if let immutableEnvCleanup { try? FileManager.default.removeItem(at: immutableEnvCleanup) }
                        self.finishStoppedExternalPrep()
                        return
                    }
                    if let finalFailure {
                        if let immutableEnvCleanup { try? FileManager.default.removeItem(at: immutableEnvCleanup) }
                        self.fail(self.nszFailureMessage(finalFailure, python: py))
                        return
                    }
                    self.finishExternalStage(name: installingNszMsg)
                    var launchEnv = immutableEnv
                    if let finalBinDir, !finalBinDir.isEmpty {
                        let curPath = launchEnv["PATH"] ?? BuildCommands.toolPath(python: py)
                        if !curPath.split(separator: ":").contains(Substring(finalBinDir)) {
                            launchEnv["PATH"] = finalBinDir + ":" + curPath
                        }
                    }
                    let launch = ProcessLaunch(executable: py, arguments: immutableArgs, environment: launchEnv, directory: engine, groupPython: py)
                    self.startBuildProcess(launch: launch, envCleanup: immutableEnvCleanup, macOutput: macOutput)
                }
            }
            return
        }

        let launch = ProcessLaunch(executable: py, arguments: args, environment: denv, directory: engine, groupPython: py)
        startBuildProcess(launch: launch, envCleanup: tempEnvURL, macOutput: macOutput)
    }

    func startBuildProcess(launch: ProcessLaunch, envCleanup: URL?, macOutput: MacAppOutput?) {
        let utf8 = UTF8StreamDecoder.Locked()
        let onExit: @Sendable (Int32) -> Void = { [weak self] status in
            if let envCleanup { try? FileManager.default.removeItem(at: envCleanup) }
            hop {
                guard let self else { return }
                let tail = utf8.finish()
                if !tail.isEmpty { self.ingest(tail) }
                self.flushLines()
                if status == 0, !self.stopping, let macOutput {
                    self.fastRefreshExternalImgPath = nil
                    self.markAllDone()
                    self.finishMacApp(macOutput)
                    return
                }
                if status == 0, !self.stopping, self.s2armRun {
                    self.fastRefreshExternalImgPath = nil
                    self.finishS2ArmBuild()
                    return
                }
                self.running = false
                if self.stopping {
                    self.stopping = false
                    self.resetProgress()
                    self.doneNote = self.t("msg.stopped")
                    macOutput?.cleanupEmptyStagingDirectory()
                    self.cleanupStaging()
                    return
                }
                if status == 0 {
                    self.markAllDone()
                    if !self.oneGameIPAPath.isEmpty {
                        self.fastRefreshExternalImgPath = nil
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
                            else if self.exportsFramework { self.exportFrameworkBundle(framework: fw, titleID: tid, name: name) }
                            else if self.exportsShell { self.exportShell(framework: fw, titleID: tid, name: name) }
                            else { self.installShell(framework: fw, titleID: tid, name: name, archive: $0) }
                        }
                    }
                } else {
                    self.fastRefreshExternalImgPath = nil
                    if self.s2armRun {
                        let note = self.s2armFailureNote(status: status)
                        if let i = self.stages.lastIndex(where: { $0.state == .running }) {
                            self.stages[i].state = .failed
                            self.stages[i].detail = String(format: self.t("msg.exitCode"), status)
                        }
                        self.doneNote = note
                        self.say("✗ " + note)
                    } else if self.mngRun {
                        let note = self.macNativeGamesFailureNote(status: status)
                        if let i = self.stages.lastIndex(where: { $0.state == .running }) {
                            self.stages[i].state = .failed
                            self.stages[i].detail = String(format: self.t("msg.exitCode"), status)
                        }
                        self.doneNote = note
                        self.say("✗ " + note)
                        self.noteFailure()
                    } else if self.nxkitRun {
                        // nxb's own exit code and its last lines, as they are: there is no script to run instead (#1460)
                        self.finishFailedNxkitBuild(status: status)   // BuildStore+Nxkit.swift
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
                    macOutput?.cleanupEmptyStagingDirectory()
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
            macOutput?.cleanupEmptyStagingDirectory()
            fail(String(format: t("msg.launchFailed"), error.localizedDescription))
        }
    }

    /// The app goes where the player finds it, macOS checks its first start (`preflight`), and the build is done.
    @discardableResult
    func finishMacApp(_ output: MacAppOutput) -> Task<Void, Never> {
        let workDir = effectiveWorkDir.isEmpty ? output.workDirectoryURL.path : effectiveWorkDir
        let preserveExternalWork = mngRun || s2armRun || nxkitRun   // nxkit's work folder is a cache of the game
        let appFolderToTidy = nxkitRun ? output.workDirectoryURL : nil
        archiveGeneration &+= 1
        let generation = archiveGeneration
        return Task {
            do {
                let app = try await Task.detached {
                    let placed = try output.finish()
                    if !preserveExternalWork {
                        PostBuildCleanup.cleanWorkDirectory(workDir, removeExtractedRomFS: true, removeShellFramework: true)
                    }
                    // nxb built the app in `<id>_build` and the output placed it beside: that folder is empty now
                    if let appFolderToTidy, ((try? FileManager.default.contentsOfDirectory(atPath: appFolderToTidy.path)) ?? ["-"]).isEmpty {
                        try? FileManager.default.removeItem(at: appFolderToTidy)
                    }
                    return placed
                }.value
                guard archiveGeneration == generation, !stopping else { return }
                macAppPath = app.path
                say("✓ " + shortPath(app.path))
                await preflight(app)
                guard archiveGeneration == generation else { return }
                done = true
                doneNote = t("msg.macAppDone")
                if nxkitRun { finishNxkitBuild(app: app) }   // BuildStore+Nxkit.swift: the game's record and "Did it work?"
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
        stages.append(Stage(id: id, name: "preflight", state: .running, started: started))
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
    package func verifyShellDevice(then resume: (() -> Void)? = nil) {
        buildingGame = true
        runningTarget = target
        beginOperation(.building, game: gameName, titleID: gameTitleID, destination: .target)
        stopping = false
        stoppedByPlayer = false
        installPhaseActive = true
        running = true
        done = false
        doneNote = ""
        failure = nil
        stages = []
        let xcrun = devices.xcrun, device = devices.installDevice, runner = runner
        DispatchQueue.global(qos: .userInitiated).async {
            let link = ShellInstall.connection(of: device, in: DeviceTools.devices(xcrun: xcrun, timeout: 20, runner: runner))
            hop {
                self.installPhaseActive = false
                self.running = false
                if self.stopping {
                    self.fastRefreshActive = false
                    self.fastRefreshTitleID = nil
                    self.fastRefreshBaseDir = nil
                    self.fastRefreshGameName = nil
                    self.fastRefreshExternalImgPath = nil
                    self.skipStaleCheckForQueuedEntry = false
                    self.stopping = false
                    self.doneNote = self.t("msg.stopped")
                    return
                }
                if link == .notPaired {
                    self.fastRefreshActive = false
                    self.fastRefreshTitleID = nil
                    self.fastRefreshBaseDir = nil
                    self.fastRefreshGameName = nil
                    self.fastRefreshExternalImgPath = nil
                    self.skipStaleCheckForQueuedEntry = false
                    self.failure = BuildFailure(kind: .devicePairing, gameName: nil)
                    self.doneNote = String(format: self.t("shell.notPaired"), self.devices.deviceName(device))
                    return
                }
                self.shellDeviceChecked = true
                if let resume { resume() } else { self.runBuild() }
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
