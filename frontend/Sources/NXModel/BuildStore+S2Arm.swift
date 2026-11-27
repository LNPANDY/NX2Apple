import Foundation
import NXCore

extension BuildStore {
    package var isS2ArmSelected: Bool {
        S2ArmBuilder.featureEnabled && buildUpstream == .s2arm
    }

    func s2armProblem() -> String? {
        guard isS2ArmSelected else { return nil }
        guard S2ArmBuilder.isUsableTree(s2armPath) else {
            return s2armPath.isEmpty ? t("upstream.s2armMissing") : String(format: t("upstream.s2armInvalid"), shortPath(s2armPath))
        }
        return nil
    }

    func startS2ArmBuild() {
        if let why = s2armProblem() {
            fail(why)
            return
        }
        s2armRun = true
        let initialPy = resolveBuildPython(includeS2Arm: true)
        let baseDir = inputFolder
        let tidHex = buildKey
        let workDir = nxnativeWorkDirectory(baseOut: outDir.isEmpty ? baseDir : outDir, tidHex: tidHex, upstream: .s2arm)
        if cloudFolderCheck(workDir) {
            failure = BuildFailure(kind: .cloudFolder, gameName: nil, detail: workDir)
            fail(failureWhat(failure!))
            return
        }
        let folder = gameFolder
        let allPaths = folder != nil ? [] : [basePath, updatePath] + dlcPaths
        let dirs = Set(allPaths.filter { !$0.isEmpty }.map { ($0 as NSString).deletingLastPathComponent })
        let picked = Set(allPaths.filter { !$0.isEmpty }.map { ($0 as NSString).lastPathComponent })
        let unpicked = folder != nil ? [] : ((try? FileManager.default.contentsOfDirectory(atPath: baseDir)) ?? []).filter {
            ["nsp", "xci", "nsz", "xcz"].contains(($0 as NSString).pathExtension.lowercased()) && !picked.contains($0)
        }
        var staged = allPaths
        if folder == nil, let base = selectedTitleID.flatMap({ UInt64($0, radix: 16) }) ?? TitleID.parse(basePath) {
            let app = base & ~0xFFF
            for f in unpicked {
                guard let tid = TitleID.parse(f) else { continue }
                let low = tid & 0xFFF
                let owner = low == 0 ? tid : (low == 0x800 ? tid & ~0xFFF : (tid & ~0xFFF) - 0x1000)
                guard owner == app else { continue }
                if low == 0x800 && !updatePath.isEmpty { continue }
                if low != 0 && low != 0x800 && tid <= app { continue }
                staged.append(baseDir + "/" + f)
            }
        }
        var sourceInput = folder?.scriptInput ?? baseDir
        let isUnencrypted = folder != nil
            || (sourceInput as NSString).pathExtension.lowercased() == "nup"
            || (basePath as NSString).pathExtension.lowercased() == "nup"
        if folder == nil && (dirs.count > 1 || !unpicked.isEmpty || staged.contains(where: InputStaging.needsLowercaseName)) {
            let tmp = InputStaging.folder(workDir: workDir)
            let linked = InputStaging.sync(files: staged, into: tmp)
            if linked == 0 {
                fail(t("msg.stagingFailed"))
                return
            }
            staging = tmp
            sourceInput = tmp
            if !unpicked.isEmpty {
                say(String(format: t("msg.stagedFromSharedFolder"), (basePath as NSString).lastPathComponent))
            }
        } else {
            let resolved = S2ArmBuilder.resolveSourceDirectory(sourceInput, workDir: workDir)
            if resolved.stagingFailed {
                fail(t("msg.stagingFailed"))
                return
            }
            sourceInput = resolved.directory
            staging = resolved.stagedDirectory
        }

        try? FileManager.default.createDirectory(atPath: workDir, withIntermediateDirectories: true)
        s2armEventsPath = workDir + "/s2a-events.jsonl"
        effectiveWorkDir = workDir
        oneGameIPAPath = ""
        macAppPath = ""
        clearSeparateRomfsState()

        let finalSourceInput = sourceInput
        let eventsFile = s2armEventsPath
        let tree = s2armPath
        let homeDir = home
        let runner = self.runner
        let gen = archiveGeneration
        let baseEnv = toolEnvironment(python: initialPy)
        let installPyMsg = t("upstream.s2armInstallingPythonDeps")
        let installDotnetMsg = t("upstream.s2armInstallingDotnet")
        let installBashMsg = t("upstream.s2armInstallingBash")
        let prepRewriterDepsMsg = t("upstream.s2armPreparingRewriterDeps")
        let prepShaderToolsMsg = t("upstream.s2armPreparingShaderTools")
        let dotnetMissingFmt = t("dep.dotnet.s2armMissing")
        let pyMissingFmt = t("dep.python.s2armMissing")
        let buildFailedReasonFmt = t("msg.buildFailedReason")
        let cancel = installCancel
        installCancel.set(false)
        installPhaseActive = true

        Task.detached(priority: .userInitiated) { [weak self] in
            if cancel.value {
                hop { self?.finishStoppedExternalPrepIfCurrent(gen) }
                return
            }
            var py = initialPy

            // 0. Ensure extracted S2Arm snapshots have a clean single-commit local Git repository
            _ = S2ArmBootstrap.ensureGitRepo(in: tree, runner: runner)
            if cancel.value {
                hop { self?.finishStoppedExternalPrepIfCurrent(gen) }
                return
            }

            // 1. Auto-prepare dedicated `<s2arm>/.venv` matching pinned `requirements*.txt` + cmake/meson/ninja
            let s2armVenvPy = S2ArmBootstrap.venvPython(in: tree)
            if S2ArmBootstrap.isVenvReady(python: s2armVenvPy, tree: tree, runner: runner) {
                py = s2armVenvPy
            } else {
                hop {
                    guard let self, self.archiveGeneration == gen, !self.stopping, !self.installCancel.value else { return }
                    self.beginExternalStage(name: installPyMsg)
                    self.say(installPyMsg)
                }
                let venvRes = S2ArmBootstrap.ensureS2ArmVenv(
                    in: tree,
                    basePython: py,
                    home: homeDir,
                    runner: runner
                ) { @Sendable line in
                    hop {
                        guard let self, self.archiveGeneration == gen, !self.stopping, !self.installCancel.value else { return }
                        self.append(line + "\n")
                    }
                }
                if cancel.value {
                    hop { self?.finishStoppedExternalPrepIfCurrent(gen) }
                    return
                }
                if venvRes.ok {
                    py = venvRes.python
                    hop {
                        guard let self, self.archiveGeneration == gen, !self.stopping, !self.installCancel.value else { return }
                        self.finishExternalStage(name: installPyMsg)
                    }
                } else {
                    let stillMissingPkgs = S2ArmBuilder.missingPythonPackages(python: s2armVenvPy, tree: tree, runner: runner)
                    let stillMissingTools = S2ArmBootstrap.missingVenvBuildTools(python: s2armVenvPy)
                    let remaining = stillMissingPkgs + stillMissingTools
                    let list = (remaining.isEmpty ? S2ArmBootstrap.fallbackPythonSpecs : remaining).joined(separator: ", ")
                    hop {
                        guard let self, self.archiveGeneration == gen else { return }
                        self.installPhaseActive = false
                        if self.stopping || self.installCancel.value {
                            self.finishStoppedExternalPrep()
                            return
                        }
                        self.fail(String(format: pyMissingFmt, list))
                    }
                    return
                }
            }

            if cancel.value {
                hop { self?.finishStoppedExternalPrepIfCurrent(gen) }
                return
            }
            // 2. Auto-prepare official .NET 10 SDK (>= 10.0.403) into $HOME/.dotnet (skipping Homebrew builds)
            let dnCandidates = S2ArmBuilder.dotnetCandidates(home: homeDir)
            var dnRes = S2ArmBuilder.findDotnet(dnCandidates, tree: tree, runner: runner)
            if !dnRes.ok {
                if cancel.value {
                    hop { self?.finishStoppedExternalPrepIfCurrent(gen) }
                    return
                }
                hop {
                    guard let self, self.archiveGeneration == gen, !self.stopping, !self.installCancel.value else { return }
                    self.beginExternalStage(name: installDotnetMsg)
                    self.say(installDotnetMsg)
                }
                var installEnv = ProxyEnvironment.merged(into: DependencyCheck.installEnvironment())
                installEnv["HOME"] = homeDir
                let installCmd = DependencyCheck.dotnetInstallCmd
                _ = runner.runCaptured(installCmd, env: installEnv) { @Sendable line in
                    hop {
                        guard let self, self.archiveGeneration == gen, !self.stopping, !self.installCancel.value else { return }
                        self.append(line + "\n")
                    }
                }
                if cancel.value {
                    hop { self?.finishStoppedExternalPrepIfCurrent(gen) }
                    return
                }
                dnRes = S2ArmBuilder.findDotnet(dnCandidates, tree: tree, runner: runner)
                if !dnRes.ok {
                    let reqVer = dnRes.requiredVersion
                    hop {
                        guard let self, self.archiveGeneration == gen else { return }
                        self.installPhaseActive = false
                        if self.stopping || self.installCancel.value {
                            self.finishStoppedExternalPrep()
                            return
                        }
                        self.fail(String(format: dotnetMissingFmt, reqVer))
                    }
                    return
                }
                hop {
                    guard let self, self.archiveGeneration == gen, !self.stopping, !self.installCancel.value else { return }
                    self.finishExternalStage(name: installDotnetMsg)
                }
            }

            if cancel.value {
                hop { self?.finishStoppedExternalPrepIfCurrent(gen) }
                return
            }
            // 3. Auto-prepare modern GNU Bash (>= 4) and symlink into <s2arm>/.nx2apple-shims/bash
            var modernBash = S2ArmBootstrap.findModernBash(home: homeDir, runner: runner)
            if modernBash == nil {
                if cancel.value {
                    hop { self?.finishStoppedExternalPrepIfCurrent(gen) }
                    return
                }
                hop {
                    guard let self, self.archiveGeneration == gen, !self.stopping, !self.installCancel.value else { return }
                    self.beginExternalStage(name: installBashMsg)
                    self.say(installBashMsg)
                }
                modernBash = S2ArmBootstrap.ensureModernBash(home: homeDir, runner: runner) { @Sendable line in
                    hop {
                        guard let self, self.archiveGeneration == gen, !self.stopping, !self.installCancel.value else { return }
                        self.append(line + "\n")
                    }
                }
                if cancel.value {
                    hop { self?.finishStoppedExternalPrepIfCurrent(gen) }
                    return
                }
                guard modernBash != nil else {
                    hop {
                        guard let self, self.archiveGeneration == gen else { return }
                        self.installPhaseActive = false
                        if self.stopping || self.installCancel.value {
                            self.finishStoppedExternalPrep()
                            return
                        }
                        self.fail(String(format: buildFailedReasonFmt, "Bash 5"))
                    }
                    return
                }
                hop {
                    guard let self, self.archiveGeneration == gen, !self.stopping, !self.installCancel.value else { return }
                    self.finishExternalStage(name: installBashMsg)
                }
            }
            if cancel.value {
                hop { self?.finishStoppedExternalPrepIfCurrent(gen) }
                return
            }
            let resolvedBash = modernBash ?? "/bin/bash"
            let bashShimDir = S2ArmBootstrap.linkBashShim(modernBash: resolvedBash, in: tree)

            // 4. Inject bash shim + dedicated venv bin + DOTNET_ROOT + same-volume TMPDIR
            let workTmp = workDir + "/.tmp"
            let effectiveTmpDir: String
            if (try? FileManager.default.createDirectory(atPath: workTmp, withIntermediateDirectories: true)) != nil,
               FileManager.default.fileExists(atPath: workTmp) {
                effectiveTmpDir = workTmp
            } else {
                effectiveTmpDir = NSTemporaryDirectory()
            }
            let pyBin = (py as NSString).deletingLastPathComponent
            var extraBins: [String] = []
            if let bashShimDir, !bashShimDir.isEmpty { extraBins.append(bashShimDir) }
            if !pyBin.isEmpty { extraBins.append(pyBin) }
            var env = S2ArmBuilder.environmentWithToolPaths(
                base: baseEnv,
                dotnetPath: dnRes.path,
                extraBinDirs: extraBins,
                home: homeDir,
                runner: runner
            )
            env["TMPDIR"] = effectiveTmpDir
            env["SHELL"] = resolvedBash

            if cancel.value {
                hop { self?.finishStoppedExternalPrepIfCurrent(gen) }
                return
            }
            // 5. Auto-prepare <s2arm>/build/rewriter-deps when missing
            let prepareDepsScript = (tree.hasSuffix("/") ? tree : tree + "/") + "runtime/rewriter/prepare_deps.py"
            if !S2ArmBootstrap.isRewriterDepsReady(in: tree),
               FileManager.default.fileExists(atPath: prepareDepsScript) {
                hop {
                    guard let self, self.archiveGeneration == gen, !self.stopping, !self.installCancel.value else { return }
                    self.beginExternalStage(name: prepRewriterDepsMsg)
                    self.say(prepRewriterDepsMsg)
                }
                let depsRes = S2ArmBootstrap.ensureRewriterDeps(
                    in: tree,
                    python: py,
                    environment: env,
                    runner: runner
                ) { @Sendable line in
                    hop {
                        guard let self, self.archiveGeneration == gen, !self.stopping, !self.installCancel.value else { return }
                        self.append(line + "\n")
                    }
                }
                if cancel.value {
                    hop { self?.finishStoppedExternalPrepIfCurrent(gen) }
                    return
                }
                guard depsRes.ok else {
                    hop {
                        guard let self, self.archiveGeneration == gen else { return }
                        self.installPhaseActive = false
                        if self.stopping || self.installCancel.value {
                            self.finishStoppedExternalPrep()
                            return
                        }
                        self.fail(String(format: buildFailedReasonFmt, "S2Arm rewriter-deps"))
                    }
                    return
                }
                hop {
                    guard let self, self.archiveGeneration == gen, !self.stopping, !self.installCancel.value else { return }
                    self.finishExternalStage(name: prepRewriterDepsMsg)
                }
            }
            if S2ArmBootstrap.isRewriterDepsReady(in: tree) {
                env["S2A_REWRITER_DEPS"] = S2ArmBootstrap.rewriterDepsDirectory(in: tree)
            }

            if cancel.value {
                hop { self?.finishStoppedExternalPrepIfCurrent(gen) }
                return
            }
            // 6. Auto-prepare SPIRV shader tools + pinned zstd 1.5.7 (`libzstd.1.dylib`) via `runtime_sources.py`
            let runtimeScript = (tree.hasSuffix("/") ? tree : tree + "/") + "launchers/macos/runtime_sources.py"
            let needsRuntimeBuild = !S2ArmBootstrap.isRuntimeToolsPrefixReady(S2ArmBootstrap.runtimeToolsPrefix(in: tree))
                && !S2ArmBootstrap.inspectSystemRuntimeTools(pathEnv: env["PATH"] ?? "", runner: runner).ready
                && FileManager.default.fileExists(atPath: runtimeScript)
            if needsRuntimeBuild {
                hop {
                    guard let self, self.archiveGeneration == gen, !self.stopping, !self.installCancel.value else { return }
                    self.beginExternalStage(name: prepShaderToolsMsg)
                    self.say(prepShaderToolsMsg)
                }
            }
            let rtRes = S2ArmBootstrap.ensureRuntimeTools(
                in: tree,
                python: py,
                environment: env,
                runner: runner
            ) { @Sendable line in
                hop {
                    guard let self, self.archiveGeneration == gen, !self.stopping, !self.installCancel.value else { return }
                    self.append(line + "\n")
                }
            }
            if cancel.value {
                hop { self?.finishStoppedExternalPrepIfCurrent(gen) }
                return
            }
            if needsRuntimeBuild {
                guard rtRes.ok else {
                    hop {
                        guard let self, self.archiveGeneration == gen else { return }
                        self.installPhaseActive = false
                        if self.stopping || self.installCancel.value {
                            self.finishStoppedExternalPrep()
                            return
                        }
                        self.fail(String(format: buildFailedReasonFmt, "SPIRV / zstd tools"))
                    }
                    return
                }
                hop {
                    guard let self, self.archiveGeneration == gen, !self.stopping, !self.installCancel.value else { return }
                    self.finishExternalStage(name: prepShaderToolsMsg)
                }
            }
            if let rtBin = rtRes.binDir, !rtBin.isEmpty {
                env = S2ArmBuilder.environmentWithToolPaths(
                    base: env,
                    dotnetPath: dnRes.path,
                    extraBinDirs: (bashShimDir.map { [$0] } ?? []) + [rtBin, pyBin].filter { !$0.isEmpty },
                    home: homeDir,
                    runner: runner
                )
            }
            if let zstdLib = rtRes.zstdLib, !zstdLib.isEmpty {
                env["S2A_ZSTD_LIB"] = zstdLib
            }
            if cancel.value {
                hop { self?.finishStoppedExternalPrepIfCurrent(gen) }
                return
            }
            if let zstdBin = S2ArmBuilder.ensureZstdWrapper(workDir: workDir, python: py, pathEnv: env["PATH"] ?? "") {
                env = S2ArmBuilder.environmentWithToolPaths(
                    base: env,
                    dotnetPath: dnRes.path,
                    extraBinDirs: (bashShimDir.map { [$0] } ?? []) + [zstdBin],
                    home: homeDir,
                    runner: runner
                )
            }

            let finalPy = py
            let finalEnv = env
            hop {
                guard let self, self.archiveGeneration == gen else { return }
                self.installPhaseActive = false
                if self.stopping || self.installCancel.value {
                    self.finishStoppedExternalPrep()
                    return
                }
                let launch = self.s2armLaunch(
                    python: finalPy,
                    sourceInput: finalSourceInput,
                    isUnencrypted: isUnencrypted,
                    workDir: workDir,
                    eventsFile: eventsFile,
                    environment: finalEnv,
                    bashPath: resolvedBash
                )
                self.startBuildProcess(launch: launch, envCleanup: nil, macOutput: nil)
            }
        }
    }

    func s2armLaunch(
        python py: String,
        sourceInput: String,
        isUnencrypted: Bool? = nil,
        workDir: String,
        eventsFile: String,
        environment: [String: String],
        bashPath: String = "/bin/bash"
    ) -> ProcessLaunch {
        let unencrypted = isUnencrypted ?? (gameFolder != nil || (sourceInput as NSString).pathExtension.lowercased() == "nup")
        let isMac = target == BuildTarget.mac
        let deviceUDID = isMac ? nil : (devices.installDevice.isEmpty ? nil : devices.installDevice)
        let args = S2ArmBuilder.arguments(
            tree: s2armPath,
            sourceInput: sourceInput,
            keysPath: keysPath,
            isUnencryptedInput: unencrypted,
            workDir: workDir,
            isMacTarget: isMac,
            titleID: selectedTitleID ?? gameTitleID,
            deviceUDID: deviceUDID,
            eventsFile: eventsFile
        )
        let bash = bashPath.isEmpty ? "/bin/bash" : bashPath
        say(String(format: t("msg.running"), bash) + " " + args.joined(separator: " "))
        lastBuildCommand = [bash] + args
        let mergedEnv = S2ArmBuilder.environmentWithConcurrencyDefaults(
            into: environment.merging(S2ArmBuilder.environment(pythonPath: py, keysPath: keysPath, isUnencryptedInput: unencrypted)) { $1 }
        )
        return ProcessLaunch(executable: bash, arguments: args, environment: mergedEnv, directory: s2armPath, groupPython: py)
    }

    func finishS2ArmBuild() {
        let eventsText = try? String(contentsOfFile: s2armEventsPath, encoding: .utf8)
        let summary = eventsText.flatMap(S2ArmBuilder.parseEvents)
        if let ipa = summary?.ipaPath, !ipa.isEmpty {
            markAllDone()
            running = false
            done = true
            clearSeparateRomfsState()
            exportedIPAPath = ipa
            say("✓ " + shortPath(ipa))
            doneNote = String(format: t("msg.ipaAt"), shortPath(ipa))
            cleanupStaging()
            return
        }
        if let root = summary?.macRootPath, !root.isEmpty {
            if runningTarget == BuildTarget.mac, S2ArmMacAppPacker.canPackHost(in: s2armPath) {
                let workDir = effectiveWorkDir.isEmpty ? (root as NSString).deletingLastPathComponent : effectiveWorkDir
                let tid = gameTitleID ?? buildKey
                let name = gameName
                let macOutput = MacAppOutput(workDir: URL(fileURLWithPath: workDir), key: buildKey, titleID: gameTitleID, upstream: .s2arm, preferred: macAppPath)
                let tree = s2armPath
                let upstreamsRoot = upstreamsRootURL
                let homeDir = home
                let runner = self.runner
                archiveGeneration &+= 1
                let gen = archiveGeneration
                let packStageName = t("upstream.s2armPackingMacApp")
                if let pendingIdx = stages.firstIndex(where: { $0.state == .pending && $0.id < 1000 && BuildPlan.canonicalKind(of: $0.name) == .macApp }) {
                    stages[pendingIdx].name = packStageName
                    stages[pendingIdx].state = .running
                    stages[pendingIdx].started = Date()
                    refreshOverallProgress(parsedTotal: nil)
                } else {
                    let nextScriptID = (stages.filter { $0.id > 0 && $0.id < 1000 }.map(\.id).max() ?? 0) + 1
                    beginExternalStage(name: packStageName, scriptIndex: nextScriptID)
                }
                say(packStageName)
                let cancel = installCancel
                installCancel.set(false)
                installPhaseActive = true
                Task.detached(priority: .userInitiated) { [weak self] in
                    if cancel.value {
                        hop { self?.finishStoppedExternalPrepIfCurrent(gen) }
                        return
                    }
                    let res = S2ArmMacAppPacker.packApp(
                        s2armTree: tree,
                        macRootPath: root,
                        titleID: tid,
                        gameName: name,
                        destinationAppURL: macOutput.builderURL,
                        upstreamsRoot: upstreamsRoot,
                        home: homeDir,
                        runner: runner,
                        onLine: { line in
                            hop {
                                guard let self, self.archiveGeneration == gen, !self.stopping, !self.installCancel.value else { return }
                                self.append(line + "\n")
                            }
                        }
                    )
                    hop {
                        guard let self, self.archiveGeneration == gen else { return }
                        self.installPhaseActive = false
                        if self.stopping || self.installCancel.value {
                            self.finishStoppedExternalPrep()
                            return
                        }
                        switch res {
                        case .success:
                            self.markAllDone()
                            self.finishMacApp(macOutput)
                        case .failure(let err):
                            self.fail(err.localizedDescription)
                        }
                    }
                }
                return
            }
            markAllDone()
            running = false
            done = true
            say("✓ " + shortPath(root))
            doneNote = String(format: t("upstream.s2armMacDone"), shortPath(root))
            cleanupStaging()
            return
        }
        markAllDone()
        running = false
        done = true
        doneNote = t("upstream.s2armDone")
        cleanupStaging()
    }

    func s2armFailureNote(status: Int32) -> String {
        let eventsText = try? String(contentsOfFile: s2armEventsPath, encoding: .utf8)
        if let line = S2ArmBuilder.lastError(in: logTail, eventsText: eventsText) {
            return String(format: t("msg.buildFailedReason"), line)
        }
        return String(format: t("msg.buildFailed"), status)
    }
}
