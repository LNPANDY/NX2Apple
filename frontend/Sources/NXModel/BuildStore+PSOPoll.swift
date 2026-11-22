import Foundation
import NXCore

// The progress of the Pipeline archive and game framework stages when the script gives no counts: the work folder's finished
// pso_offline.py batches, polled once a second (BuildStore.swift starts and stops it with the stage).
extension BuildStore {
    func startPSOPoll(stageID: Int, step: String) {
        psoPollTask?.cancel()
        psoPollGeneration &+= 1
        let generation = psoPollGeneration
        psoStageID = stageID
        psoStep = step
        psoNativeProgress = false
        let workDir = effectiveWorkDir
        psoPollTask = Task { [weak store = self] in
            while !Task.isCancelled {
                if !workDir.isEmpty {
                    let progress = await Task.detached(priority: .utility) {
                        BuildProgress.psoArchiveProgress(workDir: workDir)
                    }.value
                    guard !Task.isCancelled else { break }
                    if let progress {
                        await MainActor.run {
                            guard let store,
                                  store.psoPollGeneration == generation,
                                  store.psoStageID == stageID,
                                  !store.psoNativeProgress,
                                  store.effectiveWorkDir == workDir else { return }
                            store.applyPSOArchiveProgress(progress, stageID: stageID, generation: generation)
                        }
                    }
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { break }
                let keepGoing = await MainActor.run { [weak store] in
                    guard let store else { return false }
                    return store.psoPollGeneration == generation && store.psoStageID == stageID && !store.psoNativeProgress
                }
                if !keepGoing { break }
            }
        }
    }

    func stopPSOPoll() {
        psoPollGeneration &+= 1
        psoPollTask?.cancel()
        psoPollTask = nil
        psoStageID = nil
        psoStep = ""
        psoNativeProgress = false
    }

    /// Inspect `<workDir>/pso/mac-work` (or the iOS work directory / logs) for completed `pso_offline.py` batches while the
    /// `Pipeline archive` or `game framework` stage runs without native JSON counts from the script.
    package func pollPSOArchive() {
        guard !psoNativeProgress, let id = psoStageID, !effectiveWorkDir.isEmpty else { return }
        let generation = psoPollGeneration
        let workDir = effectiveWorkDir
        guard let p = BuildProgress.psoArchiveProgress(workDir: workDir),
              psoPollGeneration == generation,
              effectiveWorkDir == workDir else { return }
        applyPSOArchiveProgress(p, stageID: id, generation: generation)
    }

    func applyPSOArchiveProgress(_ p: PSOArchiveProgress, stageID: Int, generation: Int) {
        guard !psoNativeProgress, psoPollGeneration == generation, psoStageID == stageID,
              let i = stages.firstIndex(where: { $0.id == stageID && $0.state == .running }) else { return }
        let pct = min(Double(p.done) / Double(p.total) * 100.0, 99.0)
        let detail = BuildProgress.progressDetail([
            "step": psoStep,
            "done": p.done,
            "total": p.total,
            "unit": t("prog.unit.batches"),
            "note": p.merging ? t("prog.note.merging") : "",
        ])
        if stages[i].percent != pct || stages[i].detail != detail {
            stages[i].percent = pct
            stages[i].detail = detail
            refreshOverallProgress(parsedTotal: nil)
        }
    }
}
