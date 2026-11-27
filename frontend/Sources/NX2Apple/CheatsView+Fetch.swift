import Foundation
import NXCore
import NXModel

extension CheatsView {
    func fetchOnlineCheats() {
        guard canFetchOnline, let cheatFiles, let game, let bid = buildID else { return }
        actionGeneration &+= 1
        let gen = actionGeneration
        let targetID = game.id
        let titleID = game.titleID
        let folder = cheatFiles.folder
        let transport = cheatFetchTransport
        let rxEnd = fixupsMetadata.mainRxEnd
        let trampolines = trampolinesMetadata
        fetchingOnline = true
        result = nil
        Task.detached(priority: .userInitiated) {
            let outcome = await CheatFetcher.fetch(
                titleID: titleID,
                buildID: bid,
                into: folder,
                transport: transport
            )
            let preview: CheatOnlinePreview? = {
                guard !outcome.wroteFile,
                      outcome.receipt.statusKind == .preservedUser,
                      let onlineText = outcome.onlineText else {
                    return nil
                }
                return CheatOnlinePreview.build(
                    titleID: titleID,
                    buildID: bid,
                    folder: folder,
                    onlineText: onlineText,
                    sources: outcome.onlineSources,
                    entryCount: outcome.onlineEntryCount,
                    rxEnd: rxEnd,
                    trampolines: trampolines
                )
            }()
            await MainActor.run {
                guard actionGeneration == gen, self.game?.id == targetID else { return }
                fetchingOnline = false
                fetchReceipt = outcome.receipt
                refresh()
                if outcome.wroteFile {
                    cachedOnlineCandidate = nil
                    onlineLookupOverride = nil
                    result = (String(format: loc.t("cheats.fetch.done"), outcome.receipt.entryCount), true)
                    return
                }
                switch outcome.receipt.statusKind {
                case .preservedUser:
                    if let preview {
                        cachedOnlineCandidate = preview
                        onlineLookupOverride = nil
                        activePreview = preview
                    } else if outcome.onlineLookupStatus == .notFound {
                        cachedOnlineCandidate = nil
                        onlineLookupOverride = .notFound
                        result = (loc.t("cheats.fetch.preservedNotFound"), false)
                    } else if outcome.onlineLookupStatus == .offline {
                        cachedOnlineCandidate = nil
                        onlineLookupOverride = .offline
                        result = (loc.t("cheats.fetch.preservedOffline"), false)
                    } else {
                        result = (loc.t("cheats.fetch.statusPreserved"), true)
                    }
                case .fetched:
                    cachedOnlineCandidate = nil
                    onlineLookupOverride = nil
                    result = (String(format: loc.t("cheats.fetch.done"), outcome.receipt.entryCount), true)
                case .notFound:
                    cachedOnlineCandidate = nil
                    onlineLookupOverride = nil
                    result = (loc.t("cheats.fetch.statusNotFound"), false)
                case .offline, .none:
                    cachedOnlineCandidate = nil
                    onlineLookupOverride = nil
                    result = (loc.t("cheats.fetch.statusOffline"), false)
                }
            }
        }
    }

    func applyOnlinePreview(_ preview: CheatOnlinePreview, mergeOnly: Bool) {
        guard let cheatFiles, let game else { return }
        actionGeneration &+= 1
        let gen = actionGeneration
        let targetID = game.id
        let folder = cheatFiles.folder
        activePreview = nil
        busy = true
        result = nil
        Task.detached(priority: .userInitiated) {
            let outcomeResult: Result<CheatWriteOutcome, Error> = Result {
                if mergeOnly {
                    try CheatFetcher.mergeMissingEntries(
                        localText: preview.localText,
                        onlineText: preview.onlineText,
                        into: folder,
                        buildID: preview.buildID,
                        titleID: preview.titleID,
                        sources: preview.sources
                    )
                } else {
                    try CheatFetcher.replaceWithOnline(
                        onlineText: preview.onlineText,
                        into: folder,
                        buildID: preview.buildID,
                        titleID: preview.titleID,
                        sources: preview.sources
                    )
                }
            }
            await MainActor.run {
                guard actionGeneration == gen, self.game?.id == targetID else { return }
                busy = false
                switch outcomeResult {
                case .success(let written):
                    cachedOnlineCandidate = nil
                    onlineLookupOverride = nil
                    fetchReceipt = written.receipt
                    refresh()
                    let key = mergeOnly ? "cheats.fetch.mergedDone" : "cheats.fetch.replacedDone"
                    let count = mergeOnly ? written.addedCount : written.totalEntryCount
                    result = (String(format: loc.t(key), count, written.backupFileName), true)
                case .failure(let error):
                    result = (String(format: loc.t("cheats.writeFailed"), error.localizedDescription), false)
                }
            }
        }
    }
}
