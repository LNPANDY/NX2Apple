import Foundation
import NXCore

extension BuildStore {
    package var isMacNativeGamesSelected: Bool {
        MacNativeGamesBuilder.featureEnabled && buildUpstream == .macNativeGames
    }

    package var usesExternalUpstreamRepo: Bool {
        (isMacNativeGamesSelected && target == BuildTarget.mac && macNativeGamesInstalled) || (isS2ArmSelected && s2armInstalled)
    }

    func macNativeGamesProblem() -> String? {
        guard isMacNativeGamesSelected else { return nil }
        guard target == BuildTarget.mac else { return t("upstream.mngMacOnly") }
        guard MacNativeGamesBuilder.isUsableTree(macNativeGamesPath) else {
            return macNativeGamesPath.isEmpty ? t("upstream.mngMissing") : String(format: t("upstream.mngInvalid"), shortPath(macNativeGamesPath))
        }
        guard let route = MacNativeGamesBuilder.route(forTitleID: gameTitleID, in: macNativeGamesPath) else {
            return String(format: t("upstream.mngUnsupportedGame"), gameTitleID ?? "")
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
        let workDir = (outDir.isEmpty ? baseDir : outDir) + "/" + tidHex + "_build"
        if cloudFolderCheck(workDir) {
            failure = BuildFailure(kind: .cloudFolder, gameName: nil, detail: workDir)
            fail(failureWhat(failure!))
            return
        }
        guard let route = MacNativeGamesBuilder.route(forTitleID: gameTitleID, in: macNativeGamesPath) else {
            fail(String(format: t("upstream.mngUnsupportedGame"), gameTitleID ?? ""))
            return
        }
        try? FileManager.default.createDirectory(atPath: workDir, withIntermediateDirectories: true)
        let macOutput = MacAppOutput(workDir: URL(fileURLWithPath: workDir), key: tidHex, titleID: gameTitleID, preferred: macAppPath)
        oneGameIPAPath = ""
        macAppPath = ""
        effectiveWorkDir = workDir

        let compressed = ([basePath, updatePath] + dlcPaths).contains {
            let e = ($0 as NSString).pathExtension.lowercased()
            return e == "nsz" || e == "xcz"
        }
        let gameInput = gameFolder?.scriptInput ?? basePath
        let isUnencrypted = gameFolder != nil || (gameInput as NSString).pathExtension.lowercased() == "nup"
        let tree = macNativeGamesPath
        let homeDir = home
        let runner = self.runner
        let gen = archiveGeneration
        let langCode = lang.code
        let installingPyMsg = t("upstream.mngInstallingPython314")
        let generatingFontsMsg = t("upstream.mngGeneratingSharedFonts")
        let installingNszMsg = t("msg.installingNsz")
        let nszFailedFmt = t("msg.nszFailed")
        let py314MissingMsg = t("dep.python.mngMissing")

        Task.detached(priority: .userInitiated) { [weak self] in
            var py = MacNativeGamesBuilder.findMNGPython314(home: homeDir, runner: runner)
            if py == nil {
                hop {
                    self?.beginExternalStage(name: installingPyMsg)
                    self?.say(installingPyMsg)
                }
                let installCmd = MacNativeGamesBuilder.python314InstallCommand(home: homeDir)
                var installEnv = ProxyEnvironment.merged(into: DependencyCheck.installEnvironment())
                installEnv["HOME"] = homeDir
                let ok = runner.runCaptured(installCmd, env: installEnv) { @Sendable line in
                    hop { self?.append(line + "\n") }
                }
                if ok {
                    py = MacNativeGamesBuilder.findMNGPython314(home: homeDir, runner: runner)
                }
                if py != nil {
                    hop { self?.finishExternalStage(name: installingPyMsg) }
                }
            }
            guard let py314 = py else {
                hop {
                    guard let self, self.archiveGeneration == gen else { return }
                    if self.stopping {
                        self.stopping = false
                        self.running = false
                        self.doneNote = self.t("msg.stopped")
                        return
                    }
                    self.fail(py314MissingMsg)
                }
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

            if compressed, !Toolchain.runOK(py314, ["-c", "import nsz"], env: prepEnv, runner: runner) {
                hop {
                    self?.beginExternalStage(name: installingNszMsg)
                    self?.say(installingNszMsg)
                }
                let ok = runner.runCaptured([py314, "-m", "pip", "install", "nsz"], env: prepEnv) { @Sendable line in
                    hop { self?.append(line + "\n") }
                }
                if !ok {
                    hop {
                        guard let self, self.archiveGeneration == gen else { return }
                        self.fail(String(format: nszFailedFmt, py314))
                    }
                    return
                }
                hop { self?.finishExternalStage(name: installingNszMsg) }
            }

            var sharedFontsPath = ""
            if MacNativeGamesBuilder.needsAutoSharedFonts(
                route: route,
                gameInput: gameInput,
                isUnencryptedInput: isUnencrypted,
                workDir: workDir
            ) {
                hop {
                    self?.beginExternalStage(name: generatingFontsMsg)
                    self?.say(generatingFontsMsg)
                }
                let fontsRes = MacNativeGamesBuilder.generateSharedFonts(
                    python: py314,
                    tree: tree,
                    environment: prepEnv,
                    runner: runner,
                    onLine: { line in
                        hop { self?.append(line + "\n") }
                    }
                )
                if let resolvedFonts = fontsRes.path, !resolvedFonts.isEmpty {
                    sharedFontsPath = resolvedFonts
                }
                hop { self?.finishExternalStage(name: generatingFontsMsg) }
            }

            let finalFontsPath = sharedFontsPath
            hop {
                guard let self, self.archiveGeneration == gen else { return }
                if self.stopping {
                    self.stopping = false
                    self.running = false
                    self.doneNote = self.t("msg.stopped")
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
                    environment: denv
                ) else {
                    self.fail(String(format: self.t("upstream.mngUnsupportedGame"), self.gameTitleID ?? ""))
                    return
                }
                self.startBuildProcess(launch: launch, envCleanup: nil, macOutput: macOutput)
            }
        }
    }

    func macNativeGamesLaunch(
        python py: String,
        workDir: String,
        outputAppPath: String,
        sharedFontsPath: String = "",
        environment: [String: String]
    ) -> ProcessLaunch? {
        guard let route = MacNativeGamesBuilder.route(forTitleID: gameTitleID, in: macNativeGamesPath) else { return nil }
        let gameInput = gameFolder?.scriptInput ?? basePath
        let unencrypted = gameFolder != nil || (gameInput as NSString).pathExtension.lowercased() == "nup"
        let effectiveUpdatePath = unencrypted ? "" : updatePath
        let effectiveDlcPaths = unencrypted ? [] : dlcPaths
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
