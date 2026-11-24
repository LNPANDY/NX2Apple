import Foundation
import NXCore

/// Per-entry summary shown in the in-app completion modal and formatted into system notifications after refresh completes.
package struct RefreshNoticeItem: Identifiable, Equatable, Sendable {
    package var id: UUID
    package var gameID: UUID?
    package var titleID: String
    package var name: String
    package var target: String
    package var succeeded: Bool
    package var reason: String?
    package var imgStatus: QueueEntryImgStatus

    package init(
        id: UUID = UUID(),
        gameID: UUID? = nil,
        titleID: String,
        name: String,
        target: String,
        succeeded: Bool,
        reason: String? = nil,
        imgStatus: QueueEntryImgStatus = .unchanged
    ) {
        self.id = id
        self.gameID = gameID
        self.titleID = titleID
        self.name = name
        self.target = target
        self.succeeded = succeeded
        self.reason = reason
        self.imgStatus = imgStatus
    }
}

/// Consolidated summary emitted when a refresh batch or single refresh completes.
package struct RefreshCompletionSummary: Identifiable, Equatable, Sendable {
    package var id: UUID
    package var isBatch: Bool
    package var items: [RefreshNoticeItem]
    package var deviceName: String?

    package init(
        id: UUID = UUID(),
        isBatch: Bool,
        items: [RefreshNoticeItem],
        deviceName: String? = nil
    ) {
        self.id = id
        self.isBatch = isBatch
        self.items = items
        self.deviceName = deviceName
    }

    package var allSucceeded: Bool {
        !items.isEmpty && items.allSatisfy(\.succeeded)
    }

    package var manualReplaceItems: [RefreshNoticeItem] {
        items.filter {
            if case .manualReplace = $0.imgStatus { return true }
            return false
        }
    }

    package var transferredItems: [RefreshNoticeItem] {
        items.filter {
            if case .transferred = $0.imgStatus { return true }
            return false
        }
    }
}

/// Pure formatting helpers for refresh completion notifications and summary lines (no semicolons/em-dashes).
package enum RefreshCompletionFormatter {
    package static func notificationText(
        for summary: RefreshCompletionSummary,
        t: (String) -> String
    ) -> (title: String, body: String) {
        let succeededCount = summary.items.filter(\.succeeded).count
        let failedCount = summary.items.count - succeededCount
        let title: String
        if summary.items.count <= 1, let single = summary.items.first {
            if single.succeeded {
                title = String(format: t("notify.doneTitle"), single.name)
            } else {
                title = String(format: t("notify.failedTitle"), single.name)
            }
        } else if failedCount == 0 {
            title = String(format: t("refreshDone.notifyAllSucceeded"), succeededCount)
        } else {
            title = String(format: t("refreshDone.notifyPartial"), succeededCount, failedCount)
        }

        let lines = summary.items.map { item -> String in
            let platform = item.target == BuildTarget.mac ? t("batchRefresh.platformMac") : t("batchRefresh.platformIOS")
            let statusPart = itemLineStatus(item, t: t)
            return "\(item.name) (\(platform)) · \(statusPart)"
        }
        return (title, lines.joined(separator: "\n"))
    }

    package static func itemLineStatus(_ item: RefreshNoticeItem, t: (String) -> String) -> String {
        guard item.succeeded else {
            if let reason = item.reason, !reason.isEmpty {
                return String(format: t("refreshDone.itemFailedReason"), reason)
            }
            return t("refreshDone.itemFailed")
        }
        switch item.imgStatus {
        case .unchanged:
            return item.target == BuildTarget.mac
                ? t("refreshDone.statusMacUpdated")
                : t("refreshDone.statusNoImgChange")
        case .transferred(let imgName, let deviceName):
            return String(format: t("refreshDone.statusImgTransferred"), imgName, deviceName)
        case .manualReplace(let imgPath, _):
            let imgName = imgPath.isEmpty ? "romfs.img" : (imgPath as NSString).lastPathComponent
            return String(format: t("refreshDone.statusImgManual"), imgName)
        }
    }
}

extension BuildStore {
    /// Writes per-entry `.img` update/transfer results back onto `queue.entries` by `queueEntryID` (falling back to `titleID`),
    /// preventing any cross-game attribution mismatch.
    package func applyBatchImgResults(_ results: [ShellInstaller.BatchGameResult]) {
        guard let queue else { return }
        for item in results {
            queue.updateImgStatus(entryID: item.queueEntryID, titleID: item.titleID, imgStatus: item.imgStatus)
        }
    }

    package func recordActiveEntryArchiveOutcome(_ outcome: ArchivePackOutcome) {
        guard let queue, let entryID = activeQueuedEntryID else { return }
        if outcome.didUpdateImg {
            let path = outcome.primaryImgPath
            queue.updateImgStatus(
                entryID: entryID,
                titleID: fastRefreshTitleID ?? gameTitleID ?? "",
                imgStatus: .manualReplace(imgPath: path, reason: nil)
            )
        } else {
            queue.updateImgStatus(
                entryID: entryID,
                titleID: fastRefreshTitleID ?? gameTitleID ?? "",
                imgStatus: .unchanged
            )
        }
    }

    package func publishRefreshCompletion(
        id: UUID = UUID(),
        isBatch: Bool,
        items: [RefreshNoticeItem],
        deviceName: String?
    ) {
        guard !items.isEmpty else { return }
        let summary = RefreshCompletionSummary(id: id, isBatch: isBatch, items: items, deviceName: deviceName)
        refreshCompletionSummary = summary
        pendingRefreshNotice = summary
    }

    package func publishBatchQueueRefreshCompletionIfNeeded(batchID: UUID) {
        guard refreshCompletionSummary?.id != batchID, let queue else { return }
        let entries = queue.entries.filter { $0.batch == batchID }
        guard !entries.isEmpty,
              entries.allSatisfy({ $0.finished && $0.packagePending == nil }) else { return }
        // Only emit the refresh completion summary when the batch contains refresh entries or explicit img updates.
        let hasRefreshOrImg = entries.contains { $0.fastRefresh || $0.imgStatus != nil }
        guard hasRefreshOrImg else { return }

        let items = entries.map { entry in
            RefreshNoticeItem(
                id: entry.id,
                gameID: entry.gameID,
                titleID: entry.titleID,
                name: entry.name,
                target: entry.target,
                succeeded: entry.status == .done,
                reason: entry.reason,
                imgStatus: entry.imgStatus ?? .unchanged
            )
        }
        let devName = devices.installDevice.isEmpty ? nil : devices.deviceName(devices.installDevice)
        publishRefreshCompletion(id: batchID, isBatch: entries.count > 1, items: items, deviceName: devName)
    }
}
