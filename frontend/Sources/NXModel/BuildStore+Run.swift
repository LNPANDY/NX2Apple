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
        queuedSeparateRomfs = nil
        activeSeparateRomfsBuild = false
        activeQueueEntryUpstream = nil
        queuedIOSSeenShaders = nil
        queuedAutoFetchCheats = nil
        clearInstallRecovery(includeFastRefresh: true)
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
        activeRunStartedAt = Date()
        activeRunRebuiltShaders = false
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
        shellUpdatedOnDevice = false
        exportedIPAPath = ""
        clearSeparateRomfsState()
        if !deferShellPackaging {
            needsReplaceOldImgReminder = false
            updatedImgPath = ""
        }
        send = .idle
        lastRunWasFastRefresh = false
        installRecovery.lastFastRefresh = nil
        activeBuildUpstream = buildUpstream
        mngRun = false
        s2armRun = false
        s2armEventsPath = ""
        nxkitRun = false
        nxkitFeedback = nil   // the last build's question goes with its result (#1460)
        seedBuildPlan()
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
            let appFolder = nxnativeWorkDirectory(baseOut: outDir.isEmpty ? inputFolder : outDir, tidHex: tidHex, upstream: .nxkit)
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
            let macOutput = MacAppOutput(workDir: URL(fileURLWithPath: appFolder), key: tidHex, titleID: gameTitleID, upstream: .nxkit, preferred: macAppPath)
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
        let isVariant = isNxnativeVariantSelected
        let engineRoot = activeNxnativeEngineRoot()
        let capabilityDir = isVariant ? engineRoot : repo.path
        if isVariant {
            if let problem = validateNxnativeVariantBeforeBuild(engineRoot: engineRoot) {
                fail(problem)
                return
            }
            if buildUpstream == .kidWithSword && target == BuildTarget.mac {
                if KidWithSwordCompat.ensureMacPackCompatibility(in: engineRoot) {
                    say("Applied macOS launcher compatibility guard for Kid with Sword (MicTesterView)")
                }
            }
            if buildUpstream == .noLagKart && target == BuildTarget.mac {
                if NoLagKartCompat.ensureMacMakefileCompatibility(in: engineRoot) {
                    say("Applied macOS Makefile compatibility guard for No Lag Kart (quoted PGO profile path)")
                }
            }
        } else {
            guard repo.isRepo else {
                fail(repo.path.isEmpty ? t("msg.repoInvalidEmpty") : String(format: t("msg.repoInvalid"), shortPath(repo.path)))
                return
            }
        }
        // Resolve the interpreter safely while rejecting stale cross-upstream caches and MNG's uv-python.
        let py = resolveBuildPython()
        // engine/ is the only engine and is stale or missing (#214): make it, then start again
        if !isVariant && EngineLayout.needsSyncBeforeBuild(repo.path) {
            _ = self.engine.syncEngine { ok in
                self.running = false
                if ok && !EngineLayout.needsSyncBeforeBuild(self.repo.path) { self.runBuild() }
                else { self.fail(String(format: self.t("msg.toolsOld"), "engine/ (python3 tools/engine.py sync, see the log)")) }
            }
            return
        }
        // The tools this app runs, before a build that takes an hour finds one missing at its last step (#87)
        let missing = RepoLayout.missingTools(in: capabilityDir, for: isVariant ? buildUpstream : .nxnative)
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
        let workDir = nxnativeWorkDirectory(baseOut: outDir.isEmpty ? baseDir : outDir, tidHex: tidHex)
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
        let hasWorkDir = RepoLayout.supportsWorkDir(capabilityDir)
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
        // A game folder's files are not encrypted: the script ignores -k for it, and the launcher does not ask for the keys.
        var args = [engineRoot + "/" + RepoLayout.buildScript, inputDir] + (folder != nil ? [] : ["-k", keysPath])
        if !isVariant || RepoLayout.supportsProgressJson(capabilityDir) {
            args += ["--progress", "json"]
        }
        if let selectedTitleID { args += ["--title-id", selectedTitleID] }
        // A small env file the pipeline copies into the app bundle (main.m sets one variable per line at boot). Only for an iPhone or
        // iPad build: the in-game menu's words in the launcher's language (GameMenuText, #1129), and the CPU decode of BC textures when
        // the player turned that compatibility switch on (a Mac app runs on this Mac's GPU, which always has BC support).
        var tempEnvURL: URL?
        if target != BuildTarget.mac, (!isVariant || RepoLayout.supportsEnvFile(capabilityDir)) {
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
        // The image of this game the other platform's build left (the iPhone build's games/<id>/romfs.img, the Mac app's, or
        // an existing extract/v*/RomFS.img): the script takes it in place of extracting the RomFS again once it checks out as
        // this version's (#708). A game folder is packed, not extracted.
        if folder == nil, RepoLayout.supportsRomfsFrom(capabilityDir) {
            let effectiveExtractWork = hasWorkDir ? workDir : (inputDir as NSString).appendingPathComponent(tidHex + "_build")
            var reusable = RomFSArchive.reusableImages(
                root: outDir.isEmpty ? baseDir : outDir,
                key: tidHex,
                workDir: effectiveExtractWork,
                macAppPath: macAppPath.isEmpty ? nil : macAppPath
            )
            if let queuedArchive = activeQueuedArchivePath, !queuedArchive.isEmpty,
               let primary = RomFSArchive.primaryImagePath(in: queuedArchive),
               FileManager.default.fileExists(atPath: primary),
               FileManager.default.fileExists(atPath: primary + ".id"),
               !reusable.contains(primary) {
                reusable.append(primary)
            }
            if let extImg = fastRefreshExternalImgPath, !reusable.contains(extImg), FileManager.default.fileExists(atPath: extImg) {
                reusable.append(extImg)
            }
            for image in reusable { args += ["--romfs-from", image] }
        }
        let macApp = target == BuildTarget.mac
        let macOutput = macApp ? MacAppOutput(workDir: URL(fileURLWithPath: workDir), key: tidHex, titleID: gameTitleID, upstream: buildUpstream, preferred: macAppPath) : nil
        oneGameIPAPath = ""
        if exportsOneGame {
            // One game's own IPA (BuildStore+OneGame.swift, #540, #1627)
            oneGameIPAPath = OneGameIPA.path(folder: outDir.isEmpty ? baseDir : outDir, titleID: tidHex, upstream: buildUpstream)
            let variantBundleID = isVariant && RepoLayout.supportsBundleID(capabilityDir)
                ? OneGameIPA.personalBundleID(titleID: tidHex, teamID: devices.signingTeam, upstream: buildUpstream)
                : nil
            let romfsSupported = RepoLayout.supportsRomfsMode(capabilityDir)
            let useSeparateRomfs = usesSeparateRomfsForCurrentBuild && romfsSupported
            activeSeparateRomfsBuild = useSeparateRomfs
            if usesSeparateRomfsForCurrentBuild && !romfsSupported {
                say(String(format: t("msg.toolsOld"), "scripts/build_ipa_from_nsp.py (--romfs)"))
            }
            args += OneGameIPA.arguments(
                ipa: oneGameIPAPath,
                bundleID: variantBundleID,
                separateRomfs: useSeparateRomfs,
                includeRomfsFlag: !isVariant || romfsSupported
            )
        } else if let macOutput {
            macAppPath = ""
            args += ["--platform", "mac-app", "-o", macOutput.builderURL.path]
            if isVariant, RepoLayout.supportsBundleID(capabilityDir),
               let variantBundleID = buildUpstream.personalMacBundleID(titleID: tidHex) {
                args += ["--bundle-id", variantBundleID]
            }
            if shouldPassSeenShaders(forTitleID: gameTitleID ?? tidHex) {
                args += ["--seen-shaders"]
                say(t("msg.seenShadersOn"))
            }
            if RepoLayout.supportsFallbackIcon(capabilityDir) { args += macFallbackIconArguments(tidHex) }
        } else {
            // Only the game's framework: the one shared app is made and signed after the script (installShell)
            args += ShellInstall.buildArguments(workDir: workDir, team: exportsShell ? "" : devices.signingTeam,
                                                gpu: exportsShell ? nil : DeviceGPU.target(udid: devices.installDevice))
        }
        let fetchCheatsEnabled = (queuedAutoFetchCheats ?? autoFetchCheats) && RepoLayout.supportsFetchCheats(capabilityDir)
        if fetchCheatsEnabled {
            args += ["--fetch-cheats"]
            say(t("msg.fetchCheatsOn"))
        }
        if (fetchCheatsEnabled || !macApp),
           RepoLayout.supportsCheatDir(capabilityDir),
           let activeCheatsDir = RepoLayout.cheatsDirForBuild(
               titleID: gameTitleID ?? tidHex,
               autoFetchCheats: fetchCheatsEnabled,
               home: self.home
           ) {
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
        if !oneGameIPAPath.isEmpty { denv.merge(OneGameIPA.environment(separateRomfs: activeSeparateRomfsBuild)) { $1 } }

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
                    let launch = ProcessLaunch(executable: py, arguments: immutableArgs, environment: launchEnv, directory: engineRoot, groupPython: py)
                    self.startBuildProcess(launch: launch, envCleanup: immutableEnvCleanup, macOutput: macOutput)
                }
            }
            return
        }

        let launch = ProcessLaunch(executable: py, arguments: args, environment: denv, directory: engineRoot, groupPython: py)
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
                        self.packArchiveWithOutcome(workDir: self.effectiveWorkDir, titleID: tid) { outcome in
                            if self.deferShellPackaging {
                                self.deferShellPackage(
                                    framework: fw, titleID: tid, name: name, archive: outcome.archiveDir,
                                    didUpdateImg: outcome.didUpdateImg, updatedImgPath: outcome.primaryImgPath
                                )
                            } else if self.exportsFramework {
                                let exportNote = self.t("refreshDone.exportManualReason")
                                self.needsReplaceOldImgReminder = outcome.didUpdateImg
                                self.updatedImgPath = outcome.didUpdateImg ? outcome.primaryImgPath : ""
                                let imgStatus: QueueEntryImgStatus = outcome.didUpdateImg
                                    ? .manualReplace(imgPath: outcome.primaryImgPath, reason: exportNote)
                                    : .unchanged
                                self.queue?.updateImgStatus(entryID: self.activeQueuedEntryID, titleID: tid, imgStatus: imgStatus)
                                self.exportFrameworkBundle(framework: fw, titleID: tid, name: name)
                            } else if self.exportsShell {
                                let exportNote = self.t("refreshDone.exportManualReason")
                                self.needsReplaceOldImgReminder = outcome.didUpdateImg
                                self.updatedImgPath = outcome.didUpdateImg ? outcome.primaryImgPath : ""
                                let imgStatus: QueueEntryImgStatus = outcome.didUpdateImg
                                    ? .manualReplace(imgPath: outcome.primaryImgPath, reason: exportNote)
                                    : .unchanged
                                self.queue?.updateImgStatus(entryID: self.activeQueuedEntryID, titleID: tid, imgStatus: imgStatus)
                                self.exportShell(framework: fw, titleID: tid, name: name)
                            } else {
                                self.installShell(
                                    framework: fw, titleID: tid, name: name, archive: outcome.archiveDir,
                                    didUpdateImg: outcome.didUpdateImg, updatedImgPath: outcome.primaryImgPath
                                )
                            }
                        }
                    }
                } else {
                    self.fastRefreshExternalImgPath = nil
                    self.clearSeparateRomfsState()
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
                let builtTid = (gameTitleID?.isEmpty == false ? gameTitleID! : buildKey)
                await injectMngSharedSaveConfigIfNeeded(app: app, titleID: builtTid)
                guard archiveGeneration == generation, !stopping else { return }
                macAppPath = app.path
                BuiltUpstreamRegistry.record(appPath: app.path, titleID: builtTid, upstream: activeBuildUpstream, home: home)
                say("✓ " + shortPath(app.path))
                await preflight(app)
                guard archiveGeneration == generation else { return }
                done = true
                completeOverallProgress()
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

    /// Runs `verifyShellDevice` before building.
    /// Looks the device up in `devicectl list devices` (in the background), then starts the build, or says how to pair it.
    package func verifyShellDevice(then resume: (() -> Void)? = nil) {
        buildingGame = true
        runningTarget = target
        beginOperation(.building, game: gameName, titleID: gameTitleID, destination: .target)
        activeRunStartedAt = Date()
        activeRunRebuiltShaders = false
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
                    self.failure = nil
                    self.clearInstallRecovery(includeFastRefresh: true)
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
                    if let resume {
                        self.setInstallRecovery(.resumeClosure(resume))
                    }
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
