import Foundation
import ShellUI

extension ShellHostModel {
    func cheatsStore(for entry: CatalogueEntry) -> GameCheatsStore {
        GameCheatsStore(titleID: entry.id, appFolder: appFolder(for: entry.id), frameworkURL: entry.frameworkURL)
    }

    func cheatsStore(for id: String) -> GameCheatsStore? {
        guard let entry = entries.first(where: { $0.id == id }) else { return nil }
        return cheatsStore(for: entry)
    }

    private func nextCheatsGeneration(for id: String) -> UInt64 {
        let next = (cheatsOpGeneration[id] ?? 0) &+ 1
        cheatsOpGeneration[id] = next
        return next
    }

    private nonisolated static func summary(from snap: GameCheatsSnapshot) -> GameCheatsSummary {
        let enabledCount = snap.entries.filter { $0.switchableOnIOS && $0.enabled }.count
        return GameCheatsSummary(
            buildID: snap.buildID,
            totalCount: snap.totalActiveCount,
            enabledCount: enabledCount,
            needsBakeCount: snap.codeNeedsBakeCount,
            masterOn: snap.masterOn,
            fuseTripped: snap.fuseAlert != nil
        )
    }

    func startCheatsSummaryScan() {
        cheatsScanTask?.cancel()
        cheatsScanGeneration &+= 1
        let generation = cheatsScanGeneration
        let targets: [(id: String, title: String, store: GameCheatsStore)] = entries.map { entry in
            (entry.id, entry.title, cheatsStore(for: entry))
        }
        guard !targets.isEmpty else {
            cheatsSummaries.removeAll()
            return
        }
        cheatsScanTask = Task { [weak self] in
            let scanned = await Task.detached(priority: .utility) { () -> [String: GameCheatsSummary] in
                var found: [String: GameCheatsSummary] = [:]
                for target in targets where !Task.isCancelled {
                    found[target.id] = target.store.loadSummary(gameTitle: target.title)
                }
                return found
            }.value
            guard let self, !Task.isCancelled, self.cheatsScanGeneration == generation else { return }
            let liveIDs = Set(self.entries.map(\.id))
            for (id, summary) in scanned where liveIDs.contains(id) {
                self.updateCheatsSummary(summary, for: id)
            }
        }
    }

    // MARK: - Synchronous helpers (retained for unit tests & direct callers)

    public func loadCheatsSnapshot(for id: String) -> GameCheatsSnapshot {
        guard let entry = entries.first(where: { $0.id == id }) else {
            return GameCheatsSnapshot(gameID: id, gameTitle: "")
        }
        let snapshot = cheatsStore(for: entry).loadSnapshot(gameTitle: entry.title)
        updateCheatsSummary(Self.summary(from: snapshot), for: id)
        return snapshot
    }

    public func setCheatMaster(for id: String, on: Bool) -> GameCheatsSnapshot {
        guard let entry = entries.first(where: { $0.id == id }) else {
            return GameCheatsSnapshot(gameID: id, gameTitle: "")
        }
        let store = cheatsStore(for: entry)
        do {
            try store.setMaster(on)
        } catch {
            notice = hostText("Could not save cheat settings.")
        }
        let updated = store.loadSnapshot(gameTitle: entry.title)
        updateCheatsSummary(Self.summary(from: updated), for: id)
        return updated
    }

    public func setCheatEntry(for id: String, key: String, on: Bool) -> GameCheatsSnapshot {
        guard let entry = entries.first(where: { $0.id == id }) else {
            return GameCheatsSnapshot(gameID: id, gameTitle: "")
        }
        let store = cheatsStore(for: entry)
        do {
            let updated = try store.setEntryEnabled(key: key, on: on, gameTitle: entry.title)
            updateCheatsSummary(Self.summary(from: updated), for: id)
            return updated
        } catch {
            notice = hostText("Could not save cheat settings.")
            let fallback = store.loadSnapshot(gameTitle: entry.title)
            updateCheatsSummary(Self.summary(from: fallback), for: id)
            return fallback
        }
    }

    public func dismissCheatFuseAlert(for id: String) -> GameCheatsSnapshot {
        guard let entry = entries.first(where: { $0.id == id }) else {
            return GameCheatsSnapshot(gameID: id, gameTitle: "")
        }
        let updated = cheatsStore(for: entry).dismissFuseAlert(gameTitle: entry.title)
        updateCheatsSummary(Self.summary(from: updated), for: id)
        return updated
    }

    public func confirmMismatchCheatImport(for id: String, token: String) -> CheatImportOutcome {
        guard let pending = pendingCheatImport, pending.gameID == id, pending.token == token,
              let entry = entries.first(where: { $0.id == id }) else {
            return .cancelled
        }
        pendingCheatImport = nil
        let store = cheatsStore(for: entry)
        do {
            let snapshot = try store.saveCheatFile(data: pending.data, targetBuildID: pending.targetBuildID, gameTitle: entry.title)
            updateCheatsSummary(Self.summary(from: snapshot), for: id)
            return .imported(snapshot: snapshot, buildID: pending.targetBuildID, entryCount: snapshot.totalActiveCount)
        } catch GameCheatsStore.StoreError.fileTooLarge {
            return .failed(hostText("The selected cheat file is too large."))
        } catch {
            return .failed(hostText("Could not save the cheat file."))
        }
    }

    public func cancelMismatchCheatImport(for id: String) {
        if pendingCheatImport?.gameID == id {
            pendingCheatImport = nil
        }
    }

    // MARK: - Async off-main-thread actions with generation & ownership revalidation

    public func loadCheatsSnapshotAsync(for id: String) async -> GameCheatsSnapshot {
        guard let entry = entries.first(where: { $0.id == id }) else {
            return GameCheatsSnapshot(gameID: id, gameTitle: "")
        }
        let gen = nextCheatsGeneration(for: id)
        let store = cheatsStore(for: entry)
        let title = entry.title
        let expectedFramework = entry.frameworkURL
        let snapshot = await Task.detached(priority: .userInitiated) {
            store.loadSnapshot(gameTitle: title)
        }.value
        guard cheatsOpGeneration[id] == gen,
              entries.contains(where: { $0.id == id && $0.frameworkURL == expectedFramework }) else {
            return snapshot
        }
        updateCheatsSummary(Self.summary(from: snapshot), for: id)
        return snapshot
    }

    public func setCheatMasterAsync(for id: String, on: Bool) async -> GameCheatsSnapshot {
        guard let entry = entries.first(where: { $0.id == id }) else {
            return GameCheatsSnapshot(gameID: id, gameTitle: "")
        }
        let gen = nextCheatsGeneration(for: id)
        let store = cheatsStore(for: entry)
        let title = entry.title
        let expectedFramework = entry.frameworkURL
        let (updated, failed) = await Task.detached(priority: .userInitiated) { () -> (GameCheatsSnapshot, Bool) in
            var failed = false
            do {
                try store.setMaster(on)
            } catch {
                failed = true
            }
            return (store.loadSnapshot(gameTitle: title), failed)
        }.value
        guard cheatsOpGeneration[id] == gen,
              entries.contains(where: { $0.id == id && $0.frameworkURL == expectedFramework }) else {
            return updated
        }
        if failed {
            notice = hostText("Could not save cheat settings.")
        }
        updateCheatsSummary(Self.summary(from: updated), for: id)
        return updated
    }

    public func setCheatEntryAsync(for id: String, key: String, on: Bool) async -> GameCheatsSnapshot {
        guard let entry = entries.first(where: { $0.id == id }) else {
            return GameCheatsSnapshot(gameID: id, gameTitle: "")
        }
        let gen = nextCheatsGeneration(for: id)
        let store = cheatsStore(for: entry)
        let title = entry.title
        let expectedFramework = entry.frameworkURL
        let (updated, failed) = await Task.detached(priority: .userInitiated) { () -> (GameCheatsSnapshot, Bool) in
            do {
                let snap = try store.setEntryEnabled(key: key, on: on, gameTitle: title)
                return (snap, false)
            } catch {
                return (store.loadSnapshot(gameTitle: title), true)
            }
        }.value
        guard cheatsOpGeneration[id] == gen,
              entries.contains(where: { $0.id == id && $0.frameworkURL == expectedFramework }) else {
            return updated
        }
        if failed {
            notice = hostText("Could not save cheat settings.")
        }
        updateCheatsSummary(Self.summary(from: updated), for: id)
        return updated
    }

    public func dismissCheatFuseAlertAsync(for id: String) async -> GameCheatsSnapshot {
        guard let entry = entries.first(where: { $0.id == id }) else {
            return GameCheatsSnapshot(gameID: id, gameTitle: "")
        }
        let gen = nextCheatsGeneration(for: id)
        let store = cheatsStore(for: entry)
        let title = entry.title
        let expectedFramework = entry.frameworkURL
        let updated = await Task.detached(priority: .userInitiated) {
            store.dismissFuseAlert(gameTitle: title)
        }.value
        guard cheatsOpGeneration[id] == gen,
              entries.contains(where: { $0.id == id && $0.frameworkURL == expectedFramework }) else {
            return updated
        }
        updateCheatsSummary(Self.summary(from: updated), for: id)
        return updated
    }

    private enum BackgroundImportDecision: Sendable {
        case empty
        case tooLarge
        case noValidCheats
        case missingBuildIDInName
        case writeFailed
        case mismatch(fileBuildID: String?, expectedBuildID: String)
        case saved(snapshot: GameCheatsSnapshot, buildID: String)
    }

    public func importCheatFileNow(for id: String) async -> CheatImportOutcome {
        guard let initialEntry = entries.first(where: { $0.id == id }) else {
            return .failed(hostText("This game could not be found."))
        }
        let gen = nextCheatsGeneration(for: id)
        let expectedFramework = initialEntry.frameworkURL

        let picked = await cheatPicker.pickCheatFileOutcome()

        // Revalidate generation and titleID ownership after awaiting the file picker.
        guard cheatsOpGeneration[id] == gen,
              let currentEntry = entries.first(where: { $0.id == id && $0.frameworkURL == expectedFramework }) else {
            return .cancelled
        }

        switch picked {
        case .cancelled:
            return .cancelled
        case .unavailable:
            return .failed(hostText("The file picker could not open here. Open the app on its own and try again."))
        case .unreadable:
            return .failed(hostText("The selected cheat file could not be read."))
        case .tooLarge:
            return .failed(hostText("The selected cheat file is too large."))
        case .picked(let data, let fileName):
            let store = cheatsStore(for: currentEntry)
            let gameTitle = currentEntry.title
            let decision = await Task.detached(priority: .userInitiated) { () -> BackgroundImportDecision in
                guard !data.isEmpty else { return .empty }
                guard data.count <= GameCheatsStore.maxFileBytes else { return .tooLarge }
                let parsed = GameCheatsStore.parse(data)
                let activeCount = parsed.filter { !$0.isLabel && !$0.isBroken }.count
                guard activeCount > 0 else { return .noValidCheats }

                let fileBuildID = GameCheatsStore.buildID(ofFileNamed: fileName)
                let expectedBuildID = store.resolvedBuildID()
                if let expectedBuildID {
                    if fileBuildID != expectedBuildID {
                        return .mismatch(fileBuildID: fileBuildID, expectedBuildID: expectedBuildID)
                    }
                    do {
                        let snap = try store.saveCheatFile(data: data, targetBuildID: expectedBuildID, gameTitle: gameTitle)
                        return .saved(snapshot: snap, buildID: expectedBuildID)
                    } catch GameCheatsStore.StoreError.fileTooLarge {
                        return .tooLarge
                    } catch {
                        return .writeFailed
                    }
                }
                guard let fileBuildID else { return .missingBuildIDInName }
                do {
                    let snap = try store.saveCheatFile(data: data, targetBuildID: fileBuildID, gameTitle: gameTitle)
                    return .saved(snapshot: snap, buildID: fileBuildID)
                } catch GameCheatsStore.StoreError.fileTooLarge {
                    return .tooLarge
                } catch {
                    return .writeFailed
                }
            }.value

            // Revalidate again before committing main-actor state or staging a pending mismatch.
            guard cheatsOpGeneration[id] == gen,
                  entries.contains(where: { $0.id == id && $0.frameworkURL == expectedFramework }) else {
                return .cancelled
            }

            switch decision {
            case .empty:
                return .failed(hostText("The selected cheat file is empty."))
            case .tooLarge:
                return .failed(hostText("The selected cheat file is too large."))
            case .noValidCheats:
                return .failed(hostText("No valid Atmosphere cheats were found in that file."))
            case .missingBuildIDInName:
                return .failed(hostText("Rename the file to the 16-digit build ID (.txt) and try again."))
            case .writeFailed:
                return .failed(hostText("Could not save the cheat file."))
            case .mismatch(let fileBuildID, let expectedBuildID):
                let token = UUID().uuidString
                pendingCheatImport = (gameID: id, token: token, targetBuildID: expectedBuildID, data: data)
                return .buildMismatch(
                    fileBuildID: fileBuildID,
                    expectedBuildID: expectedBuildID,
                    fileName: fileName,
                    pendingToken: token
                )
            case .saved(let snapshot, let buildID):
                pendingCheatImport = nil
                updateCheatsSummary(Self.summary(from: snapshot), for: id)
                return .imported(snapshot: snapshot, buildID: buildID, entryCount: snapshot.totalActiveCount)
            }
        }
    }

    public func confirmMismatchCheatImportAsync(for id: String, token: String) async -> CheatImportOutcome {
        guard let pending = pendingCheatImport, pending.gameID == id, pending.token == token,
              let entry = entries.first(where: { $0.id == id }) else {
            return .cancelled
        }
        pendingCheatImport = nil
        let gen = nextCheatsGeneration(for: id)
        let store = cheatsStore(for: entry)
        let gameTitle = entry.title
        let expectedFramework = entry.frameworkURL
        let payload = pending.data
        let targetBuildID = pending.targetBuildID

        let result: Result<GameCheatsSnapshot, Error> = await Task.detached(priority: .userInitiated) {
            do {
                let snap = try store.saveCheatFile(data: payload, targetBuildID: targetBuildID, gameTitle: gameTitle)
                return .success(snap)
            } catch {
                return .failure(error)
            }
        }.value

        guard cheatsOpGeneration[id] == gen,
              entries.contains(where: { $0.id == id && $0.frameworkURL == expectedFramework }) else {
            return .cancelled
        }

        switch result {
        case .success(let snapshot):
            updateCheatsSummary(Self.summary(from: snapshot), for: id)
            return .imported(snapshot: snapshot, buildID: targetBuildID, entryCount: snapshot.totalActiveCount)
        case .failure(GameCheatsStore.StoreError.fileTooLarge):
            return .failed(hostText("The selected cheat file is too large."))
        case .failure:
            return .failed(hostText("Could not save the cheat file."))
        }
    }
}
