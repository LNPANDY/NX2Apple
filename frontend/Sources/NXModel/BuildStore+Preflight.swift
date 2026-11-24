import Foundation
import NXCore

// Preflight guards before a build starts (missing master keys, compressed package peak space, cross-volume shellRoot budget)
// and monotonic overall stage progress tracking across `[k/n]` stages.

extension BuildStore {
    package func invalidateKeyProblem() {
        keyCheckGeneration &+= 1
        if keyProblem != nil {
            keyProblem = nil
        }
    }

    /// Resets monotonic overall stage counters and runs the synchronous `prod.keys` gate before starting a build.
    /// Returns `false` when a missing `master_key_XX` or invalid `header_key` blocks the build.
    package func prepareBuildPreflight() -> Bool {
        resetOverallProgress()
        if let problem = keyPreflightProblem() {
            keyProblem = problem
            doneNote = problem
            done = false
            return false
        }
        if keyProblem != nil {
            keyProblem = nil
        }
        return true
    }

    /// Evaluates `prod.keys` against `[basePath, updatePath] + dlcPaths` when building from encrypted Switch packages.
    /// Unknown or unreadable containers (`cannotCheck`) return `nil` so non-blocking cases proceed normally.
    package func keyPreflightProblem() -> String? {
        guard !fastRefreshActive else { return nil }
        guard gameFolder == nil else { return nil }
        let files = [basePath, updatePath] + dlcPaths
        guard !keysPath.isEmpty, !basePath.isEmpty else { return nil }
        return preflightKeyProblem(keysPath, files)
    }

    /// Checks output-volume peak space (using 3.5x for `.nsz` / `.xcz` and 1.0x for `.nsp` / `.xci`) and, for iOS shared-shell
    /// builds whose `shellRoot` sits on a different volume from the output folder, verifies `shellRoot` free space as well.
    /// When `fastRefreshActive` is true, evaluates a compact refresh budget (~500 MB) instead of package extraction budget.
    package func preflightSpaceProblem() -> String? {
        let folder = effectiveOutputFolder
        let inputPaths = [basePath, updatePath] + dlcPaths
        if !folder.isEmpty, let free = spaceAvailable(folder) {
            // A build again into the same folder keeps the game files it extracted before
            let reused = fastRefreshActive ? 0 : BuildSpace.finishedExtraction(in: nxnativeWorkDirectory(baseOut: folder, tidHex: buildKey))
            let needed = fastRefreshActive ? 500_000_000 : max(0, BuildSpace.estimatedNeeded(for: inputPaths) - reused)
            let space = BuildSpace(needed: needed, available: free)
            if space.isShort {
                return String(
                    format: t("space.short"),
                    shortPath(folder),
                    BuildSpace.text(space.needed),
                    BuildSpace.text(space.available)
                )
            }
        }
        if target != BuildTarget.mac, !exportsOneGame, !exportsFramework {
            let root = shellRoot
            if !root.isEmpty,
               !folder.isEmpty,
               !BuildSpace.sameVolume(folder, root, volumeID: volumeIdentifier),
               let shellFree = spaceAvailable(root) {
                let minBytes = fastRefreshActive ? 500_000_000 : BuildSpace.shellRootMinimumBytes
                let shellSpace = BuildSpace(needed: minBytes, available: shellFree)
                if shellSpace.isShort {
                    return String(
                        format: t("preflight.shortShellRoot"),
                        shortPath(root),
                        BuildSpace.text(shellSpace.needed),
                        BuildSpace.text(shellSpace.available)
                    )
                }
            }
        }
        return nil
    }

    package func resetOverallProgress() {
        totalStages = 0
        overallProgress = nil
        peakOverallProgress = 0
    }

    /// Pre-populates `stages` with the full expected stage plan (`.pending`) when a build begins so both
    /// the segmented overall bar and "Show all steps" know every step ahead from the start.
    package func seedBuildPlan(fastRefresh: Bool = false) {
        let engineRoot: String = {
            if isNxnativeVariantSelected { return activeNxnativeEngineRoot() }
            if !repo.path.isEmpty { return EngineLayout.root(repo.path) }
            return ""
        }()
        let deviceName = devices.installDevice.isEmpty ? "" : devices.deviceName(devices.installDevice)
        let input = BuildPlanInput(
            upstream: activeBuildUpstream,
            target: target,
            fastRefresh: fastRefresh,
            exportsOneGame: exportsOneGame,
            exportsFramework: exportsFramework,
            exportsShell: exportsShell,
            deviceName: deviceName,
            preflightEnabled: preflightApp != nil && MacPreflight.enabled(defaults),
            isGameFolder: gameFolder != nil,
            isNUP: isCurrentInputNUP,
            hasDLC: !dlcPaths.isEmpty,
            titleID: selectedTitleID ?? gameTitleID ?? (fastRefresh ? fastRefreshTitleID : nil),
            engineRoot: engineRoot,
            canPackS2ArmMacApp: S2ArmMacAppPacker.canPackHost(in: s2armPath),
            includeDeviceCopyStage: devices.currentPostBuildTransferMode != .skip
        )
        let planned = BuildPlan.initialStages(for: input, localizedName: t)
        stages = planned
        let scriptCount = planned.filter { $0.id > 0 && $0.id < 1000 }.count
        totalStages = scriptCount
        refreshOverallProgress(parsedTotal: scriptCount > 0 ? scriptCount : nil)
    }

    package func refreshOverallProgress(parsedTotal: Int?) {
        if let n = parsedTotal, n > 0, n < 1000, n > totalStages {
            totalStages = n
        }
        if let next = BuildProgress.overallFraction(stages: stages, totalStages: totalStages, floor: peakOverallProgress) {
            peakOverallProgress = max(peakOverallProgress, next)
            overallProgress = peakOverallProgress
        }
    }

    package func reconcileScriptStageTotal() {
        let scriptStages = stages.filter { $0.id > 0 && $0.id < 1000 }
        if !scriptStages.isEmpty, !stages.contains(where: { $0.state == .failed }) {
            totalStages = scriptStages.count
        }
        refreshOverallProgress(parsedTotal: nil)
    }

    package func completeOverallProgress() {
        BuildPlan.pruneUnrunPendingStages(in: &stages)
        let scriptStages = stages.filter { $0.id > 0 && $0.id < 1000 }
        if !scriptStages.isEmpty {
            totalStages = scriptStages.count
        }
        peakOverallProgress = 1.0
        overallProgress = 1.0
    }

    /// Active `(current, total)` stage badge (such as `(3, 8)` or `(7, 7)`), nil before any stage is known.
    package var currentStagePosition: (current: Int, total: Int)? {
        let scriptStages = stages.filter { $0.id > 0 && $0.id < 1000 }
        let postStages = stages.filter { $0.id >= 1000 }
        let scriptTotal = max(totalStages, scriptStages.map(\.id).max() ?? 0)
        if let runningScript = scriptStages.last(where: { $0.state == .running }) {
            guard scriptTotal > 0 else { return nil }
            return (min(runningScript.id, scriptTotal), scriptTotal)
        }
        if !postStages.isEmpty {
            let scriptDone = !scriptStages.isEmpty && !scriptStages.contains(where: { $0.state != .done })
            let scriptBase = scriptStages.isEmpty ? 0 : (scriptDone ? scriptStages.count : max(scriptTotal, scriptStages.count))
            let total = scriptBase + postStages.count
            let activeIndex = postStages.lastIndex(where: { $0.state == .running })
                ?? postStages.lastIndex(where: { $0.state != .pending })
                ?? 0
            return (min(scriptBase + activeIndex + 1, total), total)
        }
        guard scriptTotal > 0, !scriptStages.isEmpty else { return nil }
        let currentStage = scriptStages.last(where: { $0.state != .pending }) ?? scriptStages.last
        guard let currentStage else { return nil }
        let resolvedTotal = (done && failure == nil) ? scriptStages.count : scriptTotal
        return (min(currentStage.id, resolvedTotal), resolvedTotal)
    }

    /// The build's last stage: the new app is opened once, hidden, so that macOS checks it now and not at the player's first
    /// start (#1005, `MacPreflight`). Its end, whatever it is, leaves the build done: a failure is a line in the log and a
    /// failed stage. Skipped when switched off in Settings, or when the app's launcher would start the game instead.
    func preflight(_ app: URL) async {
        guard let open = preflightApp, MacPreflight.enabled(defaults), preflightSupported(app) else { return }
        operation?.kind = .verifyingFirstStart
        let started = Date()
        let id: Int
        if let existingIdx = stages.firstIndex(where: { $0.nameKey == "stage.preflight" || $0.name == "preflight" }) {
            id = stages[existingIdx].id
            stages[existingIdx].state = .running
            stages[existingIdx].started = started
            stages[existingIdx].nameKey = "stage.preflight"
        } else {
            id = (stages.map(\.id).max() ?? 0) + 1
            stages.append(Stage(id: id, name: "preflight", state: .running, started: started, nameKey: "stage.preflight"))
        }
        refreshOverallProgress(parsedTotal: nil)
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
            stages[i].percent = 100
            say("✓ " + String(format: t("msg.preflightDone"), Int(Date().timeIntervalSince(started).rounded())))
        }
        refreshOverallProgress(parsedTotal: nil)
    }
}
