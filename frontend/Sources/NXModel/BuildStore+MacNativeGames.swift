import Foundation
import NXCore

@MainActor private final class HintedTitleIDBox {
    var titleID: String?
    var boundBasePath: String = ""
    var boundGameFolderInput: String?
}

@MainActor private let hintedTitleIDBoxes = NSMapTable<BuildStore, HintedTitleIDBox>.weakToStrongObjects()

extension BuildStore {
    /// Fallback 16-hex title ID supplied by a Library or Queue entry when the base filename has no `[TitleID]`.
    package var hintedTitleID: String? {
        get { effectiveHintedTitleID }
        set {
            let normalized = MacNativeGamesBuilder.normalizedHex16(newValue)
            let box: HintedTitleIDBox
            if let existing = hintedTitleIDBoxes.object(forKey: self) {
                box = existing
            } else {
                box = HintedTitleIDBox()
                hintedTitleIDBoxes.setObject(box, forKey: self)
            }
            let currentFolderInput = gameFolder?.scriptInput
            let changed = box.titleID != normalized
                || (normalized != nil && (box.boundBasePath != basePath || box.boundGameFolderInput != currentFolderInput))
            box.titleID = normalized
            box.boundBasePath = normalized == nil ? "" : basePath
            box.boundGameFolderInput = normalized == nil ? nil : currentFolderInput
            if changed {
                enforceUpstreamForCurrentGame()
            }
        }
    }

    var effectiveHintedTitleID: String? {
        guard let box = hintedTitleIDBoxes.object(forKey: self), let titleID = box.titleID else { return nil }
        let hadBoundInput = !box.boundBasePath.isEmpty || box.boundGameFolderInput != nil
        if hadBoundInput && (box.boundBasePath != basePath || box.boundGameFolderInput != gameFolder?.scriptInput) {
            return nil
        }
        return titleID
    }

    /// Applies a known library/queue title ID (hinting 16-hex IDs and reverting MacNativeGames for non-12/non-hex IDs).
    package func applyKnownTitleID(_ titleID: String?) {
        packageHeaderProbeGeneration &+= 1
        let trimmed = titleID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        hintedTitleID = trimmed.isEmpty ? nil : trimmed
        if !running,
           buildUpstream == .macNativeGames,
           !trimmed.isEmpty,
           !MacNativeGamesBuilder.supportsTitleID(trimmed) {
            buildUpstream = .nxnative
        }
    }

    package var isMacNativeGamesSelected: Bool {
        MacNativeGamesBuilder.featureEnabled && buildUpstream == .macNativeGames
    }

    /// 16-hex uppercase title ID for the currently chosen game, nil when no game is chosen or its title ID is unknown.
    package var detectedGameTitleID16: String? {
        MacNativeGamesBuilder.normalizedHex16(gameTitleID)
    }

    /// True when the single-game Build form currently holds a selected package or game folder.
    package var hasSelectedGameInput: Bool {
        !basePath.isEmpty || gameFolder != nil
    }

    /// True when a queue entry is eligible for MacNativeGames (Mac target, not fast refresh, in the 12-title allowlist).
    package static func canQueueEntryUseMNG(_ entry: QueueEntry) -> Bool {
        guard !entry.fastRefresh else { return false }
        guard BuildTarget.normalized(entry.target) == BuildTarget.mac else { return false }
        return MacNativeGamesBuilder.supportsTitleID(entry.titleID)
    }

    /// True when the staged build queue holds any waiting entry that MacNativeGames cannot build.
    package var isMNGBlockedByQueuedBuilds: Bool {
        if activeQueueEntryUpstream == .macNativeGames {
            return false
        }
        if queueBlocksMNG {
            return true
        }
        guard let queued = queue?.queued, !queued.isEmpty else { return false }
        return queued.contains { !Self.canQueueEntryUseMNG($0) }
    }

    /// True when the active game has a recognized 16-hex title ID among the 12 MacNativeGames-supported titles.
    package var isCurrentGameMNGSupported: Bool {
        detectedGameTitleID16.map { MacNativeGamesBuilder.supportsTitleID($0) } ?? false
    }

    /// Default-Deny: once any single-game input is selected, MNG is allowed only when a recognized 16-hex title ID
    /// belongs to the 12 supported titles. Any incompatible queued entry also blocks MNG selection.
    /// Only pure empty state (no input selected and no incompatible waiting queue entries) permits MNG.
    package var isMNGBlockedByCurrentGame: Bool {
        if isMNGBlockedByQueuedBuilds {
            return true
        }
        if let tid = detectedGameTitleID16 {
            return !MacNativeGamesBuilder.supportsTitleID(tid)
        }
        return hasSelectedGameInput
    }

    /// Localized reason key explaining why MacNativeGames is currently disabled in the engine switcher.
    package var mngBlockedReasonKey: String {
        isMNGBlockedByQueuedBuilds ? "upstream.mngBlockedByQueue" : "upstream.mngOnlyFiveTitles"
    }

    /// True when Builds should show the lightweight MacNativeGames recommendation banner under the engine switcher.
    package var shouldRecommendMacNativeGames: Bool {
        MacNativeGamesBuilder.featureEnabled && !running && buildUpstream == .nxnative && !isMNGBlockedByQueuedBuilds && isCurrentGameMNGSupported
    }

    /// Reads the NCA header title ID off the main thread when a renamed package has no `[TitleID]` in its filename,
    /// revalidating that `basePath` and `gameFolder` did not change before writing back `hintedTitleID`.
    package func probeBasePackageTitleIDIfNeeded() {
        packageHeaderProbeGeneration &+= 1
        let gen = packageHeaderProbeGeneration
        guard gameFolder == nil else { return }
        let capturedBase = basePath
        guard !capturedBase.isEmpty else { return }
        guard TitleID.parse(capturedBase) == nil else { return }
        guard effectiveHintedTitleID == nil else { return }
        let capturedKeys = keysPath
        guard !capturedKeys.isEmpty else { return }
        let reader = readPackageTitleID
        Task.detached(priority: .userInitiated) { [weak self] in
            let resolved = reader(capturedBase, capturedKeys)
            hop {
                guard let self,
                      self.packageHeaderProbeGeneration == gen,
                      self.gameFolder == nil,
                      self.basePath == capturedBase,
                      TitleID.parse(self.basePath) == nil,
                      self.effectiveHintedTitleID == nil else { return }
                if let resolved, let normalized = MacNativeGamesBuilder.normalizedHex16(resolved) {
                    self.hintedTitleID = normalized
                }
            }
        }
    }

    func nszFailureMessage(_ failure: NszInstallFailureKind, python: String) -> String {
        switch failure {
        case .pep668:
            return String(format: t("msg.nszFailedPEP668"), python)
        case .permissionDenied:
            return String(format: t("msg.nszFailedPermission"), shortPath(Toolchain.nszVenvDir(home: home)))
        case .network:
            return t("msg.nszFailedNetwork")
        case .other:
            return String(format: t("msg.nszFailed"), python)
        }
    }

    /// Auto-reverts from MacNativeGames back to nxnative whenever a recognized unsupported game is selected.
    package func enforceUpstreamForCurrentGame() {
        if let box = hintedTitleIDBoxes.object(forKey: self), box.titleID != nil {
            let hadBoundInput = !box.boundBasePath.isEmpty || box.boundGameFolderInput != nil
            if hadBoundInput && (box.boundBasePath != basePath || box.boundGameFolderInput != gameFolder?.scriptInput) {
                box.titleID = nil
                box.boundBasePath = ""
                box.boundGameFolderInput = nil
            }
        }
        guard !running else { return }
        if buildUpstream == .macNativeGames && isMNGBlockedByCurrentGame {
            buildUpstream = .nxnative
        }
    }

    /// Switches to MacNativeGames for the current supported game, setting target to Mac automatically.
    package func switchToMacNativeGamesForCurrentGame() {
        guard !running, MacNativeGamesBuilder.featureEnabled, !isMNGBlockedByCurrentGame else { return }
        selectUpstream(.macNativeGames)
    }

    /// Switches to MacNativeGames when already installed, otherwise starts downloading and auto-switches on completion.
    package func downloadAndSwitchToMacNativeGames() {
        guard !running, MacNativeGamesBuilder.featureEnabled, !isMNGBlockedByCurrentGame else { return }
        if macNativeGamesInstalled {
            selectUpstream(.macNativeGames)
        } else {
            _ = downloadUpstream(.macNativeGames)
        }
    }

    package var usesExternalUpstreamRepo: Bool {
        (isMacNativeGamesSelected && target == BuildTarget.mac && macNativeGamesInstalled) || (isS2ArmSelected && s2armInstalled) || (isNxkitSelected && nxkitInstalled)
    }

    func macNativeGamesProblem() -> String? {
        guard isMacNativeGamesSelected else { return nil }
        guard target == BuildTarget.mac else { return t("upstream.mngMacOnly") }
        guard MacNativeGamesBuilder.isUsableTree(macNativeGamesPath) else {
            return macNativeGamesPath.isEmpty ? t("upstream.mngMissing") : String(format: t("upstream.mngInvalid"), shortPath(macNativeGamesPath))
        }
        guard let route = MacNativeGamesBuilder.route(forTitleID: gameTitleID, in: macNativeGamesPath) else {
            let label = gameTitleID.flatMap { $0.isEmpty ? nil : $0 }
                ?? (basePath.isEmpty ? t("upstream.notSelected") : (basePath as NSString).lastPathComponent)
            return String(format: t("upstream.mngUnsupportedGame"), label)
        }
        let script = MacNativeGamesBuilder.scriptPath(for: route, in: macNativeGamesPath)
        guard FileManager.default.fileExists(atPath: script) else {
            return String(format: t("msg.toolsOld"), (script as NSString).lastPathComponent)
        }
        return nil
    }

    func startMacNativeGamesBuild() {
        if let why = macNativeGamesProblem() {
            fail(why)
            return
        }
        mngRun = true
        let baseDir = inputFolder
        let tidHex = buildKey
        let resolvedTitleID = gameTitleID
        let outputRoot = outDir.isEmpty ? baseDir : outDir
        let workDir = outputRoot + "/" + tidHex + "_build"
        if cloudFolderCheck(workDir) {
            failure = BuildFailure(kind: .cloudFolder, gameName: nil, detail: workDir)
            fail(failureWhat(failure!))
            return
        }
        guard let route = MacNativeGamesBuilder.route(forTitleID: resolvedTitleID, in: macNativeGamesPath) else {
            fail(String(format: t("upstream.mngUnsupportedGame"), resolvedTitleID ?? ""))
            return
        }
        try? FileManager.default.createDirectory(atPath: workDir, withIntermediateDirectories: true)
        // Keep first-build `-o` outside `--work` (required by games/tmnt/build.py: --out and --work must be separate).
        let stageDir = URL(fileURLWithPath: outputRoot + "/" + tidHex + "_stage")
        let macOutput = MacAppOutput(
            workDir: URL(fileURLWithPath: workDir),
            key: tidHex,
            titleID: resolvedTitleID,
            preferred: macAppPath,
            stagingDirectory: stageDir
        )
        oneGameIPAPath = ""
        macAppPath = ""
        effectiveWorkDir = workDir

        let gameInput = gameFolder?.scriptInput ?? basePath
        let isUnencrypted = gameFolder != nil || (gameInput as NSString).pathExtension.lowercased() == "nup"
        let currentKeys = keysPath
        let currentUpdate = isUnencrypted ? "" : updatePath
        let currentDLCs = isUnencrypted ? [] : dlcPaths
        let needsPreDecompress = !isUnencrypted && ([gameInput, currentUpdate] + currentDLCs).contains {
            !$0.isEmpty && MacNativeGamesBuilder.needsPreDecompress(route: route, path: $0)
        }
        let tree = macNativeGamesPath
        let homeDir = home
        let runner = self.runner
        let gen = archiveGeneration
        let langCode = lang.code
        let installingPyMsg = t("upstream.mngInstallingPython314")
        let generatingFontsMsg = t("upstream.mngGeneratingSharedFonts")
        let installingNszMsg = t("msg.installingNsz")
        let unpackingNszMsg = t("upstream.mngUnpackingNsz")
        let decompressFailedFmt = t("msg.nszDecompressFailed")
        let py314MissingMsg = t("dep.python.mngMissing")
        let cancel = installCancel
        installCancel.set(false)
        installPhaseActive = true

        Task.detached(priority: .userInitiated) { [weak self] in
            if cancel.value {
                hop { self?.finishStoppedExternalPrepIfCurrent(gen) }
                return
            }
            var py = MacNativeGamesBuilder.findMNGPython314(home: homeDir, runner: runner)
            if py == nil {
                if cancel.value {
                    hop { self?.finishStoppedExternalPrepIfCurrent(gen) }
                    return
                }
                hop {
                    guard let self, self.archiveGeneration == gen, !self.stopping, !self.installCancel.value else { return }
                    self.beginExternalStage(name: installingPyMsg)
                    self.say(installingPyMsg)
                }
                let installCmd = MacNativeGamesBuilder.python314InstallCommand(home: homeDir)
                var installEnv = ProxyEnvironment.merged(into: DependencyCheck.installEnvironment())
                installEnv["HOME"] = homeDir
                let ok = runner.runCaptured(installCmd, env: installEnv) { @Sendable line in
                    hop {
                        guard let self, self.archiveGeneration == gen, !self.stopping, !self.installCancel.value else { return }
                        self.append(line + "\n")
                    }
                }
                if cancel.value {
                    hop { self?.finishStoppedExternalPrepIfCurrent(gen) }
                    return
                }
                if ok {
                    py = MacNativeGamesBuilder.findMNGPython314(home: homeDir, runner: runner)
                }
                if py != nil {
                    hop {
                        guard let self, self.archiveGeneration == gen, !self.stopping, !self.installCancel.value else { return }
                        self.finishExternalStage(name: installingPyMsg)
                    }
                }
            }
            guard let py314 = py else {
                hop {
                    guard let self, self.archiveGeneration == gen else { return }
                    self.installPhaseActive = false
                    if self.stopping || self.installCancel.value {
                        self.finishStoppedExternalPrep()
                        return
                    }
                    self.fail(py314MissingMsg)
                }
                return
            }
            if cancel.value {
                hop { self?.finishStoppedExternalPrepIfCurrent(gen) }
                return
            }

            let workTmp = workDir + "/.tmp"
            let effectiveTmpDir: String
            if (try? FileManager.default.createDirectory(atPath: workTmp, withIntermediateDirectories: true)) != nil,
               FileManager.default.fileExists(atPath: workTmp) {
                effectiveTmpDir = workTmp
            } else {
                effectiveTmpDir = NSTemporaryDirectory()
            }

            let pyBin = (py314 as NSString).deletingLastPathComponent
            let basePathEnv = BuildCommands.toolPath(python: py314)
            let mergedPath = pyBin.isEmpty ? basePathEnv : (pyBin + ":" + basePathEnv)
            let prepEnv: [String: String] = ProxyEnvironment.merged(into: [
                "PATH": mergedPath,
                "HOME": homeDir,
                "LANG": "en_US.UTF-8",
                "TMPDIR": effectiveTmpDir,
            ].merging(BundledTools.environment(for: py314)) { $1 }
             .merging(MacNativeGamesBuilder.environment(languageCode: langCode)) { $1 })

            var effectiveGameInput = gameInput
            var effectiveUpdatePath = currentUpdate
            var effectiveDlcPaths = currentDLCs

            // Never mutate uv-managed Python 3.14 with bare `pip install nsz` (PEP 668).
            // Pre-decompress compressed containers in an isolated app-managed nsz-venv only when the route needs it.
            if needsPreDecompress {
                if cancel.value {
                    hop { self?.finishStoppedExternalPrepIfCurrent(gen) }
                    return
                }
                let alreadyReady = Toolchain.readyManagedNszTool(
                    venvDir: Toolchain.nszVenvDir(home: homeDir),
                    environment: prepEnv,
                    runner: runner
                ) != nil
                if !alreadyReady {
                    hop {
                        guard let self, self.archiveGeneration == gen, !self.stopping, !self.installCancel.value else { return }
                        self.beginExternalStage(name: installingNszMsg)
                        self.say(installingNszMsg)
                    }
                }
                let toolResult = Toolchain.ensureManagedNszTool(
                    preferredPython: py314,
                    home: homeDir,
                    runner: runner,
                    cancel: cancel,
                    onLine: { line in
                        hop {
                            guard let self, self.archiveGeneration == gen, !self.stopping, !self.installCancel.value else { return }
                            self.append(line + "\n")
                        }
                    }
                )
                if cancel.value {
                    hop { self?.finishStoppedExternalPrepIfCurrent(gen) }
                    return
                }
                let nszTool: ManagedNszTool
                switch toolResult {
                case .success(let readyTool):
                    nszTool = readyTool
                    if !alreadyReady {
                        hop {
                            guard let self, self.archiveGeneration == gen, !self.stopping, !self.installCancel.value else { return }
                            self.finishExternalStage(name: installingNszMsg)
                        }
                    }
                case .failure(let err):
                    hop {
                        guard let self, self.archiveGeneration == gen else { return }
                        self.installPhaseActive = false
                        if self.stopping || self.installCancel.value {
                            self.finishStoppedExternalPrep()
                            return
                        }
                        self.fail(self.nszFailureMessage(err, python: py314))
                    }
                    return
                }

                hop {
                    guard let self, self.archiveGeneration == gen, !self.stopping, !self.installCancel.value else { return }
                    self.beginExternalStage(name: unpackingNszMsg)
                    self.say(unpackingNszMsg)
                }

                func unpackOne(_ path: String) -> Result<String, NszUnpackError> {
                    guard !path.isEmpty, MacNativeGamesBuilder.needsPreDecompress(route: route, path: path) else {
                        return .success(path)
                    }
                    return Toolchain.unpackCompressedPackage(
                        input: path,
                        keysPath: currentKeys,
                        workDir: workDir,
                        tool: nszTool,
                        environment: prepEnv,
                        runner: runner,
                        cancel: cancel,
                        onLine: { line in
                            hop {
                                guard let self, self.archiveGeneration == gen, !self.stopping, !self.installCancel.value else { return }
                                self.append(line + "\n")
                            }
                        }
                    )
                }

                switch unpackOne(effectiveGameInput) {
                case .success(let unpacked):
                    effectiveGameInput = unpacked
                case .failure(let err):
                    hop {
                        guard let self, self.archiveGeneration == gen else { return }
                        self.installPhaseActive = false
                        if self.stopping || self.installCancel.value {
                            self.finishStoppedExternalPrep()
                            return
                        }
                        self.fail(String(format: decompressFailedFmt, err.message))
                    }
                    return
                }

                if !effectiveUpdatePath.isEmpty {
                    switch unpackOne(effectiveUpdatePath) {
                    case .success(let unpacked):
                        effectiveUpdatePath = unpacked
                    case .failure(let err):
                        hop {
                            guard let self, self.archiveGeneration == gen else { return }
                            self.installPhaseActive = false
                            if self.stopping || self.installCancel.value {
                                self.finishStoppedExternalPrep()
                                return
                            }
                            self.fail(String(format: decompressFailedFmt, err.message))
                        }
                        return
                    }
                }

                var unpackedDLCs: [String] = []
                for dlc in effectiveDlcPaths {
                    switch unpackOne(dlc) {
                    case .success(let unpacked):
                        unpackedDLCs.append(unpacked)
                    case .failure(let err):
                        hop {
                            guard let self, self.archiveGeneration == gen else { return }
                            self.installPhaseActive = false
                            if self.stopping || self.installCancel.value {
                                self.finishStoppedExternalPrep()
                                return
                            }
                            self.fail(String(format: decompressFailedFmt, err.message))
                        }
                        return
                    }
                }
                effectiveDlcPaths = unpackedDLCs

                hop {
                    guard let self, self.archiveGeneration == gen, !self.stopping, !self.installCancel.value else { return }
                    self.finishExternalStage(name: unpackingNszMsg)
                }
            }

            if cancel.value {
                hop { self?.finishStoppedExternalPrepIfCurrent(gen) }
                return
            }
            var sharedFontsPath = ""
            if MacNativeGamesBuilder.needsAutoSharedFonts(
                route: route,
                titleID: resolvedTitleID,
                gameInput: effectiveGameInput,
                isUnencryptedInput: isUnencrypted,
                workDir: workDir
            ) {
                hop {
                    guard let self, self.archiveGeneration == gen, !self.stopping, !self.installCancel.value else { return }
                    self.beginExternalStage(name: generatingFontsMsg)
                    self.say(generatingFontsMsg)
                }
                let fontsRes = MacNativeGamesBuilder.generateSharedFonts(
                    python: py314,
                    tree: tree,
                    environment: prepEnv,
                    runner: runner,
                    onLine: { line in
                        hop {
                            guard let self, self.archiveGeneration == gen, !self.stopping, !self.installCancel.value else { return }
                            self.append(line + "\n")
                        }
                    }
                )
                if cancel.value {
                    hop { self?.finishStoppedExternalPrepIfCurrent(gen) }
                    return
                }
                if let resolvedFonts = fontsRes.path, !resolvedFonts.isEmpty {
                    sharedFontsPath = resolvedFonts
                }
                hop {
                    guard let self, self.archiveGeneration == gen, !self.stopping, !self.installCancel.value else { return }
                    self.finishExternalStage(name: generatingFontsMsg)
                }
            }

            let finalFontsPath = sharedFontsPath
            let finalGameInput = effectiveGameInput
            let finalUpdatePath = effectiveUpdatePath
            let finalDlcPaths = effectiveDlcPaths
            hop {
                guard let self, self.archiveGeneration == gen else { return }
                self.installPhaseActive = false
                if self.stopping || self.installCancel.value {
                    self.finishStoppedExternalPrep()
                    return
                }
                var denv = self.toolEnvironment(python: py314)
                denv["TMPDIR"] = effectiveTmpDir
                if !pyBin.isEmpty {
                    let curPath = denv["PATH"] ?? mergedPath
                    if !curPath.split(separator: ":").contains(Substring(pyBin)) {
                        denv["PATH"] = pyBin + ":" + curPath
                    }
                }
                guard let launch = self.macNativeGamesLaunch(
                    python: py314,
                    workDir: workDir,
                    outputAppPath: macOutput.builderURL.path,
                    sharedFontsPath: finalFontsPath,
                    gameInputOverride: finalGameInput,
                    updatePathOverride: finalUpdatePath,
                    dlcPathsOverride: finalDlcPaths,
                    environment: denv
                ) else {
                    self.fail(String(format: self.t("upstream.mngUnsupportedGame"), self.gameTitleID ?? ""))
                    return
                }
                if let stagingDir = macOutput.stagingDirectoryURL {
                    try? FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
                }
                self.startBuildProcess(launch: launch, envCleanup: nil, macOutput: macOutput)
            }
        }
    }

    func finishStoppedExternalPrepIfCurrent(_ gen: Int) {
        guard archiveGeneration == gen else { return }
        finishStoppedExternalPrep()
    }

    func finishStoppedExternalPrep() {
        installPhaseActive = false
        stopping = false
        running = false
        resetProgress()
        cleanupStaging()
        doneNote = t("msg.stopped")
    }

    func macNativeGamesLaunch(
        python py: String,
        workDir: String,
        outputAppPath: String,
        sharedFontsPath: String = "",
        gameInputOverride: String? = nil,
        updatePathOverride: String? = nil,
        dlcPathsOverride: [String]? = nil,
        environment: [String: String]
    ) -> ProcessLaunch? {
        guard let route = MacNativeGamesBuilder.route(forTitleID: gameTitleID, in: macNativeGamesPath) else { return nil }
        let gameInput = gameInputOverride ?? (gameFolder?.scriptInput ?? basePath)
        let unencrypted = gameFolder != nil || (gameInput as NSString).pathExtension.lowercased() == "nup"
        let effectiveUpdatePath = unencrypted ? "" : (updatePathOverride ?? updatePath)
        let effectiveDlcPaths = unencrypted ? [] : (dlcPathsOverride ?? dlcPaths)
        let args = MacNativeGamesBuilder.arguments(
            route: route,
            tree: macNativeGamesPath,
            gameInput: gameInput,
            keysPath: keysPath,
            isUnencryptedInput: unencrypted,
            updatePath: effectiveUpdatePath,
            dlcPaths: effectiveDlcPaths,
            outputAppPath: outputAppPath,
            workDir: workDir,
            sharedFontsPath: sharedFontsPath
        )
        say(String(format: t("msg.running"), py) + " " + args.joined(separator: " "))
        lastBuildCommand = [py] + args
        let mergedEnv = environment.merging(MacNativeGamesBuilder.environment(languageCode: lang.code)) { $1 }
        return ProcessLaunch(executable: py, arguments: args, environment: mergedEnv, directory: macNativeGamesPath, groupPython: py)
    }

    func macNativeGamesFailureNote(status: Int32) -> String {
        if let line = MacNativeGamesBuilder.lastError(in: logTail) {
            return String(format: t("msg.buildFailedReason"), line)
        }
        return String(format: t("msg.buildFailed"), status)
    }

    func beginExternalStage(name: String, total: Int? = nil, detail: String = "") {
        for idx in stages.indices where stages[idx].state == .running {
            stages[idx].state = .done
            stages[idx].percent = 100
        }
        if let existing = stages.firstIndex(where: { $0.name == name }) {
            stages[existing].state = .running
            stages[existing].started = Date()
            if !detail.isEmpty { stages[existing].detail = detail }
            stages[existing].percent = nil
        } else {
            let nextID = (stages.map(\.id).max() ?? 0) + 1
            stages.append(Stage(id: nextID, name: name, state: .running, detail: detail, percent: nil, started: Date()))
        }
        refreshOverallProgress(parsedTotal: total)
    }

    func finishExternalStage(name: String, detail: String = "") {
        if let idx = stages.lastIndex(where: { $0.name == name }) {
            stages[idx].state = .done
            stages[idx].percent = 100
            if !detail.isEmpty { stages[idx].detail = detail }
        } else if let idx = stages.lastIndex(where: { $0.state == .running }) {
            stages[idx].state = .done
            stages[idx].percent = 100
            if !detail.isEmpty { stages[idx].detail = detail }
        }
        refreshOverallProgress(parsedTotal: nil)
    }

    func handleExternalUpstreamLogLine(_ line: String) {
        if mngRun, let parsed = MacNativeGamesBuilder.parseStageLine(line) {
            beginExternalStage(name: "\(parsed.index)/\(parsed.total) \(parsed.name)", total: parsed.total)
            return
        }
        if s2armRun, let event = S2ArmBuilder.parseStageEvent(line) {
            if event.finished {
                finishExternalStage(name: event.name, detail: event.detail)
            } else {
                beginExternalStage(name: event.name)
            }
        }
    }
}
