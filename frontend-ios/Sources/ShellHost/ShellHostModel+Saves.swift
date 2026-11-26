import Foundation
import ShellUI

extension ShellHostModel {
    struct PendingSaveImport {
        let gameID: String
        let preview: SaveArchiveService.Preview
        let lease: SecurityScopedLease?
    }

    func cancelAllPendingSaveImports(for gameID: String? = nil) {
        for (token, pending) in pendingSaveImports {
            if gameID == nil || pending.gameID == gameID {
                pendingSaveImports.removeValue(forKey: token)
                pending.lease?.release()
            }
        }
    }

    func formattedLocalSaveSummary(_ summary: SaveArchiveService.LocalSummary?) -> String? {
        guard let summary, summary.hasEntries else { return nil }
        let clampedBytes = Int64(min(summary.totalBytes, UInt64(Int64.max)))
        let sizeText = Self.formatByteSize(clampedBytes)
        if summary.fileCount == 1 {
            return hostText("1 file · \(sizeText)")
        }
        return hostText("\(summary.fileCount) files · \(sizeText)")
    }

    public func pickSaveImportNow(for id: String) async -> SaveImportPreviewOutcome {
        guard let initialEntry = entries.first(where: { $0.id == id }) else {
            return .failed(hostText("This game could not be found."))
        }
        guard !isBusyWithGame else {
            return .failed(hostText("Close the running game before modifying saves."))
        }
        let folder = appFolder(for: id)
        guard !SaveArchiveService.hasPendingPullJournal(in: folder) else {
            return .failed(hostText("Launch this game once to finish syncing your previous cloud save before importing."))
        }

        let gen = nextSaveGeneration(for: id)
        let expectedFramework = initialEntry.frameworkURL

        switch await savePresenter.pickSaveSourceOutcome() {
        case .cancelled:
            return .cancelled
        case .unavailable:
            return .failed(hostText("The file picker could not open here. Open the app on its own and try again."))
        case .picked(let url):
            guard saveOpGeneration[id] == gen,
                  let currentEntry = entries.first(where: { $0.id == id && $0.frameworkURL == expectedFramework }),
                  !isBusyWithGame else {
                return .cancelled
            }

            let lease = SecurityScopedLease(url: url)
            let previewResult: Result<SaveArchiveService.Preview, Error> = await Task.detached(priority: .userInitiated) {
                Result { try SaveArchiveService.preview(url, expectedTitleID: id) }
            }.value

            guard saveOpGeneration[id] == gen,
                  entries.contains(where: { $0.id == id && $0.frameworkURL == expectedFramework }),
                  !isBusyWithGame else {
                lease.release()
                return .cancelled
            }

            switch previewResult {
            case .failure(let error):
                lease.release()
                return .failed(localizedSaveFailure(error, expectedTitleID: id))
            case .success(let preview):
                cancelAllPendingSaveImports(for: id)
                let token = UUID().uuidString
                pendingSaveImports[token] = PendingSaveImport(gameID: id, preview: preview, lease: lease)
                let hasExisting = SaveArchiveService.hasLocalSaveEntries(in: folder)
                let clampedBytes = Int64(min(preview.totalBytes, UInt64(Int64.max)))
                let prompt = SaveImportPrompt(
                    token: token,
                    gameID: id,
                    gameTitle: currentEntry.title,
                    sourceName: preview.source.lastPathComponent,
                    sourceKind: preview.sourceKind,
                    fileCount: preview.fileCount,
                    totalBytes: preview.totalBytes,
                    formattedSize: Self.formatByteSize(clampedBytes),
                    jksvTitleID: preview.meta?.formattedTitleID,
                    targetFolders: preview.folders,
                    hasExistingSave: hasExisting,
                    defaultMode: .replace
                )
                return .preview(prompt)
            }
        }
    }

    public func confirmSaveImportNow(for id: String, token: String, mode: SaveImportMode) async -> SaveImportCommitOutcome {
        guard let pending = pendingSaveImports.removeValue(forKey: token),
              pending.gameID == id else {
            return .cancelled
        }
        let lease = pending.lease
        var releaseInDefer = true
        defer {
            if releaseInDefer { lease?.release() }
        }

        guard let initialEntry = entries.first(where: { $0.id == id }) else {
            return .failed(hostText("This game could not be found."))
        }
        guard !isBusyWithGame else {
            return .failed(hostText("Close the running game before modifying saves."))
        }

        let gen = nextSaveGeneration(for: id)
        let expectedFramework = initialEntry.frameworkURL
        let folder = appFolder(for: id)
        let now = config.now()
        let preview = pending.preview
        let activeGameCheck = config.activeRunningGameID

        releaseInDefer = false
        let outcome: Result<URL?, Error> = await Task.detached(priority: .userInitiated) {
            defer { lease?.release() }
            let runningNow = await MainActor.run {
                !(activeGameCheck() ?? "").isEmpty
            }
            return Result {
                try SaveArchiveService.performImport(preview, into: folder, mode: mode, gameRunning: runningNow, now: now)
            }
        }.value

        guard saveOpGeneration[id] == gen,
              entries.contains(where: { $0.id == id && $0.frameworkURL == expectedFramework }) else {
            return .cancelled
        }

        switch outcome {
        case .failure(let error):
            return .failed(localizedSaveFailure(error, expectedTitleID: id))
        case .success(let backupURL):
            startBackupScan()
            await backupScanTask?.value
            refresh(id)

            let baseMessage: String
            if let backupURL {
                let backupLabel = CloudSaveSyncCheck.displayLabel(forBackupName: backupURL.lastPathComponent)
                baseMessage = hostText("Save imported. Your previous save was backed up (\(backupLabel)).")
            } else {
                baseMessage = hostText("Save imported.")
            }
            if hasCloudSavesEnabled(for: id) {
                return .imported(message: baseMessage + " " + hostText("Your cloud save will sync on the next launch."))
            }
            return .imported(message: baseMessage)
        }
    }

    public func cancelSaveImport(for id: String, token: String) {
        guard let pending = pendingSaveImports[token], pending.gameID == id else { return }
        pendingSaveImports.removeValue(forKey: token)
        pending.lease?.release()
    }

    public func exportSaveNow(for id: String) async -> SaveExportOutcome {
        guard let initialEntry = entries.first(where: { $0.id == id }) else {
            return .failed(hostText("This game could not be found."))
        }
        guard !isBusyWithGame else {
            return .failed(hostText("Close the running game before modifying saves."))
        }
        let folder = appFolder(for: id)
        guard SaveArchiveService.hasLocalSaveEntries(in: folder) else {
            return .failed(hostText("This game has no save to export yet."))
        }

        let gen = nextSaveGeneration(for: id)
        let expectedFramework = initialEntry.frameworkURL
        let exportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nx-save-exports-\(UUID().uuidString)", isDirectory: true)
        let fileName = SaveArchiveService.suggestedExportFileName(gameTitle: initialEntry.title, titleID: id)
        let zipURL = exportDir.appendingPathComponent(fileName, isDirectory: false)

        let packResult: Result<(file: URL, files: Int), Error> = await Task.detached(priority: .userInitiated) {
            Result { try SaveArchiveService.exportJKSV(from: folder, titleID: id, to: zipURL) }
        }.value

        guard saveOpGeneration[id] == gen,
              entries.contains(where: { $0.id == id && $0.frameworkURL == expectedFramework }),
              !isBusyWithGame else {
            try? FileManager.default.removeItem(at: exportDir)
            return .cancelled
        }

        switch packResult {
        case .failure(let error):
            try? FileManager.default.removeItem(at: exportDir)
            return .failed(localizedSaveFailure(error, expectedTitleID: id))
        case .success(let exported):
            defer { try? FileManager.default.removeItem(at: exportDir) }
            switch await savePresenter.presentExportArchive(at: exported.file) {
            case .exported:
                if exported.files == 1 {
                    return .exported(message: hostText("Exported 1 save file as a JKSV archive."))
                }
                return .exported(message: hostText("Exported \(exported.files) save files as a JKSV archive."))
            case .cancelled:
                return .cancelled
            case .unavailable:
                return .failed(hostText("The export sheet could not open here. Open the app on its own and try again."))
            }
        }
    }

    private func nextSaveGeneration(for id: String) -> UInt64 {
        let next = (saveOpGeneration[id] ?? 0) &+ 1
        saveOpGeneration[id] = next
        return next
    }

    private func hasCloudSavesEnabled(for id: String) -> Bool {
        switch cloudSaves(id) {
        case .own, .shell: return true
        case .off, .stale, .none: return false
        }
    }

    private func localizedSaveFailure(_ error: Error, expectedTitleID: String) -> String {
        guard let failure = error as? SaveArchiveFailure else {
            return hostText("Save operation failed: \(error.localizedDescription)")
        }
        switch failure {
        case .gameRunning:
            return hostText("Close the running game before modifying saves.")
        case .pendingPullJournal:
            return hostText("Launch this game once to finish syncing your previous cloud save before importing.")
        case .titleIDMismatch(_, let found):
            return hostText("This JKSV archive belongs to \(found), not \(expectedTitleID.uppercased()).")
        case .quotaExceeded:
            return hostText("That archive exceeds the save size or file count limit.")
        case .unsafePath, .symlinkNotAllowed:
            return hostText("That file or archive contains an unsafe path or symbolic link and was rejected.")
        case .invalidArchive:
            return hostText("That file could not be read as a valid save archive.")
        case .nothingToImport:
            return hostText("No save files were found in the selected item.")
        case .nothingToExport:
            return hostText("This game has no save to export yet.")
        case .destinationInsideSave:
            return hostText("Choose a destination outside the save folder.")
        case .sourceUnreadable:
            return hostText("The selected save could not be read. Download it in Files first if it is in iCloud Drive, then try again.")
        }
    }
}
