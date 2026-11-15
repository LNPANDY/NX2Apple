import Combine
import Foundation
import NXCore
import NXLauncher
import NXModel

extension LiveOnboardingDriver {
    // MARK: Background progress and installs

    private static let handledDepIDs: Set<String> = ["xcode", "metal", "python", "dotnet"]

    func bindProgressStreams() {
        Publishers.CombineLatest(stores.dependencies.$installProgress, stores.dependencies.$installDetail)
            .sink { [weak self] _, _ in
                self?.recomputeBackground()
            }
            .store(in: &subscriptions)

        Publishers.CombineLatest3(
            stores.engineSync.$busy,
            stores.engineSync.$downloadFraction,
            stores.engineSync.$downloadStatus
        )
        .sink { [weak self] _, _, _ in
            self?.recomputeBackground()
        }
        .store(in: &subscriptions)
    }

    func deps(for task: OnboardingBackgroundTask) -> [Dep] {
        switch task {
        case .python: return stores.dependencies.deps.filter { $0.id == "python" }
        case .dotnet: return stores.dependencies.deps.filter { $0.id == "dotnet" }
        case .tools: return stores.dependencies.deps.filter { !Self.handledDepIDs.contains($0.id) }
        }
    }

    func recomputeBackground() {
        if stores.engineSync.busy, !stores.engineSync.downloadStatus.isEmpty {
            state.engineTransfer = OnboardingTransferProgress(
                fraction: stores.engineSync.downloadFraction,
                detail: stores.engineSync.downloadStatus
            )
        } else {
            state.engineTransfer = nil
        }

        guard backgroundStarted, stores.dependencies.checked else { return }
        for task in OnboardingBackgroundTask.allCases {
            let rows = deps(for: task)
            if rows.allSatisfy(\.present) {
                state.background[task] = .done
                state.backgroundDetails.removeValue(forKey: task)
            } else if let failure = rows.compactMap({ failedDeps[$0.id] }).first {
                state.background[task] = .failed(failure)
                state.backgroundDetails.removeValue(forKey: task)
            } else if let active = rows.first(where: { $0.installing || $0.id == currentInstall }) {
                let progress = taskProgress(for: task, rows: rows, active: active)
                state.background[task] = .running(progress.fraction)
                if let detail = progress.detail, !detail.isEmpty {
                    state.backgroundDetails[task] = detail
                } else {
                    state.backgroundDetails.removeValue(forKey: task)
                }
            } else {
                state.background[task] = .queued
                state.backgroundDetails.removeValue(forKey: task)
            }
        }
    }

    private func taskProgress(
        for task: OnboardingBackgroundTask,
        rows: [Dep],
        active: Dep
    ) -> (fraction: Double?, detail: String?) {
        let subFraction = stores.dependencies.installProgress[active.id]
        let subDetail = stores.dependencies.installDetail[active.id]
        if rows.count <= 1 {
            return (subFraction, subDetail)
        }
        let doneCount = rows.filter(\.present).count
        let combined = (Double(doneCount) + (subFraction ?? 0.1)) / Double(rows.count)
        let label = t(active.name)
        if let subDetail, !subDetail.isEmpty {
            return (min(max(combined, 0), 1), "\(label) · \(subDetail)")
        }
        return (min(max(combined, 0), 1), "\(label) (\(doneCount + 1)/\(rows.count))")
    }

    /// One install at a time, in the order Python, .NET, tools. Homebrew and its formulas need Xcode's command line tools,
    /// so they wait for Xcode to be ready. The other two start at once.
    func pumpInstalls() {
        guard installApproved, backgroundStarted, stores.dependencies.checked, currentInstall == nil, state.exit == nil else { return }
        for task in OnboardingBackgroundTask.allCases {
            if task == .tools && state.xcode != .ready { continue }
            guard let next = deps(for: task).first(where: { !$0.present && failedDeps[$0.id] == nil && !$0.installing }) else { continue }
            currentInstall = next.id
            sawRecheck = false
            logMark = model.logTail.count
            env.installDep(stores.dependencies, next)
            recomputeBackground()
            return
        }
    }

    /// An install finished and detection ran again: either its row is present now, or it failed.
    func concludeInstall() {
        guard let id = currentInstall, sawRecheck else { return }
        currentInstall = nil
        if dep(id)?.present == false {
            let name = dep(id).map { t($0.name) } ?? id
            let output = model.logTail.count >= logMark ? String(model.logTail.dropFirst(logMark)) : model.logTail
            failedDeps[id] = OnboardingFailure(message: String(format: t("dep.install.fail"), name), details: Self.tail(output))
        }
    }

    // MARK: Keys

    func searchKeys() async {
        guard state.step == .keys, state.exit == nil, state.keys != .validating, state.keys != .skipped else { return }
        let known = model.keysPath
        let candidates = ([known].filter { !$0.isEmpty && FileManager.default.fileExists(atPath: $0) })
            + env.keyCandidates(gamesFolder: library.folder.isEmpty ? model.gameDir : library.folder)
        if let first = candidates.first { state.keys = .found(URL(fileURLWithPath: first)) } else { state.keys = .empty }
    }

    func validateKeys(_ url: URL) {
        store(nil, OnboardingDefaults.keysSkipped)
        state.keys = .validating
        state.games = .empty
        spawn("keys") { d in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let groups = await d.packageGroupsForKeyCheck()
            let detailed = await d.worstKeyOutcome(keysPath: url.path, groups: groups)
            guard !Task.isCancelled, d.state.exit == nil, d.state.step == .keys, d.state.keys == .validating else { return }
            switch detailed.outcome {
            case .fits, .cannotCheck:
                d.model.updateSlot("keys") {
                    $0.paths = [url.path]
                    $0.problem = ""
                }
                d.keepKeys(url.path)
                d.state.keys = .valid
                d.advanceIfReady()
            default:
                d.state.keys = .invalid(KeyCheck.detailedMessage(detailed, d.t))
            }
        }
    }

    /// Collects `[base, update, dlc...]` file groups from the current slots, any known game folder (including sibling
    /// Update and DLC packages beside `basePath`), and any games discovered during folder scanning.
    func packageGroupsForKeyCheck(scannedGames: [LibraryGame] = []) async -> [[String]] {
        var groups: [[String]] = []
        var currentSlots = [model.basePath, model.updatePath] + model.dlcPaths
        let folderHint: String = {
            if !library.folder.isEmpty { return library.folder }
            if !model.gameDir.isEmpty { return model.gameDir }
            if !model.basePath.isEmpty { return (model.basePath as NSString).deletingLastPathComponent }
            return ""
        }()
        if !folderHint.isEmpty, (currentSlots.count < 2 || currentSlots[1].isEmpty && model.dlcPaths.isEmpty) {
            let classified = await Task.detached {
                GameInputs.classify(GameInputs.inputFiles(in: folderHint))
            }.value
            let base = currentSlots[0].isEmpty ? (classified.base ?? "") : currentSlots[0]
            let update = currentSlots[1].isEmpty ? (classified.update ?? "") : currentSlots[1]
            let dlc = model.dlcPaths.isEmpty ? classified.dlc : model.dlcPaths
            currentSlots = [base, update] + dlc
        }
        if currentSlots.contains(where: { !$0.isEmpty }) {
            groups.append(currentSlots)
        }
        for game in scannedGames where game.inputs[GameLibrary.folderInput]?.first == nil {
            let base = game.inputs["base"]?.first ?? ""
            let update = game.inputs["update"]?.first ?? ""
            let dlc = game.inputs["dlc"] ?? []
            let group = [base, update] + dlc
            if group.contains(where: { !$0.isEmpty }), !groups.contains(group) {
                groups.append(group)
            }
        }
        return groups
    }

    func worstKeyOutcome(keysPath: String, groups: [[String]]) async -> KeyCheck.DetailedOutcome {
        guard !groups.isEmpty else {
            return await env.checkKeys(keysPath, files: [])
        }
        var bestMissing: KeyCheck.DetailedOutcome?
        var fallbackCannotCheck: KeyCheck.DetailedOutcome?
        for group in groups {
            let current = await env.checkKeys(keysPath, files: group)
            switch current.outcome {
            case .unreadableKeys, .noHeaderKey, .wrongHeaderKey:
                return current
            case let .tooOld(_, generation, _):
                if let prev = bestMissing, case let .tooOld(_, prevGen, _) = prev.outcome, prevGen >= generation {
                    continue
                }
                bestMissing = current
            case .cannotCheck:
                if fallbackCannotCheck == nil { fallbackCannotCheck = current }
            case .fits:
                break
            }
        }
        if let bestMissing { return bestMissing }
        return fallbackCannotCheck ?? KeyCheck.DetailedOutcome(outcome: .fits, file: nil)
    }

    // MARK: Games

    func enterGames() async {
        let known = library.folder.isEmpty ? model.gameDir : library.folder
        if case .found = state.games { return }
        if !known.isEmpty, FileManager.default.fileExists(atPath: known) {
            state.games = .scanning
            await scanGames(URL(fileURLWithPath: known))
        } else {
            state.games = .empty
        }
    }

    func scanGames(_ url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let found = await env.scanGames(url, stores.repo.path, state.keys == .skipped ? "" : model.keysPath)
        guard !Task.isCancelled, state.step == .games, state.exit == nil else { return }
        guard !found.isEmpty else {
            state.games = .none
            return
        }
        let keys = state.keys == .skipped ? "" : model.keysRowPath
        let keylessInput = state.keys == .skipped ? found.lazy.compactMap { $0.inputs[GameLibrary.folderInput]?.first }.first : nil
        model.scan(folder: keylessInput ?? url.path)
        if state.keys == .skipped || !keys.isEmpty {
            model.updateSlot("keys") {
                $0.paths = keys.isEmpty ? [] : [keys]
                $0.problem = ""
            }
        }
        library.setFolder(url)
        if !model.running { model.outDir = url.path }
        state.games = .found(found.map {
            OnboardingGame(
                id: $0.titleID,
                title: $0.name,
                version: "",
                cover: GameLibrary.artwork(for: $0, slot: .thumbnail, repo: stores.repo.path, maxPixel: ArtworkImages.cardPixels),
                needsKeys: $0.inputs[GameLibrary.folderInput]?.first == nil
            )
        })
        let ids = found.map(\.titleID)
        spawn("covers") { d in
            await d.env.fetchArtwork(ids)
            guard case .found(var games) = d.state.games else { return }
            for i in games.indices where games[i].cover == nil {
                if let g = found.first(where: { $0.titleID == games[i].id }) {
                    games[i].cover = GameLibrary.artwork(for: g, slot: .thumbnail, repo: d.stores.repo.path, maxPixel: ArtworkImages.cardPixels)
                }
            }
            d.state.games = .found(games)
        }
        // Re-verify prod.keys against every base, update and DLC package discovered in the chosen folder.
        if state.keys != .skipped, !model.keysPath.isEmpty {
            let groups = await packageGroupsForKeyCheck(scannedGames: found)
            if !groups.isEmpty {
                let detailed = await worstKeyOutcome(keysPath: model.keysPath, groups: groups)
                if KeyCheck.blocksBuild(detailed) {
                    state.keys = .invalid(KeyCheck.detailedMessage(detailed, t))
                    state.step = .keys
                    persistStep()
                }
            }
        }
    }

    // MARK: Advancing

    func advanceIfReady() {
        guard !suppressAdvance, state.exit == nil, state.step == .xcode || state.step == .keys, state.canAdvance else { return }
        let step = state.step
        spawn("advance") { d in
            try? await Task.sleep(nanoseconds: UInt64(d.env.advanceDelay * 1_000_000_000))
            if d.state.step == step, !d.suppressAdvance { d.next() }
        }
    }
}
